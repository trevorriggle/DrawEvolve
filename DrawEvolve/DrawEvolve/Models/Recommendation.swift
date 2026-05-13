//
//  Recommendation.swift
//  DrawEvolve
//
//  Phase 4 — Subject Recommendations. Wire shape mirrors the worker's
//  RECOMMENDATIONS_SCHEMA in cloudflare-worker/lib/recommendations-
//  validation.js. When the schema changes there, mirror it here AND
//  bump any UI that depends on the enum (RecommendationCard).
//

import Foundation

// =============================================================================
// RecommendationType
// =============================================================================
//
// Three values, matching the worker enum. Decoded lossy from the
// server: an unknown value (e.g. a future server-side addition) falls
// back to .unknown so the iOS app degrades gracefully instead of
// blowing up the whole recommendations list.

enum RecommendationType: String, Codable, Sendable {
    case skillTargeting = "skill_targeting"
    case variety
    case stretch
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = RecommendationType(rawValue: raw) ?? .unknown
    }

    /// Short human-readable label for the UI badge / chip.
    var displayLabel: String {
        switch self {
        case .skillTargeting: return "Target"
        case .variety:        return "Variety"
        case .stretch:        return "Stretch"
        case .unknown:        return ""
        }
    }
}

// =============================================================================
// Recommendation
// =============================================================================

struct Recommendation: Identifiable, Codable, Equatable, Sendable {
    /// Synthetic stable id for SwiftUI ForEach. Not from the server — the
    /// server doesn't persist recommendations (ephemeral per request),
    /// so iOS generates a UUID at decode time.
    let id: UUID
    let subject: String
    let rationale: String
    let focusArea: String
    let recommendationType: RecommendationType

    enum CodingKeys: String, CodingKey {
        case subject
        case rationale
        case focusArea = "focus_area"
        case recommendationType = "recommendation_type"
    }

    init(
        id: UUID = UUID(),
        subject: String,
        rationale: String,
        focusArea: String,
        recommendationType: RecommendationType,
    ) {
        self.id = id
        self.subject = subject
        self.rationale = rationale
        self.focusArea = focusArea
        self.recommendationType = recommendationType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.subject = try container.decode(String.self, forKey: .subject)
        self.rationale = try container.decode(String.self, forKey: .rationale)
        self.focusArea = try container.decodeIfPresent(String.self, forKey: .focusArea) ?? ""
        self.recommendationType = try container.decode(RecommendationType.self, forKey: .recommendationType)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(subject, forKey: .subject)
        try container.encode(rationale, forKey: .rationale)
        try container.encode(focusArea, forKey: .focusArea)
        try container.encode(recommendationType, forKey: .recommendationType)
    }
}

// =============================================================================
// RecommendationsResponse
// =============================================================================
//
// Top-level wire shape. `context_summary` is a small telemetry block
// the worker includes so iOS can know whether the recommendations were
// generated from a real portfolio or the empty-portfolio fundamentals
// path — useful for empty-state copy later.

struct RecommendationsResponse: Decodable, Sendable {
    let recommendations: [Recommendation]
    let contextSummary: ContextSummary?

    enum CodingKeys: String, CodingKey {
        case recommendations
        case contextSummary = "context_summary"
    }

    struct ContextSummary: Decodable, Sendable {
        let drawingCount: Int
        let summaryCount: Int

        enum CodingKeys: String, CodingKey {
            case drawingCount = "drawing_count"
            case summaryCount = "summary_count"
        }
    }
}
