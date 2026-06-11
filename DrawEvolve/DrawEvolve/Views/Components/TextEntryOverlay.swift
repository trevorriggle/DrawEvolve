//
//  TextEntryOverlay.swift
//  DrawEvolve
//
//  Invisible UITextView host that captures keyboard input for PATH-BEARING
//  FloatingText (type-on-path). Plain text now edits through the visible
//  InlineTextEditorView; this host remains for path text because glyphs
//  laid along a curve can't be a native text view — the rasterised
//  on-canvas preview is the live feedback, kept visible by the
//  keyboard-avoidance pan.
//
//  5.1 type-tool rework changes:
//    • Mounted only while a PATH float's typing session is active
//      (`floatingText.path != nil && isTextEditorSessionActive`).
//    • The "Text lands behind keyboard" elevated preview card is GONE —
//      the canvas itself pans (TextKeyboardAvoidanceDriver +
//      CanvasStateManager.keyboardAvoidancePan) so the real text stays
//      visible above the keyboard. The card was hit-test transparent,
//      which meant tapping it committed the float; nothing mourns it.
//    • The Type Bar docks above the keyboard as this text view's
//      inputAccessoryView instead of floating over the canvas.
//
//  Behavior:
//    • Becomes first responder on appearance so the keyboard rises
//      immediately. Resigns when the session ends (the view disappears,
//      taking the responder with it).
//    • Hit-testing disabled — taps outside the float still hit the
//      canvas and trigger commit/new-text. The UITextView only exists
//      to drive the keyboard; the visible glyphs come from the
//      rasterised float.
//    • Newlines flow through `canvasState.setFloatingTextContent` and
//      the existing rasterise pipeline.
//

import SwiftUI
import UIKit

struct TextEntryOverlay: View {
    @ObservedObject var canvasState: CanvasStateManager

    /// Checkmark on the keyboard-docked Type Bar — "done typing".
    let onCheckmark: () -> Void

    var body: some View {
        if let ft = canvasState.floatingText,
           ft.path != nil,
           canvasState.isTextEditorSessionActive {
            ZStack {
                TextEntryHost(canvasState: canvasState, onCheckmark: onCheckmark)
                    .frame(width: 1, height: 1)
                    .position(canvasState.documentToScreen(ft.anchor))
                    .allowsHitTesting(false)

                TextKeyboardAvoidanceDriver(canvasState: canvasState)
            }
            .ignoresSafeArea()
        }
    }
}

private struct TextEntryHost: UIViewRepresentable {
    let canvasState: CanvasStateManager
    let onCheckmark: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.textColor = .clear
        tv.tintColor = .clear
        tv.text = canvasState.floatingText?.content ?? ""
        tv.delegate = context.coordinator
        tv.isScrollEnabled = false
        // Locked contract: path text gets the IDENTICAL platform keyboard
        // to plain text, QuickType bar included. Explicit .default
        // assignments defend against a numeric/compact variant drifting
        // back in (it happened once).
        tv.keyboardType = .default
        tv.returnKeyType = .default
        tv.autocapitalizationType = .sentences
        tv.autocorrectionType = .default

        // Keyboard-docked Type Bar. Must be assigned before
        // becomeFirstResponder or the accessory won't attach.
        tv.inputAccessoryView = makeTypeBarAccessoryView(
            canvasState: canvasState,
            onCheckmark: onCheckmark
        )

        // Defer to next runloop so SwiftUI's view-mount transaction
        // completes first; calling on the same tick can race with the
        // ZStack's responder management and the keyboard fails to rise.
        DispatchQueue.main.async {
            tv.becomeFirstResponder()
            tv.selectedRange = NSRange(location: (tv.text as NSString).length, length: 0)
        }
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // External cancel/commit clears the session, which removes this
        // view entirely; this fallback covers the rare case where the
        // view is still mounted but the float was cleared by something
        // other than view dismissal.
        if canvasState.floatingText == nil && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
        if uiView.isFirstResponder {
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
