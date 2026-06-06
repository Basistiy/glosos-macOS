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
final class SpeechController: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate, @preconcurrency AVAudioPlayerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isMicrophoneMuted = false
    @Published private(set) var statusMessage = "Listening to the microphone and transcribing live."
    @Published private(set) var liveTranscript = "Waiting for speech..."
    @Published private(set) var finalizedUtterance: TranscribedUtterance?
    @Published private(set) var playbackInterruptionToken: UUID?
    @Published private(set) var activePreviewClipID: UUID?

    private let playbackSynthesizer = AVSpeechSynthesizer()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let speechVoice = AVSpeechSynthesisVoice(language: "en-US")
    private let voiceProcessingIO: VoiceProcessingIO
    private let sileroVADProcessor: SileroVADProcessor
    private let speechSegmentRecorder: LockedSpeechSegmentRecorder
    private let clipStorageDirectory: URL

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var previewAudioPlayer: AVAudioPlayer?
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
    private var previewPlaybackCoordinator = AudioClipPreviewCoordinator()
    private var shouldResumeListeningAfterPreviewPlayback = false

    override init() {
        speechSegmentRecorder = LockedSpeechSegmentRecorder(sampleRate: VoiceProcessingIO.captureSampleRate)
        clipStorageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glosos-mic-clips", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        sileroVADProcessor = SileroVADProcessor(logHandler: { message in
            print("[VoiceStop] \(message)")
        })
        voiceProcessingIO = VoiceProcessingIO(logHandler: { message in
            print("[VoiceStop] \(message)")
        })
        super.init()
        playbackSynthesizer.delegate = self
        try? FileManager.default.createDirectory(
            at: clipStorageDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        sileroVADProcessor.onSpeechStarted = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.handleVADSpeechStarted()
            }
        }
        sileroVADProcessor.onSpeechEnded = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.handleVADSpeechEnded()
            }
        }
        sileroVADProcessor.loadModelIfNeeded()
    }

    var isCapturingSpeech: Bool {
        !displayedLiveTranscript.isEmpty
    }

    var displayedLiveTranscript: String {
        switch liveTranscript {
        case "Waiting for speech...", "Listening...", "Microphone permission is required.", "Microphone is muted.":
            return ""
        default:
            return liveTranscript
        }
    }

    func toggleMicrophoneMute() {
        isMicrophoneMuted ? unmuteMicrophone() : muteMicrophone()
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
            refreshStatusMessage()
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

        stopUserAudioClipPlayback(resumeListening: false)

        Task {
            beginPlayback(with: trimmedText)
        }
    }

    func toggleUserAudioClipPlayback(_ clip: UserAudioClip) {
        switch previewPlaybackCoordinator.togglePlayback(for: clip.id) {
        case .stop:
            stopUserAudioClipPlayback(resumeListening: shouldResumeListeningAfterPreviewPlayback)
        case .start:
            syncActivePreviewClipID()
            startUserAudioClipPlayback(clip)
        }
    }

    func startContinuousListening() async {
        await preparePermissions()
        guard canListenForTranscription else {
            return
        }

        shouldKeepListening = true
        guard !isMicrophoneMuted, !isListeningContinuously else {
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
        stopUserAudioClipPlayback(resumeListening: false)
        stopListening(reason: "view disappeared", shouldLog: false)
    }

    private func beginPlayback(with text: String) {
        isPreparingPlayback = true
        statusMessage = "Preparing synthesized playback..."

        if shouldActivelyListen, !isListeningContinuously {
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
            try voiceProcessingIO.setVoiceProcessingEnabled(true)
        } catch {
            log("Could not enable voice processing before playback: \(error.localizedDescription)")
        }

        isPreparingPlayback = false
        isPlaybackAudible = true
        isSpeaking = true
        statusMessage = shouldActivelyListen
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
        try voiceProcessingIO.setVoiceProcessingEnabled(false)
        voiceProcessingIO.setRecognitionRequest(recognitionRequest)
        let segmentRecorder = speechSegmentRecorder
        voiceProcessingIO.setCapturedSamplesHandler { [sileroVADProcessor, segmentRecorder] samples, sampleRate in
            segmentRecorder.append(samples: samples, sampleRate: sampleRate)
            sileroVADProcessor.append(samples: samples, sampleRate: sampleRate)
        }
        sileroVADProcessor.loadModelIfNeeded()
        sileroVADProcessor.resetSession()
        speechSegmentRecorder.reset()

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

        guard shouldActivelyListen else {
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
        } else {
            do {
                try voiceProcessingIO.setVoiceProcessingEnabled(false)
            } catch {
                log("Could not bypass voice processing after playback: \(error.localizedDescription)")
            }
        }

        if shouldActivelyListen {
            statusMessage = "Listening to the microphone and transcribing live."
        } else if isMicrophoneMuted {
            statusMessage = "Microphone is muted."
        } else {
            statusMessage = wasInterrupted ? "Playback stopped." : "Playback finished."
        }

        if shouldActivelyListen, !isListeningContinuously {
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
        speechSegmentRecorder.reset()
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
                guard self.shouldActivelyListen, !self.isListeningContinuously, !self.isPreparingPlayback, !self.isPlaybackAudible else {
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

    private var shouldActivelyListen: Bool {
        canListenForTranscription && shouldKeepListening && !isMicrophoneMuted
    }

    private func muteMicrophone() {
        guard !isMicrophoneMuted else {
            return
        }

        isMicrophoneMuted = true
        listenerRestartTask?.cancel()
        listenerRestartTask = nil
        vadSpeechEndTask?.cancel()
        vadSpeechEndTask = nil
        stopListening(reason: "microphone muted", shouldLog: true)
        voiceProcessingIO.stop()
        liveTranscript = "Microphone is muted."
        statusMessage = "Microphone is muted."
    }

    private func unmuteMicrophone() {
        guard isMicrophoneMuted else {
            return
        }

        isMicrophoneMuted = false

        guard canListenForTranscription else {
            statusMessage = "Microphone and Speech Recognition access are needed for live transcription."
            liveTranscript = "Microphone permission is required."
            return
        }

        liveTranscript = "Waiting for speech..."
        refreshStatusMessage()

        guard shouldKeepListening, !isListeningContinuously else {
            return
        }

        do {
            try startRecognitionSession()
            if isPlaybackAudible || isPreparingPlayback {
                try voiceProcessingIO.setVoiceProcessingEnabled(true)
                statusMessage = "Playback is active. Any spoken word will interrupt it."
            }
        } catch {
            log("Failed to unmute microphone: \(error.localizedDescription)")
            statusMessage = "Live transcription is unavailable right now."
        }
    }

    private func refreshStatusMessage() {
        if isMicrophoneMuted {
            statusMessage = "Microphone is muted."
        } else if activePreviewClipID != nil {
            statusMessage = "Playing recorded speech clip."
        } else if isPlaybackAudible || isPreparingPlayback {
            statusMessage = "Playback is active. Any spoken word will interrupt it."
        } else {
            statusMessage = "Listening to the microphone and transcribing live."
        }
    }

    private func startUserAudioClipPlayback(_ clip: UserAudioClip) {
        let shouldResumeListeningAfterPlayback = shouldKeepListening && canListenForTranscription && !isMicrophoneMuted
        stopUserAudioClipPlayback(resumeListening: false)
        shouldResumeListeningAfterPreviewPlayback = shouldResumeListeningAfterPlayback

        if isPreparingPlayback || isPlaybackAudible || isSpeaking {
            stopPlayback()
        }

        if isListeningContinuously {
            stopListening(reason: "playing recorded speech clip", shouldLog: false)
        }

        do {
            let player = try AVAudioPlayer(contentsOf: clip.fileURL)
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else {
                throw UserAudioClipPlaybackError.unableToStartPlayback
            }

            previewAudioPlayer = player
            if previewPlaybackCoordinator.activeClipID != clip.id {
                previewPlaybackCoordinator.forceActiveClip(clip.id)
            }
            syncActivePreviewClipID()
            refreshStatusMessage()
        } catch {
            log("Failed to play recorded speech clip: \(error.localizedDescription)")
            previewAudioPlayer = nil
            finishUserAudioClipPlayback(resumeListening: shouldResumeListeningAfterPreviewPlayback)
        }
    }

    private func stopUserAudioClipPlayback(resumeListening: Bool) {
        guard previewAudioPlayer != nil || activePreviewClipID != nil else {
            return
        }

        previewAudioPlayer?.delegate = nil
        previewAudioPlayer?.stop()
        previewAudioPlayer = nil
        finishUserAudioClipPlayback(resumeListening: resumeListening)
    }

    private func finishUserAudioClipPlayback(resumeListening: Bool) {
        previewPlaybackCoordinator.clear()
        syncActivePreviewClipID()
        shouldResumeListeningAfterPreviewPlayback = false

        if resumeListening,
           shouldKeepListening,
           canListenForTranscription,
           !isMicrophoneMuted,
           !isListeningContinuously,
           !isPreparingPlayback,
           !isPlaybackAudible {
            restartListeningAfterDelay()
        } else {
            refreshStatusMessage()
        }
    }

    private func syncActivePreviewClipID() {
        activePreviewClipID = previewPlaybackCoordinator.activeClipID
    }

    private func consumeNextPendingUserAudioClip() -> UserAudioClip? {
        guard let segment = speechSegmentRecorder.consumePendingSegment() else {
            return nil
        }

        do {
            return try writeUserAudioClip(from: segment)
        } catch {
            log("Failed to save recorded speech clip: \(error.localizedDescription)")
            return nil
        }
    }

    private func writeUserAudioClip(from segment: CapturedSpeechSegment) throws -> UserAudioClip {
        try FileManager.default.createDirectory(
            at: clipStorageDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let fileURL = clipStorageDirectory.appendingPathComponent("segment-\(segment.id.uuidString).wav")
        try writeWAVFile(samples: segment.samples, sampleRate: segment.sampleRate, to: fileURL)
        return UserAudioClip(id: segment.id, fileURL: fileURL, duration: segment.duration)
    }

    private func writeWAVFile(samples: [Float], sampleRate: Int, to fileURL: URL) throws {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = Int(bitsPerSample / 8)
        var pcmData = Data(capacity: samples.count * bytesPerSample)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, Double(sample)))
            var pcmValue = Int16((clamped * Double(Int16.max)).rounded())
            pcmData.append(Data(bytes: &pcmValue, count: MemoryLayout<Int16>.size))
        }

        let dataChunkSize = UInt32(pcmData.count)
        let byteRate = UInt32(sampleRate * Int(channelCount) * bytesPerSample)
        let blockAlign = UInt16(Int(channelCount) * bytesPerSample)
        let riffChunkSize = UInt32(36) + dataChunkSize

        var fileData = Data()
        fileData.append("RIFF".data(using: .ascii)!)
        fileData.appendLittleEndian(riffChunkSize)
        fileData.append("WAVE".data(using: .ascii)!)
        fileData.append("fmt ".data(using: .ascii)!)
        fileData.appendLittleEndian(UInt32(16))
        fileData.appendLittleEndian(UInt16(1))
        fileData.appendLittleEndian(channelCount)
        fileData.appendLittleEndian(UInt32(sampleRate))
        fileData.appendLittleEndian(byteRate)
        fileData.appendLittleEndian(blockAlign)
        fileData.appendLittleEndian(bitsPerSample)
        fileData.append("data".data(using: .ascii)!)
        fileData.appendLittleEndian(dataChunkSize)
        fileData.append(pcmData)

        try fileData.write(to: fileURL, options: .atomic)
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
        speechSegmentRecorder.speechStarted()
        vadSpeechEndTask?.cancel()
        vadSpeechEndTask = nil
        let update = speechTurnCoordinator.speechStarted(
            isPlaybackAudible: isPlaybackAudible,
            now: Date().timeIntervalSinceReferenceDate
        )
        applySpeechTurnUpdate(update, interruptionLogMessage: "Detected spoken interruption from Silero VAD.")
    }

    private func handleVADSpeechEnded() {
        speechSegmentRecorder.speechEnded()
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

        let audioClip = update.didFinalizeSpeechSegment ? consumeNextPendingUserAudioClip() : nil
        if let finalizedText = update.finalizedText {
            finalizedUtterance = TranscribedUtterance(text: finalizedText, audioClip: audioClip)
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

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === previewAudioPlayer else {
            return
        }

        finishUserAudioClipPlayback(resumeListening: shouldResumeListeningAfterPreviewPlayback)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        guard player === previewAudioPlayer else {
            return
        }

        if let error {
            log("Recorded speech clip decode error: \(error.localizedDescription)")
        }
        finishUserAudioClipPlayback(resumeListening: shouldResumeListeningAfterPreviewPlayback)
    }
}

struct CapturedSpeechSegment: Equatable, Identifiable {
    let id: UUID
    let samples: [Float]
    let sampleRate: Int

    init(id: UUID = UUID(), samples: [Float], sampleRate: Int) {
        self.id = id
        self.samples = samples
        self.sampleRate = sampleRate
    }

    var duration: TimeInterval {
        guard sampleRate > 0 else {
            return 0
        }

        return Double(samples.count) / Double(sampleRate)
    }
}

struct SpeechSegmentRecorder: Equatable {
    let sampleRate: Int
    let prerollDuration: TimeInterval

    private var prerollSamples: [Float] = []
    private var activeSegmentSamples: [Float] = []
    private(set) var pendingSegments: [CapturedSpeechSegment] = []
    private(set) var isRecordingSegment = false

    init(
        sampleRate: Int = VoiceProcessingIO.captureSampleRate,
        prerollDuration: TimeInterval = 0.2
    ) {
        self.sampleRate = sampleRate
        self.prerollDuration = prerollDuration
    }

    mutating func reset() {
        prerollSamples.removeAll(keepingCapacity: true)
        activeSegmentSamples.removeAll(keepingCapacity: true)
        pendingSegments.removeAll(keepingCapacity: true)
        isRecordingSegment = false
    }

    mutating func append(samples: [Float], sampleRate: Int) {
        guard sampleRate == self.sampleRate, !samples.isEmpty else {
            return
        }

        prerollSamples.append(contentsOf: samples)
        trimPrerollIfNeeded()

        guard isRecordingSegment else {
            return
        }

        activeSegmentSamples.append(contentsOf: samples)
    }

    mutating func speechStarted() {
        guard !isRecordingSegment else {
            return
        }

        isRecordingSegment = true
        activeSegmentSamples = prerollSamples
    }

    mutating func speechEnded() {
        guard isRecordingSegment else {
            return
        }

        defer {
            isRecordingSegment = false
            activeSegmentSamples.removeAll(keepingCapacity: true)
        }

        guard !activeSegmentSamples.isEmpty else {
            return
        }

        pendingSegments.append(
            CapturedSpeechSegment(samples: activeSegmentSamples, sampleRate: sampleRate)
        )
    }

    mutating func dequeuePendingSegment() -> CapturedSpeechSegment? {
        guard !pendingSegments.isEmpty else {
            return nil
        }

        return pendingSegments.removeFirst()
    }

    private mutating func trimPrerollIfNeeded() {
        let maximumPrerollSampleCount = max(Int((prerollDuration * Double(sampleRate)).rounded()), 0)
        guard maximumPrerollSampleCount > 0, prerollSamples.count > maximumPrerollSampleCount else {
            if maximumPrerollSampleCount == 0 {
                prerollSamples.removeAll(keepingCapacity: true)
            }
            return
        }

        prerollSamples.removeFirst(prerollSamples.count - maximumPrerollSampleCount)
    }
}

final class LockedSpeechSegmentRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: SpeechSegmentRecorder

    init(sampleRate: Int = VoiceProcessingIO.captureSampleRate, prerollDuration: TimeInterval = 0.2) {
        recorder = SpeechSegmentRecorder(sampleRate: sampleRate, prerollDuration: prerollDuration)
    }

    func reset() {
        lock.lock()
        recorder.reset()
        lock.unlock()
    }

    func append(samples: [Float], sampleRate: Int) {
        lock.lock()
        recorder.append(samples: samples, sampleRate: sampleRate)
        lock.unlock()
    }

    func speechStarted() {
        lock.lock()
        recorder.speechStarted()
        lock.unlock()
    }

    func speechEnded() {
        lock.lock()
        recorder.speechEnded()
        lock.unlock()
    }

    func consumePendingSegment() -> CapturedSpeechSegment? {
        lock.lock()
        defer { lock.unlock() }
        return recorder.dequeuePendingSegment()
    }
}

enum AudioClipPreviewAction: Equatable {
    case start
    case stop
}

struct AudioClipPreviewCoordinator: Equatable {
    private(set) var activeClipID: UUID?

    mutating func togglePlayback(for clipID: UUID) -> AudioClipPreviewAction {
        if activeClipID == clipID {
            activeClipID = nil
            return .stop
        }

        activeClipID = clipID
        return .start
    }

    mutating func forceActiveClip(_ clipID: UUID) {
        activeClipID = clipID
    }

    mutating func clear() {
        activeClipID = nil
    }
}

private enum UserAudioClipPlaybackError: LocalizedError {
    case unableToStartPlayback

    var errorDescription: String? {
        switch self {
        case .unableToStartPlayback:
            return "Audio playback could not start."
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(bytes.bindMemory(to: UInt8.self))
        }
    }
}
