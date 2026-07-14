//
//  LocalRuntimeController.swift
//  glosos-macOS
//
//  Created by EV on 6/5/26.
//

import Combine
import Foundation

enum RuntimeMode: String, CaseIterable, Identifiable, Sendable {
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

enum ModelProvider: String, CaseIterable, Identifiable, Sendable {
    case gemini
    case localOpenAI
    case cerebras

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemini:
            return "Google Gemini"
        case .localOpenAI:
            return "Local LLM (OpenAI SDK / Ollama)"
        case .cerebras:
            return "Cerebras Inference"
        }
    }
}

enum RuntimeState: Equatable, Sendable {
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

struct ManagedContainerConfiguration: Equatable, Sendable {
    static let servicePort: UInt16 = 8000

    let image: String
    let containerName: String
    let containerPort: UInt16
    let modelName: String
    let modelProvider: ModelProvider
    let googleAPIKey: String?
    let localLLMApiBase: String?
    let localLLMApiKey: String?
    let cerebrasAPIKey: String?

    nonisolated var environmentVariables: [String] {
        var variables = [
            "MODEL_NAME=\(modelName)",
            "PORT=\(containerPort)",
        ]

        switch modelProvider {
        case .gemini:
            variables.append("GOOGLE_GENAI_USE_VERTEXAI=false")
            let key = (googleAPIKey == nil || googleAPIKey!.isEmpty) ? "placeholder_key" : googleAPIKey!
            variables.append("GOOGLE_API_KEY=\(key)")
        case .localOpenAI:
            if let localLLMApiBase {
                variables.append("OPENAI_BASE_URL=\(localLLMApiBase)")
                variables.append("OPENAI_API_BASE=\(localLLMApiBase)")
            }
            if let localLLMApiKey {
                variables.append("OPENAI_API_KEY=\(localLLMApiKey)")
            }
        case .cerebras:
            let key = (cerebrasAPIKey == nil || cerebrasAPIKey!.isEmpty) ? "placeholder_key" : cerebrasAPIKey!
            variables.append("CEREBRAS_API_KEY=\(key)")
        }

        return variables
    }
}

protocol LocalRuntimeHealthChecking: Sendable {
    func waitUntilHealthy(endpoint: ManagedRuntimeEndpoint, timeoutSeconds: TimeInterval) async -> Bool
}

final class HealthEndpointChecker: LocalRuntimeHealthChecking, Sendable {
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

    @Published var managedModelProvider: ModelProvider {
        didSet {
            userDefaults.set(managedModelProvider.rawValue, forKey: Self.managedModelProviderKey)
        }
    }

    @Published var managedLocalLLMApiBase: String {
        didSet {
            userDefaults.set(managedLocalLLMApiBase, forKey: Self.managedLocalLLMApiBaseKey)
        }
    }

    @Published var managedLocalLLMApiKey: String {
        didSet {
            userDefaults.set(managedLocalLLMApiKey, forKey: Self.managedLocalLLMApiKeyKey)
        }
    }

    @Published var managedCerebrasAPIKey: String {
        didSet {
            userDefaults.set(managedCerebrasAPIKey, forKey: Self.managedCerebrasAPIKeyKey)
        }
    }

    @Published var customUserFolderPath: String {
        didSet {
            userDefaults.set(customUserFolderPath, forKey: Self.customUserFolderPathKey)
        }
    }

    @Published private(set) var runtimeState: RuntimeState = .stopped
    @Published private(set) var runtimeStatusDetail = "Stopped"
    @Published private(set) var lastRuntimeError: String?
    @Published private(set) var recentLogs = ""
    @Published private(set) var currentManagedEndpoint: ManagedRuntimeEndpoint?
    @Published private(set) var detectedContainerVersion: String?

    private let userDefaults: UserDefaults
    private let assetManager: ContainerAssetManaging
    private let runtimeManager: ContainerRuntimeManaging
    private let healthChecker: LocalRuntimeHealthChecking

    private static let runtimeModeKey = "runtimeMode"
    private static let managedContainerImageKey = "managedContainerImage"
    private static let managedContainerNameKey = "managedContainerName"
    private static let managedModelNameKey = "managedModelName"
    private static let managedGoogleAPIKeyKey = "managedGoogleAPIKey"
    private static let managedModelProviderKey = "managedModelProvider"
    private static let managedLocalLLMApiBaseKey = "managedLocalLLMApiBase"
    private static let managedLocalLLMApiKeyKey = "managedLocalLLMApiKey"
    private static let managedCerebrasAPIKeyKey = "managedCerebrasAPIKey"
    private static let customUserFolderPathKey = "customUserFolderPath"
    private static let agentEndpointURLKey = "agentEndpointURL"
    private static let legacyManualRuntimeMode = "manualWebSocket"
    private static let defaultManualEndpointURL = AgentEndpoint.defaultLocalBaseURLString
    private static let runtimeHealthTimeoutSeconds: TimeInterval = 20

    init(
        userDefaults: UserDefaults = .standard,
        assetManager: ContainerAssetManaging = ApplicationSupportContainerAssetManager(),
        runtimeManager: ContainerRuntimeManaging = ContainerizationRuntimeEngine(),
        healthChecker: LocalRuntimeHealthChecking = HealthEndpointChecker()
    ) {
        self.userDefaults = userDefaults
        self.assetManager = assetManager
        self.runtimeManager = runtimeManager
        self.healthChecker = healthChecker
        if let savedMode = userDefaults.string(forKey: Self.runtimeModeKey),
           let mode = RuntimeMode(rawValue: savedMode) {
            self.runtimeMode = mode
        } else if userDefaults.string(forKey: "agentSocketURL") != nil {
            self.runtimeMode = .manualEndpoint
        } else {
            self.runtimeMode = .managedAppleContainer
        }


        self.managedContainerImage = userDefaults.string(forKey: Self.managedContainerImageKey)
            ?? "docker.io/evbasistyi/glosos-google-user:latest"
        self.managedContainerName = userDefaults.string(forKey: Self.managedContainerNameKey)
            ?? "glosos-google-user-macos"
        self.managedModelName = userDefaults.string(forKey: Self.managedModelNameKey)
            ?? ProcessInfo.processInfo.environment["MODEL_NAME"]
            ?? "gemini-2.5-flash"
        self.managedGoogleAPIKey = userDefaults.string(forKey: Self.managedGoogleAPIKeyKey)
            ?? ProcessInfo.processInfo.environment["GOOGLE_API_KEY"]
            ?? ""
        
        if let savedProvider = userDefaults.string(forKey: Self.managedModelProviderKey),
           let provider = ModelProvider(rawValue: savedProvider) {
            self.managedModelProvider = provider
        } else {
            self.managedModelProvider = .gemini
        }

        self.managedLocalLLMApiBase = userDefaults.string(forKey: Self.managedLocalLLMApiBaseKey)
            ?? "http://192.168.64.1:11434/v1"
        self.managedLocalLLMApiKey = userDefaults.string(forKey: Self.managedLocalLLMApiKeyKey)
            ?? "local"
        self.managedCerebrasAPIKey = userDefaults.string(forKey: Self.managedCerebrasAPIKeyKey)
            ?? ProcessInfo.processInfo.environment["CEREBRAS_API_KEY"]
            ?? ""
        self.customUserFolderPath = userDefaults.string(forKey: Self.customUserFolderPathKey) ?? ""
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

    var managedUserFolderURL: URL {
        if !customUserFolderPath.isEmpty {
            return URL(filePath: customUserFolderPath)
        }
        if let assets = try? assetManager.existingAssets() {
            return assets.userWorkspaceURL
        }

        return ApplicationSupportContainerAssetManager.defaultUserWorkspaceURL()
    }

    var managedUserFolderPath: String {
        managedUserFolderURL.path(percentEncoded: false)
    }

    func saveSettings() {
        userDefaults.set(runtimeMode.rawValue, forKey: Self.runtimeModeKey)
        userDefaults.set(managedContainerImage, forKey: Self.managedContainerImageKey)
        userDefaults.set(managedContainerName, forKey: Self.managedContainerNameKey)
        userDefaults.set(managedModelName, forKey: Self.managedModelNameKey)
        userDefaults.set(managedGoogleAPIKey, forKey: Self.managedGoogleAPIKeyKey)
        userDefaults.set(managedModelProvider.rawValue, forKey: Self.managedModelProviderKey)
        userDefaults.set(managedLocalLLMApiBase, forKey: Self.managedLocalLLMApiBaseKey)
        userDefaults.set(managedLocalLLMApiKey, forKey: Self.managedLocalLLMApiKeyKey)
        userDefaults.set(managedCerebrasAPIKey, forKey: Self.managedCerebrasAPIKeyKey)
        userDefaults.set(customUserFolderPath, forKey: Self.customUserFolderPathKey)
    }

    func refreshStatus() async {
        lastRuntimeError = nil
        recentLogs = ""

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
        detectedContainerVersion = nil


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
            
            // Query version from healthz endpoint
            Task { [weak self] in
                if let version = await self?.fetchContainerVersion(from: endpoint) {
                    await MainActor.run {
                        self?.detectedContainerVersion = version
                    }
                }
            }
            
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
        detectedContainerVersion = nil
    }

    func deleteImageCache() async -> Bool {
        let image = managedContainerImage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !image.isEmpty else { return false }
        
        do {
            let assets: ContainerRuntimeAssets
            if let existing = try await assetManager.existingAssets() {
                assets = existing
            } else {
                assets = try await assetManager.prepareAssets(updateStatus: { _ in })
            }
            
            try await runtimeManager.deleteImage(reference: image, assets: assets)
            await MainActor.run {
                self.runtimeStatusDetail = "Image cache deleted. Next start will pull."
            }
            return true
        } catch {
            await MainActor.run {
                self.runtimeStatusDetail = "Failed to delete cache: \(error.localizedDescription)"
            }
            return false
        }
    }

    func restartRuntime() async -> Bool {
        await stopRuntime()
        return await startRuntime()
    }

    var resolvedConfiguration: ManagedContainerConfiguration? {
        let image = managedContainerImage.trimmingCharacters(in: .whitespacesAndNewlines)
        let containerName = managedContainerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = managedModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let googleAPIKey = managedGoogleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let localLLMApiBase = managedLocalLLMApiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let localLLMApiKey = managedLocalLLMApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cerebrasAPIKey = managedCerebrasAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !image.isEmpty,
              !containerName.isEmpty,
              !modelName.isEmpty else {
            return nil
        }

        switch managedModelProvider {
        case .gemini:
            guard !googleAPIKey.isEmpty else { return nil }
        case .localOpenAI:
            guard !localLLMApiBase.isEmpty else { return nil }
        case .cerebras:
            guard !cerebrasAPIKey.isEmpty else { return nil }
        }

        return ManagedContainerConfiguration(
            image: image,
            containerName: containerName,
            containerPort: ManagedContainerConfiguration.servicePort,
            modelName: modelName,
            modelProvider: managedModelProvider,
            googleAPIKey: googleAPIKey.isEmpty ? nil : googleAPIKey,
            localLLMApiBase: localLLMApiBase.isEmpty ? nil : localLLMApiBase,
            localLLMApiKey: localLLMApiKey.isEmpty ? nil : localLLMApiKey,
            cerebrasAPIKey: cerebrasAPIKey.isEmpty ? nil : cerebrasAPIKey
        )
    }

    private var invalidConfigurationMessage: String {
        switch managedModelProvider {
        case .gemini:
            return "Enter a valid image, container name, and model name for the managed runtime."
        case .localOpenAI:
            return "Enter a valid image, container name, model name, and Local API Base URL for the managed runtime."
        case .cerebras:
            return "Enter a valid image, container name, and model name for the managed runtime."
        }
    }

    private var managedRuntimeSetupMessage: String {
        switch managedModelProvider {
        case .gemini:
            return "Managed runtime is waiting for a Google API key."
        case .localOpenAI:
            return "Managed runtime is waiting for Local API Base URL."
        case .cerebras:
            return "Managed runtime is waiting for a Cerebras API key."
        }
    }

    private static func savedManualEndpointString(in userDefaults: UserDefaults) -> String? {
        if let savedEndpoint = userDefaults.string(forKey: agentEndpointURLKey),
           let normalized = AgentEndpoint.normalizedString(from: savedEndpoint) {
            return normalized
        }

        return nil
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
            print("[LocalRuntimeController] Attempting start with cached filesystem...")
            return try await startManagedRuntime(
                configuration: configuration,
                assets: assets,
                reuseCachedFilesystem: true,
                updateStatus: updateStatus
            )
        } catch {
            print("[LocalRuntimeController] Cached runtime filesystem start failed with error: \(error.localizedDescription)")
            print("[LocalRuntimeController] Initiating recovery... Stopping current VM.")
            await runtimeManager.stop(containerName: configuration.containerName, assets: assets)
            await updateStatus("Cached runtime filesystem failed. Rebuilding...")
            print("[LocalRuntimeController] Rebuilding container filesystem from scratch (reuseCachedFilesystem: false)...")
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
        print("[LocalRuntimeController] Starting managed runtime (reuseCachedFilesystem: \(reuseCachedFilesystem))...")
        let endpoint = try await runtimeManager.start(
            configuration: configuration,
            assets: assets,
            reuseCachedFilesystem: reuseCachedFilesystem,
            updateStatus: updateStatus
        )

        print("[LocalRuntimeController] Container runtime manager started at \(endpoint.displayString). Waiting for health check...")
        runtimeStatusDetail = "Waiting for runtime endpoint..."
        let isHealthy = await healthChecker.waitUntilHealthy(
            endpoint: endpoint,
            timeoutSeconds: Self.runtimeHealthTimeoutSeconds
        )

        guard isHealthy else {
            print("[LocalRuntimeController] Health check failed for endpoint \(endpoint.displayString).")
            print("[LocalRuntimeController] Stopping container...")
            await runtimeManager.stop(containerName: configuration.containerName, assets: assets)
            print("[LocalRuntimeController] Fetching recent logs...")
            let logs = await assetManager.recentLogs(
                containerName: configuration.containerName,
                assets: assets
            )
            recentLogs = logs
            print("[LocalRuntimeController] Recent container logs (bootlog/stdout/stderr):\n\(logs)")
            let errorMsg = reuseCachedFilesystem
                ? "Cached runtime filesystem produced an unhealthy runtime endpoint."
                : "Container started, but the runtime endpoint never became ready."
            throw RuntimePreparationError.failed(errorMsg)
        }

        print("[LocalRuntimeController] Managed runtime is healthy at \(endpoint.displayString).")
        return endpoint
    }

    private static func environmentBoolean(named name: String) -> Bool {
        guard let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }

        return ["1", "true", "yes", "on"].contains(value)
    }

    private func fetchContainerVersion(from endpoint: ManagedRuntimeEndpoint) async -> String? {
        var request = URLRequest(url: endpoint.agentEndpoint.healthURL)
        request.timeoutInterval = 2
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }
            
            struct HealthResponse: Codable {
                let status: String?
                let version: String?
            }
            
            let health = try JSONDecoder().decode(HealthResponse.self, from: data)
            return health.version
        } catch {
            return nil
        }
    }
}
