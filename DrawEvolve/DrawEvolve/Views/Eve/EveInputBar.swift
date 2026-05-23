//
//  EveInputBar.swift
//  DrawEvolve
//
//  Pinned-to-bottom multi-line text field + send button + "Eve is
//  thinking…" indicator. Bound to EveConversationManager's `draft` so
//  the parent can preserve what the user typed across re-renders, and
//  so the send button reads the same source as the TextField.
//
//  Send tap: kicks off manager.sendDraft() in a Task. The manager
//  flips sendState to .sending and clears `draft`; this view reacts.
//

import SwiftUI

struct EveInputBar: View {
    @ObservedObject var manager: EveConversationManager
    @FocusState private var isFocused: Bool

    var body: some View {
        // Single send entry point so the keyboard return key and the corner
        // button can't drift out of sync. @MainActor on the Task makes the
        // actor hop into EveConversationManager (also @MainActor) explicit
        // rather than relying on the surrounding View context to inherit it.
        let submit: () -> Void = {
            Task { @MainActor in await manager.sendDraft() }
        }

        return VStack(spacing: 0) {
            // Inline error chip when the last send failed. Tapping the
            // chip clears the error and re-focuses the input so the user
            // can edit + retry.
            if case .failed(let message) = manager.sendState {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .imageScale(.small)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Dismiss") { manager.clearSendError() }
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }

            Divider()

            HStack(alignment: .bottom, spacing: 10) {
                // Multi-line input. The .lineLimit / axis: .vertical
                // pairing gives a softly-growing field that caps at
                // 5 lines so a runaway paste doesn't push the chat
                // off-screen.
                TextField("Ask Eve…", text: $manager.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($isFocused)
                    .keyboardType(.default)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .disabled(manager.sendState == .sending || manager.conversation == nil)
                    .submitLabel(.send)
                    // Return key is the primary send affordance — Christian
                    // (and likely most users) hit return rather than reach for
                    // the corner button. `.submitLabel(.send)` was already
                    // labelling the key correctly, but with no `.onSubmit`
                    // wired the keypress only inserted a newline. Multi-line
                    // composition via return is intentionally NOT supported in
                    // this iteration; if a tester needs it later we'll add a
                    // shift+return or separate newline affordance as its own
                    // task. `sendDraft()`'s internal `!trimmed.isEmpty` guard
                    // keeps an accidental empty-return from firing a no-op
                    // request.
                    .onSubmit { submit() }

                Button {
                    submit()
                } label: {
                    Group {
                        if manager.sendState == .sending {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(sendEnabled ? Color.accentColor : Color.gray.opacity(0.5))
                    .contentShape(Circle())
                    .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!sendEnabled)
                .accessibilityLabel("Send message")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(uiColor: .systemBackground))
        }
        // Clear stale focus when the manager lands a fresh conversation.
        // Why: the M6 "Ask Eve about this" handoff from Eye Test can leave
        // SwiftUI's last-focused-field state pointing at the panel's prior
        // field, which makes the system inherit a compact / number-pad
        // keyboard configuration on first tap. Resetting on conversation
        // arrival ensures the user's first tap into this field starts
        // with no inherited focus context.
        .onChange(of: manager.conversation?.id) { _, _ in
            isFocused = false
        }
    }

    private var sendEnabled: Bool {
        guard manager.conversation != nil else { return false }
        guard manager.sendState != .sending else { return false }
        return !manager.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
