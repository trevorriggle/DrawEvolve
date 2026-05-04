//
//  DrawingContext.swift
//  DrawEvolve
//
//  Created by DrawEvolve Team
//

import Foundation

/// Holds the user's pre-drawing questionnaire responses
struct DrawingContext: Codable {
    var skillLevel: String = "Intermediate"
    var subject: String = ""
    var style: String = ""
    var artists: String = ""
    var techniques: String = ""
    var focus: String = ""
    var additionalContext: String = ""

    var isComplete: Bool {
        !subject.isEmpty && !style.isEmpty
    }

    init(
        skillLevel: String = "Intermediate",
        subject: String = "",
        style: String = "",
        artists: String = "",
        techniques: String = "",
        focus: String = "",
        additionalContext: String = ""
    ) {
        self.skillLevel = skillLevel
        self.subject = subject
        self.style = style
        self.artists = artists
        self.techniques = techniques
        self.focus = focus
        self.additionalContext = additionalContext
    }

    // Lenient decoder. Auto-synthesized Codable does NOT honor the property
    // default values above when a key is missing from the JSON — it throws
    // .keyNotFound instead. That broke fetchDrawings whenever a stored
    // jsonb context had been written by an older app version (or by any
    // codepath that persisted a partial object). Using decodeIfPresent +
    // explicit fallbacks here means any missing/null field gracefully
    // becomes its declared default and the whole drawing still loads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skillLevel        = try container.decodeIfPresent(String.self, forKey: .skillLevel)        ?? "Intermediate"
        subject           = try container.decodeIfPresent(String.self, forKey: .subject)           ?? ""
        style             = try container.decodeIfPresent(String.self, forKey: .style)             ?? ""
        artists           = try container.decodeIfPresent(String.self, forKey: .artists)           ?? ""
        techniques        = try container.decodeIfPresent(String.self, forKey: .techniques)        ?? ""
        focus             = try container.decodeIfPresent(String.self, forKey: .focus)             ?? ""
        additionalContext = try container.decodeIfPresent(String.self, forKey: .additionalContext) ?? ""
    }
}
