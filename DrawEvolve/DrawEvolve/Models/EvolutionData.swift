//
//  EvolutionData.swift
//  DrawEvolve
//
//  Codable types for GET /v1/me/evolution (v2 shape, Phase 1 of the
//  Evolution overhaul). Mirrors `buildEvolutionResponseV2` in
//  cloudflare-worker/routes/evolution.js.
//
//  Response shape:
//
//    {
//      "summary":  { drawings_this_month, critiques_this_month,
//                    top_subjects[], insights_last_updated_at },
//      "digest_sentence": string | null      (Phase 2: gpt-5.1-mini),
//      "themes": [ { category_id, status, synthesis, data_points } ],
//      "highlight": { ... } | null            (Phase 3: same-subject pair),
//      "reel": [ { critique_id, drawing_id, drawing_title,
//                  drawing_subject, thumbnail_path, created_at,
//                  excerpt_paraphrase, excerpt_raw, primary_category } ],
//      "stats": { total_critiques, most_discussed_category,
//                 most_improved_category, current_focus_area },
//      "streak": { ... }   (retained from v1 for compatibility),
//      "classifier_version": string
//    }
//
//  The v1 chart-based fields (categories, warming_up, summary_text,
//  state, example_artist_label, window) are GONE. iOS does not retain
//  fallback decoding for the old shape — the worker deploy and iOS
//  release ship paired.
//
//  CategoryID's `unknown(String)` fallback keeps future server-side
//  taxonomy bumps from failing the entire decode.
//

import Foundation

struct EvolutionFeed: Codable {
    let summary: EvolutionSummary
    let digestSentence: String?
    let themes: [EvolutionTheme]
    let highlight: EvolutionHighlight?
    let reel: [CritiqueReelRow]
    let stats: EvolutionStats
    let streak: StreakData
    let classifierVersion: String

    enum CodingKeys: String, CodingKey {
        case summary
        case digestSentence = "digest_sentence"
        case themes
        case highlight
        case reel
        case stats
        case streak
        case classifierVersion = "classifier_version"
    }
}

struct EvolutionSummary: Codable {
    let drawingsThisMonth: Int
    let critiquesThisMonth: Int
    let topSubjects: [String]
    let insightsLastUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case drawingsThisMonth = "drawings_this_month"
        case critiquesThisMonth = "critiques_this_month"
        case topSubjects = "top_subjects"
        case insightsLastUpdatedAt = "insights_last_updated_at"
    }
}

struct EvolutionTheme: Codable, Identifiable, Hashable {
    let categoryId: CategoryID
    let status: CategoryStatus?
    let synthesis: String
    let dataPoints: Int

    var id: CategoryID { categoryId }

    enum CodingKeys: String, CodingKey {
        case categoryId = "category_id"
        case status
        case synthesis
        case dataPoints = "data_points"
    }
}

struct EvolutionHighlight: Codable {
    let subject: String
    let earliest: HighlightEndpoint
    let latest: HighlightEndpoint
    let deltaSentence: String

    enum CodingKeys: String, CodingKey {
        case subject
        case earliest
        case latest
        case deltaSentence = "delta_sentence"
    }

    struct HighlightEndpoint: Codable {
        let drawingId: UUID
        let thumbnailPath: String
        let createdAt: Date

        enum CodingKeys: String, CodingKey {
            case drawingId = "drawing_id"
            case thumbnailPath = "thumbnail_path"
            case createdAt = "created_at"
        }
    }
}

struct CritiqueReelRow: Codable, Identifiable, Hashable {
    let critiqueId: UUID?
    let drawingId: UUID
    let drawingTitle: String?
    let drawingSubject: String?
    let thumbnailPath: String?
    let createdAt: Date
    let excerptParaphrase: String?
    let excerptRaw: String
    let primaryCategory: CategoryID?

    /// Identity = critique id when present, else drawing id + created_at
    /// fallback (pre-Phase-1 critiques don't carry an `id` in
    /// critique_history). Stable for SwiftUI list diffing.
    var id: String {
        if let cid = critiqueId { return cid.uuidString }
        return "\(drawingId.uuidString)-\(createdAt.timeIntervalSince1970)"
    }

    /// Excerpt to render. Prefers the LLM-paraphrased version when
    /// Phase 2 has populated it; falls back to the deterministic
    /// sentence pick from the worker. Always non-empty for rows that
    /// reach the UI (worker filters out rows with no content).
    var displayedExcerpt: String {
        if let p = excerptParaphrase, !p.isEmpty { return p }
        return excerptRaw
    }

    enum CodingKeys: String, CodingKey {
        case critiqueId = "critique_id"
        case drawingId = "drawing_id"
        case drawingTitle = "drawing_title"
        case drawingSubject = "drawing_subject"
        case thumbnailPath = "thumbnail_path"
        case createdAt = "created_at"
        case excerptParaphrase = "excerpt_paraphrase"
        case excerptRaw = "excerpt_raw"
        case primaryCategory = "primary_category"
    }
}

// MARK: - Preview payload

extension EvolutionFeed {
    /// Hardcoded illustrative feed for the empty-state "Show preview"
    /// toggle. The drawingIds in the reel are placeholder zero-UUIDs —
    /// CritiqueReelRowView's thumbnail loader will fail to find them
    /// in local cache and render the photo-icon placeholder, which is
    /// the right behaviour for a preview (the user hasn't drawn yet).
    static func preview() -> EvolutionFeed {
        EvolutionFeed(
            summary: EvolutionSummary(
                drawingsThisMonth: 8,
                critiquesThisMonth: 24,
                topSubjects: ["portraits", "landscapes", "still lifes"],
                insightsLastUpdatedAt: Calendar.current.date(byAdding: .hour, value: -4, to: Date())
            ),
            digestSentence: "Recent critiques highlight steadier value handling and stronger eye placement in your portraits.",
            themes: [
                EvolutionTheme(
                    categoryId: .anatomy,
                    status: .currentFocus,
                    synthesis: "Coach has flagged eye placement and hand proportion most often across your last 6 portraits.",
                    dataPoints: 6
                ),
                EvolutionTheme(
                    categoryId: .value,
                    status: .improving,
                    synthesis: "Your value separation has tightened — recent critiques mention cleaner darks and brighter highlights.",
                    dataPoints: 5
                ),
                EvolutionTheme(
                    categoryId: .composition,
                    status: .steady,
                    synthesis: "Composition reads as a consistent strength; recent feedback is mostly affirmations.",
                    dataPoints: 4
                ),
            ],
            highlight: nil,
            reel: previewReel,
            stats: EvolutionStats(
                totalCritiques: 24,
                mostDiscussedCategory: .anatomy,
                mostImprovedCategory: .value,
                currentFocusArea: "eye placement and proportion"
            ),
            streak: StreakData(
                drawingsThisWeek: 3,
                drawingsThisMonth: 8,
                critiquesTotal: 24,
                drawingsTotal: 14
            ),
            classifierVersion: "preview"
        )
    }

    private static var previewReel: [CritiqueReelRow] {
        let now = Date()
        return [
            CritiqueReelRow(
                critiqueId: nil,
                drawingId: UUID(),
                drawingTitle: "Tuesday portrait",
                drawingSubject: "portrait",
                thumbnailPath: nil,
                createdAt: Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now,
                excerptParaphrase: "Your eye placement is the most noticeable improvement here.",
                excerptRaw: "Your eye placement is the most noticeable improvement here.",
                primaryCategory: .anatomy
            ),
            CritiqueReelRow(
                critiqueId: nil,
                drawingId: UUID(),
                drawingTitle: "Garden study",
                drawingSubject: "landscape",
                thumbnailPath: nil,
                createdAt: Calendar.current.date(byAdding: .day, value: -3, to: now) ?? now,
                excerptParaphrase: "The value range is wider than last week's piece.",
                excerptRaw: "The value range is wider than last week's piece.",
                primaryCategory: .value
            ),
            CritiqueReelRow(
                critiqueId: nil,
                drawingId: UUID(),
                drawingTitle: nil,
                drawingSubject: "still life",
                thumbnailPath: nil,
                createdAt: Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now,
                excerptParaphrase: "Composition reads cleanly; the focal point is unambiguous.",
                excerptRaw: "Composition reads cleanly; the focal point is unambiguous.",
                primaryCategory: .composition
            ),
        ]
    }
}

struct EvolutionStats: Codable {
    let totalCritiques: Int
    let mostDiscussedCategory: CategoryID?
    let mostImprovedCategory: CategoryID?
    let currentFocusArea: String?

    enum CodingKeys: String, CodingKey {
        case totalCritiques = "total_critiques"
        case mostDiscussedCategory = "most_discussed_category"
        case mostImprovedCategory = "most_improved_category"
        case currentFocusArea = "current_focus_area"
    }
}

struct StreakData: Codable {
    let drawingsThisWeek: Int
    let drawingsThisMonth: Int
    let critiquesTotal: Int
    let drawingsTotal: Int

    enum CodingKeys: String, CodingKey {
        case drawingsThisWeek = "drawings_this_week"
        case drawingsThisMonth = "drawings_this_month"
        case critiquesTotal = "critiques_total"
        case drawingsTotal = "drawings_total"
    }
}

enum CategoryStatus: String, Codable {
    case improving
    case currentFocus = "current_focus"
    case steady
    case solidFoundation = "solid_foundation"
}

enum CategoryID: Codable, Hashable {
    case anatomy
    case composition
    case value
    case color
    case line
    case perspective
    case subjectMatch
    case general
    case unknown(String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CategoryID(rawValue: raw)
    }

    init(rawValue: String) {
        switch rawValue {
        case "anatomy":       self = .anatomy
        case "composition":   self = .composition
        case "value":         self = .value
        case "color":         self = .color
        case "line":          self = .line
        case "perspective":   self = .perspective
        case "subject_match": self = .subjectMatch
        case "general":       self = .general
        default:              self = .unknown(rawValue)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }

    /// Server-side taxonomy id (snake_case for `subject_match`).
    var stringValue: String {
        switch self {
        case .anatomy: return "anatomy"
        case .composition: return "composition"
        case .value: return "value"
        case .color: return "color"
        case .line: return "line"
        case .perspective: return "perspective"
        case .subjectMatch: return "subject_match"
        case .general: return "general"
        case .unknown(let raw): return raw
        }
    }

    /// Title-cased display form: "anatomy" → "Anatomy"; "subject_match" →
    /// "Subject match". Unknown ids are rendered the same way so a future
    /// taxonomy id ("lighting") still reads cleanly without an app update.
    var displayName: String {
        let words = stringValue.split(separator: "_")
        guard let first = words.first else { return stringValue }
        let rest = words.dropFirst().map(String.init).joined(separator: " ")
        let capFirst = first.prefix(1).uppercased() + first.dropFirst()
        return rest.isEmpty ? capFirst : "\(capFirst) \(rest)"
    }
}
