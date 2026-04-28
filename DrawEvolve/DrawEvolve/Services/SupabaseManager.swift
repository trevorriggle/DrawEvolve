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
                    logger: DrawEvolveSupabaseLogger()
                )
            )
        )
        print("✅ SupabaseManager initialized for \(url.host ?? "unknown host") (verbose logging on)")
        #else
        self.client = SupabaseClient(supabaseURL: url, supabaseKey: key)
        #endif
    }
}
