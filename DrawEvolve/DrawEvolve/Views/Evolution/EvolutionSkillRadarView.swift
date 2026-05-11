//
//  EvolutionSkillRadarView.swift
//  DrawEvolve
//
//  Compact spider chart of critique severity per taxonomy category.
//  Two polygons overlaid:
//    - "Then" — averaged over the EARLIEST 5 critiques in the period.
//      Dashed stroke, no fill.
//    - "Now" — averaged over the most recent 5 critiques in the period.
//      Solid stroke, accent fill at low opacity.
//
//  Distance from center = inverse severity:
//    severity 1.0 (minor refinement) → vertex at the outer edge
//    severity 5.0 (significant work) → vertex at the center
//    no data for a category → vertex at center (skill unknown)
//
//  Drawn with SwiftUI Canvas — no charting library. Eight axes (one per
//  CategoryID case in our taxonomy: anatomy, composition, value, color,
//  line, perspective, subject_match, general).
//

import SwiftUI

struct EvolutionSkillRadarView: View {
    let critiques: [TaggedCritique]

    @State private var period: RadarPeriod = .threeMonths

    /// Categories shown on the radar, fixed order (counter-clockwise
    /// from 12 o'clock). The labels render outside the polygon at the
    /// matching angle. Order locked so the polygon shape is comparable
    /// across runs / period changes.
    private static let categories: [CategoryID] = [
        .anatomy, .composition, .value, .color,
        .line, .perspective, .subjectMatch, .general,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Skill shape")
                    .font(.headline)
                Spacer()
                Picker("Period", selection: $period) {
                    ForEach(RadarPeriod.allCases) { p in
                        Text(p.shortLabel).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }

            radarBody

            if !canCompare {
                Text("Need at least 10 critiques to compare Then vs Now. Showing current shape only.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private var radarBody: some View {
        Canvas { ctx, size in
            let inset: CGFloat = 32
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - inset
            let axisCount = Self.categories.count

            // 1. Concentric reference rings (4 levels) — light gray.
            for ring in 1...4 {
                let r = radius * CGFloat(ring) / 4
                ctx.stroke(
                    Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                    with: .color(Color.secondary.opacity(0.15)),
                    lineWidth: 0.5
                )
            }

            // 2. Spoke axes.
            for i in 0..<axisCount {
                let angle = axisAngle(for: i, of: axisCount)
                let end = CGPoint(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius
                )
                var p = Path()
                p.move(to: center)
                p.addLine(to: end)
                ctx.stroke(p, with: .color(Color.secondary.opacity(0.15)), lineWidth: 0.5)
            }

            // 3. Polygons.
            if canCompare, let then = thenPolygon(center: center, radius: radius) {
                ctx.stroke(then, with: .color(Color.secondary.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
            }
            if let now = nowPolygon(center: center, radius: radius) {
                ctx.fill(now, with: .color(Color.accentColor.opacity(0.22)))
                ctx.stroke(now, with: .color(Color.accentColor), lineWidth: 1.8)
            }

            // 4. Axis labels.
            for i in 0..<axisCount {
                let angle = axisAngle(for: i, of: axisCount)
                let labelRadius = radius + 16
                let labelPoint = CGPoint(
                    x: center.x + cos(angle) * labelRadius,
                    y: center.y + sin(angle) * labelRadius
                )
                let text = Text(Self.categories[i].displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.secondary)
                ctx.draw(text, at: labelPoint, anchor: anchorForAngle(angle))
            }
        }
        .frame(height: 240)
        .padding(.horizontal, 8)
    }

    // MARK: - Geometry helpers

    /// Angle for vertex `i` of `n`. Starts at 12 o'clock (–π/2) and
    /// proceeds clockwise (positive Y is screen-down in Canvas, so we
    /// negate to read counter-clockwise visually if we want; here we
    /// use plain clockwise from top).
    private func axisAngle(for i: Int, of n: Int) -> CGFloat {
        let step = (2.0 * .pi) / CGFloat(n)
        return -CGFloat.pi / 2 + step * CGFloat(i)
    }

    private func anchorForAngle(_ angle: CGFloat) -> UnitPoint {
        // Compute label anchor so the text sits outside the vertex.
        let x = cos(angle), y = sin(angle)
        let h: CGFloat = x > 0.3 ? 0 : (x < -0.3 ? 1 : 0.5)
        let v: CGFloat = y > 0.3 ? 0 : (y < -0.3 ? 1 : 0.5)
        return UnitPoint(x: h, y: v)
    }

    private func vertexPosition(severityAvg: Double, axisIndex: Int, of axisCount: Int,
                                 center: CGPoint, radius: CGFloat) -> CGPoint {
        // severity 1 → outer edge (skill solid)
        // severity 5 → center (skill weak / many issues)
        // severity NaN/no-data → center (no signal)
        let clamped = max(1.0, min(5.0, severityAvg))
        let normalized = (5.0 - clamped) / 4.0   // 0 (worst) → 1 (best)
        let angle = axisAngle(for: axisIndex, of: axisCount)
        let r = radius * CGFloat(normalized)
        return CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
    }

    private func polygonPath(severityByCategory: [CategoryID: Double],
                              center: CGPoint, radius: CGFloat) -> Path? {
        let axisCount = Self.categories.count
        var path = Path()
        for (i, cat) in Self.categories.enumerated() {
            // Categories with no data sit at center → distorts the
            // polygon. Acceptable; communicates "no signal here yet."
            let sev = severityByCategory[cat] ?? 5.0
            let point = vertexPosition(severityAvg: sev, axisIndex: i, of: axisCount,
                                        center: center, radius: radius)
            if i == 0 { path.move(to: point) }
            else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Data slicing

    private var windowed: [TaggedCritique] {
        let cutoff = period.cutoffDate()
        if cutoff == nil { return critiques }
        return critiques.filter { $0.createdAt >= cutoff! }
    }

    /// Need at least 10 critiques in the window for a meaningful
    /// "Then vs Now" — 5 in each half.
    private var canCompare: Bool {
        windowed.count >= 10
    }

    private func averageSeverity(of critiques: [TaggedCritique]) -> [CategoryID: Double] {
        var sums: [CategoryID: Double] = [:]
        var counts: [CategoryID: Int] = [:]
        for c in critiques {
            // Primary counts double-weight; secondaries half.
            sums[c.primaryCategory, default: 0] += Double(c.severity)
            counts[c.primaryCategory, default: 0] += 1
            for sec in c.secondaryCategories where sec != c.primaryCategory {
                sums[sec, default: 0] += Double(c.severity) * 0.5
                counts[sec, default: 0] += 1
            }
        }
        var out: [CategoryID: Double] = [:]
        for (cat, total) in sums {
            let n = counts[cat] ?? 1
            out[cat] = total / Double(n)
        }
        return out
    }

    private func thenPolygon(center: CGPoint, radius: CGFloat) -> Path? {
        let earliest = Array(windowed.prefix(5))
        guard !earliest.isEmpty else { return nil }
        let avg = averageSeverity(of: earliest)
        return polygonPath(severityByCategory: avg, center: center, radius: radius)
    }

    private func nowPolygon(center: CGPoint, radius: CGFloat) -> Path? {
        let recent = Array(windowed.suffix(5))
        guard !recent.isEmpty else { return nil }
        let avg = averageSeverity(of: recent)
        return polygonPath(severityByCategory: avg, center: center, radius: radius)
    }
}

// MARK: - Period selector

enum RadarPeriod: String, CaseIterable, Identifiable {
    case month, threeMonths, allTime

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .month: return "Month"
        case .threeMonths: return "3 mo"
        case .allTime: return "All"
        }
    }

    /// Returns the cutoff Date; `nil` means no filtering (all-time).
    func cutoffDate(now: Date = Date()) -> Date? {
        switch self {
        case .month: return Calendar.current.date(byAdding: .day, value: -30, to: now)
        case .threeMonths: return Calendar.current.date(byAdding: .day, value: -90, to: now)
        case .allTime: return nil
        }
    }
}
