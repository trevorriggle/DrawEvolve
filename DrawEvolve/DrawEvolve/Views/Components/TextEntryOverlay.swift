//
//  TextEntryOverlay.swift
//  DrawEvolve
//
//  Invisible UITextView host that captures keyboard input for the active
//  FloatingText. Replaces the UIAlertController-based text input retired
//  in the Tier-1 type-tools UX overhaul.
//
//  Behavior:
//    • Mounted only while `canvasState.floatingText != nil`.
//    • Becomes first responder on appearance so the keyboard rises
//      immediately. Resigns when the float is committed/cancelled (the
//      view simply disappears, taking the responder with it).
//    • Hit-testing disabled — taps outside the float still hit the
//      canvas and trigger commit/new-text. The UITextView only exists
//      to drive the keyboard; the visible glyphs come from the
//      rasterised float, not from the text view's own text rendering.
//    • Newlines flow through `canvasState.setFloatingTextContent` and
//      the existing rasterise pipeline (paragraphStyle.lineSpacing
//      already handles multi-line layout).
//    • Tier-1.5 dropped the inputAccessoryView entirely. The floating
//      Type Bar's ✓ checkmark is the commit affordance and the existing
//      cancel pill handles cancel; a Done/Cancel toolbar above the
//      keyboard duplicated both. Return key remains as newline.
//

import SwiftUI
import UIKit

struct TextEntryOverlay: View {
    @ObservedObject var canvasState: CanvasStateManager

    var body: some View {
        if canvasState.floatingText != nil {
            TextEntryHost(canvasState: canvasState)
                .frame(width: 1, height: 1)
                .position(positionForFloat)
                .allowsHitTesting(false)
        }
    }

    /// Anchors the invisible UITextView to the float's anchor in screen
    /// space. The position only matters for the (invisible) caret and is
    /// otherwise unused — the keyboard rises regardless of frame.
    private var positionForFloat: CGPoint {
        guard let ft = canvasState.floatingText else { return .zero }
        return canvasState.documentToScreen(ft.anchor)
    }
}

private struct TextEntryHost: UIViewRepresentable {
    @ObservedObject var canvasState: CanvasStateManager

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.textColor = .clear
        tv.tintColor = .clear
        tv.text = canvasState.floatingText?.content ?? ""
        tv.delegate = context.coordinator
        tv.isScrollEnabled = false
        // Autocorrect / spell-check / smart-dashes / smart-quotes /
        // smart-insert-delete left at the platform defaults so the user
        // sees the standard iOS keyboard (QuickType bar included). The
        // earlier `.no` settings made the keyboard look stripped down
        // vs. every other text input on the device. If a user wants a
        // strict-typing mode for artistic intent, that becomes a
        // TextSettings preference — not a hidden compile-time default.
        // Defer to next runloop so SwiftUI's view-mount transaction
        // completes first; calling on the same tick can race with the
        // ZStack's responder management and the keyboard fails to rise.
        DispatchQueue.main.async {
            tv.becomeFirstResponder()
        }
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // External cancel/commit clears `floatingText`, which removes
        // this view entirely; the resign-first-responder fallback below
        // is for the rare case where the view is still mounted but the
        // float was cleared by something other than view dismissal.
        if canvasState.floatingText == nil && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(canvasState: canvasState)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        weak var canvasState: CanvasStateManager?

        init(canvasState: CanvasStateManager) {
            self.canvasState = canvasState
            super.init()
        }

        func textViewDidChange(_ textView: UITextView) {
            canvasState?.setFloatingTextContent(textView.text)
        }
    }
}
