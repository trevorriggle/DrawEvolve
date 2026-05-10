//
//  EvolutionView.swift
//  DrawEvolve
//
//  My Evolution dashboard. Lives as the body of the "My Evolution" tab in
//  GalleryView (sibling to "My Drawings" and "My Prompts"). Loads
//  GET /v1/me/evolution on appear, supports pull-to-refresh, switches
//  between four state-specific layouts.
//
//  Embeds inside GalleryView's NavigationStack — does NOT wrap itself in a
//  NavigationView/Stack. The tab strip in GalleryView is the visual title;
//  no .navigationTitle here on purpose. The example-state CTA's dismiss()
//  walks up to the gallery presentation context (a fullScreenCover from
//  DrawingCanvasView), which is the right behavior — closes the gallery
//  and returns to the canvas so the user can start drawing.
//
//  ───────────────────────────────────────────────────────────────────────
//  MANUAL SMOKE TESTS — run after each significant change to this surface
//  ───────────────────────────────────────────────────────────────────────
//  1. Build to iPad. Open the gallery, tap the "My Evolution" tab.
//  2. Confirm loading spinner appears, then content loads.
//  3. With 0 critiques: example state. example_artist_label banner reads as
//     a label (not a hero), chart populated, CTA button visible. Tap CTA →
//     gallery dismisses back to canvas.
//  4. With 1-2 critiques: early state. summary_text is the headline. No
//     chart. Warming-up may or may not appear.
//  5. With 3-9 critiques: growing state. summary_text as subhead. Chart
//     visible with categories at 2+ mentions.
//  6. With 10+ critiques: mature state. Chart dominates. summary_text small
//     caption at bottom (currently always omitted by server in mature, but
//     code handles it gracefully if it ever returns).
//  7. With network off: error state. Tap "Try again" — confirms retry path.
//  8. Pull-to-refresh from any loaded state — confirm reload.
//  9. Switch to another tab and back — confirm re-load fires (.task is
//     bound to the tab body lifetime, so each tab visit refreshes data).
//

import SwiftUI

struct EvolutionView: View {
    @StateObject private var viewModel = EvolutionViewModel()
    @Environment(\.dismiss) private var dismiss

    /// "Show preview" toggle. When on, EvolutionContentView renders the
    /// hardcoded EvolutionData.preview payload — same illustrative chart
    /// the server sends in `.example` state for accounts with zero
    /// critiques, but available on demand so users with non-zero
    /// critique history can see what the panel will look like once their
    /// data matures.
    @State private var showingPreview: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            previewToggleBar
            content
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }

    private var previewToggleBar: some View {
        HStack(spacing: 6) {
            Image(systemName: showingPreview ? "eye.fill" : "eye")
                .font(.subheadline)
                .foregroundStyle(showingPreview ? Color.accentColor : .secondary)
            Text(showingPreview ? "Showing preview" : "Show preview")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(showingPreview ? Color.accentColor : .secondary)
            Spacer()
            Toggle("", isOn: $showingPreview)
                .labelsHidden()
                .tint(.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Show preview of mature evolution state")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var content: some View {
        if showingPreview {
            // Use the live streak from real data when available so the
            // user's actual drawing/critique counts stay accurate even
            // while the rest of the panel renders preview data.
            let realStreak: StreakData? = {
                if case .loaded(let data) = viewModel.loadState { return data.streak }
                return nil
            }()
            EvolutionContentView(
                data: EvolutionData.preview(realStreak: realStreak),
                onDismiss: { dismiss() }
            )
        } else {
            loadStateView
        }
    }

    @ViewBuilder
    private var loadStateView: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            loadingView
        case .loaded(let data):
            EvolutionContentView(data: data, onDismiss: { dismiss() })
        case .error(let error):
            errorView(error)
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
        // DCAppAttestService is unsupported on simulator, so retrying loops
        // back to the same failure forever. Tell the user honestly that
        // this won't work here and hide the action button — there's no
        // useful retry to offer. The enum's default copy + retry button
        // still applies on real devices, where a retry can succeed after
        // AppAttestManager auto-recovers from DCError.invalidKey.
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
