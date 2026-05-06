//
//  FloatingText.swift
//  DrawEvolve
//
//  In-flight, editable text object that lives on top of the canvas until the
//  user commits (taps outside, switches tool, or rasterises via the cancel
//  pill). The cached image + texture are rebuilt by CanvasStateManager
//  whenever content / settings change (debounced ~16ms). Drag updates
//  `anchor`; corner handles update `scale`; the rotation handle updates
//  `rotation`. v1 commits to pixels — there's no re-edit story yet, but the
//  reserved fields below leave the door open.
//

import Foundation
import SwiftUI
import UIKit
import Metal

struct FloatingText {
    let id: UUID
    var content: String
    var settings: TextSettings

    /// Top-left of the displayed (scaled, unrotated) text rect in doc space.
    /// `commitFloatingText` writes pixels here; the renderer uses
    /// `displayedRect` (anchor + scaled bounds) for live preview.
    var anchor: CGPoint
    /// Per-axis scale factor. Constrained to uniform in v1 (width == height
    /// at every assignment site — `setUniformScale` enforces it). Identity
    /// = (1, 1). On lift after a corner-handle drag the canvas state bakes
    /// `scale.width` into `settings.size` and resets to identity.
    var scale: CGSize
    /// Visual CCW rotation around the displayed-rect center, matching the
    /// selection convention.
    var rotation: Angle

    /// Doc-space bounds of the rasterised image at scale=1. `bounds.origin`
    /// equals `anchor` immediately after rasterise; drag offsets `anchor`
    /// without touching `bounds.origin`. `bounds.size` is the cached image's
    /// doc-pixel size.
    var bounds: CGRect

    /// Last rasterised image (renderer output). nil until the first
    /// rasterise completes. Re-built on content/settings change.
    var cachedImage: UIImage?
    /// GPU mirror of `cachedImage` for the on-canvas live preview. nil
    /// until the first upload completes.
    var cachedTexture: MTLTexture?

    // MARK: - Reserved for Phase 3 (type-on-path)
    //
    // Architected here so renderer/state-manager touchpoints don't churn
    // again when path support lands. `pathLUT` (the arc-length lookup table)
    // is intentionally omitted — its element type ships with Phase 3's
    // PathSmoothing service.

    var path: CGPath? = nil
    var pathStartOffset: CGFloat = 0
    var baselineOffset: CGFloat = 0
    var isClosed: Bool = false
    var autoFlipEnabled: Bool = true

    init(
        id: UUID = UUID(),
        content: String,
        settings: TextSettings,
        anchor: CGPoint,
        bounds: CGRect = .zero
    ) {
        self.id = id
        self.content = content
        self.settings = settings
        self.anchor = anchor
        self.bounds = bounds
        self.scale = CGSize(width: 1, height: 1)
        self.rotation = .zero
    }

    /// Doc-space rect where the text is displayed at the current scale,
    /// before rotation. Equivalent to `selection`'s computed display rect.
    var displayedRect: CGRect {
        CGRect(
            x: anchor.x,
            y: anchor.y,
            width: bounds.width  * scale.width,
            height: bounds.height * scale.height
        )
    }

    /// True when `point` (doc space) lies inside the displayed rect after
    /// inverse-rotating around the rect's center. Mirrors the selection
    /// hit-test pattern in MetalCanvasView.
    func containsDocPoint(_ point: CGPoint) -> Bool {
        let rect = displayedRect
        guard rect.width > 0, rect.height > 0 else { return false }

        let theta = rotation.radians
        if theta == 0 {
            return rect.contains(point)
        }
        let cx = rect.midX, cy = rect.midY
        let dx = point.x - cx, dy = point.y - cy
        let cosT = cos(theta), sinT = sin(theta)
        // Inverse R(-θ) on Y-down vectors → R(+θ).
        let localX = dx * cosT - dy * sinT
        let localY = dx * sinT + dy * cosT
        return abs(localX) <= rect.width / 2 && abs(localY) <= rect.height / 2
    }

    /// Constrain `scale` to a uniform value (width == height). Use this from
    /// the corner handle so non-uniform text scaling can't sneak in via
    /// careless mutations elsewhere.
    mutating func setUniformScale(_ factor: CGFloat) {
        let clamped = max(0.05, factor)
        scale = CGSize(width: clamped, height: clamped)
    }
}
