//
//  SupabaseManager.swift
//  DrawEvolve
//
//  Supabase configuration and client setup.
//

import Foundation
import Supabase

class SupabaseManager {
    static let shared = SupabaseManager()

    let client: SupabaseClient

    private init() {
        // Initialize Supabase client
        client = SupabaseClient(
            supabaseURL: URL(string: "https://ipachwcfclhhhrvogmll.supabase.co")!,
            supabaseKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImlwYWNod2NmY2xoaGhydm9nbWxsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTk5MjQyOTQsImV4cCI6MjA3NTUwMDI5NH0.fGCsrbyGKoyWcIK2er77JoGT3eOCPetqDfyhXRgTnqk"
        )
    }
}
