//
//  Drawing.swift
//  DrawEvolve
//
//  Model representing a saved drawing.
//

import Foundation

struct Drawing: Codable, Identifiable {
    let id: UUID
    let userId: UUID
    var title: String
    var imageData: Data
    let createdAt: Date
    var updatedAt: Date
    var feedback: String? // Most recent feedback
    var context: DrawingContext?
    var critiqueHistory: [CritiqueEntry] // All critique history

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
        case imageData = "image_data"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case feedback
        case context
        case critiqueHistory = "critique_history"
    }

    // Codable conformance
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        userId = try container.decode(UUID.self, forKey: .userId)
        title = try container.decode(String.self, forKey: .title)
        imageData = try container.decode(Data.self, forKey: .imageData)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        feedback = try container.decodeIfPresent(String.self, forKey: .feedback)
        context = try container.decodeIfPresent(DrawingContext.self, forKey: .context)
        // Default to empty array if critiqueHistory is missing (for backward compatibility)
        critiqueHistory = try container.decodeIfPresent([CritiqueEntry].self, forKey: .critiqueHistory) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(userId, forKey: .userId)
        try container.encode(title, forKey: .title)
        try container.encode(imageData, forKey: .imageData)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(feedback, forKey: .feedback)
        try container.encodeIfPresent(context, forKey: .context)
        try container.encode(critiqueHistory, forKey: .critiqueHistory)
    }

    // Custom initializer with default empty critique history
    init(id: UUID, userId: UUID, title: String, imageData: Data, createdAt: Date, updatedAt: Date, feedback: String? = nil, context: DrawingContext? = nil, critiqueHistory: [CritiqueEntry] = []) {
        self.id = id
        self.userId = userId
        self.title = title
        self.imageData = imageData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.feedback = feedback
        self.context = context
        self.critiqueHistory = critiqueHistory
    }
}
