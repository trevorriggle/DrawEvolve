//
//  EveConversationView.swift
//  DrawEvolve
//
//  The chat thread. Composes EveContextChip (header), a scrolling list
//  of EveMessageBubble rows, and EveInputBar (footer). On first appear,
//  kicks off manager.start() which boots a new conversation server-side
//  and seeds the empty thread.
//
//  Auto-scroll behavior: when a new message arrives (either user-sent
//  or assistant-received), the ScrollView snaps to the bottom. We do
//  NOT auto-scroll on every tiny render to avoid yanking the view while
//  the user is reading.
//

import SwiftUI

struct EveConversationView: View {
    @ObservedObject var manager: EveConversationManager

    var body: some View {
        VStack(spacing: 0) {
            EveContextChip(
                scope: manager.scope,
                drawingTitle: manager.initialDrawingTitle,
            )

            Divider()

            messageList

            // Canvas-attach affordance — pill above the input bar. Only
            // renders on managers constructed from the canvas view
            // (canAttachCanvas == true). Two visual states: idle pill
            // ("+ Show Eve my canvas") and attached chip ("📎 Canvas
            // attached" with X). Tapping idle captures the canvas via
            // the manager's captureCanvas closure.
            if manager.canAttachCanvas {
                EveCanvasAttachRow(manager: manager)
            }

            EveInputBar(manager: manager)
        }
        .background(Color(uiColor: .systemBackground))
        .task {
            await manager.start()
        }
    }

    // =============================================================================
    // Message list
    // =============================================================================

    @ViewBuilder
    private var messageList: some View {
        switch manager.loadState {
        case .idle, .loading:
            loadingState
        case .failed(let message):
            failedState(message: message)
        case .ready:
            scrollableThread
        }
    }

    private var loadingState: some View {
        VStack {
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
            Text("Starting a conversation with Eve…")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.top, 12)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    private func failedState(message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundColor(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Try again") {
                Task { await manager.start() }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    private var scrollableThread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if manager.messages.isEmpty {
                        emptyOpener
                    }
                    ForEach(visibleMessages) { msg in
                        EveMessageBubble(message: msg)
                            .id(msg.id)
                    }
                    if manager.sendState == .sending {
                        thinkingIndicator
                            .id("eve-thinking")
                    }
                }
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemBackground))
            .onChange(of: manager.messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: manager.sendState) { _, newValue in
                if newValue == .sending {
                    scrollToBottom(proxy: proxy)
                }
            }
        }
    }

    // Filter tool turns out of the rendered list. Defense in depth — the
    // worker already strips them when assembling OpenAI messages, but
    // future 2C tool turns might end up in the persisted history and
    // the chat UI shouldn't suddenly start showing "[tool result]" rows.
    private var visibleMessages: [EveMessage] {
        manager.messages.filter { $0.role != .tool }
    }

    private var emptyOpener: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 24)
            Text(openerCopy)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            starterChips

            Spacer().frame(height: 24)
        }
    }

    private var openerCopy: String {
        switch manager.scope {
        case .drawing:
            return "I've read this critique. What do you want to dig into?"
        case .general:
            return "I don't have a specific critique pulled up — what's on your mind?"
        case .evolution:
            return "Looking at your work overall — what do you want to talk about?"
        }
    }

    // =============================================================================
    // Starter chips
    // =============================================================================
    //
    // Scope-aware tappable prompts solve the chatbot cold-start problem:
    // a blank "Ask Eve…" field tells users nothing about what she knows or
    // what to ask. Each chip both teaches a use case AND sends the
    // message in one tap — Eve's response demonstrates her capability.
    // Chips disappear naturally once messages.isEmpty flips false (the
    // optimistic user-message append in sendDraft fires the moment they
    // tap a chip).

    private var starterChips: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
            ],
            spacing: 10,
        ) {
            ForEach(starterPrompts, id: \.self) { prompt in
                Button {
                    sendStarterPrompt(prompt)
                } label: {
                    Text(prompt)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(uiColor: .secondarySystemBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .disabled(manager.conversation == nil || manager.sendState == .sending)
            }
        }
        .padding(.horizontal, 24)
    }

    private var starterPrompts: [String] {
        switch manager.scope {
        case .drawing:
            return [
                "Walk me through the last critique",
                "What should I work on next?",
                "Why doesn't this feel balanced?",
                "Suggest a focused exercise",
            ]
        case .general:
            return [
                "What should I draw today?",
                "How do I improve at proportions?",
                "Recommend an exercise for shading",
                "What are common beginner mistakes?",
            ]
        case .evolution:
            return [
                "What patterns do you see in my work?",
                "Where am I improving fastest?",
                "What should I focus on next month?",
                "Which fundamental needs the most work?",
            ]
        }
    }

    private func sendStarterPrompt(_ prompt: String) {
        manager.draft = prompt
        Task { await manager.sendDraft() }
    }

    private var thinkingIndicator: some View {
        HStack(alignment: .top) {
            HStack(spacing: 6) {
                ThinkingDots()
                Text("Eve is thinking…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 12)
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        // Anchor the scroll to the thinking indicator when present (it
        // lives below the last message), otherwise to the last visible
        // message. Wrapped in withAnimation for a soft slide rather than
        // a hard snap.
        withAnimation(.easeOut(duration: 0.18)) {
            if manager.sendState == .sending {
                proxy.scrollTo("eve-thinking", anchor: .bottom)
            } else if let last = visibleMessages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

// =============================================================================
// EveCanvasAttachRow — "+ Show Eve my canvas" pill / "Canvas attached" chip
// =============================================================================
//
// Sits between the message list and the input bar when the manager was
// constructed by the canvas-view entry point. Two visual states driven
// by manager.hasAttachedCanvas:
//   - idle:     tappable pill "+ Show Eve my canvas"
//   - attached: chip "📎 Canvas attached" with an X to clear
//
// On tap (idle), calls manager.captureAndAttachCanvas() which invokes
// the canvas-capture closure the manager was constructed with. Failure
// flashes a brief inline message; the user can tap the pill again to
// retry. Disabled while a send is in flight so the user can't change
// the attachment mid-request.

private struct EveCanvasAttachRow: View {
    @ObservedObject var manager: EveConversationManager
    @State private var captureFailedFlash = false

    var body: some View {
        HStack(spacing: 8) {
            if manager.hasAttachedCanvas {
                attachedChip
            } else {
                idlePill
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(uiColor: .systemBackground))
    }

    private var idlePill: some View {
        Button {
            let ok = manager.captureAndAttachCanvas()
            if !ok { flashFailure() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .imageScale(.small)
                Text(captureFailedFlash ? "Couldn't capture canvas — try again" : "Show Eve my canvas")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundColor(captureFailedFlash ? .orange : .accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(Color(uiColor: .secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
        .disabled(manager.sendState == .sending)
        .accessibilityLabel("Show Eve my current canvas")
    }

    private var attachedChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperclip")
                .imageScale(.small)
                .foregroundColor(.accentColor)
            Text("Canvas attached")
                .font(.subheadline.weight(.medium))
                .foregroundColor(.primary)
            Button {
                manager.clearAttachedCanvas()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.small)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove canvas attachment")
            .disabled(manager.sendState == .sending)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(Color.accentColor.opacity(0.12))
        )
    }

    private func flashFailure() {
        captureFailedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            captureFailedFlash = false
        }
    }
}

// =============================================================================
// ThinkingDots — small animated three-dot indicator
// =============================================================================
//
// Pure SwiftUI, no images. Three dots pulse in sequence on a TimelineView
// schedule. SwiftUI auto-pauses TimelineView when the view is offscreen,
// so dismissing the Eve sheet stops the animation cost without manual
// timer-cancel bookkeeping. Phase is derived from absolute time, so
// dropped frames or re-renders never desync the pulse.

private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .frame(width: 6, height: 6)
                        .foregroundColor(.secondary)
                        .opacity(phase == i ? 1.0 : 0.35)
                }
            }
        }
    }
}
