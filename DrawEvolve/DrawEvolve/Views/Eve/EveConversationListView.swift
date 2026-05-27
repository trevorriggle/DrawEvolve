//
//  EveConversationListView.swift
//  DrawEvolve
//
//  Lists the user's past Eve conversations, most-recent activity first.
//  Per the Phase 3b restructure, this view is the ROOT of EveSheetHost's
//  NavigationStack (rather than a sheet-popover stacked on top). Tapping
//  a row invokes `onSelect(id)` — the host appends an .existing(id)
//  destination to its NavigationPath, which pushes a fresh
//  EveConversationContainer to hydrate that conversation.
//
//  Chrome (navigationTitle, toolbar X, "+ New Chat") is owned by the
//  host. This view provides only content + the load lifecycle.
//

import SwiftUI

struct EveConversationListView: View {
    var onSelect: (UUID) -> Void

    @StateObject private var model = EveConversationListModel()

    var body: some View {
        content
            .task {
                if case .idle = model.loadState {
                    await model.load()
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
        List {
            Section {
                ForEach(model.conversations) { conversation in
                    Button {
                        onSelect(conversation.id)
                    } label: {
                        ConversationRow(conversation: conversation)
                    }
                    .buttonStyle(.plain)
                    // Mirrors GalleryView.swift:497 — allowsFullSwipe:false
                    // because accidental full-swipe deletes on a coaching
                    // log would feel terrible. Optimistic remove + server
                    // rollback handled in EveConversationListModel.delete.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await model.delete(id: conversation.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                // Always-on subtitle setting expectations about the cap.
                // No per-eviction banner per product decision — silent
                // eviction is intentional. This footer just makes the
                // policy discoverable without surprise.
                Text("Showing 50 most recent — older chats are archived automatically.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        // Optimistic-delete rollback surfaces here. Binding's setter
        // clears the message when the user dismisses the alert.
        .alert(
            "Couldn't delete",
            isPresented: Binding(
                get: { model.deleteErrorMessage != nil },
                set: { if !$0 { model.deleteErrorMessage = nil } }
            ),
            presenting: model.deleteErrorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }
}

// =============================================================================
// Row
// =============================================================================

private struct ConversationRow: View {
    let conversation: EveConversation

    var body: some View {
        HStack(spacing: 12) {
            // Unified icon for all rows per Phase 3d — dropped the two-
            // bubble symbol that used to distinguish critique-attached.
            // Context is conveyed by the "From critique #N" subtitle
            // instead, which reads cleaner with less visual noise.
            Image(systemName: "bubble.left")
                .font(.system(size: 18))
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayPreview)
                    .font(.headline)
                    .lineLimit(1)

                if let critiqueSubtitle {
                    Text(critiqueSubtitle)
                        .font(.caption2)
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

    // Per Path Y read order: first_user_message → title → "New chat".
    // The "New chat" fallback only appears during the brief window
    // between "+ New Chat" tap and first message send; afterward the
    // worker stamps first_user_message and the next list refresh swaps
    // the label. Title is the back-compat fallback for pre-0016 rows
    // the SQL backfill couldn't populate. Word-boundary truncation at
    // ~60 chars so list rows stay readable on iPhone.
    private var displayPreview: String {
        if let first = conversation.firstUserMessage, !first.isEmpty {
            return first.truncatedAtWordBoundary(maxLen: 60)
        }
        if let title = conversation.title, !title.isEmpty {
            return title.truncatedAtWordBoundary(maxLen: 60)
        }
        return "New chat"
    }

    // Optional second line for critique-anchored conversations. Skipped
    // for general / unscoped rows so they read as a single tight line.
    private var critiqueSubtitle: String? {
        guard conversation.scope == .drawing,
              let seq = conversation.scopeCritiqueSequence else { return nil }
        return "From critique #\(seq)"
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
    // Surfaced via .alert in the list view. Set when an optimistic delete
    // had to roll back. The view binds a Bool around `!= nil` for .alert
    // presentation, then clears on dismiss.
    @Published var deleteErrorMessage: String? = nil

    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(message: String)
    }

    private static let defaultFailureCopy = "Couldn't load your conversations. Please try again."
    private static let defaultDeleteFailureCopy = "Couldn't delete that conversation. Please try again."

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

    /// Optimistically remove from the local array, then await the server
    /// delete. On failure, re-insert at the original index and surface an
    /// error message for the view's .alert. softDeleteConversation server-
    /// side is idempotent — a double-tap during animation that fires the
    /// delete twice would no-op on the second call.
    func delete(id: UUID) async {
        guard let originalIndex = conversations.firstIndex(where: { $0.id == id }) else {
            return
        }
        let removed = conversations.remove(at: originalIndex)
        do {
            try await EveService.shared.deleteConversation(id: id)
        } catch let err as EveServiceError {
            conversations.insert(removed, at: originalIndex)
            deleteErrorMessage = err.errorDescription ?? Self.defaultDeleteFailureCopy
        } catch {
            conversations.insert(removed, at: originalIndex)
            deleteErrorMessage = Self.defaultDeleteFailureCopy
        }
    }
}
