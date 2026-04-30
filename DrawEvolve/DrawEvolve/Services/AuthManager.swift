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
import UIKit

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
    private var currentGoogleNonce: String? = nil
    private var currentGoogleCodeVerifier: String? = nil
    private var googleAuthSession: ASWebAuthenticationSession? = nil
    private let googlePresentationProvider = GooglePresentationProvider()
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

    // MARK: - Sign in with Google
    //
    // OpenID Connect authorization-code flow with PKCE via
    // ASWebAuthenticationSession (no SDK). Google returns an authorization
    // code in the callback URL's QUERY STRING (not fragment); we POST it
    // along with the PKCE code_verifier to Google's token endpoint, get
    // back an id_token, then hand that to Supabase — same final step as
    // the Apple exchange. iOS clients have no client_secret; PKCE proves
    // possession instead. Redirect URI is Google's reverse-client-ID
    // scheme; do NOT reuse drawevolve://, that's reserved for magic-link
    // callbacks.

    private static let googleClientID = "228877785649-cm4qdh7d841fpkcmronltsnh8ub224dh.apps.googleusercontent.com"
    private static let googleCallbackScheme = "com.googleusercontent.apps.228877785649-cm4qdh7d841fpkcmronltsnh8ub224dh"
    private static let googleRedirectURI = "\(googleCallbackScheme):/oauth2redirect"
    private static let googleTokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// Generate a fresh nonce + PKCE pair for the Google authorization request.
    /// Raw nonce + raw code_verifier stay on `self` until the token exchange
    /// completes; the hashed nonce + base64url(SHA256(verifier)) go to Google.
    @discardableResult
    private func prepareGoogleSignIn() -> (hashedNonce: String, codeChallenge: String) {
        let nonce = Self.randomNonce()
        currentGoogleNonce = nonce
        // PKCE spec: 43–128 unreserved chars. randomNonce default is 32, so
        // bump to 64 to land safely inside the allowed range.
        let verifier = Self.randomNonce(length: 64)
        currentGoogleCodeVerifier = verifier
        return (Self.sha256(nonce), Self.sha256Base64URL(verifier))
    }

    private func clearGoogleAuthState() {
        currentGoogleNonce = nil
        currentGoogleCodeVerifier = nil
        googleAuthSession = nil
    }

    /// Drive the full Google OAuth flow: open the auth URL in
    /// ASWebAuthenticationSession, pull the authorization code out of the
    /// callback URL's query string, exchange it at Google's token endpoint
    /// for an id_token, then exchange that for a Supabase session.
    func signInWithGoogle() async {
        guard let client = SupabaseManager.shared.client else {
            lastError = AuthError.notConfigured.errorDescription
            return
        }

        let challenge = prepareGoogleSignIn()
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: Self.googleClientID),
            URLQueryItem(name: "redirect_uri", value: Self.googleRedirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "nonce", value: challenge.hashedNonce),
            URLQueryItem(name: "code_challenge", value: challenge.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let authURL = components?.url else {
            lastError = "Google sign-in returned an unexpected response."
            clearGoogleAuthState()
            return
        }

        let callbackURL: URL
        do {
            callbackURL = try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: Self.googleCallbackScheme
                ) { url, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: NSError(
                            domain: "DrawEvolve.Auth",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Google sign-in returned no URL."]
                        ))
                    }
                }
                session.presentationContextProvider = googlePresentationProvider
                googleAuthSession = session
                session.start()
            }
        } catch {
            // User-cancellation matches SIWA's silent no-op convention.
            if (error as NSError).code != ASWebAuthenticationSessionError.canceledLogin.rawValue {
                lastError = "Google sign-in failed: \(error.localizedDescription)"
            }
            clearGoogleAuthState()
            return
        }
        googleAuthSession = nil

        guard let code = Self.parseQueryValue(from: callbackURL, key: "code"),
              let nonce = currentGoogleNonce,
              let verifier = currentGoogleCodeVerifier else {
            lastError = "Google sign-in returned an unexpected response."
            clearGoogleAuthState()
            return
        }

        do {
            let idToken = try await Self.exchangeGoogleAuthCode(code: code, verifier: verifier)
            _ = try await client.auth.signInWithIdToken(
                credentials: .init(provider: .google, idToken: idToken, nonce: nonce)
            )
            clearGoogleAuthState()
            lastError = nil
        } catch {
            lastError = "Google sign-in failed: \(error.localizedDescription)"
            clearGoogleAuthState()
        }
    }

    /// POST the authorization code + PKCE verifier to Google's token endpoint
    /// and return the id_token. iOS clients have no client_secret; PKCE
    /// (the verifier matching the challenge from the auth request) proves
    /// possession instead.
    private static func exchangeGoogleAuthCode(code: String, verifier: String) async throws -> String {
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: googleClientID),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "redirect_uri", value: googleRedirectURI),
        ]
        var request = URLRequest(url: googleTokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DrawEvolve.Auth",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "Google token exchange failed (\(status)): \(body)"]
            )
        }
        return try JSONDecoder().decode(GoogleTokenResponse.self, from: data).idToken
    }

    private struct GoogleTokenResponse: Decodable {
        let idToken: String
        enum CodingKeys: String, CodingKey { case idToken = "id_token" }
    }

    /// Pull a single key out of a URL's query string (e.g. `?code=...&state=...`).
    /// Code flow returns the authorization code as a query param, not in the
    /// fragment like implicit flow did.
    private static func parseQueryValue(from url: URL, key: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == key })?
            .value
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

    /// Signs out of Supabase, clears the local cache, and lets `authStateChanges`
    /// bounce ContentView back to AuthGateView. **Cloud data is preserved** —
    /// the user's drawings + critique history remain in Supabase and re-hydrate
    /// on the next sign-in.
    func signOut() async {
        guard let client = SupabaseManager.shared.client else { return }
        do {
            try await client.auth.signOut()
            await CloudDrawingStorageManager.shared.clearLocalCache()
        } catch {
            lastError = "Sign-out failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Account deletion (Phase 6 — calls the delete-account edge function)

    /// Calls the `delete-account` Supabase Edge Function which performs the
    /// hard-delete cascade (Storage → drawings → profile → audit row → auth.users).
    /// On success, signs out and clears the local cache; the user lands back on
    /// AuthGateView as a stranger. On failure, throws — caller stays signed in
    /// with cloud data intact.
    ///
    /// AUTH HEADER: Supabase's Swift SDK `client.functions.invoke(...)` does
    /// **automatically** attach the current session's JWT in the Authorization
    /// header — that's what the edge function's JWKS verification reads. **Do
    /// not** strip or override the `Authorization` header here; doing so would
    /// make every delete request fail with 401. This contract is documented in
    /// supabase-swift's FunctionsClient and is not configurable per-call.
    func deleteAccount() async throws {
        guard let client = SupabaseManager.shared.client else {
            throw AuthError.notConfigured
        }

        // Explicit type annotation drives supabase-swift's
        // `invoke<T: Decodable>(_:options:decoder:)` overload. The SDK
        // attaches `Authorization: Bearer <session.accessToken>`
        // automatically — see the doc comment above.
        let result: DeleteAccountResult = try await client.functions.invoke(
            "delete-account",
            options: FunctionInvokeOptions(method: .post)
        )
        if !result.success {
            throw AuthError.deleteFailed(
                step: result.step ?? "unknown",
                message: result.error ?? "Unknown error"
            )
        }

        // Best-effort cleanup. If signOut throws (network blip after server-
        // side deletion already happened), the auth.users row is gone, the
        // SDK's next refresh will fail, and `authStateChanges` will route
        // the user back to AuthGateView regardless.
        try? await client.auth.signOut()
        await CloudDrawingStorageManager.shared.clearLocalCache()
    }

    private struct DeleteAccountResult: Decodable {
        let success: Bool
        let error: String?
        let step: String?
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

    /// BASE64URL(SHA256(input)) — the PKCE S256 code_challenge encoding.
    /// Standard base64 with `+`/`/` swapped for `-`/`_` and padding stripped.
    private static func sha256Base64URL(_ input: String) -> String {
        Data(SHA256.hash(data: Data(input.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum AuthError: LocalizedError {
    case notConfigured
    case notImplemented
    /// Edge function returned `{ success: false, step, error }`. The audit
    /// step is special-cased in the user-facing copy below: it's the safest
    /// failure mode (no user data has been touched yet) so the message
    /// reassures rather than alarms.
    case deleteFailed(step: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Sign-in is unavailable: SUPABASE_URL and SUPABASE_ANON_KEY are not set in Config.plist."
        case .notImplemented:
            return "Account deletion isn't wired up yet."
        case .deleteFailed(let step, _):
            switch step {
            case "audit":
                // Audit insert is BEFORE auth deletion in the cascade. If it
                // fails, nothing destructive has happened yet — phrase it
                // reassuringly so the user retries without panic.
                return "We couldn't start the deletion. Your account and all your data are still intact. Please try again in a moment."
            case "auth":
                // Auth deletion is the last step. If it fails, all the user
                // data is already gone but the auth row remains. Surface
                // honestly — they need to contact support to finish.
                return "Your data has been removed but we couldn't finalize the account closure. Please contact support so we can complete it."
            case "storage":
                return "Couldn't remove your stored drawings. No data has been deleted yet — please try again."
            case "drawings":
                return "Couldn't remove your drawing records. Some data may have been partially cleaned up — please try again or contact support."
            case "profile":
                return "Couldn't remove your profile data. No drawings have been deleted yet — please try again."
            default:
                return "Account deletion failed at step '\(step)'. Please try again."
            }
        }
    }
}

// MARK: - Google web auth presentation anchor
//
// ASWebAuthenticationSession needs a UIWindow anchor via NSObject conformance.
// AuthManager isn't NSObject, so this small bridge carries the protocol.

private final class GooglePresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
        let active = scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        let scene = active ?? scenes.first { $0 is UIWindowScene } as? UIWindowScene
        return scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first ?? ASPresentationAnchor()
    }
}
