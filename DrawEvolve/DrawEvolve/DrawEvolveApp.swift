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
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Initialize crash reporting + boot the auth state listener early.
        _ = CrashReporter.shared
        _ = AuthManager.shared
        // The feature-flag singleton kicks off an initial fetch in its
        // init. Subsequent refreshes are driven by scenePhase below —
        // we used to run a 1h timer-loop, but it wakes the radio even
        // when the app is backgrounded for days, which adds up.
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authManager)
                .onOpenURL { url in
                    Task { await authManager.handleDeepLink(url) }
                }
                // Lock the app to light mode by default. The canvas
                // attaches its own .preferredColorScheme based on the
                // user's saved preference, which takes precedence on
                // that screen — this default just covers everywhere
                // else (launch, auth gate, gallery, prompt) so iPads
                // running system-wide dark mode don't come up dark.
                .preferredColorScheme(.light)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Refresh remote feature flags whenever the app becomes
            // active. Throttled internally (5 min) so rapid toggling
            // doesn't fan out into a stream of network calls.
            if newPhase == .active {
                Task { @MainActor in
                    await AppFeatureFlags.shared.refreshOnForegroundIfStale()
                }
            }
        }
    }
}
