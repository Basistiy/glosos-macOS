//
//  ContainerizationRuntimeSupport.swift
//  glosos-macOS
//
//  Created by Codex on 6/5/26.
//

import Containerization
import ContainerizationArchive
import ContainerizationError
import ContainerizationExtras
import Foundation

enum ContainerizationSupportStatus: Equatable {
    case supported
    case unsupported(message: String)
}

protocol ContainerizationSupportChecking {
    func currentSupportStatus() -> ContainerizationSupportStatus
}

struct ContainerRuntimeAssets: Equatable {
    let supportRootURL: URL
    let imageStoreURL: URL
    let kernelDirectoryURL: URL
    let kernelURL: URL
    let logsDirectoryURL: URL
    let userWorkspaceURL: URL
}

protocol ContainerAssetManaging {
    func existingAssets() throws -> ContainerRuntimeAssets?
    func prepareAssets(
        updateStatus: @escaping @Sendable (String) async -> Void
    ) async throws -> ContainerRuntimeAssets
    func recentLogs(
        containerName: String,
        assets: ContainerRuntimeAssets?
    ) async -> String
}

protocol ContainerRuntimeManaging {
    func currentEndpoint(containerName: String) async -> ManagedRuntimeEndpoint?
    func start(
        configuration: ManagedContainerConfiguration,
        assets: ContainerRuntimeAssets,
        reuseCachedFilesystem: Bool,
        updateStatus: @escaping @Sendable (String) async -> Void
    ) async throws -> ManagedRuntimeEndpoint
    func stop(
        containerName: String,
        assets: ContainerRuntimeAssets?
    ) async
}

struct ContainerizationSupportChecker: ContainerizationSupportChecking {
    private let processInfo: ProcessInfo

    init(processInfo: ProcessInfo = .processInfo) {
        self.processInfo = processInfo
    }

    func currentSupportStatus() -> ContainerizationSupportStatus {
#if arch(arm64)
        let isAppleSilicon = true
#else
        let isAppleSilicon = false
#endif

        guard isAppleSilicon else {
            return .unsupported(message: "Managed containers require an Apple silicon Mac.")
        }

        let version = processInfo.operatingSystemVersion
        guard version.majorVersion >= 26 else {
            return .unsupported(message: "Managed containers require macOS 26 or newer.")
        }

        return .supported
    }
}

final class ApplicationSupportContainerAssetManager: @unchecked Sendable, ContainerAssetManaging {
    private static let kernelDownloadURL =
        URL(string: "https://github.com/kata-containers/kata-containers/releases/download/3.26.0/kata-static-3.26.0-arm64.tar.zst")!
    nonisolated private static let kernelPathInArchive = "opt/kata/share/kata-containers/vmlinux.container"

    private let fileManager: FileManager
    private let session: URLSession
    private let supportRootURL: URL

    init(
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        supportRootURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.session = session
        self.supportRootURL = supportRootURL ?? Self.defaultSupportRootURL(fileManager: fileManager)
    }

    func existingAssets() throws -> ContainerRuntimeAssets? {
        guard fileManager.fileExists(atPath: supportRootURL.path(percentEncoded: false)) else {
            return nil
        }

        return makeAssets()
    }

    func prepareAssets(
        updateStatus: @escaping @Sendable (String) async -> Void
    ) async throws -> ContainerRuntimeAssets {
        await updateStatus("Preparing app support storage...")

        let assets = makeAssets()
        do {
            try fileManager.createDirectory(
                at: assets.supportRootURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: assets.imageStoreURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: assets.kernelDirectoryURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: assets.logsDirectoryURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: assets.userWorkspaceURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw RuntimePreparationError.unsupported(
                "The app could not create runtime storage in Application Support. \(error.localizedDescription)"
            )
        }

        guard !fileManager.fileExists(atPath: assets.kernelURL.path(percentEncoded: false)) else {
            return assets
        }

        let archiveURL = try await downloadKernelArchive(updateStatus: updateStatus)

        await updateStatus("Extracting Linux kernel...")
        try Self.extractKernel(from: archiveURL, to: assets.kernelURL)

        return assets
    }

    func recentLogs(
        containerName: String,
        assets: ContainerRuntimeAssets?
    ) async -> String {
        guard let assets else {
            return ""
        }

        let bootLogURL = assets.imageStoreURL
            .appendingPathComponent("containers", isDirectory: true)
            .appendingPathComponent(containerName, isDirectory: true)
            .appendingPathComponent("bootlog.log")
        let stdoutURL = assets.logsDirectoryURL.appendingPathComponent("\(containerName)-stdout.log")
        let stderrURL = assets.logsDirectoryURL.appendingPathComponent("\(containerName)-stderr.log")

        let sections = [
            ("Boot log", bootLogURL),
            ("stdout", stdoutURL),
            ("stderr", stderrURL),
        ].compactMap { label, url -> String? in
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                return nil
            }

            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }

            return "[\(label)]\n\(trimmed)"
        }

        guard !sections.isEmpty else {
            return ""
        }

        return String(sections.joined(separator: "\n\n").suffix(8_000))
    }

    private func makeAssets() -> ContainerRuntimeAssets {
        let kernelDirectoryURL = supportRootURL.appendingPathComponent("kernel", isDirectory: true)
        return ContainerRuntimeAssets(
            supportRootURL: supportRootURL,
            imageStoreURL: supportRootURL.appendingPathComponent("image-store", isDirectory: true),
            kernelDirectoryURL: kernelDirectoryURL,
            kernelURL: kernelDirectoryURL.appendingPathComponent("vmlinux"),
            logsDirectoryURL: supportRootURL.appendingPathComponent("logs", isDirectory: true),
            userWorkspaceURL: supportRootURL.appendingPathComponent("user", isDirectory: true)
        )
    }

    nonisolated private static func defaultSupportRootURL(fileManager: FileManager) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return root
            .appendingPathComponent("Glosos", isDirectory: true)
            .appendingPathComponent("Containerization", isDirectory: true)
    }

    nonisolated static func defaultUserWorkspaceURL(fileManager: FileManager = .default) -> URL {
        defaultSupportRootURL(fileManager: fileManager)
            .appendingPathComponent("user", isDirectory: true)
    }

    nonisolated private static func extractKernel(from archiveURL: URL, to destinationURL: URL) throws {
        var targetPath = kernelPathInArchive
        var archiveReader = try ArchiveReader(file: archiveURL)
        var (entry, data) = try archiveReader.extractFile(path: targetPath)

        if entry.fileType == .symbolicLink, let symlinkTarget = entry.symlinkTarget {
            archiveReader = try ArchiveReader(file: archiveURL)
            let resolvedPath = URL(filePath: targetPath)
                .deletingLastPathComponent()
                .appending(path: symlinkTarget)
                .standardized
                .relativePath
            targetPath = resolvedPath
            (_, data) = try archiveReader.extractFile(path: targetPath)
        }

        try data.write(to: destinationURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destinationURL.path(percentEncoded: false)
        )
    }

    private func downloadKernelArchive(
        updateStatus: @escaping @Sendable (String) async -> Void
    ) async throws -> URL {
        let reporter = KernelDownloadProgressReporter(statusHandler: updateStatus)
        await reporter.reportInitialStatus()

        let delegate = KernelDownloadDelegate(reporter: reporter)
        let delegateSession = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer {
            delegateSession.invalidateAndCancel()
        }

        let (archiveURL, _) = try await delegateSession.download(from: Self.kernelDownloadURL)
        await reporter.reportCompletion()
        return archiveURL
    }
}

private final class KernelDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let reporter: KernelDownloadProgressReporter

    init(reporter: KernelDownloadProgressReporter) {
        self.reporter = reporter
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let _ = session
        let _ = downloadTask

        Task {
            await reporter.report(
                bytesDownloaded: totalBytesWritten,
                totalBytesExpected: totalBytesExpectedToWrite
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let _ = session
        let _ = downloadTask
        let _ = location
    }
}

private actor KernelDownloadProgressReporter {
    private let statusHandler: @Sendable (String) async -> Void
    private var lastReportedBucket = -1
    private var lastReportedDownloadedBytes: Int64 = 0

    init(statusHandler: @escaping @Sendable (String) async -> Void) {
        self.statusHandler = statusHandler
    }

    func reportInitialStatus() async {
        await statusHandler("Downloading Linux kernel...")
    }

    func report(bytesDownloaded: Int64, totalBytesExpected: Int64) async {
        guard bytesDownloaded >= 0 else {
            return
        }

        if totalBytesExpected > 0 {
            let fraction = Double(bytesDownloaded) / Double(totalBytesExpected)
            let bucket = min(Int((fraction * 100).rounded(.down) / 10) * 10, 100)

            guard bucket > lastReportedBucket else {
                return
            }

            lastReportedBucket = bucket
            await statusHandler(
                "Downloading Linux kernel... \(bucket)% (\(Self.byteString(bytesDownloaded)) of \(Self.byteString(totalBytesExpected)))"
            )
            return
        }

        let minimumDelta: Int64 = 25 * 1024 * 1024
        guard bytesDownloaded - lastReportedDownloadedBytes >= minimumDelta else {
            return
        }

        lastReportedDownloadedBytes = bytesDownloaded
        await statusHandler("Downloading Linux kernel... \(Self.byteString(bytesDownloaded))")
    }

    func reportCompletion() async {
        await statusHandler("Downloading Linux kernel... complete")
    }

    private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private actor ContainerOperationProgressReporter {
    private let activity: String
    private let statusHandler: @Sendable (String) async -> Void
    private var totalItems = 0
    private var completedItems = 0
    private var totalSize: Int64 = 0
    private var completedSize: Int64 = 0
    private var lastReportedBucket = -1
    private var lastReportedSize: Int64 = 0

    init(
        activity: String,
        statusHandler: @escaping @Sendable (String) async -> Void
    ) {
        self.activity = activity
        self.statusHandler = statusHandler
    }

    func reportInitialStatus() async {
        await statusHandler("\(activity)...")
    }

    func record(events: [ProgressEvent]) async {
        for event in events {
            switch event {
            case .addItems(let value):
                completedItems += value
            case .addTotalItems(let value):
                totalItems += value
            case .addSize(let value):
                completedSize += value
            case .addTotalSize(let value):
                totalSize += value
            }
        }

        if totalSize > 0 {
            let fraction = min(Double(completedSize) / Double(totalSize), 1)
            let bucket = min(Int((fraction * 100).rounded(.down) / 10) * 10, 100)
            guard bucket > lastReportedBucket else {
                return
            }

            lastReportedBucket = bucket
            await statusHandler(
                "\(activity)... \(bucket)% (\(Self.byteString(completedSize)) of \(Self.byteString(totalSize)))"
            )
            return
        }

        if totalItems > 0 {
            let fraction = min(Double(completedItems) / Double(totalItems), 1)
            let bucket = min(Int((fraction * 100).rounded(.down) / 10) * 10, 100)
            guard bucket > lastReportedBucket else {
                return
            }

            lastReportedBucket = bucket
            await statusHandler("\(activity)... \(completedItems) of \(totalItems) items")
            return
        }

        let minimumDelta: Int64 = 25 * 1024 * 1024
        guard completedSize - lastReportedSize >= minimumDelta else {
            return
        }

        lastReportedSize = completedSize
        await statusHandler("\(activity)... \(Self.byteString(completedSize))")
    }

    func reportCompletion() async {
        await statusHandler("\(activity)... complete")
    }

    private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

actor ContainerizationRuntimeEngine: ContainerRuntimeManaging {
    private struct ActiveSession {
        var manager: ContainerManager
        let container: LinuxContainer
        let containerName: String
        let endpoint: ManagedRuntimeEndpoint
    }

    nonisolated private static let initfsReference = "ghcr.io/apple/containerization/vminit:0.33.4"
    nonisolated private static let rootFilesystemSizeInBytes: UInt64 = 8 * 1024 * 1024 * 1024
    nonisolated private static let containerMemoryInBytes: UInt64 = 4 * 1024 * 1024 * 1024
    nonisolated private static let rootFilesystemFilename = "rootfs.ext4"
    nonisolated private static let imageReferenceMarkerFilename = ".glosos-image-reference"

    private var session: ActiveSession?

    func currentEndpoint(containerName: String) async -> ManagedRuntimeEndpoint? {
        guard session?.containerName == containerName else {
            return nil
        }

        return session?.endpoint
    }

    func start(
        configuration: ManagedContainerConfiguration,
        assets: ContainerRuntimeAssets,
        reuseCachedFilesystem: Bool,
        updateStatus: @escaping @Sendable (String) async -> Void
    ) async throws -> ManagedRuntimeEndpoint {
        await stop(containerName: configuration.containerName, assets: assets)

        let kernel = Kernel(path: assets.kernelURL, platform: .linuxArm)

        await updateStatus("Starting vmnet network...")
        let network = try VmnetNetwork()

        let imageStore = try ImageStore(path: assets.imageStoreURL)
        let initImage = try await Self.fetchImage(
            reference: Self.initfsReference,
            using: imageStore,
            activity: "Pulling init image",
            updateStatus: updateStatus
        )
        let initfs = try await Self.prepareInitFilesystem(
            from: initImage,
            imageStore: imageStore,
            updateStatus: updateStatus
        )

        var manager = try ContainerManager(
            kernel: kernel,
            initfs: initfs,
            imageStore: imageStore,
            network: network
        )

        let stdoutWriter = try FileHandleWriter(
            url: assets.logsDirectoryURL.appendingPathComponent("\(configuration.containerName)-stdout.log")
        )
        let stderrWriter = try FileHandleWriter(
            url: assets.logsDirectoryURL.appendingPathComponent("\(configuration.containerName)-stderr.log")
        )

        let runtimeImage = try await Self.fetchImage(
            reference: configuration.image,
            using: manager.imageStore,
            activity: "Pulling runtime image",
            updateStatus: updateStatus
        )
        let containerRootURL = Self.containerRootURL(
            containerName: configuration.containerName,
            imageStoreURL: assets.imageStoreURL
        )
        let cachedRootfs = reuseCachedFilesystem
            ? Self.cachedRuntimeFilesystemMount(for: configuration, at: containerRootURL)
            : nil

        let container: LinuxContainer
        if let cachedRootfs {
            await updateStatus("Using cached runtime filesystem...")
            container = try await manager.create(
                configuration.containerName,
                image: runtimeImage,
                rootfs: cachedRootfs
            ) { runtimeConfiguration in
                runtimeConfiguration.cpus = 4
                runtimeConfiguration.memoryInBytes = Self.containerMemoryInBytes
                runtimeConfiguration.hostname = configuration.containerName
                runtimeConfiguration.mounts.append(
                    .share(
                        source: assets.userWorkspaceURL.path(percentEncoded: false),
                        destination: "/app/user"
                    )
                )

                runtimeConfiguration.process.stdout = stdoutWriter
                runtimeConfiguration.process.stderr = stderrWriter
                runtimeConfiguration.process.environmentVariables = Self.mergeEnvironmentVariables(
                    runtimeConfiguration.process.environmentVariables,
                    with: configuration.environmentVariables
                )
            }
        } else {
            try? FileManager.default.removeItem(at: containerRootURL)

            let runtimeFilesystemReporter = Self.makeProgressReporter(
                activity: "Creating runtime filesystem",
                updateStatus: updateStatus
            )
            await runtimeFilesystemReporter.reporter.reportInitialStatus()

            container = try await manager.create(
                configuration.containerName,
                image: runtimeImage,
                rootfsSizeInBytes: Self.rootFilesystemSizeInBytes,
                progress: runtimeFilesystemReporter.progressHandler
            ) { runtimeConfiguration in
                runtimeConfiguration.cpus = 4
                runtimeConfiguration.memoryInBytes = Self.containerMemoryInBytes
                runtimeConfiguration.hostname = configuration.containerName
                runtimeConfiguration.mounts.append(
                    .share(
                        source: assets.userWorkspaceURL.path(percentEncoded: false),
                        destination: "/app/user"
                    )
                )

                runtimeConfiguration.process.stdout = stdoutWriter
                runtimeConfiguration.process.stderr = stderrWriter
                runtimeConfiguration.process.environmentVariables = Self.mergeEnvironmentVariables(
                    runtimeConfiguration.process.environmentVariables,
                    with: configuration.environmentVariables
                )
            }
            await runtimeFilesystemReporter.reporter.reportCompletion()
            Self.writeRuntimeFilesystemMarker(
                for: configuration,
                at: containerRootURL
            )
        }

        await updateStatus("Starting container...")
        try await container.create()
        try await container.start()

        guard let interface = container.interfaces.first else {
            try? await container.stop()
            try? manager.delete(configuration.containerName)
            throw RuntimePreparationError.failed("The container started without a network interface.")
        }

        let endpoint = ManagedRuntimeEndpoint(
            host: interface.ipv4Address.address.description,
            port: configuration.containerPort
        )
        session = ActiveSession(
            manager: manager,
            container: container,
            containerName: configuration.containerName,
            endpoint: endpoint
        )

        return endpoint
    }

    func stop(
        containerName: String,
        assets: ContainerRuntimeAssets?
    ) async {
        let _ = assets
        guard var session, session.containerName == containerName else {
            return
        }

        try? await session.container.stop()
        try? session.manager.releaseNetwork(containerName)
        self.session = nil
    }

    nonisolated private static func containerRootURL(
        containerName: String,
        imageStoreURL: URL
    ) -> URL {
        imageStoreURL
            .appendingPathComponent("containers", isDirectory: true)
            .appendingPathComponent(containerName, isDirectory: true)
    }

    nonisolated private static func cachedRuntimeFilesystemMount(
        for configuration: ManagedContainerConfiguration,
        at containerRootURL: URL
    ) -> Mount? {
        let markerURL = containerRootURL.appendingPathComponent(imageReferenceMarkerFilename)
        let rootfsURL = containerRootURL.appendingPathComponent(rootFilesystemFilename)

        guard
            let marker = try? String(contentsOf: markerURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            marker == configuration.image,
            FileManager.default.fileExists(atPath: rootfsURL.path(percentEncoded: false))
        else {
            return nil
        }

        return .block(
            format: "ext4",
            source: rootfsURL.path(percentEncoded: false),
            destination: "/",
            options: []
        )
    }

    nonisolated private static func writeRuntimeFilesystemMarker(
        for configuration: ManagedContainerConfiguration,
        at containerRootURL: URL
    ) {
        let markerURL = containerRootURL.appendingPathComponent(imageReferenceMarkerFilename)
        try? configuration.image.write(to: markerURL, atomically: true, encoding: .utf8)
    }

    nonisolated private static func mergeEnvironmentVariables(
        _ existing: [String],
        with overrides: [String]
    ) -> [String] {
        var merged = existing

        if !merged.contains(where: { $0.hasPrefix("PATH=") }) {
            merged.insert("PATH=\(LinuxProcessConfiguration.defaultPath)", at: 0)
        }

        for override in overrides {
            let key = override.split(separator: "=", maxSplits: 1).first.map(String.init) ?? override
            merged.removeAll { candidate in
                candidate.hasPrefix("\(key)=")
            }
            merged.append(override)
        }

        return merged
    }

    nonisolated private static func makeProgressReporter(
        activity: String,
        updateStatus: @escaping @Sendable (String) async -> Void
    ) -> (reporter: ContainerOperationProgressReporter, progressHandler: ProgressHandler) {
        let reporter = ContainerOperationProgressReporter(
            activity: activity,
            statusHandler: updateStatus
        )
        let progressHandler: ProgressHandler = { events in
            await reporter.record(events: events)
        }
        return (reporter, progressHandler)
    }

    private static func fetchImage(
        reference: String,
        using imageStore: ImageStore,
        activity: String,
        updateStatus: @escaping @Sendable (String) async -> Void
    ) async throws -> Image {
        do {
            let image = try await imageStore.get(reference: reference)
            await updateStatus("Using cached \(Self.cachedActivityLabel(for: activity))...")
            return image
        } catch let error as ContainerizationError {
            guard error.code == .notFound else {
                throw error
            }
        }

        let reporter = makeProgressReporter(activity: activity, updateStatus: updateStatus)
        await reporter.reporter.reportInitialStatus()
        let image = try await imageStore.pull(
            reference: reference,
            progress: reporter.progressHandler
        )
        await reporter.reporter.reportCompletion()
        return image
    }

    nonisolated private static func cachedActivityLabel(for activity: String) -> String {
        if activity.hasPrefix("Pulling ") {
            return String(activity.dropFirst("Pulling ".count))
        }
        return activity.lowercased()
    }

    private static func prepareInitFilesystem(
        from image: Image,
        imageStore: ImageStore,
        updateStatus: @escaping @Sendable (String) async -> Void
    ) async throws -> Mount {
        let initPath = imageStore.path.appendingPathComponent("initfs.ext4")
        let initImage = InitImage(image: image)

        await updateStatus("Preparing init filesystem...")
        do {
            return try await initImage.initBlock(at: initPath, for: .linuxArm)
        } catch let error as ContainerizationError {
            guard error.code == .exists else {
                throw error
            }

            await updateStatus("Using cached init filesystem...")
            return .block(
                format: "ext4",
                source: initPath.path(percentEncoded: false),
                destination: "/",
                options: ["ro"]
            )
        }
    }
}

final class FileHandleWriter: Writer, @unchecked Sendable {
    private let lock = NSLock()
    private let fileHandle: FileHandle

    init(url: URL) throws {
        let path = url.path(percentEncoded: false)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        fileHandle = try FileHandle(forWritingTo: url)
        try fileHandle.truncate(atOffset: 0)
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: data)
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        try fileHandle.close()
    }
}

enum RuntimePreparationError: LocalizedError {
    case unsupported(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let message), .failed(let message):
            return message
        }
    }
}
