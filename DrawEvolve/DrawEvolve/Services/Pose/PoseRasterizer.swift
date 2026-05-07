//
//  PoseRasterizer.swift
//  DrawEvolve
//
//  Pure helper that bakes a PoseSkeleton into a UIImage at canvas-document
//  resolution. Used by `CanvasStateManager.commitPoseToTrace(...)` to
//  produce the bitmap that gets blitted into the active layer's MTLTexture
//  via the existing `CanvasRenderer.renderImage(_:at:to:screenSize:)`
//  path. No new pipeline state, no shader change — Decision 4.
//
//  Visual treatment per audit §4.5: neutral gray strokes, 1.5pt bone width,
//  4pt joint dots. The on-screen accent-color skeleton is intentionally
//  louder so the user can see it through busy artwork; the committed
//  trace is muted so the user can paint over it without visual fight.
//

import CoreGraphics
import UIKit

enum PoseRasterizer {

    /// Render `skeleton` into an opaque-alpha UIImage at `canvasSize`
    /// (canvas-doc pixel dimensions). The image is mostly transparent —
    /// only stroked bones and filled joint dots have non-zero alpha.
    /// `opacity` ∈ (0, 1] multiplies the trace color's alpha so the
    /// commit dialog's slider can mix between subtle and prominent.
    ///
    /// Returns nil only if `canvasSize` has a non-positive dimension.
    static func rasterize(
        skeleton: PoseSkeleton,
        canvasSize: CGSize,
        opacity: CGFloat
    ) -> UIImage? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }

        // scale = 1 keeps the rendered bitmap at the canvas's native
        // pixel resolution. UIGraphicsImageRenderer otherwise uses the
        // device's `UIScreen.main.scale`, which would over-allocate by
        // 2× on @2x displays and confuse `renderImage`'s screen-size
        // arithmetic.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let primaryColor = UIColor(white: 0.25, alpha: opacity).cgColor
            let faceColor = UIColor(white: 0.25, alpha: opacity * 0.5).cgColor

            cg.setLineCap(.round)
            cg.setLineJoin(.round)

            switch skeleton {
            case .hand(let pose):
                drawConnections(
                    HandTopology.connections,
                    joints: pose.joints,
                    color: primaryColor,
                    lineWidth: 1.5,
                    in: cg
                )
                drawJointDots(
                    pose.joints.values.map(\.position),
                    color: primaryColor,
                    diameter: 4,
                    in: cg
                )
            case .body(let pose):
                drawConnections(
                    BodyTopology.primaryConnections,
                    joints: pose.joints,
                    color: primaryColor,
                    lineWidth: 1.5,
                    in: cg
                )
                drawConnections(
                    BodyTopology.faceConnections,
                    joints: pose.joints,
                    color: faceColor,
                    lineWidth: 1.0,
                    in: cg
                )
                drawJointDots(
                    pose.joints.values.map(\.position),
                    color: primaryColor,
                    diameter: 4,
                    in: cg
                )
            }
        }
    }

    // MARK: - Drawing helpers

    private static func drawConnections<Joint: Hashable & Codable>(
        _ connections: [(Joint, Joint)],
        joints: [Joint: PoseJointPoint<Joint>],
        color: CGColor,
        lineWidth: CGFloat,
        in ctx: CGContext
    ) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(lineWidth)
        for (a, b) in connections {
            guard let pa = joints[a]?.position,
                  let pb = joints[b]?.position else { continue }
            ctx.beginPath()
            ctx.move(to: pa)
            ctx.addLine(to: pb)
            ctx.strokePath()
        }
    }

    private static func drawJointDots(
        _ positions: [CGPoint],
        color: CGColor,
        diameter: CGFloat,
        in ctx: CGContext
    ) {
        ctx.setFillColor(color)
        let radius = diameter / 2
        for p in positions {
            let rect = CGRect(
                x: p.x - radius,
                y: p.y - radius,
                width: diameter,
                height: diameter
            )
            ctx.fillEllipse(in: rect)
        }
    }
}
