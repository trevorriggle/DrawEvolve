//
//  FeedbackService.swift
//  DrawEvolve
//
//  Thin wrapper around the public.feedback_submissions table (migration
//  0018). One method — submit(category:body:) — does the PostgREST insert
//  with RLS-protected auth.uid() = user_id check on the server.
//
//  Rate limiting (5/hour/user) is enforced by a server-side trigger; this
//  client surfaces that error distinctly so the caller can show
//  "you've sent feedback recently" copy instead of a generic failure.
//
//  Pattern mirrors EvolutionService (actor, static shared, typed errors).
//

import Foundation
import Supabase
import UIKit

enum FeedbackCategory: String, CaseIterable, Identifiable, Hashable {
    case bug
    case confusion
    case featureRequest = "feature_request"
    case other

    var id: String { rawValue }

    /// User-facing label for the picker. Kept here so the sheet doesn't
    /// duplicate the mapping.
    var label: String {
        switch self {
        case .bug:             return "Bug"
        case .confusion:       return "Something was confusing"
        case .featureRequest:  return "Feature request"
        case .other:           return "Other"
        }
    }
}

enum FeedbackError: Error, Equatable {
    case notAuthenticated
    /// Server-side rate-limit trigger fired (P0001). Caller should show
    /// "you've sent feedback recently — try again in a bit" copy.
    case rateLimited
    /// Body length outside the 10..4000 char range. Caught client-side
    /// before the network call so the Send button can be disabled
    /// proactively, but kept as a thrown error so the sheet can render
    /// it if the disabled-button check is ever bypassed.
    case invalidBodyLength
    case network
    case unknown(String)

    var userFacingMessage: String {
        switch self {
        case .notAuthenticated:
            return "Sign in again to send feedback."
        case .rateLimited:
            return "You've sent feedback recently. Try again in a bit."
        case .invalidBodyLength:
            return "Feedback must be between 10 and 4000 characters."
        case .network:
            return "Couldn't send. Check your connection and try again."
        case .unknown:
            return "Couldn't send. Check your connection and try again."
        }
    }
}

actor FeedbackService {
    static let shared = FeedbackService()

    private init() {}

    /// Submit a feedback row. Captures app version + device idiom at call
    /// time as debugging hints — no IDFV, no IP, no identifying metadata
    /// beyond the user_id the server already knows about via the JWT.
    func submit(category: FeedbackCategory, body: String) async throws {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (10...4000).contains(trimmedBody.count) else {
            throw FeedbackError.invalidBodyLength
        }

        guard let client = SupabaseManager.shared.client else {
            throw FeedbackError.notAuthenticated
        }

        // The server's RLS policy requires auth.uid() == user_id. We rely on
        // the SDK to attach the current session JWT automatically; user_id
        // in the row body must match what the JWT claims or RLS rejects.
        let userID = try await client.auth.session.user.id

        let row = FeedbackInsertRow(
            user_id: userID.uuidString.lowercased(),
            category: category.rawValue,
            body: trimmedBody,
            app_version: Self.currentAppVersion,
            device_info: Self.currentDeviceInfo
        )

        do {
            try await client
                .from("feedback_submissions")
                .insert(row)
                .execute()
        } catch {
            throw Self.mapInsertError(error)
        }
    }

    // MARK: - Error mapping

    /// Map an SDK / PostgREST error to our typed enum. We avoid pinning to
    /// a specific PostgrestError type — supabase-swift's error surface has
    /// shifted between minor versions, and a string-based match on the
    /// message keeps us forward-compatible. The trigger raises with
    /// errcode P0001 and a message starting "Feedback rate limit exceeded"
    /// — we match on either.
    ///
    /// String-matched against supabase-swift 2.34.0 (per CLAUDE.md). Revisit
    /// the substrings below if upgrading: a future SDK may surface the
    /// PostgrestError fields differently in `String(describing:)`, e.g.
    /// changing field order or hiding `code` from the default description.
    /// Grep token for upgrades: "supabase-swift 2.34.0".
    private static func mapInsertError(_ error: Error) -> FeedbackError {
        let description = String(describing: error).lowercased()
        if description.contains("feedback rate limit")
            || description.contains("p0001") {
            return .rateLimited
        }
        if (error as? URLError) != nil {
            return .network
        }
        return .unknown(error.localizedDescription)
    }

    // MARK: - Debug-context helpers

    private static var currentAppVersion: String? {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        guard let version else { return nil }
        if let build { return "\(version) (\(build))" }
        return version
    }

    /// "iOS 17.4 / iPad" — short, debug-only. No model identifier, no
    /// IDFV, no anything that could fingerprint the user.
    private static var currentDeviceInfo: String {
        let systemName = UIDevice.current.systemName
        let systemVersion = UIDevice.current.systemVersion
        let idiom = DeviceIdiom.isPhone ? "iPhone"
                  : DeviceIdiom.isPad   ? "iPad"
                  : "other"
        return "\(systemName) \(systemVersion) / \(idiom)"
    }
}

// MARK: - Wire types

private struct FeedbackInsertRow: Encodable {
    let user_id: String
    let category: String
    let body: String
    let app_version: String?
    let device_info: String?
    // submitted_at is omitted — server default fills it.
}
