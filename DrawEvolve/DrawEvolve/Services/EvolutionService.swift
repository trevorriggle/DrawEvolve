//
//  EvolutionService.swift
//  DrawEvolve
//
//  Fetches the My Evolution dashboard payload from the Cloudflare Worker.
//
//  Auth pattern mirrors OpenAIManager.requestFeedback:
//    - Supabase JWT in Authorization (proves who).
//    - App Attest assertion headers via AppAttestManager (proves where).
//  The Worker rejects 401 if either is missing/invalid.
//
//  Date decoding handles both fractional-second and plain ISO8601 forms,
//  matching the dual-formatter approach in OpenAIManager.swift so any future
//  serializer drift on the Worker side stays decode-safe.
//

import Foundation
import Supabase

enum EvolutionError: Error, Equatable {
    case notAuthenticated
    /// App Attest assertion couldn't be produced. On the simulator,
    /// `DCAppAttestService.isSupported` is `false` and this fires before
    /// any network attempt; on real devices it indicates a Keychain or
    /// Apple-server issue with the attested key. Distinct from `.network`
    /// because the server was never contacted, and distinct from
    /// `.server(Int)` because no real HTTP status exists for it.
    case deviceVerificationFailed
    case network
    case decoding
    case server(Int)
    case unknown

    /// User-facing copy. Honest, direct, no padding — the Evolution feature's
    /// design discipline applies here too. The simulator-specific override
    /// for `.deviceVerificationFailed` lives in EvolutionView.errorView so
    /// the enum stays platform-agnostic.
    var userFacingMessage: String {
        switch self {
        case .notAuthenticated:
            return "Sign in again to view your evolution."
        case .deviceVerificationFailed:
            return "Couldn't verify this device."
        case .network:
            return "Couldn't reach the server."
        case .decoding:
            return "Something looks off with your data."
        case .server(let code):
            return "The server returned an error (\(code))."
        case .unknown:
            return "Something went wrong."
        }
    }
}

actor EvolutionService {
    static let shared = EvolutionService()

    /// Same backend the rest of the app talks to. Kept as a private constant
    /// to mirror OpenAIManager's pattern; if this ever needs to vary by env,
    /// both should move to a shared config at the same time.
    private let backendURL = URL(string: "https://drawevolve-backend.trevorriggle.workers.dev")!
    private let path = "/v1/me/evolution"

    private init() {}

    /// Fetches and decodes the evolution payload for the current user.
    /// Throws specific EvolutionError cases the view-model maps to UI states.
    func fetchEvolution() async throws -> EvolutionFeed {
        // 1. Supabase access token — without one the Worker returns 401.
        guard let client = SupabaseManager.shared.client else {
            throw EvolutionError.notAuthenticated
        }
        let accessToken: String
        do {
            let session = try await client.auth.session
            accessToken = session.accessToken
        } catch {
            throw EvolutionError.notAuthenticated
        }

        // 2. App Attest headers. Empty body for GET — the Worker computes
        //    sha256 over zero bytes; we pass Data() explicitly so the
        //    client/server hashes agree.
        let url = backendURL.appendingPathComponent(path.trimmingCharacters(in: ["/"]))
        let attestHeaders: [String: String]
        do {
            attestHeaders = try await AppAttestManager.shared.attestedHeaders(
                method: "GET",
                path: path,
                body: Data()
            )
        } catch {
            // Pre-network failure: AppAttest couldn't produce headers (e.g.
            // simulator without DCAppAttestService support, Keychain wedged,
            // Apple invalidated the key). The server was never contacted —
            // surfacing this as `.server(0)` was misleading on every count.
            throw EvolutionError.deviceVerificationFailed
        }

        // 3. Build + send request.
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in attestHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw EvolutionError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw EvolutionError.unknown
        }

        switch http.statusCode {
        case 200:
            break
        case 401:
            throw EvolutionError.notAuthenticated
        default:
            throw EvolutionError.server(http.statusCode)
        }

        // 4. Decode. Same dual-formatter strategy used elsewhere in the app
        //    (OpenAIManager.swift, CritiqueHistory) so fractional-second and
        //    plain ISO8601 both parse without forcing the Worker to commit
        //    to one form.
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let str = try container.decode(String.self)
            if let d = isoFractional.date(from: str) { return d }
            if let d = isoPlain.date(from: str) { return d }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unparseable evolution date: \(str)"
            )
        }

        do {
            return try decoder.decode(EvolutionFeed.self, from: data)
        } catch {
            throw EvolutionError.decoding
        }
    }
}
