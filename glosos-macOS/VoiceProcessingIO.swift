//
//  VoiceProcessingIO.swift
//  glosos-macOS
//
//  Created by EV on 6/3/26.
//

import AudioToolbox
import AVFoundation
import Speech

final class VoiceProcessingIO: @unchecked Sendable {
    private static let sampleRate: Double = 48_000
    private static let channelCount: AVAudioChannelCount = 1
    private static let inputBus: AudioUnitElement = 1
    private static let outputBus: AudioUnitElement = 0

    let clientFormat: AVAudioFormat
    var playbackCompletionHandler: (@Sendable (UUID) -> Void)?

    private let logHandler: @Sendable (String) -> Void
    private let stateLock = NSLock()
    private let asbd: AudioStreamBasicDescription

    private var audioUnit: AudioUnit?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var inputScratchBuffer: UnsafeMutableRawPointer?
    private var inputScratchCapacity = 0
    private var lastInputRenderError: OSStatus?

    private var playbackSamples: [Float] = []
    private var playbackFrameIndex = 0
    private var playbackToken: UUID?
    private var didNotifyPlaybackCompletion = false

    init(logHandler: @escaping @Sendable (String) -> Void) {
        self.logHandler = logHandler
        self.clientFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channelCount,
            interleaved: false
        )!

        var streamDescription = AudioStreamBasicDescription()
        streamDescription.mSampleRate = Self.sampleRate
        streamDescription.mFormatID = kAudioFormatLinearPCM
        streamDescription.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        streamDescription.mBytesPerPacket = 4
        streamDescription.mFramesPerPacket = 1
        streamDescription.mBytesPerFrame = 4
        streamDescription.mChannelsPerFrame = UInt32(Self.channelCount)
        streamDescription.mBitsPerChannel = 32
        streamDescription.mReserved = 0
        self.asbd = streamDescription
    }

    deinit {
        stop()
        inputScratchBuffer?.deallocate()
    }

    var isRunning: Bool {
        audioUnit != nil
    }

    func setRecognitionRequest(_ recognitionRequest: SFSpeechAudioBufferRecognitionRequest?) {
        stateLock.lock()
        self.recognitionRequest = recognitionRequest
        stateLock.unlock()
    }

    func startIfNeeded() throws {
        guard audioUnit == nil else {
            return
        }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw VoiceStopError.audioUnitComponentUnavailable
        }

        var audioUnit: AudioUnit?
        try checkStatus(AudioComponentInstanceNew(component, &audioUnit), operation: "creating VoiceProcessingIO")
        guard let audioUnit else {
            throw VoiceStopError.audioUnitComponentUnavailable
        }

        do {
            var streamDescription = asbd
            var maxFramesPerSlice: UInt32 = 4096
            var bypassVoiceProcessing: UInt32 = 0
            var enableAGC: UInt32 = 1

            // VoiceProcessingIO uses bus 0 for speaker output and bus 1 for mic input.
            // Unlike AUHAL, its IO is already wired and should not be toggled with EnableIO.
            try checkStatus(
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input,
                    Self.outputBus,
                    &streamDescription,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                ),
                operation: "setting VoiceProcessingIO playback format"
            )
            try checkStatus(
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Output,
                    Self.inputBus,
                    &streamDescription,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                ),
                operation: "setting VoiceProcessingIO capture format"
            )
            try checkStatus(
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioUnitProperty_MaximumFramesPerSlice,
                    kAudioUnitScope_Global,
                    0,
                    &maxFramesPerSlice,
                    UInt32(MemoryLayout<UInt32>.size)
                ),
                operation: "setting VoiceProcessingIO max frames"
            )
            try checkStatus(
                AudioUnitSetProperty(
                    audioUnit,
                    kAUVoiceIOProperty_BypassVoiceProcessing,
                    kAudioUnitScope_Global,
                    0,
                    &bypassVoiceProcessing,
                    UInt32(MemoryLayout<UInt32>.size)
                ),
                operation: "enabling voice processing"
            )
            try checkStatus(
                AudioUnitSetProperty(
                    audioUnit,
                    kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                    kAudioUnitScope_Global,
                    0,
                    &enableAGC,
                    UInt32(MemoryLayout<UInt32>.size)
                ),
                operation: "enabling automatic gain control"
            )

            var outputCallback = AURenderCallbackStruct(
                inputProc: voiceProcessingOutputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try checkStatus(
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioUnitProperty_SetRenderCallback,
                    kAudioUnitScope_Input,
                    Self.outputBus,
                    &outputCallback,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                ),
                operation: "setting VoiceProcessingIO playback callback"
            )

            var inputCallback = AURenderCallbackStruct(
                inputProc: voiceProcessingInputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try checkStatus(
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_SetInputCallback,
                    kAudioUnitScope_Global,
                    Self.inputBus,
                    &inputCallback,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                ),
                operation: "setting VoiceProcessingIO capture callback"
            )

            try checkStatus(AudioUnitInitialize(audioUnit), operation: "initializing VoiceProcessingIO")
            try checkStatus(AudioOutputUnitStart(audioUnit), operation: "starting VoiceProcessingIO")

            self.audioUnit = audioUnit
            logConfiguredFormats(for: audioUnit)
            logHandler("Voice processing audio unit started.")
        } catch {
            AudioComponentInstanceDispose(audioUnit)
            throw error
        }
    }

    func stop() {
        stateLock.lock()
        recognitionRequest = nil
        playbackSamples.removeAll(keepingCapacity: false)
        playbackFrameIndex = 0
        playbackToken = nil
        didNotifyPlaybackCompletion = false
        let audioUnit = self.audioUnit
        self.audioUnit = nil
        stateLock.unlock()

        guard let audioUnit else {
            return
        }

        AudioOutputUnitStop(audioUnit)
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
        logHandler("Voice processing audio unit stopped.")
    }

    func schedulePlayback(from fileURL: URL, playbackToken: UUID) throws {
        let playbackSamples = try makePlaybackSamples(from: fileURL)
        stateLock.lock()
        self.playbackSamples = playbackSamples
        self.playbackFrameIndex = 0
        self.playbackToken = playbackToken
        self.didNotifyPlaybackCompletion = false
        stateLock.unlock()
    }

    func stopPlayback() {
        stateLock.lock()
        playbackSamples.removeAll(keepingCapacity: false)
        playbackFrameIndex = 0
        playbackToken = nil
        didNotifyPlaybackCompletion = true
        stateLock.unlock()
    }

    private func makePlaybackSamples(from fileURL: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: fileURL)
        let sourceFormat = audioFile.processingFormat
        let inputFrameCapacity = AVAudioFrameCount(max(audioFile.length, 1))

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputFrameCapacity) else {
            throw VoiceStopError.playbackBufferAllocationFailed
        }

        try audioFile.read(into: sourceBuffer)

        let convertedBuffer: AVAudioPCMBuffer
        if sourceFormat == clientFormat {
            convertedBuffer = sourceBuffer
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: clientFormat) else {
                throw VoiceStopError.playbackConversionFailed("Could not create playback format converter.")
            }

            let capacityRatio = clientFormat.sampleRate / sourceFormat.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(max(1, ceil(Double(sourceBuffer.frameLength) * capacityRatio) + 1))
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: outputFrameCapacity) else {
                throw VoiceStopError.playbackBufferAllocationFailed
            }

            var conversionError: NSError?
            var didProvideInput = false
            let conversionStatus = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                didProvideInput = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }

            if conversionStatus == .error {
                throw VoiceStopError.playbackConversionFailed(conversionError?.localizedDescription ?? "Unknown conversion failure.")
            }

            convertedBuffer = outputBuffer
        }

        guard let channelData = convertedBuffer.floatChannelData?[0] else {
            throw VoiceStopError.playbackBufferAllocationFailed
        }

        return Array(UnsafeBufferPointer(start: channelData, count: Int(convertedBuffer.frameLength)))
    }

    private func logConfiguredFormats(for audioUnit: AudioUnit) {
        do {
            let playbackFormat = try getStreamFormat(
                for: audioUnit,
                scope: kAudioUnitScope_Input,
                bus: Self.outputBus
            )
            let captureFormat = try getStreamFormat(
                for: audioUnit,
                scope: kAudioUnitScope_Output,
                bus: Self.inputBus
            )
            logHandler("VoiceProcessingIO playback format: \(describe(playbackFormat))")
            logHandler("VoiceProcessingIO capture format: \(describe(captureFormat))")
        } catch {
            logHandler("Could not read VoiceProcessingIO stream formats: \(error.localizedDescription)")
        }
    }

    private func getStreamFormat(for audioUnit: AudioUnit, scope: AudioUnitScope, bus: AudioUnitElement) throws -> AudioStreamBasicDescription {
        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkStatus(
            AudioUnitGetProperty(
                audioUnit,
                kAudioUnitProperty_StreamFormat,
                scope,
                bus,
                &streamDescription,
                &size
            ),
            operation: "reading VoiceProcessingIO stream format"
        )
        return streamDescription
    }

    private func describe(_ streamDescription: AudioStreamBasicDescription) -> String {
        "\(streamDescription.mChannelsPerFrame) ch, \(Int(streamDescription.mSampleRate)) Hz, bytes/frame \(streamDescription.mBytesPerFrame)"
    }

    fileprivate func handleInput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?,
        inTimeStamp: UnsafePointer<AudioTimeStamp>?,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) -> OSStatus {
        guard let audioUnit, let inTimeStamp else {
            return noErr
        }

        ensureScratchCapacity(frameCount: Int(inNumberFrames))

        let audioBuffer = AudioBuffer(
            mNumberChannels: UInt32(Self.channelCount),
            mDataByteSize: inNumberFrames * 4,
            mData: inputScratchBuffer
        )
        var audioBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
        let status = AudioUnitRender(
            audioUnit,
            ioActionFlags,
            inTimeStamp,
            Self.inputBus,
            inNumberFrames,
            &audioBufferList
        )

        if status != noErr {
            if lastInputRenderError != status {
                lastInputRenderError = status
                logHandler("VoiceProcessingIO input render failed: \(status)")
            }
            return status
        }

        guard let recognitionRequest = withStateLock({ self.recognitionRequest }) else {
            return noErr
        }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: inNumberFrames) else {
            return noErr
        }

        pcmBuffer.frameLength = inNumberFrames
        if let destination = pcmBuffer.floatChannelData?[0], let source = audioBufferList.mBuffers.mData {
            memcpy(destination, source, Int(inNumberFrames) * MemoryLayout<Float>.size)
            recognitionRequest.append(pcmBuffer)
        }

        return noErr
    }

    fileprivate func handleOutput(ioData: UnsafeMutablePointer<AudioBufferList>?, inNumberFrames: UInt32) -> OSStatus {
        guard let ioData else {
            return noErr
        }

        let frameCount = Int(inNumberFrames)
        var completionToken: UUID?

        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        zero(buffers: buffers, frameCount: frameCount)

        stateLock.lock()
        let remainingFrames = max(0, playbackSamples.count - playbackFrameIndex)
        let copyFrames = min(frameCount, remainingFrames)

        if copyFrames > 0 {
            playbackSamples.withUnsafeBufferPointer { samples in
                guard let source = samples.baseAddress?.advanced(by: playbackFrameIndex) else {
                    return
                }

                for audioBuffer in buffers {
                    guard let data = audioBuffer.mData?.assumingMemoryBound(to: Float.self) else {
                        continue
                    }

                    memcpy(data, source, copyFrames * MemoryLayout<Float>.size)
                }
            }

            playbackFrameIndex += copyFrames
        }

        if playbackFrameIndex >= playbackSamples.count, !didNotifyPlaybackCompletion, let playbackToken {
            didNotifyPlaybackCompletion = true
            self.playbackToken = nil
            self.playbackSamples.removeAll(keepingCapacity: false)
            self.playbackFrameIndex = 0
            completionToken = playbackToken
        }
        stateLock.unlock()

        if let completionToken {
            playbackCompletionHandler?(completionToken)
        }

        return noErr
    }

    private func zero(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        for audioBuffer in buffers {
            guard let data = audioBuffer.mData else {
                continue
            }

            memset(data, 0, frameCount * MemoryLayout<Float>.size)
        }
    }

    private func ensureScratchCapacity(frameCount: Int) {
        let requiredByteCount = max(frameCount, 1) * MemoryLayout<Float>.size
        guard requiredByteCount > inputScratchCapacity else {
            return
        }

        inputScratchBuffer?.deallocate()
        inputScratchBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: requiredByteCount,
            alignment: MemoryLayout<Float>.alignment
        )
        inputScratchCapacity = requiredByteCount
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func checkStatus(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw VoiceStopError.audioUnitOperationFailed(operation: operation, status: status)
        }
    }
}

private let voiceProcessingInputCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ in
    let controller = Unmanaged<VoiceProcessingIO>.fromOpaque(inRefCon).takeUnretainedValue()
    return controller.handleInput(
        ioActionFlags: ioActionFlags,
        inTimeStamp: inTimeStamp,
        inBusNumber: inBusNumber,
        inNumberFrames: inNumberFrames
    )
}

private let voiceProcessingOutputCallback: AURenderCallback = { inRefCon, _, _, _, inNumberFrames, ioData in
    let controller = Unmanaged<VoiceProcessingIO>.fromOpaque(inRefCon).takeUnretainedValue()
    return controller.handleOutput(ioData: ioData, inNumberFrames: inNumberFrames)
}

enum VoiceStopError: LocalizedError {
    case recognizerUnavailable
    case unexpectedSynthesisBuffer
    case audioUnitComponentUnavailable
    case audioUnitOperationFailed(operation: String, status: OSStatus)
    case playbackBufferAllocationFailed
    case playbackConversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognition is unavailable."
        case .unexpectedSynthesisBuffer:
            return "Speech synthesis produced an unexpected buffer type."
        case .audioUnitComponentUnavailable:
            return "VoiceProcessingIO is unavailable on this system."
        case let .audioUnitOperationFailed(operation, status):
            return "\(operation) failed with OSStatus \(status)."
        case .playbackBufferAllocationFailed:
            return "Playback buffer allocation failed."
        case let .playbackConversionFailed(message):
            return "Playback conversion failed: \(message)"
        }
    }
}
