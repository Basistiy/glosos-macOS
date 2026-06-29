//
//  SpeechController.swift
//  glosos-macOS
//
//  Created by EV on 6/3/26.
//

import AVFoundation
import Combine
import Speech
import MLX
import MLXAudioCore
import MLXAudioSTT
import HuggingFace

enum ASRSystem: String, CaseIterable, Identifiable {
    case apple = "apple"
    case qwen = "qwen"
    
    var id: String { self.rawValue }
    var title: String {
        switch self {
        case .apple: return "Apple Speech Recognition"
        case .qwen: return "Qwen3 ASR (Local MLX)"
        }
    }
}

enum QwenASRState: Equatable {
    case idle
    case downloading(progress: Double, completedBytes: Int64, totalBytes: Int64)
    case loading
    case ready
    case failed(message: String)
}

@MainActor
final class SpeechController: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isMicrophoneMuted = false
    @Published private(set) var isSpeakersMuted = true
    @Published private(set) var statusMessage = "Ready to record incoming WebRTC audio."
    @Published private(set) var liveTranscript = ""
    @Published var finalizedUtterance: TranscribedUtterance? = nil
    @Published private(set) var playbackInterruptionToken: UUID? = nil

    @Published var selectedASRSystem: ASRSystem {
        didSet {
            guard selectedASRSystem != oldValue else {
                return
            }

            userDefaults.set(selectedASRSystem.rawValue, forKey: Self.asrSystemKey)
            handleASRSystemChange()
        }
    }

    @Published private(set) var qwenASRState: QwenASRState = .idle
    private var qwenModel: Qwen3ASRModel?

    @Published var selectedLanguage: SpeechLanguage {
        didSet {
            guard selectedLanguage != oldValue else {
                return
            }

            userDefaults.set(selectedLanguage.rawValue, forKey: Self.selectedLanguageKey)
            handleSelectedLanguageChange()
        }
    }

    @Published var usePersonalVoice: Bool {
        didSet {
            guard usePersonalVoice != oldValue else { return }
            userDefaults.set(usePersonalVoice, forKey: Self.usePersonalVoiceKey)
            updateSpeechVoice()
        }
    }

    @Published var selectedPersonalVoiceIdentifier: String? {
        didSet {
            guard selectedPersonalVoiceIdentifier != oldValue else { return }
            if let id = selectedPersonalVoiceIdentifier {
                userDefaults.set(id, forKey: Self.selectedPersonalVoiceIdentifierKey)
            } else {
                userDefaults.removeObject(forKey: Self.selectedPersonalVoiceIdentifierKey)
            }
            updateSpeechVoice()
        }
    }

    @Published private(set) var personalVoiceAuthorizationStatus: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus = .notDetermined
    @Published private(set) var availablePersonalVoices: [AVSpeechSynthesisVoice] = []

    @Published var isWebRTCConnected = false {
        didSet {
            playbackSynthesizer.delegate = isWebRTCConnected ? nil : self
        }
    }

    @Published var vadStartThreshold: Float {
        didSet {
            guard vadStartThreshold != oldValue else { return }
            userDefaults.set(vadStartThreshold, forKey: Self.vadStartThresholdKey)
            vadProcessor?.updateThresholds(
                startThreshold: vadStartThreshold,
                startFrames: vadStartFrames,
                endThreshold: vadEndThreshold,
                endFrames: vadEndFrames
            )
        }
    }

    @Published var vadStartFrames: Int {
        didSet {
            guard vadStartFrames != oldValue else { return }
            userDefaults.set(vadStartFrames, forKey: Self.vadStartFramesKey)
            vadProcessor?.updateThresholds(
                startThreshold: vadStartThreshold,
                startFrames: vadStartFrames,
                endThreshold: vadEndThreshold,
                endFrames: vadEndFrames
            )
        }
    }

    @Published var vadEndThreshold: Float {
        didSet {
            guard vadEndThreshold != oldValue else { return }
            userDefaults.set(vadEndThreshold, forKey: Self.vadEndThresholdKey)
            vadProcessor?.updateThresholds(
                startThreshold: vadStartThreshold,
                startFrames: vadStartFrames,
                endThreshold: vadEndThreshold,
                endFrames: vadEndFrames
            )
        }
    }

    @Published var vadEndFrames: Int {
        didSet {
            guard vadEndFrames != oldValue else { return }
            userDefaults.set(vadEndFrames, forKey: Self.vadEndFramesKey)
            vadProcessor?.updateThresholds(
                startThreshold: vadStartThreshold,
                startFrames: vadStartFrames,
                endThreshold: vadEndThreshold,
                endFrames: vadEndFrames
            )
        }
    }

    var onSynthesizedBuffers: (([AVAudioPCMBuffer], @escaping () -> Void) -> Void)?
    var onSynthesizedFile: ((URL, @escaping () -> Void) -> Void)?
    var onStopPlayback: (() -> Void)?
    var onSpeechStarted: (() -> Void)?
    private var currentPlaybackToken: PlaybackToken?
    
    var agentResponsesDirectoryURL: URL?

    private let playbackSynthesizer = AVSpeechSynthesizer()
    private var speechVoice: AVSpeechSynthesisVoice?
    private var speechRecognizer: SFSpeechRecognizer?
    private let userDefaults: UserDefaults

    private var canListenForTranscription = true
    private var isListeningContinuously = false
    private var isPreparingPlayback = false
    private var isPlaybackAudible = false
    private var shouldKeepListening = false

    private var audioFile: AVAudioFile?
    var audioFileURL: URL?
    private var currentPlayingFileURL: URL?
    private static let selectedLanguageKey = "speechLanguage"
    private static let usePersonalVoiceKey = "usePersonalVoice"
    private static let selectedPersonalVoiceIdentifierKey = "selectedPersonalVoiceIdentifier"
    private static let asrSystemKey = "asrSystem"
    private static let vadStartThresholdKey = "vadStartThreshold"
    private static let vadStartFramesKey = "vadStartFrames"
    private static let vadEndThresholdKey = "vadEndThreshold"
    private static let vadEndFramesKey = "vadEndFrames"

    private var vadProcessor: SileroVADProcessor?
    private var isRecordingUtterance = false
    private var prerollBuffers: [AVAudioPCMBuffer] = []
    private let maxPrerollDuration: TimeInterval = 0.8

    init(userDefaults: UserDefaults = .standard) {
        let selectedLanguage = Self.loadSavedLanguage(from: userDefaults)
        self.userDefaults = userDefaults
        self.selectedLanguage = selectedLanguage
        
        let usePV = userDefaults.bool(forKey: Self.usePersonalVoiceKey)
        let selectedPVID = userDefaults.string(forKey: Self.selectedPersonalVoiceIdentifierKey)
        self.usePersonalVoice = usePV
        self.selectedPersonalVoiceIdentifier = selectedPVID
        
        let asrSystemRaw = userDefaults.string(forKey: Self.asrSystemKey) ?? ASRSystem.apple.rawValue
        let asrSystem = ASRSystem(rawValue: asrSystemRaw) ?? .apple
        self.selectedASRSystem = asrSystem
        
        let startThreshold = userDefaults.object(forKey: Self.vadStartThresholdKey) as? Float ?? 0.60
        let startFrames = userDefaults.object(forKey: Self.vadStartFramesKey) as? Int ?? 2
        let endThreshold = userDefaults.object(forKey: Self.vadEndThresholdKey) as? Float ?? 0.35
        let endFrames = userDefaults.object(forKey: Self.vadEndFramesKey) as? Int ?? 10

        self.vadStartThreshold = startThreshold
        self.vadStartFrames = startFrames
        self.vadEndThreshold = endThreshold
        self.vadEndFrames = endFrames

        let status = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
        self.personalVoiceAuthorizationStatus = status
        
        var personalVoices: [AVSpeechSynthesisVoice] = []
        if status == .authorized {
            personalVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.voiceTraits.contains(.isPersonalVoice) }
        }
        self.availablePersonalVoices = personalVoices
        
        if usePV, status == .authorized, let pvid = selectedPVID, let voice = personalVoices.first(where: { $0.identifier == pvid }) {
            self.speechVoice = voice
        } else if usePV, status == .authorized, let firstVoice = personalVoices.first {
            self.speechVoice = firstVoice
            self.selectedPersonalVoiceIdentifier = firstVoice.identifier
            userDefaults.set(firstVoice.identifier, forKey: Self.selectedPersonalVoiceIdentifierKey)
        } else {
            self.speechVoice = Self.makeSpeechVoice(for: selectedLanguage)
        }
        
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: selectedLanguage.localeIdentifier))
        super.init()
        playbackSynthesizer.delegate = self
        
        self.vadProcessor = SileroVADProcessor(
            startThreshold: startThreshold,
            startFrames: startFrames,
            endThreshold: endThreshold,
            endFrames: endFrames,
            logHandler: { message in
                print(SpeechController.formatLog("[VAD] \(message)"))
            }
        )
        self.vadProcessor?.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                self?.handleSpeechStarted()
            }
        }
        self.vadProcessor?.onSpeechEnded = { [weak self] in
            Task { @MainActor in
                self?.handleSpeechEnded()
            }
        }
        self.vadProcessor?.loadModelIfNeeded()
        
        if asrSystem == .qwen {
            loadQwenModel()
        }
    }

    var isCapturingSpeech: Bool {
        audioFile != nil
    }

    var displayedLiveTranscript: String {
        switch liveTranscript {
        case "Listening...", "Speech detected...":
            return ""
        default:
            return liveTranscript
        }
    }

    func toggleMicrophoneMute() {
        isMicrophoneMuted ? unmuteMicrophone() : muteMicrophone()
    }

    func toggleSpeakersMute() {
        isSpeakersMuted.toggle()
        refreshStatusMessage()
    }

    var isReadyForLiveTranscription: Bool {
        canListenForTranscription
    }

    func refreshPermissionState() {
        // Speech authorization can be checked, but we request it in preparePermissions
    }

    func preparePermissions() async {
        _ = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }

        _ = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    func play(_ text: String) {
        guard isWebRTCConnected else {
            return
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, !isPreparingPlayback, !isSpeaking else {
            return
        }

        Task {
            beginPlayback(with: trimmedText)
        }
    }

    func startContinuousListening() async {
        shouldKeepListening = true
        guard !isMicrophoneMuted, !isListeningContinuously else {
            return
        }

        isListeningContinuously = true
        vadProcessor?.resetSession()
        refreshStatusMessage()
        log("Started listening to WebRTC stream for VAD-segmented recording.")
    }

    func stopContinuousListening() {
        shouldKeepListening = false
        isListeningContinuously = false
        isRecordingUtterance = false
        prerollBuffers.removeAll()
        closeAudioFileIfNeeded()
    }

    func feedExternalAudio(_ buffer: AVAudioPCMBuffer) {
        guard isListeningContinuously, !isMicrophoneMuted else {
            prerollBuffers.removeAll()
            closeAudioFileIfNeeded()
            return
        }
        
        // Feed mono channel data to VAD processor
        if let channelData = buffer.floatChannelData {
            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            vadProcessor?.append(samples: samples, sampleRate: Int(buffer.format.sampleRate))
        }
        
        if isRecordingUtterance {
            do {
                try openAudioFileIfNeeded(format: buffer.format)
                try audioFile?.write(from: buffer)
            } catch {
                log("Failed to write audio buffer to file: \(error.localizedDescription)")
            }
        } else {
            // Cache in pre-roll buffer
            prerollBuffers.append(buffer)
            trimPrerollBuffers()
        }
    }

    private func trimPrerollBuffers() {
        var totalDuration = prerollBuffers.reduce(0.0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
        while totalDuration > maxPrerollDuration && !prerollBuffers.isEmpty {
            let removed = prerollBuffers.removeFirst()
            totalDuration -= Double(removed.frameLength) / removed.format.sampleRate
        }
    }

    func handleSpeechStarted() {
        guard !isRecordingUtterance else { return }
        isRecordingUtterance = true
        log("Speech started detected by VAD.")
        liveTranscript = "Listening..."
        
        stopPlayback()
        onSpeechStarted?()
        
        if !prerollBuffers.isEmpty {
            let format = prerollBuffers[0].format
            do {
                try openAudioFileIfNeeded(format: format)
                for buf in prerollBuffers {
                    try audioFile?.write(from: buf)
                }
            } catch {
                log("Failed to open or write pre-roll buffers: \(error.localizedDescription)")
            }
        }
        prerollBuffers.removeAll()
        refreshStatusMessage()
    }

    func handleSpeechEnded() {
        guard isRecordingUtterance else { return }
        isRecordingUtterance = false
        log("Speech ended detected by VAD.")
        closeAudioFileIfNeeded()
    }

    private func handleSelectedLanguageChange() {
        updateSpeechVoice()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: selectedLanguage.localeIdentifier))
    }

    func updateSpeechVoice() {
        let status = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
        self.personalVoiceAuthorizationStatus = status
        
        if status == .authorized {
            self.availablePersonalVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.voiceTraits.contains(.isPersonalVoice) }
        } else {
            self.availablePersonalVoices = []
        }
        
        if usePersonalVoice, status == .authorized {
            if let pvid = selectedPersonalVoiceIdentifier, let voice = availablePersonalVoices.first(where: { $0.identifier == pvid }) {
                self.speechVoice = voice
            } else if let firstVoice = availablePersonalVoices.first {
                self.speechVoice = firstVoice
                self.selectedPersonalVoiceIdentifier = firstVoice.identifier
                userDefaults.set(firstVoice.identifier, forKey: Self.selectedPersonalVoiceIdentifierKey)
            } else {
                self.speechVoice = Self.makeSpeechVoice(for: selectedLanguage)
            }
        } else {
            self.speechVoice = Self.makeSpeechVoice(for: selectedLanguage)
        }
    }

    func setUsePersonalVoice(_ enabled: Bool) async {
        if enabled {
            let status = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
            if status == .notDetermined {
                let newStatus = await withCheckedContinuation { continuation in
                    AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                        continuation.resume(returning: status)
                    }
                }
                
                self.personalVoiceAuthorizationStatus = newStatus
                if newStatus == .authorized {
                    self.usePersonalVoice = true
                } else {
                    self.usePersonalVoice = false
                }
            } else if status == .authorized {
                self.usePersonalVoice = true
            } else {
                self.usePersonalVoice = false
            }
        } else {
            self.usePersonalVoice = false
        }
        updateSpeechVoice()
    }

    func refreshPersonalVoiceStatus() {
        updateSpeechVoice()
    }

    private func beginPlayback(with text: String) {
        if let oldURL = currentPlayingFileURL {
            try? FileManager.default.removeItem(at: oldURL)
            currentPlayingFileURL = nil
        }
        
        currentPlaybackToken?.isCancelled = true
        currentPlaybackToken = nil
        
        isPreparingPlayback = true
        statusMessage = "Preparing synthesized playback..."

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = speechVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = isSpeakersMuted ? 0.0 : 1.0

        if isWebRTCConnected {
            let destinationDir = agentResponsesDirectoryURL ?? FileManager.default.temporaryDirectory
            let fileURL = destinationDir.appendingPathComponent("agent_response_\(UUID().uuidString).wav")
            
            isPreparingPlayback = false
            isPlaybackAudible = true
            isSpeaking = true
            statusMessage = "Playing synthesized audio."
            log("Starting speech synthesis to WebRTC audio file.")
            
            let playbackToken = PlaybackToken()
            self.currentPlaybackToken = playbackToken
            
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else {
                    print("[SpeechController] [Error] Self is nil in synthesis task")
                    return
                }
                
                print("[SpeechController] Starting background synthesis task for text: '\(text)'")
                let voice = await self.speechVoice
                
                let runUtterance = AVSpeechUtterance(string: text)
                runUtterance.voice = voice
                runUtterance.rate = AVSpeechUtteranceDefaultSpeechRate
                
                try? FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
                
                // We will use a continuation to suspend this task until the callbacks finish.
                let synthesisSuccess = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    class SynthesisState {
                        var audioFile: AVAudioFile? = nil
                        var converter: AVAudioConverter? = nil
                        var bufferCount = 0
                        var writeFailed = false
                        var continuationFinished = false
                    }
                    
                    let state = SynthesisState()
                    let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
                    
                    print("[SpeechController] Invoking playbackSynthesizer.write...")
                    self.playbackSynthesizer.write(runUtterance) { (buffer: AVAudioBuffer) in
                        if playbackToken.isCancelled {
                            state.writeFailed = true
                            state.audioFile = nil
                            if !state.continuationFinished {
                                state.continuationFinished = true
                                continuation.resume(returning: false)
                            }
                            return
                        }
                        
                        guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                            print("[SpeechController] [Warning] Received non-PCM buffer")
                            return
                        }
                        
                        if pcmBuffer.frameLength == 0 {
                            print("[SpeechController] Synthesis callback: frameLength is 0 (end of stream)")
                            state.audioFile = nil // Close the file
                            if !state.continuationFinished {
                                state.continuationFinished = true
                                continuation.resume(returning: !state.writeFailed)
                            }
                            return
                        }
                        
                        state.bufferCount += 1
                        
                        if state.writeFailed {
                            return
                        }
                        
                        // Instantiate converter when the first buffer is received
                        if state.converter == nil {
                            state.converter = AVAudioConverter(from: pcmBuffer.format, to: targetFormat)
                            if state.converter == nil {
                                print("[SpeechController] [Error] Failed to create AVAudioConverter from \(pcmBuffer.format) to \(targetFormat)")
                                state.writeFailed = true
                                state.audioFile = nil
                                if !state.continuationFinished {
                                    state.continuationFinished = true
                                    continuation.resume(returning: false)
                                }
                                return
                            }
                        }
                        
                        guard let conv = state.converter else { return }
                        
                        // Perform sample rate conversion
                        let sampleRateRatio = targetFormat.sampleRate / pcmBuffer.format.sampleRate
                        let outputFrameCapacity = AVAudioFrameCount(Double(pcmBuffer.frameLength) * sampleRateRatio) + 16
                        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
                            print("[SpeechController] [Error] Failed to allocate output buffer for resampling")
                            state.writeFailed = true
                            state.audioFile = nil
                            if !state.continuationFinished {
                                state.continuationFinished = true
                                continuation.resume(returning: false)
                            }
                            return
                        }
                        
                        var error: NSError? = nil
                        var inputConsumed = false
                        let status = conv.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
                            if inputConsumed {
                                outStatus.pointee = .noDataNow
                                return nil
                            }
                            outStatus.pointee = .haveData
                            inputConsumed = true
                            return pcmBuffer
                        }
                        
                        if status == .error || error != nil {
                            print("[SpeechController] [Error] AVAudioConverter convert failed: \(error?.localizedDescription ?? "unknown error")")
                            state.writeFailed = true
                            state.audioFile = nil
                            if !state.continuationFinished {
                                state.continuationFinished = true
                                continuation.resume(returning: false)
                            }
                            return
                        }
                        
                        if outputBuffer.frameLength > 0 {
                            do {
                                if state.audioFile == nil {
                                    print("[SpeechController] Initializing AVAudioFile with target format settings: \(targetFormat.settings)")
                                    state.audioFile = try AVAudioFile(
                                        forWriting: fileURL,
                                        settings: targetFormat.settings,
                                        commonFormat: targetFormat.commonFormat,
                                        interleaved: targetFormat.isInterleaved
                                    )
                                }
                                try state.audioFile?.write(from: outputBuffer)
                            } catch {
                                print("[SpeechController] Failed to write resampled buffer #\(state.bufferCount) to file: \(error.localizedDescription)")
                                state.writeFailed = true
                                state.audioFile = nil
                                if !state.continuationFinished {
                                    state.continuationFinished = true
                                    continuation.resume(returning: false)
                                }
                            }
                        }
                    }
                }
                
                print("[SpeechController] AVSpeechSynthesizer.write callbacks finished. synthesisSuccess: \(synthesisSuccess)")
                
                let pathStr = fileURL.path(percentEncoded: false)
                let fileExists = FileManager.default.fileExists(atPath: pathStr)
                var fileSize: UInt64 = 0
                if fileExists {
                    fileSize = (try? FileManager.default.attributesOfItem(atPath: pathStr)[.size] as? UInt64) ?? 0
                }
                print("[SpeechController] File check: path='\(pathStr)', exists=\(fileExists), size=\(fileSize) bytes")
                
                await MainActor.run { [weak self] in
                    guard let self = self else {
                        print("[SpeechController] [Error] Self became nil in MainActor completion")
                        return
                    }
                    print("[SpeechController] MainActor completion block: isSpeaking=\(self.isSpeaking)")
                    guard self.isSpeaking && !playbackToken.isCancelled else {
                        print("[SpeechController] [Warning] isSpeaking is false or cancelled, aborting playback")
                        try? FileManager.default.removeItem(at: fileURL)
                        return
                    }
                    
                    if synthesisSuccess && fileExists && fileSize > 0 {
                        self.log("Speech synthesis written successfully to file: \(pathStr). Initiating WebRTC playback...")
                        self.currentPlayingFileURL = fileURL
                        
                        if let onSynthesizedFile = self.onSynthesizedFile {
                            onSynthesizedFile(fileURL) { [weak self] in
                                guard let self = self else {
                                    try? FileManager.default.removeItem(at: fileURL)
                                    return
                                }
                                guard self.isSpeaking && !playbackToken.isCancelled else {
                                    if self.currentPlayingFileURL == fileURL {
                                        self.currentPlayingFileURL = nil
                                    }
                                    try? FileManager.default.removeItem(at: fileURL)
                                    return
                                }
                                self.log("Speech synthesis playback via WebRTC finished.")
                                if self.currentPlayingFileURL == fileURL {
                                    self.currentPlayingFileURL = nil
                                }
                                self.finishPlayback(wasInterrupted: false)
                                try? FileManager.default.removeItem(at: fileURL)
                                print("[SpeechController] Deleted synthesized audio file: \(pathStr)")
                            }
                        } else {
                            print("[SpeechController] [Warning] onSynthesizedFile callback is nil")
                            if self.currentPlayingFileURL == fileURL {
                                self.currentPlayingFileURL = nil
                            }
                            self.finishPlayback(wasInterrupted: false)
                            try? FileManager.default.removeItem(at: fileURL)
                        }
                    } else {
                        print("[SpeechController] [Error] File writing failed, file does not exist, or size is 0")
                        self.finishPlayback(wasInterrupted: false)
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                }
            }
        } else {
            isPreparingPlayback = false
            isPlaybackAudible = true
            isSpeaking = true
            statusMessage = "Playing synthesized audio."
            log("Starting speech synthesis.")
            playbackSynthesizer.speak(utterance)
        }
    }

    private func openAudioFileIfNeeded(format: AVAudioFormat) throws {
        if let existingFile = audioFile {
            let fileFormat = existingFile.processingFormat
            if fileFormat.sampleRate != format.sampleRate ||
               fileFormat.channelCount != format.channelCount ||
               fileFormat.commonFormat != format.commonFormat ||
               fileFormat.isInterleaved != format.isInterleaved {
                log("Audio format changed from \(fileFormat.channelCount)ch \(fileFormat.sampleRate)Hz to \(format.channelCount)ch \(format.sampleRate)Hz. Re-creating audio file.")
                closeAudioFileIfNeeded()
            }
        }
        
        guard audioFile == nil else { return }
        
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("utterance_\(UUID().uuidString).wav")
        self.audioFileURL = fileURL
        
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
        
        audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        log("Started recording WebRTC utterance stream to: \(fileURL.path)")
        
        Task { @MainActor in
            refreshStatusMessage()
        }
    }

    private func closeAudioFileIfNeeded() {
        if audioFile != nil {
            if let fileURL = audioFileURL {
                log("Finished recording WebRTC utterance: \(fileURL.path). Now transcribing...")
                transcribeAudioFile(at: fileURL)
            }
            audioFile = nil
            audioFileURL = nil
            Task { @MainActor in
                refreshStatusMessage()
            }
        }
    }

    private func transcribeAudioFile(at url: URL) {
        if selectedASRSystem == .qwen {
            transcribeAudioFileWithQwen(at: url)
        } else {
            transcribeAudioFileWithApple(at: url)
        }
    }

    private func transcribeAudioFileWithApple(at url: URL) {
        guard let recognizer = speechRecognizer else {
            log("Speech recognizer is not initialized.")
            try? FileManager.default.removeItem(at: url)
            return
        }
        
        guard recognizer.isAvailable else {
            log("Speech recognizer is not available.")
            try? FileManager.default.removeItem(at: url)
            return
        }
        
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        
        recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            
            if let error = error {
                self.log("Speech recognition failed: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: url)
                return
            }
            
            if let result = result {
                let text = result.bestTranscription.formattedString
                self.log("Speech recognition result: \(text)")
                
                if result.isFinal {
                    Task { @MainActor in
                        self.liveTranscript = text
                        self.finalizedUtterance = TranscribedUtterance(text: text)
                    }
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    private func transcribeAudioFileWithQwen(at url: URL) {
        guard let model = qwenModel else {
            log("Qwen3 ASR is not loaded yet (state: \(qwenASRState)). Falling back to Apple Speech.")
            transcribeAudioFileWithApple(at: url)
            return
        }
        
        let language = selectedLanguage.rawValue
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            
            do {
                self.log("Loading and resampling audio for Qwen3 ASR...")
                let (_, audioArray) = try loadAudioArray(from: url, sampleRate: 16000)
                
                self.log("Running Qwen3 ASR generation...")
                let output = model.generate(audio: audioArray, language: language)
                let text = output.text
                
                self.log("Qwen3 ASR Result: \(text)")
                
                await MainActor.run {
                    self.liveTranscript = text
                    self.finalizedUtterance = TranscribedUtterance(text: text)
                }
            } catch {
                self.log("Qwen3 ASR transcription failed: \(error.localizedDescription)")
            }
            
            try? FileManager.default.removeItem(at: url)
        }
    }

    func loadQwenModel() {
        print("[Qwen3 ASR] loadQwenModel called. State is: \(qwenASRState)")
        
        guard qwenASRState == .idle || {
            if case .failed = qwenASRState { return true }
            return false
        }() else {
            print("[Qwen3 ASR] loadQwenModel ignored because state is not idle or failed.")
            return
        }
        
        qwenASRState = .downloading(progress: 0.0, completedBytes: 0, totalBytes: 0)
        
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                print("[Qwen3 ASR] Detached download task started.")
                let hfToken: String? = ProcessInfo.processInfo.environment["HF_TOKEN"]
                    ?? Bundle.main.object(forInfoDictionaryKey: "HF_TOKEN") as? String
                
                guard let repoID = Repo.ID(rawValue: "mlx-community/Qwen3-ASR-1.7B-bf16") else {
                    throw NSError(
                        domain: "SpeechController",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid repository ID: mlx-community/Qwen3-ASR-1.7B-bf16"]
                    )
                }
                
                print("[Qwen3 ASR] Setting up custom URLSession with 4 min request timeouts...")
                let clientConfiguration = URLSessionConfiguration.default
                clientConfiguration.timeoutIntervalForRequest = 240.0 // 4 minutes
                clientConfiguration.timeoutIntervalForResource = 7200.0 // 2 hours
                clientConfiguration.urlCache = nil
                clientConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                clientConfiguration.httpShouldUsePipelining = true
                let session = URLSession(configuration: clientConfiguration)
                
                print("[Qwen3 ASR] Initializing HubClient...")
                let client: HubClient
                if let token = hfToken, !token.isEmpty {
                    client = HubClient(
                        session: session,
                        host: HubClient.defaultHost,
                        bearerToken: token,
                        cache: .default
                    )
                } else {
                    client = HubClient(
                        session: session,
                        cache: .default
                    )
                }
                
                let modelSubdir = repoID.description.replacingOccurrences(of: "/", with: "_")
                let modelDir = HubCache.default.cacheDirectory
                    .appendingPathComponent("mlx-audio")
                    .appendingPathComponent(modelSubdir)
                
                print("[Qwen3 ASR] Model directory resolved: \(modelDir.path)")
                try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
                
                print("[Qwen3 ASR] Querying repository file list from Hugging Face...")
                let allEntries = try await client.listFiles(in: repoID, kind: .model, revision: "main", recursive: true)
                print("[Qwen3 ASR] Retrieved file list containing \(allEntries.count) entries.")
                
                let filesToDownload = allEntries.filter { entry in
                    let ext = URL(fileURLWithPath: entry.path).pathExtension.lowercased()
                    return ext == "safetensors" || ext == "json" || ext == "txt"
                }
                
                let totalBytes = filesToDownload.reduce(0) { $0 + Int64($1.size ?? 0) }
                print("[Qwen3 ASR] Found \(filesToDownload.count) files to download (Total size: \(totalBytes) bytes)")
                
                let aggregator = ProgressAggregator(totalBytes: totalBytes) { completed, speed in
                    let fraction = totalBytes > 0 ? Double(completed) / Double(totalBytes) : 0.0
                    let speedMB = speed / (1024.0 * 1024.0)
                    print("[Qwen3 ASR] Download progress update: \(completed) / \(totalBytes) bytes (\(String(format: "%.1f", fraction * 100))%) - Speed: \(String(format: "%.2f", speedMB)) MB/s")
                    Task { @MainActor [weak self] in
                        self?.qwenASRState = .downloading(progress: fraction, completedBytes: completed, totalBytes: totalBytes)
                    }
                }
                
                // Sequential download of files directly via custom stream downloader to avoid lock conflicts or system download task timeouts
                print("[Qwen3 ASR] Downloading files sequentially...")
                for entry in filesToDownload {
                    let destination = modelDir.appendingPathComponent(entry.path)
                    let fileWeight = Int64(entry.size ?? 0)
                    
                    // Check if file is already fully downloaded or partially downloaded
                    var existingSize: Int64 = 0
                    if FileManager.default.fileExists(atPath: destination.path) {
                        if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
                           let size = attributes[.size] as? Int64 {
                            if size == fileWeight {
                                print("[Qwen3 ASR] [File] Already cached: \(entry.path)")
                                aggregator.update(file: entry.path, completed: fileWeight)
                                continue
                            } else {
                                existingSize = size
                            }
                        }
                    }
                    
                    let directory = destination.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    
                    let url = URL(string: "https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-bf16/resolve/main/\(entry.path)")!
                    var request = URLRequest(url: url)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    if let token = hfToken, !token.isEmpty {
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    
                    if existingSize > 0 {
                        print("[Qwen3 ASR] [File] Resuming download for \(entry.path) from \(existingSize) bytes...")
                        request.setValue("bytes=\(existingSize)-", forHTTPHeaderField: "Range")
                        aggregator.update(file: entry.path, completed: existingSize)
                    } else {
                        print("[Qwen3 ASR] [File] Downloading: \(entry.path) (\(fileWeight) bytes)")
                    }
                    
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        let downloader = DataTaskStreamDownloader(
                            destination: destination,
                            resumeOffset: existingSize,
                            onProgress: { completed, _ in
                                aggregator.update(file: entry.path, completed: completed)
                            },
                            onComplete: {
                                continuation.resume()
                            },
                            onError: { error in
                                continuation.resume(throwing: error)
                            }
                        )
                        
                        let delegateQueue = OperationQueue()
                        delegateQueue.qualityOfService = .userInitiated
                        let taskSession = URLSession(configuration: clientConfiguration, delegate: downloader, delegateQueue: delegateQueue)
                        downloader.session = taskSession
                        
                        let task = taskSession.dataTask(with: request)
                        task.resume()
                    }
                    
                    print("[Qwen3 ASR] [File] Finished: \(entry.path)")
                    aggregator.update(file: entry.path, completed: fileWeight)
                }
                
                print("[Qwen3 ASR] All files successfully resolved. Loading weights into memory...")
                Task { @MainActor [weak self] in
                    self?.qwenASRState = .loading
                }
                
                let model = try await Qwen3ASRModel.fromModelDirectory(modelDir)
                
                Task { @MainActor [weak self] in
                    self?.qwenModel = model
                    self?.qwenASRState = .ready
                    self?.log("Qwen3 ASR model loaded successfully and ready.")
                    print("[Qwen3 ASR] Model is fully loaded and ready.")
                }
            } catch {
                print("[Qwen3 ASR] Error occurred: \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.qwenASRState = .failed(message: error.localizedDescription)
                    self?.log("Failed to load Qwen3 ASR: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleASRSystemChange() {
        if selectedASRSystem == .qwen {
            loadQwenModel()
        }
    }

    deinit {
        if let fileURL = currentPlayingFileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func stopPlayback() {
        guard isPreparingPlayback || isSpeaking || isPlaybackAudible else {
            return
        }

        log("Stopping playback.")
        
        currentPlaybackToken?.isCancelled = true
        currentPlaybackToken = nil
        
        if let fileURL = currentPlayingFileURL {
            try? FileManager.default.removeItem(at: fileURL)
            currentPlayingFileURL = nil
            print("[SpeechController] Deleted current playing file: \(fileURL.path)")
        }
        
        if isWebRTCConnected {
            onStopPlayback?()
            finishPlayback(wasInterrupted: true)
        } else {
            if !playbackSynthesizer.stopSpeaking(at: .immediate) {
                finishPlayback(wasInterrupted: true)
            }
        }
    }

    private func finishPlayback(wasInterrupted: Bool) {
        isPreparingPlayback = false
        isPlaybackAudible = false
        isSpeaking = false

        refreshStatusMessage()
    }

    private func muteMicrophone() {
        guard !isMicrophoneMuted else {
            return
        }

        isMicrophoneMuted = true
        closeAudioFileIfNeeded()
    }

    private func unmuteMicrophone() {
        guard isMicrophoneMuted else {
            return
        }

        isMicrophoneMuted = false
        refreshStatusMessage()
    }

    private func refreshStatusMessage() {
        if isMicrophoneMuted {
            statusMessage = "Recording is paused."
        } else if isPlaybackAudible || isPreparingPlayback {
            statusMessage = "Playback is active."
        } else if let fileURL = audioFileURL {
            statusMessage = "Recording to glosos-user/\(fileURL.lastPathComponent)..."
        } else {
            statusMessage = "Ready to record incoming WebRTC audio."
        }
    }

    nonisolated private static func formatLog(_ message: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        return "[VoiceStop] [\(timestamp)] \(message)"
    }

    nonisolated private func log(_ message: String) {
        print(SpeechController.formatLog(message))
    }

    private static func loadSavedLanguage(from userDefaults: UserDefaults) -> SpeechLanguage {
        guard let rawValue = userDefaults.string(forKey: selectedLanguageKey),
              let language = SpeechLanguage(rawValue: rawValue) else {
            return .defaultValue
        }

        return language
    }

    private static func makeSpeechVoice(for language: SpeechLanguage) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: language.localeIdentifier)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard synthesizer === playbackSynthesizer, !isWebRTCConnected else {
            return
        }

        log("Speech synthesis started.")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard synthesizer === playbackSynthesizer, !isWebRTCConnected else {
            return
        }

        log("Speech synthesis finished.")
        finishPlayback(wasInterrupted: false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard synthesizer === playbackSynthesizer, !isWebRTCConnected else {
            return
        }

        log("Speech synthesis cancelled.")
        finishPlayback(wasInterrupted: true)
    }
}

final class PlaybackToken {
    private let lock = NSLock()
    private var _isCancelled = false
    
    var isCancelled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isCancelled
        }
        set {
            lock.lock()
            _isCancelled = newValue
            lock.unlock()
        }
    }
}

final class ProgressAggregator: @unchecked Sendable {
    private let lock = NSLock()
    private var completedBytesByFile: [String: Int64] = [:]
    private var lastReportedPercent: Double = -1.0
    private var startTime: Date?
    let totalBytes: Int64
    let onProgress: @Sendable (Int64, Double) -> Void
    
    init(totalBytes: Int64, onProgress: @escaping @Sendable (Int64, Double) -> Void) {
        self.totalBytes = totalBytes
        self.onProgress = onProgress
    }
    
    func update(file: String, completed: Int64) {
        lock.lock()
        if startTime == nil && completed > 0 {
            startTime = Date()
        }
        completedBytesByFile[file] = completed
        let totalCompleted = completedBytesByFile.values.reduce(0, +)
        let percent = totalBytes > 0 ? (Double(totalCompleted) / Double(totalBytes)) * 100.0 : 0.0
        
        let shouldReport = (percent - lastReportedPercent >= 0.5) || (percent >= 100.0 && lastReportedPercent < 100.0)
        if shouldReport {
            lastReportedPercent = percent
            let duration = Date().timeIntervalSince(startTime ?? Date())
            let speed = duration > 0 ? Double(totalCompleted) / duration : 0.0
            lock.unlock()
            onProgress(totalCompleted, speed)
        } else {
            lock.unlock()
        }
    }
}

final class DataTaskStreamDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let resumeOffset: Int64
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let onComplete: @Sendable () -> Void
    private let onError: @Sendable (Error) -> Void
    
    weak var session: URLSession?
    private var fileHandle: FileHandle?
    private var totalBytesExpected: Int64 = 0
    private var totalBytesWritten: Int64 = 0
    private var firstChunkReceived = false
    private let lock = NSLock()
    
    private var writeBuffer = Data()
    private let maxBufferSize = 512 * 1024 // 512 KB buffer
    
    init(
        destination: URL,
        resumeOffset: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        self.destination = destination
        self.resumeOffset = resumeOffset
        self.onProgress = onProgress
        self.onComplete = onComplete
        self.onError = onError
    }
    
    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        let httpResponse = response as? HTTPURLResponse
        let isPartial = httpResponse?.statusCode == 206
        
        if isPartial {
            totalBytesExpected = response.expectedContentLength + resumeOffset
            totalBytesWritten = resumeOffset
        } else {
            totalBytesExpected = response.expectedContentLength
            totalBytesWritten = 0
        }
        
        let directory = destination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        if !isPartial {
            try? FileManager.default.removeItem(at: destination)
            FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: nil)
        }
        
        do {
            let handle = try FileHandle(forWritingTo: destination)
            if isPartial {
                try handle.seekToEnd()
            }
            fileHandle = handle
            lock.unlock()
            completionHandler(.allow)
        } catch {
            lock.unlock()
            completionHandler(.cancel)
            onError(error)
        }
    }
    
    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        if !firstChunkReceived {
            firstChunkReceived = true
            print("[Qwen3 ASR] [File] First chunk received (\(data.count) bytes). Resumed: \(resumeOffset > 0)")
        }
        
        writeBuffer.append(data)
        totalBytesWritten += Int64(data.count)
        
        if writeBuffer.count >= maxBufferSize {
            let bufferToWrite = writeBuffer
            writeBuffer = Data()
            
            guard let fileHandle = fileHandle else {
                lock.unlock()
                return
            }
            
            do {
                try fileHandle.write(contentsOf: bufferToWrite)
                lock.unlock()
                onProgress(totalBytesWritten, totalBytesExpected)
            } catch {
                lock.unlock()
                onError(error)
            }
        } else {
            lock.unlock()
            onProgress(totalBytesWritten, totalBytesExpected)
        }
    }
    
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        if !writeBuffer.isEmpty, let fileHandle = fileHandle {
            do {
                try fileHandle.write(contentsOf: writeBuffer)
            } catch {
                print("[Qwen3 ASR] Failed to flush final write buffer: \(error.localizedDescription)")
            }
            writeBuffer = Data()
        }
        
        try? fileHandle?.close()
        fileHandle = nil
        lock.unlock()
        
        session?.invalidateAndCancel()
        
        if let error = error {
            onError(error)
        } else {
            onComplete()
        }
    }
}
