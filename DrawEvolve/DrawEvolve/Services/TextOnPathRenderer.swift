//
//  TextOnPathRenderer.swift
//  DrawEvolve
//
//  Lay glyphs along a smoothed path's arc-length parameterisation and
//  rasterise to a UIImage. Mirrors the coordinate / scaling logic of
//  CanvasRenderer.rasterizeFloatingText (font size scaled to texture
//  pixels, image returned at scale=1.0 so renderImage's blit math
//  cancels back to 1:1) but replaces the linear CTFrameDraw layout with
//  a per-glyph manual layout walk.
//
//  Three v1 behaviours that future readers will second-guess — leaving
//  breadcrumbs:
//
//  • Tangent discontinuity at sharp corners renders LITERALLY. When the
//    user's smoothed path has a near-cusp (e.g., a 90° bend), adjacent
//    glyphs across the bend will rotate sharply. We do NOT smooth glyph
//    orientation across the discontinuity. Smoothing it would smear text
//    placement past the actual path geometry, which is harder to reason
//    about and not what the user drew. If a future v1.x adds a corner-
//    smoothing mode, opt in via TextSettings rather than changing the
//    default.
//
//  • Glyph overlap on tight curves renders LITERALLY. When path
//    curvature is tighter than the glyph width, adjacent glyphs visually
//    overlap. We do NOT detect this and skip / re-space glyphs.
//    Detection requires a full second pass measuring transformed glyph
//    bounds and comparing pairwise; not worth it in v1, and the visual
//    artifact is "obvious" enough that users naturally compensate by
//    redrawing the path or shortening the text.
//
//  • Per-glyph path lookup (not per-cluster). Each glyph in a grapheme
//    cluster looks up its own (point, tangent) on the path, so combining
//    marks (e.g., the diaeresis on "ü") may drift slightly relative to
//    the base glyph on tight curves. Per-cluster lookup with
//    intra-cluster glyph offsets would fix this; it's deferred. Auto-flip
//    is still computed per-cluster (see below), so flipping is consistent
//    within a cluster even though placement isn't.
//

import Foundation
import UIKit
import CoreText
import CoreGraphics

enum TextOnPathRenderer {

    /// Auto-flip threshold: a glyph cluster is FLIP-eligible when the
    /// cosine of its tangent angle dips below this value. -0.05 (≈ tangent
    /// pointing more than 93° away from screen-right) is intentionally
    /// just-past-zero — exactly horizontal tangents (cos = 0) don't trip
    /// the flip, only tangents that have begun to point left.
    private static let flipEligibleCosThreshold: CGFloat = -0.05

    /// Sustained-flip duration (in grapheme clusters). A cluster ACTUALLY
    /// flips only when it AND at least one immediate neighbour are
    /// flip-eligible. Picked the minimum-of-2 deliberately:
    ///   • 1 → single-glyph flicker when the tangent transiently dips
    ///     past horizontal through high-curvature peaks (e.g., the cusp
    ///     of a heart). Glyphs flip and unflip on neighbouring positions.
    ///   • 2 → the threshold here. Requires the upside-down section to
    ///     be persistent across two clusters before any flip lands.
    ///   • 3+ → starts missing legitimate flips on short upside-down
    ///     arcs (the bottom lobes of a heart, the bottom half of a small
    ///     ellipse).
    /// 2 is the sweet spot for typical hand-drawn paths. Document this
    /// constant when tuning.
    private static let sustainedFlipMinimumClusters = 2

    /// Rasterise `floatingText`'s content along its arc-length LUT to a
    /// UIImage at canvas-native resolution. Returns the image plus the
    /// doc-space bounds of the laid-out glyphs (so the FloatingText's
    /// `bounds` field stays accurate for hit-testing and transform-handle
    /// math).
    static func rasterize(
        _ ft: FloatingText,
        screenSize: CGSize,
        textureSize: CGSize
    ) -> (image: UIImage, docBounds: CGRect)? {
        guard !ft.content.isEmpty,
              let lut = ft.pathLUT, !lut.isEmpty,
              screenSize.width > 0, screenSize.height > 0,
              textureSize.width > 0, textureSize.height > 0 else { return nil }

        let scale = max(textureSize.width / screenSize.width,
                        textureSize.height / screenSize.height)
        let renderSize = ft.settings.size * scale
        let baselineOffsetTex = ft.baselineOffset * scale

        // Resolve font + italic shear (mirrors CanvasRenderer).
        let baseFont = UIFont(name: ft.settings.fontFace, size: renderSize)
            ?? UIFont(name: ft.settings.fontFamily, size: renderSize)
            ?? UIFont.systemFont(ofSize: renderSize, weight: .regular)
        var resolvedFont = baseFont
        var shearAngle: CGFloat = 0
        if ft.settings.italic {
            if let desc = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                resolvedFont = UIFont(descriptor: desc, size: renderSize)
            } else {
                shearAngle = 12 * .pi / 180
            }
        }

        // Build attributed string. No paragraph alignment — alignment
        // makes no sense on a path; reading direction follows the path.
        var attrs: [NSAttributedString.Key: Any] = [
            .font: resolvedFont,
            .foregroundColor: ft.settings.color,
        ]
        if ft.settings.tracking != 0 {
            attrs[.tracking] = ft.settings.tracking * scale
        }
        var kernValue: CGFloat? = nil
        switch ft.settings.kerning {
        case .auto:           kernValue = nil
        case .none:           kernValue = 0
        case .manual(let v):  kernValue = v * scale
        }
        if let k = kernValue { attrs[.kern] = k }

        let mut = NSMutableAttributedString(string: ft.content, attributes: attrs)
        if kernValue != nil {
            let ns = ft.content as NSString
            if ns.length > 0 {
                let last = ns.rangeOfComposedCharacterSequence(at: ns.length - 1)
                mut.removeAttribute(.kern, range: last)
            }
        }

        // Harvest per-glyph data from the CTLine's runs.
        let line = CTLineCreateWithAttributedString(mut)
        let runs = (CTLineGetGlyphRuns(line) as NSArray) as! [CTRun]

        var glyphRecords: [GlyphRecord] = []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            // Run's font is stored under kCTFontAttributeName. The cast
            // to CTFont always succeeds for runs we built; we still fall
            // back to resolvedFont defensively.
            let runAttrs = CTRunGetAttributes(run) as NSDictionary
            let runFont: CTFont
            if let raw = runAttrs[kCTFontAttributeName as String] {
                runFont = (raw as! CTFont)
            } else {
                runFont = resolvedFont as CTFont
            }

            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            var glyphArr = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphArr)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)

            for i in 0..<count {
                glyphRecords.append(GlyphRecord(
                    glyph: glyphArr[i],
                    font: runFont,
                    stringIndex: indices[i],
                    positionLineX: positions[i].x,
                    advanceX: advances[i].width
                ))
            }
        }
        // CTRunGetGlyphs may emit runs in storage rather than visual order
        // (matters for BiDi, harmless for LTR). Sort by source string
        // index so the cluster mapping below is monotonic.
        glyphRecords.sort { $0.stringIndex < $1.stringIndex }

        // Map each glyph to a grapheme-cluster index. enumerateSubstrings
        // by composed character sequences is the only way to handle
        // emoji / combining marks / ZWJ correctly.
        let source = ft.content as NSString
        var clusterRanges: [NSRange] = []
        var idx = 0
        while idx < source.length {
            let r = source.rangeOfComposedCharacterSequence(at: idx)
            clusterRanges.append(r)
            idx = r.location + r.length
        }
        var glyphCluster = [Int](repeating: 0, count: glyphRecords.count)
        var cIdx = 0
        for (gI, g) in glyphRecords.enumerated() {
            while cIdx < clusterRanges.count - 1 &&
                  g.stringIndex >= clusterRanges[cIdx].location + clusterRanges[cIdx].length {
                cIdx += 1
            }
            glyphCluster[gI] = cIdx
        }

        // Tier-1.5 PR2: per-glyph arclength accumulator with
        // curvature-modulated advance. Replaces the previous
        // `g.positionLineX + g.advanceX/2` flat-layout lookup, which
        // placed glyphs at uniform centerline arclength regardless of
        // curve. On tight curves that produced rotated-bbox overlap on
        // the inside (Symptom 2) and visibly uneven spacing (Symptom 4).
        // The new walk samples κ at each glyph's segment start,
        // modulates `advanceX` by `PathSmoothing.curvatureScale`, and
        // accumulates the result. Glyph height for the curvature
        // formula is `ft.settings.size` (doc-space) — must match the
        // LUT's distance units, which are doc-space.
        let glyphHeightDoc = ft.settings.size

        var glyphCenterArcDoc = [CGFloat](repeating: 0, count: glyphRecords.count)
        var cumulativeArcTex: CGFloat = 0
        for (gI, g) in glyphRecords.enumerated() {
            let segmentStartArcDoc = ft.pathStartOffset + cumulativeArcTex / scale
            let kappa = PathSmoothing.curvature(
                at: segmentStartArcDoc,
                in: lut,
                isClosed: ft.isClosed
            )
            let advanceScaleFactor = PathSmoothing.curvatureScale(
                kappa,
                glyphHeight: glyphHeightDoc
            )
            let scaledAdvanceTex = g.advanceX * advanceScaleFactor
            let centerArcTex = cumulativeArcTex + scaledAdvanceTex / 2
            glyphCenterArcDoc[gI] = ft.pathStartOffset + centerArcTex / scale
            cumulativeArcTex += scaledAdvanceTex
        }

        // Pre-pass: per-cluster flip eligibility based on the tangent at
        // the cluster's center on the path. Cluster center is the
        // midpoint between the first and last glyph's curvature-modulated
        // arclength positions — same scheme as glyph placement so the
        // flip-eligibility lookup never disagrees with the per-glyph
        // placement lookup. Auto-flip is off by default post-PR1; this
        // loop is mostly inert unless the user has toggled it on.
        var clusterFlipEligible = [Bool](repeating: false, count: clusterRanges.count)
        for cI in 0..<clusterRanges.count {
            // Find the first / last glyph belonging to this cluster.
            var startG: Int? = nil
            var endG: Int = 0
            for gI in 0..<glyphRecords.count where glyphCluster[gI] == cI {
                if startG == nil { startG = gI }
                endG = gI
            }
            guard let sG = startG else { continue }
            let centerArcDoc = (glyphCenterArcDoc[sG] + glyphCenterArcDoc[endG]) / 2
            guard let look = PathSmoothing.point(at: centerArcDoc, in: lut, isClosed: ft.isClosed) else {
                continue
            }
            clusterFlipEligible[cI] = ft.autoFlipEnabled
                && cos(look.tangent) < flipEligibleCosThreshold
        }

        // Sustained-flip rule: cluster i actually flips iff it's eligible
        // AND at least one neighbour is also eligible (run length ≥
        // sustainedFlipMinimumClusters). With minimum=2, a single
        // transient cluster never flips on its own.
        var clusterFlip = [Bool](repeating: false, count: clusterRanges.count)
        for c in 0..<clusterRanges.count where clusterFlipEligible[c] {
            // sustainedFlipMinimumClusters == 2 ⇒ check immediate neighbours.
            // If we ever bump this to 3, this loop generalises to a
            // sliding-window count.
            let prev = c > 0 && clusterFlipEligible[c - 1]
            let next = c < clusterRanges.count - 1 && clusterFlipEligible[c + 1]
            clusterFlip[c] = prev || next
        }

        // Per-glyph placement uses the curvature-modulated arclengths
        // computed in the accumulator pass above. See header doc on the
        // per-glyph vs per-cluster path-lookup trade-off.
        var placements: [GlyphPlacement] = []
        placements.reserveCapacity(glyphRecords.count)
        for (gI, g) in glyphRecords.enumerated() {
            let centerArcDoc = glyphCenterArcDoc[gI]
            guard let look = PathSmoothing.point(at: centerArcDoc, in: lut, isClosed: ft.isClosed) else {
                continue
            }
            let texAnchor = CGPoint(x: look.point.x * scale, y: look.point.y * scale)
            placements.append(GlyphPlacement(
                record: g,
                texAnchor: texAnchor,
                tangent: look.tangent,
                flip: clusterFlip[glyphCluster[gI]]
            ))
        }

        guard !placements.isEmpty else { return nil }

        // Bounding box: generous per-glyph radius approximation. Computing
        // exact transformed bboxes via CTFontGetBoundingRectsForGlyphs +
        // a per-corner rotation is doable, but the renderSize-radius
        // fallback below is roomy enough that we never clip and the
        // transparent padding is acceptable.
        let perGlyphRadius = renderSize * 1.2
            + abs(baselineOffsetTex)
            + (shearAngle > 0 ? renderSize * tan(shearAngle) : 0)

        var minX = CGFloat.infinity
        var minY = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var maxY = -CGFloat.infinity
        for p in placements {
            minX = min(minX, p.texAnchor.x - perGlyphRadius)
            minY = min(minY, p.texAnchor.y - perGlyphRadius)
            maxX = max(maxX, p.texAnchor.x + perGlyphRadius)
            maxY = max(maxY, p.texAnchor.y + perGlyphRadius)
        }
        let unionTex = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let drawSize = CGSize(width: ceil(unionTex.width), height: ceil(unionTex.height))
        guard drawSize.width > 0, drawSize.height > 0 else { return nil }

        // Each glyph's anchor is in texture-pixel "doc-origin" coords.
        // The image's local origin lives at unionTex.origin, so subtract
        // that to get image-local coords.
        let originOffset = CGPoint(x: -unionTex.minX, y: -unionTex.minY)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let imageRenderer = UIGraphicsImageRenderer(size: drawSize, format: format)
        let image = imageRenderer.image { ctx in
            let cgctx = ctx.cgContext
            cgctx.textMatrix = .identity
            // Flip to Y-up so Core Text glyphs draw right-side-up.
            cgctx.translateBy(x: 0, y: drawSize.height)
            cgctx.scaleBy(x: 1, y: -1)

            let shearMatrix: CGAffineTransform = shearAngle > 0
                ? CGAffineTransform(a: 1, b: 0, c: tan(shearAngle), d: 1, tx: 0, ty: 0)
                : .identity

            for p in placements {
                cgctx.saveGState()

                // Image-local x is the same; image-local y is flipped
                // (texture space Y-down → context Y-up after the flip).
                let imgX = p.texAnchor.x + originOffset.x
                let imgY_TopDown = p.texAnchor.y + originOffset.y
                let imgY_BottomUp = drawSize.height - imgY_TopDown
                cgctx.translateBy(x: imgX, y: imgY_BottomUp)

                // Tangent in Y-down space rotates CW by +tangent. Our
                // context is now Y-up (CCW = +), so we negate to keep the
                // semantic "rotate by tangent direction".
                cgctx.rotate(by: -p.tangent)
                if p.flip {
                    cgctx.rotate(by: .pi)
                }

                // Baseline offset goes perpendicular to the (post-flip)
                // tangent. With the rotation already applied, +Y is
                // "above the path in the flipped frame". For a non-flip
                // glyph that's visually above the canvas; for a flipped
                // glyph the flip already put it "below" — we negate the
                // sign so positive baselineOffset stays visually-above
                // for both. This matches user intent: a single slider,
                // positive = above the path, regardless of flip state.
                let baselineSign: CGFloat = p.flip ? -1 : 1
                cgctx.translateBy(x: 0, y: baselineSign * baselineOffsetTex)

                if shearAngle > 0 {
                    cgctx.textMatrix = shearMatrix
                }

                // Glyph drawn with its left-baseline at (-advance/2, 0)
                // so its center sits on the rotation origin.
                var glyph = p.record.glyph
                var pos = CGPoint(x: -p.record.advanceX / 2, y: 0)
                CTFontDrawGlyphs(p.record.font, &glyph, &pos, 1, cgctx)

                cgctx.restoreGState()
            }
        }

        // Convert unionTex back to doc space for FloatingText.bounds.
        let docBounds = CGRect(
            x: unionTex.minX / scale,
            y: unionTex.minY / scale,
            width: unionTex.width / scale,
            height: unionTex.height / scale
        )
        return (image, docBounds)
    }

    // MARK: - Internal types

    private struct GlyphRecord {
        let glyph: CGGlyph
        let font: CTFont
        /// UTF-16 index in the source string. Used to map glyphs to
        /// grapheme clusters via NSString character-sequence ranges.
        let stringIndex: Int
        let positionLineX: CGFloat
        let advanceX: CGFloat
    }

    private struct GlyphPlacement {
        let record: GlyphRecord
        /// Glyph's center on the path, in texture-pixel space (doc-origin).
        let texAnchor: CGPoint
        /// Path tangent (radians) at this glyph's center.
        let tangent: CGFloat
        /// True iff this glyph belongs to a cluster that should be
        /// drawn upside-down (sustained-flip rule satisfied).
        let flip: Bool
    }
}
