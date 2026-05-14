//
//  AppFeatureFlags.swift
//  DrawEvolve
//
//  Remote-configurable feature flags backed by the public.feature_flags
//  Supabase table (migration 0014). The iOS app polls at launch and on
//  a slow timer, caches the last-known state in UserDefaults, and fails
//  closed (unknown / never-fetched flags read as false).
//
//  Flip a flag at runtime via the Supabase SQL editor:
//
//      update public.feature_flags set enabled = true where flag_name = 'eye_test_panel';
//
//  Clients pick up the change on their next refresh tick (default
//  every hour, plus on every app foreground via app-lifecycle hook).
//  Worst-case latency is one refresh window.
//
//  Treat this as a kill switch, not a release-orchestration tool —
//  flag flips are best-effort cache-invalidated; there's no push
//  channel from server to client.
//

import Combine
import Foundation
import Supabase

/// Canonical flag names. Centralized so misspellings fail at compile.
enum FeatureFlagName {
    /// Gates the entire Composition / "Eye Test" panel surface —
    /// button visibility, panel sheet, on-canvas overlay. Both this
    /// flag and `eyeTestEveIntegration` default off for general
    /// release per the beta-only-first policy.
    static let eyeTestPanel = "eye_test_panel"

    /// Gates whether Composition findings flow into the critique
    /// pipeline and Eve's coaching context. Independent of the panel
    /// flag — the panel can be on while Eve integration stays off
    /// until panel data justifies enabling it. Set independently in
    /// the feature_flags table.
    static let eyeTestEveIntegration = "eye_test_eve_integration"
}

@MainActor
final class AppFeatureFlags: ObservableObject {
    static let shared = AppFeatureFlags()

    @Published private(set) var flags: [String: Bool] = [:]
    @Published private(set) var lastRefreshAt: Date?

    /// UserDefaults key for the persisted snapshot. Bumped if the
    /// stored encoding ever changes (currently a plain [String: Bool]).
    private let defaultsKey = "AppFeatureFlags.cachedFlags.v1"

    /// Periodic refresh task lifetime. Owned by the singleton — there's
    /// no deinit path in practice.
    private var refreshTask: Task<Void, Never>?

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let cached = try? JSONDecoder().decode([String: Bool].self, from: data) {
            self.flags = cached
        }
        // Kick off an initial fetch in the background. Auto-refresh
        // is started explicitly via `startAutoRefresh()` from the
        // app entry point so launch sequencing stays explicit.
        Task { [weak self] in await self?.refresh() }
    }

    /// True iff the named flag has been fetched and is enabled.
    /// Fails closed for unknown / unfetched flags.
    func isEnabled(_ flagName: String) -> Bool {
        return flags[flagName] ?? false
    }

    /// Fetch the latest flag state from Supabase. Keeps the previous
    /// cache on error — fail closed is per-flag (unknown → false),
    /// not blow-away-everything-on-network-blip.
    func refresh() async {
        guard let client = SupabaseManager.shared.client else {
            #if DEBUG
            print("[AppFeatureFlags] no Supabase client — keeping cached flags")
            #endif
            return
        }
        do {
            struct Row: Decodable {
                let flag_name: String
                let enabled: Bool
            }
            let rows: [Row] = try await client
                .from("feature_flags")
                .select("flag_name,enabled")
                .execute()
                .value

            var next: [String: Bool] = [:]
            for row in rows {
                next[row.flag_name] = row.enabled
            }
            self.flags = next
            self.lastRefreshAt = Date()
            if let data = try? JSONEncoder().encode(next) {
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }
            #if DEBUG
            print("[AppFeatureFlags] refreshed: \(next)")
            #endif
        } catch {
            #if DEBUG
            print("[AppFeatureFlags] refresh failed: \(error.localizedDescription)")
            #endif
            // Keep cached flags — fail closed handled per-key in isEnabled.
        }
    }

    /// Start periodic background refresh. Call once from app entry.
    /// Subsequent calls cancel the previous task; idempotent.
    func startAutoRefresh(interval: TimeInterval = 3600) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let seconds = max(interval, 60)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }
}
