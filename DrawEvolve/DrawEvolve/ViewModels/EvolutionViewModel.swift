//
//  EvolutionViewModel.swift
//  DrawEvolve
//
//  Single-screen view-model for EvolutionView. Owns the load lifecycle
//  (idle → loading → loaded/error) and exposes pull-to-refresh + retry
//  hooks. The Phase 2 force-refresh endpoint will be wired through this
//  same view-model; the public surface is intentionally minimal so the
//  view doesn't need to grow new bindings each phase.
//

import Foundation
import SwiftUI

@MainActor
final class EvolutionViewModel: ObservableObject {
    enum LoadState {
        case idle
        case loading
        case loaded(EvolutionFeed)
        case error(EvolutionError)
    }

    @Published private(set) var loadState: LoadState = .idle

    /// Tracks the "Refresh insights" button's optimistic state. Distinct
    /// from `loadState` because pull-to-refresh and the refresh button
    /// both spin the same network call but show different UI: PTR uses
    /// SwiftUI's built-in spinner, the button needs a localised inline
    /// indicator. Phase 1 wires the button but it just re-runs `load()`;
    /// Phase 2 will swap in `POST /v1/me/evolution/refresh`.
    @Published private(set) var isRefreshingInsights: Bool = false

    private let service: EvolutionService

    init(service: EvolutionService = .shared) {
        self.service = service
    }

    /// Idempotent load. Re-fires on appear and on pull-to-refresh. The
    /// loading state is set BEFORE awaiting so the UI updates immediately
    /// even on the second invocation.
    func load() async {
        loadState = .loading
        do {
            let feed = try await service.fetchEvolution()
            loadState = .loaded(feed)
        } catch let error as EvolutionError {
            loadState = .error(error)
        } catch {
            loadState = .error(.unknown)
        }
    }

    /// Alias for clarity at error-state retry call sites.
    func retry() async { await load() }

    /// Last refresh outcome — set by `refreshInsights()` and consumed
    /// by the view to show a toast/banner ("Backfilled 12 critiques",
    /// "Up to date", etc.). Cleared by the next refresh or load.
    @Published private(set) var lastRefreshOutcome: RefreshOutcome?

    struct RefreshOutcome: Equatable {
        let backfilled: Int
        let capReached: Bool

        var bannerText: String? {
            if backfilled == 0 { return "Already up to date." }
            let unit = backfilled == 1 ? "critique" : "critiques"
            if capReached {
                return "Tagged \(backfilled) more \(unit). Tap again to keep going."
            }
            return "Tagged \(backfilled) \(unit) from your earlier history."
        }
    }

    /// Force refresh. Calls `POST /v1/me/evolution/refresh`, which on
    /// the server classifies any pre-classifier (or classifier-failed)
    /// critiques and writes the tags back to Supabase. Then re-loads
    /// the feed from the response. Bounded server-side at ~100
    /// classifier calls per tap.
    func refreshInsights() async {
        guard !isRefreshingInsights else { return }
        isRefreshingInsights = true
        lastRefreshOutcome = nil
        defer { isRefreshingInsights = false }
        do {
            let result = try await service.refreshEvolution()
            loadState = .loaded(result.feed)
            lastRefreshOutcome = RefreshOutcome(
                backfilled: result.backfilled,
                capReached: result.capReached
            )
        } catch let error as EvolutionError {
            loadState = .error(error)
        } catch {
            loadState = .error(.unknown)
        }
    }

    /// Refresh is always available once data has loaded. The button is
    /// hidden in error / loading states because there's nothing
    /// meaningful to refresh from.
    var canRefresh: Bool {
        if case .loaded = loadState { return true }
        return false
    }

    /// Called by the view after the banner has been shown for ~3
    /// seconds. Auto-clears the toast so it doesn't linger on subsequent
    /// loads.
    func dismissRefreshOutcome() {
        lastRefreshOutcome = nil
    }
}
