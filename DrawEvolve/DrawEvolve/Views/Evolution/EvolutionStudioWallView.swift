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

    @State private var selectedCategory: CategoryID?
    @State private var detailCritique: TaggedCritique?

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
                                onTap: { detailCritique = c }
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
        .sheet(item: $detailCritique) { c in
            CritiqueDetailSheet(critique: c)
        }
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
        .task(id: critique.drawingId) { await loadThumbnail() }
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
            } else {
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        let mgr = CloudDrawingStorageManager.shared
        if let data = mgr.thumbnailData(for: critique.drawingId),
           let img = UIImage(data: data) {
            self.thumbnail = img
            return
        }
        do {
            if let data = try await mgr.loadFullImage(for: critique.drawingId),
               let img = UIImage(data: data) {
                self.thumbnail = img
            }
        } catch {
            // Placeholder photo icon already shows; silent fallthrough.
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}

// MARK: - Detail sheet

struct CritiqueDetailSheet: View {
    let critique: TaggedCritique
    @Environment(\.dismiss) private var dismiss
    @State private var thumbnail: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    thumbnailView
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayTitle)
                            .font(.title3.weight(.semibold))
                        Text(Self.dateFormatter.string(from: critique.createdAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        ForEach(critique.allCategories.indices, id: \.self) { i in
                            let cat = critique.allCategories[i]
                            Text(cat.displayName)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(EvolutionStudioWallView.color(for: cat).opacity(0.16))
                                )
                                .foregroundStyle(EvolutionStudioWallView.color(for: cat))
                        }
                    }
                    Text("Severity")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        ForEach(1...5, id: \.self) { i in
                            Capsule()
                                .fill(i <= critique.severity
                                    ? EvolutionStudioWallView.color(for: critique.primaryCategory)
                                    : Color.secondary.opacity(0.18))
                                .frame(width: 24, height: 6)
                        }
                        Text("\(critique.severity) / 5")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                    }
                    Divider()
                    Text("Coach said")
                        .font(.headline)
                    Text(critique.contentExcerpt)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .navigationTitle("Critique")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: critique.drawingId) { await loadThumbnail() }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(uiColor: .tertiarySystemBackground))
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 200, idealHeight: 260)
    }

    private var displayTitle: String {
        if let title = critique.drawingTitle, !title.isEmpty { return title }
        if let subject = critique.drawingSubject, !subject.isEmpty { return subject.capitalized }
        return "Untitled drawing"
    }

    @MainActor
    private func loadThumbnail() async {
        let mgr = CloudDrawingStorageManager.shared
        if let data = mgr.thumbnailData(for: critique.drawingId),
           let img = UIImage(data: data) {
            self.thumbnail = img
            return
        }
        do {
            if let data = try await mgr.loadFullImage(for: critique.drawingId),
               let img = UIImage(data: data) {
                self.thumbnail = img
            }
        } catch {
            // silent
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()
}
