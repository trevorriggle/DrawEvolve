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
//    • Keyboard-avoidance preview: when the soft keyboard rises and
//      the float's screen anchor lands behind the keyboard, we surface
//      a visible preview card above the keyboard with the current
//      content + a "lands behind keyboard" adornment. The actual
//      rasterised glyphs stay at the anchor — only this temporary
//      preview translates. Auto-dismisses on keyboard-hide. Preferred
//      over translating the canvas itself because pinch-zoom state
//      lives in canvasState and a transient pan would corrupt it.
//

import SwiftUI
import UIKit

struct TextEntryOverlay: View {
    @ObservedObject var canvasState: CanvasStateManager

    /// End-frame of the soft keyboard in screen-points, captured from
    /// the latest keyboardWillShow / keyboardWillHide notification. nil
    /// when the keyboard is down (or hardware keyboard, which reports
    /// height 0).
    @State private var keyboardFrame: CGRect? = nil

    /// Animation duration iOS published with the most recent show/hide
    /// so the preview's appear/disappear matches the keyboard slide.
    @State private var keyboardAnimDuration: Double = 0.25

    var body: some View {
        if let ft = canvasState.floatingText {
            ZStack {
                TextEntryHost(canvasState: canvasState)
                    .frame(width: 1, height: 1)
                    .position(canvasState.documentToScreen(ft.anchor))
                    .allowsHitTesting(false)

                if let elevated = elevatedPosition(for: ft) {
                    elevatedPreview(for: ft, at: elevated)
                        .transition(.opacity)
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillShowNotification
            )) { handleKeyboardShow($0) }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification
            )) { handleKeyboardHide($0) }
        }
    }

    // MARK: - Keyboard avoidance

    /// Screen-point center for the elevated preview card when the float's
    /// anchor is behind the soft keyboard. nil ⇒ either no keyboard or
    /// the anchor is already visible, and the preview shouldn't mount.
    private func elevatedPosition(for ft: FloatingText) -> CGPoint? {
        guard let kb = keyboardFrame, kb.height > 0 else { return nil }
        let anchorScreen = canvasState.documentToScreen(ft.anchor)
        // 8pt slack so a hairline overlap with the keyboard top still
        // counts as obscured — the rasterised glyph extends below the
        // anchor (font descenders + first-line height).
        guard anchorScreen.y >= kb.minY - 8 else { return nil }
        return CGPoint(x: kb.midX, y: kb.minY - 56)
    }

    @ViewBuilder
    private func elevatedPreview(for ft: FloatingText, at point: CGPoint) -> some View {
        let displayText = ft.content.isEmpty ? "Type your text…" : ft.content
        VStack(spacing: 4) {
            Text(displayText)
                .font(.body)
                .foregroundColor(ft.content.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .truncationMode(.tail)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .font(.caption2.weight(.semibold))
                Text("Text lands behind keyboard")
                    .font(.caption2)
            }
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: 320)
        .position(point)
        .allowsHitTesting(false)
    }

    private func handleKeyboardShow(_ note: Notification) {
        guard let info = note.userInfo,
              let frameValue = info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue,
              let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else {
            return
        }
        let frame = frameValue.cgRectValue
        // Hardware keyboard reports height 0 / off-screen position — no
        // preview needed because no software keyboard is hiding anything.
        guard frame.height > 0 else {
            withAnimation(.easeInOut(duration: duration)) { keyboardFrame = nil }
            return
        }
        keyboardAnimDuration = duration
        withAnimation(.easeInOut(duration: duration)) {
            keyboardFrame = frame
        }
    }

    private func handleKeyboardHide(_ note: Notification) {
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double)
            ?? keyboardAnimDuration
        withAnimation(.easeInOut(duration: duration)) {
            keyboardFrame = nil
        }
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
        // Single-pipeline keyboard config — both `.text` and `.textOnPath`
        // route their keystrokes through this one UITextView (see
        // beginText / beginTextOnPath / beginTextOnPathCircle in
        // CanvasStateManager — they all create the FloatingText that
        // this overlay then captures input for). These four traits are
        // set explicitly to .default to lock the contract: regular type
        // and type-on-path get the IDENTICAL platform keyboard,
        // QuickType bar included. A previous build set keyboardType to a
        // numeric/compact variant on the type-on-path path; explicit
        // assignment here defends against that drift returning.
        tv.keyboardType = .default
        tv.returnKeyType = .default
        tv.autocapitalizationType = .sentences
        tv.autocorrectionType = .default
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
