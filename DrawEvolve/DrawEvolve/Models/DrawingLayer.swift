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
    let id = UUID()
    @Published var name: String
    @Published var opacity: Float
    @Published var isVisible: Bool
    @Published var isLocked: Bool
    @Published var blendMode: BlendMode

    // Metal texture for this layer
    var texture: MTLTexture?

    // Cached thumbnail for layer panel preview (44x44)
    @Published var thumbnail: UIImage?

    // Cached UIImage for export
    private(set) var cachedImage: UIImage?

    init(
        name: String,
        opacity: Float = 1.0,
        isVisible: Bool = true,
        isLocked: Bool = false,
        blendMode: BlendMode = .normal
    ) {
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
