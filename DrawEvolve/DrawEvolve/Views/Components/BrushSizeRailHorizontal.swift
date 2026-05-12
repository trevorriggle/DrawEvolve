//
//  BrushSizeRailHorizontal.swift
//  DrawEvolve
//
//  iPhone-only horizontal counterpart to BrushSizeRail. The iPad mounts
//  the vertical rail in the right-side floating chrome above Save / Get
//  Feedback (BrushSizeRail.swift). iPhone has no equivalent free space
//  on the side of the canvas; the rail instead hugs the bottom action
//  row so the user can adjust brush size without opening the Brush
//  Properties sheet.
//
//  Bound directly to `CanvasStateManager.brushSettings.size`, same as
//  the vertical rail — keep them in lockstep so the user's iPad and
//  iPhone get the same brush feel when sharing an account.
//

import SwiftUI

struct BrushSizeRailHorizontal: View {
    @Binding var size: CGFloat
    /// Matches BrushSizeRail and BrushSettingsView so all three surfaces
    /// agree on bounds. Don't widen here without widening there too.
    var range: ClosedRange<CGFloat> = 1...200
    /// Optional converter from brush size (doc px) → on-screen
    /// diameter (screen pt) at the current canvas zoom/fit. When
    /// provided, the live preview circle uses this so its diameter
    /// matches what a single stamp will actually look like on the
    /// canvas. Without it, `size` is treated as screen pt directly
    /// (which is wrong on a zoomed canvas — the bug this parameter
    /// fixes).
    var screenDiameter: ((CGFloat) -> CGFloat)? = nil

    @State private var isDragging = false
    /// Captured from the GeometryReader during layout; the drag handler
    /// reads it to compute the track-coords clamp. Defaults to a sane
    /// value so the first drag before layout completes won't divide by
    /// zero.
    @State private var measuredWidth: CGFloat = 280

    private static let railHeight: CGFloat = 6
    private static let knobDiameter: CGFloat = 22
    private static let containerHeight: CGFloat = 36
    /// Padding from the left/right edges of the container to the knob's
    /// extreme positions. Prevents the knob from clipping the rounded
    /// container corners.
    private static let trackInset: CGFloat = Self.knobDiameter / 2 + 4

    /// Response-curve exponent for knob-position → brush-size mapping.
    /// 1.0 = linear. A previous version used 2.0 (quadratic) to give
    /// fine control over small brushes, but the cost was the top half
    /// of the track feeling "exponential" — small slider movements
    /// near the top caused big size jumps. The user reported this as
    /// the slider not matching what was actually drawn. Linear feels
    /// predictable: each pt of slider travel = the same px of brush
    /// size change at any position.
    private static let sizeCurve: CGFloat = 1.0
    /// Vertical offset for the preview circle's center, above the
    /// knob. Generous so even a large brush preview floats clear of
    /// the rail itself.
    private static let previewYOffset: CGFloat = 56

    var body: some View {
        ZStack {
            container

            GeometryReader { proxy in
                let trackWidth = max(0, proxy.size.width - 2 * Self.trackInset)
                let knobX = knobXOffset(in: trackWidth) + Self.trackInset

                // Background rail
                Capsule()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: trackWidth, height: Self.railHeight)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                // Filled portion (left up to knob — bigger size = more fill)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(
                        width: max(0, knobX - Self.trackInset),
                        height: Self.railHeight
                    )
                    .position(
                        x: (Self.trackInset + knobX) / 2,
                        y: proxy.size.height / 2
                    )

                // Knob
                Circle()
                    .fill(Color.accentColor)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                    .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                    .position(x: knobX, y: proxy.size.height / 2)

                // Live size preview — filled circle drawn at the
                // ACTUAL on-screen stamp diameter. No cap. The
                // previous capped version (80pt) underrepresented the
                // stroke at higher zoom levels or larger brush sizes,
                // and the discrepancy felt "exponential" to the user
                // because the gap grew faster than the slider's
                // visible position. Now what you see is what hits the
                // canvas — even if the preview circle becomes large.
                if isDragging {
                    let previewDiameter = screenDiameter?(size) ?? size
                    Circle()
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: previewDiameter, height: previewDiameter)
                        .overlay(
                            Circle().stroke(
                                Color(uiColor: .systemBackground).opacity(0.9),
                                lineWidth: 1.5
                            )
                        )
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                        // Center the preview so its BOTTOM sits a
                        // consistent distance above the rail
                        // regardless of size, rather than always
                        // anchoring at a fixed center y. Bigger
                        // brushes float higher; small ones nestle
                        // just above the knob.
                        .position(x: knobX, y: -(previewDiameter / 2 + 8))
                        .transition(.opacity)

                    // Numeric readout bubble — sits just above the
                    // knob, below the preview circle, so both are
                    // visible at a glance without overlapping.
                    // .fixedSize so the text doesn't wrap when the
                    // parent's proposed width is narrower than the
                    // pill's natural width.
                    Text("\(Int(size)) px")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.78))
                        .clipShape(Capsule())
                        .fixedSize(horizontal: true, vertical: false)
                        .position(x: knobX, y: -14)
                        .transition(.opacity)
                }
            }
            .background(GeometryReader { proxy in
                Color.clear.preference(
                    key: WidthPreferenceKey.self,
                    value: proxy.size.width
                )
            })
            .onPreferenceChange(WidthPreferenceKey.self) { newWidth in
                if newWidth > 0 { measuredWidth = newWidth }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
        }
        .frame(height: Self.containerHeight)
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

    /// Knob's horizontal offset within the track region (0 = left edge,
    /// trackWidth = right edge). Bigger size → further right, matching
    /// the desktop convention (Photoshop/Figma) rather than the iPad
    /// rail's bigger-on-top mental model — horizontal "more is to the
    /// right" reads more naturally than mirroring the vertical map.
    ///
    /// Inverse of the curve applied in `updateSize`: t = ((size - lo)
    /// / (hi - lo))^(1/curve). Without the inverse here the knob
    /// would drift relative to the size value the slider just wrote.
    private func knobXOffset(in trackWidth: CGFloat) -> CGFloat {
        let raw = (size - range.lowerBound) / (range.upperBound - range.lowerBound)
        let clamped = max(0, min(1, raw))
        let t = pow(clamped, 1 / Self.sizeCurve)
        return trackWidth * t
    }

    // MARK: - Gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    withAnimation(.easeOut(duration: 0.12)) { isDragging = true }
                }
                updateSize(from: value.location.x)
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.18)) { isDragging = false }
            }
    }

    private func updateSize(from x: CGFloat) {
        let trackWidth = max(1, measuredWidth - 2 * Self.trackInset)
        let trackX = x - Self.trackInset
        let clamped = max(0, min(trackWidth, trackX))
        let t = clamped / trackWidth
        // Quadratic response: position^2 means the left half of the
        // track covers small sizes (fine control where it matters)
        // and the right half covers big sizes (coarse control where
        // precision matters less). See `sizeCurve` doc.
        let curved = pow(t, Self.sizeCurve)
        let raw = range.lowerBound + curved * (range.upperBound - range.lowerBound)
        size = max(range.lowerBound, min(range.upperBound, raw))
    }
}

private struct WidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    VStack {
        BrushSizeRailHorizontal(size: .constant(40))
            .padding(.horizontal, 16)
    }
    .padding()
    .background(Color.gray.opacity(0.2))
}
