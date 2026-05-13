//
//  RecommendationsView.swift
//  DrawEvolve
//
//  Phase 4 — full 5-up recommendations sheet. Presented as a sheet on
//  iPhone and a popover (via .sheet too, with .formSheet detent on iPad
//  for now to keep this PR focused — promote to a true UIPopover if
//  the inline-attached presentation feels off in QA).
//
//  Two callers:
//    1. PromptInputView's "See suggestions" tap — onPick sets the
//       binding-backed context.subject (and .focus) and dismisses.
//    2. Evolution's "Recommended next" → "See all 5" affordance — same
//       sheet, same onPick callback path.
//
//  Lifecycle: fetches on .task. No client-side caching — each
//  presentation re-rolls. If the user dismisses + reopens, they get
//  a fresh set (the worker's coaching context picks up any new
//  drawings/critiques in the meantime).
//

import SwiftUI

struct RecommendationsView: View {
    /// Called when the user taps a recommendation card. The parent is
    /// responsible for applying it (pre-filling the canvas setup form)
    /// and for dismissing this sheet.
    var onPick: (Recommendation) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var recommendations: [Recommendation] = []
    @State private var loadState: LoadState = .idle

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(message: String)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Suggested subjects")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task {
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle, .loading:
            loadingState
        case .failed(let message):
            failedState(message: message)
        case .loaded:
            loadedState
        }
    }

    private var loadingState: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Finding subjects that fit your work…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    private func failedState(message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Try again") {
                Task { await load() }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    private var loadedState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Tap one to start a new drawing with the subject pre-filled.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                VStack(spacing: 10) {
                    ForEach(recommendations) { rec in
                        RecommendationCard(
                            recommendation: rec,
                            onTap: { onPick(rec) },
                            style: .full,
                        )
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func load() async {
        if loadState == .loading { return }
        loadState = .loading
        do {
            let response = try await RecommendationsService.shared.fetchRecommendations()
            self.recommendations = response.recommendations
            self.loadState = .loaded
        } catch let err as RecommendationsServiceError {
            self.loadState = .failed(message: err.errorDescription
                ?? "Couldn't load suggestions right now.")
        } catch {
            self.loadState = .failed(message: "Couldn't load suggestions right now.")
        }
    }
}
