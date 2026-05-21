//
//  EvolutionStudioWallView.swift
//  DrawEvolve
//
//  Horizontal time-strip of a user's tagged critiques. Each critique
//  is a column:
//
//    [ thumbnail ]
//      Mon 12
//       • • •      ← colored dots, one per tagged category
//                    (primary + secondaries). Dot brightness is
//                    severity: pale = solid (low severity),
//                    saturated = needs work (high severity).
//
//  Newest is on the right, mirroring chronological reading. A row of
//  filter chips above the strip lets the user constrain to one
//  category — they scroll left→right and watch the dots fade (or
//  brighten) as the model judged that category over time. That's the
//  visualization of improvement: it's literal, not abstract.
//
//  Tap a column → CritiqueDetailSheet with the coach's full excerpt.
//

import SwiftUI

struct EvolutionStudioWallView: View {
    let critiques: [TaggedCritique]
    /// Phase 2 (canvas-overlay UX) — fired when the user taps a critique
    /// column. The parent (GalleryView shell) resolves the Drawing from
    /// the TaggedCritique.drawingId and presents DrawingCanvasView via
    /// .fullScreenCover with the matching CritiqueEntry pre-selected.
    /// Replaces the old CritiqueDetailSheet modal flow.
    let onCritiqueTap: (TaggedCritique) -> Void

    @State private var selectedCategory: CategoryID?

    /// Categories actually represented in the data set, by reverse
    /// frequency. We only show chip filters for categories that have
    /// at least 2 critiques — otherwise chips clutter the row.
    private var availableCategories: [CategoryID] {
        var counts: [CategoryID: Int] = [:]
        for c in critiques {
            for tag in c.allCategories {
                counts[tag, default: 0] += 1
            }
        }
        return counts
            .filter { $0.value >= 2 }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.stringValue < rhs.key.stringValue
            }
            .map { $0.key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Studio wall")
                    .font(.headline)
                Spacer()
                Text(headerSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !availableCategories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(
                            label: "All",
                            isSelected: selectedCategory == nil,
                            tintColor: .accentColor,
                            action: { selectedCategory = nil }
                        )
                        ForEach(availableCategories, id: \.self) { cat in
                            FilterChip(
                                label: cat.displayName,
                                isSelected: selectedCategory == cat,
                                tintColor: Self.color(for: cat),
                                action: { selectedCategory = (selectedCategory == cat ? nil : cat) }
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            if critiques.isEmpty {
                Text("Once you've gotten a few critiques, your work will appear here as a scrolling time strip.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(critiques) { c in
                            CritiqueColumn(
                                critique: c,
                                selectedCategory: selectedCategory,
                                onTap: { onCritiqueTap(c) }
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 6)
                }
                .frame(minHeight: 180)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private var headerSubtitle: String {
        let n = critiques.count
        if n == 0 { return "" }
        if n == 1 { return "1 critique" }
        return "\(n) critiques"
    }

    /// Pick a representative color per category for the dot rendering.
    /// Locked palette so the same category always reads the same color
    /// across launches and themes.
    static func color(for category: CategoryID) -> Color {
        switch category {
        case .anatomy:      return Color(red: 0.93, green: 0.34, blue: 0.42)   // coral red
        case .composition:  return Color(red: 0.36, green: 0.55, blue: 0.92)   // azure blue
        case .value:        return Color(red: 0.42, green: 0.42, blue: 0.45)   // slate gray
        case .color:        return Color(red: 1.00, green: 0.62, blue: 0.21)   // amber
        case .line:         return Color(red: 0.55, green: 0.32, blue: 0.78)   // violet
        case .perspective:  return Color(red: 0.16, green: 0.62, blue: 0.51)   // teal
        case .subjectMatch: return Color(red: 0.85, green: 0.38, blue: 0.72)   // pink
        case .general:      return Color(red: 0.50, green: 0.50, blue: 0.50)   // neutral
        case .unknown:      return Color(red: 0.40, green: 0.40, blue: 0.42)
        }
    }
}

// MARK: - Filter chip

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let tintColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? Color.white : tintColor)
                .background(
                    Capsule().fill(isSelected ? tintColor : tintColor.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Single critique column

private struct CritiqueColumn: View {
    let critique: TaggedCritique
    let selectedCategory: CategoryID?
    let onTap: () -> Void

    @State private var thumbnail: UIImage?

    private var isDimmed: Bool {
        guard let selected = selectedCategory else { return false }
        return !critique.allCategories.contains(selected)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                thumbnailView
                Text(dateLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // Phase 2 temporal cue: when the row carries a snapshot, the
                // thumbnail above is historical (drawing AT critique time).
                // The "X ago" copy makes that explicit so the user doesn't
                // expect it to match the live canvas.
                if critique.snapshot != nil {
                    Text("Snapshot · \(Self.relativeFormatter.localizedString(for: critique.createdAt, relativeTo: Date()))")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    ForEach(Array(critique.allCategories.enumerated()), id: \.offset) { _, cat in
                        Circle()
                            .fill(dotColor(for: cat))
                            .frame(width: 8, height: 8)
                            .overlay(
                                Circle().stroke(EvolutionStudioWallView.color(for: cat).opacity(0.4), lineWidth: 0.5)
                            )
                    }
                }
                .frame(minHeight: 10)
            }
            .frame(width: 96)
            .opacity(isDimmed ? 0.32 : 1.0)
        }
        .buttonStyle(.plain)
        .task(id: critique.id) { await loadThumbnail() }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(uiColor: .tertiarySystemBackground))
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if critique.snapshot != nil {
                // Snapshot exists but the thumb is still loading.
                ProgressView()
                    .controlSize(.small)
            } else {
                // No snapshot — pre-VH legacy entry or promote-failed.
                // Muted placeholder per proposal §3.3: one rule covers
                // all "no historical thumb available" cases.
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundStyle(.tertiary.opacity(0.6))
            }
        }
        .frame(width: 96, height: 96)
    }

    /// Dot color = category-coded; brightness = severity (1 → pale, 5 → saturated).
    /// Linear with a small gamma curve so high severity reads as the
    /// "loudest" without low severity becoming invisible.
    private func dotColor(for category: CategoryID) -> Color {
        let base = EvolutionStudioWallView.color(for: category)
        // severity 1 → opacity 0.30 (pale, "solid"); severity 5 → 1.0 (loud, "needs work")
        let normalized = max(0.0, min(1.0, Double(critique.severity - 1) / 4.0))
        let curved = pow(normalized, 0.85)   // mild gamma
        let opacity = 0.30 + curved * 0.70
        return base.opacity(opacity)
    }

    private var dateLabel: String {
        Self.dateFormatter.string(from: critique.createdAt)
    }

    @MainActor
    private func loadThumbnail() async {
        // Phase 2: prefer the snapshot thumb (historical) over the live
        // drawing thumb (current state). When snapshot is nil, render the
        // muted placeholder — no fallback to live state, per proposal §3.3.
        guard let snapshot = critique.snapshot else { return }
        guard let client = SupabaseManager.shared.client else { return }
        do {
            let signed = try await client.storage
                .from("drawings")
                .createSignedURL(path: snapshot.thumbPath, expiresIn: 3600)
            let (data, _) = try await URLSession.shared.data(from: signed)
            if let img = UIImage(data: data) {
                self.thumbnail = img
            }
        } catch {
            // Snapshot exists but fetch failed — keep the placeholder.
            print("[CritiqueColumn] snapshot thumb fetch failed: \(error.localizedDescription)")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
