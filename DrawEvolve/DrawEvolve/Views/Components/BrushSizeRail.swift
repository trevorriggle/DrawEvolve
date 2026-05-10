//
//  BrushSizeRail.swift
//  DrawEvolve
//
//  Procreate-style vertical brush-size slider. Lives in the canvas's
//  right-side floating chrome above Save / Get Feedback so the user
//  can change brush size without opening the Brush Properties sheet.
//
//  Bound directly to `CanvasStateManager.brushSettings.size`. Affects
//  every stamp-using tool (brush / eraser / blur / smudge / line /
//  rectangle / circle); other tools (fill, eyedropper, select, text,
//  move, blurAdjustment, pose) ignore the value, so adjusting the
//  rail while one of those is active just stores the size for next
//  time a stamp tool runs.
//

import SwiftUI

struct BrushSizeRail: View {
    @Binding var size: CGFloat
    /// Matches the range surfaced in `BrushSettingsView` (1...200) so the
    /// rail and the full panel agree on bounds.
    var range: ClosedRange<CGFloat> = 1...200

    /// True while the user is actively dragging — fades in the readout
    /// bubble that shows the live numeric size.
    @State private var isDragging = false

    private static let railWidth: CGFloat = 6
    private static let knobDiameter: CGFloat = 22
    private static let containerWidth: CGFloat = 36
    private static let containerHeight: CGFloat = 200
    /// Padding from the top/bottom edges of the container to the knob's
    /// extreme positions. Prevents the knob from clipping the rounded
    /// container corners.
    private static let trackInset: CGFloat = Self.knobDiameter / 2 + 4

    var body: some View {
        ZStack(alignment: .top) {
            container

            GeometryReader { proxy in
                let trackHeight = proxy.size.height - 2 * Self.trackInset
                let knobY = knobYOffset(in: trackHeight) + Self.trackInset

                // Background rail
                Capsule()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: Self.railWidth, height: trackHeight)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                // Filled portion (bottom up — bigger size = more fill)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(
                        width: Self.railWidth,
                        height: trackHeight - (knobY - Self.trackInset)
                    )
                    .position(
                        x: proxy.size.width / 2,
                        y: (proxy.size.height + knobY) / 2
                    )

                // Knob
                Circle()
                    .fill(Color.accentColor)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                    .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                    .position(x: proxy.size.width / 2, y: knobY)

                // Numeric readout bubble — appears next to the knob while
                // dragging so the user sees the exact size without
                // opening Brush Properties.
                if isDragging {
                    Text("\(Int(size)) px")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.78))
                        .clipShape(Capsule())
                        .position(x: -28, y: knobY)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
        }
        .frame(width: Self.containerWidth, height: Self.containerHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Brush size")
        .accessibilityValue("\(Int(size)) pixels")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: size = min(range.upperBound, size + 2)
            case .decrement: size = max(range.lowerBound, size - 2)
            @unknown default: break
            }
        }
    }

    // MARK: - Container chrome

    private var container: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(uiColor: .systemBackground).opacity(0.95))
            .shadow(radius: 4)
    }

    // MARK: - Geometry

    /// Knob's vertical center within the track region (0 = top of track,
    /// trackHeight = bottom of track). Bigger size renders higher on the
    /// rail, matching Procreate's convention.
    private func knobYOffset(in trackHeight: CGFloat) -> CGFloat {
        let normalized = (size - range.lowerBound) / (range.upperBound - range.lowerBound)
        let clamped = max(0, min(1, normalized))
        return trackHeight * (1 - clamped)
    }

    // MARK: - Gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    withAnimation(.easeOut(duration: 0.12)) { isDragging = true }
                }
                updateSize(from: value.location.y)
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.18)) { isDragging = false }
            }
    }

    private func updateSize(from y: CGFloat) {
        let trackHeight = Self.containerHeight - 2 * Self.trackInset
        let trackY = y - Self.trackInset
        let clamped = max(0, min(trackHeight, trackY))
        let normalized = 1 - (clamped / trackHeight)
        let raw = range.lowerBound + normalized * (range.upperBound - range.lowerBound)
        size = max(range.lowerBound, min(range.upperBound, raw))
    }
}

#Preview {
    VStack {
        BrushSizeRail(size: .constant(40))
    }
    .padding()
    .background(Color.gray.opacity(0.2))
}
