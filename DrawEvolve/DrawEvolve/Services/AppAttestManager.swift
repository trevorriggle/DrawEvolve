//
//  AppAttestManager.swift
//  DrawEvolve
//
//  App Attest device verification. Generates a hardware-backed key on first
//  launch, attests it with Apple, caches the keyId in Keychain, and produces
//  per-request assertions that the Worker verifies before serving any
//  protected endpoint.
//
//  Layered ON TOP of Supabase JWT auth — JWT proves who the user is, App
//  Attest proves the request comes from a real DrawEvolve install on a real
//  Apple device. Both required for protected calls.
//
//  Flow on first launch:
//    1. AppAttestManager.shared.attestedHeaders(method:path:body:) is called
//       from the request layer.
//    2. No keyId in Keychain → generate one via DCAppAttestService.
//    3. Fetch a fresh challenge from Worker (POST /attest/challenge).
//    4. Attest the key with Apple servers.
//    5. POST { keyId, attestation, challenge } to Worker /attest/register.
//    6. Cache keyId in Keychain (kSecClassGenericPassword, this-device-only).
//    7. Generate an assertion over sha256("<METHOD>:<PATH>:<sha256(body)>").
//    8. Return headers for the caller to attach.
//
//  Subsequent requests skip steps 2–6 — Keychain hit, generate assertion,
//  attach headers. If Apple later invalidates the key (DCError.invalidKey on
//  assertion), we wipe the Keychain entry and re-attest on next call.
//

import CryptoKit
import DeviceCheck
import Foundation
import Security

enum AppAttestError: LocalizedError {
    case notSupported
    case keyGenerationFailed(String)
    case attestationFailed(String)
    case assertionFailed(String)
    case challengeFetchFailed(String)
    case registrationRejected(Int, String?)
    case keychainWriteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "This device doesn't support App Attest. iOS 14+ on real hardware is required."
        case .keyGenerationFailed(let m):
            return "Couldn't initialize device verification: \(m)"
        case .attestationFailed(let m):
            return "Couldn't verify this device with Apple: \(m)"
        case .assertionFailed(let m):
            return "Device verification failed for this request: \(m)"
        case .challengeFetchFailed(let m):
            return "Couldn't reach the verification server: \(m)"
        case .registrationRejected(let status, let body):
            return "Server rejected device registration (HTTP \(status)): \(body ?? "no body")"
        case .keychainWriteFailed(let status):
            return "Couldn't persist device verification (Keychain error \(status))."
        }
    }
}

actor AppAttestManager {
    static let shared = AppAttestManager()

    /// Backend base URL. MUST match OpenAIManager.backendURL — they hit the
    /// same Worker. Kept as a single constant here so /attest/challenge and
    /// /attest/register are derived from it.
    private let backendURL = URL(string: "https://drawevolve-backend.trevorriggle.workers.dev")!

    /// Keychain service / account for the cached keyId. Service-scoped so
    /// future Keychain entries don't collide. kSecAttrAccessibleAfterFirstUnlock
    /// — App Attest assertions need to run on background fetches before the
    /// user has unlocked the device this session, but never before the device
    /// has been unlocked since boot (which would imply post-restore state).
    private let keychainService = "com.drawevolve.appattest"
    private let keychainAccount = "keyId"

    private let service = DCAppAttestService.shared

    /// In-flight registration future. Without this, a burst of concurrent
    /// requests on first launch would each try to generate + attest a key,
    /// burning multiple Apple round-trips and producing orphan keys that
    /// were never registered server-side.
    private var pendingRegistration: Task<String, Error>?

    private init() {}

    // MARK: - Public API

    /// Returns the headers the request layer should attach to every outbound
    /// Worker call. On first call, this triggers full attestation + server
    /// registration. Subsequent calls just generate a fresh assertion bound
    /// to the request method/path/body.
    ///
    /// Callers must pass the EXACT body bytes they're about to send — the
    /// Worker recomputes sha256(body) from the bytes it receives, so any
    /// re-serialization between this call and URLSession.dataTask will break
    /// verification.
    func attestedHeaders(method: String, path: String, body: Data) async throws -> [String: String] {
        guard service.isSupported else { throw AppAttestError.notSupported }

        let keyId = try await ensureRegisteredKeyId()
        let assertion: Data
        do {
            assertion = try await generateAssertion(keyId: keyId, method: method, path: path, body: body)
        } catch let err as NSError where err.domain == DCError.errorDomain && err.code == DCError.invalidKey.rawValue {
            // Apple invalidated the key (e.g. App Attest server lost trust,
            // device was restored from backup). Wipe local cache and re-attest
            // once on this same call so the user doesn't see a failure.
            deleteCachedKeyId()
            let freshKeyId = try await ensureRegisteredKeyId()
            assertion = try await generateAssertion(keyId: freshKeyId, method: method, path: path, body: body)
            return Self.headers(keyId: freshKeyId, assertion: assertion)
        }
        return Self.headers(keyId: keyId, assertion: assertion)
    }

    // MARK: - Header shaping

    private static func headers(keyId: String, assertion: Data) -> [String: String] {
        return [
            "X-Apple-AppAttest-KeyId": keyId,
            "X-Apple-AppAttest-Assertion": assertion.base64EncodedString(),
        ]
    }

    // MARK: - Key lifecycle

    private func ensureRegisteredKeyId() async throws -> String {
        if let cached = readCachedKeyId() { return cached }
        if let pending = pendingRegistration {
            return try await pending.value
        }
        let task = Task<String, Error> { [self] in
            try await self.registerNewKey()
        }
        pendingRegistration = task
        defer { pendingRegistration = nil }
        return try await task.value
    }

    private func registerNewKey() async throws -> String {
        let keyId: String
        do {
            keyId = try await service.generateKey()
        } catch {
            throw AppAttestError.keyGenerationFailed(error.localizedDescription)
        }

        let challenge = try await fetchChallenge()
        let clientDataHash = Data(SHA256.hash(data: challenge))

        let attestation: Data
        do {
            attestation = try await service.attestKey(keyId, clientDataHash: clientDataHash)
        } catch {
            throw AppAttestError.attestationFailed(error.localizedDescription)
        }

        try await postRegistration(keyId: keyId, attestation: attestation, challenge: challenge)
        try writeCachedKeyId(keyId)
        return keyId
    }

    // MARK: - Assertion

    private func generateAssertion(keyId: String, method: String, path: String, body: Data) async throws -> Data {
        let clientDataHash = Self.clientDataHash(method: method, path: path, body: body)
        do {
            return try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
        } catch let err as NSError where err.domain == DCError.errorDomain && err.code == DCError.invalidKey.rawValue {
            throw err   // bubble up so caller can wipe + retry once
        } catch {
            throw AppAttestError.assertionFailed(error.localizedDescription)
        }
    }

    /// SHA-256 of "METHOD:PATH:sha256-hex(body)". Pure function, exposed
    /// internal-static so the Worker test harness can mirror it byte-for-byte.
    static func clientDataHash(method: String, path: String, body: Data) -> Data {
        let bodyHashHex = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let clientData = "\(method.uppercased()):\(path):\(bodyHashHex)"
        return Data(SHA256.hash(data: Data(clientData.utf8)))
    }

    // MARK: - Network: challenge + registration

    private func fetchChallenge() async throws -> Data {
        var req = URLRequest(url: backendURL.appendingPathComponent("attest/challenge"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw AppAttestError.challengeFetchFailed("HTTP \(status)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let challengeB64 = json["challenge"] as? String,
              let challenge = Data(base64Encoded: challengeB64) else {
            throw AppAttestError.challengeFetchFailed("Malformed response")
        }
        return challenge
    }

    private func postRegistration(keyId: String, attestation: Data, challenge: Data) async throws {
        var req = URLRequest(url: backendURL.appendingPathComponent("attest/register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "keyId": keyId,
            "attestation": attestation.base64EncodedString(),
            "challenge": challenge.base64EncodedString(),
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw AppAttestError.registrationRejected(-1, nil)
        }
        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8)
            throw AppAttestError.registrationRejected(http.statusCode, body)
        }
    }

    // MARK: - Keychain

    private func readCachedKeyId() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    private func writeCachedKeyId(_ keyId: String) throws {
        let data = Data(keyId.utf8)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        // Idempotent: delete-then-add. SecItemUpdate has finicky behavior
        // around partial attribute matches; replace-on-write avoids it.
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ] as CFDictionary)
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw AppAttestError.keychainWriteFailed(status) }
    }

    private func deleteCachedKeyId() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ] as CFDictionary)
    }
}
