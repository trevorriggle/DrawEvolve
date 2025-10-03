import Foundation

enum AppConfig {
    // MARK: - Environment Variables & Flags

    /// Use mock/fake critique responses instead of real API calls
    static let useFakeCritique: Bool = {
        ProcessInfo.processInfo.environment["APP_USE_FAKE_CRITIQUE"] == "true"
    }()

    /// Base URL for the backend API
    static let apiBaseURL: String = {
        ProcessInfo.processInfo.environment["APP_API_BASE_URL"] ?? "https://api.drawevolve.com"
    }()

    // MARK: - App Constants

    static let appName = "DrawEvolve"
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    // MARK: - Feature Flags

    static let enablePhotoLibrarySave = true
    static let enableAdvancedDrawingTools = false

    // MARK: - Debug Info

    static func printConfiguration() {
        Logger.log("=== App Configuration ===")
        Logger.log("Version: \(version) (\(build))")
        Logger.log("API Base URL: \(apiBaseURL)")
        Logger.log("Use Fake Critique: \(useFakeCritique)")
        Logger.log("========================")
    }
}
