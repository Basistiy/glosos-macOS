//
//  WebRTCManager.swift
//  glosos-macOS
//
//  Created by Antigravity on 6/9/26.
//

import Foundation
import WebRTC

public protocol WebRTCManagerDelegate: AnyObject {
    func webRTCManager(_ manager: WebRTCManager, didChangeConnectionState state: RTCIceConnectionState)
    func webRTCManager(_ manager: WebRTCManager, didGenerateIceCandidate candidate: RTCIceCandidate)
    func webRTCManager(_ manager: WebRTCManager, didReceiveMessage message: String)
    func webRTCManager(_ manager: WebRTCManager, didChangeDataChannelState isOpen: Bool)
}

public final class WebRTCManager: NSObject {
    public weak var delegate: WebRTCManagerDelegate?
    
    private var peerConnectionFactory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    
    private static let stunServers = [
        "stun:stun.l.google.com:19302",
        "stun:stun1.l.google.com:19302",
        "stun:stun2.l.google.com:19302"
    ]
    
    public override init() {
        RTCInitializeSSL()
        self.peerConnectionFactory = RTCPeerConnectionFactory()
        super.init()
    }
    
    deinit {
        cleanup()
        RTCCleanupSSL()
    }
    
    public func createPeerConnection() -> Bool {
        cleanup()
        
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: Self.stunServers)]
        config.sdpSemantics = .unifiedPlan
        
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        
        guard let pc = peerConnectionFactory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            print("[WebRTCManager] Failed to create RTCPeerConnection.")
            return false
        }
        
        self.peerConnection = pc
        print("[WebRTCManager] RTCPeerConnection created successfully.")
        return true
    }
    
    public func handleIncomingCall(offerSdp: String, completion: @escaping (Result<RTCSessionDescription, Error>) -> Void) {
        guard let pc = peerConnection else {
            let error = NSError(domain: "WebRTCManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "PeerConnection is not initialized"])
            completion(.failure(error))
            return
        }
        
        let remoteDescription = RTCSessionDescription(type: .offer, sdp: offerSdp)
        
        pc.setRemoteDescription(remoteDescription) { [weak self] error in
            if let error = error {
                print("[WebRTCManager] SetRemoteDescription (Offer) failed: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            
            print("[WebRTCManager] SetRemoteDescription (Offer) succeeded.")
            
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            pc.answer(for: constraints) { [weak self] localSdp, error in
                guard let self = self else { return }
                
                if let error = error {
                    print("[WebRTCManager] CreateAnswer failed: \(error.localizedDescription)")
                    completion(.failure(error))
                    return
                }
                
                guard let localSdp = localSdp else {
                    let error = NSError(domain: "WebRTCManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Created Answer was nil"])
                    completion(.failure(error))
                    return
                }
                
                pc.setLocalDescription(localSdp) { error in
                    if let error = error {
                        print("[WebRTCManager] SetLocalDescription (Answer) failed: \(error.localizedDescription)")
                        completion(.failure(error))
                        return
                    }
                    
                    print("[WebRTCManager] SetLocalDescription (Answer) succeeded. Sending answer...")
                    completion(.success(localSdp))
                }
            }
        }
    }
    
    public func addIceCandidate(_ candidate: RTCIceCandidate) {
        guard let pc = peerConnection else {
            print("[WebRTCManager] Cannot add ICE candidate: peerConnection is nil")
            return
        }
        pc.add(candidate) { error in
            if let error = error {
                print("[WebRTCManager] Failed to add ICE candidate: \(error.localizedDescription)")
            } else {
                // print("[WebRTCManager] Added remote ICE candidate successfully")
            }
        }
    }
    
    public func sendMessage(_ text: String) -> Bool {
        guard let channel = dataChannel, channel.readyState == .open else {
            print("[WebRTCManager] Cannot send message: Data channel is not open")
            return false
        }
        
        guard let data = text.data(using: .utf8) else {
            return false
        }
        
        let buffer = RTCDataBuffer(data: data, isBinary: false)
        return channel.sendData(buffer)
    }
    
    public func cleanup() {
        print("[WebRTCManager] Cleaning up WebRTC resources...")
        if let channel = dataChannel {
            channel.close()
            dataChannel = nil
        }
        if let pc = peerConnection {
            pc.close()
            peerConnection = nil
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCManager: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("[WebRTCManager] Signaling state changed: \(stateChanged.rawValue)")
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        // We only use data channel, but this might fire
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
    }
    
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("[WebRTCManager] peerConnectionShouldNegotiate triggered.")
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("[WebRTCManager] ICE connection state changed: \(newState.rawValue)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.webRTCManager(self, didChangeConnectionState: newState)
        }
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("[WebRTCManager] ICE gathering state changed: \(newState.rawValue)")
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // print("[WebRTCManager] Generated local ICE candidate: \(candidate.sdp)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.webRTCManager(self, didGenerateIceCandidate: candidate)
        }
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("[WebRTCManager] Remote peer opened data channel '\(dataChannel.label)'.")
        self.dataChannel = dataChannel
        dataChannel.delegate = self
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.webRTCManager(self, didChangeDataChannelState: dataChannel.readyState == .open)
        }
    }
}

// MARK: - RTCDataChannelDelegate

extension WebRTCManager: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        print("[WebRTCManager] Data channel '\(dataChannel.label)' state changed: \(dataChannel.readyState.rawValue)")
        let isOpen = (dataChannel.readyState == .open)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.webRTCManager(self, didChangeDataChannelState: isOpen)
        }
    }
    
    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary else {
            print("[WebRTCManager] Received binary message on data channel. Ignoring.")
            return
        }
        
        guard let message = String(data: buffer.data, encoding: .utf8) else {
            return
        }
        
        print("[WebRTCManager] Received message: \(message)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.webRTCManager(self, didReceiveMessage: message)
        }
    }
}
