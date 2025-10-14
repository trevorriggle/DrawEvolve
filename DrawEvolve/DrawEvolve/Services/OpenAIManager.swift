//
//  OpenAIManager.swift
//  DrawEvolve
//
//  Handles all OpenAI API interactions for image analysis and feedback generation.
//

import Foundation
import UIKit

enum OpenAIError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case serverError(String)
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key is missing. Please add it to your Config.plist."
        case .invalidResponse:
            return "Received an invalid response from OpenAI."
        case .serverError(let message):
            return "Server error: \(message)"
        case .imageEncodingFailed:
            return "Failed to encode the image for upload."
        }
    }
}

actor OpenAIManager {
    static let shared = OpenAIManager()

    // Cloudflare Worker backend URL
    private let backendURL = "https://drawevolve-backend.trevorriggle.workers.dev"

    // For local testing with Vercel Dev, use:
    // private let backendURL = "http://localhost:3000/api/feedback"

    private init() {
        print("✅ OpenAIManager using secure backend proxy at: \(backendURL)")
    }

    /// Requests feedback via our secure backend proxy
    func requestFeedback(image: UIImage, context: DrawingContext) async throws -> String {
        // Convert image to base64
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            let error = OpenAIError.imageEncodingFailed
            CrashReporter.shared.logError(error, context: "OpenAIManager.requestFeedback - Image encoding failed")
            throw error
        }
        let base64Image = imageData.base64EncodedString()

        // Send to OUR backend (not OpenAI directly)
        let requestBody: [String: Any] = [
            "image": base64Image,
            "context": [
                "subject": context.subject,
                "style": context.style,
                "artists": context.artists,
                "techniques": context.techniques,
                "focus": context.focus,
                "additionalContext": context.additionalContext
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody),
              let url = URL(string: backendURL) else {
            throw OpenAIError.invalidResponse
        }

        // Call our backend
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMessage = errorJson["error"] as? String {
                let error = OpenAIError.serverError(errorMessage)
                CrashReporter.shared.logError(error, context: "OpenAIManager.requestFeedback - Server error: \(errorMessage)")
                throw error
            }
            let error = OpenAIError.serverError("HTTP \(httpResponse.statusCode)")
            CrashReporter.shared.logError(error, context: "OpenAIManager.requestFeedback - HTTP \(httpResponse.statusCode)")
            throw error
        }

        // Parse backend response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feedback = json["feedback"] as? String else {
            let error = OpenAIError.invalidResponse
            CrashReporter.shared.logError(error, context: "OpenAIManager.requestFeedback - Invalid response format")
            throw error
        }

        return feedback
    }

    /// Builds the feedback prompt from the user's context
    private func buildPrompt(from context: DrawingContext) -> String {
        var prompt = "You are the DrawEvolve AI coach, a friendly drawing mentor.\n"
        prompt += "Today, the user is drawing \(context.subject). "
        prompt += "They're attempting the \(context.style) style. "

        if !context.artists.isEmpty {
            prompt += "They are inspired by \(context.artists). "
        }

        if !context.techniques.isEmpty {
            prompt += "They will be using \(context.techniques). "
        }

        if !context.focus.isEmpty {
            prompt += "They want feedback on \(context.focus). "
        }

        if !context.additionalContext.isEmpty {
            prompt += "The user also wants you to understand: \(context.additionalContext). "
        }

        prompt += """
        \n
        Provide detailed feedback that helps them improve their artistic skills.
        Be encouraging, precise, and specific. Never condescending.
        Slip in one small, friendly joke, never at the user's expense.
        """

        return prompt
    }
}
