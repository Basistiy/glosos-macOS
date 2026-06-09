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

    var body: some Scene {
        WindowGroup {
            ContentView(authManager: authManager)
        }
    }
}
