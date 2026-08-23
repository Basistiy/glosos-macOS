//
//  SileroVADProcessor.swift
//  glosos-macOS
//
//  Created by Codex on 6/5/26.
//

import Foundation
import CoreML
import Accelerate

public enum SileroVADError: LocalizedError {
    case modelNotReady
    case predictionFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .modelNotReady:
            return "VAD model is not loaded or ready."
        case .predictionFailed(let details):
            return "VAD inference prediction failed: \(details)"
        }
    }
}

nonisolated private func resampleAudio(_ samples: [Float], from inputRate: Int, to outputRate: Int) throws -> [Float] {
    guard inputRate != outputRate else {
        return samples
    }
    guard inputRate > 0 && outputRate > 0, !samples.isEmpty else {
        return samples
    }
    
    // Fast path for exact integer downsampling (e.g. 48kHz -> 16kHz)
    if inputRate % outputRate == 0 {
        let stride = inputRate / outputRate
        let outputCount = samples.count / stride
        guard outputCount > 0 else { return [] }
        var resampled = [Float](repeating: 0, count: outputCount)
        samples.withUnsafeBufferPointer { src in
            resampled.withUnsafeMutableBufferPointer { dst in
                guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else { return }
                var srcIdx = 0
                for i in 0..<outputCount {
                    dstBase[i] = srcBase[srcIdx]
                    srcIdx += stride
                }
            }
        }
        return resampled
    }
    
    let ratio = Double(inputRate) / Double(outputRate)
    let outputCount = Int(Double(samples.count) / ratio)
    guard outputCount > 0 else {
        return []
    }
    
    var resampled = [Float](repeating: 0, count: outputCount)
    let maxSrcIdx = samples.count - 1
    samples.withUnsafeBufferPointer { src in
        resampled.withUnsafeMutableBufferPointer { dst in
            guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else { return }
            for i in 0..<outputCount {
                let exactIdx = Double(i) * ratio
                let idx = Int(exactIdx)
                let nextIdx = min(idx + 1, maxSrcIdx)
                let weight = Float(exactIdx - Double(idx))
                let val1 = srcBase[idx]
                let val2 = srcBase[nextIdx]
                dstBase[i] = val1 + weight * (val2 - val1)
            }
        }
    }
    
    return resampled
}

struct SileroChunkAccumulator {
    nonisolated static let targetSampleRate = 16_000
    nonisolated static let targetChunkSize = 512

    nonisolated init() {}

    private var pendingInputSamples: [Float] = []
    private var pendingResampledSamples: [Float] = []

    nonisolated mutating func reset() {
        pendingInputSamples.removeAll(keepingCapacity: true)
        pendingResampledSamples.removeAll(keepingCapacity: true)
    }

    nonisolated mutating func append(samples: [Float], sampleRate: Int) throws -> [[Float]] {
        guard !samples.isEmpty else {
            return []
        }

        if sampleRate == Self.targetSampleRate {
            pendingResampledSamples.append(contentsOf: samples)
            return drainChunks()
        }

        pendingInputSamples.append(contentsOf: samples)
        let inputBatchSize = max(
            Int(round(Double(sampleRate) / Double(Self.targetSampleRate) * Double(Self.targetChunkSize))),
            Self.targetChunkSize
        )

        while pendingInputSamples.count >= inputBatchSize {
            let batch = Array(pendingInputSamples.prefix(inputBatchSize))
            pendingInputSamples.removeFirst(inputBatchSize)
            let resampled = try resampleAudio(batch, from: sampleRate, to: Self.targetSampleRate)
            pendingResampledSamples.append(contentsOf: resampled)
        }

        return drainChunks()
    }

    nonisolated private mutating func drainChunks() -> [[Float]] {
        var chunks: [[Float]] = []

        while pendingResampledSamples.count >= Self.targetChunkSize {
            chunks.append(Array(pendingResampledSamples.prefix(Self.targetChunkSize)))
            pendingResampledSamples.removeFirst(Self.targetChunkSize)
        }

        return chunks
    }
}

struct VADSpeechStateMachine {
    enum Event: Equatable {
        case none
        case speechStarted(probability: Float)
        case speechEnded(probability: Float)
    }

    let startThreshold: Float
    let startFrames: Int
    let endThreshold: Float
    let endFrames: Int
    let chunkDuration: TimeInterval

    private(set) var isSpeechActive = false
    private(set) var speechStartTime: TimeInterval?
    private(set) var lastSpeechTime: TimeInterval?
    private var consecutiveSpeechFrames = 0
    private var consecutiveSilenceFrames = 0

    nonisolated init(
        startThreshold: Float = 0.60,
        startFrames: Int = 2,
        endThreshold: Float = 0.35,
        endFrames: Int = 20,
        chunkDuration: TimeInterval = Double(SileroChunkAccumulator.targetChunkSize) / Double(SileroChunkAccumulator.targetSampleRate)
    ) {
        self.startThreshold = startThreshold
        self.startFrames = startFrames
        self.endThreshold = endThreshold
        self.endFrames = endFrames
        self.chunkDuration = chunkDuration
    }

    nonisolated mutating func reset() {
        isSpeechActive = false
        speechStartTime = nil
        lastSpeechTime = nil
        consecutiveSpeechFrames = 0
        consecutiveSilenceFrames = 0
    }

    nonisolated mutating func ingest(probability: Float, now: TimeInterval) -> Event {
        if isSpeechActive {
            if probability < endThreshold {
                consecutiveSilenceFrames += 1
            } else {
                consecutiveSilenceFrames = 0
                lastSpeechTime = now
            }

            if consecutiveSilenceFrames >= endFrames {
                isSpeechActive = false
                consecutiveSpeechFrames = 0
                consecutiveSilenceFrames = 0
                speechStartTime = nil
                lastSpeechTime = nil
                return .speechEnded(probability: probability)
            }

            return .none
        }

        if probability >= startThreshold {
            consecutiveSpeechFrames += 1
            if consecutiveSpeechFrames >= startFrames {
                isSpeechActive = true
                consecutiveSpeechFrames = 0
                consecutiveSilenceFrames = 0
                speechStartTime = now - chunkDuration * Double(max(startFrames - 1, 0))
                lastSpeechTime = now
                return .speechStarted(probability: probability)
            }
        } else {
            consecutiveSpeechFrames = 0
        }

        return .none
    }
}

public actor SileroVADProcessor {

    private struct StreamingState {
        var h: MLMultiArray
        var c: MLMultiArray
        var last64Samples: [Float]
        
        static func initial() throws -> StreamingState {
            let h = try MLMultiArray(shape: [1, 1, 128] as [NSNumber], dataType: .float16)
            let c = try MLMultiArray(shape: [1, 1, 128] as [NSNumber], dataType: .float16)
            
            let hPtr = h.dataPointer.bindMemory(to: Float16.self, capacity: 128)
            let cPtr = c.dataPointer.bindMemory(to: Float16.self, capacity: 128)
            memset(hPtr, 0, 128 * MemoryLayout<Float16>.size)
            memset(cPtr, 0, 128 * MemoryLayout<Float16>.size)
            
            return StreamingState(
                h: h,
                c: c,
                last64Samples: Array(repeating: 0.0, count: 64)
            )
        }
    }

    private enum ModelState {
        case idle
        case loading
        case ready(model: MLModel, state: StreamingState?)
        case failed(message: String)
    }

    private let logHandler: @Sendable (String) -> Void

    private var modelState: ModelState = .idle
    private var chunkAccumulator = SileroChunkAccumulator()
    private var stateMachine = VADSpeechStateMachine()
    private var onSpeechStartedClosure: (@Sendable @MainActor () -> Void)?
    private var onSpeechEndedClosure: (@Sendable @MainActor () -> Void)?

    public init(
        startThreshold: Float = 0.60,
        startFrames: Int = 2,
        endThreshold: Float = 0.35,
        endFrames: Int = 20,
        logHandler: @escaping @Sendable (String) -> Void
    ) {
        self.logHandler = logHandler
        self.stateMachine = VADSpeechStateMachine(
            startThreshold: startThreshold,
            startFrames: startFrames,
            endThreshold: endThreshold,
            endFrames: endFrames
        )
    }

    public var isReady: Bool {
        if case .ready = modelState {
            return true
        }
        return false
    }

    public var onSpeechStarted: (@Sendable @MainActor () -> Void)? {
        get { onSpeechStartedClosure }
        set { onSpeechStartedClosure = newValue }
    }

    public var onSpeechEnded: (@Sendable @MainActor () -> Void)? {
        get { onSpeechEndedClosure }
        set { onSpeechEndedClosure = newValue }
    }

    public func setOnSpeechStarted(_ closure: (@Sendable @MainActor () -> Void)?) {
        self.onSpeechStartedClosure = closure
    }

    public func setOnSpeechEnded(_ closure: (@Sendable @MainActor () -> Void)?) {
        self.onSpeechEndedClosure = closure
    }

    public func updateThresholds(startThreshold: Float, startFrames: Int, endThreshold: Float, endFrames: Int) {
        self.stateMachine = VADSpeechStateMachine(
            startThreshold: startThreshold,
            startFrames: startFrames,
            endThreshold: endThreshold,
            endFrames: endFrames
        )
        self.logHandler("Silero VAD parameters updated: startThreshold=\(startThreshold), startFrames=\(startFrames), endThreshold=\(endThreshold), endFrames=\(endFrames)")
    }

    public func loadModelIfNeeded() {
        guard case .idle = modelState else {
            return
        }

        modelState = .loading
        logHandler("Loading Silero VAD CoreML model.")

        Task {
            do {
                let model = try await loadModel()
                self.finalizeModelLoading(model: model)
            } catch {
                self.failModelLoading(message: error.localizedDescription)
            }
        }
    }

    private func finalizeModelLoading(model: MLModel) {
        self.modelState = .ready(model: model, state: nil)
        self.chunkAccumulator.reset()
        self.stateMachine.reset()
        self.logHandler("Silero VAD CoreML ready.")
    }

    private func failModelLoading(message: String) {
        self.modelState = .failed(message: message)
        self.logHandler("Silero VAD CoreML unavailable. Falling back to Apple Speech only. Error: \(message)")
    }

    private func loadModel() async throws -> MLModel {
        guard let modelURL = Bundle.main.url(forResource: "silero_vad", withExtension: "mlmodelc") else {
            throw SileroVADError.modelNotReady
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        return try MLModel(contentsOf: modelURL, configuration: config)
    }

    public func resetSession() {
        self.chunkAccumulator.reset()
        self.stateMachine.reset()

        if case let .ready(model, _) = self.modelState {
            self.modelState = .ready(model: model, state: nil)
        }
    }

    public func append(samples: [Float], sampleRate: Int) {
        guard case let .ready(model, currentState) = self.modelState else {
            return
        }

        do {
            let chunks = try self.chunkAccumulator.append(samples: samples, sampleRate: sampleRate)
            guard !chunks.isEmpty else {
                self.modelState = .ready(model: model, state: currentState)
                return
            }

            var streamState = try currentState ?? StreamingState.initial()

            for chunk in chunks {
                // Construct audio input tensor of shape [1, 1, 576] with Float16 matching model precision
                let audioMultiArray = try MLMultiArray(shape: [1, 1, 576] as [NSNumber], dataType: .float16)
                let audioPtr = audioMultiArray.dataPointer.bindMemory(to: Float16.self, capacity: 576)
                
                // Copy 64 context samples using direct memory write
                let last64 = streamState.last64Samples
                for i in 0..<64 {
                    audioPtr[i] = Float16(last64[i])
                }
                
                // Copy 512 current samples using direct memory write
                for i in 0..<512 {
                    audioPtr[64 + i] = Float16(chunk[i])
                }

                let inputs: [String: Any] = [
                    "audio": audioMultiArray,
                    "h": streamState.h,
                    "c": streamState.c
                ]
                
                let featureProvider = try MLDictionaryFeatureProvider(dictionary: inputs)
                let outputFeatures = try model.prediction(from: featureProvider)
                
                guard let probabilityArray = outputFeatures.featureValue(for: "probability")?.multiArrayValue,
                      let hOut = outputFeatures.featureValue(for: "h_out")?.multiArrayValue,
                      let cOut = outputFeatures.featureValue(for: "c_out")?.multiArrayValue else {
                    throw SileroVADError.predictionFailed("CoreML output structure is invalid (missing probability, h_out, or c_out)")
                }
                
                let probability: Float
                if probabilityArray.dataType == .float16 {
                    let pPtr = probabilityArray.dataPointer.bindMemory(to: Float16.self, capacity: 1)
                    probability = Float(pPtr[0])
                } else {
                    probability = probabilityArray[0].floatValue
                }
                
                // Update streamState
                streamState = StreamingState(
                    h: hOut,
                    c: cOut,
                    last64Samples: Array(chunk.suffix(64))
                )

                switch self.stateMachine.ingest(probability: probability, now: Date().timeIntervalSinceReferenceDate) {
                case .none:
                    break
                case .speechStarted(let loggedProbability):
                    self.logHandler("Silero VAD detected speech start. p=\(String(format: "%.3f", loggedProbability))")
                    if let closure = self.onSpeechStartedClosure {
                        Task { @MainActor in
                            closure()
                        }
                    }
                case .speechEnded(let loggedProbability):
                    self.logHandler("Silero VAD detected speech end. p=\(String(format: "%.3f", loggedProbability))")
                    if let closure = self.onSpeechEndedClosure {
                        Task { @MainActor in
                            closure()
                        }
                    }
                }
            }

            self.modelState = .ready(model: model, state: streamState)
        } catch {
            self.logHandler("Silero VAD processing error. Falling back to Apple Speech only. Error: \(error.localizedDescription)")
            self.modelState = .failed(message: error.localizedDescription)
            self.chunkAccumulator.reset()
            self.stateMachine.reset()
        }
    }
}

private nonisolated final class ModelDownloadProgressReporter: @unchecked Sendable {
    private let modelName: String
    private let logHandler: @Sendable (String) -> Void
    private let lock = NSLock()
    private var lastLoggedBucket = -1

    nonisolated init(modelName: String, logHandler: @escaping @Sendable (String) -> Void) {
        self.modelName = modelName
        self.logHandler = logHandler
    }

    nonisolated func report(_ progress: Progress) {
        guard progress.totalUnitCount > 0 else {
            return
        }

        let fraction = Double(progress.completedUnitCount) / Double(progress.totalUnitCount)
        let bucket = min(Int((fraction * 100).rounded(.down) / 10) * 10, 100)

        lock.lock()
        defer { lock.unlock() }

        guard bucket > lastLoggedBucket else {
            return
        }

        lastLoggedBucket = bucket
        logHandler("Downloading \(modelName): \(bucket)%")
    }
}
