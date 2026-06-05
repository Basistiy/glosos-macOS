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
            return "Managed Apple Container"
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
    let image: String
    let containerName: String
    let hostPort: UInt16
    let containerPort: UInt16

    var endpoint: AgentEndpoint {
        AgentEndpoint(baseURL: URL(string: "http://127.0.0.1:\(hostPort)")!)
    }

    var endpointURL: String {
        endpoint.displayString
    }

    var publishArgument: String {
        "127.0.0.1:\(hostPort):\(containerPort)"
    }
}

struct CommandResult: Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

protocol CommandRunning {
    func run(executableURL: URL, arguments: [String]) async throws -> CommandResult
}

protocol AppleContainerSupportChecking {
    func currentSupportStatus() -> AppleContainerSupportStatus
}

enum AppleContainerSupportStatus: Equatable {
    case supported(executableURL: URL)
    case unsupported(message: String)
}

protocol LocalRuntimeHealthChecking {
    func waitUntilHealthy(baseURL: URL, timeoutSeconds: TimeInterval) async -> Bool
}

final class ProcessCommandRunner: CommandRunning {
    func run(executableURL: URL, arguments: [String]) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { process in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let result = CommandResult(
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrData, as: UTF8.self)
                )
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

struct AppleContainerSupportChecker: AppleContainerSupportChecking {
    private let fileManager: FileManager
    private let processInfo: ProcessInfo
    private let candidatePaths: [String]

    init(
        fileManager: FileManager = .default,
        processInfo: ProcessInfo = .processInfo,
        candidatePaths: [String] = [
            "/usr/local/bin/container",
            "/opt/homebrew/bin/container"
        ]
    ) {
        self.fileManager = fileManager
        self.processInfo = processInfo
        self.candidatePaths = candidatePaths
    }

    func currentSupportStatus() -> AppleContainerSupportStatus {
#if arch(arm64)
        let isAppleSilicon = true
#else
        let isAppleSilicon = false
#endif

        guard isAppleSilicon else {
            return .unsupported(message: "Apple containers require an Apple silicon Mac.")
        }

        let version = processInfo.operatingSystemVersion
        guard version.majorVersion >= 26 else {
            return .unsupported(message: "Apple containers require macOS 26 or newer.")
        }

        for path in candidatePaths where fileManager.isExecutableFile(atPath: path) {
            return .supported(executableURL: URL(fileURLWithPath: path))
        }

        return .unsupported(
            message: "Install Apple's container CLI from github.com/apple/container/releases, then reopen the app."
        )
    }
}

final class HealthEndpointChecker: LocalRuntimeHealthChecking {
    func waitUntilHealthy(baseURL: URL, timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while Date() < deadline {
            if await isHealthy(baseURL: baseURL) {
                return true
            }

            try? await Task.sleep(for: .milliseconds(300))
        }

        return false
    }

    private func isHealthy(baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("healthz"))
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

    @Published var managedHostPort: String {
        didSet {
            userDefaults.set(managedHostPort, forKey: Self.managedHostPortKey)
        }
    }

    @Published var managedContainerPort: String {
        didSet {
            userDefaults.set(managedContainerPort, forKey: Self.managedContainerPortKey)
        }
    }

    @Published private(set) var runtimeState: RuntimeState = .stopped
    @Published private(set) var runtimeStatusDetail = "Stopped"
    @Published private(set) var lastRuntimeError: String?
    @Published private(set) var recentLogs = ""

    private let userDefaults: UserDefaults
    private let supportChecker: AppleContainerSupportChecking
    private let commandRunner: CommandRunning
    private let healthChecker: LocalRuntimeHealthChecking

    private static let runtimeModeKey = "runtimeMode"
    private static let managedContainerImageKey = "managedContainerImage"
    private static let managedContainerNameKey = "managedContainerName"
    private static let managedHostPortKey = "managedHostPort"
    private static let managedContainerPortKey = "managedContainerPort"
    private static let agentEndpointURLKey = "agentEndpointURL"
    private static let legacyAgentSocketURLKey = "agentSocketURL"
    private static let legacyManualRuntimeMode = "manualWebSocket"
    private static let defaultManualEndpointURL = AgentEndpoint.defaultLocalBaseURLString
    private static let legacyDefaultManualSocketURL = "ws://127.0.0.1:18000/ws"

    init(
        userDefaults: UserDefaults = .standard,
        supportChecker: AppleContainerSupportChecking = AppleContainerSupportChecker(),
        commandRunner: CommandRunning = ProcessCommandRunner(),
        healthChecker: LocalRuntimeHealthChecking = HealthEndpointChecker()
    ) {
        self.userDefaults = userDefaults
        self.supportChecker = supportChecker
        self.commandRunner = commandRunner
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
        self.managedHostPort = userDefaults.string(forKey: Self.managedHostPortKey) ?? "18000"
        self.managedContainerPort = userDefaults.string(forKey: Self.managedContainerPortKey) ?? "8000"
    }

    var computedEndpointURL: String {
        resolvedConfiguration?.endpointURL ?? AgentEndpoint.defaultLocalBaseURLString
    }

    var isManagedMode: Bool {
        runtimeMode == .managedAppleContainer
    }

    var isRuntimeActionDisabled: Bool {
        runtimeState.isBusy
    }

    func refreshStatus() async {
        lastRuntimeError = nil

        guard case .supported(let executableURL) = supportChecker.currentSupportStatus() else {
            applyUnsupportedState()
            return
        }

        guard let configuration = resolvedConfiguration else {
            runtimeState = .failed
            runtimeStatusDetail = "Managed runtime settings are invalid."
            lastRuntimeError = "Enter a valid image, container name, and port mapping for the managed runtime."
            return
        }

        do {
            let containers = try await listManagedContainers(executableURL: executableURL, configuration: configuration)
            if let container = containers.first {
                if container.status == "running" {
                    runtimeState = .running
                    let isHealthy = await healthChecker.waitUntilHealthy(
                        baseURL: configuration.endpoint.baseURL,
                        timeoutSeconds: 2
                    )
                    if isHealthy {
                        runtimeState = .running
                        runtimeStatusDetail = "Running at \(configuration.endpointURL)"
                    } else {
                        runtimeState = .failed
                        runtimeStatusDetail = "Container is running but the endpoint is unavailable."
                    }
                } else {
                    runtimeState = .stopped
                    runtimeStatusDetail = "Container exists but is not running."
                }
            } else {
                runtimeState = .stopped
                runtimeStatusDetail = "Managed container is not running."
            }
        } catch {
            runtimeState = .stopped
            runtimeStatusDetail = "Apple container service is not running."
        }
    }

    func startRuntime() async -> Bool {
        lastRuntimeError = nil
        recentLogs = ""

        guard case .supported(let executableURL) = supportChecker.currentSupportStatus() else {
            applyUnsupportedState()
            return false
        }

        guard let configuration = resolvedConfiguration else {
            applyFailure("Enter a valid image, container name, and port mapping for the managed runtime.")
            return false
        }

        runtimeState = .starting
        runtimeStatusDetail = "Starting Apple container runtime..."

        do {
            try await runChecked(
                executableURL: executableURL,
                arguments: ["system", "start"],
                failurePrefix: "Could not start Apple's container service."
            )

            let existingContainers = try await listManagedContainers(
                executableURL: executableURL,
                configuration: configuration
            )
            if let existingContainer = existingContainers.first {
                if existingContainer.status == "running" {
                    _ = try? await commandRunner.run(
                        executableURL: executableURL,
                        arguments: ["stop", configuration.containerName]
                    )
                }

                _ = try? await commandRunner.run(
                    executableURL: executableURL,
                    arguments: ["rm", configuration.containerName]
                )
            }

            _ = try? await commandRunner.run(
                executableURL: executableURL,
                arguments: ["image", "delete", configuration.image]
            )

            try await runChecked(
                executableURL: executableURL,
                arguments: [
                    "run",
                    "--name", configuration.containerName,
                    "--detach",
                    "--rm",
                    "-p", configuration.publishArgument,
                    configuration.image
                ],
                failurePrefix: "Could not start the managed container."
            )

            let isHealthy = await healthChecker.waitUntilHealthy(
                baseURL: configuration.endpoint.baseURL,
                timeoutSeconds: 20
            )

            guard isHealthy else {
                recentLogs = await fetchLogs(executableURL: executableURL, containerName: configuration.containerName)
                throw LocalRuntimeFailure("Container started, but the HTTP endpoint never became ready.")
            }

            runtimeState = .running
            runtimeStatusDetail = "Running at \(configuration.endpointURL)"
            return true
        } catch let error as LocalRuntimeFailure {
            applyFailure(error.message)
            return false
        } catch {
            applyFailure(error.localizedDescription)
            return false
        }
    }

    func stopRuntime() async {
        lastRuntimeError = nil

        guard case .supported(let executableURL) = supportChecker.currentSupportStatus() else {
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

        _ = try? await commandRunner.run(
            executableURL: executableURL,
            arguments: ["stop", containerName]
        )
        _ = try? await commandRunner.run(
            executableURL: executableURL,
            arguments: ["rm", containerName]
        )

        runtimeState = .stopped
        runtimeStatusDetail = "Managed container stopped."
        recentLogs = ""
    }

    func restartRuntime() async -> Bool {
        await stopRuntime()
        return await startRuntime()
    }

    private var resolvedConfiguration: ManagedContainerConfiguration? {
        let image = managedContainerImage.trimmingCharacters(in: .whitespacesAndNewlines)
        let containerName = managedContainerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostPortValue = UInt16(managedHostPort.trimmingCharacters(in: .whitespacesAndNewlines))
        let containerPortValue = UInt16(managedContainerPort.trimmingCharacters(in: .whitespacesAndNewlines))

        guard !image.isEmpty,
              !containerName.isEmpty,
              let hostPort = hostPortValue,
              let containerPort = containerPortValue else {
            return nil
        }

        return ManagedContainerConfiguration(
            image: image,
            containerName: containerName,
            hostPort: hostPort,
            containerPort: containerPort
        )
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
        }
    }

    private func applyFailure(_ message: String) {
        runtimeState = .failed
        runtimeStatusDetail = "Managed runtime failed."
        lastRuntimeError = message
    }

    private func listManagedContainers(
        executableURL: URL,
        configuration: ManagedContainerConfiguration
    ) async throws -> [ManagedContainerListEntry] {
        let result = try await commandRunner.run(
            executableURL: executableURL,
            arguments: ["ls", "--format", "json", "--all"]
        )

        guard result.exitCode == 0 else {
            throw LocalRuntimeFailure(preferredCommandMessage(from: result, fallback: "Could not list containers."))
        }

        let data = Data(result.stdout.utf8)
        let containers = try JSONDecoder().decode([ManagedContainerListEntry].self, from: data)
        return containers.filter { $0.configuration.id == configuration.containerName }
    }

    private func fetchLogs(executableURL: URL, containerName: String) async -> String {
        guard !containerName.isEmpty else {
            return ""
        }

        guard let result = try? await commandRunner.run(
            executableURL: executableURL,
            arguments: ["logs", containerName]
        ) else {
            return ""
        }

        let rawOutput = [result.stdout, result.stderr]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawOutput.isEmpty else {
            return ""
        }

        return String(rawOutput.suffix(4_000))
    }

    private func runChecked(
        executableURL: URL,
        arguments: [String],
        failurePrefix: String
    ) async throws {
        let result = try await commandRunner.run(executableURL: executableURL, arguments: arguments)
        guard result.exitCode == 0 else {
            throw LocalRuntimeFailure("\(failurePrefix) \(preferredCommandMessage(from: result, fallback: "The command exited with status \(result.exitCode)."))")
        }
    }

    private func preferredCommandMessage(from result: CommandResult, fallback: String) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty {
            return stderr
        }

        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            return stdout
        }

        return fallback
    }
}

private struct ManagedContainerListEntry: Decodable, Equatable {
    struct Configuration: Decodable, Equatable {
        let id: String
    }

    let status: String
    let configuration: Configuration
}

private struct LocalRuntimeFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
