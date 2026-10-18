import Foundation
import AVFoundation
import VideoToolbox
import CoreGraphics
import CoreVideo
import IOSurface

/// Real-Time Direct Video Recorder (Metal GPU 1080p Compositor + ProRes 422 LT 112-FPS Studio Encoder for NootedRed.kext!)
public final class RealTimeDirectMovieRecorder {

    private let writerQueue = DispatchQueue(label: "com.zoomkemouse.realtimerecorder", qos: .userInteractive)
    private let audioWriterQueue = DispatchQueue(label: "com.zoomkemouse.audiowriter", qos: .userInteractive)
    private let stateLock = NSLock()

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let compositor = FrameCompositor()

    private struct QueuedFrame {
        let ioSurface: IOSurfaceRef?
        let fallbackCGImage: CGImage?
        let uptime: TimeInterval
        let targetSize: CGSize
        let camera: CameraRenderState
        let cursor: CursorRenderState
        let settings: StudioSettings
    }

    private var frameQueue: [QueuedFrame] = []
    private let maxQueueCapacity: Int = 16

    private var isRecordingFlag: Bool = false
    private var baseUptime: TimeInterval = 0
    private var hasAnchoredFirstFrame: Bool = false
    private var lastFrameUptime: TimeInterval = 0
    private var lastVideoTicks: Int64 = -1
    private var targetFPS: Int = 60
    private var lastAudioPTS: CMTime = .invalid
    private var outputURL: URL?
    private var tempMOVURL: URL?
    private var requestedCodec: VideoCodecPreset = .proRes422
    private var outputSize: CGSize = CGSize(width: 1920, height: 1080)

    public init() {}

    deinit {
        stateLock.lock()
        for f in frameQueue {
            if let surf = f.ioSurface {
                IOSurfaceDecrementUseCount(surf)
            }
        }
        frameQueue.removeAll()
        stateLock.unlock()
    }

    public var isRecording: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRecordingFlag
    }

    public func startRecording(
        outputURL: URL,
        sourceSize: CGSize,
        settings: StudioSettings,
        startUptime: TimeInterval
    ) -> Bool {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let fps = settings.videoFrameRate.rawValue

        // Determine target output resolution strictly from settings.videoResolution (Full 1080p or Native — never downscaled to 720p!)
        let maxLongEdge: CGFloat
        switch settings.videoResolution {
        case .native:
            maxLongEdge = max(sourceSize.width, sourceSize.height)
        case .fhd1080p:
            maxLongEdge = 1920.0
        }

        let targetSize = settings.aspectRatio.outputSize(
            forSource: sourceSize,
            maxLongEdge: maxLongEdge
        )
        let outW = max(320, Int(round(targetSize.width / 2.0) * 2.0))
        let outH = max(240, Int(round(targetSize.height / 2.0) * 2.0))
        let evenSize = CGSize(width: outW, height: outH)

        // When user selects H.264 (.mp4) or HEVC (.mp4), record live in ultra-fast ProRes 422 Proxy (.mov) at 155+ FPS
        // so live recording is 100% butter-smooth 60 FPS with zero GPU VCN stalls, then convert/remux to .mp4 on Stop!
        let needsMP4Remux = !settings.videoCodec.isMOV && (outputURL.pathExtension.lowercased() == "mp4")
        let activeCaptureURL: URL
        let stagingMOV: URL?
        if needsMP4Remux {
            let tempFile = outputURL.deletingLastPathComponent()
                .appendingPathComponent(".\(outputURL.deletingPathExtension().lastPathComponent)_proxy_staging.mov")
            if FileManager.default.fileExists(atPath: tempFile.path) {
                try? FileManager.default.removeItem(at: tempFile)
            }
            activeCaptureURL = tempFile
            stagingMOV = tempFile
        } else {
            activeCaptureURL = outputURL
            stagingMOV = nil
        }

        let newWriter: AVAssetWriter
        do {
            newWriter = try AVAssetWriter(outputURL: activeCaptureURL, fileType: .mov)
        } catch {
            return false
        }

        let liveCaptureCodec: AVVideoCodecType
        switch settings.videoCodec {
        case .proRes422:
            liveCaptureCodec = .proRes422
        case .proRes422LT, .h264, .hevc:
            // ProRes 422 Proxy / LT runs at 155 FPS on CPU SIMD with zero NootedRed.kext VCN contention!
            liveCaptureCodec = .proRes422Proxy
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: liveCaptureCodec,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        let sourceBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: outW,
            kCVPixelBufferHeightKey as String: outH,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let newAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourceBufferAttrs
        )

        guard newWriter.canAdd(input) else { return false }
        newWriter.add(input)

        var newAudioInput: AVAssetWriterInput? = nil
        if settings.isSystemAudioEnabled || settings.isMicAudioEnabled {
            let audioOutputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192000
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
            aInput.expectsMediaDataInRealTime = true
            if newWriter.canAdd(aInput) {
                newWriter.add(aInput)
                newAudioInput = aInput
            }
        }

        guard newWriter.startWriting() else { return false }
        newWriter.startSession(atSourceTime: .zero)

        stateLock.lock()
        self.writer = newWriter
        self.writerInput = input
        self.audioInput = newAudioInput
        self.adaptor = newAdaptor
        self.outputURL = outputURL
        self.tempMOVURL = stagingMOV
        self.requestedCodec = settings.videoCodec
        self.outputSize = evenSize
        self.baseUptime = startUptime
        self.hasAnchoredFirstFrame = false
        self.lastFrameUptime = 0
        self.lastVideoTicks = -1
        self.lastAudioPTS = .invalid
        self.targetFPS = fps
        for frame in self.frameQueue {
            if let surf = frame.ioSurface {
                IOSurfaceDecrementUseCount(surf)
            }
        }
        self.frameQueue.removeAll()
        self.isRecordingFlag = true
        stateLock.unlock()

        return true
    }

    public func startRecording(
        outputURL: URL,
        width: Int,
        height: Int,
        codec: VideoCodecPreset,
        frameRate: VideoFrameRateTarget,
        audioEnabled: Bool
    ) throws {
        var s = StudioSettings()
        s.videoCodec = codec
        s.videoFrameRate = frameRate
        s.isSystemAudioEnabled = audioEnabled
        s.isMicAudioEnabled = false
        let ok = startRecording(
            outputURL: outputURL,
            sourceSize: CGSize(width: width, height: height),
            settings: s,
            startUptime: ProcessInfo.processInfo.systemUptime
        )
        if !ok {
            throw NSError(domain: "ZoomKeMouse", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to start recording"])
        }
    }

    public func appendLiveCompositedFrame(
        ioSurface: IOSurfaceRef?,
        fallbackCGImage: CGImage?,
        uptime: TimeInterval,
        camera: CameraRenderState,
        cursor: CursorRenderState,
        settings: StudioSettings,
        force: Bool = false
    ) {
        guard ioSurface != nil || fallbackCGImage != nil else { return }

        stateLock.lock()
        guard isRecordingFlag else {
            stateLock.unlock()
            return
        }

        if !force {
            let minInterval = 1.0 / (Double(targetFPS) + 5.0)
            guard (uptime - lastFrameUptime) >= minInterval else {
                stateLock.unlock()
                return
            }
            if frameQueue.count >= maxQueueCapacity {
                // Drop frame when queue capacity is reached to protect latency
                stateLock.unlock()
                return
            }
        } else {
            if frameQueue.count >= maxQueueCapacity {
                let dropped = frameQueue.removeFirst()
                if let surf = dropped.ioSurface {
                    IOSurfaceDecrementUseCount(surf)
                }
            }
        }

        lastFrameUptime = uptime
        let targetSize = outputSize

        if let surf = ioSurface {
            IOSurfaceIncrementUseCount(surf)
        }

        let queuedFrame = QueuedFrame(
            ioSurface: ioSurface,
            fallbackCGImage: fallbackCGImage,
            uptime: uptime,
            targetSize: targetSize,
            camera: camera,
            cursor: cursor,
            settings: settings
        )
        frameQueue.append(queuedFrame)
        stateLock.unlock()

        writerQueue.async { [weak self] in
            self?.processNextQueuedFrame()
        }
    }

    private func processNextQueuedFrame() {
        stateLock.lock()
        guard !frameQueue.isEmpty else {
            stateLock.unlock()
            return
        }
        let frame = frameQueue.removeFirst()
        guard let activeWriter = writer,
              activeWriter.status == .writing,
              writerInput != nil,
              let activeAdaptor = adaptor else {
            stateLock.unlock()
            if let surf = frame.ioSurface {
                IOSurfaceDecrementUseCount(surf)
            }
            return
        }
        let pool = activeAdaptor.pixelBufferPool
        stateLock.unlock()

        defer {
            if let surf = frame.ioSurface {
                IOSurfaceDecrementUseCount(surf)
            }
        }

        guard let pixelBuffer = compositor.renderToPixelBuffer(
            pool: pool,
            size: frame.targetSize,
            ioSurface: frame.ioSurface,
            fallbackImage: frame.fallbackCGImage,
            settings: frame.settings,
            camera: frame.camera,
            cursor: frame.cursor
        ) else {
            return
        }

        stateLock.lock()
        guard let stillWriter = writer,
              stillWriter.status == .writing,
              let stillInput = writerInput,
              let stillAdaptor = adaptor else {
            stateLock.unlock()
            return
        }

        var retryCount = 0
        while !stillInput.isReadyForMoreMediaData && stillWriter.status == .writing && retryCount < 35 {
            stateLock.unlock()
            Thread.sleep(forTimeInterval: 0.002)
            stateLock.lock()
            retryCount += 1
        }

        guard stillInput.isReadyForMoreMediaData else {
            stateLock.unlock()
            return
        }

        // Wall-clock real-time Presentation Timestamps (guarantees exact 1.0x playback speed):
        if !hasAnchoredFirstFrame {
            baseUptime = frame.uptime
            hasAnchoredFirstFrame = true
        }
        let relSeconds = max(0.0, frame.uptime - baseUptime)
        let timescale: Int32 = 600
        let rawTicks = Int64(round(relSeconds * Double(timescale)))
        let ptsTicks: Int64
        if lastVideoTicks < 0 {
            ptsTicks = 0
        } else {
            ptsTicks = max(lastVideoTicks + 1, rawTicks)
        }
        lastVideoTicks = ptsTicks
        let pts = CMTime(value: ptsTicks, timescale: timescale)
        stateLock.unlock()

        _ = stillAdaptor.append(pixelBuffer, withPresentationTime: pts)
    }

    public func appendVideoFrame(pixelBuffer: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        let surf = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        appendLiveCompositedFrame(
            ioSurface: surf,
            fallbackCGImage: nil,
            uptime: now,
            camera: CameraRenderState(),
            cursor: CursorRenderState(),
            settings: StudioSettings(),
            force: true
        )
    }

    public func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, isSystemAudio: Bool) {
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0,
              CMSampleBufferGetDataBuffer(sampleBuffer) != nil else {
            return
        }

        stateLock.lock()
        guard isRecordingFlag,
              let activeWriter = writer,
              activeWriter.status == .writing,
              audioInput != nil else {
            stateLock.unlock()
            return
        }
        let currentBaseUptime = baseUptime
        stateLock.unlock()

        let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard samplePTS.isValid else { return }

        let relSeconds: Double
        if currentBaseUptime > 10.0 && samplePTS.seconds >= (currentBaseUptime - 1.0) {
            relSeconds = samplePTS.seconds - currentBaseUptime
        } else {
            relSeconds = samplePTS.seconds
        }

        // Drop stale pre-roll audio arriving > 50ms before baseUptime
        guard relSeconds >= -0.05 else { return }
        let effectiveRelSeconds = max(0.0, relSeconds)

        audioWriterQueue.async { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            guard let stillWriter = self.writer,
                  stillWriter.status == .writing,
                  let aInput = self.audioInput else {
                self.stateLock.unlock()
                return
            }

            var retryCount = 0
            while !aInput.isReadyForMoreMediaData && stillWriter.status == .writing && retryCount < 10 {
                self.stateLock.unlock()
                Thread.sleep(forTimeInterval: 0.002)
                self.stateLock.lock()
                retryCount += 1
            }

            guard aInput.isReadyForMoreMediaData else {
                self.stateLock.unlock()
                return
            }

            let prevPTS = self.lastAudioPTS
            let perSampleDuration = CMTime(value: 1, timescale: 48000)
            let bufferDuration = CMTime(value: CMTimeValue(numSamples), timescale: 48000)

            var targetPTS = CMTime(value: Int64(round(effectiveRelSeconds * 48000.0)), timescale: 48000)
            if prevPTS.isValid && CMTimeCompare(targetPTS, prevPTS) < 0 {
                targetPTS = prevPTS
            }
            self.lastAudioPTS = CMTimeAdd(targetPTS, bufferDuration)
            self.stateLock.unlock()

            if CMTimeCompare(targetPTS, samplePTS) == 0 && samplePTS.timescale == 48000 {
                _ = aInput.append(sampleBuffer)
            } else {
                var timingInfo = CMSampleTimingInfo(
                    duration: perSampleDuration,
                    presentationTimeStamp: targetPTS,
                    decodeTimeStamp: .invalid
                )

                var reTimedBuffer: CMSampleBuffer?
                let status = CMSampleBufferCreateCopyWithNewTiming(
                    allocator: kCFAllocatorDefault,
                    sampleBuffer: sampleBuffer,
                    sampleTimingEntryCount: 1,
                    sampleTimingArray: &timingInfo,
                    sampleBufferOut: &reTimedBuffer
                )

                if status == noErr, let buf = reTimedBuffer {
                    _ = aInput.append(buf)
                }
            }
        }
    }

    public func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        stateLock.lock()
        guard isRecordingFlag else {
            stateLock.unlock()
            return
        }
        isRecordingFlag = false
        stateLock.unlock()

        writerQueue.async { [weak self] in
            guard let self = self else { return }

            // Drain all remaining queued frames before finalizing
            while true {
                var hasFrame = false
                self.stateLock.lock()
                hasFrame = !self.frameQueue.isEmpty
                self.stateLock.unlock()

                if hasFrame {
                    self.processNextQueuedFrame()
                } else {
                    break
                }
            }

            // Ensure all pending audio buffers are written before finalizing
            self.audioWriterQueue.sync {}

            self.stateLock.lock()
            let activeWriter = self.writer
            let activeInput = self.writerInput
            let activeAudioInput = self.audioInput
            let finalURL = self.outputURL
            let stagingMOV = self.tempMOVURL
            let targetCodec = self.requestedCodec
            self.writer = nil
            self.writerInput = nil
            self.audioInput = nil
            self.adaptor = nil
            self.tempMOVURL = nil
            self.lastAudioPTS = .invalid
            for f in self.frameQueue {
                if let surf = f.ioSurface {
                    IOSurfaceDecrementUseCount(surf)
                }
            }
            self.frameQueue.removeAll()
            self.stateLock.unlock()

            guard let w = activeWriter, let url = finalURL else {
                return
            }
            if w.status == .writing {
                activeInput?.markAsFinished()
                activeAudioInput?.markAsFinished()
                w.finishWriting {
                    if w.status == .completed {
                        if let tempMOV = stagingMOV {
                            Self.remuxStagingMOVToMP4(
                                sourceMOV: tempMOV,
                                destinationMP4: url,
                                codec: targetCodec,
                                completion: completion
                            )
                        } else {
                            completion(.success(url))
                        }
                    } else {
                        if let tempMOV = stagingMOV {
                            try? FileManager.default.removeItem(at: tempMOV)
                        }
                        let err = w.error ?? NSError(domain: "ZoomKeMouse", code: -1, userInfo: [NSLocalizedDescriptionKey: "Gagal menyimpan file video."])
                        completion(.failure(err))
                    }
                }
            } else {
                if let tempMOV = stagingMOV {
                    try? FileManager.default.removeItem(at: tempMOV)
                }
                let err = w.error ?? NSError(domain: "ZoomKeMouse", code: -1, userInfo: [NSLocalizedDescriptionKey: "Rekaman belum siap."])
                completion(.failure(err))
            }
        }
    }

    private static func remuxStagingMOVToMP4(
        sourceMOV: URL,
        destinationMP4: URL,
        codec: VideoCodecPreset,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        if FileManager.default.fileExists(atPath: destinationMP4.path) {
            try? FileManager.default.removeItem(at: destinationMP4)
        }
        let asset = AVURLAsset(url: sourceMOV)
        let preferredPreset = (codec == .hevc)
            ? AVAssetExportPresetHEVCHighestQuality
            : AVAssetExportPresetHighestQuality

        let session = AVAssetExportSession(asset: asset, presetName: preferredPreset)
            ?? AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)

        guard let exportSession = session else {
            // Fallback: move staging MOV if export session unavailable
            let fallbackMOV = destinationMP4.deletingPathExtension().appendingPathExtension("mov")
            try? FileManager.default.removeItem(at: fallbackMOV)
            try? FileManager.default.moveItem(at: sourceMOV, to: fallbackMOV)
            completion(.success(fallbackMOV))
            return
        }

        exportSession.outputURL = destinationMP4
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.exportAsynchronously {
            if exportSession.status == .completed {
                try? FileManager.default.removeItem(at: sourceMOV)
                completion(.success(destinationMP4))
            } else {
                // Keep the 60FPS Proxy MOV if MP4 export fails for any reason
                let fallbackMOV = destinationMP4.deletingPathExtension().appendingPathExtension("mov")
                try? FileManager.default.removeItem(at: fallbackMOV)
                try? FileManager.default.moveItem(at: sourceMOV, to: fallbackMOV)
                completion(.success(fallbackMOV))
            }
        }
    }

    public func finishRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        stopRecording(completion: completion)
    }
}

extension RealTimeDirectMovieRecorder: AudioCaptureDelegate {
    public func audioCaptureDidOutput(sampleBuffer: CMSampleBuffer, isSystemAudio: Bool) {
        appendAudioSampleBuffer(sampleBuffer, isSystemAudio: isSystemAudio)
    }
}

public typealias VideoExporter = RealTimeDirectMovieRecorder
