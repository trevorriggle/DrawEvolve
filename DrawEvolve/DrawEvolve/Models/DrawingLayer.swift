//
//  DrawingLayer.swift
//  DrawEvolve
//
//  Layer system for drawing app.
//

import Foundation
import UIKit
import Metal

/// Represents a single drawing layer
class DrawingLayer: Identifiable, ObservableObject {
    // Stable across saves so the layered manifest can round-trip cleanly
    // (ONLINELAYERSTORE.md §3.1). New in-session layers default to a fresh
    // UUID; loaders pass the manifest's layer id so the next save reuses it.
    let id: UUID
    @Published var name: String
    @Published var opacity: Float
    @Published var isVisible: Bool
    @Published var isLocked: Bool
    @Published var blendMode: BlendMode

    // Metal texture for this layer
    var texture: MTLTexture?

    /// Sparse tile-grid mirror of `texture`, populated by the renderer's
    /// dual-write paths (tiling migration Phase 2). Nil until the first
    /// write to this layer initializes it.
    ///
    /// **Dimension invariant:** once initialized, `tileGrid`'s dimensions
    /// (`canvasSize`, `tileSize`, `gridWidth`, `gridHeight`) do not change.
    /// If the canvas size changes mid-session, the grid keeps its original
    /// dimensions; the renderer is responsible for either refusing the
    /// canvas-size change or explicitly rebuilding the grid by reprojecting
    /// allocated tiles into a new grid. Phase 2 does neither — it relies on
    /// the existing capped 2048/4096 canvas-size logic to make this a
    /// non-issue.
    ///
    /// Phase 2 + Phase 3: `texture` is still the source of truth; `tileGrid`
    /// is shadow state. Phase 4 inverts this and removes `texture`.
    var tileGrid: TileGrid?

    // Cached thumbnail for layer panel preview (44x44)
    @Published var thumbnail: UIImage?

    // Cached UIImage for export
    private(set) var cachedImage: UIImage?

    init(
        id: UUID = UUID(),
        name: String,
        opacity: Float = 1.0,
        isVisible: Bool = true,
        isLocked: Bool = false,
        blendMode: BlendMode = .normal
    ) {
        self.id = id
        self.name = name
        self.opacity = opacity
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.blendMode = blendMode
    }

    func updateCache(from texture: MTLTexture) {
        // Convert Metal texture to UIImage for export/feedback
        // Will implement texture-to-image conversion
        self.texture = texture
    }

    func updateThumbnail(_ image: UIImage?) {
        self.thumbnail = image
    }
}

/// Blend modes for layers
enum BlendMode: String, CaseIterable {
    case normal = "Normal"
    case multiply = "Multiply"
    case screen = "Screen"
    case overlay = "Overlay"
    case add = "Add"

    var metalBlendMode: String {
        // Maps to Metal blend operations
        switch self {
        case .normal: return "normal"
        case .multiply: return "multiply"
        case .screen: return "screen"
        case .overlay: return "overlay"
        case .add: return "add"
        }
    }
}
