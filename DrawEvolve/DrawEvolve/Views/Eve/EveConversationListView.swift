//
//  EveConversationListView.swift
//  DrawEvolve
//
//  Lists the user's past Eve conversations, most-recent activity first.
//  Presented as a sheet from inside EveSheetHost via the in-Eve list
//  button (see EveSheetHost.swift). Tapping a row invokes `onSelect(id)`
//  — the parent host swaps its `currentConversationId` state, which
//  changes the inner container's `.id()` and forces a fresh
//  EveConversationManager to hydrate the picked conversation. The list
//  itself never presents another sheet; selection routes back to the
//  host that already owns the Eve surface.
//

import SwiftUI

struct EveConversationListView: View {
    var onClose: () -> Void
    var onSelect: (UUID) -> Void

    @StateObject private var model = EveConversationListModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Conversations with Eve")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Done", action: onClose)
                    }
                }
                .task {
                    if case .idle = model.loadState {
                        await model.load()
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .idle, .loading:
            loadingView
        case .ready:
            if model.conversations.isEmpty {
                emptyView
            } else {
                listView
            }
        case .failed(let message):
            errorView(message: message)
        }
    }

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No conversations yet")
                .font(.headline)
            Text("Start one from the canvas or from any past critique.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try again") {
                Task { await model.load() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listView: some View {
        List(model.conversations) { conversation in
            Button {
                onSelect(conversation.id)
            } label: {
                ConversationRow(conversation: conversation)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.insetGrouped)
    }
}

// =============================================================================
// Row
// =============================================================================

private struct ConversationRow: View {
    let conversation: EveConversation

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: leadingSymbol)
                .font(.system(size: 18))
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let critiqueBadge {
                        Text(critiqueBadge)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(messageCountLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(relativeTimestamp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var leadingSymbol: String {
        conversation.scope == .drawing
            ? "bubble.left.and.bubble.right"
            : "bubble.left.fill"
    }

    private var displayTitle: String {
        if let title = conversation.title, !title.isEmpty { return title }
        return "Eve session"
    }

    private var critiqueBadge: String? {
        guard conversation.scope == .drawing,
              let seq = conversation.scopeCritiqueSequence else { return nil }
        return "From critique #\(seq)"
    }

    private var messageCountLabel: String {
        conversation.messageCount == 1 ? "1 message" : "\(conversation.messageCount) messages"
    }

    private var relativeTimestamp: String {
        Self.relativeFormatter.localizedString(
            for: conversation.lastMessageAt,
            relativeTo: Date()
        )
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

// =============================================================================
// Model
// =============================================================================

@MainActor
private final class EveConversationListModel: ObservableObject {
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var conversations: [EveConversation] = []

    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(message: String)
    }

    private static let defaultFailureCopy = "Couldn't load your conversations. Please try again."

    func load() async {
        loadState = .loading
        do {
            let fetched = try await EveService.shared.listConversations()
            conversations = fetched.sorted { lhs, rhs in
                let lhsKey = max(lhs.lastMessageAt, lhs.createdAt)
                let rhsKey = max(rhs.lastMessageAt, rhs.createdAt)
                return lhsKey > rhsKey
            }
            loadState = .ready
        } catch let err as EveServiceError {
            loadState = .failed(message: err.errorDescription ?? Self.defaultFailureCopy)
        } catch {
            loadState = .failed(message: Self.defaultFailureCopy)
        }
    }
}
