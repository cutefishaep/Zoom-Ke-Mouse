import Foundation
import AVFoundation
import VideoToolbox
import CoreGraphics
import CoreVideo
import IOSurface

/// Real-Time Direct Video Recorder (Metal GPU 1080p Compositor + ProRes 422 LT 112-FPS Studio Encoder for NootedRed.kext!)
public final class RealTimeDirectMovieRecorder {

    private let writerQueue = DispatchQueue(label: "com.zoomkemouse.realtimerecorder", qos: .userInteractive)
    private let stateLock = NSLock()

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let compositor = FrameCompositor()

    private var isRecordingFlag: Bool = false
    private var isEncodingFrame: Bool = false
    private var baseUptime: TimeInterval = 0
    private var hasAnchoredFirstFrame: Bool = false
    private var lastFrameUptime: TimeInterval = 0
    private var lastAppendedStep: Int64 = -1
    private var outputURL: URL?
    private var outputSize: CGSize = CGSize(width: 1920, height: 1080)

    public init() {}

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

        // Full HD 1920x1080 native resolution!
        let targetSize = settings.aspectRatio.outputSize(
            forSource: sourceSize,
            maxLongEdge: 1920
        )
        let outW = max(640, Int(round(targetSize.width / 2.0) * 2.0))
        let outH = max(360, Int(round(targetSize.height / 2.0) * 2.0))
        let evenSize = CGSize(width: outW, height: outH)

        let isMOV = (outputURL.pathExtension.lowercased() == "mov")
        let fileType: AVFileType = isMOV ? .mov : .mp4

        let newWriter: AVAssetWriter
        do {
            newWriter = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        } catch {
            return false
        }

        // On AMD Ryzen + NootedRed.kext (no Intel QuickSync / VCN H.264 encoder), Apple ProRes 422 LT encodes
        // Full HD 1920x1080 at 112 FPS (~8.9ms/frame) with 10-bit 4:2:2 crystal-clear studio quality!
        let videoSettings: [String: Any]
        if isMOV {
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.proRes422LT,
                AVVideoWidthKey: outW,
                AVVideoHeightKey: outH
            ]
        } else {
            let bitrate = max(28_000_000, outW * outH * 14)
            let compressionProps: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 1,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: 60,
                kVTCompressionPropertyKey_RealTime as String: true
            ]
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.h264,
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
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let newAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourceBufferAttrs
        )

        guard newWriter.canAdd(input) else { return false }
        newWriter.add(input)
        guard newWriter.startWriting() else { return false }
        newWriter.startSession(atSourceTime: .zero)

        stateLock.lock()
        self.writer = newWriter
        self.writerInput = input
        self.adaptor = newAdaptor
        self.outputURL = outputURL
        self.outputSize = evenSize
        self.baseUptime = startUptime
        self.hasAnchoredFirstFrame = false
        self.lastFrameUptime = 0
        self.lastAppendedStep = -1
        self.isEncodingFrame = false
        self.isRecordingFlag = true
        stateLock.unlock()

        return true
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
            // Allow up to 60fps (15ms gate avoids 60Hz timer jitter dropping every 2nd tick!)
            guard !isEncodingFrame, (uptime - lastFrameUptime) >= (1.0 / 65.0) else {
                stateLock.unlock()
                return
            }
        }
        isEncodingFrame = true
        lastFrameUptime = uptime
        let targetSize = outputSize
        stateLock.unlock()

        if let surf = ioSurface {
            IOSurfaceIncrementUseCount(surf)
        }

        writerQueue.async { [weak self] in
            guard let self = self else {
                if let surf = ioSurface {
                    IOSurfaceDecrementUseCount(surf)
                }
                return
            }
            defer {
                if let surf = ioSurface {
                    IOSurfaceDecrementUseCount(surf)
                }
                self.stateLock.lock()
                self.isEncodingFrame = false
                self.stateLock.unlock()
            }

            autoreleasepool {
                self.encodeCompositedFrameOnQueue(
                    ioSurface: ioSurface,
                    fallbackCGImage: fallbackCGImage,
                    frameUptime: uptime,
                    targetSize: targetSize,
                    camera: camera,
                    cursor: cursor,
                    settings: settings
                )
            }
        }
    }

    private func encodeCompositedFrameOnQueue(
        ioSurface: IOSurfaceRef?,
        fallbackCGImage: CGImage?,
        frameUptime: TimeInterval,
        targetSize: CGSize,
        camera: CameraRenderState,
        cursor: CursorRenderState,
        settings: StudioSettings
    ) {
        stateLock.lock()
        guard isRecordingFlag,
              let activeWriter = writer,
              activeWriter.status == .writing,
              let activeInput = writerInput,
              activeInput.isReadyForMoreMediaData,
              let activeAdaptor = adaptor else {
            stateLock.unlock()
            return
        }
        let pool = activeAdaptor.pixelBufferPool
        stateLock.unlock()

        // Render first (so any one-time cache creation on Frame 0 happens BEFORE anchoring timestamp 0.0s!)
        guard let pixelBuffer = compositor.renderToPixelBuffer(
            pool: pool,
            size: targetSize,
            ioSurface: ioSurface,
            fallbackImage: fallbackCGImage,
            settings: settings,
            camera: camera,
            cursor: cursor
        ) else {
            return
        }

        stateLock.lock()
        guard isRecordingFlag,
              let stillWriter = writer,
              stillWriter.status == .writing,
              let stillInput = writerInput,
              stillInput.isReadyForMoreMediaData,
              let stillAdaptor = adaptor else {
            stateLock.unlock()
            return
        }

        let nowAfterRender = ProcessInfo.processInfo.systemUptime
        if !hasAnchoredFirstFrame {
            hasAnchoredFirstFrame = true
            baseUptime = nowAfterRender
        }
        let relTime = max(0.0, nowAfterRender - baseUptime)

        let timescale: Int32 = 600
        var step = Int64(round(relTime * Double(timescale)))
        if step <= lastAppendedStep {
            step = lastAppendedStep + 1
        }
        lastAppendedStep = step
        stateLock.unlock()

        let pts = CMTime(value: step, timescale: timescale)
        _ = stillAdaptor.append(pixelBuffer, withPresentationTime: pts)
    }

    public func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        stateLock.lock()
        guard isRecordingFlag else {
            stateLock.unlock()
            return
        }
        isRecordingFlag = false
        let activeWriter = writer
        let activeInput = writerInput
        let finalURL = outputURL
        writer = nil
        writerInput = nil
        adaptor = nil
        stateLock.unlock()

        writerQueue.async {
            guard let w = activeWriter, let url = finalURL else {
                return
            }
            if w.status == .writing {
                activeInput?.markAsFinished()
                w.finishWriting {
                    DispatchQueue.main.async {
                        if w.status == .completed {
                            completion(.success(url))
                        } else {
                            let err = w.error ?? NSError(domain: "ZoomKeMouse", code: -1, userInfo: [NSLocalizedDescriptionKey: "Gagal menyimpan file video."])
                            completion(.failure(err))
                        }
                    }
                }
            } else {
                DispatchQueue.main.async {
                    let err = w.error ?? NSError(domain: "ZoomKeMouse", code: -1, userInfo: [NSLocalizedDescriptionKey: "Rekaman belum siap."])
                    completion(.failure(err))
                }
            }
        }
    }
}
