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
final class SpeechController: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var statusMessage = "Listening to the microphone and transcribing live."
    @Published private(set) var liveTranscript = "Waiting for speech..."

    private let renderingSynthesizer = AVSpeechSynthesizer()
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
    private var currentPlaybackToken: UUID?
    private var currentPlaybackFileURL: URL?
    private var listenerRestartTask: Task<Void, Never>?

    override init() {
        voiceProcessingIO = VoiceProcessingIO(logHandler: { message in
            print("[VoiceStop] \(message)")
        })
        super.init()
        voiceProcessingIO.playbackCompletionHandler = { [weak self] playbackToken in
            DispatchQueue.main.async {
                self?.handlePlaybackCompletion(for: playbackToken)
            }
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
            await beginPlayback(with: trimmedText)
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

    private func beginPlayback(with text: String) async {
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

        do {
            let renderedPlayback = try await renderPlayback(for: utterance)
            try startPlayback(for: renderedPlayback)
        } catch {
            isPreparingPlayback = false
            isSpeaking = false
            isPlaybackAudible = false
            log("Playback preparation failed: \(error.localizedDescription)")
            statusMessage = "Playback could not start."
        }
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
        voiceProcessingIO.stopPlayback()
        finishPlayback(wasInterrupted: true)
    }

    private func finishPlayback(wasInterrupted: Bool) {
        isPreparingPlayback = false
        isPlaybackAudible = false
        isSpeaking = false
        currentPlaybackToken = nil

        cleanupPlaybackFile()

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

    private func renderPlayback(for utterance: AVSpeechUtterance) async throws -> RenderedPlayback {
        let fileURL = makePlaybackFileURL()

        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var didResume = false
            var audioFile: AVAudioFile?

            func resume(with result: Result<RenderedPlayback, Error>) {
                lock.lock()
                defer { lock.unlock() }

                guard !didResume else {
                    return
                }

                didResume = true
                continuation.resume(with: result)
            }

            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                if (error as NSError).code != NSFileNoSuchFileError {
                    resume(with: .failure(error))
                    return
                }
            }

            log("Rendering synthesized speech to \(fileURL.lastPathComponent).")
            renderingSynthesizer.write(utterance, toBufferCallback: { buffer in
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                    resume(with: .failure(VoiceStopError.unexpectedSynthesisBuffer))
                    return
                }

                if pcmBuffer.frameLength == 0 {
                    resume(with: .success(RenderedPlayback(fileURL: fileURL)))
                    return
                }

                do {
                    if audioFile == nil {
                        audioFile = try AVAudioFile(
                            forWriting: fileURL,
                            settings: pcmBuffer.format.settings,
                            commonFormat: pcmBuffer.format.commonFormat,
                            interleaved: pcmBuffer.format.isInterleaved
                        )
                    }

                    try audioFile?.write(from: pcmBuffer)
                } catch {
                    resume(with: .failure(error))
                }
            })
        }
    }

    private func startPlayback(for renderedPlayback: RenderedPlayback) throws {
        let playbackToken = UUID()

        cleanupPlaybackFile()
        currentPlaybackFileURL = renderedPlayback.fileURL
        currentPlaybackToken = playbackToken

        try voiceProcessingIO.startIfNeeded()
        try voiceProcessingIO.schedulePlayback(from: renderedPlayback.fileURL, playbackToken: playbackToken)

        isPreparingPlayback = false
        isPlaybackAudible = true
        isSpeaking = true
        statusMessage = canListenForTranscription
            ? "Playback is active. Any spoken word will interrupt it."
            : "Playing synthesized audio."
        log("Speech playback started from VoiceProcessingIO.")
    }

    private func handlePlaybackCompletion(for playbackToken: UUID) {
        guard currentPlaybackToken == playbackToken else {
            return
        }

        log("Speech playback finished.")
        finishPlayback(wasInterrupted: false)
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

    private func cleanupPlaybackFile() {
        guard let currentPlaybackFileURL else {
            return
        }

        do {
            try FileManager.default.removeItem(at: currentPlaybackFileURL)
        } catch {
            if (error as NSError).code != NSFileNoSuchFileError {
                log("Failed to remove rendered playback file: \(error.localizedDescription)")
            }
        }

        self.currentPlaybackFileURL = nil
    }

    private func makePlaybackFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("glosos-tts-\(UUID().uuidString)")
            .appendingPathExtension("caf")
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
}

private struct RenderedPlayback {
    let fileURL: URL
}
