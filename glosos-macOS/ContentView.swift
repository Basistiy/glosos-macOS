//
//  ContentView.swift
//  glosos-macOS
//
//  Created by EV on 6/3/26.
//

import AppKit
import SwiftUI
import AVFoundation

struct ContentView: View {
    @ObservedObject var authManager: AuthManager
    @StateObject private var speechController = SpeechController()
    @StateObject private var agentController = AgentConnectionController()
    @StateObject private var runtimeController = LocalRuntimeController()
    @StateObject private var p2pController = P2PConnectionController()
    @AppStorage("autoSpeakAgentReplies") private var autoSpeakAgentReplies = true
    @AppStorage("preventSystemSleep") private var preventSystemSleep = false
    @AppStorage("playThinkingSound") private var playThinkingSound = true
    @AppStorage("thinkingSoundName") private var thinkingSoundName = "Funk"
    @AppStorage("isOnboardingCompleted") private var isOnboardingCompleted = false
    @State private var isShowingSettings = false
    @State private var hasInitialized = false
    @State private var pendingUtteranceCoordinator = PendingUtteranceCoordinator()
    @State private var assistantPlaybackCoordinator = AssistantPlaybackCoordinator()
    @State private var processingSoundTask: Task<Void, Never>? = nil

    var body: some View {
        Group {
            if !isOnboardingCompleted {
                OnboardingView(runtimeController: runtimeController) {
                    isOnboardingCompleted = true
                }
            } else if authManager.token == nil {
                AuthView(authManager: authManager)
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        header

                        Divider()
                            .overlay(Color.black.opacity(0.06))

                        VStack(spacing: 12) {
                            Spacer()
                            Image(systemName: "laptopcomputer.and.iphone")
                                .font(.system(size: 48))
                                .foregroundStyle(Color(red: 0.18, green: 0.52, blue: 0.42))
                            Link(destination: URL(string: "https://glosos.com")!) {
                                Text("connect to your mac at glosos.com")
                                    .font(.system(.body, design: .rounded).weight(.semibold))
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 12)
                                    .background(Color(red: 0.18, green: 0.52, blue: 0.42))
                                    .foregroundStyle(.white)
                                    .cornerRadius(12)
                                    .shadow(color: Color(red: 0.18, green: 0.52, blue: 0.42).opacity(0.2), radius: 6, x: 0, y: 3)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.96, green: 0.95, blue: 0.92), Color(red: 0.93, green: 0.94, blue: 0.91)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    }

                    if isShowingSettings {
                        Divider()
                            .overlay(Color.black.opacity(0.06))

                        SettingsView(
                            speechController: speechController,
                            agentController: agentController,
                            runtimeController: runtimeController,
                            autoSpeakAgentReplies: $autoSpeakAgentReplies,
                            preventSystemSleep: $preventSystemSleep,
                            playThinkingSound: $playThinkingSound,
                            thinkingSoundName: $thinkingSoundName,
                            connectAction: { Task { await connectUsingSelectedRuntime() } },
                            startRuntimeAction: { Task { await startManagedRuntimeOnly() } },
                            stopRuntimeAction: { Task { await stopManagedRuntime() } },
                            restartRuntimeAction: { Task { await restartManagedRuntime() } },
                            closeAction: {
                                saveSettings()
                                isShowingSettings = false
                            }
                        )
                        .frame(width: 380)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(minWidth: isShowingSettings ? 980 : 600, minHeight: 600)
                .animation(.spring(response: 0.28, dampingFraction: 0.88), value: isShowingSettings)
                .task {
                    await initializeIfNeeded()
                }

                .onChange(of: agentController.latestCompletedAssistantMessage) { _, newValue in
                    guard let newValue else {
                        return
                    }

                    let shouldSpeakAssistantReply = assistantPlaybackCoordinator.consumeCompletion(for: newValue)
                    if autoSpeakAgentReplies, shouldSpeakAssistantReply {
                        speechController.play(newValue.text)
                    }
                    
                    // Forward LLM response to WebRTC peer if connected
                    if p2pController.isConnected {
                        let payload: [String: Any] = [
                            "type": "agent",
                            "text": newValue.text
                        ]
                        if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
                           let jsonString = String(data: jsonData, encoding: .utf8) {
                            _ = p2pController.sendMessage(jsonString)
                        } else {
                            _ = p2pController.sendMessage(newValue.text)
                        }
                    }
                    
                    sendPendingUtteranceIfPossible()
                }
                .onChange(of: p2pController.latestReceivedPeerMessage) { _, newValue in
                    guard let newValue else {
                        return
                    }
                    
                    // Forward peer message to LLM agent
                    agentController.sendUserMessage(newValue)
                }
                .onChange(of: authManager.token) { _, newToken in
                    if let newToken = newToken {
                        p2pController.startSignaling(apiEndpoint: authManager.signalingAPIEndpoint, token: newToken)
                    } else {
                        p2pController.disconnect()
                        p2pController.clearMessages()
                    }
                }
                .onChange(of: p2pController.isConnected) { _, isConnected in
                    speechController.isWebRTCConnected = isConnected
                    if isConnected {
                        p2pController.setMicrophoneMuted(speechController.isMicrophoneMuted)
                        p2pController.setSpeakersMuted(speechController.isSpeakersMuted)
                    }
                }
                .onChange(of: speechController.isMicrophoneMuted) { _, isMuted in
                    p2pController.setMicrophoneMuted(isMuted)
                }
                .onChange(of: speechController.isSpeakersMuted) { _, isMuted in
                    p2pController.setSpeakersMuted(isMuted)
                }
                .onChange(of: preventSystemSleep) { _, newValue in
                    PowerAssertionManager.shared.updateAssertion(shouldPreventSleep: newValue)
                }
                .onChange(of: agentController.isAwaitingAssistantResponse) { _, newValue in
                    sendPendingUtteranceIfPossible()
                    if playThinkingSound {
                        if newValue {
                            startProcessingSound()
                        } else {
                            stopProcessingSound()
                        }
                    }
                }
                .onChange(of: playThinkingSound) { _, newValue in
                    if !newValue {
                        stopProcessingSound()
                    } else if agentController.isAwaitingAssistantResponse {
                        startProcessingSound()
                    }
                }
                .onChange(of: speechController.playbackInterruptionToken) { _, newValue in
                    if newValue != nil {
                        assistantPlaybackCoordinator.suppress(messageID: agentController.activeAssistantTurnID)
                    }
                }
                .onChange(of: speechController.finalizedUtterance) { _, newValue in
                    guard let newValue = newValue else {
                        return
                    }
                    
                    // Send voice transcription back to WebRTC peer if connected
                    if p2pController.isConnected {
                        let payload: [String: Any] = [
                            "type": "transcription",
                            "text": newValue.text
                        ]
                        if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
                           let jsonString = String(data: jsonData, encoding: .utf8) {
                            _ = p2pController.sendMessage(jsonString)
                        }
                    }
                    
                    enqueueOrSend(newValue)
                }
                .onChange(of: runtimeController.runtimeMode) { _, _ in
                    guard hasInitialized else {
                        return
                    }

                    agentController.disconnect()
                    Task {
                        await runtimeController.refreshStatus()
                    }
                }
                .onChange(of: runtimeController.lastRuntimeError) { _, newValue in
                    guard let newValue else {
                        return
                    }

                    agentController.appendSystemMessage(newValue, state: .error)
                }
                .onDisappear {
                    saveSettings()
                    agentController.disconnect()
                    p2pController.disconnect()
                    speechController.stopContinuousListening()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    let semaphore = DispatchSemaphore(value: 0)
                    Task {
                        await stopManagedRuntime()
                        semaphore.signal()
                    }
                    _ = semaphore.wait(timeout: .now() + 2.0)
                }
            }
        }
    }



    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Glosos")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.14, green: 0.19, blue: 0.16))
                    .lineLimit(1)
                    .layoutPriority(1)
            }

            Spacer()

            if let user = authManager.user {
                Label {
                    Text(user.username)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                } icon: {
                    Circle()
                        .fill(Color(red: 0.18, green: 0.52, blue: 0.42))
                        .frame(width: 8, height: 8)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.72))
                .clipShape(Capsule())
                .fixedSize(horizontal: true, vertical: false)
            }

            Label {
                Text(agentController.statusDetail)
                    .font(.system(.subheadline, design: .rounded))
                    .lineLimit(1)
            } icon: {
                Circle()
                    .fill(agentController.isConnected ? Color(red: 0.16, green: 0.57, blue: 0.43) : Color(red: 0.78, green: 0.38, blue: 0.28))
                    .frame(width: 10, height: 10)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.white.opacity(0.72))
            .clipShape(Capsule())
            .fixedSize(horizontal: true, vertical: false)

            if authManager.token != nil {
                Label {
                    Text(p2pController.isConnected ? "Peer connected" : p2pController.statusDetail)
                        .font(.system(.subheadline, design: .rounded))
                        .lineLimit(1)
                } icon: {
                    Circle()
                        .fill(p2pController.isConnected ? Color(red: 0.22, green: 0.48, blue: 0.72) : Color(red: 0.78, green: 0.38, blue: 0.28))
                        .frame(width: 10, height: 10)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.white.opacity(0.72))
                .clipShape(Capsule())
                .fixedSize(horizontal: true, vertical: false)
            }

            Button {
                openManagedUserFolder()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.78))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Button {
                if isShowingSettings {
                    saveSettings()
                }
                isShowingSettings.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(
                        isShowingSettings
                            ? Color(red: 0.18, green: 0.52, blue: 0.42).opacity(0.92)
                            : .white.opacity(0.78)
                    )
                    .foregroundStyle(isShowingSettings ? .white : Color.primary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Button {
                authManager.logout()
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.78))
                    .foregroundStyle(Color(red: 0.70, green: 0.28, blue: 0.23))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial)
    }


    private func openManagedUserFolder() {
        let userFolderURL = runtimeController.managedUserFolderURL

        do {
            try FileManager.default.createDirectory(
                at: userFolderURL,
                withIntermediateDirectories: true
            )
        } catch {
            NSWorkspace.shared.open(userFolderURL.deletingLastPathComponent())
            return
        }

        NSWorkspace.shared.open(userFolderURL)
    }

    private func initializeIfNeeded() async {
        guard !hasInitialized else {
            return
        }

        hasInitialized = true
        
        PowerAssertionManager.shared.updateAssertion(shouldPreventSleep: preventSystemSleep)
        
        // Setup WebRTC audio callbacks
        speechController.agentResponsesDirectoryURL = runtimeController.managedUserFolderURL
        speechController.onSynthesizedFile = { [weak p2pController] fileURL, completion in
            p2pController?.playAudioFile(at: fileURL, completion: completion)
        }
        speechController.onStopPlayback = { [weak p2pController] in
            p2pController?.stopAudioPlayback()
        }
        speechController.onSpeechStarted = { [weak agentController] in
            agentController?.abortActiveTurn()
            pendingUtteranceCoordinator.clear()
        }
        speechController.isWebRTCConnected = p2pController.isConnected
        
        // Setup incoming WebRTC audio transcription callback
        p2pController.onIncomingAudioBuffer = { [weak speechController] buffer in
            Task { @MainActor in
                speechController?.feedExternalAudio(buffer)
            }
        }
        
        await speechController.preparePermissions()
        speechController.refreshPermissionState()
        if speechController.isReadyForLiveTranscription {
            await speechController.startContinuousListening()
        }
        await runtimeController.refreshStatus()
        await connectUsingSelectedRuntime()
        
        if let token = authManager.token {
            p2pController.startSignaling(apiEndpoint: authManager.signalingAPIEndpoint, token: token)
        }
        
        // Sync initial mute state
        p2pController.setMicrophoneMuted(speechController.isMicrophoneMuted)
        p2pController.setSpeakersMuted(speechController.isSpeakersMuted)
    }

    private func connectUsingSelectedRuntime() async {
        if runtimeController.isManagedMode {
            guard runtimeController.isManagedRuntimeConfigured else {
                return
            }

            if runtimeController.runtimeState == .running, let endpoint = runtimeController.currentManagedEndpoint {
                await agentController.connect(using: endpoint)
                return
            }

            let didStart = await runtimeController.startRuntime()
            guard didStart, let endpoint = runtimeController.currentManagedEndpoint else {
                return
            }

            await agentController.connect(using: endpoint)
            return
        }

        await agentController.connect()
    }

    private func startManagedRuntimeOnly() async {
        guard runtimeController.isManagedMode else {
            return
        }

        _ = await runtimeController.startRuntime()
    }

    private func stopManagedRuntime() async {
        agentController.disconnect()
        await runtimeController.stopRuntime()
    }

    private func restartManagedRuntime() async {
        agentController.disconnect()
        let didRestart = await runtimeController.restartRuntime()
        guard didRestart, let endpoint = runtimeController.currentManagedEndpoint else {
            return
        }

        await agentController.connect(using: endpoint)
    }

    private func enqueueOrSend(_ utterance: TranscribedUtterance) {
        // Always route speech to the LLM agent. When a WebRTC peer is
        // connected, the LLM response will be forwarded to the peer
        // automatically via the .onChange handler.
        if let utteranceToSend = pendingUtteranceCoordinator.register(
            utterance,
            whileAwaitingAssistantResponse: agentController.isAwaitingAssistantResponse
        ) {
            _ = agentController.sendUserMessage(utteranceToSend)
        }
    }

    private func sendPendingUtteranceIfPossible() {
        guard let pendingUtterance = pendingUtteranceCoordinator.dequeueIfReady(
            whileAwaitingAssistantResponse: agentController.isAwaitingAssistantResponse
        ) else {
            return
        }

        _ = agentController.sendUserMessage(pendingUtterance)
    }



    private func saveSettings() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        runtimeController.saveSettings()
        agentController.saveSettings()
    }

    private func startProcessingSound() {
        processingSoundTask?.cancel()
        processingSoundTask = Task {
            let soundURL = URL(fileURLWithPath: "/System/Library/Sounds/\(thinkingSoundName).aiff")
            
            if p2pController.isConnected {
                p2pController.playAudioFile(at: soundURL) {}
            } else {
                NSSound(named: thinkingSoundName)?.play()
            }
            
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                
                if p2pController.isConnected {
                    p2pController.playAudioFile(at: soundURL) {}
                } else {
                    NSSound(named: thinkingSoundName)?.play()
                }
            }
        }
    }

    private func stopProcessingSound() {
        processingSoundTask?.cancel()
        processingSoundTask = nil
        if p2pController.isConnected {
            p2pController.stopAudioPlayback()
        }
    }
}



private struct SettingsView: View {
    @ObservedObject var speechController: SpeechController
    @ObservedObject var agentController: AgentConnectionController
    @ObservedObject var runtimeController: LocalRuntimeController
    @Binding var autoSpeakAgentReplies: Bool
    @Binding var preventSystemSleep: Bool
    @Binding var playThinkingSound: Bool
    @Binding var thinkingSoundName: String
    let connectAction: () -> Void
    let startRuntimeAction: () -> Void
    let stopRuntimeAction: () -> Void
    let restartRuntimeAction: () -> Void
    let closeAction: () -> Void

    // Presets
    private let geminiPresets = [
        "gemini-3.5-flash",
        "gemini-3.1-pro",
        "gemini-3.1-flash-lite"
    ]
    
    private let localBasePresets = [
        "http://192.168.64.1:11434/v1": "Ollama (VM Bridge)",
        "http://192.168.64.1:1234/v1": "LM Studio (VM Bridge)",
        "http://localhost:11434/v1": "Ollama (Localhost)",
        "http://localhost:1234/v1": "LM Studio (Localhost)"
    ]
    
    private let localModelPresets = [
        "llama3",
        "llama3:8b",
        "mistral",
        "gemma2",
        "phi3"
    ]

    private let containerImagePresets = [
        ("docker.io/evbasistyi/glosos-google-user:latest", "Google User (Docker Hub)"),
        ("docker.io/evbasistyi/glosos-local-container:latest", "Local Container (Docker Hub)"),
    ]

    @State private var geminiModelSelection: String = ""
    @State private var localBaseSelection: String = ""
    @State private var localModelSelection: String = ""
    @State private var containerImageSelection: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Settings")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(Color(red: 0.14, green: 0.19, blue: 0.16))

                Spacer()

                Button("Close") {
                    closeAction()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                Form {
                    Section("Runtime") {
                        Picker("Mode", selection: $runtimeController.runtimeMode) {
                            ForEach(RuntimeMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }

                        if runtimeController.isManagedMode {
                            Picker("Provider", selection: $runtimeController.managedModelProvider) {
                                ForEach(ModelProvider.allCases) { provider in
                                    Text(provider.title).tag(provider)
                                }
                            }

                            switch runtimeController.managedModelProvider {
                            case .gemini:
                                Picker("Model name", selection: $geminiModelSelection) {
                                    ForEach(geminiPresets, id: \.self) { preset in
                                        Text(preset).tag(preset)
                                    }
                                    Text("Custom...").tag("custom")
                                }
                                .pickerStyle(.menu)
                                
                                if geminiModelSelection == "custom" {
                                    TextField("Custom Model Name", text: $runtimeController.managedModelName)
                                }

                                SecureField("Google API key", text: $runtimeController.managedGoogleAPIKey)

                                HStack(spacing: 4) {
                                    Text("Get a Google API key from")
                                        .font(.system(.footnote, design: .rounded))
                                        .foregroundStyle(.secondary)
                                    Link("Google AI Studio", destination: URL(string: "https://aistudio.google.com/")!)
                                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                                        .foregroundStyle(Color(red: 0.18, green: 0.52, blue: 0.42))
                                }

                            case .localOpenAI:
                                Picker("API Base URL", selection: $localBaseSelection) {
                                    ForEach(localBasePresets.keys.sorted(), id: \.self) { key in
                                        Text(localBasePresets[key] ?? "").tag(key)
                                    }
                                    Text("Custom URL...").tag("custom")
                                }
                                .pickerStyle(.menu)
                                
                                if localBaseSelection == "custom" {
                                    TextField("Custom API Base URL", text: $runtimeController.managedLocalLLMApiBase)
                                }

                                SecureField("API Key (optional)", text: $runtimeController.managedLocalLLMApiKey)

                                Picker("Model name", selection: $localModelSelection) {
                                    ForEach(localModelPresets, id: \.self) { preset in
                                        Text(preset).tag(preset)
                                    }
                                    Text("Custom Model...").tag("custom")
                                }
                                .pickerStyle(.menu)

                                if localModelSelection == "custom" {
                                    TextField("Custom Model Name", text: $runtimeController.managedModelName)
                                }
                            }

                            if !runtimeController.isManagedRuntimeConfigured {
                                Text(runtimeController.runtimeStatusDetail)
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }

                            HStack {
                                Text("Runtime endpoint")
                                Spacer()
                                Text(runtimeController.computedEndpointURL)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }

                            HStack {
                                Text("Container port")
                                Spacer()
                                Text("8000")
                                    .foregroundStyle(.secondary)
                            }

                            HStack(alignment: .top, spacing: 12) {
                                Text("User folder")
                                Spacer()
                                VStack(alignment: .trailing, spacing: 8) {
                                    Text(runtimeController.managedUserFolderPath)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.trailing)
                                        .textSelection(.enabled)

                                    Button("Open in Finder") {
                                        openManagedUserFolder()
                                    }
                                }
                            }

                            HStack {
                                Text("Runtime status")
                                Spacer()
                                Text(runtimeController.runtimeStatusDetail)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }

                            if let version = runtimeController.detectedContainerVersion {
                                HStack {
                                    Text("Container version")
                                    Spacer()
                                    Text(version)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            HStack(spacing: 12) {
                                Button("Start") {
                                    startRuntimeAction()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(runtimeController.isRuntimeActionDisabled)

                                Button("Stop") {
                                    stopRuntimeAction()
                                }
                                .disabled(runtimeController.isRuntimeActionDisabled)

                                Button("Restart") {
                                    restartRuntimeAction()
                                }
                                .disabled(runtimeController.isRuntimeActionDisabled)
                            }

                            if let lastRuntimeError = runtimeController.lastRuntimeError {
                                Text(lastRuntimeError)
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(Color(red: 0.70, green: 0.28, blue: 0.23))
                            }

                            if !runtimeController.recentLogs.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Recent container logs")
                                        .font(.system(.footnote, design: .rounded).weight(.semibold))

                                    ScrollView {
                                        Text(runtimeController.recentLogs)
                                            .font(.system(.caption, design: .monospaced))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .textSelection(.enabled)
                                    }
                                    .frame(minHeight: 120)
                                }
                            }

                            Picker("Container Image", selection: $containerImageSelection) {
                                ForEach(containerImagePresets, id: \.0) { preset in
                                    Text(preset.1).tag(preset.0)
                                }
                                Text("Custom...").tag("custom")
                            }
                            .pickerStyle(.menu)
                            
                            if containerImageSelection == "custom" {
                                TextField("Image URL", text: $runtimeController.managedContainerImage)
                            }
                            
                            TextField("Container name", text: $runtimeController.managedContainerName)

                            Button("Force Pull Image on Next Start") {
                                Task {
                                    _ = await runtimeController.deleteImageCache()
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(runtimeController.runtimeState != .stopped)
                        }
                    }

                    Section("Connection") {
                        if runtimeController.isManagedMode {
                            HStack {
                                Text("Endpoint URL")
                                Spacer()
                                Text(runtimeController.computedEndpointURL)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        } else {
                            TextField("Endpoint URL", text: $agentController.endpointURL)
                        }

                        TextField("Session ID", text: $agentController.sessionID)

                        HStack {
                            Text("Status")
                            Spacer()
                            Text(agentController.connectionStatus)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 12) {
                            Button(agentController.isConnected ? "Reconnect" : "Connect") {
                                connectAction()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Disconnect") {
                                agentController.disconnect()
                            }
                            .disabled(!agentController.isConnected)
                        }
                    }

                    Section("Playback") {
                        Toggle("Speak assistant replies aloud", isOn: $autoSpeakAgentReplies)
                        Toggle("Auditory thinking feedback", isOn: $playThinkingSound)
                        if playThinkingSound {
                            Picker("Thinking sound", selection: $thinkingSoundName) {
                                Text("Funk (Sleek Slap)").tag("Funk")
                                Text("Tink (Subtle)").tag("Tink")
                                Text("Glass (Soft Chime)").tag("Glass")
                                Text("Ping (Clear)").tag("Ping")
                                Text("Submarine (Sonar)").tag("Submarine")
                            }
                            .pickerStyle(.menu)
                            .onChange(of: thinkingSoundName) { _, newValue in
                                NSSound(named: newValue)?.play()
                            }
                        }
                    }

                    Section("System") {
                        Toggle("Prevent system sleep", isOn: $preventSystemSleep)
                        Text("Keep the Mac awake while Glosos is running so background services remain active when you are away.")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Section("Speech") {
                        Picker("Language", selection: $speechController.selectedLanguage) {
                            ForEach(SpeechLanguage.allCases) { language in
                                Text(language.title).tag(language)
                            }
                        }

                        Text("This setting changes both live speech recognition and synthesized voice playback.")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(.secondary)

                        Divider()

                        Picker("ASR System", selection: $speechController.selectedASRSystem) {
                            ForEach(ASRSystem.allCases) { system in
                                Text(system.title).tag(system)
                            }
                        }
                        .pickerStyle(.menu)

                        if speechController.selectedASRSystem == .qwen {
                            switch speechController.qwenASRState {
                            case .idle:
                                Text("Select Qwen3 ASR to start download.")
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(.secondary)
                            case .downloading(let progress, let completed, let total):
                                VStack(alignment: .leading, spacing: 4) {
                                    ProgressView("Downloading Qwen3-ASR model...", value: progress, total: 1.0)
                                        .progressViewStyle(.linear)
                                    if total > 0 {
                                        Text("\(String(format: "%.2f", Double(completed) / 1_000_000_000)) GB of \(String(format: "%.2f", Double(total) / 1_000_000_000)) GB (\(Int(progress * 100))%)")
                                            .font(.system(.footnote, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("Initializing download...")
                                            .font(.system(.footnote, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            case .loading:
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Loading model weights into memory...")
                                        .font(.system(.footnote, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            case .ready:
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text("Qwen3 ASR is ready.")
                                        .font(.system(.footnote, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            case .failed(let message):
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.red)
                                        Text("Failed to load Qwen3 ASR.")
                                            .font(.system(.body, design: .rounded))
                                            .bold()
                                    }
                                    Text(message)
                                        .font(.system(.footnote, design: .rounded))
                                        .foregroundStyle(.red)
                                    Button("Retry") {
                                        speechController.loadQwenModel()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                            }
                        }

                        if speechController.personalVoiceAuthorizationStatus != .unsupported {
                            Toggle("Use Personal Voice", isOn: Binding(
                                get: { speechController.usePersonalVoice },
                                set: { newValue in
                                    Task {
                                        await speechController.setUsePersonalVoice(newValue)
                                    }
                                }
                            ))

                            if speechController.usePersonalVoice {
                                if speechController.availablePersonalVoices.isEmpty {
                                    Text("No Personal Voices found. Please configure a Personal Voice in macOS System Settings > Accessibility > Personal Voice.")
                                        .font(.system(.footnote, design: .rounded))
                                        .foregroundStyle(.red)
                                } else {
                                    Picker("Personal Voice", selection: Binding(
                                        get: { speechController.selectedPersonalVoiceIdentifier },
                                        set: { newValue in
                                            speechController.selectedPersonalVoiceIdentifier = newValue
                                        }
                                    )) {
                                        ForEach(speechController.availablePersonalVoices, id: \.identifier) { voice in
                                            Text(voice.name).tag(voice.identifier as String?)
                                        }
                                    }
                                }
                            }
                        } else {
                            Text("Personal Voice is not supported on this Mac.")
                                .font(.system(.footnote, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Voice Activity Detection (VAD)") {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Start Threshold")
                                    Spacer()
                                    Text(String(format: "%.2f", speechController.vadStartThreshold))
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $speechController.vadStartThreshold, in: 0.1...0.9, step: 0.05)
                                Text("Minimum speech probability required to start capturing.")
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            
                            Divider()
                            
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Start Frames")
                                    Spacer()
                                    Text("\(speechController.vadStartFrames) (\(speechController.vadStartFrames * 32) ms)")
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: Binding(
                                    get: { Double(speechController.vadStartFrames) },
                                    set: { speechController.vadStartFrames = Int($0) }
                                ), in: 1...10, step: 1)
                                Text("Number of consecutive 32ms frames above start threshold to confirm speech.")
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            
                            Divider()
                            
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("End Threshold")
                                    Spacer()
                                    Text(String(format: "%.2f", speechController.vadEndThreshold))
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $speechController.vadEndThreshold, in: 0.1...0.9, step: 0.05)
                                Text("Probability threshold below which audio is considered silence.")
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            
                            Divider()
                            
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("End Frames")
                                    Spacer()
                                    Text("\(speechController.vadEndFrames) (\(speechController.vadEndFrames * 32) ms)")
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: Binding(
                                    get: { Double(speechController.vadEndFrames) },
                                    set: { speechController.vadEndFrames = Int($0) }
                                ), in: 2...30, step: 1)
                                Text("Number of consecutive 32ms frames of silence to confirm speech ended.")
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
        .onDisappear {
            NSApp.keyWindow?.makeFirstResponder(nil)
            runtimeController.saveSettings()
            agentController.saveSettings()
        }
        .onAppear {
            syncPresetsWithController()
            speechController.refreshPersonalVoiceStatus()
        }
        .onChange(of: runtimeController.managedModelProvider) { _, _ in
            syncPresetsWithController()
        }
        .onChange(of: geminiModelSelection) { _, newValue in
            if newValue != "custom" {
                runtimeController.managedModelName = newValue
            }
        }
        .onChange(of: localModelSelection) { _, newValue in
            if newValue != "custom" {
                runtimeController.managedModelName = newValue
            }
        }
        .onChange(of: localBaseSelection) { _, newValue in
            if newValue != "custom" {
                runtimeController.managedLocalLLMApiBase = newValue
            }
        }
        .onChange(of: containerImageSelection) { _, newValue in
            if newValue != "custom" {
                runtimeController.managedContainerImage = newValue
                
                // Automatically sync the container name to avoid configuration mismatches
                if newValue == "docker.io/evbasistyi/glosos-local-container:latest" {
                    runtimeController.managedContainerName = "glosos-local-container-macos"
                } else if newValue == "docker.io/evbasistyi/glosos-google-user:latest" || newValue == "ghcr.io/basistiy/glosos-google-user:latest" {
                    runtimeController.managedContainerName = "glosos-google-user-macos"
                }
            }
        }
    }

    private func openManagedUserFolder() {
        let userFolderURL = runtimeController.managedUserFolderURL

        do {
            try FileManager.default.createDirectory(
                at: userFolderURL,
                withIntermediateDirectories: true
            )
        } catch {
            NSWorkspace.shared.open(userFolderURL.deletingLastPathComponent())
            return
        }

        NSWorkspace.shared.open(userFolderURL)
    }

    private func syncPresetsWithController() {
        if geminiPresets.contains(runtimeController.managedModelName) {
            geminiModelSelection = runtimeController.managedModelName
        } else {
            geminiModelSelection = "custom"
        }
        
        if localBasePresets.keys.contains(runtimeController.managedLocalLLMApiBase) {
            localBaseSelection = runtimeController.managedLocalLLMApiBase
        } else {
            localBaseSelection = "custom"
        }

        if localModelPresets.contains(runtimeController.managedModelName) {
            localModelSelection = runtimeController.managedModelName
        } else {
            localModelSelection = "custom"
        }

        if containerImagePresets.contains(where: { $0.0 == runtimeController.managedContainerImage }) {
            containerImageSelection = runtimeController.managedContainerImage
        } else {
            containerImageSelection = "custom"
        }
    }
}

#Preview {
    ContentView(authManager: AuthManager())
}
