//
//  EvolutionContentView.swift
//  DrawEvolve
//
//  Renders an EvolutionData payload by branching on `state`. The streak
//  row is shared across all four states (Zone 1); Zone 2 (Themes) is
//  state-specific. Zone 3 (Arc) is intentionally not implemented in v1.
//
//  Visual hierarchy per state — locked design:
//
//    .example  → streak → subtle banner with example_artist_label →
//                chart → window dates → legend → warming-up → CTA
//    .early    → streak → summary_text AS HEADLINE → warming-up
//    .growing  → streak → summary_text AS SUBHEAD → chart →
//                window dates → legend → warming-up
//    .mature   → streak → chart → window dates → legend → warming-up →
//                summary_text AS FOOTNOTE (only if present; currently
//                always omitted by the server in mature state)
//
//  Why summary placement varies: the data carries the message in
//  growing/mature; in early there is no chart so the prose IS the message.
//

import SwiftUI

struct EvolutionContentView: View {
    let data: EvolutionData
    let onDismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StreakRowView(streak: data.streak)
                zoneTwo
                // TODO(arc-v2): Zone 3 — narrative arc / longer-term reflection.
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var zoneTwo: some View {
        switch data.state {
        case .example:  exampleZone
        case .early:    earlyZone
        case .growing:  growingZone
        case .mature:   matureZone
        }
    }

    // MARK: - Example

    private var exampleZone: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Themes")
            if let label = data.exampleArtistLabel {
                exampleBanner(label)
            }
            EvolutionChartView(categories: data.categories)
            windowDateCaptions
            EvolutionLegendView(categories: data.categories)
            WarmingUpRowView(items: data.warmingUp)
            EvolutionEmptyStateCTA(onTap: onDismiss)
                .padding(.top, 8)
        }
    }

    /// Subtle banner. NOT a hero element — the chart is the hero. Small icon
    /// + label text on a secondary background, modest padding. Reads as a
    /// system-style "this is illustrative" hint rather than a colored card.
    private func exampleBanner(_ label: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Early

    private var earlyZone: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let summary = data.summaryText {
                Text(summary)
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WarmingUpRowView(items: data.warmingUp)
        }
    }

    // MARK: - Growing

    private var growingZone: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Themes")
            if let summary = data.summaryText {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            EvolutionChartView(categories: data.categories)
            windowDateCaptions
            EvolutionLegendView(categories: data.categories)
            WarmingUpRowView(items: data.warmingUp)
        }
    }

    // MARK: - Mature

    private var matureZone: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Themes")
            EvolutionChartView(categories: data.categories)
            windowDateCaptions
            EvolutionLegendView(categories: data.categories)
            WarmingUpRowView(items: data.warmingUp)
            if let summary = data.summaryText {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Shared chrome

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2)
            .tracking(1.0)
            .foregroundStyle(.secondary)
    }

    /// Window dates positioned at the chart's left/right edges. The chart
    /// itself hides x-axis labels (indices aren't meaningful) — these
    /// captions give the user the time range without cluttering the chart
    /// with per-tick dates we don't actually have.
    @ViewBuilder
    private var windowDateCaptions: some View {
        HStack {
            Text(formattedDate(data.window.earliestAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formattedDate(data.window.latestAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
