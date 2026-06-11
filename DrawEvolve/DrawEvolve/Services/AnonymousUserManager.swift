//
//  AnonymousUserManager.swift
//  DrawEvolve
//
//  Manages anonymous user identification for usage tracking.
//

import Foundation

class AnonymousUserManager {
    static let shared = AnonymousUserManager()

    private let userIDKey = "anonymousUserID"

    private init() {}

    /// Get or create anonymous user ID
    var userID: String {
        if let existingID = UserDefaults.standard.string(forKey: userIDKey) {
            return existingID
        }

        // Generate new UUID
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: userIDKey)
        #if DEBUG
        // DEBUG-only: a device-tracking identifier doesn't belong in the
        // release syslog (readable via sysdiagnose / console capture).
        print("✅ Generated new anonymous user ID: \(newID)")
        #endif
        return newID
    }

    /// Check if user has been initialized
    var isInitialized: Bool {
        return UserDefaults.standard.string(forKey: userIDKey) != nil
    }
}
