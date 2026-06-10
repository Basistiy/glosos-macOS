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
    var onStopPlayback: (() -> Void)?

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

    var isReadyForLiveTranscription: Bool {
        canListenForTranscription
    }

    func refreshPermissionState() {
        // Speech authorization can be checked, but we request it in preparePermissions
    }

    func preparePermissions() async {
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
        isPreparingPlayback = true
        statusMessage = "Preparing synthesized playback..."

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = speechVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        if isWebRTCConnected {
            isPreparingPlayback = false
            isPlaybackAudible = true
            isSpeaking = true
            statusMessage = "Playing synthesized audio."
            log("Starting speech synthesis to WebRTC buffer.")
            
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else { return }
                
                var pcmBuffers: [AVAudioPCMBuffer] = []
                let voice = await self.speechVoice
                
                let runUtterance = AVSpeechUtterance(string: text)
                runUtterance.voice = voice
                runUtterance.rate = AVSpeechUtteranceDefaultSpeechRate
                
                await self.playbackSynthesizer.write(runUtterance) { (buffer: AVAudioBuffer) in
                    if let pcmBuffer = buffer as? AVAudioPCMBuffer, pcmBuffer.frameLength > 0 {
                        pcmBuffers.append(pcmBuffer)
                    }
                }
                
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    guard self.isSpeaking else { return }
                    
                    if let onSynthesizedBuffers = self.onSynthesizedBuffers {
                        onSynthesizedBuffers(pcmBuffers) { [weak self] in
                            guard let self = self else { return }
                            guard self.isSpeaking else { return }
                            self.log("Speech synthesis playback via WebRTC finished.")
                            self.finishPlayback(wasInterrupted: false)
                        }
                    } else {
                        self.finishPlayback(wasInterrupted: false)
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

    private func stopPlayback() {
        guard isPreparingPlayback || isSpeaking || isPlaybackAudible else {
            return
        }

        log("Stopping playback.")
        
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
