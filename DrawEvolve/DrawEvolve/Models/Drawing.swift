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
