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

    private static func string(forKey key: String) -> String? {
        guard let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path),
              let value = dict[key] as? String,
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
