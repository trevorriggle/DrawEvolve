//
//  AuthManager.swift
//  DrawEvolve
//
//  Phase 1 of authandratelimitingandsecurity.md. Owns auth state, exposes
//  Sign in with Apple + email magic-link flows, and handles the magic-link
//  deep-link callback. Listens to Supabase's authStateChanges stream so the
//  published state stays in sync across launches and remote sign-outs.
//

import AuthenticationServices
import CryptoKit
import Foundation
import Supabase

@MainActor
final class AuthManager: ObservableObject {
    enum State {
        case loading
        case signedOut
        case signedIn(User)
    }

    static let shared = AuthManager()

    @Published private(set) var state: State = .loading
    @Published var pendingMagicLinkEmail: String? = nil
    @Published var lastError: String? = nil

    static let callbackURLString = "drawevolve://auth/callback"
    static var callbackURL: URL { URL(string: callbackURLString)! }

    private var currentAppleNonce: String? = nil
    private var stateObserver: Task<Void, Never>? = nil

    var currentUser: User? {
        if case .signedIn(let user) = state { return user }
        return nil
    }

    var currentUserID: UUID? {
        if let id = currentUser?.id { return id }
        #if DEBUG
        if isDebugBypassed { return Self.debugBypassUserID }
        #endif
        return nil
    }

    #if DEBUG
    // MARK: - Debug bypass (compiled out of Release; UserDefaults install-scoped)

    /// Synthetic UUID stamped on drawings saved while the auth gate is bypassed.
    /// No matching `auth.users` row exists, so any cloud operation against
    /// Supabase will fail with an RLS denial — that's intentional. The bypass
    /// is for exercising local-only flows while real auth is gated on Apple
    /// Developer approval.
    static let debugBypassUserID = UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")!

    private static let debugBypassDefaultsKey = "drawevolve.debug.authBypass"

    @Published private(set) var isDebugBypassed: Bool =
        UserDefaults.standard.bool(forKey: "drawevolve.debug.authBypass")

    /// Enter the app without going through Supabase. DEBUG only.
    func enableDebugBypass() {
        isDebugBypassed = true
        UserDefaults.standard.set(true, forKey: Self.debugBypassDefaultsKey)
        lastError = nil
    }

    /// Drop back to the auth gate. DEBUG only.
    func disableDebugBypass() {
        isDebugBypassed = false
        UserDefaults.standard.set(false, forKey: Self.debugBypassDefaultsKey)
    }
    #endif

    private init() {
        Task { await bootstrap() }
    }

    deinit {
        stateObserver?.cancel()
    }

    private func bootstrap() async {
        guard let client = SupabaseManager.shared.client else {
            state = .signedOut
            return
        }
        do {
            let session = try await client.auth.session
            state = .signedIn(session.user)
        } catch {
            state = .signedOut
        }
        observeAuthChanges(client: client)
    }

    private func observeAuthChanges(client: SupabaseClient) {
        stateObserver?.cancel()
        stateObserver = Task { [weak self] in
            for await (_, session) in client.auth.authStateChanges {
                await MainActor.run {
                    guard let self else { return }
                    if let user = session?.user {
                        self.state = .signedIn(user)
                    } else {
                        self.state = .signedOut
                    }
                }
            }
        }
    }

    // MARK: - Sign in with Apple

    /// Configure an ASAuthorizationAppleIDRequest with a fresh nonce.
    /// Call from `SignInWithAppleButton`'s `onRequest`.
    func prepareAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        currentAppleNonce = nonce
        request.requestedScopes = [.email, .fullName]
        request.nonce = Self.sha256(nonce)
    }

    /// Complete sign-in after the system Apple sheet returns.
    /// Call from `SignInWithAppleButton`'s `onCompletion`.
    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let error):
            lastError = error.localizedDescription
        case .success(let authorization):
            await exchangeAppleCredential(authorization)
        }
    }

    private func exchangeAppleCredential(_ authorization: ASAuthorization) async {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8),
              let nonce = currentAppleNonce else {
            lastError = "Apple sign-in returned an unexpected response."
            return
        }
        guard let client = SupabaseManager.shared.client else {
            lastError = AuthError.notConfigured.errorDescription
            return
        }
        do {
            _ = try await client.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
            )
            currentAppleNonce = nil
            lastError = nil
        } catch {
            lastError = "Apple sign-in failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Email magic link

    func sendMagicLink(email: String) async {
        guard let client = SupabaseManager.shared.client else {
            lastError = AuthError.notConfigured.errorDescription
            return
        }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let redirectURL = Self.callbackURL
        let start = Date()
        #if DEBUG
        print("🪪 sendMagicLink → \(trimmed) redirectTo=\(redirectURL.absoluteString)")
        #endif
        do {
            // 30s watchdog: signInWithOTP must return one way or the other so
            // the spinner can't hang forever. If the SDK respects cancellation,
            // cancelAll() will unblock the underlying URLSession task.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await client.auth.signInWithOTP(
                        email: trimmed,
                        redirectTo: redirectURL,
                        shouldCreateUser: true
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    throw NSError(
                        domain: "DrawEvolve.Auth",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "signInWithOTP timed out after 30s"]
                    )
                }
                _ = try await group.next()
                group.cancelAll()
            }
            let elapsed = Date().timeIntervalSince(start)
            #if DEBUG
            print("✅ sendMagicLink returned in \(String(format: "%.2f", elapsed))s")
            #endif
            pendingMagicLinkEmail = trimmed
            lastError = nil
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            #if DEBUG
            print("❌ sendMagicLink failed after \(String(format: "%.2f", elapsed))s: \(error)")
            #endif
            lastError = "Couldn't send magic link: \(error.localizedDescription)"
        }
    }

    /// Consume the magic-link callback URL — wired up via `.onOpenURL` in the App.
    func handleDeepLink(_ url: URL) async {
        guard let client = SupabaseManager.shared.client else { return }
        do {
            _ = try await client.auth.session(from: url)
            pendingMagicLinkEmail = nil
            lastError = nil
        } catch {
            lastError = "Could not complete sign-in: \(error.localizedDescription)"
        }
    }

    // MARK: - Sign out

    func signOut() async {
        guard let client = SupabaseManager.shared.client else { return }
        do {
            try await client.auth.signOut()
        } catch {
            lastError = "Sign-out failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Account deletion (Phase 6 — calls a Supabase Edge Function)

    func deleteAccount() async throws {
        // Wired up in Phase 6 of authandratelimitingandsecurity.md.
        throw AuthError.notImplemented
    }

    // MARK: - Crypto helpers

    private static func randomNonce(length: Int = 32) -> String {
        precondition(length > 0)
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "Unable to generate secure random nonce.")
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum AuthError: LocalizedError {
    case notConfigured
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Sign-in is unavailable: SUPABASE_URL and SUPABASE_ANON_KEY are not set in Config.plist."
        case .notImplemented:
            return "Account deletion isn't wired up yet."
        }
    }
}
