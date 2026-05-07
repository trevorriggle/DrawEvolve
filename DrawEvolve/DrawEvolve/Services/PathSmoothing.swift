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

    /// Half-width of the windowed central-difference stencil used for
    /// LUT tangents. For a Catmull-Rom polyline at 12 sub-samples per
    /// raw segment, k=5 averages over ~one raw stroke segment of jitter
    /// without spanning across legitimate sharp corners (those rotate
    /// over 2-3 LUT entries, much smaller than k). Locked-spec
    /// constant; document inline rather than expose as a parameter.
    private static let tangentStencilHalfWidth: Int = 5

    /// Build the arc-length parameterisation table from the smoothed
    /// polyline. Each entry stores the cumulative distance from the start
    /// plus the path's tangent at that sample, computed via a windowed
    /// central difference (`atan2(p[i+k] − p[i−k])`) so per-glyph rotation
    /// doesn't inherit residual position jitter from the smoother.
    ///
    /// `isClosed` controls boundary handling for the tangent stencil:
    /// open paths clamp to the widest one-sided stencil at the endpoints;
    /// closed paths wrap modulo `n` so the seam doesn't have a tangent
    /// discontinuity. Distance bookkeeping ignores closure (the LUT's
    /// `total` excludes the seam-closing segment); `point(at:in:isClosed:)`
    /// applies modulo wrap on lookup, matching this convention.
    ///
    /// Take the polyline directly; spec lists CGPath as the input but the
    /// caller already has the points and converting back via
    /// `path.applyWithBlock` is wasteful. Use the polyline path API only
    /// for rendering / hit-testing.
    static func buildArcLengthLUT(_ smoothed: [CGPoint],
                                  isClosed: Bool = false) -> [PathArcLengthSample] {
        guard smoothed.count >= 2 else {
            if let only = smoothed.first {
                return [PathArcLengthSample(distance: 0, point: only, tangent: 0)]
            }
            return []
        }

        let n = smoothed.count
        let k = tangentStencilHalfWidth
        // For paths shorter than 2k+1 samples the windowed stencil would
        // self-overlap (i+k and i-k landing on the same or near-same
        // index → atan2 of zero-vector). Fall back to the original
        // one-segment forward difference in that case — which is what
        // the pre-Tier-1.5 code did and worked fine for tiny paths.
        let useWindowed = n >= (2 * k + 1)

        var lut: [PathArcLengthSample] = []
        lut.reserveCapacity(n)

        var dist: CGFloat = 0
        for i in 0..<n {
            let p = smoothed[i]
            let tangent: CGFloat = useWindowed
                ? windowedTangent(at: i, smoothed: smoothed, k: k, isClosed: isClosed)
                : forwardTangent(at: i, smoothed: smoothed)
            lut.append(PathArcLengthSample(distance: dist, point: p, tangent: tangent))
            if i + 1 < n {
                let nxt = smoothed[i + 1]
                dist += hypot(nxt.x - p.x, nxt.y - p.y)
            }
        }
        return lut
    }

    /// Tiny-path fallback: outgoing-segment tangent for non-final samples,
    /// incoming-segment tangent for the final sample. Same behaviour as
    /// the pre-Tier-1.5 code path. Only invoked when the polyline is
    /// shorter than the windowed stencil.
    private static func forwardTangent(at i: Int, smoothed: [CGPoint]) -> CGFloat {
        let p = smoothed[i]
        if i + 1 < smoothed.count {
            let nxt = smoothed[i + 1]
            return atan2(nxt.y - p.y, nxt.x - p.x)
        } else {
            let prv = smoothed[i - 1]
            return atan2(p.y - prv.y, p.x - prv.x)
        }
    }

    /// Windowed central difference. For closed paths the index wraps
    /// modulo n so the seam doesn't produce a tangent jump; for open
    /// paths the indices clamp to `[0, n-1]` (degenerating to a one-sided
    /// stencil at the endpoints). Caller has already verified `n ≥ 2k+1`,
    /// so for closed paths `(i+k) mod n` and `(i-k+n) mod n` always land
    /// on distinct samples.
    private static func windowedTangent(at i: Int,
                                        smoothed: [CGPoint],
                                        k: Int,
                                        isClosed: Bool) -> CGFloat {
        let n = smoothed.count
        let prvIdx: Int
        let nxtIdx: Int
        if isClosed {
            nxtIdx = (i + k) % n
            // Swift's `%` keeps the sign of the dividend; offset by `n`
            // to land in `[0, n)` for negative inputs.
            prvIdx = ((i - k) % n + n) % n
        } else {
            prvIdx = max(0, i - k)
            nxtIdx = min(n - 1, i + k)
        }
        if nxtIdx == prvIdx {
            return 0
        }
        let nxt = smoothed[nxtIdx]
        let prv = smoothed[prvIdx]
        return atan2(nxt.y - prv.y, nxt.x - prv.x)
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

    // MARK: - Curvature

    /// Half-width (in LUT indices) of the tangent finite-difference
    /// stencil used to estimate κ. Small enough to capture local
    /// curvature; large enough to ignore the residual jitter that
    /// survived `buildArcLengthLUT`'s windowed tangent stencil. Locked
    /// constant; document inline like the others.
    private static let curvatureWindowRadius: Int = 3

    /// Strength of curvature compensation in `curvatureScale`. 0.5
    /// widens / narrows advance by half the signed `κ × glyphHeight`
    /// factor — empirically matches Procreate's visual spacing on
    /// hand-drawn S-curves. Lower = less compensation (more overlap on
    /// tight curves). Higher = more compensation (visible spacing
    /// stretch on tight curves). Locked-spec.
    private static let curvatureShapeFactor: CGFloat = 0.5

    /// Signed local curvature κ = dθ/ds at arclength `distance` along
    /// the LUT. Computed via finite difference of tangents over a small
    /// window of LUT entries; same closed-path wrap and open-path clamp
    /// semantics as `point(at:in:isClosed:)`.
    ///
    /// Returns 0 for LUTs too small for a meaningful difference, paths
    /// of zero total length, or zero arclength spans (e.g. duplicate
    /// samples inside the window).
    ///
    /// Sign convention: κ > 0 when the path's tangent angle (under
    /// `atan2(Δy, Δx)`) increases as arclength increases. In the
    /// renderer's screen-space (Y-down) coordinates that means a path
    /// turning clockwise visually has κ > 0. Consumers should verify
    /// the sign empirically and flip if their compensation acts in the
    /// wrong direction — the underlying math is just dθ/ds.
    static func curvature(
        at distance: CGFloat,
        in lut: [PathArcLengthSample],
        isClosed: Bool = false
    ) -> CGFloat {
        let n = lut.count
        guard n >= 3 else { return 0 }

        let total = lut.last!.distance
        guard total > 0 else { return 0 }

        var d = distance
        if isClosed {
            d = d.truncatingRemainder(dividingBy: total)
            if d < 0 { d += total }
        } else {
            d = max(0, min(total, d))
        }

        // Binary search for the entry whose distance bracket contains
        // `d`. Mirrors the lookup in `point(at:in:isClosed:)`.
        var lo = 0
        var hi = n - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if lut[mid].distance <= d {
                lo = mid
            } else {
                hi = mid
            }
        }

        let w = curvatureWindowRadius
        let aIdx: Int
        let bIdx: Int
        if isClosed {
            aIdx = ((lo - w) % n + n) % n
            bIdx = (hi + w) % n
        } else {
            aIdx = max(0, lo - w)
            bIdx = min(n - 1, hi + w)
        }

        // Shortest signed angular delta from tangent[aIdx] to
        // tangent[bIdx], handling the ±π seam.
        var dTheta = lut[bIdx].tangent - lut[aIdx].tangent
        while dTheta > .pi { dTheta -= 2 * .pi }
        while dTheta < -.pi { dTheta += 2 * .pi }

        // Arclength difference along the path between the two indices.
        // If the closed-path window wrapped across the seam, the
        // forward arc is `(total - aDist) + bDist`; otherwise it's the
        // straight `bDist - aDist`.
        let aDist = lut[aIdx].distance
        let bDist = lut[bIdx].distance
        let ds: CGFloat
        if isClosed && bIdx < aIdx {
            ds = (total - aDist) + bDist
        } else {
            ds = bDist - aDist
        }

        return ds > 0 ? dTheta / ds : 0
    }

    /// Scaling factor for per-glyph advance to compensate for path
    /// curvature. On tight curves, glyphs sitting at uniform arclength
    /// would visually overlap (their rotated bounding boxes intersect
    /// even though arclength centers are spaced correctly); modulating
    /// advance by `(1 + κ · glyphHeight · shapeFactor)` widens spacing
    /// where the path turns one way and narrows it where it turns the
    /// other, producing more even visual spacing and preventing
    /// overlap on inside curves.
    ///
    /// Clamped to `[0.5, 2.0]` so a single tight cusp doesn't crash
    /// glyphs together (`< 0`) or stretch them past recognition.
    /// `glyphHeight` is in the same units as the LUT's distances
    /// (doc-space points if the LUT was built from doc-space samples,
    /// which it is).
    static func curvatureScale(_ kappa: CGFloat,
                               glyphHeight: CGFloat) -> CGFloat {
        let raw = 1 + kappa * glyphHeight * curvatureShapeFactor
        return max(0.5, min(2.0, raw))
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
