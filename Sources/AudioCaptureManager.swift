import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreAudio
import Accelerate

// MARK: - Audio Capture Delegate Protocol

public protocol AudioCaptureDelegate: AnyObject {
    func audioCaptureDidOutput(sampleBuffer: CMSampleBuffer, isSystemAudio: Bool)
}

// MARK: - Dedicated System Audio SCStream Output Handler (macOS Ventura 13+)

private final class SystemAudioStreamOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate {
    private weak var manager: AudioCaptureManager?

    init(manager: AudioCaptureManager) {
        self.manager = manager
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        manager?.handleSystemAudioSampleBuffer(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        manager?.handleSystemAudioStreamStopped()
    }
}

// MARK: - Audio Capture Manager

public final class AudioCaptureManager: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    public static let shared = AudioCaptureManager()

    public weak var delegate: AudioCaptureDelegate?

    private let stateLock = NSLock()
    private var isCapturing: Bool = false
    private var isSystemAudioEnabled: Bool = true
    private var systemAudioVolume: Float = 1.0
    private var isMicAudioEnabled: Bool = false
    private var micDeviceUID: String? = nil
    private var micAudioVolume: Float = 1.0
    private var captureStartUptime: TimeInterval = 0

    // Dedicated ScreenCaptureKit System Audio Stream (works in FullScreen, Windowed, and CGDisplayStream modes)
    private var systemAudioStream: SCStream?
    private var systemAudioHandler: SystemAudioStreamOutputHandler?
    private var isStartingSystemAudioStream: Bool = false
    private var lastSystemAudioRetryUptime: TimeInterval = 0
    private let systemAudioQueue = DispatchQueue(label: "com.cutefishaep.zoomkmouse.sysaudio", qos: .userInteractive)

    // Microphone AVCaptureSession
    private var captureSession: AVCaptureSession?
    private var activeMicDeviceUID: String? = nil
    private var audioOutput: AVCaptureAudioDataOutput?
    private var latestMicPeakLevel: Float = 0.0
    private let micQueue = DispatchQueue(label: "com.cutefishaep.zoomkmouse.micqueue", qos: .userInteractive)

    // Real-time 48kHz Stereo Processing & Heartbeat Queue
    private let audioProcessingQueue = DispatchQueue(label: "com.cutefishaep.zoomkmouse.audioprocess", qos: .userInteractive)
    private var heartbeatTimer: DispatchSourceTimer?

    private let mixer = RealTimeAudioMixer()
    private var pcmFormatDescription: CMAudioFormatDescription?

    public override init() {
        super.init()
    }

    // MARK: - Audio Device Discovery

    public func availableMicrophoneDevices() -> [AudioDeviceInfo] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )
        // Sort so built-in/analog microphones appear before unplugged Pink/Line jacks on VoodooHDA
        let sorted = discovery.devices.sorted { a, b in
            let scoreA = Self.preferredMicScore(for: a)
            let scoreB = Self.preferredMicScore(for: b)
            return scoreA > scoreB
        }
        return sorted.map { device in
            AudioDeviceInfo(
                id: device.uniqueID,
                name: device.localizedName,
                channels: 2
            )
        }
    }

    private static func preferredMicScore(for device: AVCaptureDevice) -> Int {
        let lower = device.localizedName.lowercased()
        let uidLower = device.uniqueID.lowercased()
        var score = 0
        if lower.contains("analog") || lower.contains("internal") || lower.contains("built-in") || lower.contains("macbook") {
            score += 50
        }
        if uidLower.hasSuffix(":3") || uidLower.hasSuffix(":2") {
            score += 20
        }
        if lower.contains("pink") || lower.contains("rear") || lower.contains("line in") {
            score -= 40
        }
        return score
    }

    public func currentMicInputLevel() -> Float {
        stateLock.lock()
        defer { stateLock.unlock() }
        // Decay slightly when read so meter drops smoothly if silent
        let val = latestMicPeakLevel
        latestMicPeakLevel *= 0.82
        return min(1.0, val)
    }

    // MARK: - Dedicated System Audio SCStream Management (macOS Ventura 13.7.8+)

    public func ensureSystemAudioStreamRunning() {
        stateLock.lock()
        if systemAudioStream != nil || isStartingSystemAudioStream {
            stateLock.unlock()
            return
        }
        isStartingSystemAudioStream = true
        lastSystemAudioRetryUptime = ProcessInfo.processInfo.systemUptime
        stateLock.unlock()

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self = self else { return }
            guard let content = content, error == nil,
                  let display = content.displays.first else {
                self.stateLock.lock()
                self.isStartingSystemAudioStream = false
                self.stateLock.unlock()
                return
            }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
            // Minimal dummy screen config; we do NOT add a .screen output so WindowServer never wastes GPU/CPU capturing frames for audio!
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 10, timescale: 1)
            config.queueDepth = 1
            config.showsCursor = false

            let handler = SystemAudioStreamOutputHandler(manager: self)
            let stream = SCStream(filter: filter, configuration: config, delegate: handler)

            do {
                try stream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: self.systemAudioQueue)
                stream.startCapture { [weak self] startErr in
                    guard let self = self else { return }
                    self.stateLock.lock()
                    self.isStartingSystemAudioStream = false
                    if startErr != nil {
                        self.systemAudioStream = nil
                        self.systemAudioHandler = nil
                    }
                    self.stateLock.unlock()
                }
                self.stateLock.lock()
                self.systemAudioStream = stream
                self.systemAudioHandler = handler
                self.stateLock.unlock()
            } catch {
                self.stateLock.lock()
                self.isStartingSystemAudioStream = false
                self.systemAudioStream = nil
                self.systemAudioHandler = nil
                self.stateLock.unlock()
            }
        }
    }

    fileprivate func handleSystemAudioStreamStopped() {
        stateLock.lock()
        systemAudioStream = nil
        systemAudioHandler = nil
        isStartingSystemAudioStream = false
        let shouldRestart = isCapturing && isSystemAudioEnabled
        stateLock.unlock()

        if shouldRestart {
            ensureSystemAudioStreamRunning()
        }
    }

    public func stopSystemAudioStream() {
        stateLock.lock()
        let stream = systemAudioStream
        systemAudioStream = nil
        systemAudioHandler = nil
        isStartingSystemAudioStream = false
        stateLock.unlock()

        stream?.stopCapture(completionHandler: nil)
    }

    // MARK: - Lifecycle Controls

    public func ensureMicrophonePreviewRunning(deviceUID: String?, micVolume: Float) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        stateLock.lock()
        self.micAudioVolume = max(0.0, micVolume)
        self.micDeviceUID = deviceUID
        stateLock.unlock()
        try? setupAndStartMicrophoneSession(deviceUID: deviceUID)
    }

    public func stopMicrophonePreviewIfIdle() {
        stateLock.lock()
        guard !isCapturing else {
            stateLock.unlock()
            return
        }
        let session = captureSession
        captureSession = nil
        audioOutput = nil
        activeMicDeviceUID = nil
        latestMicPeakLevel = 0.0
        stateLock.unlock()

        if let s = session, s.isRunning {
            micQueue.async {
                s.stopRunning()
            }
        }
    }

    public func startCapture(
        systemAudioEnabled: Bool,
        systemAudioVolume: Float,
        micAudioEnabled: Bool,
        micDeviceUID: String?,
        micVolume: Float
    ) throws {
        let now = ProcessInfo.processInfo.systemUptime

        stateLock.lock()
        self.isSystemAudioEnabled = systemAudioEnabled
        self.systemAudioVolume = max(0.0, systemAudioVolume)
        self.isMicAudioEnabled = micAudioEnabled
        self.micDeviceUID = micDeviceUID
        self.micAudioVolume = max(0.0, micVolume)
        self.captureStartUptime = now
        self.isCapturing = true
        self.mixer.reset()
        stateLock.unlock()

        if systemAudioEnabled {
            ensureSystemAudioStreamRunning()
        }

        if micAudioEnabled {
            try? setupAndStartMicrophoneSession(deviceUID: micDeviceUID)
        }

        if systemAudioEnabled || micAudioEnabled {
            startHeartbeatTimer()
        }
    }

    public func stopCapture() {
        stateLock.lock()
        guard isCapturing else {
            stateLock.unlock()
            return
        }
        isCapturing = false
        let stopUptime = ProcessInfo.processInfo.systemUptime
        let startUptime = captureStartUptime
        let hadAudioEnabled = isSystemAudioEnabled || isMicAudioEnabled
        stateLock.unlock()

        stopHeartbeatTimer()

        if hadAudioEnabled {
            let finalWallFrame = max(0, Int64(round((stopUptime - startUptime) * 48000.0)))
            drainRemainingMixedAudio(upToFrame: finalWallFrame)
        }
    }

    public func updateVolumes(systemAudioVolume: Float, micVolume: Float) {
        stateLock.lock()
        self.systemAudioVolume = max(0.0, systemAudioVolume)
        self.micAudioVolume = max(0.0, micVolume)
        stateLock.unlock()
    }

    private func startHeartbeatTimer() {
        stopHeartbeatTimer()
        let timer = DispatchSource.makeTimerSource(queue: audioProcessingQueue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.flushReadyAudioChunks()
        }
        timer.resume()
        stateLock.lock()
        heartbeatTimer = timer
        stateLock.unlock()
    }

    private func stopHeartbeatTimer() {
        stateLock.lock()
        let timer = heartbeatTimer
        heartbeatTimer = nil
        stateLock.unlock()
        timer?.cancel()
    }

    // MARK: - Microphone Session Setup

    private func resolvePreferredMicDevice(deviceUID: String?) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )
        let devices = discovery.devices
        if let uid = deviceUID, !uid.isEmpty,
           let matched = devices.first(where: { $0.uniqueID == uid }) {
            return matched
        }
        // Smart auto-selection for VoodooHDA: prefer "Microphone (Analog)" / built-in over unplugged "Pink Right" jack
        let sorted = devices.sorted { Self.preferredMicScore(for: $0) > Self.preferredMicScore(for: $1) }
        return sorted.first ?? AVCaptureDevice.default(for: .audio)
    }

    private func setupAndStartMicrophoneSession(deviceUID: String?) throws {
        guard let device = resolvePreferredMicDevice(deviceUID: deviceUID) else {
            return
        }

        stateLock.lock()
        if let existing = captureSession, existing.isRunning, activeMicDeviceUID == device.uniqueID {
            stateLock.unlock()
            return
        }
        let oldSession = captureSession
        captureSession = nil
        audioOutput = nil
        activeMicDeviceUID = nil
        stateLock.unlock()

        if let old = oldSession, old.isRunning {
            micQueue.async {
                old.stopRunning()
            }
        }

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        output.setSampleBufferDelegate(self, queue: micQueue)

        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        stateLock.lock()
        self.captureSession = session
        self.audioOutput = output
        self.activeMicDeviceUID = device.uniqueID
        stateLock.unlock()

        micQueue.async {
            session.startRunning()
        }
    }

    // MARK: - Ingestion Handlers

    /// Ingestion entry point for ScreenCaptureKit system audio (`SCStreamOutputType.audio`)
    public func handleSystemAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let arrivalUptime = ProcessInfo.processInfo.systemUptime
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              CMSampleBufferGetDataBuffer(sampleBuffer) != nil else {
            return
        }

        stateLock.lock()
        guard isCapturing, isSystemAudioEnabled else {
            stateLock.unlock()
            return
        }
        let vol = systemAudioVolume
        let startUptime = captureStartUptime
        stateLock.unlock()

        guard let extracted = extractStereoFloatSamples(from: sampleBuffer) else { return }
        let frameCount = extracted.left.count
        guard frameCount > 0 else { return }

        let bufferStartUptime = arrivalUptime - (Double(frameCount) / 48000.0)
        let elapsedFrame = max(0, Int64(round((bufferStartUptime - startUptime) * 48000.0)))

        audioProcessingQueue.async { [weak self] in
            guard let self = self else { return }
            self.mixer.appendSystemSamples(
                left: extracted.left,
                right: extracted.right,
                elapsedFrame: elapsedFrame,
                gain: vol
            )
            self.flushReadyAudioChunks()
        }
    }

    /// Ingestion delegate for AVCaptureAudioDataOutput microphone stream
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let arrivalUptime = ProcessInfo.processInfo.systemUptime
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              CMSampleBufferGetDataBuffer(sampleBuffer) != nil else {
            return
        }

        guard let extracted = extractStereoFloatSamples(from: sampleBuffer) else { return }
        let frameCount = extracted.left.count
        guard frameCount > 0 else { return }

        // Compute peak for live microphone UI meter (incorporating VoodooHDA 4.0x pre-amp boost)
        var peak: Float = 0.0
        let strideStep = max(1, frameCount / 64)
        var idx = 0
        while idx < frameCount {
            let a = max(abs(extracted.left[idx]), abs(extracted.right[idx]))
            if a > peak { peak = a }
            idx += strideStep
        }

        stateLock.lock()
        let vol = micAudioVolume
        let boostedPeak = min(1.0, peak * 4.5 * max(0.2, vol))
        if boostedPeak > latestMicPeakLevel {
            latestMicPeakLevel = boostedPeak
        } else {
            latestMicPeakLevel = latestMicPeakLevel * 0.75 + boostedPeak * 0.25
        }
        guard isCapturing, isMicAudioEnabled else {
            stateLock.unlock()
            return
        }
        let startUptime = captureStartUptime
        stateLock.unlock()

        let bufferStartUptime = arrivalUptime - (Double(frameCount) / 48000.0)
        let elapsedFrame = max(0, Int64(round((bufferStartUptime - startUptime) * 48000.0)))

        audioProcessingQueue.async { [weak self] in
            guard let self = self else { return }
            self.mixer.appendMicSamples(
                left: extracted.left,
                right: extracted.right,
                elapsedFrame: elapsedFrame,
                gain: vol
            )
            self.flushReadyAudioChunks()
        }
    }

    // MARK: - Flushing & Sample Extraction

    private func flushReadyAudioChunks() {
        let now = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        guard isCapturing else {
            stateLock.unlock()
            return
        }
        let startUptime = captureStartUptime
        let shouldRetrySysAudio = isSystemAudioEnabled && systemAudioStream == nil && !isStartingSystemAudioStream && (now - lastSystemAudioRetryUptime) >= 1.5
        stateLock.unlock()

        if shouldRetrySysAudio {
            ensureSystemAudioStreamRunning()
        }

        let currentWallFrame = max(0, Int64(round((now - startUptime) * 48000.0)))

        // 4800 frames = 100ms lookahead buffer so both SCStream and Mic callbacks write before readHead consumes
        let readyChunks = mixer.pollChunks(currentWallFrame: currentWallFrame, chunkSize: 960, lookaheadFrames: 4800)
        for chunk in readyChunks {
            if let sb = createSampleBuffer(left: chunk.left, right: chunk.right, ptsFrame: chunk.ptsFrame) {
                delegate?.audioCaptureDidOutput(sampleBuffer: sb, isSystemAudio: true)
            }
        }
    }

    private func drainRemainingMixedAudio(upToFrame finalWallFrame: Int64) {
        audioProcessingQueue.sync { [weak self] in
            guard let self = self else { return }
            let remainingChunks = self.mixer.drainRemaining(upToFrame: finalWallFrame, chunkSize: 960)
            for chunk in remainingChunks {
                if let sb = self.createSampleBuffer(left: chunk.left, right: chunk.right, ptsFrame: chunk.ptsFrame) {
                    self.delegate?.audioCaptureDidOutput(sampleBuffer: sb, isSystemAudio: true)
                }
            }
        }
    }

    /// Extracts stereo 48kHz Float32 samples from any planar (SCStream on macOS Ventura) or interleaved CMSampleBuffer
    private func extractStereoFloatSamples(from sampleBuffer: CMSampleBuffer) -> (left: [Float], right: [Float])? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else {
            return nil
        }
        let asbd = asbdPtr.pointee
        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numFrames > 0 else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let bits = Int(asbd.mBitsPerChannel)

        var left = [Float](repeating: 0, count: numFrames)
        var right = [Float](repeating: 0, count: numFrames)
        var didExtract = false

        // 1. Direct CMBlockBufferCopyDataBytes path (100% immune to multi-block non-contiguous CMBlockBuffers in SCStream on macOS Ventura)
        if let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            let totalBytes = CMBlockBufferGetDataLength(dataBuffer)
            if isFloat && bits == 32 && totalBytes >= numFrames * MemoryLayout<Float>.size {
                let floatCount = totalBytes / MemoryLayout<Float>.size
                var rawFloats = [Float](repeating: 0, count: floatCount)
                let copyStatus = rawFloats.withUnsafeMutableBytes { rawBuf -> OSStatus in
                    guard let base = rawBuf.baseAddress else { return -1 }
                    return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: floatCount * MemoryLayout<Float>.size, destination: base)
                }
                if copyStatus == kCMBlockBufferNoErr {
                    if isNonInterleaved {
                        if channels >= 2 && floatCount >= numFrames * 2 {
                            for i in 0..<numFrames {
                                left[i] = rawFloats[i]
                                right[i] = rawFloats[numFrames + i]
                            }
                        } else {
                            let c = min(numFrames, floatCount)
                            for i in 0..<c {
                                left[i] = rawFloats[i]
                                right[i] = rawFloats[i]
                            }
                        }
                    } else {
                        let avail = min(numFrames, floatCount / channels)
                        if channels >= 2 {
                            for i in 0..<avail {
                                left[i] = rawFloats[i * channels]
                                right[i] = rawFloats[i * channels + 1]
                            }
                        } else {
                            for i in 0..<avail {
                                left[i] = rawFloats[i]
                                right[i] = rawFloats[i]
                            }
                        }
                    }
                    didExtract = true
                }
            }
        }

        // 2. Fallback AudioBufferList path for Int16/Int32 or custom layouts
        if !didExtract {
            let maxBuffers = 8
            let ablSize = MemoryLayout<AudioBufferList>.size + (maxBuffers - 1) * MemoryLayout<AudioBuffer>.size
            let rawABL = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { rawABL.deallocate() }
            let ablPtr = rawABL.bindMemory(to: AudioBufferList.self, capacity: 1)

            var blockBuffer: CMBlockBuffer?
            var sizeNeeded: Int = 0
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: &sizeNeeded,
                bufferListOut: ablPtr,
                bufferListSize: ablSize,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockBuffer
            )
            guard status == noErr else { return nil }

            let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
            guard !buffers.isEmpty else { return nil }

            if isFloat && bits == 32 {
                if isNonInterleaved && buffers.count >= 2 {
                    if let lData = buffers[0].mData {
                        let lPtr = lData.assumingMemoryBound(to: Float.self)
                        let lCount = min(numFrames, Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size)
                        for i in 0..<lCount { left[i] = lPtr[i] }
                    }
                    if let rData = buffers[1].mData {
                        let rPtr = rData.assumingMemoryBound(to: Float.self)
                        let rCount = min(numFrames, Int(buffers[1].mDataByteSize) / MemoryLayout<Float>.size)
                        for i in 0..<rCount { right[i] = rPtr[i] }
                    }
                } else if let data = buffers[0].mData {
                    let ptr = data.assumingMemoryBound(to: Float.self)
                    let totalFloats = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
                    let availableFrames = min(numFrames, totalFloats / channels)
                    if channels >= 2 {
                        for i in 0..<availableFrames {
                            left[i] = ptr[i * channels]
                            right[i] = ptr[i * channels + 1]
                        }
                    } else {
                        for i in 0..<availableFrames {
                            left[i] = ptr[i]
                            right[i] = ptr[i]
                        }
                    }
                }
            } else if isSignedInt && bits == 16 {
                let scale: Float = 1.0 / 32768.0
                if isNonInterleaved && buffers.count >= 2 {
                    if let lData = buffers[0].mData {
                        let lPtr = lData.assumingMemoryBound(to: Int16.self)
                        let lCount = min(numFrames, Int(buffers[0].mDataByteSize) / MemoryLayout<Int16>.size)
                        for i in 0..<lCount { left[i] = Float(lPtr[i]) * scale }
                    }
                    if let rData = buffers[1].mData {
                        let rPtr = rData.assumingMemoryBound(to: Int16.self)
                        let rCount = min(numFrames, Int(buffers[1].mDataByteSize) / MemoryLayout<Int16>.size)
                        for i in 0..<rCount { right[i] = Float(rPtr[i]) * scale }
                    }
                } else if let data = buffers[0].mData {
                    let ptr = data.assumingMemoryBound(to: Int16.self)
                    let totalSamples = Int(buffers[0].mDataByteSize) / MemoryLayout<Int16>.size
                    let availableFrames = min(numFrames, totalSamples / channels)
                    if channels >= 2 {
                        for i in 0..<availableFrames {
                            left[i] = Float(ptr[i * channels]) * scale
                            right[i] = Float(ptr[i * channels + 1]) * scale
                        }
                    } else {
                        for i in 0..<availableFrames {
                            let v = Float(ptr[i]) * scale
                            left[i] = v
                            right[i] = v
                        }
                    }
                }
            } else if isSignedInt && bits == 32 {
                let scale: Float = 1.0 / 2147483648.0
                if isNonInterleaved && buffers.count >= 2 {
                    if let lData = buffers[0].mData {
                        let lPtr = lData.assumingMemoryBound(to: Int32.self)
                        let lCount = min(numFrames, Int(buffers[0].mDataByteSize) / MemoryLayout<Int32>.size)
                        for i in 0..<lCount { left[i] = Float(lPtr[i]) * scale }
                    }
                    if let rData = buffers[1].mData {
                        let rPtr = rData.assumingMemoryBound(to: Int32.self)
                        let rCount = min(numFrames, Int(buffers[1].mDataByteSize) / MemoryLayout<Int32>.size)
                        for i in 0..<rCount { right[i] = Float(rPtr[i]) * scale }
                    }
                } else if let data = buffers[0].mData {
                    let ptr = data.assumingMemoryBound(to: Int32.self)
                    let totalSamples = Int(buffers[0].mDataByteSize) / MemoryLayout<Int32>.size
                    let availableFrames = min(numFrames, totalSamples / channels)
                    if channels >= 2 {
                        for i in 0..<availableFrames {
                            left[i] = Float(ptr[i * channels]) * scale
                            right[i] = Float(ptr[i * channels + 1]) * scale
                        }
                    } else {
                        for i in 0..<availableFrames {
                            let v = Float(ptr[i]) * scale
                            left[i] = v
                            right[i] = v
                        }
                    }
                }
            } else {
                return nil
            }
        }

        // Resample to 48000 Hz if source sample rate differs
        if abs(asbd.mSampleRate - 48000.0) > 1.0 && asbd.mSampleRate >= 8000.0 {
            let outFrames = max(1, Int(round(Double(numFrames) * 48000.0 / asbd.mSampleRate)))
            var resL = [Float](repeating: 0, count: outFrames)
            var resR = [Float](repeating: 0, count: outFrames)
            let ratio = Double(max(1, numFrames - 1)) / Double(max(1, outFrames - 1))
            for i in 0..<outFrames {
                let pos = Double(i) * ratio
                let idx0 = min(numFrames - 1, max(0, Int(pos)))
                let idx1 = min(numFrames - 1, idx0 + 1)
                let frac = Float(pos - Double(idx0))
                resL[i] = left[idx0] + (left[idx1] - left[idx0]) * frac
                resR[i] = right[idx0] + (right[idx1] - right[idx0]) * frac
            }
            return (resL, resR)
        }

        return (left, right)
    }

    private func getOrCreateFormatDescription() -> CMAudioFormatDescription? {
        if let fmt = pcmFormatDescription { return fmt }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var fmt: CMAudioFormatDescription?
        let st = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &fmt
        )
        guard st == noErr else { return nil }
        pcmFormatDescription = fmt
        return fmt
    }

    private func createSampleBuffer(left: [Float], right: [Float], ptsFrame: Int64) -> CMSampleBuffer? {
        guard let fmt = getOrCreateFormatDescription() else { return nil }
        let frameCount = min(left.count, right.count)
        guard frameCount > 0 else { return nil }

        var interleaved = [Float](repeating: 0, count: frameCount * 2)
        for i in 0..<frameCount {
            interleaved[i * 2] = max(-1.0, min(1.0, left[i]))
            interleaved[i * 2 + 1] = max(-1.0, min(1.0, right[i]))
        }
        let byteCount = interleaved.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        let st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &block
        )
        guard st == noErr, let b = block else { return nil }
        interleaved.withUnsafeBufferPointer { ptr in
            _ = CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: b,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        // IMPORTANT: In CoreMedia, timing.duration for uncompressed PCM is the duration of 1 sample frame (1/48000s)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(value: ptsFrame, timescale: 48000),
            decodeTimeStamp: .invalid
        )
        var sampleSize: Int = 8
        var sampleBuffer: CMSampleBuffer?
        let createSt = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: b,
            formatDescription: fmt,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard createSt == noErr else { return nil }
        return sampleBuffer
    }
}

// MARK: - Real-Time Clock-Driven Audio Mixer (48kHz Stereo)

private final class RealTimeAudioMixer {
    private let capacity: Int = 192000 // 4 seconds of 48kHz stereo ring buffer
    private var ringL: [Float]
    private var ringR: [Float]
    private var readHeadFrameIndex: Int64 = 0
    private var sysWriteFrame: Int64 = -1
    private var micWriteFrame: Int64 = -1
    private let lock = NSLock()

    init() {
        ringL = [Float](repeating: 0, count: 192000)
        ringR = [Float](repeating: 0, count: 192000)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        ringL = [Float](repeating: 0, count: capacity)
        ringR = [Float](repeating: 0, count: capacity)
        readHeadFrameIndex = 0
        sysWriteFrame = -1
        micWriteFrame = -1
    }

    func appendSystemSamples(left: [Float], right: [Float], elapsedFrame: Int64, gain: Float) {
        lock.lock()
        defer { lock.unlock() }
        let count = min(left.count, right.count)
        guard count > 0 else { return }

        if sysWriteFrame < 0 || abs(elapsedFrame - sysWriteFrame) > 7200 {
            sysWriteFrame = max(readHeadFrameIndex, elapsedFrame)
        } else if sysWriteFrame < readHeadFrameIndex {
            sysWriteFrame = readHeadFrameIndex
        }

        for i in 0..<count {
            let k = sysWriteFrame + Int64(i)
            let idx = Int(k % Int64(capacity))
            ringL[idx] += left[i] * gain
            ringR[idx] += right[i] * gain
        }
        sysWriteFrame += Int64(count)
    }

    func appendMicSamples(left: [Float], right: [Float], elapsedFrame: Int64, gain: Float) {
        lock.lock()
        defer { lock.unlock() }
        let count = min(left.count, right.count)
        guard count > 0 else { return }

        if micWriteFrame < 0 || abs(elapsedFrame - micWriteFrame) > 7200 {
            micWriteFrame = max(readHeadFrameIndex, elapsedFrame)
        } else if micWriteFrame < readHeadFrameIndex {
            micWriteFrame = readHeadFrameIndex
        }

        // Pre-amp sensitivity boost (4.5x) for VoodooHDA analog microphone + smooth tanh limiter so voice is clear without clipping
        let effectiveGain = gain * 4.5
        for i in 0..<count {
            let k = micWriteFrame + Int64(i)
            let idx = Int(k % Int64(capacity))
            let lSample = tanhf(left[i] * effectiveGain)
            let rSample = tanhf(right[i] * effectiveGain)
            ringL[idx] += lSample
            ringR[idx] += rSample
        }
        micWriteFrame += Int64(count)
    }

    func pollChunks(currentWallFrame: Int64, chunkSize: Int = 960, lookaheadFrames: Int64 = 4800) -> [(left: [Float], right: [Float], ptsFrame: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        var result: [(left: [Float], right: [Float], ptsFrame: Int64)] = []
        let safeLimitFrame = currentWallFrame - lookaheadFrames
        guard safeLimitFrame >= readHeadFrameIndex + Int64(chunkSize) else { return result }

        while (safeLimitFrame - readHeadFrameIndex) >= Int64(chunkSize) {
            var outL = [Float](repeating: 0, count: chunkSize)
            var outR = [Float](repeating: 0, count: chunkSize)
            for i in 0..<chunkSize {
                let k = readHeadFrameIndex + Int64(i)
                let idx = Int(k % Int64(capacity))
                outL[i] = max(-1.0, min(1.0, ringL[idx]))
                outR[i] = max(-1.0, min(1.0, ringR[idx]))
                ringL[idx] = 0
                ringR[idx] = 0
            }
            result.append((outL, outR, readHeadFrameIndex))
            readHeadFrameIndex += Int64(chunkSize)
        }
        return result
    }

    func drainRemaining(upToFrame finalWallFrame: Int64, chunkSize: Int = 960) -> [(left: [Float], right: [Float], ptsFrame: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        var result: [(left: [Float], right: [Float], ptsFrame: Int64)] = []
        let targetEndFrame = max(finalWallFrame, max(sysWriteFrame, micWriteFrame))
        guard targetEndFrame > readHeadFrameIndex else { return result }

        while readHeadFrameIndex < targetEndFrame {
            let available = Int(min(Int64(chunkSize), targetEndFrame - readHeadFrameIndex))
            var outL = [Float](repeating: 0, count: available)
            var outR = [Float](repeating: 0, count: available)
            for i in 0..<available {
                let k = readHeadFrameIndex + Int64(i)
                let idx = Int(k % Int64(capacity))
                outL[i] = max(-1.0, min(1.0, ringL[idx]))
                outR[i] = max(-1.0, min(1.0, ringR[idx]))
                ringL[idx] = 0
                ringR[idx] = 0
            }
            result.append((outL, outR, readHeadFrameIndex))
            readHeadFrameIndex += Int64(available)
        }
        return result
    }
}

