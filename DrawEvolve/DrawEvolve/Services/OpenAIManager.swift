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
            return "OpenAI API key is missing. Please add it to your Config.plist."
        case .invalidResponse:
            return "Received an invalid response from OpenAI."
        case .serverError(let message):
            return "Server error: \(message)"
        case .imageEncodingFailed:
            return "Failed to encode the image for upload."
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

    /// Requests feedback via our secure backend proxy.
    ///
    /// `drawingId` must reference a row in the `drawings` table owned by the
    /// signed-in user — the Worker enforces this and rejects mismatches with
    /// 403. Callers should ensure the drawing has been persisted to cloud
    /// (see `CloudDrawingStorageManager.awaitCloudSync(for:)`) before calling
    /// this, otherwise the row won't exist yet and the request will fail.
    func requestFeedback(image: UIImage, context: DrawingContext, drawingId: UUID) async throws -> String {
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
        // (auth.uid()::text + storage paths are all lowercase).
        let requestBody: [String: Any] = [
            "image": base64Image,
            "drawingId": drawingId.uuidString.lowercased(),
            "context": [
                "skillLevel": context.skillLevel,
                "subject": context.subject,
                "style": context.style,
                "artists": context.artists,
                "techniques": context.techniques,
                "focus": context.focus,
                "additionalContext": context.additionalContext,
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
            let retryAfter = json?["retryAfter"] as? Int ?? 60
            let scope = json?["scope"] as? String ?? "unknown"
            let err = OpenAIError.rateLimited(message: message, retryAfter: retryAfter)
            CrashReporter.shared.logError(
                err,
                context: "OpenAIManager.requestFeedback - 429 from Worker (scope: \(scope), retryAfter: \(retryAfter)s)"
            )
            throw err
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMessage = errorJson["error"] as? String {
                let error = OpenAIError.serverError(errorMessage)
                CrashReporter.shared.logError(error, context: "OpenAIManager.requestFeedback - Server error: \(errorMessage)")
                throw error
            }
            let error = OpenAIError.serverError("HTTP \(httpResponse.statusCode)")
            CrashReporter.shared.logError(error, context: "OpenAIManager.requestFeedback - HTTP \(httpResponse.statusCode)")
            throw error
        }

        // Parse backend response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feedback = json["feedback"] as? String else {
            let error = OpenAIError.invalidResponse
            CrashReporter.shared.logError(error, context: "OpenAIManager.requestFeedback - Invalid response format")
            throw error
        }

        return feedback
    }
}
