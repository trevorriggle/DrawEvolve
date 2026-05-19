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
//  The rail also exposes a hardness slider when a `hardness` binding
//  is supplied — same chrome, secondary track to the right of the
//  size track. Size and hardness are the two controls that come up
//  most while drawing; surfacing them both on the rail saves the
//  Brush Properties round-trip.
//
//  Live preview: both tracks render the same `BrushPreviewDisc`
//  driven by the current size + hardness — scrubbing either slider
//  shows the disc that matches what the brush will actually paint.
//  See BrushPreviewDisc.swift for the contract.
//

import SwiftUI

struct BrushSizeRail: View {
    @Binding var size: CGFloat
    /// Optional binding for the secondary hardness track. When nil the
    /// rail keeps its legacy single-track layout. Callers that own a
    /// BrushSettings (the canvas) pass `$canvasState.brushSettings.hardness`
    /// to surface the new control.
    var hardness: Binding<CGFloat>? = nil
    /// Optional binding for the tertiary opacity track. Brush-family
    /// tools' fragment shaders multiply stamp alpha by this value at
    /// stroke commit. The slider sits to the right of the hardness
    /// track when both are present; callers pass
    /// `$canvasState.brushSettings.opacity`.
    var opacity: Binding<CGFloat>? = nil
    /// Matches the range surfaced in `BrushSettingsView` (1...200) so the
    /// rail and the full panel agree on bounds.
    var range: ClosedRange<CGFloat> = 1...200
    /// Optional converter from brush size (doc px) → on-screen
    /// diameter (screen pt) at the current canvas zoom/fit. When
    /// provided, the live preview circle uses this so its diameter
    /// matches what a single stamp will look like on the canvas.
    var screenDiameter: ((CGFloat) -> CGFloat)? = nil

    /// Response-curve exponent for knob-position → brush-size mapping.
    /// Mirrors BrushSizeRailHorizontal so the iPad and iPhone rails
    /// feel identical. Exponent 2 compresses small sizes into more
    /// track real estate (the bottom half covers ~1–50px, where
    /// artists usually live) and expands big sizes into less travel
    /// (top half covers 50–200px). Linear (=1) made the top half
    /// feel jumpy with no fine control over small brushes.
    private static let sizeCurve: CGFloat = 2.0
    /// Hardness curve. Hardness is a 0–1 percentage; the shader applies
    /// its own perceptual remap (h²) so the slider stays linear at
    /// this layer. The Pencil tool's fragment shader floors the
    /// shader-space value at 0.85 so dragging the rail below ~0.92
    /// still renders "pencil"-looking strokes.
    private static let hardnessCurve: CGFloat = 1.0
    /// Opacity curve. Linear — opacity perception is approximately
    /// linear at the slider level, matching how every reference app
    /// (Procreate, Photoshop) presents it.
    private static let opacityCurve: CGFloat = 1.0

    private static let containerHeight: CGFloat = 200
    /// Single-track width (size only) — preserves legacy chrome for
    /// any caller that doesn't pass a hardness binding.
    private static let containerWidthSingle: CGFloat = 36
    /// Two-track width — fits the size + hardness tracks side by side
    /// with a small gap.
    private static let containerWidthDual: CGFloat = 76
    /// Three-track width — adds the opacity track to the right of the
    /// hardness track.
    private static let containerWidthTriple: CGFloat = 116
    /// Max preview disc diameter so a 200px brush at high zoom doesn't
    /// blow out the rail's chrome. Exposed so the inner tracks can
    /// position the disc from the same constant the parent uses.
    static let previewDiameterCap: CGFloat = 80
    /// HStack(spacing: 8) between size and hardness tracks + each track's
    /// 30pt frame width. When the hardness track renders its disc to
    /// the LEFT of the whole rail, it needs to clear this much extra
    /// to land at the same screen-x as the size track's disc.
    private static let trackToTrackOffset: CGFloat = 30 + 8

    /// Hardness used to drive the preview disc when no hardness binding
    /// is provided (legacy single-track callers). 1.0 = hard edge,
    /// matching the solid-circle preview behaviour the rail had before
    /// the unified disc landed.
    private static let previewHardnessFallback: CGFloat = 1.0
    /// Opacity used to drive the preview disc when no opacity binding
    /// is provided. 1.0 = fully opaque (the disc behaves as it did
    /// before the third track landed).
    private static let previewOpacityFallback: CGFloat = 1.0

    /// Single source of truth for what the preview disc renders. All
    /// tracks read from this so the disc looks identical whether the
    /// user is scrubbing size, hardness, or opacity — only the anchor
    /// position differs (next to whichever knob the user is dragging).
    private var previewModel: BrushPreviewModel {
        let docDiameter = screenDiameter?(size) ?? size
        return BrushPreviewModel(
            diameter: min(docDiameter, Self.previewDiameterCap),
            hardness: hardness?.wrappedValue ?? Self.previewHardnessFallback,
            opacity: opacity?.wrappedValue ?? Self.previewOpacityFallback
        )
    }

    var body: some View {
        VStack(spacing: 4) {
            labelRow
            HStack(spacing: 8) {
                VerticalRailTrack(
                    value: $size,
                    range: range,
                    curve: Self.sizeCurve,
                    accessibilityLabel: "Brush size",
                    accessibilityValue: "\(Int(size)) pixels",
                    readoutText: "\(Int(size)) px",
                    accessibilityStep: 2,
                    previewModel: previewModel,
                    trackLeadingClearance: 0
                )
                if let hardness {
                    VerticalRailTrack(
                        value: hardness,
                        range: 0...1,
                        curve: Self.hardnessCurve,
                        accessibilityLabel: "Brush hardness",
                        accessibilityValue: "\(Int(hardness.wrappedValue * 100)) percent",
                        readoutText: "\(Int(hardness.wrappedValue * 100))%",
                        accessibilityStep: 0.05,
                        previewModel: previewModel,
                        trackLeadingClearance: Self.trackToTrackOffset
                    )
                }
                if let opacity {
                    VerticalRailTrack(
                        value: opacity,
                        range: 0...1,
                        curve: Self.opacityCurve,
                        accessibilityLabel: "Brush opacity",
                        accessibilityValue: "\(Int(opacity.wrappedValue * 100)) percent",
                        readoutText: "\(Int(opacity.wrappedValue * 100))%",
                        accessibilityStep: 0.05,
                        previewModel: previewModel,
                        trackLeadingClearance: Self.trackToTrackOffset * 2
                    )
                }
            }
            .padding(.horizontal, 4)
            .frame(
                width: railWidth,
                height: Self.containerHeight
            )
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: .systemBackground).opacity(0.95))
                    .shadow(radius: 4)
            )
        }
    }

    /// Header labels sit above the chrome so they live outside every
    /// track's drag gesture. Each label is centered over its track
    /// (track frame is 30pt; we use the same frame on the label so
    /// "hardness" / "opacity" overflow their 30pt slots symmetrically
    /// rather than pulling everything left).
    @ViewBuilder
    private var labelRow: some View {
        HStack(spacing: 8) {
            Text("size")
                .frame(width: 30, alignment: .center)
            if hardness != nil {
                Text("hardness")
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 30, alignment: .center)
            }
            if opacity != nil {
                Text("opacity")
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 30, alignment: .center)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .allowsHitTesting(false)
    }

    /// Container width selector — three-way switch between legacy
    /// single-track callers, the size+hardness dual layout, and the
    /// new size+hardness+opacity triple layout (Phase 4.6 follow-up).
    private var railWidth: CGFloat {
        if opacity != nil { return Self.containerWidthTriple }
        if hardness != nil { return Self.containerWidthDual }
        return Self.containerWidthSingle
    }
}

/// One vertical track inside the rail. Owns its own knob, fill, drag
/// gesture, and live preview readout. The outer `BrushSizeRail` lays
/// out one or two of these inside the shared rounded-rectangle chrome.
private struct VerticalRailTrack: View {
    @Binding var value: CGFloat
    var range: ClosedRange<CGFloat>
    var curve: CGFloat
    var accessibilityLabel: String
    var accessibilityValue: String
    var readoutText: String
    var accessibilityStep: CGFloat
    /// Current size + hardness from the parent — what the disc renders
    /// when this track is being scrubbed.
    var previewModel: BrushPreviewModel
    /// How far left of this track's local origin to anchor the preview
    /// disc. Size track passes 0; hardness track passes the offset
    /// across the size track + gap so the disc lands on the LEFT side
    /// of the whole rail regardless of which slider is active.
    var trackLeadingClearance: CGFloat

    @State private var isDragging = false

    private static let railWidth: CGFloat = 6
    private static let knobDiameter: CGFloat = 22
    private static let trackInset: CGFloat = Self.knobDiameter / 2 + 4

    var body: some View {
        GeometryReader { proxy in
            let trackHeight = proxy.size.height - 2 * Self.trackInset
            let knobY = knobYOffset(in: trackHeight) + Self.trackInset

            Capsule()
                .fill(Color.primary.opacity(0.15))
                .frame(width: Self.railWidth, height: trackHeight)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

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

            Circle()
                .fill(Color.accentColor)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                .position(x: proxy.size.width / 2, y: knobY)

            if isDragging {
                BrushPreviewDisc(model: previewModel)
                    .position(
                        x: -(BrushSizeRail.previewDiameterCap / 2 + 12) - trackLeadingClearance,
                        y: knobY
                    )
                    .transition(.opacity)

                // .fixedSize so the bubble doesn't wrap when the
                // parent's proposed width is narrow.
                Text(readoutText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.78))
                    .clipShape(Capsule())
                    .fixedSize(horizontal: true, vertical: false)
                    .position(
                        x: -(BrushSizeRail.previewDiameterCap + 48) - trackLeadingClearance,
                        y: knobY
                    )
                    .transition(.opacity)
            }
        }
        .frame(width: 30)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = min(range.upperBound, value + accessibilityStep)
            case .decrement: value = max(range.lowerBound, value - accessibilityStep)
            @unknown default: break
            }
        }
    }

    private func knobYOffset(in trackHeight: CGFloat) -> CGFloat {
        let raw = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        let clamped = max(0, min(1, raw))
        let t = pow(clamped, 1 / curve)
        return trackHeight * (1 - t)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if !isDragging {
                    withAnimation(.easeOut(duration: 0.12)) { isDragging = true }
                }
                updateValue(from: gesture.location.y)
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.18)) { isDragging = false }
            }
    }

    private func updateValue(from y: CGFloat) {
        // The GeometryReader's height equals the rail's content height;
        // the outer container adds vertical padding but the gesture
        // coordinates are in the GeometryReader's local space.
        let trackHeight = BrushSizeRail.containerHeightForTrack - 2 * Self.trackInset
        let trackY = y - Self.trackInset
        let clamped = max(0, min(trackHeight, trackY))
        let t = 1 - (clamped / trackHeight)
        let curved = pow(t, curve)
        let raw = range.lowerBound + curved * (range.upperBound - range.lowerBound)
        value = max(range.lowerBound, min(range.upperBound, raw))
    }
}

extension BrushSizeRail {
    /// Exposed to `VerticalRailTrack` so it can compute the same track
    /// height the outer container reserved. Keeping this here avoids a
    /// magic-number drift between layout and gesture math.
    fileprivate static var containerHeightForTrack: CGFloat { containerHeight }
}

#Preview {
    HStack {
        BrushSizeRail(size: .constant(40))
        BrushSizeRail(size: .constant(40), hardness: .constant(0.6))
        BrushSizeRail(
            size: .constant(40),
            hardness: .constant(0.6),
            opacity: .constant(0.75)
        )
    }
    .padding()
    .background(Color.gray.opacity(0.2))
}
