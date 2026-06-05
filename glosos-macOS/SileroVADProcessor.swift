//
//  SileroVADProcessor.swift
//  glosos-macOS
//
//  Created by Codex on 6/5/26.
//

import Foundation
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioVAD

struct SileroChunkAccumulator {
    static let targetSampleRate = 16_000
    static let targetChunkSize = 512

    private var pendingInputSamples: [Float] = []
    private var pendingResampledSamples: [Float] = []

    mutating func reset() {
        pendingInputSamples.removeAll(keepingCapacity: true)
        pendingResampledSamples.removeAll(keepingCapacity: true)
    }

    mutating func append(samples: [Float], sampleRate: Int) throws -> [[Float]] {
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

    private mutating func drainChunks() -> [[Float]] {
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

    init(
        startThreshold: Float = 0.60,
        startFrames: Int = 2,
        endThreshold: Float = 0.35,
        endFrames: Int = 10,
        chunkDuration: TimeInterval = Double(SileroChunkAccumulator.targetChunkSize) / Double(SileroChunkAccumulator.targetSampleRate)
    ) {
        self.startThreshold = startThreshold
        self.startFrames = startFrames
        self.endThreshold = endThreshold
        self.endFrames = endFrames
        self.chunkDuration = chunkDuration
    }

    mutating func reset() {
        isSpeechActive = false
        speechStartTime = nil
        lastSpeechTime = nil
        consecutiveSpeechFrames = 0
        consecutiveSilenceFrames = 0
    }

    mutating func ingest(probability: Float, now: TimeInterval) -> Event {
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

final class SileroVADProcessor: @unchecked Sendable {
    private enum ModelState {
        case idle
        case loading
        case ready(model: SileroVAD, state: SileroVADStreamingState?)
        case failed(message: String)
    }

    private let processingQueue = DispatchQueue(label: "com.glosos.silero-vad")
    private let callbackLock = NSLock()
    private let logHandler: @Sendable (String) -> Void

    private var modelState: ModelState = .idle
    private var chunkAccumulator = SileroChunkAccumulator()
    private var stateMachine = VADSpeechStateMachine()
    private var onSpeechStartedClosure: (@Sendable () -> Void)?
    private var onSpeechEndedClosure: (@Sendable () -> Void)?

    init(logHandler: @escaping @Sendable (String) -> Void) {
        self.logHandler = logHandler
    }

    var isReady: Bool {
        processingQueue.sync {
            if case .ready = modelState {
                return true
            }
            return false
        }
    }

    var onSpeechStarted: (@Sendable () -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return onSpeechStartedClosure
        }
        set {
            callbackLock.lock()
            onSpeechStartedClosure = newValue
            callbackLock.unlock()
        }
    }

    var onSpeechEnded: (@Sendable () -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return onSpeechEndedClosure
        }
        set {
            callbackLock.lock()
            onSpeechEndedClosure = newValue
            callbackLock.unlock()
        }
    }

    func loadModelIfNeeded() {
        processingQueue.async {
            guard case .idle = self.modelState else {
                return
            }

            self.modelState = .loading
            self.logHandler("Loading Silero VAD model.")

            Task {
                do {
                    let model = try await SileroVAD.fromPretrained("mlx-community/silero-vad")
                    self.processingQueue.async {
                        self.modelState = .ready(model: model, state: nil)
                        self.chunkAccumulator.reset()
                        self.stateMachine.reset()
                        self.logHandler("Silero VAD ready.")
                    }
                } catch {
                    self.processingQueue.async {
                        let message = error.localizedDescription
                        self.modelState = .failed(message: message)
                        self.logHandler("Silero VAD unavailable. Falling back to Apple Speech only. Error: \(message)")
                    }
                }
            }
        }
    }

    func resetSession() {
        processingQueue.async {
            self.chunkAccumulator.reset()
            self.stateMachine.reset()

            if case let .ready(model, _) = self.modelState {
                self.modelState = .ready(model: model, state: nil)
            }
        }
    }

    func append(samples: [Float], sampleRate: Int) {
        processingQueue.async {
            guard case let .ready(model, currentState) = self.modelState else {
                return
            }

            do {
                let chunks = try self.chunkAccumulator.append(samples: samples, sampleRate: sampleRate)
                guard !chunks.isEmpty else {
                    self.modelState = .ready(model: model, state: currentState)
                    return
                }

                var streamState = currentState

                for chunk in chunks {
                    if streamState == nil {
                        streamState = try model.initialState(sampleRate: SileroChunkAccumulator.targetSampleRate)
                    }

                    let input = MLXArray(chunk)
                    let (probabilityArray, nextState) = try model.feed(
                        chunk: input,
                        state: streamState,
                        sampleRate: SileroChunkAccumulator.targetSampleRate
                    )
                    streamState = nextState

                    let probability = probabilityArray[0].item(Float.self)
                    switch self.stateMachine.ingest(probability: probability, now: Date().timeIntervalSinceReferenceDate) {
                    case .none:
                        break
                    case .speechStarted(let loggedProbability):
                        self.logHandler("Silero VAD detected speech start. p=\(String(format: "%.3f", loggedProbability))")
                        self.onSpeechStarted?()
                    case .speechEnded(let loggedProbability):
                        self.logHandler("Silero VAD detected speech end. p=\(String(format: "%.3f", loggedProbability))")
                        self.onSpeechEnded?()
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
}
