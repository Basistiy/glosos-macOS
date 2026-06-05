//
//  AgentConnectionController.swift
//  glosos-macOS
//
//  Created by Codex on 6/5/26.
//

import Combine
import Foundation

@MainActor
final class AgentConnectionController: NSObject, ObservableObject {
    @Published var socketURL = UserDefaults.standard.string(forKey: "agentSocketURL")
        ?? "ws://127.0.0.1:18000/ws"
    @Published var sessionID = UserDefaults.standard.string(forKey: "agentSessionID")
        ?? "macos-local"

    @Published private(set) var isConnected = false
    @Published private(set) var connectionStatus = "Disconnected"
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isAwaitingAssistantResponse = false
    @Published private(set) var latestCompletedAssistantMessage: ChatMessage?

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var userInitiatedDisconnect = false
    private var activeAssistantMessageID: UUID?

    var statusDetail: String {
        if isAwaitingAssistantResponse {
            return "Agent is replying"
        }

        return connectionStatus
    }

    func connect() {
        let trimmedURL = socketURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), let scheme = url.scheme, ["ws", "wss"].contains(scheme) else {
            connectionStatus = "Invalid websocket URL"
            appendSystemMessage("Enter a valid ws:// or wss:// websocket URL.", state: .error)
            return
        }

        saveSettings()
        disconnectInternal(reason: nil, shouldReportToChat: false)
        userInitiatedDisconnect = false
        connectionStatus = "Connecting..."

        let session = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: nil
        )
        let task = session.webSocketTask(with: url)
        urlSession = session
        webSocketTask = task
        task.resume()
    }

    func disconnect() {
        userInitiatedDisconnect = true
        disconnectInternal(reason: "Disconnected", shouldReportToChat: false)
    }

    func saveSettings() {
        UserDefaults.standard.set(socketURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "agentSocketURL")
        UserDefaults.standard.set(sessionID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "agentSessionID")
    }

    @discardableResult
    func sendUserMessage(_ text: String) -> Bool {
        guard let webSocketTask else {
            connectionStatus = "Disconnected"
            appendSystemMessage("The app is not connected to the local agent.", state: .error)
            return false
        }

        let trimmedMessage = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let assistantMessageID = beginAssistantTurn(userText: trimmedMessage)
        connectionStatus = "Sending message..."

        do {
            let payload = OutboundMessage(session_id: trimmedSessionID, message: trimmedMessage)
            let data = try JSONEncoder().encode(payload)
            guard let text = String(data: data, encoding: .utf8) else {
                throw AgentConnectionError.encodingFailed
            }

            webSocketTask.send(.string(text)) { [weak self] error in
                let controller = self
                Task { @MainActor in
                    guard let controller else { return }

                    if let error {
                        controller.failAssistantTurn(
                            id: assistantMessageID,
                            message: "Failed to send message: \(error.localizedDescription)"
                        )
                        return
                    }

                    controller.connectionStatus = "Awaiting response..."
                }
            }
            return true
        } catch {
            failAssistantTurn(
                id: assistantMessageID,
                message: "Could not encode the outgoing websocket message."
            )
            return false
        }
    }

    @discardableResult
    func beginAssistantTurn(userText: String) -> UUID {
        let trimmedText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let assistantMessageID = UUID()

        messages.append(ChatMessage(role: .user, text: trimmedText))
        messages.append(ChatMessage(id: assistantMessageID, role: .assistant, text: "", state: .streaming))

        activeAssistantMessageID = assistantMessageID
        isAwaitingAssistantResponse = true
        latestCompletedAssistantMessage = nil

        return assistantMessageID
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

        if messages.last?.role == .system, messages.last?.text == trimmedText, messages.last?.state == state {
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
        let resolvedText = finalText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallbackText
        let finalMessageText = resolvedText.isEmpty ? "The agent returned an empty response." : resolvedText

        updateMessage(id: assistantMessageID) { message in
            message.text = finalMessageText
            message.state = .final
        }

        if let finalMessage = message(withID: assistantMessageID) {
            latestCompletedAssistantMessage = finalMessage
        }

        activeAssistantMessageID = nil
        isAwaitingAssistantResponse = false
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
        isAwaitingAssistantResponse = false
        connectionStatus = "Error"
        appendSystemMessage(message, state: .error)
    }

    private func disconnectInternal(reason: String?, shouldReportToChat: Bool) {
        if let webSocketTask {
            webSocketTask.cancel(with: .normalClosure, reason: nil)
            self.webSocketTask = nil
        }

        urlSession?.invalidateAndCancel()
        urlSession = nil
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

    deinit {
        urlSession?.invalidateAndCancel()
    }
}

extension AgentConnectionController: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol negotiatedProtocol: String?
    ) {
        let _ = negotiatedProtocol

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.webSocketTask === webSocketTask else { return }

            self.isConnected = true
            self.connectionStatus = "Connected"
            self.startReceiveLoop(for: webSocketTask)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.webSocketTask === webSocketTask else { return }

            let message: String
            if self.userInitiatedDisconnect {
                message = "Disconnected"
            } else if let reasonText, !reasonText.isEmpty {
                message = "Websocket closed: \(reasonText)"
            } else {
                message = "Websocket closed with code \(closeCode.rawValue)."
            }

            self.disconnectInternal(
                reason: message,
                shouldReportToChat: !self.userInitiatedDisconnect
            )
        }
    }

    private func startReceiveLoop(for task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            let controller = self
            Task { @MainActor in
                guard let controller else { return }
                guard controller.webSocketTask === task else { return }

                switch result {
                case .success(let message):
                    controller.handleReceivedMessage(message)
                    controller.startReceiveLoop(for: task)
                case .failure(let error):
                    let isCleanShutdown = controller.userInitiatedDisconnect || (error as NSError).code == NSURLErrorCancelled
                    if isCleanShutdown {
                        controller.disconnectInternal(reason: "Disconnected", shouldReportToChat: false)
                        return
                    }

                    controller.disconnectInternal(
                        reason: "The websocket connection closed unexpectedly.",
                        shouldReportToChat: true
                    )
                }
            }
        }
    }

    private func handleReceivedMessage(_ message: URLSessionWebSocketTask.Message) {
        let rawText: String

        switch message {
        case .string(let text):
            rawText = text
        case .data(let data):
            rawText = String(decoding: data, as: UTF8.self)
        @unknown default:
            appendSystemMessage("Received an unsupported websocket frame.", state: .error)
            return
        }

        guard let event = try? JSONDecoder().decode(AgentEvent.self, from: Data(rawText.utf8)) else {
            appendSystemMessage("Received an unreadable websocket payload.", state: .error)
            return
        }

        applyAgentEvent(event)
    }
}

private struct OutboundMessage: Encodable {
    let type = "message"
    let session_id: String
    let message: String
}

private enum AgentConnectionError: Error {
    case encodingFailed
}
