//
//  OnboardingView.swift
//  glosos-macOS
//
//  Created by Antigravity on 6/24/26.
//

import SwiftUI
import Combine

struct OnboardingStep: Identifiable, Equatable {
    let id: Int
    let title: String
    var status: StepStatus
    var duration: TimeInterval?
    var detailText: String?

    enum StepStatus: Equatable {
        case pending
        case inProgress
        case completed
        case failed
    }
}

struct OnboardingView: View {
    @ObservedObject var runtimeController: LocalRuntimeController
    var onCompletion: () -> Void

    @State private var onboardingStage: OnboardingStage = .welcome
    @State private var steps: [OnboardingStep] = [
        OnboardingStep(id: 0, title: "Check system prerequisites", status: .pending),
        OnboardingStep(id: 1, title: "Download Linux kernel archive", status: .pending),
        OnboardingStep(id: 2, title: "Extract Linux kernel vmlinux", status: .pending),
        OnboardingStep(id: 3, title: "Start vmnet network interface", status: .pending),
        OnboardingStep(id: 4, title: "Fetch container initialization image (vminit)", status: .pending),
        OnboardingStep(id: 5, title: "Prepare init filesystem", status: .pending),
        OnboardingStep(id: 6, title: "Fetch Glosos runtime image", status: .pending),
        OnboardingStep(id: 7, title: "Create container runtime filesystem", status: .pending),
        OnboardingStep(id: 8, title: "Start local Glosos container", status: .pending),
        OnboardingStep(id: 9, title: "Verify container endpoint health", status: .pending)
    ]

    @State private var activeStepIndex = 0
    @State private var stepStartTime: Date? = nil
    @State private var timer: AnyCancellable? = nil
    @State private var showDetails = false
    @State private var logLines: [String] = []


    enum OnboardingStage {
        case welcome
        case installing
        case completed
    }

    var body: some View {
        ZStack {
            // Elegant background gradient matching the chat theme
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.95, blue: 0.92),
                    Color(red: 0.93, green: 0.94, blue: 0.91)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                switch onboardingStage {
                case .welcome:
                    welcomeView
                case .installing:
                    installingView
                case .completed:
                    completedView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 620)
    }

    // MARK: - Welcome View
    private var welcomeView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Text("Welcome to Glosos")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.14, green: 0.19, blue: 0.16))

                Text("Let's configure Google Gemini and set up your secure runtime.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.5))
            }

            VStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Google API Key")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color(red: 0.14, green: 0.19, blue: 0.16))

                    SecureField("AIzaSy...", text: $runtimeController.managedGoogleAPIKey)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
                        )
                        .font(.system(.body, design: .monospaced))

                    HStack(spacing: 4) {
                        Text("Don't have an API key?")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(.secondary)
                        Link("Get one for free at Google AI Studio", destination: URL(string: "https://aistudio.google.com/")!)
                            .font(.system(.footnote, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color(red: 0.18, green: 0.52, blue: 0.42))
                    }
                }
            }
            .padding(24)
            .background(.white.opacity(0.82))
            .cornerRadius(24)
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(.white.opacity(0.5), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.03), radius: 15, x: 0, y: 10)
            .frame(maxWidth: 460)

            Button {
                startOnboardingSetup()
            } label: {
                Text("Start Setup")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 48)
                    .padding(.vertical, 12)
                    .background(isGoogleKeyValid ? Color(red: 0.18, green: 0.52, blue: 0.42) : Color.gray.opacity(0.4))
                    .foregroundStyle(.white)
                    .cornerRadius(12)
                    .shadow(color: isGoogleKeyValid ? Color(red: 0.18, green: 0.52, blue: 0.42).opacity(0.2) : Color.clear, radius: 6, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(!isGoogleKeyValid)

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Installing View
    private var installingView: some View {
        VStack(spacing: 0) {
            // Header Progress Bar Section
            VStack(spacing: 12) {
                HStack {
                    Text(currentProgressStepTitle)
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(Color(red: 0.14, green: 0.19, blue: 0.16))

                    Spacer()

                    Text("\(activeStepIndex + 1) of \(steps.count) steps")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                // Custom Animated Progress Bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.black.opacity(0.06))
                            .frame(height: 6)

                        Capsule()
                            .fill(Color(red: 0.18, green: 0.52, blue: 0.42))
                            .frame(width: geo.size.width * CGFloat(activeStepIndex + 1) / CGFloat(steps.count), height: 6)
                            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: activeStepIndex)
                    }
                }
                .frame(height: 6)
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()
                .overlay(Color.black.opacity(0.06))

            // Steps ScrollList
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(steps) { step in
                        stepRow(step: step)

                        if step.id < steps.count - 1 {
                            Divider()
                                .padding(.leading, 52)
                                .overlay(Color.black.opacity(0.03))
                        }
                    }
                }
                .background(.white.opacity(0.7))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.black.opacity(0.04), lineWidth: 1)
                )
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
            }
            .frame(maxHeight: .infinity)

            // Log Console Drawer
            if showDetails {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()

                    HStack {
                        Text("Installation Details")
                            .font(.system(.footnote, design: .rounded).weight(.bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.02))

                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(logLines.indices, id: \.self) { idx in
                                    Text(logLines[idx])
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Color.black.opacity(0.7))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(idx)
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                        }
                        .background(Color.black.opacity(0.04))
                        .onChange(of: logLines.count) { _, _ in
                            if let lastIndex = logLines.indices.last {
                                withAnimation {
                                    proxy.scrollTo(lastIndex, anchor: .bottom)
                                }
                            }
                        }
                    }
                    .frame(height: 140)
                }
                .transition(.move(edge: .bottom))
            }

            Divider()
                .overlay(Color.black.opacity(0.06))

            // Bottom controls
            HStack {
                Button {
                    withAnimation {
                        showDetails.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Show details")
                        Image(systemName: "chevron.right")
                            .rotationEffect(showDetails ? .degrees(90) : .degrees(0))
                    }
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    cancelSetup()
                } label: {
                    Text("Cancel")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.06))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color.white.opacity(0.4))
        }
        .onChange(of: runtimeController.runtimeStatusDetail) { _, newDetail in
            processStatusDetail(newDetail)
        }
        .onChange(of: runtimeController.runtimeState) { _, newState in
            if newState == .running {
                completeOnboarding()
            } else if newState == .failed {
                failActiveStep(runtimeController.lastRuntimeError ?? "Verification failed.")
            }
        }
    }

    // MARK: - Completed View
    private var completedView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(Color(red: 0.18, green: 0.52, blue: 0.42))

            VStack(spacing: 8) {
                Text("Setup Complete!")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.14, green: 0.19, blue: 0.16))

                Text("Your Glosos agent container is running and healthy.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.5))
            }

            Button {
                onCompletion()
            } label: {
                Text("Launch Glosos")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 48)
                    .padding(.vertical, 12)
                    .background(Color(red: 0.18, green: 0.52, blue: 0.42))
                    .foregroundStyle(.white)
                    .cornerRadius(12)
                    .shadow(color: Color(red: 0.18, green: 0.52, blue: 0.42).opacity(0.2), radius: 6, x: 0, y: 3)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Row Builder
    private func stepRow(step: OnboardingStep) -> some View {
        HStack(spacing: 16) {
            Group {
                switch step.status {
                case .pending:
                    Circle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .fill(Color.white)
                                .frame(width: 8, height: 8)
                        )
                case .inProgress:
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 20, height: 20)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(red: 0.18, green: 0.52, blue: 0.42))
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.red)
                }
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(step.status == .pending ? Color.primary.opacity(0.4) : Color.primary)
                    .fontWeight(step.status == .inProgress ? .semibold : .regular)

                if let detailText = step.detailText {
                    Text(detailText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let duration = step.duration {
                Text(formattedDuration(duration))
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.8))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    // MARK: - State Logic

    private var isGoogleKeyValid: Bool {
        !runtimeController.managedGoogleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var currentProgressStepTitle: String {
        guard activeStepIndex < steps.count else { return "" }
        return steps[activeStepIndex].title
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        if interval < 0.1 {
            return String(format: "%.0fms", interval * 1000)
        } else {
            return String(format: "%.1fs", interval)
        }
    }

    private func startOnboardingSetup() {
        // Save the chosen model configurations
        runtimeController.managedModelName = "gemini-3.1-flash-lite"
        runtimeController.managedModelProvider = .gemini
        runtimeController.runtimeMode = .managedAppleContainer
        runtimeController.saveSettings()

        // Reset step state
        for i in 0..<steps.count {
            steps[i].status = .pending
            steps[i].duration = nil
            steps[i].detailText = nil
        }
        activeStepIndex = 0
        steps[0].status = .inProgress
        stepStartTime = Date()
        logLines = ["Starting setup sequence..."]

        withAnimation {
            onboardingStage = .installing
        }

        // Start checking prerequisites immediately
        checkPrerequisitesAndStart()
    }

    private func checkPrerequisitesAndStart() {
        appendLog("Checking system prerequisites...")
        
        let checker = ContainerizationSupportChecker()
        let support = checker.currentSupportStatus()
        
        // Measure first step
        let duration = Date().timeIntervalSince(stepStartTime ?? Date())
        steps[0].duration = duration
        
        switch support {
        case .supported:
            steps[0].status = .completed
            appendLog("System prerequisites check: supported.")
            
            // Move to step 1 (kernel download)
            activeStepIndex = 1
            steps[1].status = .inProgress
            stepStartTime = Date()
            
            // Trigger start in controller
            Task {
                _ = await runtimeController.startRuntime()
            }
        case .unsupported(let message):
            steps[0].status = .failed
            steps[0].detailText = message
            appendLog("System check failed: \(message)")
            Task {
                await runtimeController.stopRuntime()
            }
        }
    }

    private func processStatusDetail(_ status: String) {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Append status update to details logs if it has changed
        if logLines.isEmpty || logLines.last != trimmed {
            appendLog(trimmed)
        }

        guard let targetIndex = parseStatusToStepIndex(trimmed) else {
            // Update detail text for progress updates (e.g. download percentages)
            if activeStepIndex < steps.count {
                if trimmed.contains("%") || trimmed.contains("of") {
                    steps[activeStepIndex].detailText = trimmed
                }
            }
            return
        }

        if targetIndex > activeStepIndex && targetIndex < steps.count {
            let now = Date()
            let duration = now.timeIntervalSince(stepStartTime ?? now)

            // Complete the current step
            steps[activeStepIndex].status = .completed
            steps[activeStepIndex].duration = duration
            steps[activeStepIndex].detailText = nil

            // Auto-complete any intermediate skipped (cached) steps
            for idx in (activeStepIndex + 1)..<targetIndex {
                steps[idx].status = .completed
                steps[idx].duration = 0.02 // represent very short cached time
                steps[idx].detailText = "Cached"
            }

            // Start the next target step
            activeStepIndex = targetIndex
            steps[targetIndex].status = .inProgress
            steps[targetIndex].detailText = nil
            stepStartTime = now
        }
    }

    private func failActiveStep(_ errorMessage: String) {
        if activeStepIndex < steps.count {
            steps[activeStepIndex].status = .failed
            steps[activeStepIndex].detailText = errorMessage
            appendLog("Error: \(errorMessage)")
        }
    }

    private func completeOnboarding() {
        let now = Date()
        // Complete verify health
        if activeStepIndex == 9 {
            steps[9].status = .completed
            steps[9].duration = now.timeIntervalSince(stepStartTime ?? now)
            steps[9].detailText = nil
        } else {
            // Auto complete remaining steps if container just ran successfully
            for idx in activeStepIndex..<steps.count {
                steps[idx].status = .completed
                steps[idx].duration = 0.05
            }
        }
        activeStepIndex = steps.count - 1
        appendLog("Onboarding setup sequence completed successfully.")
        
        withAnimation {
            onboardingStage = .completed
        }
    }

    private func cancelSetup() {
        Task {
            await runtimeController.stopRuntime()
        }
        withAnimation {
            onboardingStage = .welcome
        }
    }

    private func appendLog(_ message: String) {
        logLines.append(message)
    }

    private func parseStatusToStepIndex(_ status: String) -> Int? {
        if status.contains("Preparing app support storage") { return 1 }
        if status.contains("Downloading Linux kernel") { return 1 }
        if status.contains("Extracting Linux kernel") { return 2 }
        if status.contains("Starting vmnet network") { return 3 }
        if status.contains("Pulling init image") || status.contains("Using cached init image") { return 4 }
        if status.contains("Preparing init filesystem") || status.contains("Using cached init filesystem") { return 5 }
        if status.contains("Pulling runtime image") || status.contains("Using cached runtime image") { return 6 }
        if status.contains("Creating runtime filesystem") || status.contains("Using cached runtime filesystem") { return 7 }
        if status.contains("Starting container") { return 8 }
        if status.contains("Waiting for runtime endpoint") || status.contains("health") { return 9 }
        return nil
    }
}
