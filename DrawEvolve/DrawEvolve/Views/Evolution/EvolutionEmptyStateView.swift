//
//  EvolutionEmptyStateView.swift
//  DrawEvolve
//
//  Zero-critique state. Replaces the v1 EvolutionEmptyStateCTA. Holds
//  the "Show preview" toggle (per locked decision §7.5: keep the
//  toggle for empty state only, drop once the user has data).
//
//  When the toggle is on, `EvolutionView` swaps in `EvolutionPanelView`
//  rendered against `EvolutionFeed.preview()`. This view is purely the
//  empty-state shell.
//

import SwiftUI

struct EvolutionEmptyStateView: View {
    @Binding var showingPreview: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 60)

            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 56))
                .foregroundStyle(.secondary.opacity(0.7))

            VStack(spacing: 8) {
                Text("Your evolution starts with one critique.")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                Text("Once you start getting AI feedback on your drawings, this panel will show your recent work, recurring themes, and what you're improving at.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)

            Button(action: onDismiss) {
                Text("Start drawing")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)

            Toggle(isOn: $showingPreview) {
                Label(
                    showingPreview ? "Showing preview" : "Show preview",
                    systemImage: showingPreview ? "eye.fill" : "eye"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(showingPreview ? Color.accentColor : .secondary)
            }
            .tint(.accentColor)
            .padding(.horizontal, 32)
            .padding(.top, 8)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }
}
