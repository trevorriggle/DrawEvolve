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
//  Tangent computation uses the **analytic Catmull-Rom derivative** —
//  closed-form, exact at every t. The earlier finite-difference
//  approaches (one-segment forward in v1, windowed central in PR1)
//  inherited residual position-jitter from the smoothed polyline; the
//  derivative doesn't. Pro tools (Adobe Illustrator, SVG textPath,
//  Procreate) all rely on analytic tangents from smooth curves; this
//  matches that approach. PR #61's curvature-modulated advance was
//  removed at the same time — pro tools don't compensate for curvature
//  either, so neither do we.
//
//  Critical: build the LUT ONCE when the path is finalised. Looking up
//  by re-walking the path per glyph is O(glyphs × samples) and visibly
//  chugs on long text or tight curves. The LUT pays for itself after
//  the first ~10 glyphs.
//

import Foundation
import CoreGraphics

/// One sample along a smoothed path, with its analytic tangent angle.
/// Used as the shared input to `buildArcLengthLUT` so the LUT can carry
/// noise-free tangents derived from the spline's closed-form derivative
/// rather than reconstructing them via finite differences on the
/// resulting polyline.
struct PathPointSample: Equatable {
    let point: CGPoint
    /// Tangent angle in radians, `atan2(dp/dt.y, dp/dt.x)`. Range
    /// `(-π, π]`.
    let tangent: CGFloat
}

/// One sample on the smoothed path, in doc-space coordinates.
/// `tangent` is the angle (radians) of the path's direction at this
/// sample, copied from the source `PathPointSample`.
struct PathArcLengthSample: Equatable {
    let distance: CGFloat
    let point: CGPoint
    let tangent: CGFloat
}

enum PathSmoothing {

    // MARK: - Catmull-Rom

    /// Smooth a polyline through the supplied control points using
    /// Catmull-Rom interpolation, returning per-sample position AND
    /// analytic tangent.
    ///
    /// - Parameters:
    ///   - points: raw stroke samples in doc space.
    ///   - tension: 0 = uniform Catmull-Rom (looser, more curvature);
    ///     0.5 = the locked-spec default (closer to centripetal feel
    ///     without the parameterisation cost).
    ///   - samplesPerSegment: subdivisions inserted between each pair of
    ///     adjacent control points. 12 produces a curve that reads as
    ///     smooth at typical zoom levels without bloating the LUT.
    /// - Returns: dense polyline approximating the smoothed curve, with
    ///   analytic tangents at each sample. `points` is returned as a
    ///   single zero-tangent sample for fewer than 2 inputs (degenerate).
    static func catmullRom(
        _ points: [CGPoint],
        tension: CGFloat = 0.5,
        samplesPerSegment: Int = 12
    ) -> [PathPointSample] {
        guard points.count >= 2 else {
            if let only = points.first {
                return [PathPointSample(point: only, tangent: 0)]
            }
            return []
        }
        guard samplesPerSegment >= 1 else {
            return points.map { PathPointSample(point: $0, tangent: 0) }
        }

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

        var result: [PathPointSample] = []
        result.reserveCapacity(samplesPerSegment * (pts.count - 3) + 1)

        let s = (1 - tension) / 2

        for i in 1..<(pts.count - 2) {
            let p0 = pts[i - 1]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[i + 2]
            for j in 0..<samplesPerSegment {
                let t = CGFloat(j) / CGFloat(samplesPerSegment)
                let point = catmullRomPoint(p0: p0, p1: p1, p2: p2, p3: p3, t: t, s: s)
                let deriv = catmullRomDerivative(p0: p0, p1: p1, p2: p2, p3: p3, t: t, s: s)
                let tangent = atan2(deriv.dy, deriv.dx)
                result.append(PathPointSample(point: point, tangent: tangent))
            }
        }

        // Final point at t=1 of the last segment. Position is the
        // user's last raw sample; tangent is the analytic derivative of
        // the last spline segment evaluated at t=1.
        let lastIdx = pts.count - 3
        let lp0 = pts[lastIdx - 1]
        let lp1 = pts[lastIdx]
        let lp2 = pts[lastIdx + 1]
        let lp3 = pts[lastIdx + 2]
        let endDeriv = catmullRomDerivative(p0: lp0, p1: lp1, p2: lp2, p3: lp3, t: 1.0, s: s)
        let endTangent = atan2(endDeriv.dy, endDeriv.dx)
        result.append(PathPointSample(point: last, tangent: endTangent))

        return result
    }

    /// Catmull-Rom position at parameter t in [0, 1] for the segment
    /// bracketed by p1 → p2 with neighbouring control points p0, p3.
    /// Hermite-form basis with tension weight `s = (1 - tension) / 2`.
    private static func catmullRomPoint(
        p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint,
        t: CGFloat, s: CGFloat
    ) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t
        // At t=0 yields p1, at t=1 yields p2. Derivatives at endpoints
        // are scaled by s, which gives a tighter curve as tension → 1.
        let h0 = -s * t3 + 2 * s * t2 - s * t
        let h1 = (2 - s) * t3 + (s - 3) * t2 + 1
        let h2 = (s - 2) * t3 + (3 - 2 * s) * t2 + s * t
        let h3 = s * t3 - s * t2
        return CGPoint(
            x: h0 * p0.x + h1 * p1.x + h2 * p2.x + h3 * p3.x,
            y: h0 * p0.y + h1 * p1.y + h2 * p2.y + h3 * p3.y
        )
    }

    /// Analytic derivative of the Catmull-Rom basis above. Differentiate
    /// each `h_i(t)` polynomial with respect to t:
    ///
    ///     h0'(t) = -3s·t² + 4s·t - s
    ///     h1'(t) = 3(2-s)·t² + 2(s-3)·t
    ///     h2'(t) = 3(s-2)·t² + 2(3-2s)·t + s
    ///     h3'(t) = 3s·t² - 2s·t
    ///
    /// Returns the 2D tangent vector dp/dt at parameter t. The
    /// instantaneous direction-of-travel along the curve is
    /// `atan2(dp/dt.y, dp/dt.x)`. This is mathematically exact at every
    /// t — no finite-difference noise, no smoothing pass needed. Pro
    /// tools rely on the same closed-form derivative idea (theirs comes
    /// from Bezier-curve derivatives instead of Catmull-Rom; the
    /// principle is identical).
    private static func catmullRomDerivative(
        p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint,
        t: CGFloat, s: CGFloat
    ) -> CGVector {
        let t2 = t * t
        let h0p = -3 * s * t2 + 4 * s * t - s
        let h1p = 3 * (2 - s) * t2 + 2 * (s - 3) * t
        let h2p = 3 * (s - 2) * t2 + 2 * (3 - 2 * s) * t + s
        let h3p = 3 * s * t2 - 2 * s * t
        return CGVector(
            dx: h0p * p0.x + h1p * p1.x + h2p * p2.x + h3p * p3.x,
            dy: h0p * p0.y + h1p * p1.y + h2p * p2.y + h3p * p3.y
        )
    }

    // MARK: - CGPath

    /// Build a CGPath from a polyline of `PathPointSample`s. Tangents
    /// are not used by the path-rendering API; this just walks the
    /// `point` field. Used for the visible path-overlay during typing.
    static func cgPath(from samples: [PathPointSample]) -> CGPath {
        let path = CGMutablePath()
        guard let first = samples.first else { return path }
        path.move(to: first.point)
        for s in samples.dropFirst() {
            path.addLine(to: s.point)
        }
        return path
    }

    // MARK: - Arc-length LUT

    /// Build the arc-length parameterisation table from the smoothed
    /// polyline. Each entry stores the cumulative distance from the
    /// start plus the path's analytic tangent at that sample. Tangents
    /// come straight from the input (computed by `catmullRom` via the
    /// closed-form derivative); no finite-difference reconstruction
    /// happens here.
    ///
    /// `isClosed` is preserved on the API for caller clarity (the
    /// matching `point(at:in:isClosed:)` lookup wraps differently for
    /// closed paths). LUT *construction* doesn't currently need it —
    /// analytic tangents are already correct at every sample regardless
    /// of closure — but the parameter stays so call sites are explicit
    /// about closed/open intent and future construction-time changes
    /// (e.g. seam tangent normalisation) have somewhere to live.
    static func buildArcLengthLUT(_ samples: [PathPointSample],
                                  isClosed: Bool = false) -> [PathArcLengthSample] {
        _ = isClosed  // reserved; see doc comment
        guard samples.count >= 2 else {
            if let only = samples.first {
                return [PathArcLengthSample(distance: 0, point: only.point, tangent: only.tangent)]
            }
            return []
        }

        var lut: [PathArcLengthSample] = []
        lut.reserveCapacity(samples.count)

        var dist: CGFloat = 0
        for i in 0..<samples.count {
            let s = samples[i]
            lut.append(PathArcLengthSample(distance: dist, point: s.point, tangent: s.tangent))
            if i + 1 < samples.count {
                let nxt = samples[i + 1]
                dist += hypot(nxt.point.x - s.point.x, nxt.point.y - s.point.y)
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

    // MARK: - Circle path mode

    /// Default doc-space spacing between samples on a generated circle.
    /// At 4pt spacing a 100pt-radius circle gets ~157 samples; well
    /// above the 64-sample floor and dense enough that even tight
    /// portions of the LUT have fine angular resolution.
    private static let circleDefaultSampleSpacingDoc: CGFloat = 4

    /// Build the arc-length LUT for a perfect circle directly, without
    /// going through Catmull-Rom. A circle is already analytically
    /// smooth at every point — feeding it through spline interpolation
    /// adds nothing and risks artefacts at the seam. We compute
    /// position, tangent, and cumulative arclength from parametric
    /// circle math.
    ///
    /// Parameterisation: angle θ ∈ [0, 2π) maps to
    ///
    ///     point   = center + (R·sin θ, -R·cos θ)
    ///     tangent = atan2(sin θ, cos θ) ≡ θ (normalised to (-π, π])
    ///
    /// At θ=0 the sample is at the **top** of the circle and the
    /// tangent points right (+x). Increasing θ traces visually
    /// clockwise in screen-Y-down. With `autoFlipEnabled=false` (PR1
    /// default) this means text starts at the top reading left-to-right
    /// and reads upside-down on the bottom — same as Adobe Illustrator
    /// circle text.
    ///
    /// Caller should set `floatingText.isClosed = true` so the LUT
    /// lookup wraps the seam continuously.
    static func circleArcLengthLUT(
        center: CGPoint,
        radius: CGFloat,
        sampleSpacingDoc: CGFloat = circleDefaultSampleSpacingDoc
    ) -> [PathArcLengthSample] {
        guard radius > 0 else { return [] }
        let circumference = 2 * .pi * radius
        let n = max(64, Int(ceil(circumference / max(sampleSpacingDoc, 0.5))))
        var lut: [PathArcLengthSample] = []
        lut.reserveCapacity(n)
        for i in 0..<n {
            let theta = 2 * .pi * CGFloat(i) / CGFloat(n)
            let point = CGPoint(
                x: center.x + radius * sin(theta),
                y: center.y - radius * cos(theta)
            )
            // Normalise to (-π, π] to match `atan2`'s range and the
            // tangent values produced by Catmull-Rom samples.
            var tangent = theta
            if tangent > .pi { tangent -= 2 * .pi }
            let distance = circumference * CGFloat(i) / CGFloat(n)
            lut.append(PathArcLengthSample(distance: distance, point: point, tangent: tangent))
        }
        return lut
    }

    /// CGPath for a circle, used as the visible path-overlay during
    /// typing. Doc-space coordinates, matches the LUT's parameterisation
    /// (top-most point, traced visually clockwise).
    static func cgPath(forCircleAt center: CGPoint, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard radius > 0 else { return path }
        path.addEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: 2 * radius,
            height: 2 * radius
        ))
        return path
    }
}
