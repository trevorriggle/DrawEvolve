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
    /// double-write to Postgres.
    func requestFeedback(image: UIImage, context: DrawingContext, drawingId: UUID) async throws -> FeedbackResponse {
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
        // (auth.uid()::text + storage paths are all lowercase). Phase 5d adds
        // client_request_id for idempotency — same lowercase convention.
        let clientRequestId = UUID().uuidString.lowercased()

        // Read the user's selected preset voice. Lives in UserDefaults under
        // the key the My Prompts view writes to via @AppStorage. Default
        // "studio_mentor" matches the worker's DEFAULT_PRESET_ID and the
        // AppStorage default in the view — three sources, one value.
        let selectedPresetID = UserDefaults.standard.string(forKey: "selectedPresetID") ?? "studio_mentor"

        let requestBody: [String: Any] = [
            "image": base64Image,
            "drawingId": drawingId.uuidString.lowercased(),
            "client_request_id": clientRequestId,
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

        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody),
              let url = URL(string: backendURL) else {
            throw OpenAIError.invalidResponse
        }

        // Call our backend
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
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
