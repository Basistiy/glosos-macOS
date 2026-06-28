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
