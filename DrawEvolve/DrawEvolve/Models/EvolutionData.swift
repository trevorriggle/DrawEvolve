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
    /// v3: every classified critique with its drawing's metadata +
    /// full severity tag set. Powers EvolutionStudioWallView and
    /// EvolutionSkillRadarView. Oldest-first (worker promises). The
    /// older `reel` and `themes` fields remain in the payload for
    /// back-compat but are no longer rendered in v3.
    let taggedCritiques: [TaggedCritique]
    let streak: StreakData
    let classifierVersion: String

    enum CodingKeys: String, CodingKey {
        case summary
        case digestSentence = "digest_sentence"
        case themes
        case highlight
        case reel
        case stats
        case taggedCritiques = "tagged_critiques"
        case streak
        case classifierVersion = "classifier_version"
    }

    // Explicit memberwise init — Swift's synthesized one is suppressed
    // because we provide a custom `init(from:)` below for lenient
    // decoding. Used by `EvolutionFeed.preview()` and any future
    // ad-hoc construction.
    init(summary: EvolutionSummary,
         digestSentence: String?,
         themes: [EvolutionTheme],
         highlight: EvolutionHighlight?,
         reel: [CritiqueReelRow],
         stats: EvolutionStats,
         taggedCritiques: [TaggedCritique],
         streak: StreakData,
         classifierVersion: String) {
        self.summary = summary
        self.digestSentence = digestSentence
        self.themes = themes
        self.highlight = highlight
        self.reel = reel
        self.stats = stats
        self.taggedCritiques = taggedCritiques
        self.streak = streak
        self.classifierVersion = classifierVersion
    }

    // Lenient decoder so older worker responses (pre-tagged_critiques)
    // still decode without crashing the panel.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary           = try container.decode(EvolutionSummary.self, forKey: .summary)
        digestSentence    = try container.decodeIfPresent(String.self, forKey: .digestSentence)
        themes            = (try? container.decodeIfPresent([EvolutionTheme].self,    forKey: .themes))           ?? []
        highlight         = try? container.decodeIfPresent(EvolutionHighlight.self,   forKey: .highlight)
        reel              = (try? container.decodeIfPresent([CritiqueReelRow].self,   forKey: .reel))             ?? []
        stats             = try container.decode(EvolutionStats.self, forKey: .stats)
        taggedCritiques   = (try? container.decodeIfPresent([TaggedCritique].self,    forKey: .taggedCritiques))  ?? []
        streak            = try container.decode(StreakData.self, forKey: .streak)
        classifierVersion = (try? container.decodeIfPresent(String.self, forKey: .classifierVersion)) ?? "unknown"
    }
}

// MARK: - Tagged critique (v3 Studio Wall + Skill Radar)

struct TaggedCritique: Codable, Identifiable, Hashable {
    let critiqueId: UUID?
    let drawingId: UUID
    let drawingTitle: String?
    let drawingSubject: String?
    let thumbnailPath: String?
    let createdAt: Date
    let contentExcerpt: String
    /// Full markdown-formatted critique body. Optional because older
    /// worker deploys don't include it. The detail sheet renders this
    /// when present, falling back to `contentExcerpt` otherwise.
    let content: String?
    let primaryCategory: CategoryID
    let secondaryCategories: [CategoryID]
    /// 1 (minor refinement) – 5 (needs significant work). Studio Wall
    /// renders dot brightness ∝ severity; Skill Radar maps severity to
    /// a signed positivity weight (sev 1 → +1.0, 5 → −1.0) and
    /// accumulates per category as net mastery evidence.
    let severity: Int
    /// Drawing version history pointer (phase 1). Non-nil once the
    /// worker promotes a pending snapshot bundle for this critique;
    /// nil for pre-VH legacy entries and for entries where promote
    /// failed (graceful degradation). The Studio Wall column and the
    /// detail sheet both prefer this over the live drawing thumbnail
    /// when present, so the user sees the drawing AT critique time.
    let snapshot: SnapshotPointer?

    var id: String {
        critiqueId?.uuidString ?? "\(drawingId.uuidString)-\(createdAt.timeIntervalSince1970)"
    }

    /// Every tag this critique carries — primary plus secondaries.
    /// Studio Wall renders one dot per entry.
    var allCategories: [CategoryID] {
        [primaryCategory] + secondaryCategories
    }

    enum CodingKeys: String, CodingKey {
        case critiqueId = "critique_id"
        case drawingId = "drawing_id"
        case drawingTitle = "drawing_title"
        case drawingSubject = "drawing_subject"
        case thumbnailPath = "thumbnail_path"
        case createdAt = "created_at"
        case contentExcerpt = "content_excerpt"
        case content
        case primaryCategory = "primary_category"
        case secondaryCategories = "secondary_categories"
        case severity
        case snapshot
    }

    init(
        critiqueId: UUID?,
        drawingId: UUID,
        drawingTitle: String?,
        drawingSubject: String?,
        thumbnailPath: String?,
        createdAt: Date,
        contentExcerpt: String,
        content: String?,
        primaryCategory: CategoryID,
        secondaryCategories: [CategoryID],
        severity: Int,
        snapshot: SnapshotPointer? = nil
    ) {
        self.critiqueId = critiqueId
        self.drawingId = drawingId
        self.drawingTitle = drawingTitle
        self.drawingSubject = drawingSubject
        self.thumbnailPath = thumbnailPath
        self.createdAt = createdAt
        self.contentExcerpt = contentExcerpt
        self.content = content
        self.primaryCategory = primaryCategory
        self.secondaryCategories = secondaryCategories
        self.severity = severity
        self.snapshot = snapshot
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
            taggedCritiques: previewTaggedCritiques,
            streak: StreakData(
                drawingsThisWeek: 3,
                drawingsThisMonth: 8,
                critiquesTotal: 24,
                drawingsTotal: 14
            ),
            classifierVersion: "preview"
        )
    }

    private static var previewTaggedCritiques: [TaggedCritique] {
        let now = Date()
        // 21 critiques across ~115 days, oldest-first. Designed to
        // exercise the Skill Radar's new accumulated-evidence math:
        //   - composition + value end strongly net-positive (visible fill)
        //   - anatomy mixed but net-positive (partial fill, recovering)
        //   - line emerging (small fill)
        //   - color net-NEGATIVE (collapses to center AND tints axis
        //     label red — verifies the regression warning renders)
        //   - perspective / subject_match / general untouched (neutral)
        //   - count ≥ 20 so `canCompare` triggers and the "Then"
        //     midpoint polygon draws inside a tighter, less-filled shape.
        func ts(_ daysAgo: Int) -> Date {
            Calendar.current.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        }
        let d1 = UUID(), d2 = UUID(), d3 = UUID(), d4 = UUID()
        let d5 = UUID(), d6 = UUID(), d7 = UUID(), d8 = UUID()
        return [
            // Early period — severity high, color & anatomy struggling.
            TaggedCritique(critiqueId: nil, drawingId: d1, drawingTitle: "Self-portrait 1",
                           drawingSubject: "portrait", thumbnailPath: nil, createdAt: ts(115),
                           contentExcerpt: "Anatomy reads heavy; eye placement and jaw are off.",
                           content: nil,
                           primaryCategory: .anatomy, secondaryCategories: [.color], severity: 4),
            TaggedCritique(critiqueId: nil, drawingId: d1, drawingTitle: "Self-portrait 1",
                           drawingSubject: "portrait", thumbnailPath: nil, createdAt: ts(110),
                           contentExcerpt: "Color choices clash and skin tones read muddy.",
                           content: nil,
                           primaryCategory: .color, secondaryCategories: [.anatomy], severity: 5),
            TaggedCritique(critiqueId: nil, drawingId: d1, drawingTitle: "Self-portrait 1",
                           drawingSubject: "portrait", thumbnailPath: nil, createdAt: ts(105),
                           contentExcerpt: "Proportion drift in the hands; line confidence low.",
                           content: nil,
                           primaryCategory: .anatomy, secondaryCategories: [.line], severity: 3),
            TaggedCritique(critiqueId: nil, drawingId: d2, drawingTitle: "Landscape sketch",
                           drawingSubject: "landscape", thumbnailPath: nil, createdAt: ts(95),
                           contentExcerpt: "Values compress in the midtones — sky needs more separation.",
                           content: nil,
                           primaryCategory: .value, secondaryCategories: [], severity: 3),
            TaggedCritique(critiqueId: nil, drawingId: d2, drawingTitle: "Landscape sketch",
                           drawingSubject: "landscape", thumbnailPath: nil, createdAt: ts(90),
                           contentExcerpt: "Color temperature shifts feel arbitrary; values fight color.",
                           content: nil,
                           primaryCategory: .color, secondaryCategories: [.value], severity: 4),
            // Mid period — composition starts landing, color still rough.
            TaggedCritique(critiqueId: nil, drawingId: d3, drawingTitle: "Still life A",
                           drawingSubject: "still life", thumbnailPath: nil, createdAt: ts(85),
                           contentExcerpt: "Composition reads but the focal point is ambiguous.",
                           content: nil,
                           primaryCategory: .composition, secondaryCategories: [], severity: 3),
            TaggedCritique(critiqueId: nil, drawingId: d3, drawingTitle: "Still life A",
                           drawingSubject: "still life", thumbnailPath: nil, createdAt: ts(75),
                           contentExcerpt: "Anatomy of the bottle handles is closer; only minor drift.",
                           content: nil,
                           primaryCategory: .anatomy, secondaryCategories: [.composition], severity: 2),
            TaggedCritique(critiqueId: nil, drawingId: d3, drawingTitle: "Still life A",
                           drawingSubject: "still life", thumbnailPath: nil, createdAt: ts(70),
                           contentExcerpt: "Values are tightening; midtone separation is improving.",
                           content: nil,
                           primaryCategory: .value, secondaryCategories: [.line], severity: 3),
            TaggedCritique(critiqueId: nil, drawingId: d4, drawingTitle: "Self-portrait 2",
                           drawingSubject: "portrait", thumbnailPath: nil, createdAt: ts(65),
                           contentExcerpt: "Line weight is more deliberate but still inconsistent.",
                           content: nil,
                           primaryCategory: .line, secondaryCategories: [], severity: 3),
            TaggedCritique(critiqueId: nil, drawingId: d4, drawingTitle: "Self-portrait 2",
                           drawingSubject: "portrait", thumbnailPath: nil, createdAt: ts(60),
                           contentExcerpt: "Composition framing is workable; value structure carries it.",
                           content: nil,
                           primaryCategory: .composition, secondaryCategories: [.value], severity: 3),
            TaggedCritique(critiqueId: nil, drawingId: d4, drawingTitle: "Self-portrait 2",
                           drawingSubject: "portrait", thumbnailPath: nil, createdAt: ts(50),
                           contentExcerpt: "Eye placement clean; proportion noticeably tighter.",
                           content: nil,
                           primaryCategory: .anatomy, secondaryCategories: [], severity: 2),
            // Late-mid period — recent strengths emerging.
            TaggedCritique(critiqueId: nil, drawingId: d5, drawingTitle: "Color study",
                           drawingSubject: "abstract", thumbnailPath: nil, createdAt: ts(45),
                           contentExcerpt: "Value separation is cleaner; only small midtone smoothing left.",
                           content: nil,
                           primaryCategory: .value, secondaryCategories: [.composition], severity: 2),
            TaggedCritique(critiqueId: nil, drawingId: d5, drawingTitle: "Color study",
                           drawingSubject: "abstract", thumbnailPath: nil, createdAt: ts(40),
                           contentExcerpt: "Composition reads cleanly — only minor focal-point refinement.",
                           content: nil,
                           primaryCategory: .composition, secondaryCategories: [.line], severity: 2),
            TaggedCritique(critiqueId: nil, drawingId: d5, drawingTitle: "Color study",
                           drawingSubject: "abstract", thumbnailPath: nil, createdAt: ts(35),
                           contentExcerpt: "Line confidence is up; small wobble in the long strokes.",
                           content: nil,
                           primaryCategory: .line, secondaryCategories: [], severity: 2),
            TaggedCritique(critiqueId: nil, drawingId: d6, drawingTitle: "Self-portrait 3",
                           drawingSubject: "portrait", thumbnailPath: nil, createdAt: ts(28),
                           contentExcerpt: "Anatomy is solid; only minor proportion polish remains.",
                           content: nil,
                           primaryCategory: .anatomy, secondaryCategories: [], severity: 1),
            TaggedCritique(critiqueId: nil, drawingId: d6, drawingTitle: "Self-portrait 3",
                           drawingSubject: "portrait", thumbnailPath: nil, createdAt: ts(22),
                           contentExcerpt: "Value range widened — strong darks, brighter highlights.",
                           content: nil,
                           primaryCategory: .value, secondaryCategories: [.composition], severity: 2),
            TaggedCritique(critiqueId: nil, drawingId: d7, drawingTitle: "Quick gesture",
                           drawingSubject: "figure", thumbnailPath: nil, createdAt: ts(18),
                           contentExcerpt: "Composition framing is decisive; balance reads at a glance.",
                           content: nil,
                           primaryCategory: .composition, secondaryCategories: [.value], severity: 1),
            TaggedCritique(critiqueId: nil, drawingId: d7, drawingTitle: "Quick gesture",
                           drawingSubject: "figure", thumbnailPath: nil, createdAt: ts(14),
                           contentExcerpt: "Value control is the standout — only the deepest darks need work.",
                           content: nil,
                           primaryCategory: .value, secondaryCategories: [], severity: 1),
            TaggedCritique(critiqueId: nil, drawingId: d8, drawingTitle: "Final piece",
                           drawingSubject: "portrait", thumbnailPath: nil, createdAt: ts(10),
                           contentExcerpt: "Composition is clean and unambiguous — focal hierarchy reads.",
                           content: nil,
                           primaryCategory: .composition, secondaryCategories: [], severity: 1),
            TaggedCritique(critiqueId: nil, drawingId: d8, drawingTitle: "Final piece",
                           drawingSubject: "portrait", thumbnailPath: nil, createdAt: ts(7),
                           contentExcerpt: "Line economy is excellent; small confidence wobble in long arcs.",
                           content: nil,
                           primaryCategory: .line, secondaryCategories: [.value], severity: 2),
            TaggedCritique(critiqueId: nil, drawingId: d8, drawingTitle: "Final piece",
                           drawingSubject: "portrait", thumbnailPath: nil, createdAt: ts(3),
                           contentExcerpt: "Value handling is the standout strength — minimal polish needed.",
                           content: nil,
                           primaryCategory: .value, secondaryCategories: [.composition], severity: 1),
        ]
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
