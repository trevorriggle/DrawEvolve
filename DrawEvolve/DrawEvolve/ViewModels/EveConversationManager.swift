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

    /// Construct with an explicit scope. The manager will either
    /// create a fresh conversation (most common) or hydrate an existing
    /// one when an `existingConversationId` is supplied (used by 2B's
    /// list view; in 2A every entry creates a new conversation per spec).
    let scope: EveScope
    let scopeDrawingId: UUID?
    let scopeCritiqueSequence: Int?
    let initialDrawingTitle: String?

    init(
        scope: EveScope,
        drawingId: UUID? = nil,
        critiqueSequence: Int? = nil,
        drawingTitle: String? = nil,
        captureCanvas: (() -> Data?)? = nil,
    ) {
        self.scope = scope
        self.scopeDrawingId = drawingId
        self.scopeCritiqueSequence = critiqueSequence
        self.initialDrawingTitle = drawingTitle
        self.captureCanvas = captureCanvas
    }

    /// Idempotent bootstrap. Call from .task on the sheet. Subsequent
    /// calls (e.g. if the view re-attaches) short-circuit when the
    /// conversation is already loaded.
    func start() async {
        if loadState == .ready { return }
        loadState = .loading
        do {
            let convo = try await EveService.shared.createConversation(
                scope: scope,
                drawingId: scopeDrawingId,
                critiqueSequence: scopeCritiqueSequence,
            )
            self.conversation = convo
            self.messages = []
            self.loadState = .ready
        } catch let err as EveServiceError {
            self.loadState = .failed(message: err.errorDescription
                ?? "Couldn't start a conversation with Eve.")
        } catch {
            self.loadState = .failed(message: "Couldn't start a conversation with Eve.")
        }
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
