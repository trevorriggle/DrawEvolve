//
//  EvolutionData.swift
//  DrawEvolve
//
//  Codable types for GET /v1/me/evolution. Mirrors the contract emitted by
//  cloudflare-worker/routes/evolution.js (buildEvolutionResponseWithState):
//
//    {
//      "state": "example" | "early" | "growing" | "mature",
//      "window": { "critique_count", "earliest_at", "latest_at", "span_days" },
//      "streak": { "drawings_this_week", "drawings_this_month",
//                  "critiques_total", "drawings_total" },
//      "categories": [{ "id", "data_points", "current_value", "series", "status" }],
//      "warming_up": [{ "id", "data_points", "needed" }],
//      "summary_text":          string (early/growing only — key absent otherwise),
//      "example_artist_label":  string (example only — key absent otherwise),
//      "classifier_version":    string
//    }
//
//  The CategoryID enum has an `unknown(String)` fallback so a future server-
//  side taxonomy bump (e.g. adding "lighting") doesn't fail the entire decode
//  — the unknown id round-trips and the UI renders it via stringValue.
//

import Foundation

struct EvolutionData: Codable {
    let state: EvolutionState
    let window: WindowData
    let streak: StreakData
    let categories: [CategoryData]
    let warmingUp: [WarmingUpItem]
    let summaryText: String?
    let exampleArtistLabel: String?
    let classifierVersion: String

    enum CodingKeys: String, CodingKey {
        case state
        case window
        case streak
        case categories
        case warmingUp = "warming_up"
        case summaryText = "summary_text"
        case exampleArtistLabel = "example_artist_label"
        case classifierVersion = "classifier_version"
    }
}

enum EvolutionState: String, Codable {
    case example
    case early
    case growing
    case mature
}

struct WindowData: Codable {
    let critiqueCount: Int
    let earliestAt: Date?
    let latestAt: Date?
    let spanDays: Int

    enum CodingKeys: String, CodingKey {
        case critiqueCount = "critique_count"
        case earliestAt = "earliest_at"
        case latestAt = "latest_at"
        case spanDays = "span_days"
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

struct CategoryData: Codable, Identifiable, Hashable {
    let id: CategoryID
    let dataPoints: Int
    let currentValue: Double
    let series: [Double]
    let status: CategoryStatus

    enum CodingKeys: String, CodingKey {
        case id
        case dataPoints = "data_points"
        case currentValue = "current_value"
        case series
        case status
    }
}

struct WarmingUpItem: Codable, Identifiable, Hashable {
    let id: CategoryID
    let dataPoints: Int
    let needed: Int

    enum CodingKeys: String, CodingKey {
        case id
        case dataPoints = "data_points"
        case needed
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
