//
//  RecommendationsService.swift
//  DrawEvolve
//
//  Phase 4 — calls POST /v1/recommendations on the worker. Sibling of
//  OpenAIManager + EveService. Same auth posture (Supabase JWT +
//  App Attest when enforced), same URLSession, same error-mapping shape.
//

import Foundation
import Supabase

enum RecommendationsServiceError: LocalizedError {
    case notAuthenticated
    case unauthorized
    case forbidden
    case disabled
    case modelError(message: String)
    case rateLimited(message: String, retryAfter: Int)
    case transport(underlying: Error)
    case decoding(underlying: Error)
    case server(message: String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Sign in to get suggestions."
        case .unauthorized:
            return "Your session has expired. Sign out and sign in again."
        case .forbidden:
            return "You don't have access to suggestions right now."
        case .disabled:
            return "Suggestions are temporarily unavailable. Try again later."
        case .modelError(let message), .server(let message):
            return message
        case .rateLimited(let message, _):
            return message
        case .transport:
            return "Couldn't reach the suggestions service. Check your connection and try again."
        case .decoding:
            return "We got an unexpected response. Please try again."
        }
    }
}

actor RecommendationsService {
    static let shared = RecommendationsService()

    private let backendURL = "https://drawevolve-backend.trevorriggle.workers.dev"

    /// Session-lived cache of the most recent successful recommendations
    /// response. Added in the Phase 4 cost pass: the Evolution panel's
    /// "Recommended next" section auto-loads on .task, which means every
    /// navigation to the My Evolution tab was firing a fresh OpenAI call
    /// (~$0.003 each). Caching for the app session means each user pays
    /// for one set per launch — they can quit + relaunch (or, later, tap
    /// a manual refresh affordance) to roll for a different mix.
    ///
    /// Cleared only on process death. No TTL, no auto-invalidation on
    /// new critique writes — the recommendations are best-effort coaching,
    /// not a real-time feed.
    private var cachedResponse: RecommendationsResponse?

    private init() {}

    /// Fetch 5 personalized subject recommendations. Returns the
    /// session-cached response when present so a user opening Evolution
    /// three times in a row pays for one OpenAI call, not three.
    /// Pass `forceRefresh: true` to bypass the cache (reserved for a
    /// future "roll for new suggestions" affordance — no caller uses
    /// it today).
    func fetchRecommendations(forceRefresh: Bool = false) async throws -> RecommendationsResponse {
        if !forceRefresh, let cached = cachedResponse {
            return cached
        }
        guard let client = SupabaseManager.shared.client else {
            throw RecommendationsServiceError.notAuthenticated
        }
        let accessToken: String
        do {
            let session = try await client.auth.session
            accessToken = session.accessToken
        } catch {
            throw RecommendationsServiceError.notAuthenticated
        }

        guard let url = URL(string: backendURL + "/v1/recommendations") else {
            throw RecommendationsServiceError.server(message: "Invalid URL")
        }

        // POST with empty body — recommendations is a server-driven
        // endpoint, the user has no body to submit. App Attest signs
        // over zero bytes, matching the GET-shape Eve list endpoints.
        let bodyBytes = Data()

        let attestHeaders: [String: String]
        do {
            attestHeaders = try await AppAttestManager.shared.attestedHeaders(
                method: "POST",
                path: url.path.isEmpty ? "/" : url.path,
                body: bodyBytes,
            )
        } catch {
            throw RecommendationsServiceError.server(
                message: "Couldn't verify this device. \(error.localizedDescription)"
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        for (name, value) in attestHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = bodyBytes

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RecommendationsServiceError.transport(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RecommendationsServiceError.server(message: "Unexpected response")
        }

        switch http.statusCode {
        case 200:
            do {
                let decoded = try JSONDecoder().decode(RecommendationsResponse.self, from: data)
                self.cachedResponse = decoded
                return decoded
            } catch {
                throw RecommendationsServiceError.decoding(underlying: error)
            }

        case 401:
            throw RecommendationsServiceError.unauthorized
        case 403:
            throw RecommendationsServiceError.forbidden
        case 429:
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = payload?["message"] as? String
                ?? "You've hit your usage limit. Try again later."
            let retryAfter = (payload?["retryAfter"] as? NSNumber)?.intValue ?? 60
            throw RecommendationsServiceError.rateLimited(message: message, retryAfter: retryAfter)
        case 503:
            throw RecommendationsServiceError.disabled
        case 502:
            throw RecommendationsServiceError.modelError(
                message: "Couldn't generate suggestions just now. Try again in a moment."
            )
        default:
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = payload?["error"] as? String ?? "Server error (\(http.statusCode))"
            throw RecommendationsServiceError.server(message: message)
        }
    }
}
