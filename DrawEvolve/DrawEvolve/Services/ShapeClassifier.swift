//
//  ShapeClassifier.swift
//  DrawEvolve
//
//  Perfect Shapes (punch list 5.2). Pure, testable geometry: decide whether a
//  just-drawn freehand stroke is *confidently* a line, rectangle, or ellipse.
//  No Metal / renderer / UIKit-touch dependencies — operates on document-space
//  points only, so it can be unit-tested without a device.
//

import CoreGraphics
import Foundation

/// A freehand stroke classified as a clean geometric shape, expressed in the
/// same DOCUMENT-space coordinates the stroke points use. Rectangles and
/// ellipses are axis-aligned and inscribed in the stroke's bounding box — v1
/// does not infer rotation (oriented shapes are a logged later item, not a
/// bug). This matches the existing line/rect/circle shape-tool generators.
enum DetectedShape {
    case line(from: CGPoint, to: CGPoint)
    case rectangle(CGRect)
    case ellipse(CGRect)
}

/// Ramer–Douglas–Peucker polyline simplification. Lifted out of
/// `MetalCanvasView.Coordinator` (per the 5.2 plan) so both the lasso path and
/// the shape classifier share one implementation. Drops near-collinear points
/// whose perpendicular distance to the chord between two kept neighbours is
/// below `epsilon`. Iterative (explicit stack) so a degenerate spiral can't
/// blow the recursion limit on a 5k-point Pencil-coalesced sample. Preserves
/// first and last points (callers rely on `path[0]` for the close).
func simplifyPathRDP(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
    guard pts.count > 2 else { return pts }
    let epsSq = epsilon * epsilon
    var keep = [Bool](repeating: false, count: pts.count)
    keep[0] = true
    keep[pts.count - 1] = true

    // Explicit stack of (start, end) index pairs to process.
    var stack: [(Int, Int)] = [(0, pts.count - 1)]
    while let (start, end) = stack.popLast() {
        if end <= start + 1 { continue }
        let a = pts[start], b = pts[end]
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        var maxDistSq: CGFloat = 0
        var maxIndex = start
        for i in (start + 1)..<end {
            let p = pts[i]
            let distSq: CGFloat
            if lenSq == 0 {
                let ex = p.x - a.x, ey = p.y - a.y
                distSq = ex * ex + ey * ey
            } else {
                // |cross(b-a, p-a)|² / |b-a|² = perp-dist²
                let cross = dx * (a.y - p.y) - dy * (a.x - p.x)
                distSq = cross * cross / lenSq
            }
            if distSq > maxDistSq {
                maxDistSq = distSq
                maxIndex = i
            }
        }
        if maxDistSq > epsSq {
            keep[maxIndex] = true
            stack.append((start, maxIndex))
            stack.append((maxIndex, end))
        }
    }

    var out: [CGPoint] = []
    out.reserveCapacity(pts.count)
    for i in 0..<pts.count where keep[i] {
        out.append(pts[i])
    }
    return out
}

/// Decides whether a just-drawn freehand stroke is *confidently* a line,
/// rectangle, or ellipse. Returns `nil` when the stroke is ambiguous — the
/// caller then leaves the stroke freehand and the hold does nothing.
///
/// Design priorities (spec 5.2): **bias to MISS, never force-correct.** Every
/// gate is scale-invariant (normalised by the stroke's bounding-box diagonal)
/// so it behaves identically at any zoom / canvas resolution. Confidence is a
/// normalised fit error (mean Euclidean deviation from the ideal shape ÷ the
/// bbox diagonal) plus a discrimination margin between the two best
/// candidates, so a stroke that is genuinely between two shapes (rounded
/// rectangle, blob) is rejected rather than guessed.
///
/// All constants are deliberately conservative and **need on-device tuning** —
/// they were chosen by geometric reasoning, not measured against real strokes.
enum ShapeClassifier {
    /// Too few points to distinguish a shape from noise / a tap.
    static let minPoints = 8
    /// Bounding-box diagonal (document points) below which the mark is almost
    /// certainly a tap or accidental flick, not an intended shape.
    static let minDiagonal: CGFloat = 24
    /// Confidence gate: max mean fit error as a fraction of the bbox diagonal.
    /// 0.08 ≈ "the average sample sits within 8% of the diagonal of the ideal
    /// shape." Lower = stricter. Conservative so intentional-but-wobbly art is
    /// left alone.
    static let maxNormalizedError: CGFloat = 0.08
    /// Endpoint gap ÷ diagonal at or below this ⇒ treat the stroke as closed
    /// (rectangle / ellipse candidate). Above ⇒ open (line candidate).
    static let closedMaxGap: CGFloat = 0.18
    /// Line straightness: `endpointDistance / pathLength` at or above this ⇒
    /// the stroke runs (roughly) straight without doubling back. Kills
    /// back-and-forth scribbles that happen to fit a line.
    static let minStraightness: CGFloat = 0.9
    /// RDP simplification epsilon as a fraction of the bbox diagonal
    /// (scale-invariant). Used to count corners on a closed stroke.
    static let rdpEpsilonFraction: CGFloat = 0.03
    /// Corner discriminator for closed strokes. A rectangle reduces under RDP
    /// to ~5 vertices (4 corners + the duplicated close), an ellipse to many
    /// more (a smooth curve needs many short segments). At or below this ⇒
    /// route to rectangle; above ⇒ route to ellipse. This corner count — not a
    /// fixed error margin — is the rect-vs-ellipse discriminator, because an
    /// ellipse sits deceptively close to its bbox edges (its "rectangle error"
    /// is only moderate), which made an error-margin approach reject clean
    /// ellipses. The normalised fit error below is the confidence gate.
    static let rectMaxVertices = 7

    /// Classify `rawPoints` (document space). `nil` ⇒ not confident ⇒ no snap.
    static func classify(_ rawPoints: [CGPoint]) -> DetectedShape? {
        guard rawPoints.count >= minPoints,
              let first = rawPoints.first,
              let last = rawPoints.last else { return nil }

        let box = boundingBox(of: rawPoints)
        let diag = hypot(box.width, box.height)
        guard diag >= minDiagonal else { return nil }

        let isClosed = distance(first, last) / diag <= closedMaxGap

        if !isClosed {
            // Open stroke → line is the only candidate.
            guard let lineError = lineFitError(rawPoints, diag: diag),
                  lineError <= maxNormalizedError else { return nil }
            return .line(from: first, to: last)
        }

        // Closed stroke → rectangle vs ellipse, discriminated by corner count.
        // The routed shape must (a) pass the confidence gate and (b) fit better
        // than the other shape (a cheap cross-check against corner misrouting
        // near the threshold).
        let epsilon = max(2.0, rdpEpsilonFraction * diag)
        let verts = simplifyPathRDP(rawPoints, epsilon: epsilon).count
        let rectError = rectFitError(rawPoints, box: box, diag: diag)
        let ellipseError = ellipseFitError(rawPoints, box: box, diag: diag)

        if verts <= rectMaxVertices {
            if rectError <= maxNormalizedError, rectError <= ellipseError {
                return .rectangle(box)
            }
        } else {
            if ellipseError <= maxNormalizedError, ellipseError <= rectError {
                return .ellipse(box)
            }
        }
        return nil
    }

    // MARK: - Fit errors (mean Euclidean deviation ÷ bbox diagonal)

    /// Mean perpendicular distance to the infinite line through first↔last,
    /// normalised by `diag`. Returns `nil` if the stroke doubles back (low
    /// straightness) or is degenerate.
    private static func lineFitError(_ pts: [CGPoint], diag: CGFloat) -> CGFloat? {
        guard let a = pts.first, let b = pts.last else { return nil }
        let segLen = distance(a, b)
        guard segLen > 0 else { return nil }
        var pathLen: CGFloat = 0
        for i in 1..<pts.count { pathLen += distance(pts[i - 1], pts[i]) }
        guard pathLen > 0, segLen / pathLen >= minStraightness else { return nil }
        var sum: CGFloat = 0
        for p in pts { sum += perpendicularDistance(p, a, b) }
        return (sum / CGFloat(pts.count)) / diag
    }

    /// Mean distance to the nearest edge of the axis-aligned bbox, normalised.
    private static func rectFitError(_ pts: [CGPoint], box: CGRect, diag: CGFloat) -> CGFloat {
        var sum: CGFloat = 0
        for p in pts { sum += distanceToRectPerimeter(p, box) }
        return (sum / CGFloat(pts.count)) / diag
    }

    /// Mean radial deviation from the inscribed ellipse, converted to an
    /// approximate Euclidean distance and normalised by `diag` so it is
    /// comparable to the line / rect errors. `r` is the point's radius in
    /// normalised ellipse space (1.0 ⇒ on the curve); the approximate distance
    /// to the curve is `distanceFromCentre · |r − 1| / r`.
    private static func ellipseFitError(_ pts: [CGPoint], box: CGRect, diag: CGFloat) -> CGFloat {
        let cx = box.midX, cy = box.midY
        let rx = box.width / 2, ry = box.height / 2
        guard rx > 0, ry > 0 else { return .greatestFiniteMagnitude }
        var sum: CGFloat = 0
        var counted = 0
        for p in pts {
            let dx = p.x - cx, dy = p.y - cy
            let nx = dx / rx, ny = dy / ry
            let r = sqrt(nx * nx + ny * ny)
            guard r > 0.0001 else { continue }
            let distFromCentre = hypot(dx, dy)
            sum += distFromCentre * abs(r - 1) / r
            counted += 1
        }
        guard counted > 0 else { return .greatestFiniteMagnitude }
        return (sum / CGFloat(counted)) / diag
    }

    // MARK: - Geometry helpers

    private static func boundingBox(of pts: [CGPoint]) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in pts {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    /// Perpendicular distance from `p` to the infinite line through a↔b.
    private static func perpendicularDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return distance(p, a) }
        let cross = dx * (a.y - p.y) - dy * (a.x - p.x)
        return abs(cross) / sqrt(lenSq)
    }

    /// Distance from `p` to the segment a↔b (clamped to the segment).
    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return distance(p, a) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return distance(p, proj)
    }

    /// Distance from `p` to the nearest of the four bbox edges (the perimeter,
    /// not the filled interior).
    private static func distanceToRectPerimeter(_ p: CGPoint, _ box: CGRect) -> CGFloat {
        let tl = CGPoint(x: box.minX, y: box.minY)
        let tr = CGPoint(x: box.maxX, y: box.minY)
        let br = CGPoint(x: box.maxX, y: box.maxY)
        let bl = CGPoint(x: box.minX, y: box.maxY)
        return min(
            distanceToSegment(p, tl, tr),
            distanceToSegment(p, tr, br),
            distanceToSegment(p, br, bl),
            distanceToSegment(p, bl, tl)
        )
    }
}
