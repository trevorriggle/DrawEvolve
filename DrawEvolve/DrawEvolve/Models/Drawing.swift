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
    let title: String
    let imageData: Data
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
        case imageData = "image_data"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
