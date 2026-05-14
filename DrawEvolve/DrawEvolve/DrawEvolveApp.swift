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
        // Start the remote feature-flag refresher. The singleton kicks
        // off an initial fetch in its init; this turns on the hourly
        // background refresh so flag flips picked up by the
        // TestFlight cohort don't wait for an app restart.
        Task { @MainActor in
            AppFeatureFlags.shared.startAutoRefresh()
        }
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
