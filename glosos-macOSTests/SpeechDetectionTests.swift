//
//  SpeechDetectionTests.swift
//  glosos-macOSTests
//
//  Created by Codex on 6/5/26.
//

import Foundation
import Testing
@testable import glosos_macOS

struct SpeechDetectionTests {

    @Test
    func chunkAccumulatorDownsamplesFortyEightKilohertzIntoSileroChunks() throws {
        var accumulator = SileroChunkAccumulator()
        let sampleRate = 48_000
        let input = (0 ..< 3_072).map { index in
            sin(2.0 * .pi * Double(index) / 48.0).isFinite ? Float(sin(2.0 * .pi * Double(index) / 48.0)) : 0
        }

        let firstPassChunks = try accumulator.append(samples: Array(input.prefix(1_000)), sampleRate: sampleRate)
        #expect(firstPassChunks.isEmpty)

        let secondPassChunks = try accumulator.append(samples: Array(input.dropFirst(1_000)), sampleRate: sampleRate)
        let chunkCountIsExpected = secondPassChunks.count == 2
        let chunkSizesAreExpected = secondPassChunks.allSatisfy { $0.count == SileroChunkAccumulator.targetChunkSize }
        let allSamplesAreFinite = secondPassChunks.flatMap { $0 }.allSatisfy { $0.isFinite }

        #expect(chunkCountIsExpected)
        #expect(chunkSizesAreExpected)
        #expect(allSamplesAreFinite)
    }

    @Test
    func segmentRecorderIncludesPrerollAtSpeechStart() throws {
        var recorder = SpeechSegmentRecorder(sampleRate: 10, prerollDuration: 0.3)
        recorder.append(samples: [0, 1, 2, 3], sampleRate: 10)

        recorder.speechStarted()
        recorder.append(samples: [4, 5], sampleRate: 10)
        recorder.speechEnded()

        let segment = recorder.dequeuePendingSegment()

        #expect(segment?.samples == [1, 2, 3, 4, 5])
    }

    @Test
    func segmentRecorderQueuesOneSegmentPerVadWindowInOrder() throws {
        var recorder = SpeechSegmentRecorder(sampleRate: 10, prerollDuration: 0.0)

        recorder.append(samples: [1, 2], sampleRate: 10)
        recorder.speechStarted()
        recorder.append(samples: [3], sampleRate: 10)
        recorder.speechEnded()

        recorder.append(samples: [4, 5], sampleRate: 10)
        recorder.speechStarted()
        recorder.append(samples: [6], sampleRate: 10)
        recorder.speechEnded()

        let firstSegment = recorder.dequeuePendingSegment()
        let secondSegment = recorder.dequeuePendingSegment()

        #expect(firstSegment?.samples == [3])
        #expect(secondSegment?.samples == [6])
        #expect(recorder.dequeuePendingSegment() == nil)
    }

    @Test
    func vadStateMachineIgnoresShortNoiseBurst() throws {
        var stateMachine = VADSpeechStateMachine()
        let now = Date().timeIntervalSinceReferenceDate

        let firstEvent = stateMachine.ingest(probability: 0.8, now: now)
        let secondEvent = stateMachine.ingest(probability: 0.2, now: now + stateMachine.chunkDuration)

        let firstIsNone = matchesNone(firstEvent)
        let secondIsNone = matchesNone(secondEvent)

        #expect(firstIsNone)
        #expect(secondIsNone)
        #expect(stateMachine.isSpeechActive == false)
    }

    @Test
    func vadStateMachineStartsSpeechOnce() throws {
        var stateMachine = VADSpeechStateMachine()
        let startTime = Date().timeIntervalSinceReferenceDate

        let firstEvent = stateMachine.ingest(probability: 0.8, now: startTime)
        let secondEvent = stateMachine.ingest(probability: 0.9, now: startTime + stateMachine.chunkDuration)
        let thirdEvent = stateMachine.ingest(probability: 0.95, now: startTime + 2 * stateMachine.chunkDuration)

        let firstIsNone = matchesNone(firstEvent)
        let secondIsStart = matchesSpeechStarted(secondEvent)
        let thirdIsNone = matchesNone(thirdEvent)

        #expect(firstIsNone)
        #expect(secondIsStart)
        #expect(thirdIsNone)
        #expect(stateMachine.isSpeechActive == true)
    }

    @Test
    func vadStateMachineEndsSpeechAfterSustainedSilence() throws {
        var stateMachine = VADSpeechStateMachine()
        let startTime = Date().timeIntervalSinceReferenceDate

        _ = stateMachine.ingest(probability: 0.8, now: startTime)
        _ = stateMachine.ingest(probability: 0.85, now: startTime + stateMachine.chunkDuration)

        var endEvent = VADSpeechStateMachine.Event.none
        for index in 0 ..< 10 {
            endEvent = stateMachine.ingest(
                probability: 0.1,
                now: startTime + Double(index + 2) * stateMachine.chunkDuration
            )
        }

        #expect(matchesSpeechEnded(endEvent))
        #expect(stateMachine.isSpeechActive == false)
    }

    @Test
    func coordinatorDoesNotInterruptPlaybackOnVadStartAlone() throws {
        var coordinator = SpeechTurnCoordinator()
        let startUpdate = coordinator.speechStarted(isPlaybackAudible: true, now: 10)

        #expect(startUpdate.shouldInterruptPlayback == false)
    }

    @Test
    func coordinatorInterruptsPlaybackOnlyOncePerSpeechSegmentAfterTranscriptArrives() throws {
        var coordinator = SpeechTurnCoordinator()
        _ = coordinator.speechStarted(isPlaybackAudible: true, now: 10)

        let firstTranscriptUpdate = coordinator.recordTranscript(
            "stop",
            hasRecognizedContent: true,
            usingVAD: true,
            isFinal: false,
            isPlaybackAudible: true
        )
        let repeatedTranscriptUpdate = coordinator.recordTranscript(
            "stop now",
            hasRecognizedContent: true,
            usingVAD: true,
            isFinal: false,
            isPlaybackAudible: true
        )

        #expect(firstTranscriptUpdate.shouldInterruptPlayback == true)
        #expect(repeatedTranscriptUpdate.shouldInterruptPlayback == false)
    }

    @Test
    func coordinatorFinalizesLatestTranscriptWhenVadSegmentEnds() throws {
        var coordinator = SpeechTurnCoordinator()

        _ = coordinator.recordTranscript(
            "hello",
            hasRecognizedContent: true,
            usingVAD: true,
            isFinal: false,
            isPlaybackAudible: false
        )
        _ = coordinator.speechStarted(isPlaybackAudible: false, now: 5.0)
        _ = coordinator.recordTranscript(
            "hello there",
            hasRecognizedContent: true,
            usingVAD: true,
            isFinal: false,
            isPlaybackAudible: false
        )

        let endUpdate = coordinator.speechEnded(now: 5.4)
        let earlyFinalize = coordinator.finalizePendingSpeechIfNeeded(now: 5.45)
        let update = coordinator.finalizePendingSpeechIfNeeded(now: 5.65)

        #expect(endUpdate.finalizedText == nil)
        #expect(earlyFinalize.finalizedText == nil)
        #expect(update.finalizedText == "hello there")
        #expect(update.shouldClearTranscript == true)
        #expect(update.didFinalizeSpeechSegment == true)
    }

    @Test
    func coordinatorDoesNotFinalizeEmptyOrTooShortVadSegments() throws {
        var emptyCoordinator = SpeechTurnCoordinator()
        _ = emptyCoordinator.speechStarted(isPlaybackAudible: false, now: 2.0)
        let emptyEndUpdate = emptyCoordinator.speechEnded(now: 2.5)
        let emptyUpdate = emptyCoordinator.finalizePendingSpeechIfNeeded(now: 2.8)

        #expect(emptyEndUpdate.finalizedText == nil)
        #expect(emptyUpdate.finalizedText == nil)
        #expect(emptyUpdate.shouldClearTranscript == true)

        var shortCoordinator = SpeechTurnCoordinator()
        _ = shortCoordinator.recordTranscript(
            "hi",
            hasRecognizedContent: true,
            usingVAD: true,
            isFinal: false,
            isPlaybackAudible: false
        )
        _ = shortCoordinator.speechStarted(isPlaybackAudible: false, now: 4.0)
        _ = shortCoordinator.speechEnded(now: 4.1)
        let shortUpdate = shortCoordinator.finalizePendingSpeechIfNeeded(now: 4.4)

        #expect(shortUpdate.finalizedText == nil)
        #expect(shortUpdate.shouldClearTranscript == true)
    }

    @Test
    func coordinatorUsesLateTranscriptThatArrivesAfterVadEnd() throws {
        var coordinator = SpeechTurnCoordinator()

        _ = coordinator.recordTranscript(
            "What is in the data",
            hasRecognizedContent: true,
            usingVAD: true,
            isFinal: false,
            isPlaybackAudible: false
        )
        _ = coordinator.speechStarted(isPlaybackAudible: false, now: 10.0)
        _ = coordinator.recordTranscript(
            "What is in the data",
            hasRecognizedContent: true,
            usingVAD: true,
            isFinal: false,
            isPlaybackAudible: false
        )
        _ = coordinator.speechEnded(now: 10.3)
        _ = coordinator.recordTranscript(
            "What is in the database",
            hasRecognizedContent: true,
            usingVAD: true,
            isFinal: false,
            isPlaybackAudible: false
        )

        let update = coordinator.finalizePendingSpeechIfNeeded(now: 10.6)

        #expect(update.finalizedText == "What is in the database")
        #expect(update.shouldClearTranscript == true)
        #expect(update.didFinalizeSpeechSegment == true)
    }

    @Test
    func coordinatorUsesFinalTranscriptThatArrivesAfterVadEnd() throws {
        var coordinator = SpeechTurnCoordinator()

        _ = coordinator.recordTranscript(
            "set a tim",
            hasRecognizedContent: true,
            usingVAD: true,
            isFinal: false,
            isPlaybackAudible: false
        )
        _ = coordinator.speechStarted(isPlaybackAudible: false, now: 12.0)
        _ = coordinator.recordTranscript(
            "set a tim",
            hasRecognizedContent: true,
            usingVAD: true,
            isFinal: false,
            isPlaybackAudible: false
        )
        _ = coordinator.speechEnded(now: 12.4)
        _ = coordinator.recordTranscript(
            "set a timer",
            hasRecognizedContent: true,
            usingVAD: true,
            isFinal: true,
            isPlaybackAudible: false
        )

        let update = coordinator.finalizePendingSpeechIfNeeded(now: 12.7, force: true)

        #expect(update.finalizedText == "set a timer")
        #expect(update.shouldClearTranscript == true)
        #expect(update.didFinalizeSpeechSegment == true)
    }

    @Test
    func coordinatorFlushesPendingSegmentBeforeStartingNextOne() throws {
        var coordinator = SpeechTurnCoordinator()

        _ = coordinator.recordTranscript(
            "stop",
            hasRecognizedContent: true,
            usingVAD: true,
            isFinal: false,
            isPlaybackAudible: false
        )
        _ = coordinator.speechStarted(isPlaybackAudible: true, now: 20.0)
        _ = coordinator.recordTranscript(
            "stop",
            hasRecognizedContent: true,
            usingVAD: true,
            isFinal: false,
            isPlaybackAudible: false
        )
        _ = coordinator.speechEnded(now: 20.3)

        let nextStartUpdate = coordinator.speechStarted(isPlaybackAudible: false, now: 20.45)

        #expect(nextStartUpdate.finalizedText == "stop")
        #expect(nextStartUpdate.shouldInterruptPlayback == false)
        #expect(nextStartUpdate.didFinalizeSpeechSegment == true)
    }

    @Test
    func fallbackSpeechRecognitionDoesNotProduceVadAudioClip() throws {
        var coordinator = SpeechTurnCoordinator()
        let update = coordinator.recordTranscript(
            "fallback only",
            hasRecognizedContent: true,
            usingVAD: false,
            isFinal: true,
            isPlaybackAudible: false
        )
        let utterance = update.finalizedText.map {
            TranscribedUtterance(
                text: $0,
                audioClip: update.didFinalizeSpeechSegment
                    ? UserAudioClip(
                        fileURL: URL(fileURLWithPath: "/tmp/should-not-exist.wav"),
                        duration: 0.5
                    )
                    : nil
            )
        }

        #expect(update.didFinalizeSpeechSegment == false)
        #expect(utterance?.audioClip == nil)
    }

    @Test
    func previewPlaybackCoordinatorTogglesActiveClipState() throws {
        var coordinator = AudioClipPreviewCoordinator()
        let firstClipID = UUID()
        let secondClipID = UUID()

        let firstAction = coordinator.togglePlayback(for: firstClipID)
        let secondAction = coordinator.togglePlayback(for: firstClipID)
        let thirdAction = coordinator.togglePlayback(for: secondClipID)

        #expect(firstAction == .start)
        #expect(secondAction == .stop)
        #expect(thirdAction == .start)
        #expect(coordinator.activeClipID == secondClipID)
    }

    @Test
    func userMessagesOnlyExposePlayableAudioClipState() throws {
        let clip = UserAudioClip(
            fileURL: URL(fileURLWithPath: "/tmp/clip.wav"),
            duration: 0.5
        )

        let userMessage = ChatMessage(role: .user, text: "Hello", audioClip: clip)
        let assistantMessage = ChatMessage(role: .assistant, text: "Hi", audioClip: clip)
        let plainUserMessage = ChatMessage(role: .user, text: "Hello")

        #expect(userMessage.hasPlayableAudioClip)
        #expect(assistantMessage.hasPlayableAudioClip == false)
        #expect(plainUserMessage.hasPlayableAudioClip == false)
    }

    private func matchesSpeechStarted(_ event: VADSpeechStateMachine.Event) -> Bool {
        if case .speechStarted = event {
            return true
        }
        return false
    }

    private func matchesSpeechEnded(_ event: VADSpeechStateMachine.Event) -> Bool {
        if case .speechEnded = event {
            return true
        }
        return false
    }

    private func matchesNone(_ event: VADSpeechStateMachine.Event) -> Bool {
        if case .none = event {
            return true
        }
        return false
    }
}
