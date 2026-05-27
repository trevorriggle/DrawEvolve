//
//  EveService.swift
//  DrawEvolve
//
//  Service for talking to the Worker's /v1/eve/* endpoints. Sibling to
//  OpenAIManager — same auth posture (Supabase JWT + App Attest when
//  enforced), same URLSession, same error-mapping shape.
//
//  Feature 2, Phase 2A — no streaming yet. Each send-message call
//  returns the full assistant response in one round-trip. Streaming
//  ships in 2B and will likely live in a parallel method on this same
//  service rather than replacing the existing one (different consumption
//  contract: AsyncStream vs a single awaited response).
//

import Foundation
import Supabase

enum EveServiceError: LocalizedError {
    case notAuthenticated
    case unauthorized
    case forbidden
    case notFound
    case conversationFull(message: String)
    case rateLimited(message: String, retryAfter: Int)
    case proRequired
    case server(message: String)
    case decoding(underlying: Error)
    case transport(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Sign in to talk to Eve."
        case .unauthorized:
            return "Your session has expired. Sign out and sign in again."
        case .forbidden:
            return "This conversation isn't available."
        case .notFound:
            return "Conversation not found."
        case .conversationFull(let message):
            return message
        case .rateLimited(let message, _):
            return message
        case .proRequired:
            return "This feature requires DrawEvolve Pro."
        case .server(let message):
            return message
        case .decoding:
            return "We got an unexpected response from Eve. Please try again."
        case .transport:
            return "Couldn't reach Eve. Check your connection and try again."
        }
    }
}

actor EveService {
    static let shared = EveService()

    // Same Cloudflare Worker host as OpenAIManager. Keeping the constant
    // duplicated rather than extracting a shared base intentionally — the
    // two services have different idempotency / retry / streaming needs
    // long-term, and a single shared constant would tempt a "let me just
    // share the request builder too" refactor that we'd want to undo
    // when streaming lands.
    private let backendURL = "https://drawevolve-backend.trevorriggle.workers.dev"

    private init() {}

    // =============================================================================
    // Public API
    // =============================================================================

    /// Create a new conversation. Pass `scope = .drawing` with a drawing
    /// id + critique sequence when opening Eve from a critique panel;
    /// pass `scope = .general` when opening from the dedicated EVE icon.
    /// `clientRequestId` is the create idempotency key — a double-tap on
    /// "Ask Eve" should produce a single row.
    func createConversation(
        scope: EveScope,
        drawingId: UUID? = nil,
        critiqueSequence: Int? = nil,
        title: String? = nil,
        clientRequestId: UUID = UUID()
    ) async throws -> EveConversation {
        var body: [String: Any] = [
            "scope": scope.rawValue,
            "client_request_id": clientRequestId.uuidString.lowercased(),
        ]
        if scope == .drawing {
            guard let drawingId else {
                // Surfaced as a validation error so the caller sees a clear
                // assertion-style message rather than a Worker 400.
                throw EveServiceError.server(message: "scope=drawing requires a drawingId")
            }
            body["scope_drawing_id"] = drawingId.uuidString.lowercased()
            if let critiqueSequence {
                body["scope_critique_sequence"] = critiqueSequence
            }
        }
        if let title {
            body["title"] = title
        }

        let response: EveConversationResponse = try await send(
            method: "POST",
            path: "/v1/eve/conversations",
            body: body,
        )
        // The worker stamps evictedConversationId when the user was at
        // the active-conversation cap and the oldest got soft-deleted to
        // make room. Currently log-only — silent eviction is intentional
        // per product decision; no UI banner. Logged here so the rate is
        // visible via Console / CrashReporter telemetry; if it spikes
        // we'll know users are routinely hitting the cap.
        if let evictedId = response.evictedConversationId {
            print("[Eve] cap eviction during create — archived \(evictedId.uuidString)")
        }
        return response.conversation
    }

    /// Fetch the user's active conversations, newest activity first.
    /// Soft-deleted rows are filtered server-side.
    func listConversations(limit: Int = 50) async throws -> [EveConversation] {
        let response: EveConversationListResponse = try await send(
            method: "GET",
            path: "/v1/eve/conversations?limit=\(limit)",
            body: nil,
        )
        return response.conversations
    }

    /// Fetch a conversation + its full message history.
    func getConversation(id: UUID) async throws -> (EveConversation, [EveMessage]) {
        let response: EveConversationDetailResponse = try await send(
            method: "GET",
            path: "/v1/eve/conversations/\(id.uuidString.lowercased())",
            body: nil,
        )
        return (response.conversation, response.messages)
    }

    /// Soft-delete a conversation. Idempotent server-side.
    func deleteConversation(id: UUID) async throws {
        let _: EmptyResponse = try await send(
            method: "DELETE",
            path: "/v1/eve/conversations/\(id.uuidString.lowercased())",
            body: nil,
        )
    }

    /// Send a user turn, get the full assistant response.
    ///
    /// `clientRequestId` is the per-conversation idempotency key — same
    /// UUID twice returns the same assistant row without re-charging
    /// OpenAI. The caller should generate a fresh UUID per logical send
    /// (not per retry).
    ///
    /// `canvasImageBase64`: optional JPEG bytes (base64-encoded) of the
    /// student's in-progress canvas, only ever sent from the
    /// canvas-launched Eve sheet. The worker treats it as an ephemeral
    /// per-turn attachment — never persisted as bytes, but the user-row
    /// content gets prefixed with a `[canvas attached this turn]` marker
    /// for audit + future-turn recall.
    func sendMessage(
        conversationId: UUID,
        content: String,
        clientRequestId: UUID = UUID(),
        canvasImageBase64: String? = nil
    ) async throws -> EveSendMessageResponse {
        var body: [String: Any] = [
            "content": content,
            "client_request_id": clientRequestId.uuidString.lowercased(),
        ]
        if let canvasImageBase64, !canvasImageBase64.isEmpty {
            body["canvas_image_base64"] = canvasImageBase64
        }
        return try await send(
            method: "POST",
            path: "/v1/eve/conversations/\(conversationId.uuidString.lowercased())/messages",
            body: body,
        )
    }

    // =============================================================================
    // Private — request plumbing
    // =============================================================================

    private struct EmptyResponse: Decodable {}

    private func send<T: Decodable>(
        method: String,
        path: String,
        body: [String: Any]?,
    ) async throws -> T {
        // JWT — same path as OpenAIManager.
        guard let client = SupabaseManager.shared.client else {
            throw EveServiceError.notAuthenticated
        }
        let accessToken: String
        do {
            let session = try await client.auth.session
            accessToken = session.accessToken
        } catch {
            throw EveServiceError.notAuthenticated
        }

        guard let url = URL(string: backendURL + path) else {
            throw EveServiceError.server(message: "Invalid URL")
        }

        // Body serialization happens BEFORE App Attest header generation
        // because the assertion is bound to the exact body bytes. The
        // empty-body case (GET / DELETE) signs over zero bytes — matches
        // the worker's `new Uint8Array(0)` contract.
        let bodyBytes: Data
        if let body {
            do {
                bodyBytes = try JSONSerialization.data(withJSONObject: body)
            } catch {
                throw EveServiceError.server(message: "Couldn't serialize request body")
            }
        } else {
            bodyBytes = Data()
        }

        let attestHeaders: [String: String]
        do {
            attestHeaders = try await AppAttestManager.shared.attestedHeaders(
                method: method,
                path: url.path.isEmpty ? "/" : url.path,
                body: bodyBytes,
            )
        } catch {
            throw EveServiceError.server(message: "Couldn't verify this device. \(error.localizedDescription)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        for (name, value) in attestHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if body != nil {
            request.httpBody = bodyBytes
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw EveServiceError.transport(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw EveServiceError.server(message: "Unexpected response")
        }

        switch http.statusCode {
        case 200, 201:
            // Empty 200 (DELETE) → empty struct succeeds the generic decode.
            if T.self == EmptyResponse.self {
                return EmptyResponse() as! T
            }
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
                return try decoder.decode(T.self, from: data)
            } catch {
                throw EveServiceError.decoding(underlying: error)
            }

        case 401:
            throw EveServiceError.unauthorized
        case 402:
            throw EveServiceError.proRequired
        case 403:
            throw EveServiceError.forbidden
        case 404:
            throw EveServiceError.notFound
        case 409:
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = payload?["message"] as? String
                ?? "This conversation is full. Start a new one to continue."
            throw EveServiceError.conversationFull(message: message)
        case 429:
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = payload?["message"] as? String
                ?? "You've hit your usage limit. Please try again later."
            let retryAfter = (payload?["retryAfter"] as? NSNumber)?.intValue ?? 60
            throw EveServiceError.rateLimited(message: message, retryAfter: retryAfter)
        default:
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = payload?["error"] as? String ?? "Server error (\(http.statusCode))"
            throw EveServiceError.server(message: message)
        }
    }
}

// =============================================================================
// JSONDecoder.dateDecodingStrategy: iso8601WithFractionalSeconds
// =============================================================================
//
// Same decoder shim OpenAIManager uses — Supabase / the Worker emit
// ISO8601 with fractional seconds (e.g. "2026-05-13T12:00:00.123Z").
// The built-in .iso8601 strategy rejects the milliseconds. Hoist a
// parallel formatter that accepts both shapes so EveService doesn't
// re-implement the same fallback chain.

private extension JSONDecoder.DateDecodingStrategy {
    static var iso8601WithFractionalSeconds: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)

            let withFrac = ISO8601DateFormatter()
            withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = withFrac.date(from: str) { return d }

            let without = ISO8601DateFormatter()
            without.formatOptions = [.withInternetDateTime]
            if let d = without.date(from: str) { return d }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Could not decode ISO8601 date: \(str)"
            )
        }
    }
}
