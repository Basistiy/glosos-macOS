//
//  SpeechTurnCoordinator.swift
//  glosos-macOS
//
//  Created by Codex on 6/5/26.
//

import Foundation

struct SpeechTurnUpdate: Equatable {
    var shouldInterruptPlayback = false
    var finalizedText: String?
    var shouldClearTranscript = false
    var didFinalizeSpeechSegment = false
}

struct SpeechTurnCoordinator {
    let minimumSpeechDuration: TimeInterval
    let transcriptSettleDuration: TimeInterval

    private(set) var isSpeechSegmentActive = false
    private(set) var latestRecognizedTranscript = ""
    private(set) var currentSegmentTranscript = ""
    private(set) var speechSegmentStartTime: TimeInterval?
    private(set) var pendingSegmentEndTime: TimeInterval?
    private(set) var didEmitFinalUtteranceForCurrentSession = false

    init(
        minimumSpeechDuration: TimeInterval = 0.2,
        transcriptSettleDuration: TimeInterval = 0.2
    ) {
        self.minimumSpeechDuration = minimumSpeechDuration
        self.transcriptSettleDuration = transcriptSettleDuration
    }

    mutating func reset() {
        isSpeechSegmentActive = false
        latestRecognizedTranscript = ""
        currentSegmentTranscript = ""
        speechSegmentStartTime = nil
        pendingSegmentEndTime = nil
        didEmitFinalUtteranceForCurrentSession = false
    }

    mutating func recordTranscript(
        _ transcript: String,
        hasRecognizedContent: Bool,
        usingVAD: Bool,
        isFinal: Bool,
        isPlaybackAudible: Bool
    ) -> SpeechTurnUpdate {
        guard hasRecognizedContent else {
            if !usingVAD, isFinal {
                return SpeechTurnUpdate(shouldClearTranscript: true)
            }
            return SpeechTurnUpdate()
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        latestRecognizedTranscript = trimmed

        if usingVAD {
            if isSpeechSegmentActive {
                currentSegmentTranscript = trimmed
            }
            return SpeechTurnUpdate()
        }

        var update = SpeechTurnUpdate()
        if isPlaybackAudible {
            update.shouldInterruptPlayback = true
        }

        guard isFinal, !didEmitFinalUtteranceForCurrentSession else {
            return update
        }

        didEmitFinalUtteranceForCurrentSession = true
        update.finalizedText = trimmed
        update.shouldClearTranscript = true
        return update
    }

    mutating func speechStarted(isPlaybackAudible: Bool, now: TimeInterval) -> SpeechTurnUpdate {
        var update = SpeechTurnUpdate()

        if let pendingSegmentEndTime {
            update = finalizeSegment(endedAt: pendingSegmentEndTime)
        } else if isSpeechSegmentActive {
            return SpeechTurnUpdate()
        }

        isSpeechSegmentActive = true
        speechSegmentStartTime = now
        pendingSegmentEndTime = nil

        if !latestRecognizedTranscript.isEmpty {
            currentSegmentTranscript = latestRecognizedTranscript
        }

        update.shouldInterruptPlayback = isPlaybackAudible
        return update
    }

    mutating func speechEnded(now: TimeInterval) -> SpeechTurnUpdate {
        guard isSpeechSegmentActive else {
            return SpeechTurnUpdate()
        }

        pendingSegmentEndTime = now
        return SpeechTurnUpdate()
    }

    mutating func finalizePendingSpeechIfNeeded(now: TimeInterval, force: Bool = false) -> SpeechTurnUpdate {
        guard let pendingSegmentEndTime else {
            return SpeechTurnUpdate()
        }

        guard force || now - pendingSegmentEndTime >= transcriptSettleDuration else {
            return SpeechTurnUpdate()
        }

        return finalizeSegment(endedAt: pendingSegmentEndTime)
    }

    private mutating func finalizeSegment(endedAt endTime: TimeInterval) -> SpeechTurnUpdate {
        let segmentStartTime = speechSegmentStartTime ?? endTime
        let finalizedText = shouldFinalizeSegment(endedAt: endTime, startedAt: segmentStartTime)
            ? currentSegmentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        isSpeechSegmentActive = false
        latestRecognizedTranscript = ""
        currentSegmentTranscript = ""
        speechSegmentStartTime = nil
        pendingSegmentEndTime = nil

        guard let finalizedText, !finalizedText.isEmpty else {
            return SpeechTurnUpdate(shouldClearTranscript: true, didFinalizeSpeechSegment: true)
        }

        return SpeechTurnUpdate(
            finalizedText: finalizedText,
            shouldClearTranscript: true,
            didFinalizeSpeechSegment: true
        )
    }

    private func shouldFinalizeSegment(endedAt endTime: TimeInterval, startedAt startTime: TimeInterval) -> Bool {
        guard !currentSegmentTranscript.isEmpty else {
            return false
        }

        return endTime - startTime >= minimumSpeechDuration
    }
}
