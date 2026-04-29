//
//  Drawing.swift
//  DrawEvolve
//
//  Phase 3 (cloud sync): image bytes no longer live on the model. The
//  cloud-truth row carries `storagePath` (`<user_id>/<id>.jpg`); the
//  pixels themselves live in Supabase Storage and the local disk cache.
//  Views fetch image bytes via CloudDrawingStorageManager (thumbnail
//  accessor for gallery cells, async loadFullImage for the detail/canvas
//  views).
//
//  Codable is used both for the local metadata cache (Documents/
//  DrawEvolveCache/metadata/<id>.json) and for PostgREST round-trips
//  with the `drawings` table — column names and field names line up via
//  CodingKeys.
//

import Foundation

struct Drawing: Codable, Identifiable {
    let id: UUID
    let userId: UUID
    var title: String
    var storagePath: String        // "<user_id>/<id>.jpg" — Supabase Storage key
    let createdAt: Date
    var updatedAt: Date
    var feedback: String?          // Most recent feedback summary
    var context: DrawingContext?
    var critiqueHistory: [CritiqueEntry]

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
        case storagePath = "storage_path"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case feedback
        case context
        case critiqueHistory = "critique_history"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        userId = try container.decode(UUID.self, forKey: .userId)
        title = try container.decode(String.self, forKey: .title)
        storagePath = try container.decode(String.self, forKey: .storagePath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        feedback = try container.decodeIfPresent(String.self, forKey: .feedback)
        context = try container.decodeIfPresent(DrawingContext.self, forKey: .context)
        critiqueHistory = try container.decodeIfPresent([CritiqueEntry].self, forKey: .critiqueHistory) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(userId, forKey: .userId)
        try container.encode(title, forKey: .title)
        try container.encode(storagePath, forKey: .storagePath)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(feedback, forKey: .feedback)
        try container.encodeIfPresent(context, forKey: .context)
        try container.encode(critiqueHistory, forKey: .critiqueHistory)
    }

    init(
        id: UUID,
        userId: UUID,
        title: String,
        storagePath: String,
        createdAt: Date,
        updatedAt: Date,
        feedback: String? = nil,
        context: DrawingContext? = nil,
        critiqueHistory: [CritiqueEntry] = []
    ) {
        self.id = id
        self.userId = userId
        self.title = title
        self.storagePath = storagePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.feedback = feedback
        self.context = context
        self.critiqueHistory = critiqueHistory
    }
}
