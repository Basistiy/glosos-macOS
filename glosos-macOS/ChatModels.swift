//
//  ChatModels.swift
//  glosos-macOS
//
//  Created by Codex on 6/5/26.
//

import Foundation

struct AgentEndpoint: Equatable {
    static let defaultLocalBaseURLString = "http://127.0.0.1:18000"

    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    init?(rawValue: String) {
        guard let normalized = Self.normalizedString(from: rawValue),
              let baseURL = URL(string: normalized) else {
            return nil
        }

        self.baseURL = baseURL
    }

    var displayString: String {
        baseURL.absoluteString
    }

    var healthURL: URL {
        baseURL.appendingPathComponent("healthz")
    }

    var messageURL: URL {
        baseURL.appendingPathComponent("message")
    }

    static func normalizedString(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased() else {
            return nil
        }

        switch scheme {
        case "ws":
            components.scheme = "http"
        case "wss":
            components.scheme = "https"
        case "http", "https":
            break
        default:
            return nil
        }

        components.query = nil
        components.fragment = nil

        let path = components.percentEncodedPath
        if path == "/ws" {
            components.percentEncodedPath = ""
        } else if path.hasSuffix("/ws") {
            components.percentEncodedPath = String(path.dropLast(3))
        }

        if components.percentEncodedPath == "/" {
            components.percentEncodedPath = ""
        }

        return components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

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

struct AssistantPlaybackCoordinator: Equatable {
    private(set) var suppressedAssistantMessageID: UUID?

    mutating func suppress(messageID: UUID?) {
        suppressedAssistantMessageID = messageID
    }

    mutating func consumeCompletion(for message: ChatMessage) -> Bool {
        guard message.role == .assistant else {
            return false
        }

        guard let suppressedAssistantMessageID else {
            return true
        }

        if message.id == suppressedAssistantMessageID {
            self.suppressedAssistantMessageID = nil
            return false
        }

        return true
    }
}

struct AgentEvent: Decodable, Equatable {
    let type: String
    let session_id: String?
    let text: String?
    let tool: String?
    let message: String?
}
