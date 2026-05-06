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

import Foundation
import UIKit

struct TextSettings {
    enum Alignment: String, CaseIterable {
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

// MARK: - Persistence
//
// JSON-encoded via a small flat struct so UIColor and the kerning enum can
// round-trip. Keep the storage key versioned — bumping schema requires
// invalidating older payloads (decode failures fall through to .default).

private struct TextSettingsCodable: Codable {
    let fontFamily: String
    let fontFace: String
    let size: CGFloat
    let r: CGFloat
    let g: CGFloat
    let b: CGFloat
    let a: CGFloat
    let alignment: String
    let leading: CGFloat
    let tracking: CGFloat
    let kerningKind: String
    let kerningValue: CGFloat
    let italic: Bool

    init(_ s: TextSettings) {
        fontFamily = s.fontFamily
        fontFace = s.fontFace
        size = s.size
        var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 1
        s.color.getRed(&rr, green: &gg, blue: &bb, alpha: &aa)
        r = rr; g = gg; b = bb; a = aa
        alignment = s.alignment.rawValue
        leading = s.leading
        tracking = s.tracking
        switch s.kerning {
        case .auto:           kerningKind = "auto";   kerningValue = 0
        case .none:           kerningKind = "none";   kerningValue = 0
        case .manual(let v):  kerningKind = "manual"; kerningValue = v
        }
        italic = s.italic
    }

    func unwrap() -> TextSettings {
        let kerning: TextSettings.Kerning
        switch kerningKind {
        case "manual": kerning = .manual(kerningValue)
        case "none":   kerning = .none
        default:       kerning = .auto
        }
        return TextSettings(
            fontFamily: fontFamily,
            fontFace: fontFace,
            size: size,
            color: UIColor(red: r, green: g, blue: b, alpha: a),
            alignment: TextSettings.Alignment(rawValue: alignment) ?? .leading,
            leading: leading,
            tracking: tracking,
            kerning: kerning,
            italic: italic
        )
    }
}

extension TextSettings {
    static let storageKey = "DrawEvolve.TextSettings.v1"

    static func loadPersisted() -> TextSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let coded = try? JSONDecoder().decode(TextSettingsCodable.self, from: data) else {
            return .default
        }
        return coded.unwrap()
    }

    func savePersisted() {
        guard let data = try? JSONEncoder().encode(TextSettingsCodable(self)) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
