# Swift 6 Concurrency Migration — Full Project Plan

## Overview

This plan covers **every source file** in the project that needs changes for Swift 6 strict concurrency. The project currently uses `SWIFT_VERSION = 5.0` with no strict concurrency checking.

Across **18 source files**, we identified **~40 specific issues** including data races, isolation boundary violations, non-Sendable types, and patterns that will deadlock under Swift 6's cooperative executor.

---

## Issue Inventory by Module

### 🔴 Critical (will crash/deadlock or is an active data race)

| # | File | Issue | Lines |
|---|------|-------|-------|
| 1 | [ContentView.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/ContentView.swift) | **`DispatchSemaphore` blocks MainActor** — will deadlock under Swift 6's cooperative executor | L252–257 |
| 2 | [SpeechController.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/speech/SpeechController.swift) | **`taskLock` (NSLock) fights `@MainActor` isolation** — redundant lock on MainActor-isolated fields, race between lock-guarded and non-lock-guarded access to `activeQwenGenerationTask` | L283, L643–648, L680–734, L1479–1483 |
| 3 | [SpeechController.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/speech/SpeechController.swift) | **`PlaybackToken` NSLock-based class** checked from multiple isolation domains | L1626–1642 |
| 4 | [WebRTCManager.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/WebRTC/WebRTCManager.swift) | **`onIncomingAudioBuffer` data race** — set from main thread, read from audio render thread | L43, L685–687 |
| 5 | [SignalingClient.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/WebRTC/SignalingClient.swift) | **`heartbeatTimer` data race** — written from main, referenced from `queue`; `pingInterval`/`pingTimeout` written from `queue`, read from main | L40–42, L205–209, L410 |
| 6 | [PowerAssertionManager.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/PowerAssertionManager.swift) | **ObservableObject without `@MainActor`** — global mutable singleton with `@Published` state and no isolation | L11–16 |

---

### 🟠 High (isolation boundary violations — Swift 6 compile errors)

| # | File | Issue | Lines |
|---|------|-------|-------|
| 7 | [SpeechController.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/speech/SpeechController.swift) | 7 callback properties not `@Sendable` — set on MainActor, called from audio threads | L271–280 |
| 8 | [SpeechController.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/speech/SpeechController.swift) | `Task.detached` in `transcribeAudioFileWithQwen` — accesses `self` from non-isolated context | L1084 |
| 9 | [SpeechController.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/speech/SpeechController.swift) | `Task.detached` in `loadQwenModel` / `loadQwenTTSModel` — captures `self` across isolation | L1127, L1304 |
| 10 | [SpeechController.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/speech/SpeechController.swift) | `Task.detached` for Apple TTS synthesis — `AVSpeechSynthesizer.write` callbacks on arbitrary threads with non-Sendable closures | L756 |
| 11 | [WebRTCManager.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/WebRTC/WebRTCManager.swift) | 3 `NSLock`s guarding state the compiler can't verify — `bufferLock`, `streamLock`, `mixerLock` | L35, L38, L52 |
| 12 | [WebRTCManager.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/WebRTC/WebRTCManager.swift) | ~15 `DispatchQueue.main.async` hops in delegate callbacks with non-Sendable `self` capture | L512, L525, L539, L552, L569 |
| 13 | [WebRTCManager.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/WebRTC/WebRTCManager.swift) | 3 delegate protocols not `@MainActor` — `RTCPeerConnectionDelegate`, `RTCDataChannelDelegate`, `RTCAudioDeviceModuleDelegate` | L494, L548, L578 |
| 14 | [SignalingClient.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/WebRTC/SignalingClient.swift) | ~12 isolation boundary crossings between `queue` and `DispatchQueue.main` | Throughout |
| 15 | [P2PConnectionController.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/WebRTC/P2PConnectionController.swift) | `SignalingClientDelegate` and `WebRTCManagerDelegate` not annotated `@MainActor` — conformance on `@MainActor` class | L266, L426 |
| 16 | [P2PConnectionController.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/WebRTC/P2PConnectionController.swift) | `NWPathMonitor` callback closure not `@Sendable` — crosses from monitor queue to MainActor | L150–153 |
| 17 | [ContentView.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/ContentView.swift) | 7 non-`@Sendable` callback closures assigned to SpeechController | L403–444 |
| 18 | [AuthManager.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/auth/AuthManager.swift) | `NotificationCenter` closure calls `@MainActor` methods without `await` | L99–104 |
| 19 | [AgentConnectionController.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/AgentConnectionController.swift) | `AgentTransport` protocol not `Sendable` — stored in `@MainActor` class, used across boundaries | L11, L95 |
| 20 | [LocalRuntimeController.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/LocalRuntimeController.swift) | 3 injected protocol types not `Sendable` — `ContainerAssetManaging`, `ContainerRuntimeManaging`, `LocalRuntimeHealthChecking` | L205–207 |

---

### 🟡 Medium (`@unchecked Sendable` / DispatchQueue-based isolation — functional but not compiler-verified)

| # | File | Issue | Lines |
|---|------|-------|-------|
| 21 | [SileroVADProcessor.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/speech/SileroVADProcessor.swift) | `@unchecked Sendable` + `DispatchQueue` + `NSLock` — complex manual synchronization | L144, L154–155 |
| 22 | [SpeechController.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/speech/SpeechController.swift) | `ProgressAggregator` — `@unchecked Sendable` + `NSLock` | L1644 |
| 23 | [SpeechController.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/speech/SpeechController.swift) | `DataTaskStreamDownloader` — `@unchecked Sendable` + `NSLock`, URLSessionDataDelegate | L1679 |
| 24 | [ContainerizationRuntimeSupport.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/containers/ContainerizationRuntimeSupport.swift) | `FileHandleWriter` — `@unchecked Sendable` + `NSLock`, conforms to sync `Writer` protocol | L871 |

---

### 🟢 Low (missing `Sendable` on value types — easy wins)

| # | File | Issue | Lines |
|---|------|-------|-------|
| 25 | [ChatModels.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/ChatModels.swift) | 7+ structs/enums missing `Sendable` — `ChatMessage`, `AgentEvent`, `TranscribedUtterance`, `ManagedRuntimeEndpoint`, `AgentEndpoint`, `UserAudioClip`, `OutboundMessage` | Various |
| 26 | [LocalRuntimeController.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/LocalRuntimeController.swift) | `ManagedContainerConfiguration` not `Sendable` | L77 |
| 27 | [ContainerizationRuntimeSupport.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/containers/ContainerizationRuntimeSupport.swift) | `ApplicationSupportContainerAssetManager` uses `@unchecked Sendable` but has no mutable state — can just be `Sendable` | L58 |
| 28 | [ContainerizationRuntimeSupport.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/containers/ContainerizationRuntimeSupport.swift) | `KernelDownloadDelegate` not marked `Sendable` — crosses threads as URLSession delegate | L238 |
| 29 | [AuthManager.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/auth/AuthManager.swift) | `KeychainHelper` should explicitly conform to `Sendable` | L16 |
| 30 | [SileroVADProcessor.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/speech/SileroVADProcessor.swift) | `@preconcurrency import MLX` — check if still needed | L9 |

---

### ⚪ Trivial (cleanup)

| # | File | Issue | Lines |
|---|------|-------|-------|
| 31 | [OnboardingView.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/onboarding/OnboardingView.swift) | Unused `@State private var timer: AnyCancellable?` | L46 |
| 32 | [ChatModels.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/ChatModels.swift) | Unnecessary `nonisolated` annotations on plain structs | L21, L43, L47, L56 |
| 33 | [glosos_macOSApp.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/glosos_macOSApp.swift) | Global `print()` creates `DateFormatter` per call (not thread-safe if cached) | L27–37 |

---

## Files That Are Already Clean ✅

| File | Why |
|------|-----|
| [AuthModels.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/auth/AuthModels.swift) | All immutable value types, implicitly `Sendable` |
| [AuthView.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/auth/AuthView.swift) | SwiftUI View, correct `Task` usage |
| [SpeechLanguage.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/speech/SpeechLanguage.swift) | Simple enum |
| [SpeechTurnCoordinator.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/speech/SpeechTurnCoordinator.swift) | Pure value-type state machine |
| `ContainerizationRuntimeEngine` (in ContainerizationRuntimeSupport) | Already an `actor` ✅ |
| `KernelDownloadProgressReporter` / `ContainerOperationProgressReporter` | Already actors ✅ |

---

## Execution Plan

### Phase 1: Fix Critical Issues (Swift 5 compatible)

These changes work under Swift 5 and fix real bugs/races.

#### 1a. [SpeechController.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/speech/SpeechController.swift) — Qwen TTS races
- Remove `taskLock` (NSLock) — fields are MainActor-isolated, lock is redundant
- Remove `PlaybackToken` class — replace with `Task.isCancelled`
- Store `activePlaybackTask: Task<Void, Never>?` — cancel on new playback or `stopPlayback()`
- Convert Qwen TTS `beginPlayback` to structured `Task` with `Task.isCancelled` checks
- Make 7 callback properties `@Sendable`
- Replace `Task.detached` in `transcribeAudioFileWithQwen` / `loadQwenModel` / `loadQwenTTSModel` with `Task { }` that hops out only for CPU-bound work

#### 1b. [PowerAssertionManager.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/PowerAssertionManager.swift) — Missing isolation
- Add `@MainActor` to the class

#### 1c. [ContentView.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/ContentView.swift) — DispatchSemaphore deadlock
- Replace `DispatchSemaphore` pattern (L252–257) with a `Task` that runs the async cleanup and calls `NSApp.reply(toApplicationShouldTerminate: true)` when done
- Mark all callback closures assigned to `SpeechController` as `@Sendable`

#### 1d. [ChatModels.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/ChatModels.swift) — Sendable conformances
- Add `: Sendable` to all structs and enums
- Remove unnecessary `nonisolated` annotations

---

### Phase 2: WebRTC & Signaling Layer

#### 2a. [SignalingClient.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/WebRTC/SignalingClient.swift) — Convert to `actor`
- Replace `DispatchQueue` isolation with actor isolation
- Replace `Timer.scheduledTimer` heartbeat with `Task.sleep`-based loop
- `URLSessionWebSocketDelegate` methods become `nonisolated`
- Delegate calls use `@MainActor`-annotated `SignalingClientDelegate` protocol

#### 2b. [WebRTCManager.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/WebRTC/WebRTCManager.swift) — Convert to `actor`
- Replace 3 `NSLock` instances with actor isolation
- WebRTC delegate methods (`RTCPeerConnectionDelegate`, etc.) become `nonisolated` with internal hops
- **Exception**: Audio real-time path (buffer scheduling callbacks) stays with `Mutex`/`OSAllocatedUnfairLock` — audio render callbacks cannot `await`
- Annotate `WebRTCManagerDelegate` protocol with `@MainActor`

#### 2c. [P2PConnectionController.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/WebRTC/P2PConnectionController.swift) — Fix protocol conformances
- Annotate `SignalingClientDelegate` and `WebRTCManagerDelegate` with `@MainActor`
- Make `NWPathMonitor` callback `@Sendable`
- Convert `@escaping` completion handlers to `async` where possible

---

### Phase 3: Supporting Modules

#### 3a. [SileroVADProcessor.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/speech/SileroVADProcessor.swift) — Convert to `actor`
- Replace `DispatchQueue` + `NSLock` + `@unchecked Sendable` with actor
- `append(samples:)` and `loadModelIfNeeded()` become `async`
- Callbacks become `@Sendable` closures
- Remove `@preconcurrency import MLX` if no longer needed

#### 3b. Other supporting fixes
- [AgentConnectionController.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/AgentConnectionController.swift) — Add `Sendable` to `AgentTransport` protocol and `OutboundMessage`
- [LocalRuntimeController.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/LocalRuntimeController.swift) — Add `Sendable` to injected protocols and `ManagedContainerConfiguration`
- [AuthManager.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/auth/AuthManager.swift) — Fix NotificationCenter closure (L99–104)
- [ContainerizationRuntimeSupport.swift](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS/containers/ContainerizationRuntimeSupport.swift) — Minor `Sendable` fixes

---

### Phase 4: Flip to Swift 6

#### [project.pbxproj](file:///Users/evgeniibasistyi/GitHub/glosos-macOS/glosos-macOS.xcodeproj/project.pbxproj)
- Change `SWIFT_VERSION = 5.0` → `SWIFT_VERSION = 6.0`
- Build and fix any remaining compiler errors (likely from MLX/WebRTC framework imports needing `@preconcurrency`)

---

## Open Questions

> [!IMPORTANT]
> **1. What is your minimum macOS deployment target?**
> - macOS 13+ → can use `OSAllocatedUnfairLock`
> - macOS 15+ → can use stdlib `Mutex`
> - This affects how we handle the audio real-time path in `WebRTCManager` (can't use actors there)

> [!IMPORTANT]
> **2. Do you want all 4 phases, or should we start with Phase 1 only?**
> Phase 1 fixes the actual races and is lowest risk. Phases 2–3 are larger refactors of WebRTC/VAD that change more code. Phase 4 is the final flag flip.

> [!WARNING]
> **3. MLX library compatibility** — `MLXAudioTTS`, `MLXAudioSTT`, `MLXAudioCore`, `MLXLMCommon`, and `HuggingFace` packages may not be Swift 6 ready. If they aren't, we'd need `@preconcurrency import` for those modules or keep specific targets in Swift 5 mode.

> [!NOTE]
> **4. WebRTC.xcframework** — The `RTCPeerConnectionDelegate`, `RTCDataChannelDelegate`, `RTCAudioDeviceModuleDelegate` protocols come from the vendored WebRTC framework. These are Objective-C protocols and will likely need `@preconcurrency import WebRTC` under Swift 6.

## Verification Plan

### After Each Phase
- Build and verify zero compiler errors
- Run the app, test Qwen3 TTS playback and ASR transcription
- Test rapid start/stop/switch of playback
- Test WebRTC connection lifecycle (connect, disconnect, reconnect)

### After Phase 4 (Swift 6 flip)
- Build with `SWIFT_STRICT_CONCURRENCY = complete`
- Address any remaining warnings from third-party dependencies with `@preconcurrency import`
- Full integration test: connect to WebRTC → speak → VAD triggers → ASR transcribes → agent responds → TTS plays back → interrupt with speech
