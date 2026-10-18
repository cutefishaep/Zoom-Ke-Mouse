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
        let targetSize: CGSize
        let camera: CameraRenderState
        let cursor: CursorRenderState
        let settings: StudioSettings
    }

    private var frameQueue: [QueuedFrame] = []
    private let maxQueueCapacity: Int = 4

    private var isRecordingFlag: Bool = false
    private var baseUptime: TimeInterval = 0
    private var hasAnchoredFirstFrame: Bool = false
    private var lastFrameUptime: TimeInterval = 0
    private var recordedFrameIndex: Int64 = 0
    private var targetFPS: Int = 60
    private var lastAudioPTS: CMTime = .invalid
    private var outputURL: URL?
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

        // Determine target output resolution based on settings.videoResolution
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

        let isMOV = settings.videoCodec.isMOV || (outputURL.pathExtension.lowercased() == "mov")
        let fileType: AVFileType = isMOV ? .mov : .mp4

        let newWriter: AVAssetWriter
        do {
            newWriter = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        } catch {
            return false
        }

        let fps = settings.videoFrameRate.rawValue
        let videoSettings: [String: Any]
        switch settings.videoCodec {
        case .proRes422:
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.proRes422,
                AVVideoWidthKey: outW,
                AVVideoHeightKey: outH
            ]
        case .proRes422LT:
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.proRes422LT,
                AVVideoWidthKey: outW,
                AVVideoHeightKey: outH
            ]
        case .h264:
            let bitrate = (fps == 60)
                ? max(20_000_000, outW * outH * 10)
                : max(12_000_000, outW * outH * 6)
            let compressionProps: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: fps,
                kVTCompressionPropertyKey_RealTime as String: true
            ]
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outW,
                AVVideoHeightKey: outH,
                AVVideoCompressionPropertiesKey: compressionProps
            ]
        case .hevc:
            let bitrate = max(10_000_000, outW * outH * 5)
            let compressionProps: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: fps,
                kVTCompressionPropertyKey_RealTime as String: true
            ]
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: outW,
                AVVideoHeightKey: outH,
                AVVideoCompressionPropertiesKey: compressionProps
            ]
        }

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
        self.outputSize = evenSize
        self.baseUptime = startUptime
        self.hasAnchoredFirstFrame = true
        self.lastFrameUptime = 0
        self.lastAudioPTS = .invalid
        self.recordedFrameIndex = 0
        self.targetFPS = settings.videoFrameRate.rawValue
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
        let fps = targetFPS
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
        while !stillInput.isReadyForMoreMediaData && stillWriter.status == .writing && retryCount < 10 {
            stateLock.unlock()
            Thread.sleep(forTimeInterval: 0.002)
            stateLock.lock()
            retryCount += 1
        }

        guard stillInput.isReadyForMoreMediaData else {
            stateLock.unlock()
            return
        }

        // Monotonic Equidistant Presentation Timestamps:
        let timescale: Int32 = 600
        let stepDelta: Int64 = Int64(600 / max(1, fps))
        let pts = CMTime(value: recordedFrameIndex * stepDelta, timescale: timescale)
        recordedFrameIndex += 1
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
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              CMSampleBufferGetDataBuffer(sampleBuffer) != nil else {
            return
        }

        stateLock.lock()
        guard isRecordingFlag,
              let activeWriter = writer,
              activeWriter.status == .writing,
              let activeAudioInput = audioInput,
              activeAudioInput.isReadyForMoreMediaData else {
            stateLock.unlock()
            return
        }
        let currentBaseUptime = baseUptime
        stateLock.unlock()

        let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard samplePTS.isValid else { return }
        let sampleSeconds = samplePTS.seconds
        let relSeconds = sampleSeconds - currentBaseUptime

        // Drop stale pre-roll audio arriving > 50ms before baseUptime
        guard relSeconds >= -0.05 else { return }
        let effectiveRelSeconds = max(0.0, relSeconds)

        audioWriterQueue.async { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            guard let aInput = self.audioInput,
                  aInput.isReadyForMoreMediaData else {
                self.stateLock.unlock()
                return
            }

            let prevPTS = self.lastAudioPTS
            let bufferDuration = CMSampleBufferGetDuration(sampleBuffer)
            let step = (bufferDuration.isValid && bufferDuration > .zero)
                ? bufferDuration
                : CMTime(value: 960, timescale: 48000)

            var targetPTS = CMTime(seconds: effectiveRelSeconds, preferredTimescale: 48000)
            if prevPTS.isValid && CMTimeCompare(targetPTS, prevPTS) <= 0 {
                targetPTS = CMTimeAdd(prevPTS, step)
            }
            self.lastAudioPTS = targetPTS
            self.stateLock.unlock()

            var timingInfo = CMSampleTimingInfo(
                duration: step,
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
            self.writer = nil
            self.writerInput = nil
            self.audioInput = nil
            self.adaptor = nil
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
                        completion(.success(url))
                    } else {
                        let err = w.error ?? NSError(domain: "ZoomKeMouse", code: -1, userInfo: [NSLocalizedDescriptionKey: "Gagal menyimpan file video."])
                        completion(.failure(err))
                    }
                }
            } else {
                let err = w.error ?? NSError(domain: "ZoomKeMouse", code: -1, userInfo: [NSLocalizedDescriptionKey: "Rekaman belum siap."])
                completion(.failure(err))
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
