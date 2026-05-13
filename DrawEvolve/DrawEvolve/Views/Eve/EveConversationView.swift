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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(starterPrompts, id: \.self) { prompt in
                    Button {
                        sendStarterPrompt(prompt)
                    } label: {
                        Text(prompt)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(Color(uiColor: .secondarySystemBackground))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.conversation == nil || manager.sendState == .sending)
                }
            }
            .padding(.horizontal, 16)
        }
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
// ThinkingDots — small animated three-dot indicator
// =============================================================================
//
// Pure SwiftUI, no images. Three dots pulse in sequence using a
// repeating timeline. Lives in this file because it's only used here;
// promote to Components/ if a second caller appears.

private struct ThinkingDots: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .frame(width: 6, height: 6)
                    .foregroundColor(.secondary)
                    .opacity(phase == i ? 1.0 : 0.35)
            }
        }
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}
