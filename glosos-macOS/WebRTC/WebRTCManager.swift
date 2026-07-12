//
//  WebRTCManager.swift
//  glosos-macOS
//
//  Created by Antigravity on 6/9/26.
//

import Foundation
@preconcurrency import WebRTC
import AVFoundation

extension RTCSessionDescription: @unchecked Sendable {}
extension RTCIceCandidate: @unchecked Sendable {}

@MainActor
public protocol WebRTCManagerDelegate: AnyObject {
    func webRTCManager(_ manager: WebRTCManager, didChangeConnectionState state: RTCIceConnectionState)
    func webRTCManager(_ manager: WebRTCManager, didGenerateIceCandidate candidate: RTCIceCandidate)
    func webRTCManager(_ manager: WebRTCManager, didReceiveMessage message: String)
    func webRTCManager(_ manager: WebRTCManager, didChangeDataChannelState isOpen: Bool)
}

// Thread-safe container to protect audio engine state accessed concurrently by real-time rendering threads and WebRTC setup callbacks.
private nonisolated final class WebRTCAudioState: @unchecked Sendable {
    private let lock = NSLock()
    
    private var _onIncomingAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var _activeBuffersCount = 0
    private var _onPlaybackFinished: (@Sendable () -> Void)?
    
    private var _streamBuffersCount = 0
    private var _streamCompletion: (@Sendable () -> Void)?
    private var _streamFinishedSending = false
    
    private weak var _outputMixer: AVAudioMixerNode?
    private weak var _audioEngine: AVAudioEngine?
    
    private var _playerNode: AVAudioPlayerNode?
    private var _micMixerNode: AVAudioMixerNode?
    private var _mainMixerNode: AVAudioMixerNode?
    private var _physicalInputNode: AVAudioNode?
    private var _inputDestinationNode: AVAudioNode?
    private var _inputFormat: AVAudioFormat?
    
    private var _isSpeakersMuted = true
    
    var isSpeakersMuted: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isSpeakersMuted
        }
        set {
            lock.lock()
            _isSpeakersMuted = newValue
            lock.unlock()
        }
    }
    
    var onIncomingAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onIncomingAudioBuffer
        }
        set {
            lock.lock()
            _onIncomingAudioBuffer = newValue
            lock.unlock()
        }
    }
    
    var activeBuffersCount: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _activeBuffersCount
        }
        set {
            lock.lock()
            _activeBuffersCount = newValue
            lock.unlock()
        }
    }
    
    var onPlaybackFinished: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onPlaybackFinished
        }
        set {
            lock.lock()
            _onPlaybackFinished = newValue
            lock.unlock()
        }
    }
    
    var streamBuffersCount: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _streamBuffersCount
        }
        set {
            lock.lock()
            _streamBuffersCount = newValue
            lock.unlock()
        }
    }
    
    var streamCompletion: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _streamCompletion
        }
        set {
            lock.lock()
            _streamCompletion = newValue
            lock.unlock()
        }
    }
    
    var streamFinishedSending: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _streamFinishedSending
        }
        set {
            lock.lock()
            _streamFinishedSending = newValue
            lock.unlock()
        }
    }
    
    var outputMixer: AVAudioMixerNode? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _outputMixer
        }
        set {
            lock.lock()
            _outputMixer = newValue
            lock.unlock()
        }
    }
    
    var audioEngine: AVAudioEngine? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _audioEngine
        }
        set {
            lock.lock()
            _audioEngine = newValue
            lock.unlock()
        }
    }
    
    var playerNode: AVAudioPlayerNode? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _playerNode
        }
        set {
            lock.lock()
            _playerNode = newValue
            lock.unlock()
        }
    }
    
    var micMixerNode: AVAudioMixerNode? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _micMixerNode
        }
        set {
            lock.lock()
            _micMixerNode = newValue
            lock.unlock()
        }
    }
    
    var mainMixerNode: AVAudioMixerNode? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _mainMixerNode
        }
        set {
            lock.lock()
            _mainMixerNode = newValue
            lock.unlock()
        }
    }
    
    var physicalInputNode: AVAudioNode? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _physicalInputNode
        }
        set {
            lock.lock()
            _physicalInputNode = newValue
            lock.unlock()
        }
    }
    
    var inputDestinationNode: AVAudioNode? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _inputDestinationNode
        }
        set {
            lock.lock()
            _inputDestinationNode = newValue
            lock.unlock()
        }
    }
    
    var inputFormat: AVAudioFormat? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _inputFormat
        }
        set {
            lock.lock()
            _inputFormat = newValue
            lock.unlock()
        }
    }
    
    func decrementActiveBuffers() -> (Int, (@Sendable () -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        _activeBuffersCount -= 1
        let count = _activeBuffersCount
        let callback = _onPlaybackFinished
        if count == 0 {
            _onPlaybackFinished = nil
        }
        return (count, callback)
    }
    
    func resetPlayback() {
        lock.lock()
        _activeBuffersCount = 0
        _onPlaybackFinished = nil
        lock.unlock()
    }
    
    func incrementStreamBuffers() {
        lock.lock()
        _streamBuffersCount += 1
        lock.unlock()
    }
    
    func decrementStreamBuffers() -> (Int, (@Sendable () -> Void)?, Bool) {
        lock.lock()
        defer { lock.unlock() }
        _streamBuffersCount -= 1
        return (_streamBuffersCount, _streamCompletion, _streamFinishedSending)
    }
    
    func finishStreamSending() -> (Int, (@Sendable () -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        _streamFinishedSending = true
        return (_streamBuffersCount, _streamCompletion)
    }
    
    func clearStream() {
        lock.lock()
        _streamBuffersCount = 0
        _streamCompletion = nil
        _streamFinishedSending = false
        lock.unlock()
    }
    
    func clearAudioGraph() {
        lock.lock()
        _playerNode = nil
        _micMixerNode = nil
        _mainMixerNode = nil
        _physicalInputNode = nil
        _inputDestinationNode = nil
        _inputFormat = nil
        _outputMixer = nil
        _audioEngine = nil
        _activeBuffersCount = 0
        _onPlaybackFinished = nil
        lock.unlock()
    }
}

@MainActor
public final class WebRTCManager: NSObject {
    public weak var delegate: WebRTCManagerDelegate?
    
    private var peerConnectionFactory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var pendingIceCandidates: [RTCIceCandidate] = []
    
    private let audioState = WebRTCAudioState()
    
    public var onIncomingAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { audioState.onIncomingAudioBuffer }
        set { audioState.onIncomingAudioBuffer = newValue }
    }
    
    public var isMicrophoneMuted: Bool = false {
        didSet {
            localAudioTrack?.isEnabled = !isMicrophoneMuted
            print("[WebRTCManager] Microphone mute state changed to: \(isMicrophoneMuted), track isEnabled: \(localAudioTrack?.isEnabled ?? false)")
        }
    }
    
    private var localAudioTrack: RTCAudioTrack?
    
    public var isSpeakersMuted: Bool = true {
        didSet {
            audioState.isSpeakersMuted = isSpeakersMuted
            updateSpeakersMuteState()
        }
    }
    
    private func updateSpeakersMuteState() {
        let mixer = audioState.outputMixer
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
        let pc = self.peerConnection
        let dc = self.dataChannel
        let state = self.audioState
        DispatchQueue.main.async {
            dc?.close()
            pc?.close()
            state.clearAudioGraph()
        }
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
        
        // Configure ADM observer and disable voice processing
        let adm = peerConnectionFactory.audioDeviceModule
        adm.observer = self
        _ = adm.setVoiceProcessingEnabled(false)
        adm.isVoiceProcessingBypassed = true
        
        // Add local audio track
        let audioSource = peerConnectionFactory.audioSource(with: nil)
        let audioTrack = peerConnectionFactory.audioTrack(with: audioSource, trackId: "audio0")
        audioTrack.isEnabled = !isMicrophoneMuted
        pc.add(audioTrack, streamIds: ["stream0"])
        self.localAudioTrack = audioTrack
        
        print("[WebRTCManager] RTCPeerConnection created successfully with local audio track.")
        return true
    }
    
    public func handleIncomingCall(offerSdp: String, completion: @escaping @Sendable @MainActor (Result<RTCSessionDescription, Error>) -> Void) {
        guard let pc = peerConnection else {
            let error = NSError(domain: "WebRTCManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "PeerConnection is not initialized"])
            completion(.failure(error))
            return
        }
        
        let remoteDescription = RTCSessionDescription(type: .offer, sdp: offerSdp)
        
        pc.setRemoteDescription(remoteDescription) { [weak self] error in
            Task { @MainActor in
                guard let self = self else { return }
                if let error = error {
                    print("[WebRTCManager] SetRemoteDescription (Offer) failed: \(error.localizedDescription)")
                    completion(.failure(error))
                    return
                }
                
                print("[WebRTCManager] SetRemoteDescription (Offer) succeeded.")
                self.flushPendingIceCandidates()
                
                let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
                pc.answer(for: constraints) { [weak self] localSdp, error in
                    Task { @MainActor in
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
                            Task { @MainActor in
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
        audioState.clearAudioGraph()
    }
    
    private func monoFormat(for format: AVAudioFormat) -> AVAudioFormat {
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false) ?? format
    }
    
    public func playAudioBuffers(_ buffers: [AVAudioPCMBuffer], completion: @escaping @Sendable () -> Void) {
        guard let player = audioState.playerNode,
              let mixer = audioState.mainMixerNode,
              let engine = player.engine, !buffers.isEmpty else {
            completion()
            return
        }
        
        if let firstBuffer = buffers.first {
            engine.disconnectNodeOutput(player)
            let connectionFormat = monoFormat(for: firstBuffer.format)
            engine.connect(player, to: mixer, format: connectionFormat)
            print("[WebRTCManager] Playing audio buffers with format: \(connectionFormat) (reconnected player to mainMixerNode)")
        }
        
        audioState.activeBuffersCount = buffers.count
        audioState.onPlaybackFinished = completion
        
        if !player.isPlaying {
            player.play()
        }
        
        let state = self.audioState
        for buffer in buffers {
            player.scheduleBuffer(buffer) {
                let (count, callback) = state.decrementActiveBuffers()
                if count == 0 {
                    DispatchQueue.main.async {
                        callback?()
                    }
                }
            }
        }
    }
    
    public func playAudioFile(at url: URL, completion: @escaping @Sendable () -> Void) {
        guard let player = audioState.playerNode,
              let micMixer = audioState.micMixerNode,
              let mainMixer = audioState.mainMixerNode,
              let dest = audioState.inputDestinationNode,
              let format = audioState.inputFormat,
              let engine = player.engine else {
            print("[WebRTCManager] [Warning] playAudioFile called but playerNode, micMixerNode, mainMixerNode, inputDestinationNode, inputFormat, or engine is nil")
            completion()
            return
        }
        
        do {
            let file = try AVAudioFile(forReading: url)
            
            print("[WebRTCManager] Playing resampled audio file with format: \(file.processingFormat)")
            
            engine.disconnectNodeOutput(player)
            if let src = audioState.physicalInputNode {
                engine.disconnectNodeOutput(src)
            }
            engine.disconnectNodeOutput(micMixer)
            engine.disconnectNodeOutput(mainMixer)
            
            let connectionFormat = monoFormat(for: file.processingFormat)
            engine.connect(player, to: mainMixer, format: connectionFormat)
            player.volume = 1.0
            
            if let src = audioState.physicalInputNode {
                engine.connect(src, to: micMixer, format: format)
                micMixer.outputVolume = 0.0
                engine.connect(micMixer, to: mainMixer, format: format)
            }
            
            engine.connect(mainMixer, to: dest, format: format)
            
            print("[WebRTCManager] Reconnected WebRTC input path: player (1.0 vol) & physical microphone (0.0 vol via micMixer) -> mainMixer -> destination")
            
            audioState.activeBuffersCount = 1
            audioState.onPlaybackFinished = completion
            
            if !player.isPlaying {
                player.play()
            }
            
            let state = self.audioState
            player.scheduleFile(file, at: nil) {
                let (_, callback) = state.decrementActiveBuffers()
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
        audioState.playerNode?.stop()
        audioState.resetPlayback()
        audioState.clearStream()
    }
    
    public func startAudioStream(format: AVAudioFormat, completion: @escaping @Sendable () -> Void) {
        guard let player = audioState.playerNode,
              let micMixer = audioState.micMixerNode,
              let mainMixer = audioState.mainMixerNode,
              let dest = audioState.inputDestinationNode,
              let inputFmt = audioState.inputFormat,
              let engine = player.engine else {
            print("[WebRTCManager] [Warning] startAudioStream called but playerNode, micMixerNode, mainMixerNode, inputDestinationNode, inputFormat, or engine is nil")
            completion()
            return
        }
        
        engine.disconnectNodeOutput(player)
        if let src = audioState.physicalInputNode {
            engine.disconnectNodeOutput(src)
        }
        engine.disconnectNodeOutput(micMixer)
        engine.disconnectNodeOutput(mainMixer)
        
        let connectionFormat = monoFormat(for: format)
        engine.connect(player, to: mainMixer, format: connectionFormat)
        player.volume = 1.0
        
        if let src = audioState.physicalInputNode {
            engine.connect(src, to: micMixer, format: inputFmt)
            micMixer.outputVolume = 0.0
            engine.connect(micMixer, to: mainMixer, format: inputFmt)
        }
        
        engine.connect(mainMixer, to: dest, format: inputFmt)
        
        audioState.clearStream()
        audioState.streamCompletion = completion
        
        if !player.isPlaying {
            player.play()
        }
        
        print("[WebRTCManager] Reconnected WebRTC input path for streaming: player (\(format.sampleRate)Hz) & physical microphone (0.0 vol via micMixer) -> mainMixer -> destination")
    }
    
    public func submitAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let player = audioState.playerNode else { return }
        
        let playerOutputFormat = player.outputFormat(forBus: 0)
        guard playerOutputFormat.channelCount == buffer.format.channelCount else {
            print("[WebRTCManager] [Warning] Dropped streaming buffer due to channel count mismatch: player \(playerOutputFormat.channelCount) ch vs buffer \(buffer.format.channelCount) ch")
            return
        }
        
        audioState.incrementStreamBuffers()
        
        let state = self.audioState
        player.scheduleBuffer(buffer) {
            let (count, completion, isFinished) = state.decrementStreamBuffers()
            if count == 0 && isFinished {
                state.streamCompletion = nil
                DispatchQueue.main.async {
                    completion?()
                }
            }
        }
    }
    
    public func finishAudioStream() {
        let (count, completion) = audioState.finishStreamSending()
        if count == 0 {
            audioState.streamCompletion = nil
            DispatchQueue.main.async {
                completion?()
            }
        }
        print("[WebRTCManager] Audio stream finish requested (active buffers: \(count)).")
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCManager: RTCPeerConnectionDelegate {
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("[WebRTCManager] Signaling state changed: \(stateChanged.rawValue)")
    }
    
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
    }
    
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
    }
    
    nonisolated public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("[WebRTCManager] peerConnectionShouldNegotiate triggered.")
    }
    
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("[WebRTCManager] ICE connection state changed: \(newState.rawValue)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.webRTCManager(self, didChangeConnectionState: newState)
        }
    }
    
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("[WebRTCManager] ICE gathering state changed: \(newState.rawValue)")
    }
    
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.webRTCManager(self, didGenerateIceCandidate: candidate)
        }
    }
    
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
    }
    
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("[WebRTCManager] Remote peer opened data channel '\(dataChannel.label)'.")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.dataChannel = dataChannel
            dataChannel.delegate = self
            self.delegate?.webRTCManager(self, didChangeDataChannelState: dataChannel.readyState == .open)
        }
    }
}

// MARK: - RTCDataChannelDelegate

extension WebRTCManager: RTCDataChannelDelegate {
    nonisolated public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        print("[WebRTCManager] Data channel '\(dataChannel.label)' state changed: \(dataChannel.readyState.rawValue)")
        let isOpen = (dataChannel.readyState == .open)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.webRTCManager(self, didChangeDataChannelState: isOpen)
        }
    }
    
    nonisolated public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
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
    nonisolated public func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, didReceiveSpeechActivityEvent speechActivityEvent: RTCSpeechActivityEvent) {
        print("[WebRTCManager] audioDeviceModule didReceiveSpeechActivityEvent: \(speechActivityEvent.rawValue)")
    }
    
    nonisolated public func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, didCreateEngine engine: AVAudioEngine) -> Int {
        print("[WebRTCManager] audioDeviceModule didCreateEngine called.")
        return 0
    }
    
    nonisolated public func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, willEnableEngine engine: AVAudioEngine, isPlayoutEnabled playoutEnabled: Bool, isRecordingEnabled recordingEnabled: Bool) -> Int {
        print("[WebRTCManager] audioDeviceModule willEnableEngine. Playout: \(playoutEnabled), Recording: \(recordingEnabled)")
        return 0
    }
    
    nonisolated public func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, willStartEngine engine: AVAudioEngine, isPlayoutEnabled playoutEnabled: Bool, isRecordingEnabled recordingEnabled: Bool) -> Int {
        print("[WebRTCManager] audioDeviceModule willStartEngine. Playout: \(playoutEnabled), Recording: \(recordingEnabled)")
        return 0
    }
    
    nonisolated public func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, didStopEngine engine: AVAudioEngine, isPlayoutEnabled playoutEnabled: Bool, isRecordingEnabled recordingEnabled: Bool) -> Int {
        print("[WebRTCManager] audioDeviceModule didStopEngine. Playout: \(playoutEnabled), Recording: \(recordingEnabled)")
        return 0
    }
    
    nonisolated public func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, didDisableEngine engine: AVAudioEngine, isPlayoutEnabled playoutEnabled: Bool, isRecordingEnabled recordingEnabled: Bool) -> Int {
        print("[WebRTCManager] audioDeviceModule didDisableEngine. Playout: \(playoutEnabled), Recording: \(recordingEnabled)")
        return 0
    }
    
    nonisolated public func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine) -> Int {
        print("[WebRTCManager] audioDeviceModule willReleaseEngine called.")
        return 0
    }
    
    nonisolated public func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, engine: AVAudioEngine, configureInputFromSource source: AVAudioNode?, toDestination destination: AVAudioNode, format: AVAudioFormat, context: [AnyHashable : Any]) -> Int {
        print("[WebRTCManager] configureInputFromSource called. Format: \(format)")
        
        if let src = source {
            engine.disconnectNodeOutput(src)
        }
        engine.disconnectNodeInput(destination)
        
        let player = AVAudioPlayerNode()
        let micMixer = AVAudioMixerNode()
        let mainMixer = AVAudioMixerNode()
        
        engine.attach(player)
        engine.attach(micMixer)
        engine.attach(mainMixer)
        
        engine.connect(player, to: mainMixer, format: format)
        player.volume = 1.0
        
        if let src = source {
            engine.connect(src, to: micMixer, format: format)
            micMixer.outputVolume = 0.0
            print("[WebRTCManager] Programmatically muted physical microphone input using micMixer outputVolume")
            engine.connect(micMixer, to: mainMixer, format: format)
        }
        
        engine.connect(mainMixer, to: destination, format: format)
        
        audioState.playerNode = player
        audioState.micMixerNode = micMixer
        audioState.mainMixerNode = mainMixer
        audioState.physicalInputNode = source
        audioState.inputDestinationNode = destination
        audioState.inputFormat = format
        
        return 0
    }
    
    nonisolated public func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, engine: AVAudioEngine, configureOutputFromSource source: AVAudioNode, toDestination destination: AVAudioNode?, format: AVAudioFormat, context: [AnyHashable : Any]) -> Int {
        print("[WebRTCManager] configureOutputFromSource called. Format: \(format)")
        
        engine.disconnectNodeOutput(source)
        if let dest = destination {
            engine.disconnectNodeInput(dest)
        }
        
        let localOutputMixer = AVAudioMixerNode()
        engine.attach(localOutputMixer)
        
        engine.connect(source, to: localOutputMixer, format: format)
        
        let finalDest = destination ?? engine.mainMixerNode
        engine.connect(localOutputMixer, to: finalDest, format: format)
        
        localOutputMixer.outputVolume = audioState.isSpeakersMuted ? 0.0 : 1.0
        
        audioState.outputMixer = localOutputMixer
        audioState.audioEngine = engine
        
        print("[WebRTCManager] Configured custom output mixer node with volume: \(localOutputMixer.outputVolume)")
        
        engine.mainMixerNode.outputVolume = 1.0
        
        source.removeTap(onBus: 0)
        source.installTap(onBus: 0, bufferSize: 1024, format: format) { (buffer, time) in
            if let onIncoming = self.audioState.onIncomingAudioBuffer {
                onIncoming(buffer)
            }
        }
        
        return 0
    }
    
    nonisolated public func audioDeviceModuleDidUpdateDevices(_ audioDeviceModule: RTCAudioDeviceModule) {
        print("[WebRTCManager] audioDeviceModuleDidUpdateDevices called.")
    }
    
    nonisolated public func audioDeviceModule(_ module: RTCAudioDeviceModule, didUpdateAudioProcessingState state: RTCAudioProcessingState) {
        print("[WebRTCManager] audioDeviceModule didUpdateAudioProcessingState: voiceProcessingEnabled=\(state.voiceProcessingEnabled)")
    }
}
