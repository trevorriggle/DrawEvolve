//
//  SymmetryGuideOverlay.swift
//  DrawEvolve
//
//  Renders the dashed guide lines for the active symmetry mode. Lives as a
//  SwiftUI overlay sibling to MarchingAntsPath / TransformHandlesOverlay
//  in DrawingCanvasView's ZStack — same coordinate-transform pattern:
//  define endpoints in DOC space, map through `canvasState.documentToScreen`
//  for rendering. The overlay rotates / zooms / pans with the canvas
//  automatically because that's what `documentToScreen` already does.
//
//  Static, NOT animated. Marching ants is selection feedback; symmetry
//  guides are persistent reference lines and shouldn't compete for the
//  user's attention with motion.
//
//  When `symmetry.guideHidden == true` the overlay short-circuits to
//  EmptyView. Symmetry math still runs in MetalCanvasView; the user just
//  doesn't see the lines.
//

import SwiftUI

struct SymmetryGuideOverlay: View {
    @ObservedObject var canvasState: CanvasStateManager
    @ObservedObject var symmetry: SymmetryConfig

    var body: some View {
        Group {
            if !symmetry.guideHidden {
                switch symmetry.mode {
                case .off:
                    EmptyView()
                case .axis(let cfg):
                    axisGuides(config: cfg)
                case .radial(let sections):
                    radialGuides(sections: sections)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Axis mode

    @ViewBuilder
    private func axisGuides(config: SymmetryConfig.AxisConfig) -> some View {
        let docSize = canvasState.documentSize
        if docSize.width > 0, docSize.height > 0 {
            // Y-axis: vertical line at x = W/2 (the line that points
            // reflect ACROSS). X-axis: horizontal line at y = H/2.
            // Two flags can be true simultaneously → both lines render.
            if config.yAxis {
                let cx = docSize.width / 2
                guideLine(
                    from: CGPoint(x: cx, y: 0),
                    to: CGPoint(x: cx, y: docSize.height)
                )
            }
            if config.xAxis {
                let cy = docSize.height / 2
                guideLine(
                    from: CGPoint(x: 0, y: cy),
                    to: CGPoint(x: docSize.width, y: cy)
                )
            }
        }
    }

    // MARK: - Radial mode

    @ViewBuilder
    private func radialGuides(sections: Int) -> some View {
        let docSize = canvasState.documentSize
        if sections >= 2, docSize.width > 0, docSize.height > 0 {
            let cx = docSize.width / 2
            let cy = docSize.height / 2
            // N spokes from center at angles 2π·k/N for k ∈ 0..<N. Same
            // angle generator C3's radialMirroredPoints uses, just with
            // k starting at 0 (k=0 is the "spoke pointing east" — the
            // first section divider — and the originals fall in the
            // wedge between spoke 0 and spoke 1).
            ForEach(0..<sections, id: \.self) { k in
                let theta = 2.0 * Double.pi * Double(k) / Double(sections)
                let endpoint = spokeEndpoint(centerX: cx, centerY: cy,
                                             theta: theta,
                                             W: docSize.width, H: docSize.height)
                guideLine(from: CGPoint(x: cx, y: cy), to: endpoint)
            }
        }
    }

    /// Find where a spoke from (cx, cy) at angle θ exits the rectangle
    /// [0, W] × [0, H]. The spoke is `(cx + t·cosθ, cy + t·sinθ)` for
    /// t > 0; the exit `t` is the smallest positive value at which the
    /// parameterized point hits an edge. With center at canvas center
    /// every angle yields a valid intersection. Epsilon guards against
    /// spurious solutions when a spoke is parallel to an axis.
    private func spokeEndpoint(centerX cx: CGFloat, centerY cy: CGFloat,
                               theta: Double, W: CGFloat, H: CGFloat) -> CGPoint {
        let cosT = CGFloat(cos(theta))
        let sinT = CGFloat(sin(theta))
        let eps: CGFloat = 1e-9

        var candidates: [CGFloat] = []
        if cosT > eps { candidates.append((W - cx) / cosT) }   // right edge
        if cosT < -eps { candidates.append((0 - cx) / cosT) }  // left edge
        if sinT > eps { candidates.append((H - cy) / sinT) }   // bottom edge
        if sinT < -eps { candidates.append((0 - cy) / sinT) }  // top edge

        let t = candidates.min() ?? 0
        return CGPoint(x: cx + t * cosT, y: cy + t * sinT)
    }

    // MARK: - Shared line renderer

    /// Render a single doc-space line segment as a dashed guide on screen.
    /// Maps both endpoints through `documentToScreen` so the line picks
    /// up the canvas's current zoom / pan / rotation.
    private func guideLine(from docStart: CGPoint, to docEnd: CGPoint) -> some View {
        let screenStart = canvasState.documentToScreen(docStart)
        let screenEnd = canvasState.documentToScreen(docEnd)
        return Path { p in
            p.move(to: screenStart)
            p.addLine(to: screenEnd)
        }
        .stroke(style: StrokeStyle(
            lineWidth: 1,
            lineCap: .round,
            dash: [6, 3]
        ))
        .foregroundColor(.secondary.opacity(0.5))
    }
}
