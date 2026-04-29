//
//  CritiqueHistory.swift
//  DrawEvolve
//
//  Model representing a critique/feedback entry in the history.
//
//  Phase 5d note: the Worker is the sole writer to drawings.critique_history
//  in the cloud. Each entry decoded from the cloud arrives in the new shape
//  (`content`, `created_at`, `sequence_number`, `prompt_config`, token
//  counts). Old entries written by pre-Phase-5d iOS used `feedback` /
//  `timestamp`. The Codable below accepts BOTH on decode and writes only the
//  new shape on encode, so the local metadata cache rewrites stale entries
//  to the canonical form the next time they're hydrated.
//

import Foundation

struct CritiqueEntry: Codable, Identifiable {
    let id: UUID
    let feedback: String
    let timestamp: Date
    let context: DrawingContext?

    // Phase 5d additions — populated for entries written by the Worker. Old
    // entries (synthesized by iOS pre-Phase-5d) leave these nil.
    let sequenceNumber: Int?
    let promptConfig: PromptConfigSnapshot?
    let promptTokenCount: Int?
    let completionTokenCount: Int?

    struct PromptConfigSnapshot: Codable, Equatable {
        let tier: String
        let includeHistoryCount: Int
        let styleModifier: String?
    }

    init(
        id: UUID = UUID(),
        feedback: String,
        timestamp: Date = Date(),
        context: DrawingContext? = nil,
        sequenceNumber: Int? = nil,
        promptConfig: PromptConfigSnapshot? = nil,
        promptTokenCount: Int? = nil,
        completionTokenCount: Int? = nil
    ) {
        self.id = id
        self.feedback = feedback
        self.timestamp = timestamp
        self.context = context
        self.sequenceNumber = sequenceNumber
        self.promptConfig = promptConfig
        self.promptTokenCount = promptTokenCount
        self.completionTokenCount = completionTokenCount
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case feedback                                  // legacy iOS-only key
        case content                                   // Phase 5d server key
        case timestamp                                 // legacy iOS-only key
        case createdAt = "created_at"                  // Phase 5d server key
        case context
        case sequenceNumber = "sequence_number"
        case promptConfig = "prompt_config"
        case promptTokenCount = "prompt_token_count"
        case completionTokenCount = "completion_token_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // id: legacy entries had a UUID; server entries don't. Generate one
        // for server entries so Identifiable conformance keeps working.
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()

        // Prefer the new key, fall back to the legacy one.
        if let content = try container.decodeIfPresent(String.self, forKey: .content) {
            self.feedback = content
        } else {
            self.feedback = try container.decode(String.self, forKey: .feedback)
        }

        if let createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) {
            self.timestamp = createdAt
        } else {
            self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        }

        self.context = try container.decodeIfPresent(DrawingContext.self, forKey: .context)
        self.sequenceNumber = try container.decodeIfPresent(Int.self, forKey: .sequenceNumber)
        self.promptConfig = try container.decodeIfPresent(PromptConfigSnapshot.self, forKey: .promptConfig)
        self.promptTokenCount = try container.decodeIfPresent(Int.self, forKey: .promptTokenCount)
        self.completionTokenCount = try container.decodeIfPresent(Int.self, forKey: .completionTokenCount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        // Write only the canonical Phase 5d key names — old key names are
        // accepted on decode for back-compat but are not re-emitted.
        try container.encode(feedback, forKey: .content)
        try container.encode(timestamp, forKey: .createdAt)
        try container.encodeIfPresent(context, forKey: .context)
        try container.encodeIfPresent(sequenceNumber, forKey: .sequenceNumber)
        try container.encodeIfPresent(promptConfig, forKey: .promptConfig)
        try container.encodeIfPresent(promptTokenCount, forKey: .promptTokenCount)
        try container.encodeIfPresent(completionTokenCount, forKey: .completionTokenCount)
    }
}
