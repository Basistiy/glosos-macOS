//
//  glosos_macOSTests.swift
//  glosos-macOSTests
//
//  Created by EV on 6/3/26.
//

import Foundation
import Testing
import AVFoundation
@testable import glosos_macOS

struct glosos_macOSTests {

    @Test
    @MainActor
    func agentControllerConnectsThroughTransportAbstraction() async throws {
        let transport = RecordingAgentTransport()
        let suiteName = "AgentConnectionControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let controller = AgentConnectionController(
            userDefaults: defaults,
            transport: transport
        )

        await controller.connect(using: "http://127.0.0.1:18000")

        #expect(controller.isConnected)
        #expect(controller.connectionStatus == "Connected")
        #expect(transport.connectedEndpoints == [AgentEndpoint(baseURL: URL(string: "http://127.0.0.1:18000")!)])
    }

    @Test
    @MainActor
    func assistantChunksAreAggregatedIntoSingleBubble() async throws {
        let controller = AgentConnectionController()
        let assistantMessageID = controller.beginAssistantTurn(userText: "Hello there")

        controller.applyAgentEvent(AgentEvent(type: "chunk", session_id: nil, text: "Hi", tool: nil, message: nil))
        controller.applyAgentEvent(AgentEvent(type: "chunk", session_id: nil, text: " there", tool: nil, message: nil))
        controller.applyAgentEvent(AgentEvent(type: "final", session_id: nil, text: "Hi there", tool: nil, message: nil))

        #expect(controller.messages.count == 2)
        #expect(controller.messages[0].role == .user)
        #expect(controller.messages[0].text == "Hello there")
        #expect(controller.messages[1].id == assistantMessageID)
        #expect(controller.messages[1].role == .assistant)
        #expect(controller.messages[1].text == "Hi there")
        #expect(controller.messages[1].state == .final)
        #expect(controller.latestCompletedAssistantMessage?.id == assistantMessageID)
        #expect(controller.isAwaitingAssistantResponse == false)
    }

    @Test
    @MainActor
    func userAudioClipIsPreservedOnLocalUserBubble() async throws {
        let controller = AgentConnectionController()
        let clip = UserAudioClip(
            id: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/test-user-clip.wav"),
            duration: 0.8
        )

        _ = controller.beginAssistantTurn(
            userUtterance: TranscribedUtterance(text: "Hello there", audioClip: clip)
        )

        #expect(controller.messages.count == 2)
        #expect(controller.messages[0].role == .user)
        #expect(controller.messages[0].audioClip == clip)
        #expect(controller.messages[0].hasPlayableAudioClip)
    }

    @Test
    func pendingUtteranceWaitsUntilAssistantTurnCompletes() async throws {
        var coordinator = PendingUtteranceCoordinator()
        let utterance = TranscribedUtterance(text: "Second turn")

        let immediateSend = coordinator.register(utterance, whileAwaitingAssistantResponse: true)
        #expect(immediateSend == nil)
        #expect(coordinator.pendingUtterance == utterance)
        #expect(coordinator.dequeueIfReady(whileAwaitingAssistantResponse: true) == nil)
        #expect(coordinator.dequeueIfReady(whileAwaitingAssistantResponse: false) == utterance)
        #expect(coordinator.pendingUtterance == nil)
    }

    @Test
    func latestPendingUtteranceReplacesOlderOne() async throws {
        var coordinator = PendingUtteranceCoordinator()
        let older = TranscribedUtterance(text: "Older")
        let newer = TranscribedUtterance(text: "Newer")

        _ = coordinator.register(older, whileAwaitingAssistantResponse: true)
        _ = coordinator.register(newer, whileAwaitingAssistantResponse: true)

        #expect(coordinator.pendingUtterance == newer)
        #expect(coordinator.dequeueIfReady(whileAwaitingAssistantResponse: false) == newer)
    }

    @Test
    func interruptedAssistantReplyIsSuppressedByMessageID() async throws {
        let interruptedID = UUID()
        let interruptedMessage = ChatMessage(id: interruptedID, role: .assistant, text: "Old reply")
        var coordinator = AssistantPlaybackCoordinator()

        coordinator.suppress(messageID: interruptedID)
        let shouldSpeak = coordinator.consumeCompletion(for: interruptedMessage)

        #expect(shouldSpeak == false)
        #expect(coordinator.suppressedAssistantMessageID == nil)
    }

    @Test
    func newAssistantReplyStillSpeaksAfterInterruptingDifferentTurn() async throws {
        let interruptedID = UUID()
        let nextReply = ChatMessage(role: .assistant, text: "New reply")
        var coordinator = AssistantPlaybackCoordinator()

        coordinator.suppress(messageID: interruptedID)
        let shouldSpeak = coordinator.consumeCompletion(for: nextReply)

        #expect(shouldSpeak == true)
        #expect(coordinator.suppressedAssistantMessageID == interruptedID)
    }

    @Test
    @MainActor
    func speechControllerCreatesFileWhenFeedingAudio() async throws {
        let controller = SpeechController()
        
        // Ensure listening is enabled
        await controller.startContinuousListening()
        
        // Simulate speech detection starting
        controller.handleSpeechStarted()
        
        // Create a dummy audio buffer (1 second of silence at 16kHz mono)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        
        // Feed the audio buffer
        controller.feedExternalAudio(buffer)
        
        // Verify that the temporary file was created and is not empty
        let fileManager = FileManager.default
        guard let tempFileURL = controller.audioFileURL else {
            Issue.record("audioFileURL is nil")
            return
        }
        #expect(fileManager.fileExists(atPath: tempFileURL.path))
        
        // Simulate speech detection ending (triggers transcription and deletion)
        controller.handleSpeechEnded()
        
        // Stop listening to close any remaining files
        controller.stopContinuousListening()
        
        // Clean up the created utterance files if still present
        try? fileManager.removeItem(at: tempFileURL)
    }

    @Test
    @MainActor
    func abortActiveTurnCancelsTaskAndLeavesControllerConnected() async throws {
        let transport = RecordingAgentTransport()
        transport.shouldWaitAndThrowOnCancel = true
        let suiteName = "AgentConnectionControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        
        let controller = AgentConnectionController(
            userDefaults: defaults,
            transport: transport
        )
        
        // Setup initial connected state
        await controller.connect(using: "http://127.0.0.1:18000")
        #expect(controller.isConnected)
        
        // Send a user message (which starts the task)
        _ = controller.sendUserMessage("Interrupt me")
        
        // Allow the task to start running
        try await Task.sleep(nanoseconds: 50_000_000) // 0.05s
        
        #expect(controller.isAwaitingAssistantResponse)
        
        // Abort the turn (simulating user speaking barge-in)
        controller.abortActiveTurn()
        
        // Allow the task cancellation catch block to execute on MainActor
        try await Task.sleep(nanoseconds: 50_000_000) // 0.05s
        
        #expect(controller.isConnected) // Should still be connected
        #expect(controller.isAwaitingAssistantResponse == false)
        #expect(controller.messages.last?.state == .error)
        #expect(controller.messages.last?.text.contains("Interrupted") == true)
    }

    @Test
    func pendingUtteranceCanBeCleared() async throws {
        var coordinator = PendingUtteranceCoordinator()
        let utterance = TranscribedUtterance(text: "Stale")
        
        _ = coordinator.register(utterance, whileAwaitingAssistantResponse: true)
        #expect(coordinator.pendingUtterance == utterance)
        
        coordinator.clear()
        #expect(coordinator.pendingUtterance == nil)
    }

    @Test
    @MainActor
    func stopPlaybackCancelsActivePlaybackToken() async throws {
        let controller = SpeechController()
        
        // We will trigger a fake playback setup
        controller.play("Test speech synthesis")
        
        // Now call stopPlayback
        controller.stopPlayback()
        
        // Verify isSpeaking has been reset
        #expect(controller.isSpeaking == false)
    }

}

final class RecordingAgentTransport: AgentTransport {
    private(set) var connectedEndpoints: [AgentEndpoint] = []
    var shouldWaitAndThrowOnCancel = false

    func connect(to endpoint: AgentEndpoint) async throws {
        connectedEndpoints.append(endpoint)
    }

    func disconnect() {}

    func send(
        _ payload: OutboundMessage,
        to endpoint: AgentEndpoint,
        onEvent: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws {
        if shouldWaitAndThrowOnCancel {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 10_000_000) // 0.01s
            }
            throw URLError(.cancelled)
        }
    }
}
