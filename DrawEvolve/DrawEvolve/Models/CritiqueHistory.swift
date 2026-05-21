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

    // Phase 1 / 2.5 additions for the My Evolution feature. `tags` is
    // produced by the classifier post-critique and stored on the cloud row;
    // `presetId` records which voice preset was active for this critique.
    // Both decode-only on iOS — the Worker is the sole writer of
    // critique_history per CLAUDE.md, so we never PATCH these back.
    let tags: CritiqueTags?
    let presetId: String?

    // Drawing version history. Populated by the Worker when the snapshot
    // capture path promotes a pending bundle to snapshots/<sequence>/.
    // Nil for entries that pre-date the feature, and for entries where
    // promote failed (graceful degradation — see proposal §2.5).
    let snapshot: SnapshotPointer?

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
        completionTokenCount: Int? = nil,
        tags: CritiqueTags? = nil,
        presetId: String? = nil,
        snapshot: SnapshotPointer? = nil
    ) {
        self.id = id
        self.feedback = feedback
        self.timestamp = timestamp
        self.context = context
        self.sequenceNumber = sequenceNumber
        self.promptConfig = promptConfig
        self.promptTokenCount = promptTokenCount
        self.completionTokenCount = completionTokenCount
        self.tags = tags
        self.presetId = presetId
        self.snapshot = snapshot
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
        case tags
        case presetId = "preset_id"
        case snapshot
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
        self.tags = try container.decodeIfPresent(CritiqueTags.self, forKey: .tags)
        self.presetId = try container.decodeIfPresent(String.self, forKey: .presetId)
        self.snapshot = try container.decodeIfPresent(SnapshotPointer.self, forKey: .snapshot)
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
        try container.encodeIfPresent(tags, forKey: .tags)
        try container.encodeIfPresent(presetId, forKey: .presetId)
        try container.encodeIfPresent(snapshot, forKey: .snapshot)
    }
}

/// Pointer to a promoted snapshot bundle, written by the Worker into the
/// `snapshot` field of a CritiqueEntry. iOS reads this to (a) render a
/// thumbnail next to the critique row and (b) hydrate the time-machine
/// viewer when the row is tapped.
///
/// All paths are storage object keys under the `drawings` bucket, relative
/// to the bucket root. Use SupabaseManager's signed-URL helper to fetch.
struct SnapshotPointer: Codable, Equatable, Hashable {
    let manifestPath: String
    let compositePath: String
    let thumbPath: String
    let formatVersion: Int
    let layerCount: Int
    let totalBytes: Int64

    enum CodingKeys: String, CodingKey {
        case manifestPath  = "manifest_path"
        case compositePath = "composite_path"
        case thumbPath     = "thumb_path"
        case formatVersion = "format_version"
        case layerCount    = "layer_count"
        case totalBytes    = "total_bytes"
    }
}

/// Classifier-produced metadata, attached to each critique row by the
/// Worker (cloudflare-worker/lib/classifier.js). iOS reads only — the
/// Worker is the sole writer.
struct CritiqueTags: Codable, Equatable {
    let primaryCategory: CategoryID
    let secondaryCategories: [CategoryID]
    let severity: Int
    let focusAreaText: String?
    let subjectInferred: String?
    let acknowledgedProgress: Bool
    let classifierVersion: String

    enum CodingKeys: String, CodingKey {
        case primaryCategory = "primary_category"
        case secondaryCategories = "secondary_categories"
        case severity
        case focusAreaText = "focus_area_text"
        case subjectInferred = "subject_inferred"
        case acknowledgedProgress = "acknowledged_progress"
        case classifierVersion = "classifier_version"
    }
}
