//
//  DrawEvolveApp.swift
//  DrawEvolve
//
//  App entry point.
//

import SwiftUI

@main
struct DrawEvolveApp: App {
    @StateObject private var authManager = AuthManager.shared

    init() {
        // Initialize crash reporting + boot the auth state listener early.
        _ = CrashReporter.shared
        _ = AuthManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authManager)
                .onOpenURL { url in
                    Task { await authManager.handleDeepLink(url) }
                }
        }
    }
}
