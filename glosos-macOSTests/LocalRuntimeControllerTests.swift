//
//  LocalRuntimeControllerTests.swift
//  glosos-macOSTests
//
//  Created by Codex on 6/5/26.
//

import Foundation
import Testing
@testable import glosos_macOS

struct LocalRuntimeControllerTests {

    @Test
    @MainActor
    func defaultsToManagedRuntimeWhenNoCustomEndpointURLIsSaved() async throws {
        let defaults = makeIsolatedDefaults()
        let controller = LocalRuntimeController(
            userDefaults: defaults,
            supportChecker: StubSupportChecker(status: .unsupported(message: "Unavailable")),
            commandRunner: RecordingCommandRunner(results: []),
            healthChecker: ImmediateHealthChecker(isHealthy: false)
        )

        #expect(controller.runtimeMode == .managedAppleContainer)
    }

    @Test
    @MainActor
    func preservesManualModeWhenCustomLegacySocketURLExists() async throws {
        let defaults = makeIsolatedDefaults()
        defaults.set("ws://127.0.0.1:19000/ws", forKey: "agentSocketURL")

        let controller = LocalRuntimeController(
            userDefaults: defaults,
            supportChecker: StubSupportChecker(status: .unsupported(message: "Unavailable")),
            commandRunner: RecordingCommandRunner(results: []),
            healthChecker: ImmediateHealthChecker(isHealthy: false)
        )

        #expect(controller.runtimeMode == .manualEndpoint)
    }

    @Test
    @MainActor
    func managedRuntimeStartUsesExpectedAppleContainerCommands() async throws {
        let defaults = makeIsolatedDefaults()
        let commandRunner = RecordingCommandRunner(results: [
            .success(CommandResult(exitCode: 0, stdout: "", stderr: "")),
            .success(CommandResult(exitCode: 0, stdout: "[]", stderr: "")),
            .success(CommandResult(exitCode: 0, stdout: "", stderr: "")),
            .success(CommandResult(exitCode: 0, stdout: "glosos-google-user-macos\n", stderr: ""))
        ])

        let controller = LocalRuntimeController(
            userDefaults: defaults,
            supportChecker: StubSupportChecker(
                status: .supported(executableURL: URL(fileURLWithPath: "/usr/local/bin/container"))
            ),
            commandRunner: commandRunner,
            healthChecker: ImmediateHealthChecker(isHealthy: true)
        )

        let didStart = await controller.startRuntime()

        #expect(didStart)
        #expect(controller.runtimeState == .running)
        #expect(controller.runtimeStatusDetail == "Running at http://127.0.0.1:18000")
        #expect(commandRunner.invocations.map(\.arguments) == [
            ["system", "start"],
            ["ls", "--format", "json", "--all"],
            ["image", "delete", "ghcr.io/basistiy/glosos-google-user:latest"],
            [
                "run",
                "--name", "glosos-google-user-macos",
                "--detach",
                "--rm",
                "-p", "127.0.0.1:18000:8000",
                "ghcr.io/basistiy/glosos-google-user:latest"
            ]
        ])
    }

    @Test
    @MainActor
    func managedRuntimeStartFailsWhenEndpointNeverBecomesHealthy() async throws {
        let defaults = makeIsolatedDefaults()
        let commandRunner = RecordingCommandRunner(results: [
            .success(CommandResult(exitCode: 0, stdout: "", stderr: "")),
            .success(CommandResult(exitCode: 0, stdout: "[]", stderr: "")),
            .success(CommandResult(exitCode: 0, stdout: "", stderr: "")),
            .success(CommandResult(exitCode: 0, stdout: "glosos-google-user-macos\n", stderr: "")),
            .success(CommandResult(exitCode: 0, stdout: "container logs", stderr: ""))
        ])

        let controller = LocalRuntimeController(
            userDefaults: defaults,
            supportChecker: StubSupportChecker(
                status: .supported(executableURL: URL(fileURLWithPath: "/usr/local/bin/container"))
            ),
            commandRunner: commandRunner,
            healthChecker: ImmediateHealthChecker(isHealthy: false)
        )

        let didStart = await controller.startRuntime()

        #expect(didStart == false)
        #expect(controller.runtimeState == .failed)
        #expect(controller.lastRuntimeError == "Container started, but the HTTP endpoint never became ready.")
        #expect(controller.recentLogs == "container logs")
    }

    @Test
    @MainActor
    func missingAppleContainerCliShowsInstallGuidance() async throws {
        let defaults = makeIsolatedDefaults()
        let controller = LocalRuntimeController(
            userDefaults: defaults,
            supportChecker: StubSupportChecker(
                status: .unsupported(message: "Install Apple's container CLI.")
            ),
            commandRunner: RecordingCommandRunner(results: []),
            healthChecker: ImmediateHealthChecker(isHealthy: false)
        )

        let didStart = await controller.startRuntime()

        #expect(didStart == false)
        #expect(controller.runtimeState == .unsupported)
        #expect(controller.lastRuntimeError == "Install Apple's container CLI.")
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "LocalRuntimeControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private struct StubSupportChecker: AppleContainerSupportChecking {
    let status: AppleContainerSupportStatus

    func currentSupportStatus() -> AppleContainerSupportStatus {
        status
    }
}

@MainActor
private final class RecordingCommandRunner: CommandRunning {
    struct Invocation: Equatable {
        let executableURL: URL
        let arguments: [String]
    }

    private var queuedResults: [Result<CommandResult, Error>]
    private(set) var invocations: [Invocation] = []

    init(results: [Result<CommandResult, Error>]) {
        self.queuedResults = results
    }

    func run(executableURL: URL, arguments: [String]) async throws -> CommandResult {
        invocations.append(Invocation(executableURL: executableURL, arguments: arguments))

        guard !queuedResults.isEmpty else {
            Issue.record("No queued command result for \(arguments.joined(separator: " "))")
            return CommandResult(exitCode: 1, stdout: "", stderr: "Missing stub result.")
        }

        let nextResult = queuedResults.removeFirst()
        return try nextResult.get()
    }
}

private struct ImmediateHealthChecker: LocalRuntimeHealthChecking {
    let isHealthy: Bool

    func waitUntilHealthy(baseURL: URL, timeoutSeconds: TimeInterval) async -> Bool {
        let _ = baseURL
        let _ = timeoutSeconds
        return isHealthy
    }
}
