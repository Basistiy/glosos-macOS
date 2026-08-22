//
//  WebRTCManager.swift
//  glosos-macOS
//
//  Created by Antigravity on 6/9/26.
//

import Foundation
@preconcurrency import LiveKitWebRTC
import AVFoundation
import CoreMedia
import Accelerate

// SAFETY: LKRTCSessionDescription is immutable after construction (read-only `type` and `sdp` properties).
extension LKRTCSessionDescription: @retroactive @unchecked Sendable {}
// SAFETY: LKRTCIceCandidate is immutable after construction (read-only `sdp`, `sdpMLineIndex`, `sdpMid` properties).
extension LKRTCIceCandidate: @retroactive @unchecked Sendable {}

extension AVAudioPCMBuffer {
    nonisolated func makeCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: self.frameLength) else { return nil }
        copy.frameLength = self.frameLength
        
        let channelCount = Int(self.format.channelCount)
        let frameLength = Int(self.frameLength)
        
        if let src = self.floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], frameLength * MemoryLayout<Float>.size)
            }
        } else if let src = self.int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], frameLength * MemoryLayout<Int16>.size)
            }
        } else if let src = self.int32ChannelData, let dst = copy.int32ChannelData {
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], frameLength * MemoryLayout<Int32>.size)
            }
        }
        return copy
    }
}

@MainActor
public protocol WebRTCManagerDelegate: AnyObject {
    func webRTCManager(_ manager: WebRTCManager, didChangeConnectionState state: RTCIceConnectionState)
    func webRTCManager(_ manager: WebRTCManager, didGenerateIceCandidate candidate: LKRTCIceCandidate)
    func webRTCManager(_ manager: WebRTCManager, didReceiveMessage message: String)
    func webRTCManager(_ manager: WebRTCManager, didChangeDataChannelState isOpen: Bool)
}

// Thread-safe container to manage custom audio injection and tap buffers for LiveKitWebRTC.
private nonisolated final class WebRTCAudioState: @unchecked Sendable {
    private let lock = NSLock()
    
    private var _onIncomingAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var _isMicrophoneMuted = false
    private var _isSpeakersMuted = true
    
    private var _processingSampleRate: Double = 48000
    private var _processingChannels: Int = 1
    
    private var _sampleQueue: [Float] = []
    private var _readIndex: Int = 0
    private var _activeBuffersCount = 0
    private var _onPlaybackFinished: (@Sendable () -> Void)?
    
    private var _isStreaming = false
    private var _streamCompletion: (@Sendable () -> Void)?
    private var _streamFinishedSending = false
    
    var isMicrophoneMuted: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isMicrophoneMuted
        }
        set {
            lock.lock()
            _isMicrophoneMuted = newValue
            lock.unlock()
        }
    }
    
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
    
    var processingSampleRate: Double {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _processingSampleRate
        }
        set {
            lock.lock()
            _processingSampleRate = newValue
            lock.unlock()
        }
    }
    
    var processingChannels: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _processingChannels
        }
        set {
            lock.lock()
            _processingChannels = newValue
            lock.unlock()
        }
    }
    
    func resetAudioQueue() {
        lock.lock()
        defer { lock.unlock() }
        _sampleQueue.removeAll(keepingCapacity: false)
        _readIndex = 0
        _activeBuffersCount = 0
        _onPlaybackFinished = nil
        _isStreaming = false
        _streamCompletion = nil
        _streamFinishedSending = false
    }
    
    func appendSamples(_ samples: [Float], count: Int = 1, completion: (@Sendable () -> Void)? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if _readIndex > 96000 {
            _sampleQueue.removeFirst(_readIndex)
            _readIndex = 0
        }
        _sampleQueue.append(contentsOf: samples)
        if count > 0 {
            _activeBuffersCount += count
        }
        if let completion = completion {
            _onPlaybackFinished = completion
        }
    }
    
    func startStream(completion: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        _sampleQueue.removeAll(keepingCapacity: false)
        _readIndex = 0
        _isStreaming = true
        _streamCompletion = completion
        _streamFinishedSending = false
    }
    
    func appendStreamSamples(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        if _readIndex > 96000 {
            _sampleQueue.removeFirst(_readIndex)
            _readIndex = 0
        }
        _sampleQueue.append(contentsOf: samples)
    }
    
    func finishStream() {
        lock.lock()
        defer { lock.unlock() }
        _streamFinishedSending = true
        if _sampleQueue.count == _readIndex {
            let completion = _streamCompletion
            _streamCompletion = nil
            _isStreaming = false
            if let completion = completion {
                DispatchQueue.main.async { completion() }
            }
        }
    }
    
    // Called on real-time audio thread
    func readSamples(into dest: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        let available = _sampleQueue.count - _readIndex
        if available == 0 {
            if _sampleQueue.count > 0 {
                _sampleQueue.removeAll(keepingCapacity: true)
                _readIndex = 0
            }
            if _isStreaming && _streamFinishedSending {
                let completion = _streamCompletion
                _streamCompletion = nil
                _isStreaming = false
                if let completion = completion {
                    DispatchQueue.main.async { completion() }
                }
            } else if _activeBuffersCount > 0 {
                _activeBuffersCount = 0
                let completion = _onPlaybackFinished
                _onPlaybackFinished = nil
                if let completion = completion {
                    DispatchQueue.main.async { completion() }
                }
            }
            return false
        }
        
        let toCopy = min(available, count)
        _ = _sampleQueue.withUnsafeBufferPointer { bufPtr in
            memcpy(dest, bufPtr.baseAddress!.advanced(by: _readIndex), toCopy * MemoryLayout<Float>.size)
        }
        _readIndex += toCopy
        
        if toCopy < count {
            memset(dest.advanced(by: toCopy), 0, (count - toCopy) * MemoryLayout<Float>.size)
        }
        
        if _sampleQueue.count == _readIndex {
            _sampleQueue.removeAll(keepingCapacity: true)
            _readIndex = 0
            if _isStreaming && _streamFinishedSending {
                let completion = _streamCompletion
                _streamCompletion = nil
                _isStreaming = false
                if let completion = completion {
                    DispatchQueue.main.async { completion() }
                }
            } else if _activeBuffersCount > 0 {
                _activeBuffersCount = 0
                let completion = _onPlaybackFinished
                _onPlaybackFinished = nil
                if let completion = completion {
                    DispatchQueue.main.async { completion() }
                }
            }
        }
        
        return true
    }
}

private final class WebRTCCaptureAudioProcessor: NSObject, LKRTCAudioCustomProcessingDelegate, @unchecked Sendable {
    private let audioState: WebRTCAudioState
    
    init(audioState: WebRTCAudioState) {
        self.audioState = audioState
        super.init()
    }
    
    nonisolated func audioProcessingInitialize(sampleRate: Int, channels: Int) {
        print("[WebRTCManager] captureAudioProcessingInitialize: sampleRate=\(sampleRate), channels=\(channels)")
        audioState.processingSampleRate = Double(sampleRate)
        audioState.processingChannels = channels
    }
    
    nonisolated func audioProcessingProcess(audioBuffer: LKRTCAudioBuffer) {
        let frames = audioBuffer.frames
        let channels = audioBuffer.channels
        
        let primaryBuf = audioBuffer.rawBuffer(forChannel: 0)
        let hasCustomAudio = audioState.readSamples(into: primaryBuf, count: frames)
        
        if hasCustomAudio {
            // Duplicate mono custom audio to remaining channels if multi-channel
            if channels > 1 {
                for ch in 1..<channels {
                    let chBuf = audioBuffer.rawBuffer(forChannel: ch)
                    memcpy(chBuf, primaryBuf, frames * MemoryLayout<Float>.size)
                }
            }
        } else {
            // Always silence microphone input when no custom audio (TTS/stream) is active.
            // This prevents Mac's physical mic from broadcasting ambient noise/echo to the remote peer.
            for ch in 0..<channels {
                let chBuf = audioBuffer.rawBuffer(forChannel: ch)
                memset(chBuf, 0, frames * MemoryLayout<Float>.size)
            }
        }
    }
    
    nonisolated func audioProcessingRelease() {
        print("[WebRTCManager] captureAudioProcessingRelease called.")
    }
}

private final class WebRTCRenderAudioProcessor: NSObject, LKRTCAudioCustomProcessingDelegate, @unchecked Sendable {
    private let audioState: WebRTCAudioState
    
    init(audioState: WebRTCAudioState) {
        self.audioState = audioState
        super.init()
    }
    
    nonisolated func audioProcessingInitialize(sampleRate: Int, channels: Int) {
        print("[WebRTCManager] renderAudioProcessingInitialize: sampleRate=\(sampleRate), channels=\(channels)")
    }
    
    nonisolated func audioProcessingProcess(audioBuffer: LKRTCAudioBuffer) {
        let frames = audioBuffer.frames
        let channels = audioBuffer.channels
        
        if audioState.isSpeakersMuted {
            // Silence local speaker playout of the remote peer's voice (prevents echo/sidetone).
            for ch in 0..<channels {
                let chBuf = audioBuffer.rawBuffer(forChannel: ch)
                memset(chBuf, 0, frames * MemoryLayout<Float>.size)
            }
        }
    }
    
    nonisolated func audioProcessingRelease() {
        print("[WebRTCManager] renderAudioProcessingRelease called.")
    }
}

@MainActor
public final class WebRTCManager: NSObject {
    public weak var delegate: WebRTCManagerDelegate?
    
    private let captureAudioProcessor: WebRTCCaptureAudioProcessor
    private let renderAudioProcessor: WebRTCRenderAudioProcessor
    private var audioProcessingModule: LKRTCDefaultAudioProcessingModule?
    private var peerConnectionFactory: LKRTCPeerConnectionFactory
    private var peerConnection: LKRTCPeerConnection?
    private var dataChannel: LKRTCDataChannel?
    private var pendingIceCandidates: [LKRTCIceCandidate] = []
    
    private var cachedAudioConverter: AVAudioConverter?
    private var cachedAudioConverterInputFormat: AVAudioFormat?
    private var cachedAudioConverterOutputFormat: AVAudioFormat?
    
    public var iceConnectionState: RTCIceConnectionState {
        return peerConnection?.iceConnectionState ?? .closed
    }
    
    private let audioState = WebRTCAudioState()
    
    public var onIncomingAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { audioState.onIncomingAudioBuffer }
        set { audioState.onIncomingAudioBuffer = newValue }
    }
    
    public var isMicrophoneMuted: Bool {
        get { audioState.isMicrophoneMuted }
        set {
            audioState.isMicrophoneMuted = newValue
            localAudioTrack?.isEnabled = !newValue
            print("[WebRTCManager] Microphone mute state changed to: \(newValue)")
        }
    }
    
    private var localAudioTrack: LKRTCAudioTrack?
    private var remoteAudioTracks: [LKRTCAudioTrack] = []
    
    public var isSpeakersMuted: Bool {
        get { audioState.isSpeakersMuted }
        set { audioState.isSpeakersMuted = newValue }
    }
    
    private static let stunServers = [
        "stun:stun.l.google.com:19302",
        "stun:stun1.l.google.com:19302",
        "stun:stun2.l.google.com:19302"
    ]
    
    public override init() {
        RTCInitializeSSL()
        
        let audioState = self.audioState
        let captureProcessor = WebRTCCaptureAudioProcessor(audioState: audioState)
        let renderProcessor = WebRTCRenderAudioProcessor(audioState: audioState)
        self.captureAudioProcessor = captureProcessor
        self.renderAudioProcessor = renderProcessor
        
        let apm = LKRTCDefaultAudioProcessingModule(
            config: nil,
            capturePostProcessingDelegate: captureProcessor,
            renderPreProcessingDelegate: renderProcessor
        )
        self.audioProcessingModule = apm
        
        self.peerConnectionFactory = LKRTCPeerConnectionFactory(
            bypassVoiceProcessing: true,
            encoderFactory: nil,
            decoderFactory: nil,
            audioProcessingModule: apm
        )
        super.init()
    }
    
    deinit {
        let pc = self.peerConnection
        let dc = self.dataChannel
        let state = self.audioState
        let tracks = self.remoteAudioTracks
        
        pc?.delegate = nil
        dc?.delegate = nil
        
        for track in tracks {
            track.remove(self)
        }
        
        DispatchQueue.main.async {
            dc?.close()
            pc?.close()
            state.resetAudioQueue()
        }
        RTCCleanupSSL()
    }
    
    public func createPeerConnection(iceServers: [LKRTCIceServer] = []) -> Bool {
        cleanup(clearPendingCandidates: false)
        
        let config = LKRTCConfiguration()
        var servers = [LKRTCIceServer(urlStrings: Self.stunServers)]
        servers.append(contentsOf: iceServers)
        config.iceServers = servers
        config.sdpSemantics = .unifiedPlan
        
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        
        guard let pc = peerConnectionFactory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            print("[WebRTCManager] Failed to create LKRTCPeerConnection.")
            return false
        }
        
        self.peerConnection = pc
        
        // Add local audio track
        let audioSource = peerConnectionFactory.audioSource(with: nil)
        let audioTrack = peerConnectionFactory.audioTrack(with: audioSource, trackId: "audio0")
        audioTrack.isEnabled = !isMicrophoneMuted
        pc.add(audioTrack, streamIds: ["stream0"])
        self.localAudioTrack = audioTrack
        
        print("[WebRTCManager] LKRTCPeerConnection created successfully with local audio track.")
        return true
    }
    
    public func handleIncomingCall(offerSdp: String, completion: @escaping @Sendable @MainActor (Result<LKRTCSessionDescription, Error>) -> Void) {
        guard let pc = peerConnection else {
            let error = NSError(domain: "WebRTCManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "PeerConnection is not initialized"])
            completion(.failure(error))
            return
        }
        
        let remoteDescription = LKRTCSessionDescription(type: .offer, sdp: offerSdp)
        
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
                
                let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
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
    
    public func addIceCandidate(_ candidate: LKRTCIceCandidate) {
        guard let pc = peerConnection, pc.remoteDescription != nil else {
            print("[WebRTCManager] Queuing remote ICE candidate (peerConnection or remote description not set)")
            pendingIceCandidates.append(candidate)
            return
        }
        
        pc.add(candidate) { error in
            if let error = error {
                print("[WebRTCManager] Failed to add ICE candidate: \(error.localizedDescription)")
            }
        }
    }
    
    public func clearPendingIceCandidates() {
        pendingIceCandidates.removeAll()
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
        
        let buffer = LKRTCDataBuffer(data: data, isBinary: false)
        return channel.sendData(buffer)
    }
    
    public func cleanup(clearPendingCandidates: Bool = true) {
        print("[WebRTCManager] Cleaning up WebRTC resources...")
        for track in remoteAudioTracks {
            track.remove(self)
        }
        remoteAudioTracks.removeAll()
        
        if let channel = dataChannel {
            channel.close()
            dataChannel = nil
        }
        if let pc = peerConnection {
            pc.close()
            peerConnection = nil
        }
        if clearPendingCandidates {
            pendingIceCandidates.removeAll()
        }
        audioState.resetAudioQueue()
    }
    
    private func extractFloatSamples(from buffer: AVAudioPCMBuffer, targetSampleRate: Double) -> [Float] {
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false)!
        
        let monoBuffer: AVAudioPCMBuffer
        if buffer.format == targetFormat {
            monoBuffer = buffer
        } else {
            let converter: AVAudioConverter
            if let cached = cachedAudioConverter, cachedAudioConverterInputFormat == buffer.format, cachedAudioConverterOutputFormat == targetFormat {
                converter = cached
            } else if let newConverter = AVAudioConverter(from: buffer.format, to: targetFormat) {
                cachedAudioConverter = newConverter
                cachedAudioConverterInputFormat = buffer.format
                cachedAudioConverterOutputFormat = targetFormat
                converter = newConverter
            } else {
                return []
            }
            
            let sampleRateRatio = targetSampleRate / buffer.format.sampleRate
            let targetCapacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRateRatio + 1024)
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
                return []
            }
            var isProvided = false
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                if !isProvided {
                    isProvided = true
                    outStatus.pointee = .haveData
                    return buffer
                } else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }
            let status = converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
            if status == .error || error != nil {
                return []
            }
            monoBuffer = converted
        }
        
        guard let floatData = monoBuffer.floatChannelData?[0], monoBuffer.frameLength > 0 else {
            return []
        }
        
        let count = Int(monoBuffer.frameLength)
        // WebRTC's APM AudioBuffer (float) expects samples scaled to the Int16 range [-32768.0, 32767.0].
        // CoreAudio's float buffers are in the [-1.0, 1.0] range, so they must be scaled up.
        var scaledSamples = [Float](repeating: 0, count: count)
        var multiplier: Float = 32768.0
        vDSP_vsmul(floatData, 1, &multiplier, &scaledSamples, 1, vDSP_Length(count))
        return scaledSamples
    }
    
    public func playAudioBuffers(_ buffers: [AVAudioPCMBuffer], completion: @escaping @Sendable () -> Void) {
        let sampleRate = audioState.processingSampleRate
        var allSamples: [Float] = []
        
        for buffer in buffers {
            let samples = extractFloatSamples(from: buffer, targetSampleRate: sampleRate)
            allSamples.append(contentsOf: samples)
        }
        
        guard !allSamples.isEmpty else {
            completion()
            return
        }
        
        audioState.appendSamples(allSamples, count: buffers.count, completion: completion)
    }
    
    public func playAudioFile(at url: URL, completion: @escaping @Sendable () -> Void) {
        do {
            let file = try AVAudioFile(forReading: url)
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0,
                  let fileBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
                completion()
                return
            }
            try file.read(into: fileBuffer)
            
            let sampleRate = audioState.processingSampleRate
            let samples = extractFloatSamples(from: fileBuffer, targetSampleRate: sampleRate)
            
            guard !samples.isEmpty else {
                completion()
                return
            }
            
            audioState.appendSamples(samples, count: 1, completion: completion)
        } catch {
            print("[WebRTCManager] [Warning] Failed to read audio file at \(url): \(error.localizedDescription)")
            completion()
        }
    }
    
    public func stopAudioPlayback() {
        print("[WebRTCManager] Stopping audio playback queue.")
        audioState.resetAudioQueue()
    }
    
    public func startAudioStream(format: AVAudioFormat, completion: @escaping @Sendable () -> Void) {
        audioState.startStream(completion: completion)
        print("[WebRTCManager] Prepared WebRTC audio stream playback (source stream format: \(format))")
    }
    
    public func submitAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let sampleRate = audioState.processingSampleRate
        let samples = extractFloatSamples(from: buffer, targetSampleRate: sampleRate)
        if !samples.isEmpty {
            audioState.appendStreamSamples(samples)
        }
    }
    
    public func finishAudioStream() {
        audioState.finishStream()
        print("[WebRTCManager] Audio stream finish requested.")
    }
    
    private nonisolated func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        
        guard let format = AVAudioFormat(streamDescription: asbd) else {
            return nil
        }
        
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(numSamples)
        
        var blockBuffer: CMBlockBuffer?
        let channelCount = Int(format.channelCount)
        let bufferList = AudioBufferList.allocate(maximumBuffers: channelCount)
        defer { free(UnsafeMutableRawPointer(bufferList.unsafeMutablePointer)) }
        
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channelCount),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        
        guard status == noErr else { return nil }
        
        let numBuffers = Int(bufferList.unsafePointer.pointee.mNumberBuffers)
        let isNonInterleaved = format.isInterleaved == false && channelCount > 1
        
        if let dst = pcmBuffer.floatChannelData {
            for ch in 0..<channelCount {
                let bufIndex = isNonInterleaved ? min(ch, numBuffers - 1) : 0
                if let src = bufferList[bufIndex].mData {
                    let byteSize = Int(bufferList[bufIndex].mDataByteSize)
                    let copyBytes = min(byteSize, Int(pcmBuffer.frameLength) * MemoryLayout<Float>.size)
                    memcpy(dst[ch], src, copyBytes)
                }
            }
        } else if let dst = pcmBuffer.int16ChannelData {
            for ch in 0..<channelCount {
                let bufIndex = isNonInterleaved ? min(ch, numBuffers - 1) : 0
                if let src = bufferList[bufIndex].mData {
                    let byteSize = Int(bufferList[bufIndex].mDataByteSize)
                    let copyBytes = min(byteSize, Int(pcmBuffer.frameLength) * MemoryLayout<Int16>.size)
                    memcpy(dst[ch], src, copyBytes)
                }
            }
        } else if let dst = pcmBuffer.int32ChannelData {
            for ch in 0..<channelCount {
                let bufIndex = isNonInterleaved ? min(ch, numBuffers - 1) : 0
                if let src = bufferList[bufIndex].mData {
                    let byteSize = Int(bufferList[bufIndex].mDataByteSize)
                    let copyBytes = min(byteSize, Int(pcmBuffer.frameLength) * MemoryLayout<Int32>.size)
                    memcpy(dst[ch], src, copyBytes)
                }
            }
        }
        
        return pcmBuffer
    }
}

// MARK: - LKRTCPeerConnectionDelegate

extension WebRTCManager: LKRTCPeerConnectionDelegate {
    nonisolated public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("[WebRTCManager] Signaling state changed: \(stateChanged.rawValue)")
    }
    
    nonisolated public func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {
        print("[WebRTCManager] Remote stream added with \(stream.audioTracks.count) audio tracks.")
        for track in stream.audioTracks {
            track.add(self)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for track in stream.audioTracks {
                if !self.remoteAudioTracks.contains(where: { $0 === track }) {
                    self.remoteAudioTracks.append(track)
                }
            }
        }
    }
    
    nonisolated public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {
        for track in stream.audioTracks {
            track.remove(self)
        }
        Task { @MainActor [weak self] in
            self?.remoteAudioTracks.removeAll(where: { track in stream.audioTracks.contains(where: { $0 === track }) })
        }
    }
    
    nonisolated public func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {
        print("[WebRTCManager] peerConnectionShouldNegotiate triggered.")
    }
    
    nonisolated public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("[WebRTCManager] ICE connection state changed: \(newState.rawValue)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.webRTCManager(self, didChangeConnectionState: newState)
        }
    }
    
    nonisolated public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("[WebRTCManager] ICE gathering state changed: \(newState.rawValue)")
    }
    
    nonisolated public func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.webRTCManager(self, didGenerateIceCandidate: candidate)
        }
    }
    
    nonisolated public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {
    }
    
    nonisolated public func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        print("[WebRTCManager] Remote peer opened data channel '\(dataChannel.label)'.")
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.dataChannel = dataChannel
            dataChannel.delegate = self
            self.delegate?.webRTCManager(self, didChangeDataChannelState: dataChannel.readyState == .open)
        }
    }
    
    nonisolated public func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
        if let audioTrack = rtpReceiver.track as? LKRTCAudioTrack {
            print("[WebRTCManager] Remote audio track received via RTP receiver.")
            audioTrack.add(self)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.remoteAudioTracks.contains(where: { $0 === audioTrack }) {
                    self.remoteAudioTracks.append(audioTrack)
                }
            }
        }
    }
}

// MARK: - LKRTCDataChannelDelegate

extension WebRTCManager: LKRTCDataChannelDelegate {
    nonisolated public func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        print("[WebRTCManager] Data channel '\(dataChannel.label)' state changed: \(dataChannel.readyState.rawValue)")
        let isOpen = (dataChannel.readyState == .open)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.webRTCManager(self, didChangeDataChannelState: isOpen)
        }
    }
    
    nonisolated public func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        guard !buffer.isBinary else {
            print("[WebRTCManager] Received binary message on data channel. Ignoring.")
            return
        }
        
        guard let message = String(data: buffer.data, encoding: .utf8) else {
            return
        }
        
        print("[WebRTCManager] Received message: \(message)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.webRTCManager(self, didReceiveMessage: message)
        }
    }
}

// MARK: - LKRTCAudioRenderer

extension WebRTCManager: LKRTCAudioRenderer {
    nonisolated public func render(sampleBuffer: CMSampleBuffer) {
        if let onIncoming = self.audioState.onIncomingAudioBuffer,
           let pcm = self.pcmBuffer(from: sampleBuffer) {
            onIncoming(pcm)
        }
    }
}
