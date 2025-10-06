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

    private let apiKey: String
    private let baseURL = "https://api.openai.com/v1/chat/completions"
    private let model = "gpt-4o" // GPT-4 with vision capabilities

    private init() {
        // Load API key from Config.plist
        if let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
           let config = NSDictionary(contentsOfFile: path),
           let key = config["OPENAI_API_KEY"] as? String, !key.isEmpty {
            self.apiKey = key
        } else {
            self.apiKey = ""
            print("⚠️ WARNING: OpenAI API key not found in Config.plist")
        }
    }

    /// Requests feedback from OpenAI by sending the drawing image and user context
    func requestFeedback(image: UIImage, context: DrawingContext) async throws -> String {
        guard !apiKey.isEmpty else {
            throw OpenAIError.missingAPIKey
        }

        // Convert image to base64
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw OpenAIError.imageEncodingFailed
        }
        let base64Image = imageData.base64EncodedString()

        // Build the prompt
        let prompt = buildPrompt(from: context)

        // Construct the API request
        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": prompt
                        ],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/jpeg;base64,\(base64Image)"
                            ]
                        ]
                    ]
                ]
            ],
            "max_tokens": 800
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw OpenAIError.invalidResponse
        }

        // Make the API call
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw OpenAIError.serverError(message)
            }
            throw OpenAIError.serverError("HTTP \(httpResponse.statusCode)")
        }

        // Parse the response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OpenAIError.invalidResponse
        }

        return content
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
