//
//  PathSmoothing.swift
//  DrawEvolve
//
//  Catmull-Rom path smoothing + arc-length parameterisation for the
//  type-on-path tool. The user's raw stroke samples come from coalesced
//  Apple Pencil touches at ~240 Hz, which produces a jittery polyline.
//  Smoothing turns that into a visually clean curve; arc-length
//  parameterisation lets us look up "where on the path is distance D
//  from the start?" in O(log N), which is what the per-glyph layout walk
//  needs hundreds of times per rasterise.
//
//  Critical: build the LUT ONCE when the path is finalised. Looking up
//  by re-walking the path per glyph is O(glyphs × samples) and visibly
//  chugs on long text or tight curves. The LUT pays for itself after
//  the first ~10 glyphs.
//

import Foundation
import CoreGraphics

/// One sample on the smoothed path, in doc-space coordinates.
/// `tangent` is the angle (radians) of the path's direction at this
/// sample, measured by `atan2(Δy, Δx)` of the segment leaving this point.
struct PathArcLengthSample: Equatable {
    let distance: CGFloat
    let point: CGPoint
    let tangent: CGFloat
}

enum PathSmoothing {

    // MARK: - Catmull-Rom

    /// Smooth a polyline through the supplied control points using
    /// Catmull-Rom interpolation.
    ///
    /// - Parameters:
    ///   - points: raw stroke samples in doc space.
    ///   - tension: 0 = uniform Catmull-Rom (looser, more curvature);
    ///     0.5 = the locked-spec default (closer to centripetal feel
    ///     without the parameterisation cost).
    ///   - samplesPerSegment: subdivisions inserted between each pair of
    ///     adjacent control points. 12 produces a curve that reads as
    ///     smooth at typical zoom levels without bloating the LUT.
    /// - Returns: dense polyline approximating the smoothed curve.
    ///   `points` is returned unchanged for fewer than 2 inputs.
    static func catmullRom(
        _ points: [CGPoint],
        tension: CGFloat = 0.5,
        samplesPerSegment: Int = 12
    ) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        guard samplesPerSegment >= 1 else { return points }

        // Reflect the endpoints so the first/last spline segments are
        // well-defined without "phantom" tangent direction. Without this,
        // the first and last raw samples would be skipped by the spline.
        var pts: [CGPoint] = []
        pts.reserveCapacity(points.count + 2)
        let first = points[0]
        let second = points[1]
        pts.append(CGPoint(x: 2 * first.x - second.x, y: 2 * first.y - second.y))
        pts.append(contentsOf: points)
        let last = points[points.count - 1]
        let secondLast = points[points.count - 2]
        pts.append(CGPoint(x: 2 * last.x - secondLast.x, y: 2 * last.y - secondLast.y))

        var result: [CGPoint] = []
        result.reserveCapacity(samplesPerSegment * (pts.count - 3) + 1)

        let s = (1 - tension) / 2

        for i in 1..<(pts.count - 2) {
            let p0 = pts[i - 1]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[i + 2]
            for j in 0..<samplesPerSegment {
                let t = CGFloat(j) / CGFloat(samplesPerSegment)
                result.append(catmullRomPoint(p0: p0, p1: p1, p2: p2, p3: p3, t: t, s: s))
            }
        }
        result.append(last)
        return result
    }

    private static func catmullRomPoint(
        p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint,
        t: CGFloat, s: CGFloat
    ) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t
        // Hermite-form basis with tension weight `s`. At t=0 yields p1, at t=1
        // yields p2. Derivatives at endpoints are scaled by s, which gives a
        // tighter curve as tension → 1.
        let h0 = -s * t3 + 2 * s * t2 - s * t
        let h1 = (2 - s) * t3 + (s - 3) * t2 + 1
        let h2 = (s - 2) * t3 + (3 - 2 * s) * t2 + s * t
        let h3 = s * t3 - s * t2
        return CGPoint(
            x: h0 * p0.x + h1 * p1.x + h2 * p2.x + h3 * p3.x,
            y: h0 * p0.y + h1 * p1.y + h2 * p2.y + h3 * p3.y
        )
    }

    // MARK: - CGPath

    /// Build a CGPath from the smoothed polyline.
    static func cgPath(from smoothed: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = smoothed.first else { return path }
        path.move(to: first)
        for p in smoothed.dropFirst() {
            path.addLine(to: p)
        }
        return path
    }

    // MARK: - Arc-length LUT

    /// Build the arc-length parameterisation table from the smoothed
    /// polyline. Each entry stores the cumulative distance from the start
    /// plus the point's tangent (atan2 of the leaving segment).
    ///
    /// Take the polyline directly; spec lists CGPath as the input but the
    /// caller already has the points and converting back via
    /// `path.applyWithBlock` is wasteful. Use the polyline path API only
    /// for rendering / hit-testing.
    static func buildArcLengthLUT(_ smoothed: [CGPoint]) -> [PathArcLengthSample] {
        guard smoothed.count >= 2 else {
            if let only = smoothed.first {
                return [PathArcLengthSample(distance: 0, point: only, tangent: 0)]
            }
            return []
        }

        var lut: [PathArcLengthSample] = []
        lut.reserveCapacity(smoothed.count)

        var dist: CGFloat = 0
        for i in 0..<smoothed.count {
            let p = smoothed[i]
            // Tangent direction: outgoing segment for non-final samples, and
            // the incoming segment for the final sample (so the last entry
            // has a sensible angle).
            let tangent: CGFloat
            if i + 1 < smoothed.count {
                let nxt = smoothed[i + 1]
                tangent = atan2(nxt.y - p.y, nxt.x - p.x)
            } else {
                let prv = smoothed[i - 1]
                tangent = atan2(p.y - prv.y, p.x - prv.x)
            }
            lut.append(PathArcLengthSample(distance: dist, point: p, tangent: tangent))
            if i + 1 < smoothed.count {
                let nxt = smoothed[i + 1]
                dist += hypot(nxt.x - p.x, nxt.y - p.y)
            }
        }
        return lut
    }

    /// Look up the (point, tangent) at arc-length `distance` along the LUT
    /// via binary search + linear interpolation between the bracketing
    /// samples. Tangent interpolation wraps across the ±π seam.
    ///
    /// `isClosed` enables modular wrap of the input distance so closed
    /// paths get continuous text past the seam; otherwise the input is
    /// clamped to `[0, totalLength]`.
    ///
    /// Returns nil only when the LUT is empty.
    static func point(
        at distance: CGFloat,
        in lut: [PathArcLengthSample],
        isClosed: Bool = false
    ) -> (point: CGPoint, tangent: CGFloat)? {
        guard !lut.isEmpty else { return nil }
        if lut.count == 1 {
            return (lut[0].point, lut[0].tangent)
        }
        let total = lut.last!.distance
        var d = distance
        if isClosed, total > 0 {
            d = d.truncatingRemainder(dividingBy: total)
            if d < 0 { d += total }
        } else {
            d = max(0, min(total, d))
        }

        // Binary search: find the largest index i with lut[i].distance <= d.
        var lo = 0
        var hi = lut.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if lut[mid].distance <= d {
                lo = mid
            } else {
                hi = mid
            }
        }

        let a = lut[lo]
        let b = lut[hi]
        let span = b.distance - a.distance
        let t: CGFloat = span > 0 ? (d - a.distance) / span : 0

        let point = CGPoint(
            x: a.point.x + (b.point.x - a.point.x) * t,
            y: a.point.y + (b.point.y - a.point.y) * t
        )
        let tangent = lerpAngle(a.tangent, b.tangent, t: t)
        return (point, tangent)
    }

    /// Interpolate two angles (radians) along the shorter arc between
    /// them. Without wrap handling, lerping across the ±π seam (e.g.,
    /// from -3.0 rad to 3.0 rad) would visit every angle the long way
    /// round and visibly spin the glyphs.
    private static func lerpAngle(_ a: CGFloat, _ b: CGFloat, t: CGFloat) -> CGFloat {
        var delta = b - a
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return a + delta * t
    }

    // MARK: - Closure detection

    /// True when the path's endpoints are within `screenPtThreshold` of
    /// each other in screen space at lift. Caller is responsible for
    /// converting doc → screen (the LUT itself doesn't know about screen
    /// coords).
    ///
    /// The 30pt threshold is per the locked spec — small enough that
    /// users with steady hands don't get false closures, large enough to
    /// forgive typical pen drift on a finger-stroked closed loop.
    static func isClosedByEndpoint(
        firstScreen: CGPoint,
        lastScreen: CGPoint,
        screenPtThreshold: CGFloat = 30
    ) -> Bool {
        hypot(firstScreen.x - lastScreen.x, firstScreen.y - lastScreen.y) <= screenPtThreshold
    }
}
