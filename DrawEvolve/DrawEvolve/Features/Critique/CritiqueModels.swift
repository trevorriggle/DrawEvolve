import Foundation

// MARK: - Request Models

/// Request payload for critique API
struct CritiqueRequest: Codable {
    /// PNG image data encoded as base64 string
    let imagePNGBase64: String

    /// User's learning context
    let context: UserContextRequest

    enum CodingKeys: String, CodingKey {
        case imagePNGBase64 = "image_png_base64"
        case context
    }
}

/// User context embedded in critique request
struct UserContextRequest: Codable {
    let subject: String
    let style: String
    let focus: String
}

/// Backwards compatibility alias
typealias UserContext = UserContextRequest

// MARK: - Response Models

/// Response from critique API - two-phase analysis
struct CritiqueResponse: Codable {
    /// Phase 1: Objective visual analysis (measurement-driven)
    let visualAnalysis: String

    /// Phase 2: Personalized coaching (context-aware)
    let personalizedCoaching: String

    enum CodingKeys: String, CodingKey {
        case visualAnalysis = "visual_analysis"
        case personalizedCoaching = "personalized_coaching"
    }
}

// MARK: - Error Handling

/// Structured errors for critique pipeline
enum CritiqueError: Error, LocalizedError {
    case networkError(String)
    case invalidResponse
    case serverError(Int, String?)
    case timeout
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .networkError(let message):
            return "Network error: \(message)"
        case .invalidResponse:
            return "Invalid response from server"
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message ?? "Unknown error")"
        case .timeout:
            return "Request timed out. Please try again."
        case .invalidImage:
            return "Could not process drawing image"
        }
    }
}
