//
//  Palette.swift
//  DrawEvolve
//
//  Phase 3 — Color System Overhaul. Palette = a named group of user-
//  curated colors. Stored cloud-side in public.user_palettes (migration
//  0013) and locally in PaletteManager's cache (UserDefaults-backed).
//
//  Wire shape mirrors the worker — hex strings on the wire, CodableColor
//  internally for the in-memory UIColor interop. The model carries a
//  deletedAt marker that the iOS client uses to optimistically hide a
//  palette while the server confirms the soft-delete (or to revert if
//  the server rejects). Server-side, deletedAt is the canonical state.
//

import Foundation
import UIKit

struct Palette: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var colors: [CodableColor]
    let createdAt: Date
    var updatedAt: Date
    var deletedAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case colors
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    init(
        id: UUID = UUID(),
        name: String,
        colors: [CodableColor],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
    ) {
        self.id = id
        self.name = name
        self.colors = colors
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    // The worker sends colors as a JSONB array of 6-digit hex strings
    // (`["#ff8844", "#33aa66"]`). iOS converts each to a CodableColor at
    // decode time. The encode path goes the other direction.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        let hexStrings = try c.decodeIfPresent([String].self, forKey: .colors) ?? []
        self.colors = hexStrings.compactMap { Palette.colorFromHex($0) }
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(colors.map(Palette.hexFromColor), forKey: .colors)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }

    // MARK: - Hex conversion (6-digit, no alpha)
    //
    // Palette swatches carry color choices, not specific brush-opacity
    // choices. The opacity slider in the picker operates on the active
    // brush color independently. Storing alpha here would create a
    // double-source-of-truth bug.

    static func colorFromHex(_ hex: String) -> CodableColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xff) / 255.0
        let g = CGFloat((value >> 8) & 0xff) / 255.0
        let b = CGFloat(value & 0xff) / 255.0
        return CodableColor(UIColor(red: r, green: g, blue: b, alpha: 1.0))
    }

    static func hexFromColor(_ color: CodableColor) -> String {
        let r = Int((max(0, min(1, color.red)) * 255).rounded())
        let g = Int((max(0, min(1, color.green)) * 255).rounded())
        let b = Int((max(0, min(1, color.blue)) * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

// MARK: - Wire response shapes

struct PaletteListResponse: Decodable {
    let palettes: [Palette]
}

struct PaletteResponse: Decodable {
    let palette: Palette
}
