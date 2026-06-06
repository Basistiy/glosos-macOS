//
//  AgentConnectionController.swift
//  glosos-macOS
//
//  Created by Codex on 6/5/26.
//

import Combine
import Foundation

protocol AgentTransport {
    func connect(to endpoint: AgentEndpoint) async throws
    func disconnect()
    func send(
        _ payload: OutboundMessage,
        to endpoint: AgentEndpoint,
        onEvent: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws
}

struct HTTPStreamingAgentTransport: AgentTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(to endpoint: AgentEndpoint) async throws {
        var request = URLRequest(url: endpoint.healthURL)
        request.timeoutInterval = 5

        let (_, response) = try await session.data(for: request)
        try validate(response: response, fallbackMessage: "Health check failed.")
    }

    func disconnect() {}

    func send(
        _ payload: OutboundMessage,
        to endpoint: AgentEndpoint,
        onEvent: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws {
        var request = URLRequest(url: endpoint.messageURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (bytes, response) = try await session.bytes(for: request)
        try validate(
            response: response,
            fallbackMessage: "The agent request failed before streaming started."
        )

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            guard let event = try? JSONDecoder().decode(AgentEvent.self, from: Data(trimmed.utf8)) else {
                throw AgentConnectionError.invalidResponsePayload
            }

            await onEvent(event)
        }
    }

    private func validate(response: URLResponse, fallbackMessage: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentConnectionError.invalidHTTPResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AgentConnectionError.httpFailure(
                statusCode: httpResponse.statusCode,
                message: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                fallback: fallbackMessage
            )
        }
    }
}

@MainActor
final class AgentConnectionController: ObservableObject {
    @Published var endpointURL: String
    @Published var sessionID: String

    @Published private(set) var isConnected = false
    @Published private(set) var connectionStatus = "Disconnected"
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isAwaitingAssistantResponse = false
    @Published private(set) var latestCompletedAssistantMessage: ChatMessage?

    private let userDefaults: UserDefaults
    private let transport: AgentTransport
    private var activeRequestTask: Task<Void, Never>?
    private var userInitiatedDisconnect = false
    private var activeAssistantMessageID: UUID?

    private static let endpointURLKey = "agentEndpointURL"
    private static let legacySocketURLKey = "agentSocketURL"
    private static let sessionIDKey = "agentSessionID"

    init(
        userDefaults: UserDefaults = .standard,
        transport: AgentTransport = HTTPStreamingAgentTransport()
    ) {
        self.userDefaults = userDefaults
        self.transport = transport
        self.endpointURL = Self.loadSavedEndpointURL(from: userDefaults)
        self.sessionID = userDefaults.string(forKey: Self.sessionIDKey) ?? "macos-local"
    }

    var activeAssistantTurnID: UUID? {
        activeAssistantMessageID
    }

    var statusDetail: String {
        if isAwaitingAssistantResponse {
            return "Agent is replying"
        }

        return connectionStatus
    }

    func connect(using overrideEndpointURL: String? = nil) async {
        let trimmedURL = (overrideEndpointURL ?? endpointURL).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let endpoint = AgentEndpoint(rawValue: trimmedURL) else {
            connectionStatus = "Invalid endpoint URL"
            appendSystemMessage("Enter a valid http:// or https:// endpoint URL.", state: .error)
            return
        }

        endpointURL = endpoint.displayString
        saveSettings()
        disconnectInternal(reason: nil, shouldReportToChat: false)
        userInitiatedDisconnect = false
        connectionStatus = "Checking endpoint..."

        do {
            try await transport.connect(to: endpoint)
            isConnected = true
            connectionStatus = "Connected"
        } catch {
            connectionStatus = "Connection failed"
            appendSystemMessage(
                "Could not reach the local agent endpoint: \(error.localizedDescription)",
                state: .error
            )
        }
    }

    func connect(using managedEndpoint: ManagedRuntimeEndpoint) async {
        await connect(using: managedEndpoint.displayString)
    }

    func disconnect() {
        userInitiatedDisconnect = true
        disconnectInternal(reason: "Disconnected", shouldReportToChat: false)
    }

    func saveSettings() {
        userDefaults.set(
            endpointURL.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Self.endpointURLKey
        )
        userDefaults.set(
            sessionID.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Self.sessionIDKey
        )
    }

    @discardableResult
    func sendUserMessage(_ utterance: TranscribedUtterance) -> Bool {
        guard isConnected else {
            connectionStatus = "Disconnected"
            appendSystemMessage("The app is not connected to the local agent.", state: .error)
            return false
        }

        guard let endpoint = AgentEndpoint(rawValue: endpointURL) else {
            connectionStatus = "Invalid endpoint URL"
            appendSystemMessage("Enter a valid http:// or https:// endpoint URL.", state: .error)
            return false
        }

        let trimmedMessage = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedSessionID.isEmpty else {
            connectionStatus = "Session ID is blank"
            appendSystemMessage("Session ID cannot be blank.", state: .error)
            return false
        }

        guard !trimmedMessage.isEmpty else {
            return false
        }

        saveSettings()
        let assistantMessageID = beginAssistantTurn(userUtterance: utterance)
        connectionStatus = "Sending message..."
        activeRequestTask?.cancel()
        userInitiatedDisconnect = false

        let payload = OutboundMessage(session_id: trimmedSessionID, message: trimmedMessage)
        activeRequestTask = Task { [weak self] in
            do {
                try await self?.transport.send(
                    payload,
                    to: endpoint,
                    onEvent: { [weak self] event in
                        await MainActor.run {
                            self?.applyAgentEvent(event)
                        }
                    }
                )
            } catch is CancellationError {
                await MainActor.run {
                    guard let self else { return }
                    self.handleRequestCancellation()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.failAssistantTurn(
                        id: assistantMessageID,
                        message: "The HTTP request failed: \(error.localizedDescription)"
                    )
                    self.isConnected = false
                }
            }

            await MainActor.run {
                guard let self else { return }
                if self.activeRequestTask?.isCancelled == false {
                    self.activeRequestTask = nil
                }
            }
        }

        return true
    }

    @discardableResult
    func sendUserMessage(_ text: String) -> Bool {
        sendUserMessage(TranscribedUtterance(text: text))
    }

    @discardableResult
    func beginAssistantTurn(userUtterance: TranscribedUtterance) -> UUID {
        let trimmedText = userUtterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let assistantMessageID = UUID()

        messages.append(
            ChatMessage(
                role: .user,
                text: trimmedText,
                audioClip: userUtterance.audioClip
            )
        )
        messages.append(
            ChatMessage(id: assistantMessageID, role: .assistant, text: "", state: .streaming)
        )

        activeAssistantMessageID = assistantMessageID
        isAwaitingAssistantResponse = true
        latestCompletedAssistantMessage = nil

        return assistantMessageID
    }

    @discardableResult
    func beginAssistantTurn(userText: String) -> UUID {
        beginAssistantTurn(userUtterance: TranscribedUtterance(text: userText))
    }

    func applyAgentEvent(_ event: AgentEvent) {
        switch event.type {
        case "ack":
            connectionStatus = "Connected"
        case "session_started":
            connectionStatus = "Session \(event.session_id ?? sessionID) ready"
        case "chunk":
            applyAssistantChunk(event.text ?? "")
        case "final":
            finalizeAssistantTurn(with: event.text)
        case "tool_call":
            connectionStatus = "Agent is using \(event.tool ?? "a tool")"
        case "tool_result":
            connectionStatus = "Agent finished \(event.tool ?? "a tool")"
        case "error":
            failActiveAssistantTurn(message: event.message ?? "The local agent returned an error.")
        default:
            break
        }
    }

    func appendSystemMessage(_ text: String, state: ChatMessage.State = .error) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return
        }

        if messages.last?.role == .system,
           messages.last?.text == trimmedText,
           messages.last?.state == state {
            return
        }

        messages.append(ChatMessage(role: .system, text: trimmedText, state: state))
    }

    private func applyAssistantChunk(_ chunk: String) {
        guard !chunk.isEmpty else {
            return
        }

        let assistantMessageID = ensureActiveAssistantMessageID()

        updateMessage(id: assistantMessageID) { message in
            message.state = .streaming
            message.text += chunk
        }
        isAwaitingAssistantResponse = true
        connectionStatus = "Receiving response..."
    }

    private func finalizeAssistantTurn(with finalText: String?) {
        guard let assistantMessageID = activeAssistantMessageID else {
            return
        }

        let fallbackText = message(withID: assistantMessageID)?.text ?? ""
        let resolvedText =
            finalText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallbackText
        let finalMessageText =
            resolvedText.isEmpty ? "The agent returned an empty response." : resolvedText

        updateMessage(id: assistantMessageID) { message in
            message.text = finalMessageText
            message.state = .final
        }

        if let finalMessage = message(withID: assistantMessageID) {
            latestCompletedAssistantMessage = finalMessage
        }

        activeAssistantMessageID = nil
        isAwaitingAssistantResponse = false
        activeRequestTask = nil
        connectionStatus = "Connected"
    }

    private func failActiveAssistantTurn(message: String) {
        guard let assistantMessageID = activeAssistantMessageID else {
            connectionStatus = "Error"
            appendSystemMessage(message, state: .error)
            return
        }

        failAssistantTurn(id: assistantMessageID, message: message)
    }

    private func failAssistantTurn(id assistantMessageID: UUID, message: String) {
        updateMessage(id: assistantMessageID) { chatMessage in
            chatMessage.text = message
            chatMessage.state = .error
        }

        activeAssistantMessageID = nil
        activeRequestTask = nil
        isAwaitingAssistantResponse = false
        connectionStatus = "Error"
        appendSystemMessage(message, state: .error)
    }

    private func disconnectInternal(reason: String?, shouldReportToChat: Bool) {
        activeRequestTask?.cancel()
        activeRequestTask = nil
        transport.disconnect()
        isConnected = false
        isAwaitingAssistantResponse = false

        if let activeAssistantMessageID, shouldReportToChat {
            let disconnectMessage = reason ?? "Connection closed before the assistant reply finished."
            updateMessage(id: activeAssistantMessageID) { message in
                message.state = .error
                if message.text.isEmpty {
                    message.text = disconnectMessage
                }
            }
        }

        self.activeAssistantMessageID = nil
        connectionStatus = reason ?? "Disconnected"

        if shouldReportToChat, let reason {
            appendSystemMessage(reason, state: .error)
        }
    }

    private func handleRequestCancellation() {
        activeRequestTask = nil

        if userInitiatedDisconnect {
            return
        }

        disconnectInternal(
            reason: "The HTTP stream ended unexpectedly.",
            shouldReportToChat: true
        )
    }

    private func ensureActiveAssistantMessageID() -> UUID {
        if let activeAssistantMessageID {
            return activeAssistantMessageID
        }

        let messageID = UUID()
        messages.append(ChatMessage(id: messageID, role: .assistant, text: "", state: .streaming))
        activeAssistantMessageID = messageID
        isAwaitingAssistantResponse = true
        return messageID
    }

    private func updateMessage(id: UUID, mutate: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }

        mutate(&messages[index])
    }

    private func message(withID id: UUID) -> ChatMessage? {
        messages.first(where: { $0.id == id })
    }

    private static func loadSavedEndpointURL(from userDefaults: UserDefaults) -> String {
        if let savedEndpoint = userDefaults.string(forKey: endpointURLKey),
           let normalized = AgentEndpoint.normalizedString(from: savedEndpoint) {
            return normalized
        }

        if let legacySocketURL = userDefaults.string(forKey: legacySocketURLKey),
           let normalized = AgentEndpoint.normalizedString(from: legacySocketURL) {
            return normalized
        }

        return AgentEndpoint.defaultLocalBaseURLString
    }
}

struct OutboundMessage: Encodable, Equatable {
    let type = "message"
    let session_id: String
    let message: String
}

enum AgentConnectionError: LocalizedError {
    case invalidHTTPResponse
    case invalidResponsePayload
    case httpFailure(statusCode: Int, message: String, fallback: String)

    var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            return "The agent returned an invalid HTTP response."
        case .invalidResponsePayload:
            return "The agent returned unreadable streamed JSON events."
        case let .httpFailure(statusCode, message, fallback):
            return "\(fallback) HTTP \(statusCode): \(message)"
        }
    }
}
