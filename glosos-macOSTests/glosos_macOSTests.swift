//
//  glosos_macOSTests.swift
//  glosos-macOSTests
//
//  Created by EV on 6/3/26.
//

import Foundation
import Testing
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

}

final class RecordingAgentTransport: AgentTransport {
    private(set) var connectedEndpoints: [AgentEndpoint] = []

    func connect(to endpoint: AgentEndpoint) async throws {
        connectedEndpoints.append(endpoint)
    }

    func disconnect() {}

    func send(
        _ payload: OutboundMessage,
        to endpoint: AgentEndpoint,
        onEvent: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws {
        let _ = payload
        let _ = endpoint
        let _ = onEvent
    }
}
