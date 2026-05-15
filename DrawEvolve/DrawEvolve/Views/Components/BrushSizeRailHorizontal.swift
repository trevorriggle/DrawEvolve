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
//  When a `hardness` binding is supplied the rail surfaces a secondary
//  track stacked below the size track, mirroring the vertical rail's
//  two-track layout. Hardness lives on the rail because it's the
//  second-most-used brush parameter after size and the Brush
//  Properties sheet round-trip was the most-reported friction point.
//
//  Live preview: both tracks render the same `BrushPreviewDisc`
//  driven by the current size + hardness. The hardness track pushes
//  its disc up over the size track so the disc lives ABOVE the rail
//  on either scrub. See BrushPreviewDisc.swift for the contract.
//

import SwiftUI

struct BrushSizeRailHorizontal: View {
    @Binding var size: CGFloat
    /// Optional binding for the secondary hardness track. nil keeps
    /// the legacy single-track layout.
    /// TODO: add opacity slider once wet-ink pipeline lands (see BrushSettingsView.swift ~96–101)
    var hardness: Binding<CGFloat>? = nil
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

    /// Response-curve exponent for knob-position → brush-size mapping.
    /// 1.0 = linear. A previous version used 2.0 (quadratic) to give
    /// fine control over small brushes, but the cost was the top half
    /// of the track feeling "exponential" — small slider movements
    /// near the top caused big size jumps. The user reported this as
    /// the slider not matching what was actually drawn. Linear feels
    /// predictable: each pt of slider travel = the same px of brush
    /// size change at any position.
    private static let sizeCurve: CGFloat = 1.0
    private static let hardnessCurve: CGFloat = 1.0

    private static let singleTrackHeight: CGFloat = 36
    /// Combined height when the hardness track is present. Two 30pt
    /// tracks plus a small gutter; matches the rail's chrome feeling
    /// "thin" while doubling the controls available.
    private static let dualTrackHeight: CGFloat = 64
    /// Max preview disc diameter so the disc doesn't tower over the
    /// rail at large brush sizes on iPhone. Mirrors the iPad cap.
    static let previewDiameterCap: CGFloat = 80
    /// Per-track height (30pt) + the VStack(spacing: 4) between them.
    /// When the hardness track renders its disc above itself, it
    /// needs this much extra clearance to land ABOVE the size track.
    private static let trackToTrackOffset: CGFloat = 30 + 4

    private static let previewHardnessFallback: CGFloat = 1.0

    /// Single source of truth for what the preview disc renders — see
    /// BrushSizeRail.previewModel for rationale.
    private var previewModel: BrushPreviewModel {
        let docDiameter = screenDiameter?(size) ?? size
        return BrushPreviewModel(
            diameter: min(docDiameter, Self.previewDiameterCap),
            hardness: hardness?.wrappedValue ?? Self.previewHardnessFallback
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            labelColumn
            VStack(spacing: 4) {
                HorizontalRailTrack(
                    value: $size,
                    range: range,
                    curve: Self.sizeCurve,
                    accessibilityLabel: "Brush size",
                    accessibilityValue: "\(Int(size)) pixels",
                    readoutText: "\(Int(size)) px",
                    accessibilityStep: 2,
                    previewModel: previewModel,
                    trackTopClearance: 0
                )
                if let hardness {
                    HorizontalRailTrack(
                        value: hardness,
                        range: 0...1,
                        curve: Self.hardnessCurve,
                        accessibilityLabel: "Brush hardness",
                        accessibilityValue: "\(Int(hardness.wrappedValue * 100)) percent",
                        readoutText: "\(Int(hardness.wrappedValue * 100))%",
                        accessibilityStep: 0.05,
                        previewModel: previewModel,
                        trackTopClearance: Self.trackToTrackOffset
                    )
                }
            }
        }
        .padding(.leading, 10)
        .frame(height: hardness == nil ? Self.singleTrackHeight : Self.dualTrackHeight)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .systemBackground).opacity(0.95))
                .shadow(radius: 4)
        )
    }

    /// Leading-edge labels live inside the chrome but outside each
    /// track's drag gesture. Each label sits at the same vertical
    /// centre as the track it names (30pt-tall row with matching 4pt
    /// inter-row gap, mirroring the tracks' VStack(spacing: 4)).
    @ViewBuilder
    private var labelColumn: some View {
        VStack(spacing: 4) {
            Text("size")
                .frame(height: 30, alignment: .center)
            if hardness != nil {
                Text("hardness")
                    .frame(height: 30, alignment: .center)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 56, alignment: .leading)
        .allowsHitTesting(false)
    }
}

/// One horizontal track inside the rail. Owns its own knob, fill,
/// drag gesture, and live preview readout. The outer
/// `BrushSizeRailHorizontal` stacks one or two of these inside the
/// shared rounded-rectangle chrome.
private struct HorizontalRailTrack: View {
    @Binding var value: CGFloat
    var range: ClosedRange<CGFloat>
    var curve: CGFloat
    var accessibilityLabel: String
    var accessibilityValue: String
    var readoutText: String
    var accessibilityStep: CGFloat
    var previewModel: BrushPreviewModel
    /// How far above this track's local origin to anchor the preview
    /// disc. Size track passes 0; hardness track passes the offset
    /// across the size track + spacing so the disc lands ABOVE the
    /// whole rail regardless of which slider is active.
    var trackTopClearance: CGFloat

    @State private var isDragging = false
    @State private var measuredWidth: CGFloat = 280

    private static let railHeight: CGFloat = 6
    private static let knobDiameter: CGFloat = 22
    private static let trackInset: CGFloat = Self.knobDiameter / 2 + 4

    var body: some View {
        GeometryReader { proxy in
            let trackWidth = max(0, proxy.size.width - 2 * Self.trackInset)
            let knobX = knobXOffset(in: trackWidth) + Self.trackInset

            Capsule()
                .fill(Color.primary.opacity(0.15))
                .frame(width: trackWidth, height: Self.railHeight)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

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

            Circle()
                .fill(Color.accentColor)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                .position(x: knobX, y: proxy.size.height / 2)

            if isDragging {
                BrushPreviewDisc(model: previewModel)
                    .position(
                        x: knobX,
                        y: -(previewModel.diameter / 2 + 8) - trackTopClearance
                    )
                    .transition(.opacity)

                Text(readoutText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.78))
                    .clipShape(Capsule())
                    .fixedSize(horizontal: true, vertical: false)
                    .position(x: knobX, y: -14 - trackTopClearance)
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

    private func knobXOffset(in trackWidth: CGFloat) -> CGFloat {
        let raw = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        let clamped = max(0, min(1, raw))
        let t = pow(clamped, 1 / curve)
        return trackWidth * t
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if !isDragging {
                    withAnimation(.easeOut(duration: 0.12)) { isDragging = true }
                }
                updateValue(from: gesture.location.x)
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.18)) { isDragging = false }
            }
    }

    private func updateValue(from x: CGFloat) {
        let trackWidth = max(1, measuredWidth - 2 * Self.trackInset)
        let trackX = x - Self.trackInset
        let clamped = max(0, min(trackWidth, trackX))
        let t = clamped / trackWidth
        let curved = pow(t, curve)
        let raw = range.lowerBound + curved * (range.upperBound - range.lowerBound)
        value = max(range.lowerBound, min(range.upperBound, raw))
    }
}

private struct WidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    VStack(spacing: 16) {
        BrushSizeRailHorizontal(size: .constant(40))
            .padding(.horizontal, 16)
        BrushSizeRailHorizontal(size: .constant(40), hardness: .constant(0.6))
            .padding(.horizontal, 16)
    }
    .padding()
    .background(Color.gray.opacity(0.2))
}
