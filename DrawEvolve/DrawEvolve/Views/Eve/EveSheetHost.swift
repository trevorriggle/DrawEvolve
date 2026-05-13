//
//  EveSheetHost.swift
//  DrawEvolve
//
//  Top-level Eve UI. Frames EveConversationView with the chrome each
//  idiom expects:
//    - iPad: floating panel on the right edge, sized like a side drawer.
//            The caller embeds it in their canvas ZStack with a
//            transition; the manager + presentation state lives on
//            the host so the caller can toggle visibility with a single
//            @State Bool.
//    - iPhone: sheet content. The caller attaches `.sheet(isPresented:)`
//            to whatever's appropriate (canvas root, FloatingFeedbackPanel
//            parent, etc.) and passes this view as the content.
//
//  The view itself doesn't know HOW it's being presented — it just
//  draws the chrome (header with dismiss X, EveConversationView, and
//  the frame). Presentation routing is the caller's concern, mirroring
//  how FloatingFeedbackPanel works.
//

import SwiftUI

struct EveSheetHost: View {
    @StateObject private var manager: EveConversationManager
    var onClose: () -> Void

    init(
        scope: EveScope,
        drawingId: UUID? = nil,
        critiqueSequence: Int? = nil,
        drawingTitle: String? = nil,
        onClose: @escaping () -> Void,
    ) {
        _manager = StateObject(wrappedValue: EveConversationManager(
            scope: scope,
            drawingId: drawingId,
            critiqueSequence: critiqueSequence,
            drawingTitle: drawingTitle,
        ))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            EveConversationView(manager: manager)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var header: some View {
        HStack {
            Text("Eve")
                .font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.title3)
            }
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemBackground))
    }
}
