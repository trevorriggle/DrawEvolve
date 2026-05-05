//
//  EvolutionLegendView.swift
//  DrawEvolve
//
//  Compact legend. One row per category: colored swatch + display name +
//  status label + current score. Tappable rows / drill-down are explicitly
//  out of scope for v1 — the legend is read-only.
//
//  Layout:    ●  Anatomy — Improving · 2.0
//

import SwiftUI

struct EvolutionLegendView: View {
    let categories: [CategoryData]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(categories) { category in
                row(category)
            }
        }
    }

    private func row(_ category: CategoryData) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(EvolutionChartView.color(for: category.status))
                .frame(width: 10, height: 10)
            Text(category.id.displayName)
                .font(.subheadline)
                .fontWeight(.medium)
            Text("— \(Self.label(for: category.status))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(Self.formatScore(category.currentValue))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private static func label(for status: CategoryStatus) -> String {
        switch status {
        case .improving:        return "Improving"
        case .currentFocus:     return "Current focus"
        case .steady:           return "Steady"
        case .solidFoundation:  return "Solid foundation"
        }
    }

    private static func formatScore(_ value: Double) -> String {
        // Server emits whole-number severities for primary mentions and
        // 0.5 increments for secondary mentions. One decimal is enough
        // resolution and never shows trailing zeros.
        if value.rounded() == value { return String(format: "%.0f", value) }
        return String(format: "%.1f", value)
    }
}

#Preview {
    EvolutionLegendView(categories: [
        CategoryData(id: .anatomy, dataPoints: 8, currentValue: 2,
                     series: [4, 4.5, 3.5, 4, 3, 2.5, 2, 2], status: .improving),
        CategoryData(id: .composition, dataPoints: 7, currentValue: 4,
                     series: [2, 2.5, 3, 2.5, 3.5, 4, 4], status: .currentFocus),
        CategoryData(id: .perspective, dataPoints: 5, currentValue: 1.5,
                     series: [1, 1.5, 1, 1, 1.5], status: .solidFoundation),
    ])
    .padding()
}
