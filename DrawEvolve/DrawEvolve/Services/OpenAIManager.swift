//
//  OpenAIManager.swift
//  DrawEvolve
//
//  Handles all OpenAI API interactions for image analysis and feedback generation.
//
//  Phase 5a/5b: every request now carries the user's Supabase JWT in
//  `Authorization` and a `drawingId` in the body. The Worker rejects anything
//  unauthenticated (401) or where the drawing doesn't belong to the JWT's
//  user (403). Callers must hold a real Supabase session — DEBUG bypass users
//  cannot reach the Worker.
//

import Foundation
import Supabase
import UIKit

enum OpenAIError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case serverError(String)
    case imageEncodingFailed
    case notAuthenticated
    case unauthorized
    case forbidden
    case rateLimited(message: String, retryAfter: Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Feedback isn't available right now. Please try again later."
        case .invalidResponse:
            return "We got an unexpected response from the server. Please try again."
        case .serverError(let message):
            // Callers MUST pass a human-friendly message — this is rendered as-is
            // in the alert. Never pass Worker error codes (e.g. "rate_limited")
            // here; codes belong in CrashReporter context, not user copy.
            return message
        case .imageEncodingFailed:
            return "We couldn't prepare your drawing for upload. Try saving it again."
        case .notAuthenticated:
            return "Sign in to request feedback."
        case .unauthorized:
            return "Your session has expired. Sign out and sign in again."
        case .forbidden:
            return "We couldn't verify this drawing belongs to you. Try saving it again."
        case .rateLimited(let message, _):
            // Server message is already tier-aware and human-readable — surface verbatim.
            return message
        }
    }
}

/// Carried in `requestFeedback` to tell the Worker how to find and
/// promote the pending snapshot bundle that the caller uploaded in
/// parallel. "All three together or nothing" — if iOS can't compute any
/// of these, pass nil and the Worker will skip the promote step
/// (entry persists with snapshot: null).
struct SnapshotUploadMetadata {
    let layerCount: Int
    let totalBytes: Int64
    let formatVersion: Int
}

/// Per-request declaration of where the student is in the drawing
/// process. Sent on the critique sheet's segmented toggle. The Worker
/// branches Eve's STAGE_OF_WORK_BLOCK on this value — `in_progress`
/// prioritizes next-step coaching, `finished` prioritizes polish notes.
/// Transient and per-request; never persisted on the drawing model.
enum StageOfWork: String, Codable {
    case inProgress = "in_progress"
    case finished
}

actor OpenAIManager {
    static let shared = OpenAIManager()

    // Cloudflare Worker backend URL
    private let backendURL = "https://drawevolve-backend.trevorriggle.workers.dev"

    // For local testing with Vercel Dev, use:
    // private let backendURL = "http://localhost:3000/api/feedback"

    private init() {
        print("✅ OpenAIManager using secure backend proxy at: \(backendURL)")
    }

    /// Result of a successful feedback request. Phase 5d: the Worker now
    /// persists the critique to `drawings.critique_history` server-side and
    /// returns the canonical entry alongside the feedback text. Callers use
    /// `critiqueEntry` to update local UI state — the cloud row is the
    /// source of truth on next gallery refresh.
    struct FeedbackResponse {
        let feedback: String
        let critiqueEntry: CritiqueEntry?
    }

    /// Requests feedback via our secure backend proxy.
    ///
    /// `drawingId` must reference a row in the `drawings` table owned by the
    /// signed-in user — the Worker enforces this and rejects mismatches with
    /// 403. Callers should ensure the drawing has been persisted to cloud
    /// (see `CloudDrawingStorageManager.awaitCloudSync(for:)`) before calling
    /// this, otherwise the row won't exist yet and the request will fail.
    ///
    /// Phase 5d: every request includes a fresh lowercase UUID
    /// `client_request_id`. The Worker caches the response under that key
    /// for 1h so retries on flaky networks don't double-charge OpenAI or
    /// double-write to Postgres. The caller generates the UUID and passes
    /// it in so the same ID can also serve as the pending-snapshot folder
    /// key for the parallel upload (drawing version history).
    ///
    /// `snapshotMetadata` (drawing version history): when non-nil, the
    /// Worker promotes the pending snapshot bundle the caller uploaded
    /// in parallel and attaches a pointer to the resulting CritiqueEntry.
    /// When nil, the Worker skips the promote step entirely — the entry
    /// persists with snapshot: null. Old iOS builds that don't know
    /// about snapshots simply pass nil here.
    ///
    /// `compositionFindings` (Eye Test M4): when non-nil, the worker
    /// adds a COMPOSITION ANALYSIS section to the system prompt and
    /// persists the structured payload on the critique row. Callers
    /// should pass nil whenever the `eye_test_eve_integration`
    /// feature flag is off — the gate lives on the caller side so
    /// the OpenAIManager remains feature-agnostic.
    func requestFeedback(
        image: UIImage,
        context: DrawingContext,
        drawingId: UUID,
        clientRequestId: String,
        stageOfWork: StageOfWork,
        snapshotMetadata: SnapshotUploadMetadata? = nil,
        compositionFindings: CompositionFindingsPayload? = nil
    ) async throws -> FeedbackResponse {
        // Convert image to base64
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            let error = OpenAIError.imageEncodingFailed
            CrashReporter.shared.logError(error, context: "OpenAIManager.requestFeedback - Image encoding failed")
            throw error
        }
        let base64Image = imageData.base64EncodedString()

        // Phase 5a — fetch the current Supabase access token. Without one the
        // Worker will return 401 with no body, so we surface a clearer error
        // here rather than letting the caller see a generic server failure.
        guard let client = SupabaseManager.shared.client else {
            CrashReporter.shared.logError(
                OpenAIError.notAuthenticated,
                context: "OpenAIManager.requestFeedback - Supabase client not configured"
            )
            throw OpenAIError.notAuthenticated
        }
        let accessToken: String
        do {
            let session = try await client.auth.session
            accessToken = session.accessToken
        } catch {
            CrashReporter.shared.logError(
                OpenAIError.notAuthenticated,
                context: "OpenAIManager.requestFeedback - No active session: \(error.localizedDescription)"
            )
            throw OpenAIError.notAuthenticated
        }

        // Send to OUR backend (not OpenAI directly).
        // drawingId is sent lowercase to match the Phase 3 cloud convention
        // (auth.uid()::text + storage paths are all lowercase). Phase 5d:
        // client_request_id is now supplied by the caller (lowercase UUID)
        // so it can double as the pending-snapshot folder key for the
        // parallel upload (drawing version history).

        // Read the user's selected preset voice. Lives in UserDefaults under
        // the key the My Prompts view writes to via @AppStorage. Default
        // "studio_mentor" matches the worker's DEFAULT_PRESET_ID and the
        // AppStorage default in the view — three sources, one value.
        let selectedPresetID = UserDefaults.standard.string(forKey: "selectedPresetID") ?? "studio_mentor"

        var requestBody: [String: Any] = [
            "image": base64Image,
            "drawingId": drawingId.uuidString.lowercased(),
            "client_request_id": clientRequestId,
            // snake_case to match the worker's body validator at
            // routes/feedback.js — the worker reads body.stage_of_work and
            // 400s on unrecognized values. Always sent (never omitted) so
            // newer iOS builds give the worker a predictable contract;
            // older iOS builds that omit the field fall through to the
            // worker's inferred-stage STAGE_OF_WORK_BLOCK for back-compat.
            "stage_of_work": stageOfWork.rawValue,
            "context": [
                "skillLevel": context.skillLevel,
                "subject": context.subject,
                "style": context.style,
                "artists": context.artists,
                "techniques": context.techniques,
                "focus": context.focus,
                "additionalContext": context.additionalContext,
                // snake_case to match the worker's CONTEXT_STRING_FIELDS
                // contract — sending "presetId" would silently fail validation
                // and the worker would default to studio_mentor without
                // surfacing an error.
                "preset_id": selectedPresetID,
            ],
        ]

        // Eye Test M4 — when the caller passes a CompositionFindingsPayload
        // (controlled by the eye_test_eve_integration feature flag), encode
        // it to a plain dict so it round-trips through JSONSerialization
        // alongside the existing top-level fields. Field name matches the
        // worker's body validator (`compositionFindings`, camelCase) at
        // routes/feedback.js:700-ish.
        if let compositionFindings = compositionFindings {
            do {
                let encoder = JSONEncoder()
                let data = try encoder.encode(compositionFindings)
                if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    requestBody["compositionFindings"] = dict
                }
            } catch {
                #if DEBUG
                print("[OpenAIManager] compositionFindings encode failed: \(error.localizedDescription) — sending request without it")
                #endif
                // Silent fall-through: the critique should still succeed
                // without composition findings; we don't want a local
                // serialization bug to block the critique.
            }
        }

        // Drawing version history. All three fields together or none.
        // When absent, the Worker skips the promote step (entry persists
        // with snapshot: null) — same shape as a pre-VH iOS build.
        if let snapshotMetadata = snapshotMetadata {
            requestBody["layer_count"]    = snapshotMetadata.layerCount
            requestBody["total_bytes"]    = snapshotMetadata.totalBytes
            requestBody["format_version"] = snapshotMetadata.formatVersion
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody),
              let url = URL(string: backendURL) else {
            throw OpenAIError.invalidResponse
        }

        // App Attest device verification (additive — sits next to JWT, doesn't
        // replace it). Headers are bound to (METHOD, PATH, sha256(jsonData)),
        // so re-serializing or appending bytes after this call would break
        // server-side verification. Don't mutate jsonData past this point.
        let attestHeaders: [String: String]
        do {
            attestHeaders = try await AppAttestManager.shared.attestedHeaders(
                method: "POST",
                path: url.path.isEmpty ? "/" : url.path,
                body: jsonData
            )
        } catch {
            CrashReporter.shared.logError(
                error,
                context: "OpenAIManager.requestFeedback - App Attest header generation failed"
            )
            throw OpenAIError.serverError("Couldn't verify this device. \(error.localizedDescription)")
        }

        // Call our backend
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        for (name, value) in attestHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            CrashReporter.shared.logError(
                OpenAIError.unauthorized,
                context: "OpenAIManager.requestFeedback - 401 from Worker (JWT invalid/expired)"
            )
            throw OpenAIError.unauthorized
        case 403:
            CrashReporter.shared.logError(
                OpenAIError.forbidden,
                context: "OpenAIManager.requestFeedback - 403 from Worker (drawing ownership mismatch)"
            )
            throw OpenAIError.forbidden
        case 429:
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = json?["message"] as? String
                ?? "You've hit your usage limit. Please try again later."
            // JSON numbers can bridge as Int or Double depending on serializer
            // — accept either so retryAfter isn't silently lost.
            let retryAfter = (json?["retryAfter"] as? NSNumber)?.intValue ?? 60
            let scope = json?["scope"] as? String ?? "unknown"
            let errorCode = json?["error"] as? String ?? "unknown"
            let err = OpenAIError.rateLimited(message: message, retryAfter: retryAfter)
            CrashReporter.shared.logError(
                err,
                context: "OpenAIManager.requestFeedback - 429 from Worker (error: \(errorCode), scope: \(scope), retryAfter: \(retryAfter)s)"
            )
            throw err
        default:
            // Capture the Worker's `error` code for diagnostics ONLY — never
            // surface it to the user (codes like "rate_limited" leak as ugly
            // copy). User-facing message is keyed off the status code.
            let errorJson = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let errorCode = errorJson?["error"] as? String ?? "none"
            let userMessage: String
            switch httpResponse.statusCode {
            case 500...599:
                userMessage = "We're having trouble reaching our servers right now. Please try again in a moment."
            case 400...499:
                userMessage = "Something went wrong with this request. Please try again."
            default:
                userMessage = "Something went wrong. Please try again."
            }
            let error = OpenAIError.serverError(userMessage)
            CrashReporter.shared.logError(
                error,
                context: "OpenAIManager.requestFeedback - HTTP \(httpResponse.statusCode) (worker error code: \(errorCode))"
            )
            throw error
        }

        // Parse backend response.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feedback = json["feedback"] as? String else {
            let error = OpenAIError.invalidResponse
            CrashReporter.shared.logError(error, context: "OpenAIManager.requestFeedback - Invalid response format")
            throw error
        }

        // Phase 5d: decode the server-supplied critique_entry. Falls back to
        // nil if missing or malformed — caller will synthesize a local entry
        // for display in that case (graceful handling of older Worker
        // deployments that don't yet return this field).
        var critiqueEntry: CritiqueEntry?
        if let entryDict = json["critique_entry"] as? [String: Any],
           let entryData = try? JSONSerialization.data(withJSONObject: entryDict) {
            let decoder = JSONDecoder()
            // Worker emits created_at via Date.toISOString() — always
            // includes fractional seconds. Built-in .iso8601 strategy
            // doesn't accept fractional seconds, so parse explicitly.
            let isoFractional = ISO8601DateFormatter()
            isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoPlain = ISO8601DateFormatter()
            isoPlain.formatOptions = [.withInternetDateTime]
            decoder.dateDecodingStrategy = .custom { dec in
                let container = try dec.singleValueContainer()
                let str = try container.decode(String.self)
                if let date = isoFractional.date(from: str) { return date }
                if let date = isoPlain.date(from: str) { return date }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unparseable critique_entry date: \(str)"
                )
            }
            critiqueEntry = try? decoder.decode(CritiqueEntry.self, from: entryData)
        }

        return FeedbackResponse(feedback: feedback, critiqueEntry: critiqueEntry)
    }
}
