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

    /// User tapped "Refresh insights". Phase 1: just re-runs `load()`
    /// (cache invalidation is server-side once Phase 2 lands; for now
    /// the worker re-aggregates from DB every call, so this is honest).
    /// The button stays present but visually disabled (`canRefresh ==
    /// false`) when there's no LLM-synthesized content to refresh,
    /// avoiding the wrong promise.
    func refreshInsights() async {
        guard !isRefreshingInsights else { return }
        isRefreshingInsights = true
        defer { isRefreshingInsights = false }
        await load()
    }

    /// Phase 1: the button shows but is disabled. Once Phase 2 wires
    /// gpt-5.1-mini synthesis behind a 24h cache, this gates on whether
    /// there's anything to refresh (digest_sentence non-null OR themes
    /// non-empty OR highlight non-null). Today nothing is LLM-synthesized,
    /// so the button is always disabled with the "coming soon" subtitle.
    var canRefresh: Bool {
        guard case .loaded(let feed) = loadState else { return false }
        if feed.digestSentence != nil { return true }
        if !feed.themes.isEmpty && feed.themes.contains(where: { $0.synthesis.isEmpty == false }) {
            // Phase 1 ships deterministic theme synthesis ("N recent
            // critiques touched on anatomy.") which technically counts;
            // gate on whether the worker has populated
            // insightsLastUpdatedAt to distinguish "real synthesis"
            // from "placeholder synthesis."
            if feed.summary.insightsLastUpdatedAt != nil { return true }
        }
        if feed.highlight != nil { return true }
        return false
    }
}
