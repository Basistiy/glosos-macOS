//
//  LocalRuntimeController.swift
//  glosos-macOS
//
//  Created by Codex on 6/5/26.
//

import Combine
import Foundation

enum RuntimeMode: String, CaseIterable, Identifiable {
    case managedAppleContainer
    case manualEndpoint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .managedAppleContainer:
            return "Managed Container"
        case .manualEndpoint:
            return "Manual Endpoint"
        }
    }
}

enum RuntimeState: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case unsupported
    case failed

    var isBusy: Bool {
        switch self {
        case .starting, .stopping:
            return true
        case .stopped, .running, .unsupported, .failed:
            return false
        }
    }
}

struct ManagedContainerConfiguration: Equatable {
    static let servicePort: UInt16 = 8000

    let image: String
    let containerName: String
    let containerPort: UInt16
    let modelName: String
    let googleAPIKey: String?
    let googleGenAIUseVertexAI: Bool
    let googleCloudProject: String?
    let googleCloudLocation: String?

    nonisolated var environmentVariables: [String] {
        var variables = [
            "MODEL_NAME=\(modelName)",
            "PORT=\(containerPort)",
        ]

        if googleGenAIUseVertexAI {
            variables.append("GOOGLE_GENAI_USE_VERTEXAI=true")
            if let googleCloudProject {
                variables.append("GOOGLE_CLOUD_PROJECT=\(googleCloudProject)")
            }
            if let googleCloudLocation {
                variables.append("GOOGLE_CLOUD_LOCATION=\(googleCloudLocation)")
            }
        } else {
            variables.append("GOOGLE_GENAI_USE_VERTEXAI=false")
            if let googleAPIKey {
                variables.append("GOOGLE_API_KEY=\(googleAPIKey)")
            }
        }

        return variables
    }
}

protocol LocalRuntimeHealthChecking {
    func waitUntilHealthy(endpoint: ManagedRuntimeEndpoint, timeoutSeconds: TimeInterval) async -> Bool
}

final class HealthEndpointChecker: LocalRuntimeHealthChecking {
    func waitUntilHealthy(endpoint: ManagedRuntimeEndpoint, timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while Date() < deadline {
            if await isHealthy(endpoint: endpoint) {
                return true
            }

            try? await Task.sleep(for: .milliseconds(300))
        }

        return false
    }

    private func isHealthy(endpoint: ManagedRuntimeEndpoint) async -> Bool {
        var request = URLRequest(url: endpoint.agentEndpoint.healthURL)
        request.timeoutInterval = 2

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }

            return (200..<300).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }
}

@MainActor
final class LocalRuntimeController: ObservableObject {
    @Published var runtimeMode: RuntimeMode {
        didSet {
            userDefaults.set(runtimeMode.rawValue, forKey: Self.runtimeModeKey)
        }
    }

    @Published var managedContainerImage: String {
        didSet {
            userDefaults.set(managedContainerImage, forKey: Self.managedContainerImageKey)
        }
    }

    @Published var managedContainerName: String {
        didSet {
            userDefaults.set(managedContainerName, forKey: Self.managedContainerNameKey)
        }
    }

    @Published var managedModelName: String {
        didSet {
            userDefaults.set(managedModelName, forKey: Self.managedModelNameKey)
        }
    }

    @Published var managedGoogleAPIKey: String {
        didSet {
            userDefaults.set(managedGoogleAPIKey, forKey: Self.managedGoogleAPIKeyKey)
        }
    }

    @Published var managedUseVertexAI: Bool {
        didSet {
            userDefaults.set(managedUseVertexAI, forKey: Self.managedUseVertexAIKey)
        }
    }

    @Published var managedGoogleCloudProject: String {
        didSet {
            userDefaults.set(managedGoogleCloudProject, forKey: Self.managedGoogleCloudProjectKey)
        }
    }

    @Published var managedGoogleCloudLocation: String {
        didSet {
            userDefaults.set(managedGoogleCloudLocation, forKey: Self.managedGoogleCloudLocationKey)
        }
    }

    @Published private(set) var runtimeState: RuntimeState = .stopped
    @Published private(set) var runtimeStatusDetail = "Stopped"
    @Published private(set) var lastRuntimeError: String?
    @Published private(set) var recentLogs = ""
    @Published private(set) var currentManagedEndpoint: ManagedRuntimeEndpoint?

    private let userDefaults: UserDefaults
    private let supportChecker: ContainerizationSupportChecking
    private let assetManager: ContainerAssetManaging
    private let runtimeManager: ContainerRuntimeManaging
    private let healthChecker: LocalRuntimeHealthChecking

    private static let runtimeModeKey = "runtimeMode"
    private static let managedContainerImageKey = "managedContainerImage"
    private static let managedContainerNameKey = "managedContainerName"
    private static let managedModelNameKey = "managedModelName"
    private static let managedGoogleAPIKeyKey = "managedGoogleAPIKey"
    private static let managedUseVertexAIKey = "managedUseVertexAI"
    private static let managedGoogleCloudProjectKey = "managedGoogleCloudProject"
    private static let managedGoogleCloudLocationKey = "managedGoogleCloudLocation"
    private static let agentEndpointURLKey = "agentEndpointURL"
    private static let legacyAgentSocketURLKey = "agentSocketURL"
    private static let legacyManualRuntimeMode = "manualWebSocket"
    private static let defaultManualEndpointURL = AgentEndpoint.defaultLocalBaseURLString
    private static let legacyDefaultManualSocketURL = "ws://127.0.0.1:18000/ws"
    private static let runtimeHealthTimeoutSeconds: TimeInterval = 20

    init(
        userDefaults: UserDefaults = .standard,
        supportChecker: ContainerizationSupportChecking = ContainerizationSupportChecker(),
        assetManager: ContainerAssetManaging = ApplicationSupportContainerAssetManager(),
        runtimeManager: ContainerRuntimeManaging = ContainerizationRuntimeEngine(),
        healthChecker: LocalRuntimeHealthChecking = HealthEndpointChecker()
    ) {
        self.userDefaults = userDefaults
        self.supportChecker = supportChecker
        self.assetManager = assetManager
        self.runtimeManager = runtimeManager
        self.healthChecker = healthChecker

        if let savedMode = userDefaults.string(forKey: Self.runtimeModeKey) {
            if savedMode == Self.legacyManualRuntimeMode {
                self.runtimeMode = .manualEndpoint
            } else if let runtimeMode = RuntimeMode(rawValue: savedMode) {
                self.runtimeMode = runtimeMode
            } else {
                self.runtimeMode = .managedAppleContainer
            }
        } else if let savedEndpoint = Self.savedManualEndpointString(in: userDefaults),
                  savedEndpoint != Self.defaultManualEndpointURL {
            self.runtimeMode = .manualEndpoint
        } else {
            self.runtimeMode = .managedAppleContainer
        }

        self.managedContainerImage = userDefaults.string(forKey: Self.managedContainerImageKey)
            ?? "ghcr.io/basistiy/glosos-google-user:latest"
        self.managedContainerName = userDefaults.string(forKey: Self.managedContainerNameKey)
            ?? "glosos-google-user-macos"
        self.managedModelName = userDefaults.string(forKey: Self.managedModelNameKey)
            ?? ProcessInfo.processInfo.environment["MODEL_NAME"]
            ?? "gemini-2.5-flash"
        self.managedGoogleAPIKey = userDefaults.string(forKey: Self.managedGoogleAPIKeyKey)
            ?? ProcessInfo.processInfo.environment["GOOGLE_API_KEY"]
            ?? ""
        self.managedUseVertexAI = if userDefaults.object(forKey: Self.managedUseVertexAIKey) != nil {
            userDefaults.bool(forKey: Self.managedUseVertexAIKey)
        } else {
            Self.environmentBoolean(named: "GOOGLE_GENAI_USE_VERTEXAI")
        }
        self.managedGoogleCloudProject = userDefaults.string(forKey: Self.managedGoogleCloudProjectKey)
            ?? ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"]
            ?? ""
        self.managedGoogleCloudLocation = userDefaults.string(forKey: Self.managedGoogleCloudLocationKey)
            ?? ProcessInfo.processInfo.environment["GOOGLE_CLOUD_LOCATION"]
            ?? ""
    }

    var computedEndpointURL: String {
        currentManagedEndpoint?.displayString ?? "Not ready"
    }

    var isManagedMode: Bool {
        runtimeMode == .managedAppleContainer
    }

    var isRuntimeActionDisabled: Bool {
        runtimeState.isBusy
    }

    var isManagedRuntimeConfigured: Bool {
        resolvedConfiguration != nil
    }

    func refreshStatus() async {
        lastRuntimeError = nil
        recentLogs = ""

        guard case .supported = supportChecker.currentSupportStatus() else {
            applyUnsupportedState()
            return
        }

        guard let configuration = resolvedConfiguration else {
            currentManagedEndpoint = nil
            runtimeState = .stopped
            runtimeStatusDetail = managedRuntimeSetupMessage
            return
        }

        guard let endpoint = await runtimeManager.currentEndpoint(containerName: configuration.containerName) else {
            currentManagedEndpoint = nil
            runtimeState = .stopped
            runtimeStatusDetail = "Managed container is not running."
            return
        }

        currentManagedEndpoint = endpoint
        let isHealthy = await healthChecker.waitUntilHealthy(endpoint: endpoint, timeoutSeconds: 2)
        if isHealthy {
            runtimeState = .running
            runtimeStatusDetail = "Running at \(endpoint.displayString)"
        } else {
            runtimeState = .failed
            runtimeStatusDetail = "Container endpoint is unavailable."
            recentLogs = await assetManager.recentLogs(
                containerName: configuration.containerName,
                assets: try? await assetManager.existingAssets()
            )
        }
    }

    func startRuntime() async -> Bool {
        lastRuntimeError = nil
        recentLogs = ""
        currentManagedEndpoint = nil

        guard case .supported = supportChecker.currentSupportStatus() else {
            applyUnsupportedState()
            return false
        }

        guard let configuration = resolvedConfiguration else {
            applyFailure(invalidConfigurationMessage)
            return false
        }

        runtimeState = .starting
        runtimeStatusDetail = "Preparing managed runtime..."

        do {
            let assets = try await assetManager.prepareAssets { [weak self] status in
                await MainActor.run {
                    self?.runtimeStatusDetail = status
                }
            }

            let updateStatus: @Sendable (String) async -> Void = { [weak self] status in
                await MainActor.run {
                    self?.runtimeStatusDetail = status
                }
            }
            let endpoint = try await startManagedRuntimeWithRecovery(
                configuration: configuration,
                assets: assets,
                updateStatus: updateStatus
            )
            currentManagedEndpoint = endpoint
            runtimeState = .running
            runtimeStatusDetail = "Running at \(endpoint.displayString)"
            return true
        } catch let error as RuntimePreparationError {
            switch error {
            case .unsupported(let message):
                runtimeState = .unsupported
                runtimeStatusDetail = message
                lastRuntimeError = message
            case .failed(let message):
                applyFailure(message)
            }
            return false
        } catch {
            applyFailure(error.localizedDescription)
            return false
        }
    }

    func stopRuntime() async {
        lastRuntimeError = nil

        guard case .supported = supportChecker.currentSupportStatus() else {
            applyUnsupportedState()
            return
        }

        let containerName = managedContainerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !containerName.isEmpty else {
            applyFailure("Enter a container name before stopping the managed runtime.")
            return
        }

        runtimeState = .stopping
        runtimeStatusDetail = "Stopping managed container..."

        let assets = try? await assetManager.existingAssets()
        await runtimeManager.stop(containerName: containerName, assets: assets)

        runtimeState = .stopped
        runtimeStatusDetail = "Managed container stopped."
        currentManagedEndpoint = nil
        recentLogs = ""
    }

    func restartRuntime() async -> Bool {
        await stopRuntime()
        return await startRuntime()
    }

    private var resolvedConfiguration: ManagedContainerConfiguration? {
        let image = managedContainerImage.trimmingCharacters(in: .whitespacesAndNewlines)
        let containerName = managedContainerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = managedModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let googleAPIKey = managedGoogleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let googleCloudProject = managedGoogleCloudProject.trimmingCharacters(in: .whitespacesAndNewlines)
        let googleCloudLocation = managedGoogleCloudLocation.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !image.isEmpty,
              !containerName.isEmpty,
              !modelName.isEmpty else {
            return nil
        }

        if managedUseVertexAI {
            guard !googleCloudProject.isEmpty, !googleCloudLocation.isEmpty else {
                return nil
            }
        } else if googleAPIKey.isEmpty {
            return nil
        }

        return ManagedContainerConfiguration(
            image: image,
            containerName: containerName,
            containerPort: ManagedContainerConfiguration.servicePort,
            modelName: modelName,
            googleAPIKey: googleAPIKey.isEmpty ? nil : googleAPIKey,
            googleGenAIUseVertexAI: managedUseVertexAI,
            googleCloudProject: googleCloudProject.isEmpty ? nil : googleCloudProject,
            googleCloudLocation: googleCloudLocation.isEmpty ? nil : googleCloudLocation
        )
    }

    private var invalidConfigurationMessage: String {
        if managedUseVertexAI {
            return "Enter a valid image, container name, model name, Google Cloud project, and Google Cloud location for the managed runtime."
        }

        return "Enter a valid image, container name, model name, and Google API key for the managed runtime."
    }

    private var managedRuntimeSetupMessage: String {
        if managedUseVertexAI {
            return "Managed runtime is waiting for Google Cloud project and location."
        }

        return "Managed runtime is waiting for a Google API key."
    }

    private static func savedManualEndpointString(in userDefaults: UserDefaults) -> String? {
        if let savedEndpoint = userDefaults.string(forKey: agentEndpointURLKey),
           let normalized = AgentEndpoint.normalizedString(from: savedEndpoint) {
            return normalized
        }

        if let legacySocketURL = userDefaults.string(forKey: legacyAgentSocketURLKey),
           legacySocketURL != legacyDefaultManualSocketURL,
           let normalized = AgentEndpoint.normalizedString(from: legacySocketURL) {
            return normalized
        }

        return nil
    }

    private func applyUnsupportedState() {
        if case .unsupported(let message) = supportChecker.currentSupportStatus() {
            runtimeState = .unsupported
            runtimeStatusDetail = message
            lastRuntimeError = message
            currentManagedEndpoint = nil
        }
    }

    private func applyFailure(_ message: String) {
        runtimeState = .failed
        runtimeStatusDetail = "Managed runtime failed."
        lastRuntimeError = message
        currentManagedEndpoint = nil
    }

    private func startManagedRuntimeWithRecovery(
        configuration: ManagedContainerConfiguration,
        assets: ContainerRuntimeAssets,
        updateStatus: @escaping @Sendable (String) async -> Void
    ) async throws -> ManagedRuntimeEndpoint {
        do {
            return try await startManagedRuntime(
                configuration: configuration,
                assets: assets,
                reuseCachedFilesystem: true,
                updateStatus: updateStatus
            )
        } catch {
            await runtimeManager.stop(containerName: configuration.containerName, assets: assets)
            await updateStatus("Cached runtime filesystem failed. Rebuilding...")
            return try await startManagedRuntime(
                configuration: configuration,
                assets: assets,
                reuseCachedFilesystem: false,
                updateStatus: updateStatus
            )
        }
    }

    private func startManagedRuntime(
        configuration: ManagedContainerConfiguration,
        assets: ContainerRuntimeAssets,
        reuseCachedFilesystem: Bool,
        updateStatus: @escaping @Sendable (String) async -> Void
    ) async throws -> ManagedRuntimeEndpoint {
        let endpoint = try await runtimeManager.start(
            configuration: configuration,
            assets: assets,
            reuseCachedFilesystem: reuseCachedFilesystem,
            updateStatus: updateStatus
        )

        runtimeStatusDetail = "Waiting for runtime endpoint..."
        let isHealthy = await healthChecker.waitUntilHealthy(
            endpoint: endpoint,
            timeoutSeconds: Self.runtimeHealthTimeoutSeconds
        )

        guard isHealthy else {
            await runtimeManager.stop(containerName: configuration.containerName, assets: assets)
            recentLogs = await assetManager.recentLogs(
                containerName: configuration.containerName,
                assets: assets
            )
            throw RuntimePreparationError.failed(
                reuseCachedFilesystem
                    ? "Cached runtime filesystem produced an unhealthy runtime endpoint."
                    : "Container started, but the runtime endpoint never became ready."
            )
        }

        return endpoint
    }

    private static func environmentBoolean(named name: String) -> Bool {
        guard let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }

        return ["1", "true", "yes", "on"].contains(value)
    }
}
