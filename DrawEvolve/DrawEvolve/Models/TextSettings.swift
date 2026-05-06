//
//  TextSettings.swift
//  DrawEvolve
//
//  Per-text typographic settings. Persisted globally across app launches via
//  UserDefaults — same model brushes use, conceptually a "default text" that
//  the active FloatingText is initialised from. Editing the sheet while a
//  FloatingText is active updates BOTH the global default and the active
//  text's settings (single source of truth, see CanvasStateManager).
//
//  Codable conformance is wired up here even though v1 only persists the
//  global default to UserDefaults — v1.1 vector text layers will need to
//  serialise per-document FloatingText payloads, and getting the wire
//  format right (CodableColor wrapper for UIColor, tagged Kerning enum)
//  costs nothing now. Don't add a new serialiser; just use the conformance.
//

import Foundation
import UIKit

struct TextSettings {
    enum Alignment: String, Codable, CaseIterable {
        case leading
        case center
        case trailing

        var nsTextAlignment: NSTextAlignment {
            switch self {
            case .leading:  return .left
            case .center:   return .center
            case .trailing: return .right
            }
        }
    }

    /// Kerning ("letter-pair" spacing).
    /// - .auto: no `.kern` attribute set, Core Text applies the font's native
    ///   kern table.
    /// - .none: explicit zero kern, no native pair adjustment.
    /// - .manual(value): explicit doc-space points added to every glyph pair.
    ///
    /// Codable conformance lives in an extension (associated values can't
    /// auto-synthesise — see KerningCoding below).
    enum Kerning: Equatable {
        case auto
        case none
        case manual(CGFloat)
    }

    /// Family name as listed in `UIFont.familyNames`.
    var fontFamily: String
    /// PostScript face name as listed in `UIFont.fontNames(forFamilyName:)`.
    /// Used as the primary lookup; family is the fallback.
    var fontFace: String
    /// Doc-space point size. Sliders run 1...500.
    var size: CGFloat
    /// Drawing color. Independent from BrushSettings.color (locked decision).
    /// On the wire this round-trips through CodableColor (RGBA) so we don't
    /// depend on UIColor's NSCoding.
    var color: UIColor
    var alignment: Alignment
    /// Doc-space leading (extra inter-line spacing). Sliders run -20...80.
    var leading: CGFloat
    /// Doc-space tracking (uniform spacing applied to every glyph). -10...50.
    var tracking: CGFloat
    var kerning: Kerning
    /// True → request italic via UIFontDescriptor symbolic traits, falling
    /// back to a 12° shear when the font has no italic variant.
    var italic: Bool

    static let `default` = TextSettings(
        fontFamily: "Helvetica Neue",
        fontFace: "HelveticaNeue",
        size: 32,
        color: .black,
        alignment: .leading,
        leading: 0,
        tracking: 0,
        kerning: .auto,
        italic: false
    )
}

// MARK: - Codable conformance
//
// Hand-written rather than synthesised because UIColor isn't Codable and
// Kerning has associated values. Both surfaces live in extensions so the
// memberwise initialiser the rest of the codebase relies on stays
// synthesised.

extension TextSettings.Kerning: Codable {
    private enum Tag: String, Codable {
        case auto, none, manual
    }
    private enum CodingKeys: String, CodingKey {
        case tag, value
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto:
            try c.encode(Tag.auto, forKey: .tag)
        case .none:
            try c.encode(Tag.none, forKey: .tag)
        case .manual(let v):
            try c.encode(Tag.manual, forKey: .tag)
            try c.encode(v, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .tag) {
        case .auto:   self = .auto
        case .none:   self = .none
        case .manual: self = .manual(try c.decode(CGFloat.self, forKey: .value))
        }
    }
}

extension TextSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case fontFamily, fontFace, size, color, alignment, leading, tracking, kerning, italic
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fontFamily, forKey: .fontFamily)
        try c.encode(fontFace, forKey: .fontFace)
        try c.encode(size, forKey: .size)
        try c.encode(CodableColor(color), forKey: .color)
        try c.encode(alignment, forKey: .alignment)
        try c.encode(leading, forKey: .leading)
        try c.encode(tracking, forKey: .tracking)
        try c.encode(kerning, forKey: .kerning)
        try c.encode(italic, forKey: .italic)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            fontFamily: try c.decode(String.self, forKey: .fontFamily),
            fontFace:   try c.decode(String.self, forKey: .fontFace),
            size:       try c.decode(CGFloat.self, forKey: .size),
            color:      try c.decode(CodableColor.self, forKey: .color).uiColor,
            alignment:  try c.decode(Alignment.self, forKey: .alignment),
            leading:    try c.decode(CGFloat.self, forKey: .leading),
            tracking:   try c.decode(CGFloat.self, forKey: .tracking),
            kerning:    try c.decode(Kerning.self, forKey: .kerning),
            italic:     try c.decode(Bool.self, forKey: .italic)
        )
    }
}

// MARK: - Persistence

extension TextSettings {
    static let storageKey = "DrawEvolve.TextSettings.v1"

    static func loadPersisted() -> TextSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(TextSettings.self, from: data) else {
            return .default
        }
        return decoded
    }

    func savePersisted() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
