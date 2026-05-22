//
//  CritiqueReelRowView.swift
//  DrawEvolve
//
//  One row in the reel: thumbnail, drawing title / subject / date, the
//  paraphrased excerpt (falls back to deterministic raw excerpt in
//  Phase 1), and a primary-category chip. Tap target opens the
//  underlying drawing in the gallery; long-press expands the full
//  critique text inline.
//

import SwiftUI

struct CritiqueReelRowView: View {
    let row: CritiqueReelRow

    @State private var thumbnail: UIImage?
    @State private var isExpanded: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnailView
            VStack(alignment: .leading, spacing: 4) {
                titleRow
                Text(displayDate)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(formattedExcerpt)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(isExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                if let cat = row.primaryCategory {
                    Text(cat.displayName)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundStyle(Color.accentColor)
                        .cornerRadius(4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .contentShape(Rectangle())
        .onTapGesture { openDrawing() }
        .onLongPressGesture(minimumDuration: 0.4) {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        }
        .task(id: row.drawingId) {
            await loadThumbnail()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Tap to open this drawing. Long press to expand the critique.")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(uiColor: .tertiarySystemBackground))
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 80, height: 80)
    }

    private var titleRow: some View {
        Text(displayTitle)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
    }

    private var displayTitle: String {
        if let title = row.drawingTitle, !title.isEmpty { return title }
        if let subject = row.drawingSubject, !subject.isEmpty { return subject.capitalized }
        return "Untitled drawing"
    }

    private var displayDate: String {
        Self.dateFormatter.string(from: row.createdAt)
    }

    /// Phase 1 prefix per the locked design decision (overhaul proposal
    /// §7): reel excerpts read as quoted coaching ("Coach said: …").
    /// When Phase 2 ships the LLM paraphrase, the prefix wraps the
    /// paraphrased version; the raw fallback still gets the prefix so
    /// the visual rhythm is identical either way.
    private var formattedExcerpt: String {
        let body = row.displayedExcerpt
        if body.isEmpty { return "" }
        return "Coach said: \(body)"
    }

    private var accessibilityDescription: String {
        var parts: [String] = [displayTitle, displayDate]
        if let cat = row.primaryCategory {
            parts.append(cat.displayName)
        }
        parts.append(row.displayedExcerpt)
        return parts.joined(separator: ". ")
    }

    @MainActor
    private func loadThumbnail() async {
        let manager = CloudDrawingStorageManager.shared
        if let data = manager.thumbnailData(for: row.drawingId),
           let img = UIImage(data: data) {
            self.thumbnail = img
            return
        }
        // Cache miss — leave the placeholder up. The previous fallback
        // decoded the FULL-resolution composite image (16-64 MB at canvas
        // size) just to display an 80×80 tile, which blew memory on older
        // hardware whenever the thumbnail cache hadn't filled in yet.
        // The reel view's `task(id:)` re-fires when the drawing id
        // changes; the gallery's thumbnail hydration will populate the
        // shared cache eventually, and ContentView re-renders pick up
        // the new bytes via the manager's observable invalidation.
    }

    private func openDrawing() {
        // Phase 1: emit a notification the gallery host listens for so
        // the user lands on the drawing detail. Threading the
        // navigation through the gallery's existing NavigationStack
        // without a new tap target keeps the architecture honest. The
        // gallery view subscribes to this notification and pushes the
        // matching drawing.
        NotificationCenter.default.post(
            name: .evolutionOpenDrawingRequest,
            object: nil,
            userInfo: ["drawing_id": row.drawingId]
        )
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

extension Notification.Name {
    /// Fired by `CritiqueReelRowView` when the user taps a row. Listened
    /// to by the gallery host (the view that wraps the Evolution tab),
    /// which pushes the matching drawing detail onto its NavigationStack.
    static let evolutionOpenDrawingRequest = Notification.Name("DrawEvolve.evolutionOpenDrawingRequest")
}
