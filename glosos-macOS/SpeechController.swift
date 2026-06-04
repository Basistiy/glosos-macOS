//
//  SpeechController.swift
//  glosos-macOS
//
//  Created by EV on 6/3/26.
//

import AVFoundation
import Combine
import Speech
import SwiftUI

@MainActor
final class SpeechController: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var statusMessage = "Listening to the microphone and transcribing live."
    @Published private(set) var liveTranscript = "Waiting for speech..."

    private let playbackSynthesizer = AVSpeechSynthesizer()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let speechVoice = AVSpeechSynthesisVoice(language: "en-US")
    private let voiceProcessingIO: VoiceProcessingIO

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

    override init() {
        voiceProcessingIO = VoiceProcessingIO(logHandler: { message in
            print("[VoiceStop] \(message)")
        })
        super.init()
        playbackSynthesizer.delegate = self
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

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.addsPunctuation = false
        recognitionRequest.taskHint = .dictation
        recognitionRequest.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition
        self.recognitionRequest = recognitionRequest
        log("Requires on-device recognition: \(recognitionRequest.requiresOnDeviceRecognition)")

        try voiceProcessingIO.startIfNeeded()
        voiceProcessingIO.setRecognitionRequest(recognitionRequest)

        isListeningContinuously = true
        isShuttingDownListener = false
        lastLoggedTranscript = ""
        log("Microphone capture started.")
        liveTranscript = "Listening..."

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }

            if let transcript = result?.bestTranscription.formattedString, !transcript.isEmpty {
                Task { @MainActor in
                    self.handleTranscript(transcript)
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

            if error != nil || result?.isFinal == true {
                Task { @MainActor in
                    self.handleRecognitionSessionEnded(error: error, isFinal: result?.isFinal == true)
                }
            }
        }
    }

    private func handleRecognitionSessionEnded(error: Error?, isFinal: Bool) {
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

    private func handleTranscript(_ transcript: String) {
        if transcript == lastLoggedTranscript {
            return
        }

        lastLoggedTranscript = transcript
        log("Transcript: \(transcript)")
        liveTranscript = transcript

        guard isPlaybackAudible else {
            return
        }

        let hasRecognizedContent = transcript.contains { !$0.isWhitespace && !$0.isPunctuation }
        guard hasRecognizedContent else {
            return
        }

        log("Detected spoken interruption in transcript.")
        stopPlayback()
    }

    private func stopPlayback() {
        guard isPreparingPlayback || isSpeaking || isPlaybackAudible else {
            return
        }

        log("Stopping playback.")
        // Recycling the recognizer after a barge-in has been more reliable than
        // keeping the same partial-results stream alive across interruptions.
        if shouldKeepListening, isListeningContinuously {
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
            : (wasInterrupted ? "Playback stopped. Press Play to start again." : "Playback finished. Press Play to listen again.")

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
