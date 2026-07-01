//
//  glosos_macOSApp.swift
//  glosos-macOS
//
//  Created by EV on 6/3/26.
//

import SwiftUI

@main
struct glosos_macOSApp: App {
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

// Global print overload to automatically append millisecond-precision timestamps to all standard print() outputs
public func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let message = items.map { "\($0)" }.joined(separator: separator)
    if message.hasPrefix("[VoiceStop]") {
        Swift.print(message, terminator: terminator)
    } else {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        Swift.print("[\(timestamp)] \(message)", terminator: terminator)
    }
}
