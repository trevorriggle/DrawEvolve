//
//  EvolutionChartView.swift
//  DrawEvolve
//
//  Per-category criticality trend lines. Uses Swift Charts (iOS 16+; this
//  project's deployment target is 17.0 so the framework is unconditionally
//  available).
//
//  Color encodes status, NOT category, so the user reads the chart as
//  "what's improving / what to focus on" rather than "what's anatomy."
//
//    improving         → teal
//    current_focus     → orange
//    steady            → gray
//    solid_foundation  → green
//
//  Y-axis is fixed 0–25 (criticality range) so swings between renderings
//  don't distort by auto-scaling. X-axis labels are hidden — series indices
//  aren't user-meaningful — and the parent renders earliest_at / latest_at
//  date captions below the chart frame.
//

import SwiftUI
import Charts

struct EvolutionChartView: View {
    let categories: [CategoryData]

    var body: some View {
        if categories.isEmpty {
            placeholder
        } else {
            chart
        }
    }

    private var placeholder: some View {
        Text("No theme data yet")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 240, maxHeight: 320)
    }

    private var chart: some View {
        Chart {
            ForEach(categories) { category in
                ForEach(Array(category.series.enumerated()), id: \.offset) { index, value in
                    LineMark(
                        x: .value("Index", index),
                        y: .value("Criticality", value)
                    )
                    .foregroundStyle(by: .value("Category", category.id.displayName))
                    .interpolationMethod(.catmullRom)
                }
                if let last = category.series.last {
                    PointMark(
                        x: .value("Index", category.series.count - 1),
                        y: .value("Criticality", last)
                    )
                    .foregroundStyle(by: .value("Category", category.id.displayName))
                    .symbolSize(60)
                }
            }
        }
        .chartForegroundStyleScale(domain: chartDomain, range: chartRange)
        .chartLegend(.hidden) // legend is rendered separately by EvolutionLegendView
        .chartYScale(domain: 0...25)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 5, 10, 15, 20, 25]) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .frame(minHeight: 240, maxHeight: 320)
    }

    private var chartDomain: [String] { categories.map { $0.id.displayName } }
    private var chartRange: [Color] { categories.map { Self.color(for: $0.status) } }

    /// Status → line color. Exposed `static` so the legend uses identical
    /// values without a duplicate switch.
    static func color(for status: CategoryStatus) -> Color {
        switch status {
        case .improving:        return .teal
        case .currentFocus:     return .orange
        case .steady:           return .gray
        case .solidFoundation:  return .green
        }
    }
}

#Preview {
    EvolutionChartView(categories: [
        CategoryData(
            id: .anatomy, dataPoints: 8,
            currentValue: 2, series: [4, 4.5, 3.5, 4, 3, 2.5, 2, 2],
            status: .improving
        ),
        CategoryData(
            id: .composition, dataPoints: 7,
            currentValue: 4, series: [2, 2.5, 3, 2.5, 3.5, 4, 4],
            status: .currentFocus
        ),
        CategoryData(
            id: .value, dataPoints: 6,
            currentValue: 2.5, series: [3, 2.5, 3, 3.5, 3, 2.5],
            status: .steady
        ),
        CategoryData(
            id: .perspective, dataPoints: 5,
            currentValue: 1.5, series: [1, 1.5, 1, 1, 1.5],
            status: .solidFoundation
        ),
    ])
    .padding()
}
