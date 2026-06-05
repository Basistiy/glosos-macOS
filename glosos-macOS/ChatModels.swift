//
//  ChatModels.swift
//  glosos-macOS
//
//  Created by Codex on 6/5/26.
//

import Foundation

struct ChatMessage: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
        case system
    }

    enum State: String {
        case draft
        case streaming
        case final
        case error
    }

    let id: UUID
    let role: Role
    var text: String
    var state: State

    init(id: UUID = UUID(), role: Role, text: String, state: State = .final) {
        self.id = id
        self.role = role
        self.text = text
        self.state = state
    }
}

struct TranscribedUtterance: Identifiable, Equatable {
    let id: UUID
    let text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

struct PendingUtteranceCoordinator: Equatable {
    private(set) var pendingUtterance: TranscribedUtterance?

    mutating func register(_ utterance: TranscribedUtterance, whileAwaitingAssistantResponse isAwaitingAssistantResponse: Bool) -> TranscribedUtterance? {
        guard isAwaitingAssistantResponse else {
            return utterance
        }

        pendingUtterance = utterance
        return nil
    }

    mutating func dequeueIfReady(whileAwaitingAssistantResponse isAwaitingAssistantResponse: Bool) -> TranscribedUtterance? {
        guard !isAwaitingAssistantResponse, let pendingUtterance else {
            return nil
        }

        self.pendingUtterance = nil
        return pendingUtterance
    }
}

struct AgentEvent: Decodable, Equatable {
    let type: String
    let session_id: String?
    let text: String?
    let tool: String?
    let message: String?
}
