//
//  EventLogService.swift
//  DrawEvolve
//
//  Fire-and-forget event sink for public.user_event_log (migration 0019).
//  First consumer is the fresh-install tutorial; subsequent PRs will
//  instrument other surfaces (critique funnel, Eve engagement, etc).
//
//  CONTRACT: analytics failure must NEVER block UX or surface to the user.
//  Every call site is fire-and-forget. Errors (network drop, missing
//  client, RLS misconfig, encoding failure) are swallowed silently. If
//  the table is missing, we lose the event — the user still sees the
//  tutorial.
//
//  Event shapes are documented at call sites and in the migration header.
//  payload is jsonb with no server-side schema validation; callers are
//  responsible for shape. The custom Encodable here handles String / Int
//  / Double / Bool / nil — anything else is silently dropped from the
//  payload. Good enough for the tutorial events; revisit if a future
//  caller needs nested objects or arrays.
//

import Foundation
import Supabase

@MainActor
final class EventLogService {
    static let shared = EventLogService()

    private init() {}

    /// Fire-and-forget. Returns immediately; the insert happens on a
    /// detached background task. Errors are swallowed. Do not chain
    /// UX logic off this call.
    func log(event: String, payload: [String: Any] = [:]) {
        Task.detached(priority: .background) {
            await Self.persist(event: event, payload: payload)
        }
    }

    /// Internal worker. Static so it doesn't capture the actor; we don't
    /// hop back to MainActor after the fire-and-forget detach.
    private static func persist(event: String, payload: [String: Any]) async {
        guard let client = SupabaseManager.shared.client else { return }

        let userID: UUID
        do {
            userID = try await client.auth.session.user.id
        } catch {
            // No session → fire-and-forget swallow. Anonymous events
            // would violate the RLS policy (auth.uid() = user_id check),
            // so there's no fallback path; just drop the event.
            return
        }

        let row = EventInsertRow(
            user_id: userID.uuidString.lowercased(),
            event_name: event,
            payload: JSONPayload(dict: payload)
        )

        do {
            try await client
                .from("user_event_log")
                .insert(row)
                .execute()
        } catch {
            // Swallow. See CONTRACT in file header.
            #if DEBUG
            print("[EventLogService] dropped event '\(event)': \(error.localizedDescription)")
            #endif
        }
    }
}

// MARK: - Wire types

private struct EventInsertRow: Encodable {
    let user_id: String
    let event_name: String
    let payload: JSONPayload
    // created_at omitted — server default fills it.
}

/// Custom Encodable that bridges `[String: Any]` to a JSON object suitable
/// for jsonb. Only primitive value types are encoded; unsupported types
/// (arrays, nested dicts, Date, custom objects) are silently dropped. For
/// the tutorial event shapes this is sufficient; extend if a future caller
/// needs richer payloads.
private struct JSONPayload: Encodable {
    let dict: [String: Any]

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        for (key, value) in dict {
            guard let codingKey = StringCodingKey(stringValue: key) else { continue }
            switch value {
            case let v as String:
                try container.encode(v, forKey: codingKey)
            case let v as Bool:
                try container.encode(v, forKey: codingKey)
            case let v as Int:
                try container.encode(v, forKey: codingKey)
            case let v as Double:
                try container.encode(v, forKey: codingKey)
            case is NSNull:
                try container.encodeNil(forKey: codingKey)
            default:
                // DEBUG-only warning: silent drop means future event callers
                // adding nested objects/arrays would lose data with no signal.
                // Extend the switch above if this fires for a legitimate
                // use case.
                #if DEBUG
                print("[EventLogService] ⚠️ dropping payload key '\(key)' — unsupported type \(type(of: value)). Add a case to JSONPayload.encode if this is intentional.")
                #endif
                continue
            }
        }
    }
}

private struct StringCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        return nil
    }
}
