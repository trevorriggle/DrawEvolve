//
//  CustomPrompt.swift
//  DrawEvolve
//
//  User-authored custom prompt (bounded-knobs only). The product surface is
//  intentionally restricted to enum knobs — there is no freeform "write your
//  own system prompt" editor. Each knob value maps to a curated server-side
//  fragment in cloudflare-worker/lib/prompt.js. See CUSTOMPROMPTSPLAN.md §2.3
//  for the security rationale (freeform text would re-introduce the
//  styleModifier prompt-injection footgun).
//
//  Wire format mirrors the Worker's response from /v1/prompts/me and
//  /v1/prompts/:id. The case lists in PromptParameters.* enums MUST match
//  FOCUS_OPTIONS / TONE_OPTIONS / DEPTH_OPTIONS / TECHNIQUE_OPTIONS in
//  cloudflare-worker/lib/prompt.js exactly — sending a value the Worker
//  doesn't recognize causes it to silently drop the knob (forward-compat is
//  intentional, but the user's intent gets lost).
//

import Foundation

// MARK: - Bounded knob enums

enum PromptFocus: String, Codable, CaseIterable, Identifiable {
    case anatomy
    case composition
    case color
    case lighting
    case lineWork = "line_work"
    case value
    case perspective
    case general

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anatomy:     return "Anatomy"
        case .composition: return "Composition"
        case .color:       return "Color"
        case .lighting:    return "Lighting"
        case .lineWork:    return "Line work"
        case .value:       return "Value / contrast"
        case .perspective: return "Perspective"
        case .general:     return "General (no bias)"
        }
    }
}

enum PromptTone: String, Codable, CaseIterable, Identifiable {
    case encouraging, balanced, rigorous, blunt
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

enum PromptDepth: String, Codable, CaseIterable, Identifiable {
    case brief, standard
    case deepDive = "deep_dive"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .brief:    return "Brief (~250 words)"
        case .standard: return "Standard (~700 words)"
        case .deepDive: return "Deep dive (~1100 words)"
        }
    }
}

enum PromptTechnique: String, Codable, CaseIterable, Identifiable {
    case digital, traditional, observational, gestural, studied, imagination
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .digital:       return "Digital"
        case .traditional:   return "Traditional media"
        case .observational: return "Observational"
        case .gestural:      return "Gestural / quick studies"
        case .studied:       return "Long careful studies"
        case .imagination:   return "Imaginative / construction"
        }
    }
}

// MARK: - Parameters payload

/// JSON shape stored in custom_prompts.parameters. All fields optional —
/// missing means "no bias from this knob, use the base voice as-is."
struct PromptParameters: Codable, Equatable {
    var focus: PromptFocus?
    var tone: PromptTone?
    var depth: PromptDepth?
    var techniques: [PromptTechnique]?

    init(focus: PromptFocus? = nil,
         tone: PromptTone? = nil,
         depth: PromptDepth? = nil,
         techniques: [PromptTechnique]? = nil) {
        self.focus = focus
        self.tone = tone
        self.depth = depth
        self.techniques = techniques
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Lenient decoding: an unknown raw value (e.g. a future enum case
        // shipped in a newer Worker) decodes as nil rather than throwing.
        // This mirrors the Worker's validate-and-narrow posture so old
        // clients never fail to render newer rows.
        focus      = (try? container.decodeIfPresent(PromptFocus.self,        forKey: .focus))      ?? nil
        tone       = (try? container.decodeIfPresent(PromptTone.self,         forKey: .tone))       ?? nil
        depth      = (try? container.decodeIfPresent(PromptDepth.self,        forKey: .depth))      ?? nil
        techniques = (try? container.decodeIfPresent([PromptTechnique].self,  forKey: .techniques)) ?? nil
    }

    var isEmpty: Bool {
        focus == nil && tone == nil && depth == nil && (techniques?.isEmpty ?? true)
    }
}

// MARK: - CustomPrompt row

struct CustomPrompt: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var parameters: PromptParameters
    let templateVersion: Int
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case parameters
        case templateVersion = "template_version"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
