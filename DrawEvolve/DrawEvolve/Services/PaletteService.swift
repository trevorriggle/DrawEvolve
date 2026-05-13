//
//  PaletteService.swift
//  DrawEvolve
//
//  Phase 3 — Color System Overhaul. CRUD against /v1/palettes. Sibling
//  of EveService + RecommendationsService — same auth posture (JWT +
//  App Attest when enforced), same URLSession, same error mapping
//  shape. The service is a thin actor wrapper around URLSession; all
//  caching + sync state lives on PaletteManager.
//
//  AI palette generation in v1 runs on-device (PaletteGenerator). The
//  service does NOT call /v1/palettes/generate today — that endpoint
//  doesn't exist server-side, and the on-device path means the user
//  never waits on a worker round-trip for a generation. The hook is
//  reserved for a future Pro-tier "Smart palette" feature.
//

import Foundation
import Supabase
import UIKit

enum PaletteServiceError: LocalizedError {
    case notAuthenticated
    case unauthorized
    case forbidden
    case notFound
    case validation(message: String)
    case server(message: String)
    case decoding(underlying: Error)
    case transport(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Sign in to sync your palettes."
        case .unauthorized:
            return "Your session has expired. Sign out and sign in again."
        case .forbidden:
            return "You don't have access to this palette."
        case .notFound:
            return "Palette not found."
        case .validation(let message), .server(let message):
            return message
        case .decoding:
            return "We got an unexpected response. Please try again."
        case .transport:
            return "Couldn't reach the palette server. Check your connection and try again."
        }
    }
}

actor PaletteService {
    static let shared = PaletteService()

    private let backendURL = "https://drawevolve-backend.trevorriggle.workers.dev"

    private init() {}

    // MARK: - Public API

    func listPalettes() async throws -> [Palette] {
        let response: PaletteListResponse = try await send(
            method: "GET",
            path: "/v1/palettes",
            body: nil,
        )
        return response.palettes
    }

    func createPalette(name: String, colors: [UIColor]) async throws -> Palette {
        let body: [String: Any] = [
            "name": name,
            "colors": colors.map { Self.hexFor($0) },
        ]
        let response: PaletteResponse = try await send(
            method: "POST",
            path: "/v1/palettes",
            body: body,
        )
        return response.palette
    }

    func updatePalette(id: UUID, name: String?, colors: [UIColor]?) async throws -> Palette {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let colors { body["colors"] = colors.map { Self.hexFor($0) } }
        guard !body.isEmpty else {
            throw PaletteServiceError.validation(message: "Nothing to update.")
        }
        let response: PaletteResponse = try await send(
            method: "PATCH",
            path: "/v1/palettes/\(id.uuidString.lowercased())",
            body: body,
        )
        return response.palette
    }

    func deletePalette(id: UUID) async throws {
        let _: EmptyResponse = try await send(
            method: "DELETE",
            path: "/v1/palettes/\(id.uuidString.lowercased())",
            body: nil,
        )
    }

    // MARK: - Private

    private struct EmptyResponse: Decodable {}

    private static func hexFor(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let rr = Int((max(0, min(1, r)) * 255).rounded())
        let gg = Int((max(0, min(1, g)) * 255).rounded())
        let bb = Int((max(0, min(1, b)) * 255).rounded())
        return String(format: "#%02x%02x%02x", rr, gg, bb)
    }

    private func send<T: Decodable>(
        method: String,
        path: String,
        body: [String: Any]?,
    ) async throws -> T {
        guard let client = SupabaseManager.shared.client else {
            throw PaletteServiceError.notAuthenticated
        }
        let accessToken: String
        do {
            let session = try await client.auth.session
            accessToken = session.accessToken
        } catch {
            throw PaletteServiceError.notAuthenticated
        }

        guard let url = URL(string: backendURL + path) else {
            throw PaletteServiceError.server(message: "Invalid URL")
        }

        let bodyBytes: Data
        if let body {
            do {
                bodyBytes = try JSONSerialization.data(withJSONObject: body)
            } catch {
                throw PaletteServiceError.server(message: "Couldn't serialize request body")
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
            throw PaletteServiceError.server(
                message: "Couldn't verify this device. \(error.localizedDescription)"
            )
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
            throw PaletteServiceError.transport(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PaletteServiceError.server(message: "Unexpected response")
        }

        switch http.statusCode {
        case 200, 201:
            if T.self == EmptyResponse.self {
                return EmptyResponse() as! T
            }
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601WithFractionalSecondsForPalettes
                return try decoder.decode(T.self, from: data)
            } catch {
                throw PaletteServiceError.decoding(underlying: error)
            }

        case 400:
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = payload?["error"] as? String ?? "Invalid palette data."
            throw PaletteServiceError.validation(message: message)
        case 401:
            throw PaletteServiceError.unauthorized
        case 403:
            throw PaletteServiceError.forbidden
        case 404:
            throw PaletteServiceError.notFound
        default:
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = payload?["error"] as? String ?? "Server error (\(http.statusCode))"
            throw PaletteServiceError.server(message: message)
        }
    }
}

// MARK: - Date decoding

private extension JSONDecoder.DateDecodingStrategy {
    /// Same ISO8601 fractional-seconds tolerance EveService uses.
    /// Supabase emits both shapes depending on column / driver path.
    static var iso8601WithFractionalSecondsForPalettes: JSONDecoder.DateDecodingStrategy {
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
