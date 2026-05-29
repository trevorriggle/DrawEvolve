//
//  EvolutionView.swift
//  DrawEvolve
//
//  My Evolution dashboard (v2 — Phase 1 of the overhaul). Lives as the
//  body of the "My Evolution" tab in GalleryView (sibling to "My
//  Drawings" and "My Prompts"). Loads `GET /v1/me/evolution` on appear,
//  supports pull-to-refresh.
//
//  v2 collapses the four-state chart-based panel (example / early /
//  growing / mature) to two states: empty (no critiques) and populated.
//  Empty users see `EvolutionEmptyStateView` with an optional "Show
//  preview" toggle; populated users see `EvolutionPanelView`. The state
//  enum and the chart family from v1 are gone.
//
//  Embeds inside GalleryView's NavigationStack — does NOT wrap itself
//  in a NavigationView/Stack. The tab strip in GalleryView is the
//  visual title; no .navigationTitle here on purpose. The empty-state
//  "Start drawing" CTA's dismiss() walks up to the gallery presentation
//  context (a fullScreenCover from DrawingCanvasView), which closes the
//  gallery and returns to the canvas.
//

import SwiftUI

struct EvolutionView: View {
    @StateObject private var viewModel = EvolutionViewModel()
    @Environment(\.dismiss) private var dismiss

    /// "Show preview" toggle. Surfaced only in the empty state per
    /// the locked decision (overhaul proposal §7.5). When on, the
    /// populated panel renders `EvolutionFeed.preview()`.
    @State private var showingPreview: Bool = false

    /// Phase 4 — Subject Recommendations. When the user taps a card in
    /// the "Recommended next" section (rendered inside EvolutionPanelView),
    /// this callback fires with the picked recommendation. The parent
    /// (GalleryView via GalleryContent) handles routing — typically by
    /// pre-filling drawingContext + presenting the PromptInputView cover.
    /// Optional so existing callers without recommendations wiring still
    /// compile and run (Evolution still works without it).
    var onUseRecommendation: ((Recommendation) -> Void)? = nil

    /// Drawing version history phase 2 — fires when the user taps a
    /// critique column in the Studio Wall (inside EvolutionPanelView).
    /// Bubbles up to the GalleryView shell, which presents
    /// DrawingCanvasView via .fullScreenCover with the entry pre-selected.
    var onCritiqueTap: ((TaggedCritique) -> Void)? = nil

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                switch viewModel.loadState {
                case .idle, .loading:
                    loadingView
                case .loaded(let feed):
                    loadedView(feed)
                case .error(let error):
                    errorView(error)
                }
            }
            // Toast banner for refresh outcome ("Tagged N critiques",
            // "Already up to date"). Auto-dismisses after 3 seconds via
            // the .onChange handler below.
            if let outcome = viewModel.lastRefreshOutcome, let text = outcome.bannerText {
                refreshBanner(text)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .onChange(of: viewModel.lastRefreshOutcome) { _, new in
            guard new != nil else { return }
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run {
                    withAnimation { viewModel.dismissRefreshOutcome() }
                }
            }
        }
    }

    private func refreshBanner(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.accentColor))
            .padding(.top, 8)
    }

    /// Broadest "this user has real evolution data worth showing" signal.
    /// Render the panel whenever ANY of these holds and let each section
    /// (header, radar, wall, stats) handle its own empty sub-state. The old
    /// gate keyed off `feed.reel` — the deprecated v2 field the v3 worker
    /// leaves unpopulated — so healthy v3 data fell through to the empty
    /// state. `totalCritiques > 0` also keeps the panel (and its Refresh
    /// button) reachable when the classifier missed some critiques, which
    /// is exactly how the user backfills the missing tags.
    private func feedHasContent(_ feed: EvolutionFeed) -> Bool {
        feed.stats.totalCritiques > 0
            || !feed.taggedCritiques.isEmpty
            || feed.summary.drawingsThisMonth > 0
            || feed.summary.critiquesThisMonth > 0
    }

    @ViewBuilder
    private func loadedView(_ feed: EvolutionFeed) -> some View {
        if !feedHasContent(feed) && !showingPreview {
            EvolutionEmptyStateView(
                showingPreview: $showingPreview,
                onDismiss: { dismiss() }
            )
        } else {
            EvolutionPanelView(
                feed: showingPreview ? .preview() : feed,
                canRefresh: showingPreview ? false : viewModel.canRefresh,
                isRefreshing: viewModel.isRefreshingInsights,
                onRefresh: {
                    Task { await viewModel.refreshInsights() }
                },
                onUseRecommendation: onUseRecommendation,
                onCritiqueTap: onCritiqueTap
            )
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading your evolution")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: EvolutionError) -> some View {
        // Simulator-specific override for .deviceVerificationFailed only:
        // DCAppAttestService is unsupported on simulator, so retrying
        // loops back to the same failure forever. Tell the user honestly
        // that this won't work here and hide the action button.
        let isSimulatorDeviceVerification: Bool = {
            #if targetEnvironment(simulator)
            return error == .deviceVerificationFailed
            #else
            return false
            #endif
        }()

        let message: String = isSimulatorDeviceVerification
            ? "Device verification can't run in the simulator. Try on a device."
            : error.userFacingMessage

        return VStack(spacing: 16) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if !isSimulatorDeviceVerification {
                Button(action: { Task { await viewModel.retry() } }) {
                    Text(error == .notAuthenticated ? "Sign Out" : "Try again")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    NavigationStack { EvolutionView() }
}
