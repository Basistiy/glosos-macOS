//
//  glosos_macOSApp.swift
//  glosos-macOS
//
//  Created by EV on 6/3/26.
//

import SwiftUI
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() async -> Void)?
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let onTerminate = onTerminate else { return .terminateNow }
        Task {
            await onTerminate()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct glosos_macOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var authManager = AuthManager()

    init() {
        // Disable Metal API Validation to prevent crashes with MLX Swift in Debug mode
        setenv("METAL_DEVICE_WRAPPER_TYPE", "0", 1)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(authManager: authManager)
        }
    }
}

private nonisolated final class ThreadSafeFormatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: DateFormatter

    init() {
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
    }

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }
}

private nonisolated let threadSafeFormatter = ThreadSafeFormatter()

nonisolated public func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let message = items.map { "\($0)" }.joined(separator: separator)
    if message.hasPrefix("[VoiceStop]") {
        Swift.print(message, terminator: terminator)
    } else {
        let timestamp = threadSafeFormatter.string(from: Date())
        Swift.print("[\(timestamp)] \(message)", terminator: terminator)
    }
}
