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
            assetManager: StubAssetManager(),
            runtimeManager: StubRuntimeManager(),
            healthChecker: ImmediateHealthChecker(isHealthy: false)
        )

        #expect(controller.runtimeMode == .managedAppleContainer)
    }

//    @Test
//    @MainActor
//    func preservesManualModeWhenCustomLegacySocketURLExists() async throws {
//        let defaults = makeIsolatedDefaults()
//        defaults.set("ws://127.0.0.1:19000/ws", forKey: "agentSocketURL")
//
//        let controller = LocalRuntimeController(
//            userDefaults: defaults,
//            supportChecker: StubSupportChecker(status: .unsupported(message: "Unavailable")),
//            assetManager: StubAssetManager(),
//            runtimeManager: StubRuntimeManager(),
//            healthChecker: ImmediateHealthChecker(isHealthy: false)
//        )
//
//        #expect(controller.runtimeMode == .manualEndpoint)
//    }

    @Test
    @MainActor
    func managedRuntimeStartUsesPreparedAssetsAndPublishesEndpoint() async throws {
        let defaults = makeIsolatedDefaults()
        defaults.set("gemini-2.5-flash", forKey: "managedModelName")
        defaults.set("secret", forKey: "managedGoogleAPIKey")

        let assetManager = StubAssetManager()
        let runtimeManager = StubRuntimeManager(
            startResult: .success(
                ManagedRuntimeEndpoint(host: "192.168.64.2", port: 8000)
            )
        )

        let controller = LocalRuntimeController(
            userDefaults: defaults,
            supportChecker: StubSupportChecker(status: .supported),
            assetManager: assetManager,
            runtimeManager: runtimeManager,
            healthChecker: ImmediateHealthChecker(isHealthy: true)
        )

        let didStart = await controller.startRuntime()
        let prepareCalls = await assetManager.prepareCalls
        let startInvocation = await runtimeManager.startInvocation

        #expect(didStart)
        #expect(controller.runtimeState == .running)
        #expect(controller.currentManagedEndpoint == ManagedRuntimeEndpoint(host: "192.168.64.2", port: 8000))
        #expect(controller.runtimeStatusDetail == "Running at http://192.168.64.2:8000")
        #expect(prepareCalls == 1)
        #expect(startInvocation?.configuration.image == "docker.io/evbasistyi/glosos-google-user:latest")
        #expect(startInvocation?.configuration.containerName == "glosos-google-user-macos")
        #expect(startInvocation?.configuration.modelName == "gemini-2.5-flash")
        #expect(startInvocation?.configuration.googleAPIKey == "secret")
        #expect(startInvocation?.assets == StubAssetManager.sampleAssets)
        #expect(startInvocation?.reuseCachedFilesystem == true)
    }

    @Test
    @MainActor
    func managedRuntimeStartFailsWhenEndpointNeverBecomesHealthy() async throws {
        let defaults = makeIsolatedDefaults()
        defaults.set("gemini-2.5-flash", forKey: "managedModelName")
        defaults.set("secret", forKey: "managedGoogleAPIKey")

        let assetManager = StubAssetManager(logs: "boot failed")
        let runtimeManager = StubRuntimeManager(
            startResults: [
                .success(ManagedRuntimeEndpoint(host: "192.168.64.2", port: 8000)),
                .success(ManagedRuntimeEndpoint(host: "192.168.64.3", port: 8000)),
            ]
        )

        let controller = LocalRuntimeController(
            userDefaults: defaults,
            supportChecker: StubSupportChecker(status: .supported),
            assetManager: assetManager,
            runtimeManager: runtimeManager,
            healthChecker: ImmediateHealthChecker(isHealthy: false)
        )

        let didStart = await controller.startRuntime()
        let stopCalls = await runtimeManager.stopCalls

        #expect(didStart == false)
        #expect(controller.runtimeState == .failed)
        #expect(controller.lastRuntimeError == "Container started, but the runtime endpoint never became ready.")
        #expect(controller.recentLogs == "boot failed")
        #expect(stopCalls == ["glosos-google-user-macos", "glosos-google-user-macos", "glosos-google-user-macos"])
    }

    @Test
    @MainActor
    func managedRuntimeRetriesWithoutCachedFilesystemAfterCachedStartFailure() async throws {
        let defaults = makeIsolatedDefaults()
        defaults.set("gemini-2.5-flash", forKey: "managedModelName")
        defaults.set("secret", forKey: "managedGoogleAPIKey")

        let runtimeManager = StubRuntimeManager(
            startResults: [
                .failure(RuntimePreparationError.failed("Cached filesystem failed")),
                .success(ManagedRuntimeEndpoint(host: "192.168.64.2", port: 8000)),
            ]
        )

        let controller = LocalRuntimeController(
            userDefaults: defaults,
            supportChecker: StubSupportChecker(status: .supported),
            assetManager: StubAssetManager(),
            runtimeManager: runtimeManager,
            healthChecker: ImmediateHealthChecker(isHealthy: true)
        )

        let didStart = await controller.startRuntime()
        let startInvocations = await runtimeManager.startInvocations
        let stopCalls = await runtimeManager.stopCalls

        #expect(didStart)
        #expect(startInvocations.count == 2)
        #expect(startInvocations.map(\.reuseCachedFilesystem) == [true, false])
        #expect(stopCalls == ["glosos-google-user-macos"])
    }

    @Test
    @MainActor
    func managedRuntimeRetriesWithoutCachedFilesystemAfterUnhealthyCachedStart() async throws {
        let defaults = makeIsolatedDefaults()
        defaults.set("gemini-2.5-flash", forKey: "managedModelName")
        defaults.set("secret", forKey: "managedGoogleAPIKey")

        let runtimeManager = StubRuntimeManager(
            startResults: [
                .success(ManagedRuntimeEndpoint(host: "192.168.64.2", port: 8000)),
                .success(ManagedRuntimeEndpoint(host: "192.168.64.3", port: 8000)),
            ]
        )

        let controller = LocalRuntimeController(
            userDefaults: defaults,
            supportChecker: StubSupportChecker(status: .supported),
            assetManager: StubAssetManager(logs: "boot failed"),
            runtimeManager: runtimeManager,
            healthChecker: SequencedHealthChecker(results: [false, true])
        )

        let didStart = await controller.startRuntime()
        let startInvocations = await runtimeManager.startInvocations
        let stopCalls = await runtimeManager.stopCalls

        #expect(didStart)
        #expect(controller.currentManagedEndpoint == ManagedRuntimeEndpoint(host: "192.168.64.3", port: 8000))
        #expect(startInvocations.map(\.reuseCachedFilesystem) == [true, false])
        #expect(stopCalls == ["glosos-google-user-macos", "glosos-google-user-macos"])
    }

    @Test
    @MainActor
    func missingAppleContainerSupportShowsGuidance() async throws {
        let defaults = makeIsolatedDefaults()
        let controller = LocalRuntimeController(
            userDefaults: defaults,
            supportChecker: StubSupportChecker(
                status: .unsupported(message: "Managed containers require macOS 26 or newer.")
            ),
            assetManager: StubAssetManager(),
            runtimeManager: StubRuntimeManager(),
            healthChecker: ImmediateHealthChecker(isHealthy: false)
        )

        let didStart = await controller.startRuntime()

        #expect(didStart == false)
        #expect(controller.runtimeState == .unsupported)
        #expect(controller.lastRuntimeError == "Managed containers require macOS 26 or newer.")
    }

    @Test
    @MainActor
    func refreshStatusDoesNotTreatMissingManagedCredentialsAsFailure() async throws {
        let defaults = makeIsolatedDefaults()
        let controller = LocalRuntimeController(
            userDefaults: defaults,
            supportChecker: StubSupportChecker(status: .supported),
            assetManager: StubAssetManager(),
            runtimeManager: StubRuntimeManager(),
            healthChecker: ImmediateHealthChecker(isHealthy: false)
        )

        await controller.refreshStatus()

        #expect(controller.runtimeState == .stopped)
        #expect(controller.lastRuntimeError == nil)
        #expect(controller.runtimeStatusDetail == "Managed runtime is waiting for a Google API key.")
    }

    @Test
    @MainActor
    func storagePreparationFailureSurfacesUnsupportedMessage() async throws {
        let defaults = makeIsolatedDefaults()
        defaults.set("gemini-2.5-flash", forKey: "managedModelName")
        defaults.set("secret", forKey: "managedGoogleAPIKey")

        let controller = LocalRuntimeController(
            userDefaults: defaults,
            supportChecker: StubSupportChecker(status: .supported),
            assetManager: StubAssetManager(
                prepareError: RuntimePreparationError.unsupported("Storage unavailable.")
            ),
            runtimeManager: StubRuntimeManager(),
            healthChecker: ImmediateHealthChecker(isHealthy: false)
        )

        let didStart = await controller.startRuntime()

        #expect(didStart == false)
        #expect(controller.runtimeState == .unsupported)
        #expect(controller.lastRuntimeError == "Storage unavailable.")
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "LocalRuntimeControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private struct StubSupportChecker: ContainerizationSupportChecking {
    let status: ContainerizationSupportStatus

    func currentSupportStatus() -> ContainerizationSupportStatus {
        status
    }
}

actor StubAssetManager: ContainerAssetManaging {
    static let sampleAssets = ContainerRuntimeAssets(
        supportRootURL: URL(fileURLWithPath: "/tmp/glosos"),
        imageStoreURL: URL(fileURLWithPath: "/tmp/glosos/image-store"),
        kernelDirectoryURL: URL(fileURLWithPath: "/tmp/glosos/kernel"),
        kernelURL: URL(fileURLWithPath: "/tmp/glosos/kernel/vmlinux"),
        logsDirectoryURL: URL(fileURLWithPath: "/tmp/glosos/logs"),
        userWorkspaceURL: URL(fileURLWithPath: "/tmp/glosos/user")
    )

    var prepareCalls = 0
    private let prepareError: Error?
    private let logs: String

    init(prepareError: Error? = nil, logs: String = "") {
        self.prepareError = prepareError
        self.logs = logs
    }

    func existingAssets() throws -> ContainerRuntimeAssets? {
        Self.sampleAssets
    }

    func prepareAssets(
        updateStatus: @escaping @Sendable (String) async -> Void
    ) async throws -> ContainerRuntimeAssets {
        prepareCalls += 1
        await updateStatus("Preparing app support storage...")
        if let prepareError {
            throw prepareError
        }
        return Self.sampleAssets
    }

    func recentLogs(
        containerName: String,
        assets: ContainerRuntimeAssets?
    ) async -> String {
        let _ = containerName
        let _ = assets
        return logs
    }
}

actor StubRuntimeManager: ContainerRuntimeManaging {
    struct StartInvocation {
        let configuration: ManagedContainerConfiguration
        let assets: ContainerRuntimeAssets
        let reuseCachedFilesystem: Bool
    }

    private var startResults: [Result<ManagedRuntimeEndpoint, Error>]
    private(set) var startInvocation: StartInvocation?
    private(set) var startInvocations: [StartInvocation] = []
    private(set) var stopCalls: [String] = []

    init(
        startResult: Result<ManagedRuntimeEndpoint, Error> = .failure(RuntimePreparationError.failed("Not started"))
    ) {
        self.startResults = [startResult]
    }

    init(startResults: [Result<ManagedRuntimeEndpoint, Error>]) {
        self.startResults = startResults
    }

    func currentEndpoint(containerName: String) async -> ManagedRuntimeEndpoint? {
        let _ = containerName
        return nil
    }

    func start(
        configuration: ManagedContainerConfiguration,
        assets: ContainerRuntimeAssets,
        reuseCachedFilesystem: Bool,
        updateStatus: @escaping @Sendable (String) async -> Void
    ) async throws -> ManagedRuntimeEndpoint {
        let invocation = StartInvocation(
            configuration: configuration,
            assets: assets,
            reuseCachedFilesystem: reuseCachedFilesystem
        )
        startInvocation = invocation
        startInvocations.append(invocation)
        await updateStatus("Starting container...")
        guard !startResults.isEmpty else {
            throw RuntimePreparationError.failed("Not started")
        }

        return try startResults.removeFirst().get()
    }

    func stop(
        containerName: String,
        assets: ContainerRuntimeAssets?
    ) async {
        let _ = assets
        stopCalls.append(containerName)
    }
}

private struct ImmediateHealthChecker: LocalRuntimeHealthChecking {
    let isHealthy: Bool

    func waitUntilHealthy(endpoint: ManagedRuntimeEndpoint, timeoutSeconds: TimeInterval) async -> Bool {
        let _ = endpoint
        let _ = timeoutSeconds
        return isHealthy
    }
}

actor SequencedHealthChecker: LocalRuntimeHealthChecking {
    private var results: [Bool]

    init(results: [Bool]) {
        self.results = results
    }

    func waitUntilHealthy(endpoint: ManagedRuntimeEndpoint, timeoutSeconds: TimeInterval) async -> Bool {
        let _ = endpoint
        let _ = timeoutSeconds
        guard !results.isEmpty else {
            return false
        }

        return results.removeFirst()
    }
}
