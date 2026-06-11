//
//  DrawEvolveApp.swift
//  DrawEvolve
//
//  App entry point.
//

import SwiftUI

/// Debug-only console logging. `print` is synchronous, unbuffered I/O —
/// at the volume this codebase logs (hundreds of lines per drawing
/// session), it's measurable battery/CPU on Release builds and exposes
/// internal state to the device syslog. All diagnostic call sites route
/// through here (2026-06-11 perf pass); the body compiles to nothing in
/// Release. Variadic args still evaluate in Release — acceptable, the
/// dominant cost is the I/O — so keep anything EXPENSIVE (big string
/// dumps, image describes) behind an explicit `#if DEBUG` block instead.
@inline(__always)
func dbgLog(_ items: Any...) {
    #if DEBUG
    print(items.map { "\($0)" }.joined(separator: " "))
    #endif
}

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
            //
            // Also kick a pending-upload sweep here (slice 3 of the
            // durability rework). Launch + reachability-restored sweeps
            // already exist; foreground is the missing third trigger.
            // Idempotent — retryPendingUploads skips drawings with an
            // already-running task and honors per-drawing backoff.
            if newPhase == .active {
                Task { @MainActor in
                    await AppFeatureFlags.shared.refreshOnForegroundIfStale()
                    await CloudDrawingStorageManager.shared.resumePendingUploads()
                }
            }
        }
    }
}
