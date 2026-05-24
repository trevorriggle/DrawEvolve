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
//  draws the chrome (header with browse-conversations + dismiss X,
//  EveConversationView, and the frame). Presentation routing is the
//  caller's concern, mirroring how FloatingFeedbackPanel works.
//
//  Conversation identity is mutable: the host stores the active
//  conversation id as @State and forces the inner container's
//  StateObject manager to be torn down + re-created via .id() whenever
//  the id changes. This is what powers the "browse list → tap a row →
//  swap to that conversation in-place" UX. The user sees a brief
//  loading spinner during the swap — that's the "you switched"
//  signal. In-flight draft text is intentionally not preserved across
//  switches.
//

import SwiftUI

struct EveSheetHost: View {
    // Caller-provided seed values for the initial conversation. These
    // feed the inner container's first construction; once the user
    // swaps to a different conversation via the in-Eve list, the
    // container is re-created with `existingConversationId =
    // currentConversationId` and the scope/drawing/critique seeds are
    // overwritten by whatever the persisted conversation says.
    private let initialScope: EveScope?
    private let initialDrawingId: UUID?
    private let initialCritiqueSequence: Int?
    private let initialDrawingTitle: String?
    private let captureCanvas: (() -> Data?)?

    var onClose: () -> Void

    // Mutable identity for the active conversation. nil = "fresh,
    // seeded from initialScope" (the create path). Non-nil = "resume
    // this conversation". Bumping this triggers the inner container's
    // .id() to change, destroying + re-creating the manager.
    @State private var currentConversationId: UUID?

    // Stable .id() sentinel for the "fresh conversation" state.
    // Captured once at construction so re-renders don't churn the
    // inner StateObject. UUID() per-host-instance is fine — the host
    // is constructed exactly once per "open Eve" session.
    @State private var freshSentinelId = UUID()

    @State private var showList = false

    // Mirror of the active container's `manager.hasUnsentText`,
    // propagated up via a binding so this host can drive
    // `interactiveDismissDisabled`. Resets to false on every container
    // tear-down (the new container has an empty draft).
    @State private var hasUnsentText = false

    init(
        scope: EveScope? = nil,
        drawingId: UUID? = nil,
        critiqueSequence: Int? = nil,
        drawingTitle: String? = nil,
        captureCanvas: (() -> Data?)? = nil,
        existingConversationId: UUID? = nil,
        onClose: @escaping () -> Void,
    ) {
        self.initialScope = scope
        self.initialDrawingId = drawingId
        self.initialCritiqueSequence = critiqueSequence
        self.initialDrawingTitle = drawingTitle
        self.captureCanvas = captureCanvas
        self.onClose = onClose
        _currentConversationId = State(initialValue: existingConversationId)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            EveConversationContainer(
                scope: initialScope,
                drawingId: initialDrawingId,
                critiqueSequence: initialCritiqueSequence,
                drawingTitle: initialDrawingTitle,
                captureCanvas: captureCanvas,
                existingConversationId: currentConversationId,
                hasUnsentText: $hasUnsentText
            )
            // Identity-swap mechanism: when the user picks a different
            // conversation from the in-Eve list, currentConversationId
            // changes and SwiftUI tears down the container (and its
            // StateObject manager) then re-creates it. The freshSentinelId
            // fallback keeps the id stable across re-renders while
            // currentConversationId is nil.
            .id(currentConversationId ?? freshSentinelId)
        }
        .background(Color(uiColor: .systemBackground))
        // Block iPhone's interactive swipe-down dismiss when the user
        // has unsent text — losing a half-typed message to an accidental
        // swipe broke too much trust. The X button still dismisses.
        // Harmless no-op on iPad (overlay presentation, not a sheet).
        .interactiveDismissDisabled(hasUnsentText)
        .sheet(isPresented: $showList) {
            EveConversationListView(
                onClose: { showList = false },
                onSelect: { id in
                    // Swap conversation identity. Dismiss the list in
                    // the same tick so the user lands directly in the
                    // resumed conversation. The .id() bump on the
                    // container then forces a fresh manager hydrate.
                    currentConversationId = id
                    showList = false
                }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: { showList = true }) {
                Image(systemName: "list.bullet")
                    .foregroundColor(.secondary)
                    .font(.title3)
            }
            .accessibilityLabel("Browse conversations")

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

// =============================================================================
// EveConversationContainer — owns the per-conversation StateObject manager
// =============================================================================
//
// Wrapping the manager + EveConversationView in this thin container lets
// the parent EveSheetHost swap conversation identity via SwiftUI's
// .id() mechanism without losing host-level state (header visibility,
// list sheet binding, etc.). When .id() changes on the container, the
// @StateObject manager is torn down and a fresh one is constructed via
// the init below — picking up whatever existingConversationId the host
// passed in this render pass.
//
// The hasUnsentText binding is the only piece of inner state that leaks
// back up to the host (so the host can drive interactiveDismissDisabled).
// An onChange observes the manager's draft and pushes the derived
// `hasUnsentText` upward.

private struct EveConversationContainer: View {
    @StateObject private var manager: EveConversationManager
    @Binding var hasUnsentText: Bool

    init(
        scope: EveScope?,
        drawingId: UUID?,
        critiqueSequence: Int?,
        drawingTitle: String?,
        captureCanvas: (() -> Data?)?,
        existingConversationId: UUID?,
        hasUnsentText: Binding<Bool>,
    ) {
        _manager = StateObject(wrappedValue: EveConversationManager(
            scope: scope,
            drawingId: drawingId,
            critiqueSequence: critiqueSequence,
            drawingTitle: drawingTitle,
            captureCanvas: captureCanvas,
            existingConversationId: existingConversationId,
        ))
        _hasUnsentText = hasUnsentText
    }

    var body: some View {
        EveConversationView(manager: manager)
            .onChange(of: manager.draft) { _, _ in
                let next = manager.hasUnsentText
                if hasUnsentText != next {
                    hasUnsentText = next
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
    }
}
