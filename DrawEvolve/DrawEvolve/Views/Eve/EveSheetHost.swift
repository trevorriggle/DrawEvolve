//
//  EveSheetHost.swift
//  DrawEvolve
//
//  Top-level Eve UI. iMessage-pattern: a NavigationStack with the
//  conversation list as root, individual conversations pushed as
//  destinations. Per the EVE-PATCHES restructure (Phase 3b).
//
//  Two presentation modes branch on the caller's intent:
//    - .openOnList: NavigationStack with EveConversationListView as
//      root. User browses, taps a row to push that conversation, or
//      taps "+ New Chat" in the toolbar to push a fresh one. Back
//      arrow returns to the list. X dismisses the whole sheet.
//      Entered from the canvas Eve icon (general scope).
//    - .openOnNewConversation(...): NavigationStack wrapping a SINGLE
//      conversation view directly. No list visible, no back arrow.
//      X dismisses the whole sheet → returns to canvas. Entered from
//      the "Ask Eve" buttons on critique panels (drawing scope), where
//      the user has explicit task intent and the list would be the
//      wrong UX.
//
//  Idiom routing (sheet vs overlay) is the parent's concern, same as
//  FloatingFeedbackPanel — DrawingCanvasView wraps this in `.sheet`
//  on iPhone and a ZStack overlay on iPad.
//
//  Conversation creation timing: for .openOnList, no conversation is
//  created on sheet-open. Creation happens when the user taps "+ New
//  Chat" (which pushes a destination whose container has
//  existingConversationId=nil, triggering manager.start()'s create
//  path). For .openOnNewConversation, creation happens on first render
//  of the pushed destination, same mechanism. This eliminates the
//  empty-chat-on-open bug at its source for the .openOnList path.
//
//  §6 cleanup contract (in-session empty conversations): the host
//  maintains a Set<UUID> of every conversation that became active
//  during this sheet's lifecycle plus a snapshot dict of each one's
//  most recent observed message_count. On host .onDisappear (which
//  fires once when the sheet is being dismissed on both iPhone and
//  iPad), iterate the Set, and for each id where the snapshot count
//  is 0 (or missing-defensive-treat-as-0), fire-and-forget
//  EveService.deleteConversation. The snapshot is updated on every
//  observed messages.count change by the container's .onChange, so
//  it reflects the latest state of any container alive during the
//  session — handles the nav-back-then-add-messages case. Cleanup
//  does NOT fire on navigation pop/push — only on host .onDisappear.
//

import SwiftUI

struct EveSheetHost: View {

    // =============================================================================
    // Intent — what the caller wants when the sheet opens
    // =============================================================================

    enum EveOpenIntent {
        case openOnList
        case openOnNewConversation(
            scope: EveScope,
            drawingId: UUID?,
            critiqueSequence: Int?,
            drawingTitle: String?
        )
    }

    // =============================================================================
    // Init parameters
    // =============================================================================

    private let intent: EveOpenIntent
    private let captureCanvas: (() -> Data?)?
    var onClose: () -> Void

    // =============================================================================
    // Sheet-lifecycle state — owned by the host, survives nav
    // =============================================================================

    // §6 fix: every conversation that became active during this sheet's
    // lifetime. Ids are NEVER removed mid-session. The dismiss-time
    // cleanup iterates this and gates each on the message-count snapshot.
    @State private var touchedConversationIds: Set<UUID> = []

    // Snapshot of each touched conversation's observed message_count.
    // Updated on every container .onChange of manager.messages.count.
    // Persists across navigation pushes/pops — when a container is torn
    // down (nav-back) and a new one hydrates the same conversation later,
    // the new container's .onChange picks up where the old one left off
    // and pushes the fresh count.
    @State private var conversationMessageCounts: [UUID: Int] = [:]

    // hasUnsentText state, mirrored up from whichever container is
    // currently showing. Used to gate iPhone interactive swipe-down
    // dismiss (.interactiveDismissDisabled). Reset to false by the
    // container's .onDisappear so nav-back to the list (or to a fresh
    // conversation) doesn't keep the dismiss block on stale state.
    @State private var hasUnsentText = false

    // Navigation path for the .openOnList intent. The list root never
    // pushes itself; destinations are appended via "+ New Chat" or row
    // selection from the list.
    @State private var path: [EveConversationDestination] = []

    init(
        intent: EveOpenIntent,
        captureCanvas: (() -> Data?)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.intent = intent
        self.captureCanvas = captureCanvas
        self.onClose = onClose
    }

    var body: some View {
        Group {
            switch intent {
            case .openOnList:
                listRootStack
            case let .openOnNewConversation(scope, drawingId, critiqueSequence, drawingTitle):
                directConversationStack(
                    scope: scope,
                    drawingId: drawingId,
                    critiqueSequence: critiqueSequence,
                    drawingTitle: drawingTitle
                )
            }
        }
        .interactiveDismissDisabled(hasUnsentText)
        .onDisappear {
            // Single cleanup site for both iPhone (.sheet teardown) and
            // iPad (overlay removal via showEve=false). Fire-and-forget
            // deletes for every touched conversation whose snapshot
            // count is 0 at dismiss time.
            cleanupEmptyTouchedConversations()
        }
    }

    // =============================================================================
    // List-root flow (.openOnList)
    // =============================================================================

    @ViewBuilder
    private var listRootStack: some View {
        NavigationStack(path: $path) {
            EveConversationListView(
                onSelect: { id in
                    path.append(.existing(id))
                }
            )
            .navigationTitle("Eve")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    closeButton
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        path.append(.new)
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                }
            }
            .navigationDestination(for: EveConversationDestination.self) { dest in
                pushedConversationView(for: dest)
            }
        }
    }

    @ViewBuilder
    private func pushedConversationView(for dest: EveConversationDestination) -> some View {
        switch dest {
        case .new:
            // Fresh general-scope conversation. existingConversationId=nil
            // triggers manager.start()'s create path. The user's "+ New
            // Chat" tap is the explicit creation moment, replacing the
            // old empty-on-open bug.
            EveConversationContainer(
                scope: .general,
                drawingId: nil,
                critiqueSequence: nil,
                drawingTitle: nil,
                captureCanvas: captureCanvas,
                existingConversationId: nil,
                hasUnsentText: $hasUnsentText,
                touchedConversationIds: $touchedConversationIds,
                conversationMessageCounts: $conversationMessageCounts
            )
        case .existing(let id):
            // Resume a server-persisted conversation. The container's
            // manager hydrates scope/drawing/critique from the row.
            EveConversationContainer(
                scope: nil,
                drawingId: nil,
                critiqueSequence: nil,
                drawingTitle: nil,
                captureCanvas: captureCanvas,
                existingConversationId: id,
                hasUnsentText: $hasUnsentText,
                touchedConversationIds: $touchedConversationIds,
                conversationMessageCounts: $conversationMessageCounts
            )
        }
    }

    // =============================================================================
    // Direct-conversation flow (.openOnNewConversation)
    // =============================================================================

    @ViewBuilder
    private func directConversationStack(
        scope: EveScope,
        drawingId: UUID?,
        critiqueSequence: Int?,
        drawingTitle: String?
    ) -> some View {
        NavigationStack {
            EveConversationContainer(
                scope: scope,
                drawingId: drawingId,
                critiqueSequence: critiqueSequence,
                drawingTitle: drawingTitle,
                captureCanvas: captureCanvas,
                existingConversationId: nil,
                hasUnsentText: $hasUnsentText,
                touchedConversationIds: $touchedConversationIds,
                conversationMessageCounts: $conversationMessageCounts
            )
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    closeButton
                }
            }
        }
    }

    // =============================================================================
    // Shared chrome
    // =============================================================================

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.secondary)
                .font(.title3)
        }
        .accessibilityLabel("Close")
    }

    // =============================================================================
    // Cleanup
    // =============================================================================

    private func cleanupEmptyTouchedConversations() {
        // Snapshot copies so the Task captures stable values; the @State
        // may mutate during teardown and we don't want races.
        let ids = touchedConversationIds
        let dictFallback = conversationMessageCounts
        guard !ids.isEmpty else { return }

        Task.detached {
            // Authoritative re-read at gate time per user adjustment F.
            // The dict-only path was vulnerable to a theoretical race
            // where a .onChange update could be queued behind .onDisappear
            // and leave a stale 0 — wrongly deleting a non-empty
            // conversation. Refetching from the server eliminates that
            // window. One round trip total, not N — listConversations
            // returns all of the user's non-deleted rows.
            //
            // The detached Task runs after the sheet has already dismissed
            // (.onDisappear is post-dismiss), so this network latency is
            // not user-visible.
            let serverCounts: [UUID: Int]
            var usedFallback = false
            do {
                let rows = try await EveService.shared.listConversations()
                var map: [UUID: Int] = [:]
                for row in rows { map[row.id] = row.messageCount }
                serverCounts = map
            } catch {
                // Network or auth blip. Fall back to the local dict —
                // better than skipping cleanup entirely or risking false
                // deletes. Log so a repeated occurrence is visible.
                print("[Eve] cleanup listConversations failed, using local dict — \(error)")
                serverCounts = [:]
                usedFallback = true
            }

            for id in ids {
                let shouldDelete: Bool
                if usedFallback {
                    // Fallback path: trust the dict.
                    shouldDelete = (dictFallback[id] ?? 0) == 0
                } else if let serverCount = serverCounts[id] {
                    // Authoritative path: server says X messages.
                    shouldDelete = serverCount == 0
                } else {
                    // Id not in the server's list → already deleted
                    // (deleted_at IS NULL filter excluded it). Skip;
                    // no double-delete.
                    shouldDelete = false
                }

                if shouldDelete {
                    try? await EveService.shared.deleteConversation(id: id)
                }
            }
        }
    }
}

// =============================================================================
// Navigation destinations for the .openOnList path
// =============================================================================

enum EveConversationDestination: Hashable {
    case new                  // user tapped "+ New Chat" — create on first render
    case existing(UUID)       // user tapped a row — resume by id
}

// =============================================================================
// EveConversationContainer — owns the per-conversation StateObject manager
// =============================================================================
//
// Wrapping the manager + EveConversationView in this thin container lets
// the parent EveSheetHost use NavigationStack push/pop to swap which
// conversation is active. Each push of a `.new` or `.existing` destination
// constructs a fresh container (and thus a fresh @StateObject manager).
// Navigation pop tears the container down.
//
// Bindings out to the host:
//   - hasUnsentText: drives the host's interactiveDismissDisabled. The
//     container's .onChange of manager.draft pushes upward; .onDisappear
//     resets to false so nav-back doesn't keep stale dismiss-blocks alive.
//     This is the ONLY job of .onDisappear here — see CRITICAL note below.
//   - touchedConversationIds + conversationMessageCounts: the §6 cleanup
//     state. The container observes manager.conversation?.id and inserts
//     into the Set on first appearance, then observes manager.messages.count
//     and updates the snapshot dict on every change.
//
// CRITICAL: .onDisappear here does ONE thing — reset hasUnsentText. It
// does NOT iterate touchedConversationIds, does NOT call deleteConversation.
// Empty-chat cleanup is owned by the host's .onDisappear (which fires
// once on sheet dismissal). Conflating them would cause the cleanup to
// fire on every nav-back, which is the wrong trigger.

private struct EveConversationContainer: View {
    @StateObject private var manager: EveConversationManager
    @Binding var hasUnsentText: Bool
    @Binding var touchedConversationIds: Set<UUID>
    @Binding var conversationMessageCounts: [UUID: Int]

    init(
        scope: EveScope?,
        drawingId: UUID?,
        critiqueSequence: Int?,
        drawingTitle: String?,
        captureCanvas: (() -> Data?)?,
        existingConversationId: UUID?,
        hasUnsentText: Binding<Bool>,
        touchedConversationIds: Binding<Set<UUID>>,
        conversationMessageCounts: Binding<[UUID: Int]>
    ) {
        _manager = StateObject(wrappedValue: EveConversationManager(
            scope: scope,
            drawingId: drawingId,
            critiqueSequence: critiqueSequence,
            drawingTitle: drawingTitle,
            captureCanvas: captureCanvas,
            existingConversationId: existingConversationId
        ))
        _hasUnsentText = hasUnsentText
        _touchedConversationIds = touchedConversationIds
        _conversationMessageCounts = conversationMessageCounts
    }

    var body: some View {
        EveConversationView(manager: manager)
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: manager.draft) { _, _ in
                let next = manager.hasUnsentText
                if hasUnsentText != next {
                    hasUnsentText = next
                }
            }
            .onChange(of: manager.conversation?.id) { _, newId in
                guard let newId else { return }
                if !touchedConversationIds.contains(newId) {
                    touchedConversationIds.insert(newId)
                }
                // Seed the snapshot with the current count on first
                // observation. Subsequent .onChange-of-messages.count
                // keeps it live.
                conversationMessageCounts[newId] = manager.messages.count
            }
            .onChange(of: manager.messages.count) { _, newCount in
                if let id = manager.conversation?.id {
                    conversationMessageCounts[id] = newCount
                }
            }
            .onAppear {
                // Fresh container: draft is empty, so the host's flag
                // resets. Critical on conversation switch — the previous
                // container's flag may have been true.
                if hasUnsentText {
                    hasUnsentText = false
                }
            }
            .onDisappear {
                // ONLY job: reset hasUnsentText so the host stops
                // blocking dismissal once this container is gone.
                // Empty-chat cleanup is the host's job, not ours.
                if hasUnsentText {
                    hasUnsentText = false
                }
            }
    }

    // Nav title computed from manager state per the Path Y read order:
    // firstUserMessage > title > "Eve" fallback. Word-boundary truncation
    // for readability — ~40 chars works for the iPhone/iPad inline title.
    private var navTitle: String {
        if let first = manager.conversation?.firstUserMessage,
           !first.isEmpty {
            return first.truncatedAtWordBoundary(maxLen: 40, ellipsis: "…")
        }
        if let title = manager.conversation?.title, !title.isEmpty {
            return title.truncatedAtWordBoundary(maxLen: 40, ellipsis: "…")
        }
        return "Eve"
    }
}
