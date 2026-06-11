//
//  GhostAnnotationOverlay.swift
//  DrawEvolve
//
//  Ghost layer — renders a critique's grounded annotations as toggleable
//  markers over the live canvas. Each CritiqueAnnotation is a normalized
//  circular region (x, y, radius in 0..1 image space) the Worker's
//  annotator tied to a concrete critique point; here it becomes a dashed
//  region circle + numbered badge. Tapping a badge shows the annotation's
//  label and critique excerpt in a callout; tapping again dismisses it.
//
//  Coordinate path: normalized → document pixels (× documentSize) →
//  screen via documentToScreen, so markers ride canvas zoom / pan /
//  rotation / keyboard-avoidance exactly like every other doc-space
//  overlay. The region circle and callout are hit-test transparent —
//  only the small numbered badge is tappable, so drawing through and
//  around the ghosts keeps working.
//
//  v1 scope: markers render for the LATEST critique over the live canvas
//  only. Historical snapshot viewing skips them — the snapshot overlay
//  letterboxes with its own fit math, not the canvas transform, and
//  mapping into that rect is a v1.1 follow-up.
//

import SwiftUI

struct GhostAnnotationOverlay: View {
    @ObservedObject var canvasState: CanvasStateManager
    let annotations: [CritiqueAnnotation]

    /// id of the annotation whose callout is open. One at a time — these
    /// are reading aids, not a forest of bubbles.
    @State private var selectedID: String? = nil

    var body: some View {
        ZStack {
            ForEach(Array(annotations.enumerated()), id: \.element.id) { index, annotation in
                marker(index: index, annotation: annotation)
            }
        }
    }

    @ViewBuilder
    private func marker(index: Int, annotation: CritiqueAnnotation) -> some View {
        let docSize = canvasState.documentSize
        let docPoint = CGPoint(x: annotation.x * docSize.width,
                               y: annotation.y * docSize.height)
        let center = canvasState.documentToScreen(docPoint)
        // Radius is normalized to the image's max dimension; project a
        // doc-space horizontal segment of that length to get the screen
        // radius under the current zoom (rotation preserves length).
        let radiusDoc = annotation.radius * max(docSize.width, docSize.height)
        let edge = canvasState.documentToScreen(CGPoint(x: docPoint.x + radiusDoc, y: docPoint.y))
        let radiusScreen = max(12, hypot(edge.x - center.x, edge.y - center.y))
        let badgeCenter = CGPoint(x: center.x, y: center.y - radiusScreen)

        // Region circle — dashed, ghost-translucent, never hit-testable.
        Circle()
            .stroke(
                Color.accentColor.opacity(0.75),
                style: StrokeStyle(lineWidth: 2, dash: [7, 5])
            )
            .background(Circle().fill(Color.accentColor.opacity(0.08)))
            .frame(width: radiusScreen * 2, height: radiusScreen * 2)
            .position(center)
            .allowsHitTesting(false)

        // Numbered badge at the region's top edge — the one tappable bit.
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedID = (selectedID == annotation.id) ? nil : annotation.id
            }
        } label: {
            Text("\(index + 1)")
                .font(.footnote.weight(.bold))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor))
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        }
        .position(badgeCenter)

        if selectedID == annotation.id {
            callout(for: annotation, above: badgeCenter)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private func callout(for annotation: CritiqueAnnotation, above badgeCenter: CGPoint) -> some View {
        let maxWidth: CGFloat = 280
        // Clamp the callout's center so it stays on-screen near edges.
        let screen = canvasState.screenSize
        let x = min(max(badgeCenter.x, maxWidth / 2 + 12),
                    max(screen.width - maxWidth / 2 - 12, maxWidth / 2 + 12))
        let y = max(badgeCenter.y - 64, 60)

        VStack(alignment: .leading, spacing: 4) {
            Text(annotation.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            if let excerpt = annotation.excerpt, !excerpt.isEmpty {
                Text("“\(excerpt)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .position(x: x, y: y)
    }
}

/// Floating chip that toggles the ghost layer — "N pointers" with an eye.
/// Mounted by DrawingCanvasView whenever the active critique carries
/// annotations, regardless of visibility state, so toggling back ON is
/// always one tap (the "easy toggle off" requirement cuts both ways).
struct GhostLayerToggleChip: View {
    let count: Int
    @Binding var isVisible: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isVisible.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isVisible ? "eye.fill" : "eye.slash")
                    .font(.caption.weight(.semibold))
                Text(isVisible ? "\(count) pointer\(count == 1 ? "" : "s")" : "Pointers off")
                    .font(.caption.weight(.medium))
            }
            .foregroundColor(isVisible ? .accentColor : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(.regularMaterial))
            .overlay(
                Capsule().stroke(
                    (isVisible ? Color.accentColor : Color.secondary).opacity(0.35),
                    lineWidth: 1
                )
            )
            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        }
        .accessibilityLabel(isVisible ? "Hide critique pointers" : "Show critique pointers")
    }
}
