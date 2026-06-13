//
//  SpeechController.swift
//  glosos-macOS
//
//  Created by EV on 6/3/26.
//

import AVFoundation
import Combine
import Speech

@MainActor
final class SpeechController: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isMicrophoneMuted = false
    @Published private(set) var isSpeakersMuted = true
    @Published private(set) var statusMessage = "Ready to record incoming WebRTC audio."
    @Published private(set) var liveTranscript = ""
    @Published var finalizedUtterance: TranscribedUtterance? = nil
    @Published private(set) var playbackInterruptionToken: UUID? = nil

    @Published var selectedLanguage: SpeechLanguage {
        didSet {
            guard selectedLanguage != oldValue else {
                return
            }

            userDefaults.set(selectedLanguage.rawValue, forKey: Self.selectedLanguageKey)
            handleSelectedLanguageChange()
        }
    }

    @Published var isWebRTCConnected = false {
        didSet {
            playbackSynthesizer.delegate = isWebRTCConnected ? nil : self
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

    private var vadProcessor: SileroVADProcessor?
    private var isRecordingUtterance = false
    private var prerollBuffers: [AVAudioPCMBuffer] = []
    private let maxPrerollDuration: TimeInterval = 0.8

    init(userDefaults: UserDefaults = .standard) {
        let selectedLanguage = Self.loadSavedLanguage(from: userDefaults)
        self.userDefaults = userDefaults
        self.selectedLanguage = selectedLanguage
        self.speechVoice = Self.makeSpeechVoice(for: selectedLanguage)
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: selectedLanguage.localeIdentifier))
        super.init()
        playbackSynthesizer.delegate = self
        
        self.vadProcessor = SileroVADProcessor(logHandler: { message in
            print("[VoiceStop] [VAD] \(message)")
        })
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
        speechVoice = Self.makeSpeechVoice(for: selectedLanguage)
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: selectedLanguage.localeIdentifier))
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

    nonisolated private func log(_ message: String) {
        print("[VoiceStop] \(message)")
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
