//
//  FloatingTextCaretIndicator.swift
//  DrawEvolve
//
//  Visible blinking caret rendered at the FloatingText's anchor while
//  the float exists with empty content. Solves the "where is my text
//  about to land?" problem when the Text tool is selected — the user
//  sees the standard iOS-style cursor and can immediately type.
//
//  Tracks `floatingText.anchor` through `documentToScreen`, so the
//  caret follows canvas zoom / pan / rotation / flip the same way
//  every other doc-space overlay does. The Rectangle itself is also
//  rotated by `-canvasRotation` so the bar reads as doc-vertical
//  (matching the rasterised glyphs the shader rotates by the same
//  amount) rather than screen-vertical on a tilted canvas. Hides
//  itself the moment the user types anything (the rasterised glyphs
//  take over). Hit-testing is disabled — the underlying
//  TextEntryOverlay's UITextView owns keyboard input.
//

import SwiftUI

struct FloatingTextCaretIndicator: View {
    @ObservedObject var canvasState: CanvasStateManager

    /// Driven by a TimelineView for a steady half-second blink that's
    /// not affected by SwiftUI re-render cadence.
    var body: some View {
        if shouldShow, let anchor = caretAnchorScreen, let height = caretHeightScreen {
            TimelineView(.animation(minimumInterval: 0.5)) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let isOn = Int(elapsed * 2) % 2 == 0
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: height)
                    .opacity(isOn ? 1.0 : 0.15)
                    // Match canvas rotation so the bar reads doc-vertical.
                    // Sign matches ReferenceImageView.effectiveRotation:
                    // canvasState.canvasRotation already has its gesture
                    // sign inverted at the handler, and SwiftUI's
                    // .rotationEffect(+θ) rotates visually CW, so we
                    // negate here to land on the same visual axis the
                    // floating-text shader produces for the rasterised
                    // glyph (selTheta + canvasRotation, with selTheta=0
                    // for the caret-only phase).
                    .rotationEffect(-canvasState.canvasRotation)
                    .position(anchor)
                    .allowsHitTesting(false)
            }
        }
    }

    private var shouldShow: Bool {
        guard let ft = canvasState.floatingText else { return false }
        // Plain text now edits through the visible InlineTextEditorView,
        // which has a real native caret — rendering a second one here
        // would fight it. This indicator survives only for PATH text
        // (whose editor is invisible) with empty content; once the user
        // types, the rasterised on-path glyphs take over.
        if ft.path == nil && canvasState.isTextEditorSessionActive {
            return false
        }
        return ft.content.isEmpty
    }

    /// Anchor in screen-space, projected through the canvas transform.
    private var caretAnchorScreen: CGPoint? {
        guard let ft = canvasState.floatingText else { return nil }
        return canvasState.documentToScreen(ft.anchor)
    }

    /// Caret height = the font's doc-space size projected through the
    /// real doc→screen scale (fit-scale × zoom), measured by projecting a
    /// vertical doc segment of `size` length through documentToScreen.
    /// The old `size * zoomScale` approximation omitted the fit scale and
    /// under/over-shot whenever document pixels ≠ screen points at 1×.
    private var caretHeightScreen: CGFloat? {
        let size = canvasState.textSettings.size
        let a = canvasState.documentToScreen(CGPoint(x: 0, y: 0))
        let b = canvasState.documentToScreen(CGPoint(x: 0, y: size))
        let raw = hypot(b.x - a.x, b.y - a.y)
        guard raw.isFinite, raw > 0 else { return 12 }
        return max(12, min(raw, 400))
    }
}
