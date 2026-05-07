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
//  Codable conformance is wired up (no v1 call site), load-bearing for the
//  v1.1 vector text layer where each float will round-trip through the
//  layered drawing manifest. Three categories of fields are deliberately
//  excluded from encoding:
//    • Runtime caches (cachedImage, cachedTexture, pathLUT) — rebuilt from
//      content/settings/path on demand.
//    • CGPath itself — has no built-in Codable. v1.1 will add a path-segment
//      encoder when the layered manifest learns about FloatingText. Until
//      then, path-bearing texts don't survive a Codable round-trip; v1
//      doesn't serialise either way so this is theoretical.
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

    // MARK: - Type-on-path (Phase 3)
    //
    // `path` and `pathLUT` are set together when the user finishes drawing
    // a path with the textOnPath tool. The LUT is derived from the path
    // (PathSmoothing.buildArcLengthLUT) and treated as a runtime cache —
    // it's *not* persisted; loaders rebuild it from the path after decode.

    /// The user-drawn (smoothed) path the text rides on. nil for plain
    /// FloatingText. Doc-space coordinates.
    var path: CGPath? = nil
    /// Arc-length parameterisation of `path`. Runtime cache; rebuilt by
    /// `PathSmoothing.buildArcLengthLUT` on first rasterise after decode.
    var pathLUT: [PathArcLengthSample]? = nil
    /// Doc-space distance along `path` where text begins. PathStartHandle
    /// drags this. Clamped to [0, arcLength] for open paths; wraps mod
    /// arcLength for closed paths.
    var pathStartOffset: CGFloat = 0
    /// Doc-space perpendicular shift of the text baseline relative to the
    /// path. Positive = above the path (canvas-up direction); negative =
    /// below. Single slider, not a segmented "Above/Centered/Below"
    /// control (locked spec).
    var baselineOffset: CGFloat = 0
    /// True when the user's draw closed the loop (endpoints within 30 pt
    /// screen-space at lift). Auto-detected; the toggle in TypeInspectorView
    /// lets the user override.
    var isClosed: Bool = false
    /// True ⇒ TextOnPathRenderer flips glyphs in upside-down sections
    /// (sustained negative cos of tangent direction). Default off, per
    /// the Tier-1.5 re-audit: matches Procreate / Illustrator behaviour
    /// where text follows path direction continuously. With auto-flip
    /// ON, glyphs on a return leg are rotated upright but their
    /// placement order still walks arclength forward, producing
    /// mirror-text on self-doubling paths (the screenshotted bug). The
    /// toggle stays in the model so users who want the v1 flip
    /// behaviour on heart shapes / closed loops can re-enable it; the
    /// UI surface for the toggle is deferred until the inspector
    /// half-sheet returns.
    var autoFlipEnabled: Bool = false

    /// Runtime cache (Tier-1.5): the doc-space origin where the most
    /// recent rasterise placed the path-laid glyphs. Used by
    /// `CanvasStateManager.rasterizeFloatingTextNow` to preserve a
    /// user-set body-drag offset across re-rasterises (e.g., when a
    /// corner-handle scale bakes into `settings.size` and triggers a
    /// re-layout). Without this, path text would snap back to its
    /// path-natural origin every time the user did anything that
    /// triggered a rasterise. Always nil for plain text. Not Codable.
    var pathNaturalAnchor: CGPoint? = nil

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

// MARK: - Codable
//
// Hand-written conformance that:
//   • Skips runtime caches (cachedImage, cachedTexture, pathLUT) — they're
//     rebuilt from content + settings + path on demand.
//   • Stores `rotation` as Double radians — SwiftUI.Angle isn't Codable
//     itself, and radians is the canonical representation everywhere else.
//   • decodeIfPresent for every type-on-path field so older payloads
//     (without those keys) decode cleanly with the documented defaults.
//   • Skips the `path` (CGPath) entirely. CGPath has no built-in Codable
//     and adding a segment encoder is deferred to v1.1 (when the layered
//     manifest actually serialises FloatingText). Until then, on-path text
//     reverts to plain text on a Codable round-trip; v1 doesn't serialise
//     either way so this is theoretical.

extension FloatingText: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case content
        case settings
        case anchor
        case scale
        case rotationRadians
        case bounds
        case pathStartOffset
        case baselineOffset
        case isClosed
        case autoFlipEnabled
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(content, forKey: .content)
        try c.encode(settings, forKey: .settings)
        try c.encode(anchor, forKey: .anchor)
        try c.encode(scale, forKey: .scale)
        try c.encode(rotation.radians, forKey: .rotationRadians)
        try c.encode(bounds, forKey: .bounds)
        try c.encode(pathStartOffset, forKey: .pathStartOffset)
        try c.encode(baselineOffset, forKey: .baselineOffset)
        try c.encode(isClosed, forKey: .isClosed)
        try c.encode(autoFlipEnabled, forKey: .autoFlipEnabled)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id       = try c.decode(UUID.self, forKey: .id)
        let content  = try c.decode(String.self, forKey: .content)
        let settings = try c.decode(TextSettings.self, forKey: .settings)
        let anchor   = try c.decode(CGPoint.self, forKey: .anchor)
        let bounds   = try c.decode(CGRect.self, forKey: .bounds)

        // Memberwise init handles id/content/settings/anchor/bounds; the
        // rest are mutated in below since they aren't init parameters.
        self.init(
            id: id,
            content: content,
            settings: settings,
            anchor: anchor,
            bounds: bounds
        )

        self.scale = try c.decode(CGSize.self, forKey: .scale)
        self.rotation = .radians(try c.decode(Double.self, forKey: .rotationRadians))
        self.pathStartOffset  = try c.decodeIfPresent(CGFloat.self, forKey: .pathStartOffset)  ?? 0
        self.baselineOffset   = try c.decodeIfPresent(CGFloat.self, forKey: .baselineOffset)   ?? 0
        self.isClosed         = try c.decodeIfPresent(Bool.self,    forKey: .isClosed)         ?? false
        self.autoFlipEnabled  = try c.decodeIfPresent(Bool.self,    forKey: .autoFlipEnabled)  ?? false
        // Runtime caches (cachedImage, cachedTexture) and the path stay nil;
        // caller re-rasterises after load.
    }
}
