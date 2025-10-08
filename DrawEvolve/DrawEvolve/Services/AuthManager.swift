//
//  AuthManager.swift
//  DrawEvolve
//
//  Manages user authentication with Supabase.
//

import Foundation
import SwiftUI
import Supabase

@MainActor
class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var currentUser: User?
    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let supabase = SupabaseManager.shared.client

    init() {
        // Check for existing session
        Task {
            await checkSession()
        }
    }

    // MARK: - Session Management

    func checkSession() async {
        do {
            let session = try await supabase.auth.session
            currentUser = session.user
            isAuthenticated = true
        } catch {
            isAuthenticated = false
            currentUser = nil
        }
    }

    // MARK: - Sign Up

    func signUp(email: String, password: String) async throws {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            let response = try await supabase.auth.signUp(
                email: email,
                password: password
            )

            currentUser = response.user
            isAuthenticated = true
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Sign In

    func signIn(email: String, password: String) async throws {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            let session = try await supabase.auth.signIn(
                email: email,
                password: password
            )

            currentUser = session.user
            isAuthenticated = true
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Sign Out

    func signOut() async throws {
        try await supabase.auth.signOut()
        currentUser = nil
        isAuthenticated = false
    }

    // MARK: - Guest Mode

    func continueAsGuest() {
        // Set guest mode flag without authentication
        isAuthenticated = true
        currentUser = nil
    }
}
