//
//  EveConversationManager.swift
//  DrawEvolve
//
//  @MainActor ObservableObject that owns the currently-open Eve
//  conversation: the conversation row, the message list, and the send
//  state machine (idle / sending / failed).
//
//  One instance per open Eve sheet. The sheet is dismissable, so the
//  manager has a deliberate lifecycle: views construct it on .onAppear,
//  drop the reference on dismissal. We do NOT make this a singleton —
//  multiple conversations could be opened in sequence and each needs
//  its own message list / send state.
//

import Foundation
import SwiftUI

@MainActor
final class EveConversationManager: ObservableObject {

    // =============================================================================
    // Published state — drives the chat thread UI
    // =============================================================================

    @Published private(set) var conversation: EveConversation?
    @Published private(set) var messages: [EveMessage] = []
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var sendState: SendState = .idle

    /// The user's text in the input bar. Bound from EveInputBar's TextField.
    /// Lives here (not in the input bar) so the send button can read it,
    /// and so dismissing + reopening the sheet preserves any in-flight
    /// draft within the same manager lifetime.
    @Published var draft: String = ""

    /// Optional JPEG-encoded canvas snapshot to attach to the next send.
    /// Only ever non-nil when `canAttachCanvas` is true — the
    /// canvas-launched Eve sheet exposes the attach affordance, every
    /// other entry point hides it. Cleared on successful send. Retained
    /// on failure so the user can retry the same shot.
    @Published private(set) var pendingCanvasImage: Data?

    /// Computed convenience for the UI — "should I show the chip?"
    var hasAttachedCanvas: Bool { pendingCanvasImage != nil }

    /// Drives whether the "+ Show Eve my canvas" pill renders. Derived
    /// from whether the caller passed a `captureCanvas` closure — every
    /// canvas-launched entry point provides one, everything else (home,
    /// gallery, critique panel) doesn't. Belt-and-suspenders against
    /// the pill leaking onto entry points that have no canvas to share.
    var canAttachCanvas: Bool { captureCanvas != nil }

    /// Closure that produces a JPEG-encoded snapshot of the current
    /// canvas. Owned by this manager so the pill UI doesn't have to
    /// know anything about MetalCanvasView / CanvasRenderer. nil for
    /// non-canvas-launched entries — the pill won't render.
    private let captureCanvas: (() -> Data?)?

    /// True when the input bar has non-whitespace text the user hasn't
    /// sent yet. Gates iPhone's interactive (swipe-down) sheet dismissal
    /// so an in-progress message isn't lost to an accidental swipe — the
    /// X button still dismisses, since that's a deliberate tap.
    var hasUnsentText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(message: String)
    }

    enum SendState: Equatable {
        case idle
        case sending
        case failed(message: String)
    }

    // =============================================================================
    // Bootstrap
    // =============================================================================

    /// Construct with an explicit scope (to create a fresh conversation)
    /// or an `existingConversationId` (to hydrate one the user is
    /// resuming from the conversation list). When both are supplied,
    /// `existingConversationId` wins — the hydrated conversation's
    /// persisted scope is authoritative and overwrites the passed values
    /// on `start()`.
    ///
    /// These four are `@Published` rather than `let` because the resume
    /// path overwrites them post-hydrate from the fetched conversation;
    /// SwiftUI consumers (EveContextChip, scope-switched UI in
    /// EveConversationView) auto-refresh when they change.
    @Published private(set) var scope: EveScope
    @Published private(set) var scopeDrawingId: UUID?
    @Published private(set) var scopeCritiqueSequence: Int?
    @Published private(set) var initialDrawingTitle: String?

    /// When non-nil, `start()` hydrates this conversation instead of
    /// creating a new one. Set once at init and not mutated thereafter.
    private let existingConversationId: UUID?

    init(
        scope: EveScope? = nil,
        drawingId: UUID? = nil,
        critiqueSequence: Int? = nil,
        drawingTitle: String? = nil,
        captureCanvas: (() -> Data?)? = nil,
        existingConversationId: UUID? = nil,
    ) {
        // One of {scope, existingConversationId} must be provided. Debug
        // assertion alerts the programmer; release falls back to `.general`
        // so a misuse doesn't crash a TestFlight user.
        assert(
            scope != nil || existingConversationId != nil,
            "EveConversationManager requires either `scope` (create) or `existingConversationId` (resume)"
        )
        self.scope = scope ?? .general
        self.scopeDrawingId = drawingId
        self.scopeCritiqueSequence = critiqueSequence
        self.initialDrawingTitle = drawingTitle
        self.captureCanvas = captureCanvas
        self.existingConversationId = existingConversationId
    }

    /// Idempotent bootstrap. Call from .task on the sheet. Subsequent
    /// calls (e.g. if the view re-attaches) short-circuit when the
    /// conversation is already loaded.
    ///
    /// Branches on `existingConversationId`:
    /// - non-nil → hydrate the persisted conversation + its message
    ///   history via `EveService.getConversation(id:)`. The fetched
    ///   conversation's scope/drawing/critique overwrite whatever was
    ///   passed at init time (the persisted values are the truth).
    /// - nil → create a fresh conversation server-side via
    ///   `EveService.createConversation`, seeded with the init scope.
    func start() async {
        if loadState == .ready { return }
        loadState = .loading
        do {
            if let existingId = existingConversationId {
                let (convo, history) = try await EveService.shared.getConversation(id: existingId)
                self.conversation = convo
                self.messages = history
                // Hydrated conversation is authoritative — overwrite the
                // scope quartet so the context chip + scope-switched UI
                // render the resumed conversation's real scope, not
                // whatever placeholder the caller passed (often nothing
                // when resuming from the conversation list).
                self.scope = convo.scope
                self.scopeDrawingId = convo.scopeDrawingId
                self.scopeCritiqueSequence = convo.scopeCritiqueSequence
                // initialDrawingTitle is left as-passed. The worker's
                // list endpoint doesn't carry drawing titles, so resume
                // from the list arrives with nil here; the chip's nil
                // fallback handles it.
            } else {
                let convo = try await EveService.shared.createConversation(
                    scope: scope,
                    drawingId: scopeDrawingId,
                    critiqueSequence: scopeCritiqueSequence,
                )
                self.conversation = convo
                self.messages = []
            }
            self.loadState = .ready
        } catch let err as EveServiceError {
            self.loadState = .failed(message: err.errorDescription ?? defaultFailureCopy)
        } catch {
            self.loadState = .failed(message: defaultFailureCopy)
        }
    }

    /// Copy differs by branch: a hydrate failure is "couldn't load that
    /// conversation" (the row exists, we just can't reach it), while a
    /// create failure is "couldn't start a conversation" (the row never
    /// got persisted). Either error path falls through to this if the
    /// service didn't supply a localized description.
    private var defaultFailureCopy: String {
        existingConversationId == nil
            ? "Couldn't start a conversation with Eve."
            : "Couldn't load that conversation."
    }

    // =============================================================================
    // Send + retry
    // =============================================================================

    /// Send the current draft. No-op when draft is empty / sending is
    /// in flight / the conversation hasn't booted yet.
    func sendDraft() async {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard sendState != .sending else { return }
        guard let convo = conversation else { return }

        // Snapshot the canvas attachment (if any) into a local so the
        // request body sees the bytes that were present at send-tap time,
        // even if the user re-taps "Show Eve my canvas" mid-flight.
        let canvasSnapshot = pendingCanvasImage
        let canvasBase64 = canvasSnapshot?.base64EncodedString()

        // Optimistic UI: render the user's message immediately as a
        // pending row so the bubble appears the instant they tap send.
        // The pending row carries a synthetic UUID; the real row (with
        // its server-assigned id) replaces it on the response. When a
        // canvas was attached we mirror the worker's persisted format so
        // the in-flight bubble matches what the canonical row will look
        // like on next conversation hydrate.
        let pendingId = UUID()
        let pendingContent = canvasBase64 != nil
            ? "[canvas attached this turn]\n\n\(trimmed)"
            : trimmed
        let pending = EveMessage(
            id: pendingId,
            conversationId: convo.id,
            role: .user,
            content: pendingContent,
            createdAt: Date(),
            promptTokenCount: nil,
            completionTokenCount: nil,
            personaVersion: nil,
            productContextVersion: nil,
        )
        messages.append(pending)
        draft = ""
        sendState = .sending

        do {
            let response = try await EveService.shared.sendMessage(
                conversationId: convo.id,
                content: trimmed,
                canvasImageBase64: canvasBase64,
            )
            // Replace the pending row with the canonical user row (if
            // the server returned one — on idempotent replay it may be
            // null). Append the assistant row.
            if let idx = messages.firstIndex(where: { $0.id == pendingId }) {
                if let serverUser = response.userMessage {
                    messages[idx] = serverUser
                }
                // If the server didn't return a user row (replay path),
                // keep the pending row as-is — its content is correct
                // and the visual state is consistent.
            }
            messages.append(response.assistantMessage)
            self.conversation = response.conversation
            self.sendState = .idle
            // Successful send → drop the staged canvas. Each canvas
            // share is one-turn by design (per ship spec); the user
            // can re-tap "Show Eve my canvas" if they want to attach
            // the (now-updated) state again.
            self.pendingCanvasImage = nil
        } catch let err as EveServiceError {
            // Failed send: leave the user's bubble in place (with a
            // visual error indicator at the bubble level) so they
            // don't lose what they typed, and restore the draft to
            // the input bar so they can edit and retry. The canvas
            // attachment also stays in place — the user shouldn't lose
            // their shot just because OpenAI burped.
            messages.removeAll { $0.id == pendingId }
            draft = trimmed
            sendState = .failed(message: err.errorDescription ?? "Eve couldn't reply just now.")
        } catch {
            messages.removeAll { $0.id == pendingId }
            draft = trimmed
            sendState = .failed(message: "Eve couldn't reply just now.")
        }
    }

    /// Clear an error state (called from the input bar's "dismiss" tap
    /// on the inline error chip).
    func clearSendError() {
        if case .failed = sendState {
            sendState = .idle
        }
    }

    // =============================================================================
    // Canvas attachment
    // =============================================================================

    /// Invoke the canvas-capture closure and stage the result as the
    /// next-send attachment. No-op when the manager wasn't constructed
    /// with a `captureCanvas` closure (defensive — the pill is gated
    /// upstream by `canAttachCanvas` so it shouldn't render in that
    /// case). Returns false when the closure was missing or returned
    /// nil (export failed) so the UI can surface a transient error.
    @discardableResult
    func captureAndAttachCanvas() -> Bool {
        guard let captureCanvas else {
            assertionFailure("captureAndAttachCanvas called without a captureCanvas closure")
            return false
        }
        guard let data = captureCanvas(), !data.isEmpty else {
            return false
        }
        pendingCanvasImage = data
        return true
    }

    /// Drop the staged attachment without sending. Called from the chip's
    /// remove button.
    func clearAttachedCanvas() {
        pendingCanvasImage = nil
    }
}
