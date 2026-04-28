//
//  SupabaseManager.swift
//  DrawEvolve
//
//  Wraps the Supabase client. `client` is nil until Config.plist has real
//  SUPABASE_URL + SUPABASE_ANON_KEY values — auth flows surface a clear error
//  in that case rather than crashing the app at launch.
//

import Foundation
import Supabase

#if DEBUG
/// Pipes every SDK log message to the Xcode console. Compiled out of
/// Release builds so production never pays the chatter cost.
private struct DrawEvolveSupabaseLogger: SupabaseLogger {
    func log(message: SupabaseLogMessage) {
        print("[Supabase \(message.level)] \(message.message)")
    }
}

/// HTTP/3 / QUIC has been observed to hang in the iOS simulator against
/// Supabase's edge — the console shows
/// "nw_connection_copy_connected_local_endpoint_block_invoke - Connection
/// has no local endpoint" and "quic_conn_process_inbound - unable to parse
/// packet", with `signInWithOTP` never returning.
///
/// There is no public iOS API to disable HTTP/3 outright. Apple only
/// exposes `URLRequest.assumesHTTP3Capable` to opt *in*; the OS still
/// opportunistically upgrades to HTTP/3 from cached `Alt-Svc` records.
///
/// The pragmatic workaround is an ephemeral configuration so the session
/// doesn't share the system's QUIC route cache, plus `urlCache = nil` so
/// no Alt-Svc record carries over to bias the next request. This biases
/// URLSession toward HTTP/2 in practice — it does not *guarantee* HTTP/3
/// is never selected. If the simulator hang persists we'll need the
/// `_supportsHTTP3` KVC private-flag escalation (DEBUG-only; not App-Store
/// safe).
private func makeSimulatorFriendlyURLSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    config.httpMaximumConnectionsPerHost = 2
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 60
    return URLSession(configuration: config)
}
#endif

final class SupabaseManager {
    static let shared = SupabaseManager()

    let client: SupabaseClient?

    private init() {
        guard let url = AppConfig.supabaseURL,
              let key = AppConfig.supabaseAnonKey else {
            #if DEBUG
            print("⚠️ SupabaseManager: SUPABASE_URL / SUPABASE_ANON_KEY not set in Config.plist. Auth + cloud sync will be unavailable until Phase 0 of authandratelimitingandsecurity.md is complete.")
            #endif
            self.client = nil
            return
        }
        #if DEBUG
        self.client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: key,
            options: SupabaseClientOptions(
                global: SupabaseClientOptions.GlobalOptions(
                    session: makeSimulatorFriendlyURLSession(),
                    logger: DrawEvolveSupabaseLogger()
                )
            )
        )
        print("✅ SupabaseManager initialized for \(url.host ?? "unknown host") (HTTP/3 biased off, verbose logging on)")
        #else
        self.client = SupabaseClient(supabaseURL: url, supabaseKey: key)
        #endif
    }
}
