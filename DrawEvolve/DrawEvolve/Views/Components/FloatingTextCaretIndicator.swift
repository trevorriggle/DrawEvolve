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
//  every other doc-space overlay does. Hides itself the moment the
//  user types anything (the rasterised glyphs take over). Hit-testing
//  is disabled — the underlying TextEntryOverlay's UITextView owns
//  keyboard input.
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
                    .position(anchor)
                    .allowsHitTesting(false)
            }
        }
    }

    private var shouldShow: Bool {
        guard let ft = canvasState.floatingText else { return false }
        // Only render the caret while content is empty — once the user
        // types, the rasterised glyphs are the source of truth and a
        // separate caret would just visually fight them.
        return ft.content.isEmpty
    }

    /// Anchor in screen-space, projected through the canvas transform.
    private var caretAnchorScreen: CGPoint? {
        guard let ft = canvasState.floatingText else { return nil }
        return canvasState.documentToScreen(ft.anchor)
    }

    /// Caret height ≈ the font's point size, scaled by the canvas zoom
    /// so the caret matches what a single line of text will visibly
    /// occupy. textSettings.size is in font points (matches what
    /// TypeBarView's size slider writes), so screen height is
    /// `size * zoomScale * scaleFactor` where scaleFactor maps doc
    /// pixels → screen points (handled inside documentToScreen for
    /// positions, but caret height needs explicit math).
    ///
    /// Approximation: size at 1× zoom roughly = font points on screen.
    /// At higher zoom, multiply by zoomScale. Good enough for an
    /// indicator — the rasterised text will replace it the moment the
    /// user types.
    private var caretHeightScreen: CGFloat? {
        let raw = canvasState.textSettings.size * canvasState.zoomScale
        return max(12, min(raw, 200))
    }
}
