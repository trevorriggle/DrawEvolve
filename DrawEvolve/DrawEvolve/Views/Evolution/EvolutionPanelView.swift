//
//  EvolutionPanelView.swift
//  DrawEvolve
//
//  Populated-state composition for the v2 Evolution panel. Owns the
//  six sections from the overhaul proposal §4:
//
//    1. Header strip   — title + monthly summary
//    2. Digest + refresh — synthesized sentence (null in Phase 1) and
//                          the Refresh insights affordance
//    3. Themes card    — top 3 categories with status chips
//    4. Highlight card — conditional same-subject pair (Phase 3)
//    5. Reel           — recent critiques (hero)
//    6. Stats strip    — 2×2 footer
//
//  The chart family from v1 (EvolutionChartView, EvolutionLegendView,
//  WarmingUpRowView, StreakRowView, EvolutionContentView) is deleted —
//  this single file replaces all of them.
//
//  Private subviews are co-located rather than split into separate
//  files to keep the pbxproj footprint small (one new file = four
//  pbxproj entries per the project's convention).
//

import SwiftUI

struct EvolutionPanelView: View {
    let feed: EvolutionFeed
    let canRefresh: Bool
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderStrip(summary: feed.summary)

                // v3 — Skill Radar (compact) + Studio Wall (hero).
                // The radar shows shape change ("Then vs Now"); the
                // wall shows the journey. Together they replace the
                // v2 reel + themes + highlight stack with a real
                // visualization of improvement.
                EvolutionSkillRadarView(critiques: feed.taggedCritiques)

                EvolutionStudioWallView(critiques: feed.taggedCritiques)

                StatsStrip(stats: feed.stats)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }
}

// MARK: - Header strip

private struct HeaderStrip: View {
    let summary: EvolutionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("My Evolution")
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
            Text(line1)
                .font(.subheadline)
                .foregroundStyle(.primary)
            if let l2 = line2 {
                Text(l2)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var line1: String {
        let n = summary.drawingsThisMonth
        switch n {
        case 0: return "You haven't drawn anything in the last month."
        case 1: return "You drew 1 thing this month."
        default: return "You drew \(n) things this month."
        }
    }

    private var line2: String? {
        let critiques = summary.critiquesThisMonth
        if critiques == 0 && summary.topSubjects.isEmpty { return nil }
        let critiquePart: String
        if critiques == 0 {
            critiquePart = "No critiques yet this month"
        } else if critiques == 1 {
            critiquePart = "1 critique"
        } else {
            critiquePart = "\(critiques) critiques"
        }
        if summary.topSubjects.isEmpty {
            return critiquePart + "."
        }
        return "\(critiquePart) across \(joinedSubjects)."
    }

    private var joinedSubjects: String {
        let s = summary.topSubjects
        if s.count == 1 { return s[0] }
        if s.count == 2 { return "\(s[0]) and \(s[1])" }
        return "\(s.prefix(s.count - 1).joined(separator: ", ")), and \(s.last!)"
    }
}

// MARK: - Digest + refresh

private struct DigestSection: View {
    let digestSentence: String?
    let insightsLastUpdatedAt: Date?
    let canRefresh: Bool
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = digestSentence, !s.isEmpty {
                Text(s)
                    .font(.body)
                    .foregroundStyle(.primary)
            } else {
                // Phase 1: no synthesis yet. The button still renders
                // below with disabled affordance so the user sees the
                // shape of what's coming.
                Text("Insights coming soon.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                // iOS 17 deployment target — no .symbolEffect(.rotate)
                // available (it landed in iOS 18). Swap the icon shape
                // instead of animating: the "Refreshing…" text label
                // below is the primary spinner-equivalent affordance.
                Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(canRefresh ? Color.accentColor : .secondary)
                Text(buttonLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(canRefresh ? Color.accentColor : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(canRefresh ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.08))
            )
            .contentShape(Capsule())
            .onTapGesture {
                guard canRefresh, !isRefreshing else { return }
                onRefresh()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(canRefresh ? "Refresh insights" : "Insights coming soon")
            .accessibilityAddTraits(canRefresh ? .isButton : [])
        }
    }

    private var buttonLabel: String {
        if !canRefresh { return "Insights coming soon" }
        if isRefreshing { return "Refreshing…" }
        guard let ts = insightsLastUpdatedAt else { return "Refresh insights" }
        return "Updated \(Self.relativeFormatter.localizedString(for: ts, relativeTo: Date())) · Refresh"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

// MARK: - Themes card

private struct ThemesCard: View {
    let themes: [EvolutionTheme]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Themes")
                .font(.headline)
                .foregroundStyle(.primary)
            VStack(spacing: 10) {
                ForEach(themes) { theme in
                    ThemeRow(theme: theme)
                }
            }
        }
    }
}

private struct ThemeRow: View {
    let theme: EvolutionTheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Status accent — single color bar on the leading edge of
            // the row. Drives the "current focus / improving / steady /
            // solid foundation" semantic without leaning on a chart.
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(theme.categoryId.displayName)
                        .font(.subheadline.weight(.semibold))
                    if let chip = statusChip {
                        Text(chip)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(accentColor.opacity(0.18))
                            .foregroundStyle(accentColor)
                            .cornerRadius(4)
                    }
                }
                Text(theme.synthesis)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusChip: String? {
        switch theme.status {
        case .currentFocus: return "Current focus"
        case .improving: return "Improving"
        case .steady: return "Steady"
        case .solidFoundation: return "Solid foundation"
        case .none: return nil
        }
    }

    private var accentColor: Color {
        switch theme.status {
        case .currentFocus: return .orange
        case .improving: return .teal
        case .steady: return .gray
        case .solidFoundation: return .green
        case .none: return .secondary
        }
    }
}

// MARK: - Highlight card (Phase 3 — null in Phase 1)

private struct HighlightCard: View {
    let highlight: EvolutionHighlight

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Then & now — \(highlight.subject)")
                .font(.headline)
                .foregroundStyle(.primary)
            HStack(spacing: 12) {
                HighlightThumbnail(drawingId: highlight.earliest.drawingId, label: "Then")
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                HighlightThumbnail(drawingId: highlight.latest.drawingId, label: "Now")
            }
            Text(highlight.deltaSentence)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }
}

private struct HighlightThumbnail: View {
    let drawingId: UUID
    let label: String

    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(uiColor: .tertiarySystemBackground))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    ProgressView()
                }
            }
            .frame(width: 120, height: 120)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .task(id: drawingId) {
            if let data = CloudDrawingStorageManager.shared.thumbnailData(for: drawingId),
               let ui = UIImage(data: data) {
                self.image = ui
            }
        }
    }
}

// MARK: - Reel

private struct ReelSection: View {
    let rows: [CritiqueReelRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent critiques")
                .font(.headline)
                .foregroundStyle(.primary)
            LazyVStack(spacing: 12) {
                ForEach(rows) { row in
                    CritiqueReelRowView(row: row)
                }
            }
        }
    }
}

// MARK: - Stats strip

private struct StatsStrip: View {
    let stats: EvolutionStats

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By the numbers")
                .font(.headline)
                .foregroundStyle(.primary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatCell(label: "Total critiques", value: "\(stats.totalCritiques)")
                StatCell(label: "Most discussed", value: stats.mostDiscussedCategory?.displayName ?? "—")
                StatCell(label: "Most improved", value: stats.mostImprovedCategory?.displayName ?? "—")
                StatCell(label: "Current focus", value: stats.currentFocusArea ?? "—")
            }
        }
        .padding(.top, 4)
    }
}

private struct StatCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }
}
