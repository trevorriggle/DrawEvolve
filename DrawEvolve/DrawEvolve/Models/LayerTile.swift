// LayerTile.swift
// DrawEvolve
//
// Storage cell of TileGrid: one GPU tile plus its bookkeeping.

import Metal

/// A single allocated tile within a layer's `TileGrid`.
///
/// Holds the GPU texture covering one `tileSize × tileSize` region of the
/// layer, plus two pieces of bookkeeping the renderer uses to skip work:
///
/// - `dirtyVersion` is bumped by callers (Phase 2+) every time the tile's
///   pixels are mutated. Consumers like the thumbnail generator can cache a
///   last-seen version per tile and short-circuit if nothing's changed.
/// - `nonTransparentBits` is a 2×2 sub-grid occupancy hint. The tile is
///   split into four equal quadrants and one bit records whether that
///   quadrant has any non-transparent pixels. Composite/export passes use
///   this to early-out tiles that are allocated but entirely zeroed.
///
/// Bit layout of `nonTransparentBits` (bits 4-7 reserved, must remain 0):
///
/// ```
///   ┌─────────┬─────────┐
///   │ bit 0   │ bit 1   │   top-left   top-right
///   ├─────────┼─────────┤
///   │ bit 2   │ bit 3   │   bot-left   bot-right
///   └─────────┴─────────┘
/// ```
///
/// `texture` is `.bgra8Unorm` with `storageMode = .private`. Metal does not
/// guarantee any initial contents for `.private` textures; callers must
/// issue a clear render pass before the first read. Phase 1 has no callers,
/// so this is benign; Phase 2's renderer integration owns the first-use
/// clear.
struct LayerTile {
    let texture: MTLTexture
    var dirtyVersion: UInt32
    var nonTransparentBits: UInt8
}
