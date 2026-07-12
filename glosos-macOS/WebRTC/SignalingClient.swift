//
//  SignalingClient.swift
//  glosos-macOS
//
//  Created by Antigravity on 6/9/26.
//

import Foundation

@MainActor
public protocol SignalingClientDelegate: AnyObject, Sendable {
    func signalingClientDidConnect(_ client: SignalingClient)
    func signalingClientDidDisconnect(_ client: SignalingClient)
    func signalingClient(_ client: SignalingClient, didReceiveIncomingCall callerSocketId: String, callerUsername: String, offer: [String: Any])
    func signalingClient(_ client: SignalingClient, didReceiveIceCandidate senderSocketId: String, candidate: [String: Any])
    func signalingClient(_ client: SignalingClient, didReceiveHangUp senderSocketId: String)
    func signalingClient(_ client: SignalingClient, didFailWithError error: Error)
    func signalingClient(_ client: SignalingClient, willAttemptReconnect attempt: Int, delay: TimeInterval)
    func signalingClientDidGiveUpReconnect(_ client: SignalingClient)
}

public extension SignalingClientDelegate {
    func signalingClientDidGiveUpReconnect(_ client: SignalingClient) {}
}

public actor SignalingClient {
    public weak var delegate: SignalingClientDelegate?
    
    private let apiEndpoint: String
    private let token: String
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var sessionDelegate: URLSessionWebSocketDelegate?
    private var isConnected = false
    
    private var isExplicitDisconnect = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var reconnectTask: Task<Void, Never>?
    
    private var lastHeartbeatTime = Date()
    private var heartbeatTask: Task<Void, Never>?
    private var pingInterval: TimeInterval = 25.0
    private var pingTimeout: TimeInterval = 20.0
    
    public init(apiEndpoint: String, token: String) {
        self.apiEndpoint = apiEndpoint
        self.token = token
    }
    
    public func setDelegate(_ delegate: SignalingClientDelegate?) {
        self.delegate = delegate
    }
    
    public func connect() {
        guard !isConnected else { return }
        
        reconnectTask?.cancel()
        reconnectTask = nil
        isExplicitDisconnect = false
        
        guard let webSocketURL = Self.makeWebSocketURL(from: apiEndpoint) else {
            let error = NSError(domain: "SignalingClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid apiEndpoint for WebSocket URL formulation"])
            let currentDelegate = delegate
            Task { @MainActor in
                await currentDelegate?.signalingClient(self, didFailWithError: error)
            }
            return
        }
        
        print("[SignalingClient] Connecting to \(webSocketURL.absoluteString)...")
        
        let configuration = URLSessionConfiguration.default
        // Set reasonable timeout
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        
        let delegateHelper = SignalingSessionDelegate(
            onOpen: {
                print("[SignalingClient] WebSocket connection opened successfully.")
            },
            onClose: { [weak self] in
                print("[SignalingClient] WebSocket connection closed.")
                guard let self = self else { return }
                Task {
                    await self.handleDisconnect()
                }
            },
            didComplete: { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    print("[SignalingClient] WebSocket task completed with error: \(error.localizedDescription)")
                    Task {
                        await self.handleFailure(error)
                    }
                } else {
                    print("[SignalingClient] WebSocket task completed.")
                    Task {
                        await self.handleDisconnect()
                    }
                }
            }
        )
        self.sessionDelegate = delegateHelper
        
        let session = URLSession(configuration: configuration, delegate: delegateHelper, delegateQueue: nil)
        self.urlSession = session
        
        // Clean up any stale webSocketTask
        webSocketTask?.cancel()
        
        let task = session.webSocketTask(with: webSocketURL)
        self.webSocketTask = task
        task.resume()
        
        listen()
    }
    
    public func disconnect() {
        print("[SignalingClient] Disconnecting...")
        isExplicitDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
        
        heartbeatTask?.cancel()
        heartbeatTask = nil
        
        guard isConnected || webSocketTask != nil else { return }
        
        // Send Socket.IO namespace disconnect frame (41)
        sendRaw("41")
        
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false
        
        let currentDelegate = delegate
        Task { @MainActor in
            await currentDelegate?.signalingClientDidDisconnect(self)
        }
    }
    
    public func sendAnswer(targetSocketId: String, answer: [String: any Sendable]) {
        let payload: [any Sendable] = [
            "make-answer",
            [
                "targetSocketId": targetSocketId,
                "answer": answer
            ] as [String: any Sendable]
        ]
        sendSocketIOEvent(payload)
    }
    
    public func sendIceCandidate(targetSocketId: String, candidate: [String: any Sendable]) {
        let payload: [any Sendable] = [
            "ice-candidate",
            [
                "targetSocketId": targetSocketId,
                "candidate": candidate
            ] as [String: any Sendable]
        ]
        sendSocketIOEvent(payload)
    }
    
    public func sendHangUp(targetSocketId: String) {
        let payload: [any Sendable] = [
            "hang-up",
            [
                "targetSocketId": targetSocketId
            ] as [String: any Sendable]
        ]
        sendSocketIOEvent(payload)
    }
    
    // MARK: - Internal Helpers
    
    private func listen() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            Task {
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        await self.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await self.handleMessage(text)
                        }
                    @unknown default:
                        break
                    }
                    await self.listen()
                case .failure(let error):
                    print("[SignalingClient] WebSocket read error: \(error.localizedDescription)")
                    await self.handleFailure(error)
                }
            }
        }
    }
    
    private func handleMessage(_ text: String) {
        guard let firstChar = text.first else { return }
        
        // Reset heartbeat timer on any incoming message
        self.resetHeartbeatTimer()
        
        if firstChar == "0" {
            // Engine.IO Handshake packet
            print("[SignalingClient] Engine.IO handshake received: \(text)")
            
            // Parse pingInterval and pingTimeout from handshake
            if let data = String(text.dropFirst()).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                if let interval = json["pingInterval"] as? Double {
                    self.pingInterval = interval / 1000.0
                }
                if let timeout = json["pingTimeout"] as? Double {
                    self.pingTimeout = timeout / 1000.0
                }
                print("[SignalingClient] Handshake heartbeat settings: pingInterval=\(self.pingInterval)s, pingTimeout=\(self.pingTimeout)s")
            }
            
            // Send Socket.IO connect packet to the default namespace (40) with JWT Auth Token in payload
            let authPayload = [
                "token": self.token,
                "clientType": "mac-server"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: authPayload, options: []),
               let jsonString = String(data: data, encoding: .utf8) {
                let connectMsg = "40\(jsonString)"
                self.sendRaw(connectMsg)
            } else {
                let connectMsg = "40"
                self.sendRaw(connectMsg)
            }
        } else if text.hasPrefix("40") {
            // Socket.IO namespace connected
            print("[SignalingClient] Socket.IO namespace connected: \(text)")
            self.isConnected = true
            self.reconnectAttempts = 0
            self.isExplicitDisconnect = false
            self.reconnectTask?.cancel()
            self.reconnectTask = nil
            let currentDelegate = delegate
            Task { @MainActor in
                await currentDelegate?.signalingClientDidConnect(self)
            }
        } else if firstChar == "2" {
            // Ping from server: reply with Pong (3) immediately to maintain connection
            self.sendRaw("3")
        } else if text.hasPrefix("42") {
            // Socket.IO custom event
            let jsonStartIndex = text.index(text.startIndex, offsetBy: 2)
            let jsonString = String(text[jsonStartIndex...])
            self.parseSocketIOEvent(jsonString)
        } else if firstChar == "1" || text.hasPrefix("41") {
            print("[SignalingClient] Server closed connection: \(text)")
            self.handleDisconnect()
        } else if text.hasPrefix("44") {
            print("[SignalingClient] Socket.IO namespace connection error: \(text)")
            let jsonStartIndex = text.index(text.startIndex, offsetBy: 2)
            let jsonString = String(text[jsonStartIndex...])
            
            var errorMsg = "Signaling connection error"
            if let data = jsonString.data(using: .utf8),
               let jsonDict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let message = jsonDict["message"] as? String {
                errorMsg = message
            }
            
            let error = NSError(domain: "SignalingClient", code: -2, userInfo: [NSLocalizedDescriptionKey: errorMsg])
            
            // Post notification if it's an authentication error
            let lowercased = errorMsg.lowercased()
            if lowercased.contains("auth") || lowercased.contains("token") || lowercased.contains("expired") || lowercased.contains("invalid") {
                print("[SignalingClient] Authentication error detected. Posting GlososAuthTokenExpired notification.")
                NotificationCenter.default.post(name: NSNotification.Name("GlososAuthTokenExpired"), object: nil)
            }
            
            self.isExplicitDisconnect = true
            self.handleFailure(error)
        }
    }
    
    private func parseSocketIOEvent(_ jsonString: String) {
        let currentDelegate = delegate
        Task { @MainActor in
            guard let data = jsonString.data(using: .utf8),
                  let jsonArray = try? JSONSerialization.jsonObject(with: data, options: []) as? [Any],
                  jsonArray.count >= 2,
                  let eventName = jsonArray[0] as? String else {
                return
            }
            
            let eventData = jsonArray[1]
            
            switch eventName {
            case "incoming-call":
                guard let payload = eventData as? [String: Any],
                      let callerSocketId = payload["callerSocketId"] as? String,
                      let callerUsername = payload["callerUsername"] as? String,
                      let offer = payload["offer"] as? [String: Any] else {
                    return
                }
                print("[SignalingClient] Incoming call from \(callerUsername) (\(callerSocketId))")
                await currentDelegate?.signalingClient(self, didReceiveIncomingCall: callerSocketId, callerUsername: callerUsername, offer: offer)
                
            case "ice-candidate":
                guard let payload = eventData as? [String: Any],
                      let senderSocketId = payload["senderSocketId"] as? String,
                      let candidate = payload["candidate"] as? [String: Any] else {
                    return
                }
                await currentDelegate?.signalingClient(self, didReceiveIceCandidate: senderSocketId, candidate: candidate)
                
            case "hang-up":
                guard let payload = eventData as? [String: Any],
                      let senderSocketId = payload["senderSocketId"] as? String else {
                    return
                }
                print("[SignalingClient] Call hung up by peer \(senderSocketId)")
                await currentDelegate?.signalingClient(self, didReceiveHangUp: senderSocketId)
                
            default:
                break
            }
        }
    }
    
    private func sendRaw(_ text: String) {
        let message = URLSessionWebSocketTask.Message.string(text)
        webSocketTask?.send(message) { error in
            if let error = error {
                print("[SignalingClient] WebSocket send error: \(error.localizedDescription)")
            }
        }
    }
    
    private func sendSocketIOEvent(_ payload: [any Sendable]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }
        sendRaw("42\(jsonString)")
    }
    
    private func handleFailure(_ error: Error) {
        self.handleDisconnect()
        let currentDelegate = delegate
        Task { @MainActor in
            await currentDelegate?.signalingClient(self, didFailWithError: error)
        }
    }
    
    private func handleDisconnect() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        
        guard isConnected || webSocketTask != nil else { return }
        webSocketTask = nil
        urlSession = nil
        isConnected = false
        
        let currentDelegate = delegate
        Task { @MainActor in
            await currentDelegate?.signalingClientDidDisconnect(self)
        }
        
        // Schedule reconnect if this was an implicit disconnect
        if !isExplicitDisconnect {
            reconnectAttempts += 1
            let delay = min(30.0, pow(2.0, Double(min(5, reconnectAttempts))))
            
            if reconnectAttempts <= maxReconnectAttempts {
                print("[SignalingClient] Connection lost. Scheduling reconnect attempt \(reconnectAttempts)/\(maxReconnectAttempts) in \(delay) seconds...")
            } else {
                print("[SignalingClient] Connection lost. Scheduling background reconnect attempt \(reconnectAttempts) in \(delay) seconds...")
            }
            
            reconnectTask?.cancel()
            reconnectTask = Task {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                await self.connect()
            }
            
            let currentDelegate = delegate
            let attempts = reconnectAttempts
            Task { @MainActor in
                await currentDelegate?.signalingClient(self, willAttemptReconnect: attempts, delay: delay)
                
                if attempts == maxReconnectAttempts {
                    print("[SignalingClient] Max rapid reconnect attempts reached (\(maxReconnectAttempts)). Transitioning to background retries.")
                    await currentDelegate?.signalingClientDidGiveUpReconnect(self)
                }
            }
        }
    }
    
    private func resetHeartbeatTimer() {
        lastHeartbeatTime = Date()
        guard heartbeatTask == nil else { return }
        
        heartbeatTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    break
                }
                
                guard !Task.isCancelled else { break }
                
                let elapsed = Date().timeIntervalSince(self.lastHeartbeatTime)
                if elapsed >= (self.pingInterval + self.pingTimeout) {
                    self.handleHeartbeatTimeout()
                    break
                }
            }
        }
    }
    
    private func handleHeartbeatTimeout() {
        print("[SignalingClient] Heartbeat timeout: No ping or message received from server for \(self.pingInterval + self.pingTimeout) seconds. Marking connection as dead.")
        let error = NSError(
            domain: "SignalingClient",
            code: -3,
            userInfo: [NSLocalizedDescriptionKey: "Signaling connection timed out due to heartbeat loss."]
        )
        self.handleFailure(error)
    }
    
    // MARK: - Static URL formulation helper
    
    public static func makeWebSocketURL(from apiEndpoint: String) -> URL? {
        var normalized = apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        
        if normalized.hasSuffix("/api") {
            normalized = String(normalized.dropLast(4))
        }
        
        guard var components = URLComponents(string: normalized) else { return nil }
        
        if components.scheme == "https" {
            components.scheme = "wss"
        } else if components.scheme == "http" {
            components.scheme = "ws"
        } else if components.scheme == nil {
            components.scheme = "wss"
        }
        
        components.path = "/socket.io/"
        components.queryItems = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "websocket")
        ]
        
        return components.url
    }
}

// MARK: - Session Delegate Helper

private final class SignalingSessionDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    private let onOpen: @Sendable () -> Void
    private let onClose: @Sendable () -> Void
    private let didComplete: @Sendable (Error?) -> Void
    
    init(
        onOpen: @escaping @Sendable () -> Void,
        onClose: @escaping @Sendable () -> Void,
        didComplete: @escaping @Sendable (Error?) -> Void
    ) {
        self.onOpen = onOpen
        self.onClose = onClose
        self.didComplete = didComplete
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen()
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onClose()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        didComplete(error)
    }
}
