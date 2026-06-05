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
    @Published private(set) var statusMessage = "Listening to the microphone and transcribing live."
    @Published private(set) var liveTranscript = "Waiting for speech..."
    @Published private(set) var finalizedUtterance: TranscribedUtterance?
    @Published private(set) var playbackInterruptionToken: UUID?

    private let playbackSynthesizer = AVSpeechSynthesizer()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let speechVoice = AVSpeechSynthesisVoice(language: "en-US")
    private let voiceProcessingIO: VoiceProcessingIO
    private let sileroVADProcessor: SileroVADProcessor

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasPreparedPermissions = false
    private var canListenForTranscription = false
    private var isListeningContinuously = false
    private var isShuttingDownListener = false
    private var isPreparingPlayback = false
    private var isPlaybackAudible = false
    private var lastLoggedTranscript = ""
    private var shouldKeepListening = false
    private var listenerRestartTask: Task<Void, Never>?
    private var vadSpeechEndTask: Task<Void, Never>?
    private var speechTurnCoordinator = SpeechTurnCoordinator()

    override init() {
        sileroVADProcessor = SileroVADProcessor(logHandler: { message in
            print("[VoiceStop] \(message)")
        })
        voiceProcessingIO = VoiceProcessingIO(logHandler: { message in
            print("[VoiceStop] \(message)")
        })
        super.init()
        playbackSynthesizer.delegate = self
        sileroVADProcessor.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                self?.handleVADSpeechStarted()
            }
        }
        sileroVADProcessor.onSpeechEnded = { [weak self] in
            Task { @MainActor in
                self?.handleVADSpeechEnded()
            }
        }
        sileroVADProcessor.loadModelIfNeeded()
    }

    var isCapturingSpeech: Bool {
        !displayedLiveTranscript.isEmpty
    }

    var displayedLiveTranscript: String {
        switch liveTranscript {
        case "Waiting for speech...", "Listening...", "Microphone permission is required.":
            return ""
        default:
            return liveTranscript
        }
    }

    func preparePermissions() async {
        guard !hasPreparedPermissions else {
            return
        }

        hasPreparedPermissions = true

        let speechStatus = await requestSpeechAuthorization()
        let microphoneGranted = await requestMicrophonePermission()
        let recognizerAvailable = speechRecognizer?.isAvailable == true

        log("Speech auth: \(describe(speechStatus))")
        log("Microphone auth: \(microphoneGranted ? "granted" : "denied")")
        log("Recognizer available: \(recognizerAvailable)")
        sileroVADProcessor.loadModelIfNeeded()

        canListenForTranscription = speechStatus == .authorized && microphoneGranted && recognizerAvailable

        if canListenForTranscription {
            statusMessage = "Listening to the microphone and transcribing live."
        } else {
            statusMessage = "Microphone and Speech Recognition access are needed for live transcription."
            liveTranscript = "Microphone permission is required."
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
        await preparePermissions()
        guard canListenForTranscription else {
            return
        }

        shouldKeepListening = true
        guard !isListeningContinuously else {
            return
        }

        do {
            try startRecognitionSession()
        } catch {
            log("Failed to start continuous transcription: \(error.localizedDescription)")
            statusMessage = "Live transcription is unavailable right now."
        }
    }

    func stopContinuousListening() {
        shouldKeepListening = false
        listenerRestartTask?.cancel()
        listenerRestartTask = nil
        vadSpeechEndTask?.cancel()
        vadSpeechEndTask = nil
        stopListening(reason: "view disappeared", shouldLog: false)
    }

    private func beginPlayback(with text: String) {
        isPreparingPlayback = true
        statusMessage = "Preparing synthesized playback..."

        if canListenForTranscription, shouldKeepListening, !isListeningContinuously {
            do {
                try startRecognitionSession()
            } catch {
                log("Could not restart listener before playback: \(error.localizedDescription)")
            }
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = speechVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        isPreparingPlayback = false
        isPlaybackAudible = true
        isSpeaking = true
        statusMessage = canListenForTranscription
            ? "Playback is active. Any spoken word will interrupt it."
            : "Playing synthesized audio."
        log("Starting speech synthesis.")
        playbackSynthesizer.speak(utterance)
    }

    private func startRecognitionSession() throws {
        stopListening(reason: "reset before starting", shouldLog: false)

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw VoiceStopError.recognizerUnavailable
        }

        speechTurnCoordinator.reset()
        vadSpeechEndTask?.cancel()
        vadSpeechEndTask = nil

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.addsPunctuation = false
        recognitionRequest.taskHint = .dictation
        recognitionRequest.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition
        self.recognitionRequest = recognitionRequest
        log("Requires on-device recognition: \(recognitionRequest.requiresOnDeviceRecognition)")

        try voiceProcessingIO.startIfNeeded()
        voiceProcessingIO.setRecognitionRequest(recognitionRequest)
        voiceProcessingIO.setCapturedSamplesHandler { [sileroVADProcessor] samples, sampleRate in
            sileroVADProcessor.append(samples: samples, sampleRate: sampleRate)
        }
        sileroVADProcessor.loadModelIfNeeded()
        sileroVADProcessor.resetSession()

        isListeningContinuously = true
        isShuttingDownListener = false
        lastLoggedTranscript = ""
        log("Microphone capture started.")
        liveTranscript = "Listening..."

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }

            let isFinal = result?.isFinal == true
            if let transcript = result?.bestTranscription.formattedString, !transcript.isEmpty {
                Task { @MainActor in
                    self.handleTranscript(transcript, isFinal: isFinal)
                }
            }

            if let error {
                Task { @MainActor in
                    self.handleRecognitionError(error)
                }
            }

            if let result {
                self.log("Recognition result received. isFinal=\(result.isFinal)")
            }

            if error != nil || isFinal {
                Task { @MainActor in
                    self.handleRecognitionSessionEnded(error: error, isFinal: isFinal)
                }
            }
        }
    }

    private func handleRecognitionSessionEnded(error: Error?, isFinal: Bool) {
        finalizePendingVADSpeechSegment(force: true)
        stopListening(reason: "recognition completed", shouldLog: error == nil && isFinal)

        guard shouldKeepListening else {
            return
        }

        if isPlaybackAudible || isPreparingPlayback {
            log("Deferring listener restart until playback becomes idle.")
            return
        }

        restartListeningAfterDelay()
    }

    private func handleTranscript(_ transcript: String, isFinal: Bool) {
        if transcript == lastLoggedTranscript, !isFinal {
            return
        }

        lastLoggedTranscript = transcript
        log("Transcript: \(transcript)")
        liveTranscript = transcript

        let update = speechTurnCoordinator.recordTranscript(
            transcript,
            hasRecognizedContent: hasRecognizedContent(in: transcript),
            usingVAD: sileroVADProcessor.isReady,
            isFinal: isFinal,
            isPlaybackAudible: isPlaybackAudible
        )
        applySpeechTurnUpdate(update, interruptionLogMessage: "Detected spoken interruption in transcript.")
    }

    private func stopPlayback() {
        guard isPreparingPlayback || isSpeaking || isPlaybackAudible else {
            return
        }

        log("Stopping playback.")
        if !sileroVADProcessor.isReady, shouldKeepListening, isListeningContinuously {
            stopListening(reason: "refreshing recognition after interruption", shouldLog: false)
        }
        if !playbackSynthesizer.stopSpeaking(at: .immediate) {
            finishPlayback(wasInterrupted: true)
        }
    }

    private func finishPlayback(wasInterrupted: Bool) {
        isPreparingPlayback = false
        isPlaybackAudible = false
        isSpeaking = false

        if !isListeningContinuously {
            voiceProcessingIO.stop()
        }

        statusMessage = shouldKeepListening
            ? "Listening to the microphone and transcribing live."
            : (wasInterrupted ? "Playback stopped." : "Playback finished.")

        if shouldKeepListening, !isListeningContinuously {
            restartListeningAfterDelay()
        }
    }

    private func stopListening(reason: String, shouldLog: Bool = true) {
        let hasActiveListener = isListeningContinuously || recognitionTask != nil || recognitionRequest != nil || voiceProcessingIO.isRunning
        guard hasActiveListener, !isShuttingDownListener else {
            return
        }

        isShuttingDownListener = true

        if shouldLog {
            log("Stopping voice-stop listener. Reason: \(reason)")
        }

        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        voiceProcessingIO.setRecognitionRequest(nil)
        voiceProcessingIO.setCapturedSamplesHandler(nil)
        sileroVADProcessor.resetSession()
        vadSpeechEndTask?.cancel()
        vadSpeechEndTask = nil
        speechTurnCoordinator.reset()

        if !isPlaybackAudible, !isPreparingPlayback {
            voiceProcessingIO.stop()
        }

        isListeningContinuously = false
        isShuttingDownListener = false
        lastLoggedTranscript = ""
    }

    private func handleRecognitionError(_ error: Error) {
        if isShuttingDownListener {
            return
        }

        let nsError = error as NSError
        let noSpeechDetected = error.localizedDescription == "No speech detected"

        if noSpeechDetected {
            log("Ignoring expected recognition cancellation: \(error.localizedDescription)")
            return
        }

        log("Recognition error [\(nsError.domain):\(nsError.code)]: \(error.localizedDescription)")
    }

    private func restartListeningAfterDelay() {
        listenerRestartTask?.cancel()
        listenerRestartTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self.listenerRestartTask = nil
                guard self.shouldKeepListening, !self.isListeningContinuously, !self.isPreparingPlayback, !self.isPlaybackAudible else {
                    return
                }

                do {
                    try self.startRecognitionSession()
                } catch {
                    self.log("Failed to restart continuous transcription: \(error.localizedDescription)")
                    self.statusMessage = "Transcription stopped and could not restart."
                }
            }
        }
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func hasRecognizedContent(in transcript: String) -> Bool {
        transcript.contains { !$0.isWhitespace && !$0.isPunctuation }
    }

    private func handleVADSpeechStarted() {
        vadSpeechEndTask?.cancel()
        vadSpeechEndTask = nil
        let update = speechTurnCoordinator.speechStarted(
            isPlaybackAudible: isPlaybackAudible,
            now: Date().timeIntervalSinceReferenceDate
        )
        applySpeechTurnUpdate(update, interruptionLogMessage: "Detected spoken interruption from Silero VAD.")
    }

    private func handleVADSpeechEnded() {
        let update = speechTurnCoordinator.speechEnded(now: Date().timeIntervalSinceReferenceDate)
        applySpeechTurnUpdate(update, interruptionLogMessage: nil)

        vadSpeechEndTask?.cancel()
        vadSpeechEndTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                self?.finalizePendingVADSpeechSegment()
            }
        }
    }

    private func finalizePendingVADSpeechSegment(force: Bool = false) {
        let update = speechTurnCoordinator.finalizePendingSpeechIfNeeded(
            now: Date().timeIntervalSinceReferenceDate,
            force: force
        )
        applySpeechTurnUpdate(update, interruptionLogMessage: nil)
    }

    private func applySpeechTurnUpdate(_ update: SpeechTurnUpdate, interruptionLogMessage: String?) {
        if update.shouldInterruptPlayback {
            playbackInterruptionToken = UUID()
            if let interruptionLogMessage {
                log(interruptionLogMessage)
            }
            stopPlayback()
        }

        if let finalizedText = update.finalizedText {
            finalizedUtterance = TranscribedUtterance(text: finalizedText)
        }

        if update.shouldClearTranscript {
            liveTranscript = "Waiting for speech..."
        }
    }

    private func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "notDetermined"
        @unknown default:
            return "unknown"
        }
    }

    nonisolated private func log(_ message: String) {
        print("[VoiceStop] \(message)")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard synthesizer === playbackSynthesizer else {
            return
        }

        log("Speech synthesis started.")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard synthesizer === playbackSynthesizer else {
            return
        }

        log("Speech synthesis finished.")
        finishPlayback(wasInterrupted: false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard synthesizer === playbackSynthesizer else {
            return
        }

        log("Speech synthesis cancelled.")
        finishPlayback(wasInterrupted: true)
    }
}
