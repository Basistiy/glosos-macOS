//
//  P2PConnectionController.swift
//  glosos-macOS
//
//  Created by Antigravity on 6/9/26.
//

import Foundation
import Combine
import WebRTC

@MainActor
final class P2PConnectionController: ObservableObject {
    private(set) var isConnected = false
    private(set) var statusDetail = "Disconnected"
    var messages: [ChatMessage] = []
    var latestCompletedPeerMessage: ChatMessage?
    
    private var signalingClient: SignalingClient?
    private let webRTCManager: WebRTCManager
    
    private var currentCallerSocketId: String?
    private var peerUsername: String?
    
    init() {
        self.webRTCManager = WebRTCManager()
        self.webRTCManager.delegate = self
    }
    
    func startSignaling(apiEndpoint: String, token: String) {
        // Disconnect any existing session first
        disconnect()
        
        print("[P2PConnectionController] Starting signaling connection...")
        statusDetail = "Connecting to signaling server..."
        
        let client = SignalingClient(apiEndpoint: apiEndpoint, token: token)
        client.delegate = self
        self.signalingClient = client
        client.connect()
    }
    
    func disconnect() {
        if let callerId = currentCallerSocketId {
            print("[P2PConnectionController] Sending hang-up to peer \(callerId)...")
            signalingClient?.sendHangUp(targetSocketId: callerId)
        }
        
        signalingClient?.disconnect()
        signalingClient = nil
        
        cleanupCall()
        statusDetail = "Disconnected"
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
    
    // MARK: - Private Call Cleanup
    
    private func cleanupCall() {
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
        print("[P2PConnectionController] Connected to signaling server successfully.")
        statusDetail = "Waiting for browser connection..."
        appendSystemMessage("Ready! Log in to the web app on another device to call this client.", state: .final)
    }
    
    public func signalingClientDidDisconnect(_ client: SignalingClient) {
        print("[P2PConnectionController] Signaling client disconnected.")
        if signalingClient != nil {
            statusDetail = "Disconnected from signaling server"
            appendSystemMessage("Connection to signaling server lost.", state: .error)
        }
        cleanupCall()
    }
    
    public func signalingClient(_ client: SignalingClient, didReceiveIncomingCall callerSocketId: String, callerUsername: String, offer: [String: Any]) {
        // If we are already connected to a peer, decline the incoming call or hang up the current connection.
        // For simplicity, we accept the new call and end the old one.
        if isConnected || currentCallerSocketId != nil {
            print("[P2PConnectionController] Already in call. Re-negotiating connection...")
            if let oldCallerId = currentCallerSocketId {
                signalingClient?.sendHangUp(targetSocketId: oldCallerId)
            }
            cleanupCall()
        }
        
        self.currentCallerSocketId = callerSocketId
        self.peerUsername = callerUsername
        
        print("[P2PConnectionController] Incoming call from \(callerUsername) (\(callerSocketId)). Creating PeerConnection...")
        
        let pcCreated = webRTCManager.createPeerConnection()
        guard pcCreated else {
            statusDetail = "Failed to create PeerConnection"
            appendSystemMessage("WebRTC error: Failed to create PeerConnection.", state: .error)
            return
        }
        
        statusDetail = "Negotiating connection..."
        
        webRTCManager.handleIncomingCall(offerSdp: offer["sdp"] as? String ?? "") { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let localSdp):
                print("[P2PConnectionController] Negotiation success. Sending SDP answer...")
                self.signalingClient?.sendAnswer(
                    targetSocketId: callerSocketId,
                    answer: [
                        "type": "answer",
                        "sdp": localSdp.sdp
                    ]
                )
                self.statusDetail = "Connecting to \(callerUsername)..."
            case .failure(let error):
                print("[P2PConnectionController] Negotiation failed: \(error.localizedDescription)")
                self.statusDetail = "Failed to connect to \(callerUsername)"
                self.appendSystemMessage("WebRTC offer processing failed: \(error.localizedDescription)", state: .error)
                self.cleanupCall()
            }
        }
    }
    
    public func signalingClient(_ client: SignalingClient, didReceiveIceCandidate senderSocketId: String, candidate: [String: Any]) {
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
        guard senderSocketId == currentCallerSocketId else { return }
        print("[P2PConnectionController] Peer \(peerUsername ?? senderSocketId) hung up.")
        appendSystemMessage("Peer ended connection.", state: .final)
        cleanupCall()
    }
    
    public func signalingClient(_ client: SignalingClient, didFailWithError error: Error) {
        print("[P2PConnectionController] Signaling error: \(error.localizedDescription)")
        statusDetail = "Signaling error"
        appendSystemMessage("Signaling error: \(error.localizedDescription)", state: .error)
        cleanupCall()
    }
}

// MARK: - WebRTCManagerDelegate

extension P2PConnectionController: WebRTCManagerDelegate {
    public func webRTCManager(_ manager: WebRTCManager, didChangeConnectionState state: RTCIceConnectionState) {
        print("[P2PConnectionController] WebRTC connection state changed: \(state.rawValue)")
        switch state {
        case .connected, .completed:
            // Handled when data channel opens as well
            break
        case .disconnected, .failed, .closed:
            print("[P2PConnectionController] WebRTC connection failed/closed. Cleaning up...")
            appendSystemMessage("WebRTC connection lost.", state: .error)
            cleanupCall()
        default:
            break
        }
    }
    
    public func webRTCManager(_ manager: WebRTCManager, didGenerateIceCandidate candidate: RTCIceCandidate) {
        guard let targetId = currentCallerSocketId else { return }
        
        let candidateDict: [String: Any] = [
            "candidate": candidate.sdp,
            "sdpMLineIndex": candidate.sdpMLineIndex,
            "sdpMid": candidate.sdpMid ?? ""
        ]
        
        // print("[P2PConnectionController] Sending local ICE candidate to \(targetId)...")
        signalingClient?.sendIceCandidate(targetSocketId: targetId, candidate: candidateDict)
    }
    
    public func webRTCManager(_ manager: WebRTCManager, didReceiveMessage message: String) {
        print("[P2PConnectionController] Message received over Data Channel: \(message)")
        let chatMsg = ChatMessage(role: .assistant, text: message, state: .final)
        messages.append(chatMsg)
        latestCompletedPeerMessage = chatMsg
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
