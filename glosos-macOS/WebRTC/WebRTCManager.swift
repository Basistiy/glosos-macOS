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
    private var pendingIceCandidates: [RTCIceCandidate] = []
    
    private var localAudioTrack: RTCAudioTrack?
    private var playerNode: AVAudioPlayerNode?
    private var mixerNode: AVAudioMixerNode?
    
    private var activeBuffersCount = 0
    private let bufferLock = NSLock()
    private var onPlaybackFinished: (() -> Void)?
    
    public var onIncomingAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    
    public var isMicrophoneMuted: Bool = false {
        didSet {
            localAudioTrack?.isEnabled = !isMicrophoneMuted
            print("[WebRTCManager] Microphone mute state changed to: \(isMicrophoneMuted), track isEnabled: \(localAudioTrack?.isEnabled ?? false)")
        }
    }
    
    private let mixerLock = NSLock()
    private weak var outputMixer: AVAudioMixerNode?
    private weak var audioEngine: AVAudioEngine?
    
    public var isSpeakersMuted: Bool = true {
        didSet {
            updateSpeakersMuteState()
        }
    }
    
    private func updateSpeakersMuteState() {
        mixerLock.lock()
        let mixer = outputMixer
        mixerLock.unlock()
        
        let volume: Float = isSpeakersMuted ? 0.0 : 1.0
        if let mixer = mixer {
            mixer.outputVolume = volume
            print("[WebRTCManager] Set custom output mixer volume to \(volume)")
        }
    }
    
    private static let stunServers = [
        "stun:stun.l.google.com:19302",
        "stun:stun1.l.google.com:19302",
        "stun:stun2.l.google.com:19302"
    ]
    
    public override init() {
        RTCInitializeSSL()
        self.peerConnectionFactory = RTCPeerConnectionFactory(
            audioDeviceModuleType: .audioEngine,
            bypassVoiceProcessing: true,
            encoderFactory: nil,
            decoderFactory: nil,
            audioProcessingModule: nil
        )
        super.init()
    }
    
    deinit {
        cleanup()
        RTCCleanupSSL()
    }
    
    public func createPeerConnection(iceServers: [RTCIceServer] = []) -> Bool {
        cleanup()
        
        let config = RTCConfiguration()
        var servers = [RTCIceServer(urlStrings: Self.stunServers)]
        servers.append(contentsOf: iceServers)
        config.iceServers = servers
        config.sdpSemantics = .unifiedPlan
        
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        
        guard let pc = peerConnectionFactory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            print("[WebRTCManager] Failed to create RTCPeerConnection.")
            return false
        }
        
        self.peerConnection = pc
        
        // Configure ADM observer
        peerConnectionFactory.audioDeviceModule.observer = self
        
        // Add local audio track
        let audioSource = peerConnectionFactory.audioSource(with: nil)
        let audioTrack = peerConnectionFactory.audioTrack(with: audioSource, trackId: "audio0")
        audioTrack.isEnabled = !isMicrophoneMuted
        pc.add(audioTrack, streamIds: ["stream0"])
        self.localAudioTrack = audioTrack
        
        print("[WebRTCManager] RTCPeerConnection created successfully with local audio track.")
        return true
    }
    
    public func handleIncomingCall(offerSdp: String, completion: @escaping (Result<RTCSessionDescription, Error>) -> Void) {
        guard let pc = peerConnection else {
            let error = NSError(domain: "WebRTCManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "PeerConnection is not initialized"])
            DispatchQueue.main.async { completion(.failure(error)) }
            return
        }
        
        let remoteDescription = RTCSessionDescription(type: .offer, sdp: offerSdp)
        
        pc.setRemoteDescription(remoteDescription) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                print("[WebRTCManager] SetRemoteDescription (Offer) failed: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            
            print("[WebRTCManager] SetRemoteDescription (Offer) succeeded.")
            self.flushPendingIceCandidates()
            
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            pc.answer(for: constraints) { [weak self] localSdp, error in
                guard let self = self else { return }
                
                if let error = error {
                    print("[WebRTCManager] CreateAnswer failed: \(error.localizedDescription)")
                    DispatchQueue.main.async { completion(.failure(error)) }
                    return
                }
                
                guard let localSdp = localSdp else {
                    let error = NSError(domain: "WebRTCManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Created Answer was nil"])
                    DispatchQueue.main.async { completion(.failure(error)) }
                    return
                }
                
                pc.setLocalDescription(localSdp) { error in
                    if let error = error {
                        print("[WebRTCManager] SetLocalDescription (Answer) failed: \(error.localizedDescription)")
                        DispatchQueue.main.async { completion(.failure(error)) }
                        return
                    }
                    
                    print("[WebRTCManager] SetLocalDescription (Answer) succeeded. Sending answer...")
                    DispatchQueue.main.async { completion(.success(localSdp)) }
                }
            }
        }
    }
    
    public func addIceCandidate(_ candidate: RTCIceCandidate) {
        guard let pc = peerConnection else {
            print("[WebRTCManager] Cannot add ICE candidate: peerConnection is nil")
            return
        }
        
        if pc.remoteDescription != nil {
            pc.add(candidate) { error in
                if let error = error {
                    print("[WebRTCManager] Failed to add ICE candidate: \(error.localizedDescription)")
                }
            }
        } else {
            print("[WebRTCManager] Queuing remote ICE candidate (remote description not set)")
            pendingIceCandidates.append(candidate)
        }
    }
    
    private func flushPendingIceCandidates() {
        guard let pc = peerConnection else { return }
        guard !pendingIceCandidates.isEmpty else { return }
        
        print("[WebRTCManager] Flushing \(pendingIceCandidates.count) pending remote ICE candidates")
        let candidates = pendingIceCandidates
        pendingIceCandidates.removeAll()
        
        for candidate in candidates {
            pc.add(candidate) { error in
                if let error = error {
                    print("[WebRTCManager] Failed to add flushed ICE candidate: \(error.localizedDescription)")
                }
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
        localAudioTrack = nil
        pendingIceCandidates.removeAll()
        playerNode = nil
        mixerNode = nil
        
        mixerLock.lock()
        outputMixer = nil
        audioEngine = nil
        mixerLock.unlock()
        
        bufferLock.lock()
        activeBuffersCount = 0
        onPlaybackFinished = nil
        bufferLock.unlock()
    }
    
    public func playAudioBuffers(_ buffers: [AVAudioPCMBuffer], completion: @escaping () -> Void) {
        guard let player = playerNode, let mixer = mixerNode, let engine = player.engine, !buffers.isEmpty else {
            completion()
            return
        }
        
        if let firstBuffer = buffers.first {
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: mixer, format: firstBuffer.format)
            print("[WebRTCManager] Playing audio buffers with format: \(firstBuffer.format) (reconnected player to mixer)")
        }
        
        bufferLock.lock()
        activeBuffersCount = buffers.count
        onPlaybackFinished = completion
        bufferLock.unlock()
        
        if !player.isPlaying {
            player.play()
        }
        
        for buffer in buffers {
            player.scheduleBuffer(buffer) { [weak self] in
                guard let self = self else { return }
                self.bufferLock.lock()
                self.activeBuffersCount -= 1
                let count = self.activeBuffersCount
                let callback = self.onPlaybackFinished
                if count == 0 {
                    self.onPlaybackFinished = nil
                }
                self.bufferLock.unlock()
                
                if count == 0 {
                    DispatchQueue.main.async {
                        callback?()
                    }
                }
            }
        }
    }
    
    public func playAudioFile(at url: URL, completion: @escaping () -> Void) {
        guard let player = playerNode, let engine = player.engine else {
            print("[WebRTCManager] [Warning] playAudioFile called but playerNode or engine is nil")
            completion()
            return
        }
        
        do {
            let file = try AVAudioFile(forReading: url)
            
            print("[WebRTCManager] Playing resampled audio file with format: \(file.processingFormat)")
            
            bufferLock.lock()
            activeBuffersCount = 1
            onPlaybackFinished = completion
            bufferLock.unlock()
            
            if !player.isPlaying {
                player.play()
            }
            
            player.scheduleFile(file, at: nil) { [weak self] in
                guard let self = self else { return }
                self.bufferLock.lock()
                self.activeBuffersCount = 0
                let callback = self.onPlaybackFinished
                self.onPlaybackFinished = nil
                self.bufferLock.unlock()
                
                DispatchQueue.main.async {
                    callback?()
                }
            }
        } catch {
            print("[WebRTCManager] Failed to read audio file for playback: \(error.localizedDescription)")
            completion()
        }
    }
    
    public func stopAudioPlayback() {
        print("[WebRTCManager] Stopping audio player node.")
        playerNode?.stop()
        bufferLock.lock()
        activeBuffersCount = 0
        onPlaybackFinished = nil
        bufferLock.unlock()
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

// MARK: - RTCAudioDeviceModuleDelegate

extension WebRTCManager: RTCAudioDeviceModuleDelegate {
    public func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, didReceiveSpeechActivityEvent speechActivityEvent: RTCSpeechActivityEvent) {
        print("[WebRTCManager] audioDeviceModule didReceiveSpeechActivityEvent: \(speechActivityEvent.rawValue)")
    }
    
    public func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, didCreateEngine engine: AVAudioEngine) -> Int {
        print("[WebRTCManager] audioDeviceModule didCreateEngine called.")
        return 0
    }
    
    public func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, willEnableEngine engine: AVAudioEngine, isPlayoutEnabled playoutEnabled: Bool, isRecordingEnabled recordingEnabled: Bool) -> Int {
        print("[WebRTCManager] audioDeviceModule willEnableEngine. Playout: \(playoutEnabled), Recording: \(recordingEnabled)")
        return 0
    }
    
    public func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, willStartEngine engine: AVAudioEngine, isPlayoutEnabled playoutEnabled: Bool, isRecordingEnabled recordingEnabled: Bool) -> Int {
        print("[WebRTCManager] audioDeviceModule willStartEngine. Playout: \(playoutEnabled), Recording: \(recordingEnabled)")
        return 0
    }
    
    public func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, didStopEngine engine: AVAudioEngine, isPlayoutEnabled playoutEnabled: Bool, isRecordingEnabled recordingEnabled: Bool) -> Int {
        print("[WebRTCManager] audioDeviceModule didStopEngine. Playout: \(playoutEnabled), Recording: \(recordingEnabled)")
        return 0
    }
    
    public func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, didDisableEngine engine: AVAudioEngine, isPlayoutEnabled playoutEnabled: Bool, isRecordingEnabled recordingEnabled: Bool) -> Int {
        print("[WebRTCManager] audioDeviceModule didDisableEngine. Playout: \(playoutEnabled), Recording: \(recordingEnabled)")
        return 0
    }
    
    public func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine) -> Int {
        print("[WebRTCManager] audioDeviceModule willReleaseEngine called.")
        return 0
    }
    
    public func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, engine: AVAudioEngine, configureInputFromSource source: AVAudioNode?, toDestination destination: AVAudioNode, format: AVAudioFormat, context: [AnyHashable : Any]) -> Int {
        print("[WebRTCManager] configureInputFromSource called. Format: \(format)")
        
        // Break any default connections WebRTC might have made for input
        if let src = source {
            engine.disconnectNodeOutput(src)
        }
        engine.disconnectNodeInput(destination)
        
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        
        engine.attach(player)
        engine.attach(mixer)
        
        // Connect the player to the mixer using format
        engine.connect(player, to: mixer, format: format)
        
        // Connect the physical microphone (source) to the mixer using WebRTC's mono format
        if let src = source {
            print("[WebRTCManager] Connecting input source with WebRTC format: \(format)")
            engine.connect(src, to: mixer, format: format)
        }
        
        // Connect the mixer to WebRTC's input destination
        engine.connect(mixer, to: destination, format: format)
        
        self.playerNode = player
        self.mixerNode = mixer
        
        return 0
    }
    
    public func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, engine: AVAudioEngine, configureOutputFromSource source: AVAudioNode, toDestination destination: AVAudioNode?, format: AVAudioFormat, context: [AnyHashable : Any]) -> Int {
        print("[WebRTCManager] configureOutputFromSource called. Format: \(format)")
        
        // Break any default connections WebRTC/engine might have made
        engine.disconnectNodeOutput(source)
        if let dest = destination {
            engine.disconnectNodeInput(dest)
        }
        
        let localOutputMixer = AVAudioMixerNode()
        engine.attach(localOutputMixer)
        
        // Connect source -> localOutputMixer -> destination (or mainMixerNode if destination is nil)
        engine.connect(source, to: localOutputMixer, format: format)
        
        let finalDest = destination ?? engine.mainMixerNode
        engine.connect(localOutputMixer, to: finalDest, format: format)
        
        mixerLock.lock()
        self.outputMixer = localOutputMixer
        self.audioEngine = engine
        localOutputMixer.outputVolume = isSpeakersMuted ? 0.0 : 1.0
        mixerLock.unlock()
        
        print("[WebRTCManager] Configured custom output mixer node with volume: \(localOutputMixer.outputVolume)")
        
        // Keep mainMixerNode outputVolume at 1.0 to ensure voice processing / downlink DSP works
        engine.mainMixerNode.outputVolume = 1.0
        
        source.removeTap(onBus: 0)
        source.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] (buffer, time) in
            guard let self = self else { return }
            self.onIncomingAudioBuffer?(buffer)
        }
        
        return 0
    }
    
    public func audioDeviceModuleDidUpdateDevices(_ audioDeviceModule: RTCAudioDeviceModule) {
        print("[WebRTCManager] audioDeviceModuleDidUpdateDevices called.")
    }
    
    public func audioDeviceModule(_ module: RTCAudioDeviceModule, didUpdateAudioProcessingState state: RTCAudioProcessingState) {
        print("[WebRTCManager] audioDeviceModule didUpdateAudioProcessingState: voiceProcessingEnabled=\(state.voiceProcessingEnabled)")
    }
}
