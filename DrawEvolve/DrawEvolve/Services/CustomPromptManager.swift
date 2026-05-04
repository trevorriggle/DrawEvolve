//
//  CustomPromptManager.swift
//  DrawEvolve
//
//  CRUD client for /v1/prompts/* on the Cloudflare Worker. Mirrors
//  OpenAIManager's auth posture: every request carries the Supabase JWT
//  in `Authorization` and an App Attest assertion in the
//  `X-Apple-AppAttest-*` headers. Without both the Worker rejects with
//  401 and a stable error code.
//
//  Bounded knobs only — the Worker rejects any field outside the
//  documented enum surface. CustomPromptManager doesn't try to validate
//  enum values client-side beyond what the model types already guarantee
//  via Codable.
//

import Foundation
import Supabase

@MainActor
final class CustomPromptManager: ObservableObject {
    static let shared = CustomPromptManager()

    /// Source of truth for the My Prompts list view. Updated after every
    /// successful list / create / update / delete so the UI doesn't need
    /// to refetch on every interaction.
    @Published private(set) var prompts: [CustomPrompt] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    /// Backend base URL — same Worker as OpenAIManager + AppAttestManager.
    /// Keeping the constant local rather than reading from a shared config
    /// matches the existing pattern; future cleanup can extract a single
    /// Config-derived value once any of the three managers needs to vary
    /// it (e.g. local dev).
    private let backendURL = URL(string: "https://drawevolve-backend.trevorriggle.workers.dev")!

    private init() {}

    // MARK: - Public API

    func refresh() async {
        await loadList()
    }

    func loadList() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let url = backendURL.appendingPathComponent("v1/prompts/me")
            let (data, _) = try await sendRequest(url: url, method: "GET", body: nil)
            let decoded = try Self.decoder().decode(ListResponse.self, from: data)
            self.prompts = decoded.prompts
            self.lastError = nil
        } catch {
            self.lastError = "Couldn't load your prompts. \(error.localizedDescription)"
            CrashReporter.shared.logError(error, context: "CustomPromptManager.loadList")
        }
    }

    /// Create a new bounded-knobs prompt. Returns the server-assigned row
    /// (with id, timestamps, template_version), and prepends it to the
    /// in-memory list.
    @discardableResult
    func create(name: String, parameters: PromptParameters) async throws -> CustomPrompt {
        let url = backendURL.appendingPathComponent("v1/prompts")
        let payload: [String: Any] = [
            "name": name,
            "parameters": parametersJSON(parameters),
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await sendRequest(url: url, method: "POST", body: bodyData)
        let decoded = try Self.decoder().decode(SingleResponse.self, from: data)
        prompts.insert(decoded.prompt, at: 0)
        return decoded.prompt
    }

    /// Patch name and/or parameters. Server replaces the in-memory row on
    /// the response so post-write state is authoritative.
    @discardableResult
    func update(id: UUID, name: String?, parameters: PromptParameters?) async throws -> CustomPrompt {
        let url = backendURL.appendingPathComponent("v1/prompts/\(id.uuidString.lowercased())")
        var payload: [String: Any] = [:]
        if let name { payload["name"] = name }
        if let parameters { payload["parameters"] = parametersJSON(parameters) }
        guard !payload.isEmpty else {
            throw CustomPromptError.noFieldsToUpdate
        }
        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await sendRequest(url: url, method: "PATCH", body: bodyData)
        let decoded = try Self.decoder().decode(SingleResponse.self, from: data)
        if let idx = prompts.firstIndex(where: { $0.id == decoded.prompt.id }) {
            prompts[idx] = decoded.prompt
        } else {
            prompts.insert(decoded.prompt, at: 0)
        }
        return decoded.prompt
    }

    /// Soft delete. Server stamps deleted_at; the row is removed from the
    /// in-memory list but past critiques referencing this prompt's id
    /// continue to render normally on the server side.
    func delete(id: UUID) async throws {
        let url = backendURL.appendingPathComponent("v1/prompts/\(id.uuidString.lowercased())")
        _ = try await sendRequest(url: url, method: "DELETE", body: nil)
        prompts.removeAll { $0.id == id }
    }

    // MARK: - Encoding helpers

    /// PromptParameters → [String: Any] for JSONSerialization. Drops nil
    /// fields so the wire payload only carries set knobs (the Worker
    /// treats a missing key as "knob not set").
    private func parametersJSON(_ p: PromptParameters) -> [String: Any] {
        var out: [String: Any] = [:]
        if let focus = p.focus { out["focus"] = focus.rawValue }
        if let tone = p.tone { out["tone"] = tone.rawValue }
        if let depth = p.depth { out["depth"] = depth.rawValue }
        if let techniques = p.techniques, !techniques.isEmpty {
            out["techniques"] = techniques.map { $0.rawValue }
        }
        return out
    }

    // MARK: - Network plumbing (JWT + App Attest, mirrors OpenAIManager)

    private func sendRequest(url: URL, method: String, body: Data?) async throws -> (Data, HTTPURLResponse) {
        guard let client = SupabaseManager.shared.client else {
            throw CustomPromptError.notAuthenticated
        }
        let accessToken: String
        do {
            let session = try await client.auth.session
            accessToken = session.accessToken
        } catch {
            throw CustomPromptError.notAuthenticated
        }

        let bodyData = body ?? Data()
        let path = url.path.isEmpty ? "/" : url.path
        let attestHeaders = try await AppAttestManager.shared.attestedHeaders(
            method: method, path: path, body: bodyData,
        )

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        for (name, value) in attestHeaders { request.setValue(value, forHTTPHeaderField: name) }
        if let body { request.httpBody = body }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CustomPromptError.invalidResponse
        }

        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 401:
            throw CustomPromptError.unauthorized
        case 403:
            throw CustomPromptError.forbidden
        case 404:
            throw CustomPromptError.notFound
        default:
            // Surface the Worker's error code in the diagnostic, but never
            // leak it to the user. Match OpenAIManager's posture.
            let errJson = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = errJson?["error"] as? String ?? "unknown"
            throw CustomPromptError.serverError(code: code, status: http.statusCode)
        }
    }

    private static func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        // Worker emits ISO-8601 with fractional seconds (Date.toISOString()).
        // Same pattern as OpenAIManager.requestFeedback's critique_entry decoding.
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        dec.dateDecodingStrategy = .custom { d in
            let container = try d.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = isoFractional.date(from: str) { return date }
            if let date = isoPlain.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date: \(str)")
        }
        return dec
    }

    // MARK: - Wire types

    private struct ListResponse: Codable { let prompts: [CustomPrompt] }
    private struct SingleResponse: Codable { let prompt: CustomPrompt }
}

// MARK: - Errors

enum CustomPromptError: LocalizedError {
    case notAuthenticated
    case unauthorized
    case forbidden
    case notFound
    case invalidResponse
    case noFieldsToUpdate
    case serverError(code: String, status: Int)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Sign in to manage your prompts."
        case .unauthorized:     return "Your session has expired. Sign out and sign in again."
        case .forbidden:        return "We couldn't verify this prompt belongs to you."
        case .notFound:         return "We couldn't find that prompt."
        case .invalidResponse:  return "We got an unexpected response from the server."
        case .noFieldsToUpdate: return "Nothing to save."
        case .serverError(_, let status) where status >= 500:
            return "We're having trouble reaching our servers right now. Please try again."
        case .serverError:
            return "Something went wrong with this request."
        }
    }
}
