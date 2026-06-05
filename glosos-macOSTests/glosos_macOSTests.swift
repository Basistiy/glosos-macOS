//
//  glosos_macOSTests.swift
//  glosos-macOSTests
//
//  Created by EV on 6/3/26.
//

import Testing
@testable import glosos_macOS

struct glosos_macOSTests {

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

}
