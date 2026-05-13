//
//  EveMessageBubble.swift
//  DrawEvolve
//
//  Renders one message in the Eve chat thread. User messages are right-
//  aligned in accent color; assistant messages are left-aligned, neutral
//  bubble, markdown-rendered via the existing FormattedMarkdownView
//  (shared with the critique panel).
//
//  Tool turns are filtered out by the conversation view before this
//  bubble ever sees them — so this view only handles .user and
//  .assistant. (.tool falls through to a do-nothing branch as defense
//  in depth.)
//

import SwiftUI

struct EveMessageBubble: View {
    let message: EveMessage

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            assistantBubble
        case .tool:
            EmptyView() // 2A — no tools yet; defense-in-depth.
        }
    }

    private var userBubble: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 40)
            Text(message.content)
                .font(.body)
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
    }

    private var assistantBubble: some View {
        HStack(alignment: .top) {
            FormattedMarkdownView(text: message.content)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 12)
    }
}
