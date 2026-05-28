//
//  EveTextField.swift
//  DrawEvolve
//
//  UITextField wrapped for SwiftUI so Eve's input can suppress the
//  iPadOS shortcut bar (mic / undo / redo / dictation) above the
//  keyboard. SwiftUI's plain TextField hands the input-assistant item
//  to iOS with its default leading/trailing groups; UIKit lets us
//  empty those groups per-field.
//
//  Scoped to Eve only. Every other text input in the app keeps the
//  default iPad shortcut bar, which is the right call for form-style
//  fields (drawing title, layer name, prompt data) where dictation /
//  undo / redo are useful. The Eve chat field is the one place where
//  the row is noise above an iMessage-style composer.
//
//  Floating-vs-docked keyboard mode is NOT controllable from app code
//  on iPad — that's a system-wide user gesture (pinch-to-float).
//  This wrapper only governs what shows ABOVE the keyboard, not
//  whether the keyboard is docked.
//
//  Return-as-send is wired through UIKit's editingDidEndOnExit. That
//  path is more reliable on the iPad floating keyboard than SwiftUI's
//  .onSubmit, which has known quirks firing from the compact return
//  key.
//
//  Autocorrect / autocapitalize / spell-check intentionally LEFT at
//  platform defaults. Stripping them makes the keyboard look broken
//  vs. every other text input on the device (same lesson the on-canvas
//  text tool learned — see TextEntryOverlay.swift:170-181). The Eve
//  field is a chat-with-an-AI field; standard iOS autocorrect is the
//  norm there.
//

import SwiftUI
import UIKit

struct EveTextField: UIViewRepresentable {
    @Binding var text: String
    /// External signal to drop first-responder. EveInputBar flips this
    /// to false when the conversation id changes, matching the prior
    /// .focused($isFocused) + .onChange clearing pattern that prevents
    /// the M6 "Ask Eve about this" handoff from inheriting a compact
    /// keyboard config from the previous panel's last-focused field.
    @Binding var isFocused: Bool
    var isEnabled: Bool
    var placeholder: String
    var onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.delegate = context.coordinator
        tf.placeholder = placeholder
        tf.borderStyle = .none
        tf.backgroundColor = .clear
        tf.font = .preferredFont(forTextStyle: .body)
        tf.adjustsFontForContentSizeCategory = true
        tf.returnKeyType = .send
        // Empty leading/trailing groups collapse the iPadOS shortcut bar
        // (mic / undo / redo / dictation) above the keyboard for this
        // field only. iPhone ignores these — the iPhone keyboard has
        // no shortcut bar to begin with.
        tf.inputAssistantItem.leadingBarButtonGroups = []
        tf.inputAssistantItem.trailingBarButtonGroups = []
        tf.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged,
        )
        tf.addTarget(
            context.coordinator,
            action: #selector(Coordinator.returnPressed(_:)),
            for: .editingDidEndOnExit,
        )
        return tf
    }

    func updateUIView(_ tf: UITextField, context: Context) {
        // Push the binding's text into UIKit only when they diverge,
        // otherwise we'd clobber the user's mid-edit caret position on
        // every parent re-render.
        if tf.text != text {
            tf.text = text
        }
        tf.isEnabled = isEnabled
        // External "clear focus" signal: parent set isFocused to false
        // while the field was first responder → resign.
        if !isFocused && tf.isFirstResponder {
            tf.resignFirstResponder()
        }
        context.coordinator.onSubmit = onSubmit
        context.coordinator.textBinding = $text
        context.coordinator.focusBinding = $isFocused
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            textBinding: $text,
            focusBinding: $isFocused,
            onSubmit: onSubmit,
        )
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var textBinding: Binding<String>
        var focusBinding: Binding<Bool>
        var onSubmit: () -> Void

        init(
            textBinding: Binding<String>,
            focusBinding: Binding<Bool>,
            onSubmit: @escaping () -> Void
        ) {
            self.textBinding = textBinding
            self.focusBinding = focusBinding
            self.onSubmit = onSubmit
        }

        @objc func editingChanged(_ tf: UITextField) {
            textBinding.wrappedValue = tf.text ?? ""
        }

        @objc func returnPressed(_ tf: UITextField) {
            // editingDidEndOnExit fires AFTER the field has resigned
            // first responder. The empty-guard and in-flight-guard live
            // in manager.sendDraft(), so a redundant return on an empty
            // field is a no-op there. Re-focus is the caller's job —
            // sendDraft clears `draft` on success, which flows back as
            // an empty field with focus retained on iOS-standard
            // behavior. (UITextField actually loses focus here because
            // editingDidEndOnExit implies resign; if discoverability
            // testing shows users want to keep typing after send, we
            // can call becomeFirstResponder() after onSubmit returns.)
            onSubmit()
        }

        nonisolated func textFieldDidBeginEditing(_ tf: UITextField) {
            Task { @MainActor in
                if !focusBinding.wrappedValue { focusBinding.wrappedValue = true }
            }
        }

        nonisolated func textFieldDidEndEditing(_ tf: UITextField) {
            Task { @MainActor in
                if focusBinding.wrappedValue { focusBinding.wrappedValue = false }
            }
        }
    }
}
