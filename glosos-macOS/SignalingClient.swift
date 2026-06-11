//
//  SignalingClient.swift
//  glosos-macOS
//
//  Created by Antigravity on 6/9/26.
//

import Foundation

public protocol SignalingClientDelegate: AnyObject {
    func signalingClientDidConnect(_ client: SignalingClient)
    func signalingClientDidDisconnect(_ client: SignalingClient)
    func signalingClient(_ client: SignalingClient, didReceiveIncomingCall callerSocketId: String, callerUsername: String, offer: [String: Any])
    func signalingClient(_ client: SignalingClient, didReceiveIceCandidate senderSocketId: String, candidate: [String: Any])
    func signalingClient(_ client: SignalingClient, didReceiveHangUp senderSocketId: String)
    func signalingClient(_ client: SignalingClient, didFailWithError error: Error)
    func signalingClient(_ client: SignalingClient, willAttemptReconnect attempt: Int, delay: TimeInterval)
}

public final class SignalingClient: NSObject {
    public weak var delegate: SignalingClientDelegate?
    
    private let apiEndpoint: String
    private let token: String
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isConnected = false
    private let queue = DispatchQueue(label: "com.glosos.signaling-client", qos: .userInitiated)
    
    private var isExplicitDisconnect = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var reconnectWorkItem: DispatchWorkItem?
    
    public init(apiEndpoint: String, token: String) {
        self.apiEndpoint = apiEndpoint
        self.token = token
        super.init()
    }
    
    public func connect() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isConnected else { return }
            
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.isExplicitDisconnect = false
            
            guard let webSocketURL = Self.makeWebSocketURL(from: self.apiEndpoint) else {
                let error = NSError(domain: "SignalingClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid apiEndpoint for WebSocket URL formulation"])
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.signalingClient(self, didFailWithError: error)
                }
                return
            }
            
            print("[SignalingClient] Connecting to \(webSocketURL.absoluteString)...")
            
            let configuration = URLSessionConfiguration.default
            // Set reasonable timeout
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.urlSession = session
            
            // Clean up any stale webSocketTask
            self.webSocketTask?.cancel()
            
            let task = session.webSocketTask(with: webSocketURL)
            self.webSocketTask = task
            task.resume()
            
            self.listen()
        }
    }
    
    public func disconnect() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            print("[SignalingClient] Disconnecting...")
            self.isExplicitDisconnect = true
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.reconnectAttempts = 0
            
            guard self.isConnected || self.webSocketTask != nil else { return }
            
            // Send Socket.IO namespace disconnect frame (41)
            self.sendRaw("41")
            
            self.webSocketTask?.cancel(with: .normalClosure, reason: nil)
            self.webSocketTask = nil
            self.urlSession?.invalidateAndCancel()
            self.urlSession = nil
            self.isConnected = false
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.signalingClientDidDisconnect(self)
            }
        }
    }
    
    public func sendAnswer(targetSocketId: String, answer: [String: Any]) {
        let payload: [Any] = [
            "make-answer",
            [
                "targetSocketId": targetSocketId,
                "answer": answer
            ]
        ]
        sendSocketIOEvent(payload)
    }
    
    public func sendIceCandidate(targetSocketId: String, candidate: [String: Any]) {
        let payload: [Any] = [
            "ice-candidate",
            [
                "targetSocketId": targetSocketId,
                "candidate": candidate
            ]
        ]
        sendSocketIOEvent(payload)
    }
    
    public func sendHangUp(targetSocketId: String) {
        let payload: [Any] = [
            "hang-up",
            [
                "targetSocketId": targetSocketId
            ]
        ]
        sendSocketIOEvent(payload)
    }
    
    // MARK: - Internal Helpers
    
    private func listen() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self.listen()
            case .failure(let error):
                print("[SignalingClient] WebSocket read error: \(error.localizedDescription)")
                self.handleFailure(error)
            }
        }
    }
    
    private func handleMessage(_ text: String) {
        // Engine.IO protocol prefixes messages with digits representing packet type:
        // 0: open (connection handshake with JSON payload)
        // 1: close
        // 2: ping
        // 3: pong
        // 4: message
        // 40: socket.io namespace connect
        // 41: socket.io namespace disconnect
        // 42: socket.io namespace event (JSON array payload [eventName, data])
        
        guard let firstChar = text.first else { return }
        
        if firstChar == "0" {
            // Engine.IO Handshake packet
            print("[SignalingClient] Engine.IO handshake received: \(text)")
            // Send Socket.IO connect packet to the default namespace (40) with JWT Auth Token in payload
            let authPayload = ["token": self.token]
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
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.signalingClientDidConnect(self)
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
        }
    }
    
    private func parseSocketIOEvent(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let jsonArray = try? JSONSerialization.jsonObject(with: data, options: []) as? [Any],
              jsonArray.count >= 2,
              let eventName = jsonArray[0] as? String else {
            return
        }
        
        let eventData = jsonArray[1]
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            switch eventName {
            case "incoming-call":
                guard let payload = eventData as? [String: Any],
                      let callerSocketId = payload["callerSocketId"] as? String,
                      let callerUsername = payload["callerUsername"] as? String,
                      let offer = payload["offer"] as? [String: Any] else {
                    return
                }
                print("[SignalingClient] Incoming call from \(callerUsername) (\(callerSocketId))")
                self.delegate?.signalingClient(self, didReceiveIncomingCall: callerSocketId, callerUsername: callerUsername, offer: offer)
                
            case "ice-candidate":
                guard let payload = eventData as? [String: Any],
                      let senderSocketId = payload["senderSocketId"] as? String,
                      let candidate = payload["candidate"] as? [String: Any] else {
                    return
                }
                self.delegate?.signalingClient(self, didReceiveIceCandidate: senderSocketId, candidate: candidate)
                
            case "hang-up":
                guard let payload = eventData as? [String: Any],
                      let senderSocketId = payload["senderSocketId"] as? String else {
                    return
                }
                print("[SignalingClient] Call hung up by peer \(senderSocketId)")
                self.delegate?.signalingClient(self, didReceiveHangUp: senderSocketId)
                
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
    
    private func sendSocketIOEvent(_ payload: [Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }
        queue.async { [weak self] in
            self?.sendRaw("42\(jsonString)")
        }
    }
    
    private func handleFailure(_ error: Error) {
        self.handleDisconnect()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.signalingClient(self, didFailWithError: error)
        }
    }
    
    private func handleDisconnect() {
        guard isConnected || webSocketTask != nil else { return }
        webSocketTask = nil
        urlSession = nil
        isConnected = false
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.signalingClientDidDisconnect(self)
        }
        
        // Schedule reconnect if this was an implicit disconnect
        if !isExplicitDisconnect && reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            let delay = min(30.0, pow(2.0, Double(reconnectAttempts)))
            print("[SignalingClient] Connection lost. Scheduling reconnect attempt \(reconnectAttempts)/\(maxReconnectAttempts) in \(delay) seconds...")
            
            reconnectWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                print("[SignalingClient] Attempting reconnect (attempt \(self.reconnectAttempts))...")
                self.connect()
            }
            self.reconnectWorkItem = workItem
            queue.asyncAfter(deadline: .now() + delay, execute: workItem)
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.signalingClient(self, willAttemptReconnect: self.reconnectAttempts, delay: delay)
            }
        } else if !isExplicitDisconnect {
            print("[SignalingClient] Max reconnect attempts reached (\(maxReconnectAttempts)). Giving up.")
        }
    }
    
    // MARK: - Static URL formulation helper
    
    public static func makeWebSocketURL(from apiEndpoint: String) -> URL? {
        // e.g. "https://glosos.com/api" -> "wss://glosos.com/socket.io/?EIO=4&transport=websocket"
        // e.g. "http://127.0.0.1:5000/api" -> "ws://127.0.0.1:5000/socket.io/?EIO=4&transport=websocket"
        
        var normalized = apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove trailing slash if present
        if normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        
        // Strip trailing "/api" if it exists, since socket.io matches on root endpoint or custom path
        if normalized.hasSuffix("/api") {
            normalized = String(normalized.dropLast(4))
        }
        
        guard var components = URLComponents(string: normalized) else { return nil }
        
        if components.scheme == "https" {
            components.scheme = "wss"
        } else if components.scheme == "http" {
            components.scheme = "ws"
        } else if components.scheme == nil {
            // Default to secure WebSocket if scheme is omitted
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

// MARK: - URLSessionWebSocketDelegate

extension SignalingClient: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("[SignalingClient] WebSocket connection opened successfully.")
    }
    
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("[SignalingClient] WebSocket connection closed.")
        self.handleDisconnect()
    }
}
