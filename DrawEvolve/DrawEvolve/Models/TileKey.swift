// TileKey.swift
// DrawEvolve
//
// Tile-grid coordinate used by TileGrid (Phase 1 of the tiling migration).

import Foundation

/// A coordinate in a layer's tile grid.
///
/// `x` and `y` are **tile-grid indices**, not pixel coordinates. The pixel rect
/// of a tile at `TileKey(x: tx, y: ty)` within a grid with `tileSize = S` is:
/// `(tx * S, ty * S, S, S)` in layer-local pixel space.
///
/// Two `TileKey` values are equal iff their `x` and `y` match; the hash
/// combines both fields. Pure value type — no GPU or Foundation dependencies
/// beyond `Int`'s `Hashable` conformance.
struct TileKey: Hashable {
    let x: Int
    let y: Int
}
