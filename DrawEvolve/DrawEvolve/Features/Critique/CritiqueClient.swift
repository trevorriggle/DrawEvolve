import Foundation
import UIKit

/// Client for submitting drawings and receiving AI critiques
/// Supports fake (stubbed) and real (network) modes via AppConfig
class CritiqueClient {
    static let shared = CritiqueClient()

    private let baseURL: String
    private let useFakeCritique: Bool
    private let timeout: TimeInterval = 10.0
    private let maxRetries = 1

    private init() {
        self.baseURL = AppConfig.apiBaseURL
        self.useFakeCritique = AppConfig.useFakeCritique
    }

    // MARK: - Public API

    /// Submit drawing for critique
    /// - Parameters:
    ///   - image: Drawing image (will be converted to PNG)
    ///   - context: User's learning context (subject, style, focus)
    /// - Returns: Two-phase critique response
    func requestCritique(
        image: UIImage,
        context: UserContext
    ) async throws -> CritiqueResponse {
        Logger.log("Requesting critique (fake: \(useFakeCritique))", log: .network)

        if useFakeCritique {
            return try await fakeCritique(context: context)
        }

        return try await realCritique(image: image, context: context)
    }

    // MARK: - Fake (Stubbed) Implementation

    /// Returns a realistic fake critique after short delay
    private func fakeCritique(context: UserContext) async throws -> CritiqueResponse {
        // Simulate network delay
        try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds

        // Generate context-aware fake response
        let visualAnalysis = """
        Strong composition with balanced proportions. Line weight varies appropriately, creating depth. \
        The overall structure shows good understanding of form. Suggestion: Extend the left shoulder 15% wider \
        for improved anatomical accuracy.
        """

        let coaching = """
        Great progress on your \(context.subject) drawing in \(context.style) style! Your focus on \
        \(context.focus) is showing clear results. Next step: Try applying more varied line pressure in \
        shadow areas to enhance dimensionality. Keep practicing!
        """

        return CritiqueResponse(
            visualAnalysis: visualAnalysis,
            personalizedCoaching: coaching
        )
    }

    // MARK: - Real (Network) Implementation

    /// Submits drawing to backend API with retry logic
    private func realCritique(image: UIImage, context: UserContext) async throws -> CritiqueResponse {
        // Convert image to PNG base64
        guard let pngData = image.pngData(),
              let base64String = pngData.base64EncodedString() as String? else {
            throw CritiqueError.invalidImage
        }

        let request = CritiqueRequest(
            imagePNGBase64: base64String,
            context: context
        )

        // Try with exponential backoff
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                let response = try await performRequest(request)
                Logger.log("Critique request succeeded on attempt \(attempt + 1)", log: .network)
                return response
            } catch {
                lastError = error
                if attempt < maxRetries {
                    let backoff = pow(2.0, Double(attempt)) // 1s, 2s, 4s...
                    Logger.log("Attempt \(attempt + 1) failed, retrying after \(backoff)s", log: .network)
                    try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                }
            }
        }

        throw lastError ?? CritiqueError.networkError("Unknown error")
    }

    /// Perform single HTTP request
    private func performRequest(_ request: CritiqueRequest) async throws -> CritiqueResponse {
        // Build URL
        guard let url = URL(string: "\(baseURL)/critique") else {
            throw CritiqueError.networkError("Invalid base URL")
        }

        // Configure request
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Encode body
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        urlRequest.httpBody = try encoder.encode(request)

        // Execute request
        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        // Validate response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CritiqueError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8)
            throw CritiqueError.serverError(httpResponse.statusCode, errorMessage)
        }

        // Decode response
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(CritiqueResponse.self, from: data)
        } catch {
            Logger.error("Failed to decode response: \(error)", log: .network)
            throw CritiqueError.invalidResponse
        }
    }
}
