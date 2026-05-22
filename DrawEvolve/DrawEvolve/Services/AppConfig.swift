//
//  AppConfig.swift
//  DrawEvolve
//
//  Reads runtime config (Supabase URL, anon key) from Config.plist.
//  Returns nil when the keys haven't been set yet so the project keeps
//  building before Phase 0 of authandratelimitingandsecurity.md is done.
//

import Foundation

enum AppConfig {
    static var supabaseURL: URL? {
        guard let raw = string(forKey: "SUPABASE_URL"),
              let url = URL(string: raw),
              !raw.contains("YOUR-PROJECT") else {
            return nil
        }
        return url
    }

    static var supabaseAnonKey: String? {
        guard let raw = string(forKey: "SUPABASE_ANON_KEY"),
              !raw.contains("YOUR-ANON-KEY") else {
            return nil
        }
        return raw
    }

    static var isSupabaseConfigured: Bool {
        supabaseURL != nil && supabaseAnonKey != nil
    }

    /// Cached Config.plist contents. The plist is read once at first
    /// access and reused for every subsequent key lookup. The previous
    /// pattern hit `Bundle.main.path` + `NSDictionary(contentsOfFile:)`
    /// on every static var access, which during launch happened at
    /// least twice (URL + anon key) for no reason.
    private static let cachedDict: NSDictionary? = {
        guard let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) else {
            return nil
        }
        return dict
    }()

    private static func string(forKey key: String) -> String? {
        guard let value = cachedDict?[key] as? String, !value.isEmpty else {
            return nil
        }
        return value
    }
}
