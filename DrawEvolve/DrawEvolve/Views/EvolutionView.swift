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

    var body: some View {
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
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }

    @ViewBuilder
    private func loadedView(_ feed: EvolutionFeed) -> some View {
        if feed.reel.isEmpty && !showingPreview {
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
                }
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
