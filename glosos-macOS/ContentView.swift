//
//  ContentView.swift
//  glosos-macOS
//
//  Created by EV on 6/3/26.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var authManager: AuthManager
    @StateObject private var speechController = SpeechController()
    @StateObject private var agentController = AgentConnectionController()
    @StateObject private var runtimeController = LocalRuntimeController()
    @StateObject private var p2pController = P2PConnectionController()
    @AppStorage("autoSpeakAgentReplies") private var autoSpeakAgentReplies = true
    @State private var isShowingSettings = false
    @State private var hasInitialized = false
    @State private var pendingUtteranceCoordinator = PendingUtteranceCoordinator()
    @State private var assistantPlaybackCoordinator = AssistantPlaybackCoordinator()

    var body: some View {
        Group {
            if authManager.token == nil && !authManager.isOfflineMode {
                AuthView(authManager: authManager)
            } else {
                HStack(spacing: 0) {
                    mainContent

                    if isShowingSettings {
                        Divider()
                            .overlay(Color.black.opacity(0.06))

                        SettingsView(
                            speechController: speechController,
                            agentController: agentController,
                            runtimeController: runtimeController,
                            autoSpeakAgentReplies: $autoSpeakAgentReplies,
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
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.96, green: 0.95, blue: 0.92), Color(red: 0.93, green: 0.94, blue: 0.91)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
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
                        _ = p2pController.sendMessage(newValue.text)
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
                    }
                }
                .onChange(of: speechController.isMicrophoneMuted) { _, isMuted in
                    p2pController.setMicrophoneMuted(isMuted)
                }
                .onChange(of: agentController.isAwaitingAssistantResponse) { _, _ in
                    sendPendingUtteranceIfPossible()
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
            }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .overlay(Color.black.opacity(0.06))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        let messagesToShow = agentController.messages
                        
                        if messagesToShow.isEmpty {
                            emptyState
                        }

                        ForEach(messagesToShow) { message in
                            ChatBubbleRow(message: message, speechController: speechController)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("chat-bottom")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
                .background(chatBackground)
                .task(id: chatScrollState) {
                    await Task.yield()
                    scrollToBottom(with: proxy)
                }
            }

            liveTranscriptPanel
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Glosos")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.14, green: 0.19, blue: 0.16))

                Text("Voice chat")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.5))
            }

            Spacer()

            if let user = authManager.user {
                Label {
                    Text(user.username)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                } icon: {
                    Circle()
                        .fill(Color(red: 0.18, green: 0.52, blue: 0.42))
                        .frame(width: 8, height: 8)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.72))
                .clipShape(Capsule())
            } else if authManager.isOfflineMode {
                Label {
                    Text("Offline Mode")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                } icon: {
                    Circle()
                        .fill(Color(red: 0.78, green: 0.38, blue: 0.28))
                        .frame(width: 8, height: 8)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.72))
                .clipShape(Capsule())
            }

            Label {
                Text(agentController.statusDetail)
                    .font(.system(.subheadline, design: .rounded))
            } icon: {
                Circle()
                    .fill(agentController.isConnected ? Color(red: 0.16, green: 0.57, blue: 0.43) : Color(red: 0.78, green: 0.38, blue: 0.28))
                    .frame(width: 10, height: 10)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.white.opacity(0.72))
            .clipShape(Capsule())

            if authManager.token != nil {
                Label {
                    Text(p2pController.isConnected ? "Peer connected" : p2pController.statusDetail)
                        .font(.system(.subheadline, design: .rounded))
                } icon: {
                    Circle()
                        .fill(p2pController.isConnected ? Color(red: 0.22, green: 0.48, blue: 0.72) : Color(red: 0.78, green: 0.38, blue: 0.28))
                        .frame(width: 10, height: 10)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.white.opacity(0.72))
                .clipShape(Capsule())
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
                Image(systemName: authManager.isOfflineMode ? "person.crop.circle.badge.plus" : "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.78))
                    .foregroundStyle(authManager.isOfflineMode ? Color(red: 0.18, green: 0.52, blue: 0.42) : Color(red: 0.70, green: 0.28, blue: 0.23))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("Waiting for connection")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(Color(red: 0.18, green: 0.22, blue: 0.19))

            Text("Connect from a WebRTC peer and start speaking. The app will stream and transcribe audio automatically.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var liveTranscriptPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    microphoneStatusLabel,
                    systemImage: microphoneStatusIcon
                )
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(microphoneStatusColor)

                Spacer()

                if agentController.isAwaitingAssistantResponse {
                    Text("Agent replying")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.black.opacity(0.48))
                }

                Button {
                    if speechController.isReadyForLiveTranscription {
                        speechController.toggleMicrophoneMute()
                    } else {
                        Task {
                            await speechController.startContinuousListening()
                        }
                    }
                } label: {
                    Label(
                        speechController.isReadyForLiveTranscription
                            ? (speechController.isMicrophoneMuted ? "Resume" : "Pause")
                            : "Enable Recording",
                        systemImage: speechController.isReadyForLiveTranscription
                            ? (speechController.isMicrophoneMuted ? "play.circle.fill" : "pause.circle.fill")
                            : "waveform.badge.plus"
                    )
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(
                        speechController.isReadyForLiveTranscription
                            ? (speechController.isMicrophoneMuted ? Color.white : Color(red: 0.35, green: 0.24, blue: 0.18))
                            : Color(red: 0.35, green: 0.24, blue: 0.18)
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        speechController.isReadyForLiveTranscription
                            ? (
                                speechController.isMicrophoneMuted
                                    ? Color(red: 0.73, green: 0.34, blue: 0.21)
                                    : Color(red: 0.95, green: 0.89, blue: 0.84)
                            )
                            : Color(red: 0.95, green: 0.89, blue: 0.84)
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Text(liveTranscriptText)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(speechController.isCapturingSpeech ? Color.primary : Color.black.opacity(0.48))
                .frame(maxWidth: .infinity, alignment: .leading)

            if let pendingText = pendingUtteranceCoordinator.pendingUtterance?.text {
                Text("Queued next turn: \(pendingText)")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Color(red: 0.55, green: 0.33, blue: 0.17))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.white.opacity(0.82))
    }

    private var liveTranscriptText: String {
        if !speechController.isReadyForLiveTranscription {
            return speechController.statusMessage
        }

        if speechController.isMicrophoneMuted {
            return agentController.isAwaitingAssistantResponse
                ? "Transcription is paused. Assistant playback will continue without spoken interruptions."
                : "Transcription is paused. Resume when you want to transcribe WebRTC audio again."
        }

        let transcript = speechController.displayedLiveTranscript
        if !transcript.isEmpty {
            return transcript
        }

        return agentController.isAwaitingAssistantResponse
            ? "Incoming WebRTC audio will interrupt playback."
            : "Stream incoming WebRTC audio to transcribe."
    }

    private var chatBackground: some View {
        ZStack {
            Color(red: 0.97, green: 0.96, blue: 0.94)

            LinearGradient(
                colors: [
                    Color.white.opacity(0.55),
                    Color(red: 0.90, green: 0.93, blue: 0.89).opacity(0.2)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var chatScrollState: ChatScrollState {
        ChatScrollState(
            lastMessageID: agentController.messages.last?.id,
            lastMessageLength: agentController.messages.last?.text.count ?? 0,
            transcript: speechController.displayedLiveTranscript
        )
    }

    private var microphoneStatusLabel: String {
        if speechController.isMicrophoneMuted {
            return "Transcription paused"
        }

        return speechController.isCapturingSpeech ? "Transcribing speech..." : "Transcription ready"
    }

    private var microphoneStatusIcon: String {
        if speechController.isMicrophoneMuted {
            return "pause.fill"
        }

        return speechController.isCapturingSpeech ? "waveform.badge.mic" : "waveform"
    }

    private var microphoneStatusColor: Color {
        if speechController.isMicrophoneMuted {
            return Color(red: 0.71, green: 0.32, blue: 0.20)
        }

        return Color(red: 0.16, green: 0.20, blue: 0.17)
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
    }

    private func connectUsingSelectedRuntime() async {
        if runtimeController.isManagedMode {
            guard runtimeController.isManagedRuntimeConfigured else {
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

    private func scrollToBottom(with proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        }
    }

    private func saveSettings() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        runtimeController.saveSettings()
        agentController.saveSettings()
    }
}

private struct ChatScrollState: Equatable {
    let lastMessageID: UUID?
    let lastMessageLength: Int
    let transcript: String
}

private struct ChatBubbleRow: View {
    let message: ChatMessage
    @ObservedObject var speechController: SpeechController

    var body: some View {
        switch message.role {
        case .system:
            Text(message.text)
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(message.state == .error ? Color(red: 0.70, green: 0.28, blue: 0.23) : Color.black.opacity(0.55))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.white.opacity(0.7))
                .clipShape(Capsule())
                .frame(maxWidth: .infinity)
        case .user, .assistant:
            HStack {
                if message.role == .assistant {
                    bubble
                    Spacer(minLength: 56)
                } else {
                    Spacer(minLength: 56)
                    bubble
                }
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(labelColor)

            Text(message.text.isEmpty && message.state == .streaming ? "..." : message.text)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)


        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(bubbleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .frame(maxWidth: 420, alignment: message.role == .assistant ? .leading : .trailing)
    }

    private var label: String {
        switch message.role {
        case .assistant:
            return message.state == .streaming ? "Agent is typing" : "Agent"
        case .user:
            return "You"
        case .system:
            return "System"
        }
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .assistant:
            return Color.white.opacity(0.94)
        case .user:
            return Color(red: 0.18, green: 0.52, blue: 0.42).opacity(message.state == .error ? 0.70 : 0.96)
        case .system:
            return .clear
        }
    }

    private var borderColor: Color {
        switch message.role {
        case .assistant:
            return message.state == .error ? Color(red: 0.75, green: 0.41, blue: 0.35) : Color.black.opacity(0.06)
        case .user:
            return Color.white.opacity(0.15)
        case .system:
            return .clear
        }
    }

    private var labelColor: Color {
        switch message.role {
        case .assistant:
            return message.state == .error ? Color(red: 0.71, green: 0.31, blue: 0.24) : Color.black.opacity(0.44)
        case .user:
            return Color.white.opacity(0.78)
        case .system:
            return Color.black.opacity(0.44)
        }
    }

    private var textColor: Color {
        message.role == .user ? .white : Color(red: 0.14, green: 0.16, blue: 0.15)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.1fs", duration)
    }
}

private struct SettingsView: View {
    @ObservedObject var speechController: SpeechController
    @ObservedObject var agentController: AgentConnectionController
    @ObservedObject var runtimeController: LocalRuntimeController
    @Binding var autoSpeakAgentReplies: Bool
    let connectAction: () -> Void
    let startRuntimeAction: () -> Void
    let stopRuntimeAction: () -> Void
    let restartRuntimeAction: () -> Void
    let closeAction: () -> Void

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

            Form {
                Section("Runtime") {
                    Picker("Mode", selection: $runtimeController.runtimeMode) {
                        ForEach(RuntimeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    if runtimeController.isManagedMode {
                        TextField("Image", text: $runtimeController.managedContainerImage)
                        TextField("Container name", text: $runtimeController.managedContainerName)
                        TextField("Model name", text: $runtimeController.managedModelName)
                        SecureField("Google API key", text: $runtimeController.managedGoogleAPIKey)
                        Toggle("Use Vertex AI", isOn: $runtimeController.managedUseVertexAI)

                        if runtimeController.managedUseVertexAI {
                            TextField("Google Cloud project", text: $runtimeController.managedGoogleCloudProject)
                            TextField("Google Cloud location", text: $runtimeController.managedGoogleCloudLocation)
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
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
        .onDisappear {
            NSApp.keyWindow?.makeFirstResponder(nil)
            runtimeController.saveSettings()
            agentController.saveSettings()
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
}

#Preview {
    ContentView(authManager: AuthManager())
}
