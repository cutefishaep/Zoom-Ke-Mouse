import Foundation
import AVFoundation
import CoreMedia
import CoreAudio
import Accelerate

// MARK: - Audio Capture Delegate Protocol

public protocol AudioCaptureDelegate: AnyObject {
    func audioCaptureDidOutput(sampleBuffer: CMSampleBuffer, isSystemAudio: Bool)
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

    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let micQueue = DispatchQueue(label: "com.cutefishaep.zoomkmouse.micqueue", qos: .userInteractive)
    private let audioProcessingQueue = DispatchQueue(label: "com.cutefishaep.zoomkmouse.audioprocess", qos: .userInteractive)

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
        return discovery.devices.map { device in
            AudioDeviceInfo(
                id: device.uniqueID,
                name: device.localizedName,
                channels: 2
            )
        }
    }

    // MARK: - Lifecycle Controls

    public func startCapture(
        systemAudioEnabled: Bool,
        systemAudioVolume: Float,
        micAudioEnabled: Bool,
        micDeviceUID: String?,
        micVolume: Float
    ) throws {
        stateLock.lock()
        self.isSystemAudioEnabled = systemAudioEnabled
        self.systemAudioVolume = max(0.0, systemAudioVolume)
        self.isMicAudioEnabled = micAudioEnabled
        self.micDeviceUID = micDeviceUID
        self.micAudioVolume = max(0.0, micVolume)
        self.isCapturing = true
        self.mixer.reset()
        stateLock.unlock()

        if micAudioEnabled {
            try setupAndStartMicrophoneSession(deviceUID: micDeviceUID)
        }
    }

    public func stopCapture() {
        stateLock.lock()
        guard isCapturing else {
            stateLock.unlock()
            return
        }
        isCapturing = false
        let session = captureSession
        captureSession = nil
        audioOutput = nil
        stateLock.unlock()

        if let s = session, s.isRunning {
            micQueue.async {
                s.stopRunning()
            }
        }

        // Drain any remaining mixed frames
        drainRemainingMixedAudio()
    }

    public func updateVolumes(systemAudioVolume: Float, micVolume: Float) {
        stateLock.lock()
        self.systemAudioVolume = max(0.0, systemAudioVolume)
        self.micAudioVolume = max(0.0, micVolume)
        stateLock.unlock()
    }

    // MARK: - Microphone Session Setup

    private func setupAndStartMicrophoneSession(deviceUID: String?) throws {
        let selectedDevice: AVCaptureDevice?
        if let uid = deviceUID, !uid.isEmpty {
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInMicrophone, .externalUnknown],
                mediaType: .audio,
                position: .unspecified
            )
            selectedDevice = discovery.devices.first(where: { $0.uniqueID == uid }) ?? AVCaptureDevice.default(for: .audio)
        } else {
            selectedDevice = AVCaptureDevice.default(for: .audio)
        }

        guard let device = selectedDevice else {
            return
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
        stateLock.unlock()

        micQueue.async {
            session.startRunning()
        }
    }

    // MARK: - Ingestion Handlers

    /// Ingestion entry point for ScreenCaptureKit system audio (`SCStreamOutputType.audio`)
    public func handleSystemAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.seconds >= 0.0,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              CMSampleBufferGetDataBuffer(sampleBuffer) != nil else {
            return
        }

        stateLock.lock()
        guard isCapturing, isSystemAudioEnabled else {
            stateLock.unlock()
            return
        }
        let bothActive = isMicAudioEnabled
        let vol = systemAudioVolume
        stateLock.unlock()

        audioProcessingQueue.async { [weak self] in
            guard let self = self else { return }
            if bothActive {
                self.processForMixing(sampleBuffer: sampleBuffer, gain: vol)
            } else {
                self.applyGainInPlace(sampleBuffer: sampleBuffer, gain: vol)
                self.delegate?.audioCaptureDidOutput(sampleBuffer: sampleBuffer, isSystemAudio: true)
            }
        }
    }

    /// Ingestion delegate for AVCaptureAudioDataOutput microphone stream
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.seconds >= 0.0,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              CMSampleBufferGetDataBuffer(sampleBuffer) != nil else {
            return
        }

        stateLock.lock()
        guard isCapturing, isMicAudioEnabled else {
            stateLock.unlock()
            return
        }
        let bothActive = isSystemAudioEnabled
        let vol = micAudioVolume
        stateLock.unlock()

        audioProcessingQueue.async { [weak self] in
            guard let self = self else { return }
            if bothActive {
                self.processForMixing(sampleBuffer: sampleBuffer, gain: vol)
            } else {
                self.applyGainInPlace(sampleBuffer: sampleBuffer, gain: vol)
                self.delegate?.audioCaptureDidOutput(sampleBuffer: sampleBuffer, isSystemAudio: false)
            }
        }
    }

    // MARK: - Mixing & Gain Helpers

    private func processForMixing(sampleBuffer: CMSampleBuffer, gain: Float) {
        guard let extracted = extractSamples(from: sampleBuffer) else { return }
        mixer.appendSamples(
            left: extracted.left,
            right: extracted.right,
            sampleIndex: extracted.sampleIndex,
            gain: gain
        )

        // Poll any completed mixed chunks (960 frames = 20ms standard)
        let readyChunks = mixer.pollMixedChunks(chunkSize: 960, delayFrames: 480)
        for chunk in readyChunks {
            if let mixedBuffer = createSampleBuffer(left: chunk.left, right: chunk.right, ptsFrame: chunk.ptsFrame) {
                delegate?.audioCaptureDidOutput(sampleBuffer: mixedBuffer, isSystemAudio: true)
            }
        }
    }

    private func drainRemainingMixedAudio() {
        audioProcessingQueue.sync { [weak self] in
            guard let self = self else { return }
            let remainingChunks = self.mixer.drainRemaining(chunkSize: 960)
            for chunk in remainingChunks {
                if let mixedBuffer = self.createSampleBuffer(left: chunk.left, right: chunk.right, ptsFrame: chunk.ptsFrame) {
                    self.delegate?.audioCaptureDidOutput(sampleBuffer: mixedBuffer, isSystemAudio: true)
                }
            }
        }
    }

    private func applyGainInPlace(sampleBuffer: CMSampleBuffer, gain: Float) {
        guard abs(gain - 1.0) > 0.001 else { return }
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }
        var length = 0
        var rawPtr: UnsafeMutablePointer<CChar>?
        let st = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &rawPtr
        )
        guard st == noErr, let ptr = rawPtr else { return }

        if (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && asbd.mBitsPerChannel == 32 {
            let floatCount = length / MemoryLayout<Float>.size
            let floatPtr = ptr.withMemoryRebound(to: Float.self, capacity: floatCount) { $0 }
            for i in 0..<floatCount {
                let s = floatPtr[i] * gain
                floatPtr[i] = max(-1.0, min(1.0, s))
            }
        } else if (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 && asbd.mBitsPerChannel == 16 {
            let int16Count = length / MemoryLayout<Int16>.size
            let int16Ptr = ptr.withMemoryRebound(to: Int16.self, capacity: int16Count) { $0 }
            for i in 0..<int16Count {
                let scaled = Float(int16Ptr[i]) * gain
                let clamped = max(-32768.0, min(32767.0, scaled))
                int16Ptr[i] = Int16(clamped)
            }
        }
    }

    private func extractSamples(from sampleBuffer: CMSampleBuffer) -> (left: [Float], right: [Float], sampleIndex: Int64)? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.seconds >= 0.0 else { return nil }
        let sampleIndex = Int64(round(pts.seconds * 48000.0))
        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numFrames > 0 else { return nil }

        var length = 0
        var rawPtr: UnsafeMutablePointer<CChar>?
        let st = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &rawPtr
        )
        guard st == noErr, let ptr = rawPtr else { return nil }

        var left = [Float](repeating: 0, count: numFrames)
        var right = [Float](repeating: 0, count: numFrames)

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let channels = Int(asbd.mChannelsPerFrame)

        if isFloat && asbd.mBitsPerChannel == 32 {
            let floatCount = length / MemoryLayout<Float>.size
            let floatPtr = ptr.withMemoryRebound(to: Float.self, capacity: floatCount) { $0 }
            if isNonInterleaved && channels >= 2 {
                for i in 0..<numFrames {
                    left[i] = floatPtr[i]
                    right[i] = floatPtr[numFrames + i]
                }
            } else if !isNonInterleaved && channels >= 2 {
                for i in 0..<numFrames {
                    left[i] = floatPtr[i * 2]
                    right[i] = floatPtr[i * 2 + 1]
                }
            } else if channels == 1 {
                for i in 0..<numFrames {
                    left[i] = floatPtr[i]
                    right[i] = floatPtr[i]
                }
            }
        } else if (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 && asbd.mBitsPerChannel == 16 {
            let int16Count = length / MemoryLayout<Int16>.size
            let int16Ptr = ptr.withMemoryRebound(to: Int16.self, capacity: int16Count) { $0 }
            if !isNonInterleaved && channels >= 2 {
                for i in 0..<numFrames {
                    left[i] = Float(int16Ptr[i * 2]) / 32768.0
                    right[i] = Float(int16Ptr[i * 2 + 1]) / 32768.0
                }
            } else {
                for i in 0..<numFrames {
                    left[i] = Float(int16Ptr[i]) / 32768.0
                    right[i] = Float(int16Ptr[i]) / 32768.0
                }
            }
        }
        return (left, right, sampleIndex)
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
        let frameCount = left.count
        var interleaved = [Float](repeating: 0, count: frameCount * 2)
        for i in 0..<frameCount {
            interleaved[i * 2] = left[i]
            interleaved[i * 2 + 1] = right[i]
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
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frameCount), timescale: 48000),
            presentationTimeStamp: CMTime(value: ptsFrame, timescale: 48000),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let createSt = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: b,
            formatDescription: fmt,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createSt == noErr else { return nil }
        return sampleBuffer
    }
}

// MARK: - Real-Time Audio Mixer

private final class RealTimeAudioMixer {
    private let capacity: Int = 96000 // 2 seconds of 48kHz audio
    private var ringL: [Float]
    private var ringR: [Float]
    private var anchorFrameIndex: Int64 = -1
    private var readHeadFrameIndex: Int64 = -1
    private var maxWriteIndex: Int64 = -1
    private let lock = NSLock()

    init() {
        ringL = [Float](repeating: 0, count: 96000)
        ringR = [Float](repeating: 0, count: 96000)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        ringL = [Float](repeating: 0, count: capacity)
        ringR = [Float](repeating: 0, count: capacity)
        anchorFrameIndex = -1
        readHeadFrameIndex = -1
        maxWriteIndex = -1
    }

    func appendSamples(left: [Float], right: [Float], sampleIndex: Int64, gain: Float) {
        lock.lock()
        defer { lock.unlock() }
        let count = Int64(left.count)
        if anchorFrameIndex == -1 {
            anchorFrameIndex = sampleIndex
            readHeadFrameIndex = sampleIndex
        }
        for i in 0..<count {
            let k = sampleIndex + i
            if k < readHeadFrameIndex { continue }
            let rawMod = k % Int64(capacity)
            let idx = Int((rawMod + Int64(capacity)) % Int64(capacity))
            ringL[idx] += left[Int(i)] * gain
            ringR[idx] += right[Int(i)] * gain
            if k > maxWriteIndex {
                maxWriteIndex = k
            }
        }
    }

    func pollMixedChunks(chunkSize: Int = 960, delayFrames: Int64 = 480) -> [(left: [Float], right: [Float], ptsFrame: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        var result: [(left: [Float], right: [Float], ptsFrame: Int64)] = []
        guard readHeadFrameIndex >= 0 else { return result }

        while (maxWriteIndex - readHeadFrameIndex) >= Int64(chunkSize) + delayFrames {
            var outL = [Float](repeating: 0, count: chunkSize)
            var outR = [Float](repeating: 0, count: chunkSize)
            for i in 0..<chunkSize {
                let k = readHeadFrameIndex + Int64(i)
                let rawMod = k % Int64(capacity)
                let idx = Int((rawMod + Int64(capacity)) % Int64(capacity))
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

    func drainRemaining(chunkSize: Int = 960) -> [(left: [Float], right: [Float], ptsFrame: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        var result: [(left: [Float], right: [Float], ptsFrame: Int64)] = []
        guard readHeadFrameIndex >= 0 else { return result }

        while readHeadFrameIndex < maxWriteIndex {
            let available = Int(min(Int64(chunkSize), maxWriteIndex - readHeadFrameIndex + 1))
            var outL = [Float](repeating: 0, count: available)
            var outR = [Float](repeating: 0, count: available)
            for i in 0..<available {
                let k = readHeadFrameIndex + Int64(i)
                let rawMod = k % Int64(capacity)
                let idx = Int((rawMod + Int64(capacity)) % Int64(capacity))
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
