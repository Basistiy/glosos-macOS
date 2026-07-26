//
//  P2PConnectionController.swift
//  glosos-macOS
//
//  Created by Antigravity on 6/9/26.
//

import Foundation
import Combine
import Network
import WebRTC

@MainActor
final class P2PConnectionController: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var statusDetail = "Disconnected"
    var messages: [ChatMessage] = []
    var latestCompletedPeerMessage: ChatMessage?
    @Published var latestReceivedPeerMessage: String?
    
    var onIncomingAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        didSet {
            webRTCManager.onIncomingAudioBuffer = onIncomingAudioBuffer
        }
    }
    
    @Published private(set) var localServer = LocalSignalingServer()
    @Published var isLocalServerEnabled = false
    
    private var signalingClient: SignalingClient?
    private let webRTCManager: WebRTCManager
    private var turnServers: [RTCIceServer] = []
    
    private var currentCallerSocketId: String?
    private var peerUsername: String?
    
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.glosos.network-monitor")
    private var lastSavedApiEndpoint: String?
    private var lastSavedToken: String?
    private var wasOffline = false
    private var hasGivenUpReconnecting = false
    
    init() {
        self.webRTCManager = WebRTCManager()
        self.webRTCManager.delegate = self
        self.localServer.delegate = self
        self.startLocalServer()
    }
    
    private func fetchTurnCredentials(apiEndpoint: String, token: String) async -> [RTCIceServer] {
        var endpoint = apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.hasSuffix("/") {
            endpoint.removeLast()
        }
        
        guard let url = URL(string: "\(endpoint)/turn/credentials") else {
            print("[P2PConnectionController] Invalid apiEndpoint URL for TURN credentials")
            return []
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                print("[P2PConnectionController] Failed to fetch TURN credentials (status code: \(statusCode))")
                if statusCode == 401 || statusCode == 403 {
                    print("[P2PConnectionController] Ephemeral TURN credentials retrieval returned \(statusCode). Posting GlososAuthTokenExpired notification.")
                    NotificationCenter.default.post(name: NSNotification.Name("GlososAuthTokenExpired"), object: nil)
                }
                return []
            }
            
            struct TurnResponse: Codable {
                let url: String?
                let urls: [String]?
                let username: String?
                let credential: String?
            }
            
            let turnData = try JSONDecoder().decode(TurnResponse.self, from: data)
            let urls = turnData.urls ?? (turnData.url.map { [$0] } ?? [])
            guard !urls.isEmpty else { return [] }
            
            let turnServer = RTCIceServer(
                urlStrings: urls,
                username: turnData.username,
                credential: turnData.credential
            )
            return [turnServer]
        } catch {
            print("[P2PConnectionController] Error fetching TURN credentials: \(error.localizedDescription)")
            return []
        }
    }
    
    func startSignaling(apiEndpoint: String, token: String) async {
        // If we are already connected or connecting to the exact same endpoint and token, do nothing
        if lastSavedApiEndpoint == apiEndpoint && lastSavedToken == token && (isConnected || signalingClient != nil) {
            print("[P2PConnectionController] Already connected or connecting to the same endpoint and token. Skipping startSignaling.")
            return
        }

        // If signalingClient exists and apiEndpoint is unchanged (e.g. token refreshed):
        if let client = signalingClient, lastSavedApiEndpoint == apiEndpoint {
            print("[P2PConnectionController] Updating token on existing signaling client (preserving active WebRTC connection if any)...")
            self.lastSavedToken = token
            self.hasGivenUpReconnecting = false
            
            await client.updateToken(token)
            
            // Refresh TURN credentials in background
            Task {
                let servers = await fetchTurnCredentials(apiEndpoint: apiEndpoint, token: token)
                self.turnServers = servers
                print("[P2PConnectionController] Ephemeral TURN credentials updated: \(servers.count) servers found.")
            }
            
            // Reconnect signaling with updated token without tearing down active WebRTC call
            await client.connect()
            return
        }

        // Save credentials for network self-healing
        self.lastSavedApiEndpoint = apiEndpoint
        self.lastSavedToken = token
        self.hasGivenUpReconnecting = false // Reset given up state
        
        // Disconnect any existing session first (do NOT clear credentials)
        await disconnect(isUserInitiated: false)
        
        // Start network monitoring
        startPathMonitoring()
        
        print("[P2PConnectionController] Starting signaling connection...")
        statusDetail = "Connecting to signaling server..."
        
        self.turnServers = []
        Task {
            let servers = await fetchTurnCredentials(apiEndpoint: apiEndpoint, token: token)
            self.turnServers = servers
            print("[P2PConnectionController] Ephemeral TURN credentials loaded: \(servers.count) servers found.")
        }
        
        let client = SignalingClient(apiEndpoint: apiEndpoint, token: token)
        self.signalingClient = client
        Task {
            await client.setDelegate(self)
            await client.connect()
        }
    }
    
    func disconnect(isUserInitiated: Bool = false) async {
        if isUserInitiated {
            // User explicitly requested disconnect: stop monitoring and forget credentials
            self.lastSavedApiEndpoint = nil
            self.lastSavedToken = nil
            stopPathMonitoring()
        }
        
        let client = signalingClient
        signalingClient = nil
        
        if let callerId = currentCallerSocketId {
            print("[P2PConnectionController] Sending hang-up to peer \(callerId)...")
            await client?.sendHangUp(targetSocketId: callerId)
        }
        
        await client?.setDelegate(nil)
        await client?.disconnect()
        
        cleanupCall()
        statusDetail = "Disconnected"
    }
    
    private func startPathMonitoring() {
        guard pathMonitor == nil else { return }
        
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            Task { @MainActor in
                self?.handleNetworkPathUpdate(path)
            }
        }
        self.pathMonitor = monitor
        monitor.start(queue: pathMonitorQueue)
        print("[P2PConnectionController] Network path monitoring started.")
    }
    
    private func stopPathMonitoring() {
        print("[P2PConnectionController] Network path monitoring stopped.")
        pathMonitor?.cancel()
        pathMonitor = nil
    }
    
    private func handleNetworkPathUpdate(_ path: NWPath) {
        let isPathSatisfied = path.status == .satisfied
        print("[P2PConnectionController] Network path status updated: \(path.status), interfaces: \(path.availableInterfaces)")
        
        if !isPathSatisfied {
            self.wasOffline = true
        }
        
        // If network recovered from offline, or if we gave up reconnecting and the network is satisfied
        if isPathSatisfied && (self.wasOffline || self.hasGivenUpReconnecting) {
            self.wasOffline = false
            self.hasGivenUpReconnecting = false
            
            if let apiEndpoint = lastSavedApiEndpoint,
               let token = lastSavedToken {
                print("[P2PConnectionController] Network path is satisfied. Re-initiating signaling connection...")
                Task {
                    await startSignaling(apiEndpoint: apiEndpoint, token: token)
                }
            }
        }
    }
    
    func sendMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        
        guard isConnected else {
            appendSystemMessage("Cannot send message: Not connected to any peer", state: .error)
            return false
        }
        
        let sent = webRTCManager.sendMessage(trimmed)
        if sent {
            messages.append(ChatMessage(role: .user, text: trimmed, state: .final))
            return true
        } else {
            appendSystemMessage("Failed to send message over data channel", state: .error)
            return false
        }
    }
    
    func appendSystemMessage(_ text: String, state: ChatMessage.State = .error) {
        messages.append(ChatMessage(role: .system, text: text, state: state))
    }
    
    func clearMessages() {
        messages.removeAll()
        latestCompletedPeerMessage = nil
    }
    
    func playAudioBuffers(_ buffers: [AVAudioPCMBuffer], completion: @escaping @Sendable () -> Void) {
        webRTCManager.playAudioBuffers(buffers, completion: completion)
     }
     
     func stopAudioPlayback() {
         webRTCManager.stopAudioPlayback()
     }
     
     func playAudioFile(at url: URL, completion: @escaping @Sendable () -> Void) {
         webRTCManager.playAudioFile(at: url, completion: completion)
     }
     
     func startAudioStream(format: AVAudioFormat, completion: @escaping @Sendable () -> Void) {
         webRTCManager.startAudioStream(format: format, completion: completion)
     }
    
    func submitAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        webRTCManager.submitAudioBuffer(buffer)
    }
    
    func finishAudioStream() {
        webRTCManager.finishAudioStream()
    }
    
    func setMicrophoneMuted(_ isMuted: Bool) {
        webRTCManager.isMicrophoneMuted = isMuted
    }
    
    func setSpeakersMuted(_ isMuted: Bool) {
        webRTCManager.isSpeakersMuted = isMuted
    }
    
    // MARK: - Private Call Cleanup
    
    private func cleanupCall() {
        guard isConnected || currentCallerSocketId != nil else { return }
        webRTCManager.cleanup()
        isConnected = false
        currentCallerSocketId = nil
        peerUsername = nil
        
        if signalingClient != nil {
            statusDetail = "Waiting for browser connection..."
        } else {
            statusDetail = "Disconnected"
        }
    }
}

// MARK: - SignalingClientDelegate

extension P2PConnectionController: SignalingClientDelegate {
    public func signalingClientDidConnect(_ client: SignalingClient) {
        guard client === self.signalingClient else { return }
        print("[P2PConnectionController] Connected to signaling server successfully.")
        if isConnected || currentCallerSocketId != nil {
            let name = peerUsername ?? "Peer"
            statusDetail = "Connected to \(name)"
            appendSystemMessage("Signaling connection restored.", state: .final)
        } else {
            statusDetail = "Waiting for browser connection..."
            if messages.isEmpty {
                appendSystemMessage("Ready! Log in to the web app on another device to call this client.", state: .final)
            }
        }
    }
    
    public func signalingClientDidDisconnect(_ client: SignalingClient) {
        guard client === self.signalingClient else { return }
        print("[P2PConnectionController] Signaling client disconnected.")
        if signalingClient != nil {
            if isConnected || currentCallerSocketId != nil {
                statusDetail = "Signaling lost (call active)"
                appendSystemMessage("Connection to signaling server lost. Attempting to reconnect, call remains active...", state: .final)
            } else {
                statusDetail = "Disconnected from signaling server"
                cleanupCall()
            }
        } else {
            cleanupCall()
        }
    }
    
    public func signalingClient(_ client: SignalingClient, didReceiveIncomingCall callerSocketId: String, callerUsername: String, offer: [String: Any]) {
        guard client === self.signalingClient else { return }
        // If we are already connected to a peer, decline the incoming call or hang up the current connection.
        // For simplicity, we accept the new call and end the old one.
        if isConnected || currentCallerSocketId != nil {
            print("[P2PConnectionController] Already in call. Re-negotiating connection...")
            if let oldCallerId = currentCallerSocketId {
                let client = signalingClient
                Task {
                    await client?.sendHangUp(targetSocketId: oldCallerId)
                }
            }
            cleanupCall()
        } else {
            webRTCManager.clearPendingIceCandidates()
        }
        
        self.currentCallerSocketId = callerSocketId
        self.peerUsername = callerUsername
        
        statusDetail = "Fetching connection credentials..."
        
        let apiEndpoint = self.lastSavedApiEndpoint ?? ""
        let token = self.lastSavedToken ?? ""
        
        Task {
            // Fetch fresh credentials right before creating the connection to avoid expiration
            let servers = await fetchTurnCredentials(apiEndpoint: apiEndpoint, token: token)
            self.turnServers = servers
            
            print("[P2PConnectionController] Fresh ephemeral TURN credentials loaded for incoming call: \(servers.count) servers found.")
            
            // Check that we haven't hung up or started a different connection in the meantime
            guard self.signalingClient === client, self.currentCallerSocketId == callerSocketId else {
                print("[P2PConnectionController] Call context changed during credential fetch. Aborting incoming call setup.")
                return
            }
            
            print("[P2PConnectionController] Incoming call from \(callerUsername) (\(callerSocketId)). Creating PeerConnection...")
            
            let pcCreated = self.webRTCManager.createPeerConnection(iceServers: self.turnServers)
            guard pcCreated else {
                self.statusDetail = "Failed to create PeerConnection"
                self.appendSystemMessage("WebRTC error: Failed to create PeerConnection.", state: .error)
                return
            }
            
            self.statusDetail = "Negotiating connection..."
            
            self.webRTCManager.handleIncomingCall(offerSdp: offer["sdp"] as? String ?? "") { [weak self] result in
                guard let self = self else { return }
                guard client === self.signalingClient else { return }
                switch result {
                case .success(let localSdp):
                    print("[P2PConnectionController] Negotiation success. Sending SDP answer...")
                    let signaling = self.signalingClient
                    Task {
                        await signaling?.sendAnswer(
                            targetSocketId: callerSocketId,
                            answer: [
                                "type": "answer",
                                "sdp": localSdp.sdp
                            ] as [String: any Sendable]
                        )
                    }
                    self.statusDetail = "Connecting to \(callerUsername)..."
                case .failure(let error):
                    print("[P2PConnectionController] Negotiation failed: \(error.localizedDescription)")
                    self.statusDetail = "Failed to connect to \(callerUsername)"
                    self.appendSystemMessage("WebRTC offer processing failed: \(error.localizedDescription)", state: .error)
                    self.cleanupCall()
                }
            }
        }
    }
    
    public func signalingClient(_ client: SignalingClient, didReceiveIceCandidate senderSocketId: String, candidate: [String: Any]) {
        guard client === self.signalingClient else { return }
        guard senderSocketId == currentCallerSocketId else { return }
        
        guard let sdp = candidate["candidate"] as? String,
              let sdpMLineIndex = candidate["sdpMLineIndex"] as? Int32,
              let sdpMid = candidate["sdpMid"] as? String else {
            return
        }
        
        let rtcCandidate = RTCIceCandidate(
            sdp: sdp,
            sdpMLineIndex: sdpMLineIndex,
            sdpMid: sdpMid
        )
        webRTCManager.addIceCandidate(rtcCandidate)
    }
    
    public func signalingClient(_ client: SignalingClient, didReceiveHangUp senderSocketId: String) {
        guard client === self.signalingClient else { return }
        guard senderSocketId == currentCallerSocketId else { return }
        print("[P2PConnectionController] Peer \(peerUsername ?? senderSocketId) hung up.")
        appendSystemMessage("Peer ended connection.", state: .final)
        cleanupCall()
    }
    
    public func signalingClient(_ client: SignalingClient, didFailWithError error: Error) {
        guard client === self.signalingClient else { return }
        print("[P2PConnectionController] Signaling error: \(error.localizedDescription)")
        if isConnected || currentCallerSocketId != nil {
            appendSystemMessage("Signaling error: \(error.localizedDescription). Reconnecting...", state: .final)
        } else {
            statusDetail = "Signaling error"
            cleanupCall()
        }
    }
    
    public func signalingClient(_ client: SignalingClient, willAttemptReconnect attempt: Int, delay: TimeInterval) {
        guard client === self.signalingClient else { return }
        print("[P2PConnectionController] Signaling reconnect attempt \(attempt) in \(delay) seconds...")
        statusDetail = "Reconnecting (attempt \(attempt)/5)..."
        if isConnected || currentCallerSocketId != nil {
            appendSystemMessage("Connection lost. Reconnecting in \(Int(delay))s (attempt \(attempt)/5)...", state: .final)
        }
    }
    
    public func signalingClientDidGiveUpReconnect(_ client: SignalingClient) {
        guard client === self.signalingClient else { return }
        print("[P2PConnectionController] Signaling client gave up reconnecting.")
        self.hasGivenUpReconnecting = true
        statusDetail = "Connection lost"
        if isConnected || currentCallerSocketId != nil {
            appendSystemMessage("Signaling server connection lost permanently. Reconnect failed.", state: .error)
        }
        cleanupCall()
    }
}

// MARK: - WebRTCManagerDelegate

extension P2PConnectionController: WebRTCManagerDelegate {
    public func webRTCManager(_ manager: WebRTCManager, didChangeConnectionState state: RTCIceConnectionState) {
        print("[P2PConnectionController] WebRTC connection state changed: \(state.rawValue)")
        switch state {
        case .connected, .completed:
            isConnected = true
            let name = peerUsername ?? "Peer"
            statusDetail = "Connected to \(name)"
            appendSystemMessage("WebRTC connection established with \(name).", state: .final)
        case .disconnected:
            print("[P2PConnectionController] WebRTC connection disconnected. Waiting for recovery...")
            statusDetail = "Connection unstable"
            appendSystemMessage("WebRTC connection unstable. Attempting to recover...", state: .final)
        case .failed, .closed:
            print("[P2PConnectionController] WebRTC connection failed/closed. Cleaning up...")
            appendSystemMessage("WebRTC connection lost.", state: .error)
            cleanupCall()
        default:
            break
        }
    }
    
    public func webRTCManager(_ manager: WebRTCManager, didGenerateIceCandidate candidate: RTCIceCandidate) {
        guard let targetId = currentCallerSocketId else { return }
        
        let candidateDict: [String: any Sendable] = [
            "candidate": candidate.sdp,
            "sdpMLineIndex": candidate.sdpMLineIndex,
            "sdpMid": candidate.sdpMid ?? ""
        ]
        
        let client = signalingClient
        Task {
            await client?.sendIceCandidate(targetSocketId: targetId, candidate: candidateDict)
        }
    }
    
    public func webRTCManager(_ manager: WebRTCManager, didReceiveMessage message: String) {
        print("[P2PConnectionController] Message received over Data Channel: \(message)")
        // Publish the raw text so ContentView can forward it to the LLM agent
        latestReceivedPeerMessage = message
    }
    
    public func webRTCManager(_ manager: WebRTCManager, didChangeDataChannelState isOpen: Bool) {
        print("[P2PConnectionController] Data channel status changed: \(isOpen ? "Open" : "Closed")")
        if isOpen {
            isConnected = true
            let name = peerUsername ?? "Peer"
            statusDetail = "Connected to \(name)"
            appendSystemMessage("Secure end-to-end data channel established with \(name).", state: .final)
        } else {
            print("[P2PConnectionController] Data channel closed. Ending session.")
            cleanupCall()
        }
    }
}

// MARK: - LocalSignalingServerDelegate

extension P2PConnectionController: LocalSignalingServerDelegate {
    func startLocalServer(port: UInt16 = 8080) {
        isLocalServerEnabled = true
        localServer.start(port: port)
        statusDetail = "Local server: http://127.0.0.1:\(localServer.listeningPort)"
    }

    func stopLocalServer() {
        isLocalServerEnabled = false
        localServer.stop()
        statusDetail = "Local server stopped"
    }

    public func localSignalingServer(_ server: LocalSignalingServer, didReceiveOffer sdp: String) async throws -> String {
        webRTCManager.clearPendingIceCandidates()
        self.peerUsername = "Local Browser Client"
        self.isConnected = true
        
        let pcCreated = webRTCManager.createPeerConnection(iceServers: [])
        guard pcCreated else {
            throw NSError(domain: "P2PConnectionController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create WebRTC PeerConnection for local offer"])
        }

        return try await withCheckedThrowingContinuation { continuation in
            webRTCManager.handleIncomingCall(offerSdp: sdp) { result in
                switch result {
                case .success(let localSdp):
                    continuation.resume(returning: localSdp.sdp)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func localSignalingServer(_ server: LocalSignalingServer, didReceiveCandidate candidate: String, sdpMid: String?, sdpMLineIndex: Int32) async {
        let rtcCandidate = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        webRTCManager.addIceCandidate(rtcCandidate)
    }
}

