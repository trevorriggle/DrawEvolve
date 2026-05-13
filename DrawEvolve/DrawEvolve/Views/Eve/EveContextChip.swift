//
//  EveContextChip.swift
//  DrawEvolve
//
//  Persistent header chip showing what the current Eve conversation is
//  scoped to. Not dismissible — the user's affordance for trust. Two
//  shapes:
//    - scope=.drawing:    "About your drawing 'Forest at Dusk'"
//    - scope=.general:    "About your work, in general"
//
//  Renders at the top of EveConversationView, above the scroll thread.
//

import SwiftUI

struct EveContextChip: View {
    let scope: EveScope
    let drawingTitle: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: scope == .drawing ? "photo.on.rectangle" : "person.bubble")
                .foregroundColor(.accentColor)
                .imageScale(.small)
            Text(displayText)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var displayText: String {
        switch scope {
        case .drawing:
            if let title = drawingTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                return "About your drawing “\(title)”"
            }
            return "About this drawing"
        case .general:
            return "About your work, in general"
        case .evolution:
            return "About your progress overall"
        }
    }
}
