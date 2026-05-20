//
//  EvolutionSkillRadarView.swift
//  DrawEvolve
//
//  Compact spider chart of accumulated skill evidence per taxonomy
//  category. Two polygons overlaid:
//    - "Then" — net evidence at the midpoint of the period window.
//      Dashed stroke, no fill. Only drawn when there's enough data.
//    - "Now" — net evidence across ALL critiques in the period window.
//      Solid stroke, accent fill at low opacity.
//
//  Severity → signed positivity weight per mention:
//    sev 1 (minor refinement)        → +1.0   strong positive
//    sev 2 (small issue)             → +0.5   mild positive
//    sev 3 (moderate)                →  0.0   neutral
//    sev 4 (significant)             → −0.5   mild regression
//    sev 5 (foundational problem)    → −1.0   strong regression
//  Primary tag gets full weight, each secondary half.
//  Vertex radius: 1 − exp(−max(0, net) / k), saturating asymptotically
//  toward the outer edge as positive evidence accumulates.
//  Categories with net evidence < 0 collapse to center AND tint their
//  axis label red — distinguishes "you're regressing" from "no data."
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

    /// Controls how much net positive evidence is needed before an axis
    /// approaches the outer edge. Bigger k ⇒ slower fill ⇒ more critiques
    /// required to look full. Tuned so ~15 sev-1 primary critiques per
    /// axis (× 8 axes ≈ 120 total) get the polygon near fully-filled.
    private static let saturationConstant: Double = 2.5

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
                Text("Need at least 20 critiques to compare Then vs Now. Showing current shape only.")
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

            // Accumulated net evidence across the full period window.
            // Computed once and shared by the "Now" polygon AND the per-axis
            // label tinting below, so both read the same source of truth.
            let nowEvidence = netEvidenceByCategory(of: windowed)

            // 3. Polygons.
            if canCompare, let then = thenPolygon(center: center, radius: radius) {
                ctx.stroke(then, with: .color(Color.secondary.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
            }
            if !windowed.isEmpty,
               let now = polygonPath(netEvidenceByCategory: nowEvidence,
                                     center: center, radius: radius) {
                ctx.fill(now, with: .color(Color.accentColor.opacity(0.22)))
                ctx.stroke(now, with: .color(Color.accentColor), lineWidth: 1.8)
            }

            // 4. Axis labels. Categories whose net evidence has gone
            // negative (more sev≥4 than sev≤2 in the window) tint red
            // to surface "you're regressing here" — otherwise a
            // regressing axis is visually identical to "no data."
            for i in 0..<axisCount {
                let angle = axisAngle(for: i, of: axisCount)
                let labelRadius = radius + 16
                let labelPoint = CGPoint(
                    x: center.x + cos(angle) * labelRadius,
                    y: center.y + sin(angle) * labelRadius
                )
                let cat = Self.categories[i]
                let net = nowEvidence[cat] ?? 0.0
                let tint: Color = net < 0 ? Color.red.opacity(0.8) : Color.secondary
                let text = Text(cat.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tint)
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

    private func vertexPosition(netEvidence: Double, axisIndex: Int, of axisCount: Int,
                                 center: CGPoint, radius: CGFloat) -> CGPoint {
        // Asymptotic fill: positive evidence pushes outward, saturating
        // toward the rim as the user accumulates more. Negative net
        // evidence collapses to center (no negative radius) — the axis
        // label tints red elsewhere to disambiguate from "no data."
        let n = max(0.0, netEvidence)
        let normalized = 1.0 - exp(-n / Self.saturationConstant)
        let angle = axisAngle(for: axisIndex, of: axisCount)
        let r = radius * CGFloat(normalized)
        return CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
    }

    private func polygonPath(netEvidenceByCategory: [CategoryID: Double],
                              center: CGPoint, radius: CGFloat) -> Path? {
        let axisCount = Self.categories.count
        var path = Path()
        for (i, cat) in Self.categories.enumerated() {
            // Missing-category fallback is 0.0 (still collapses to
            // center, but means "no positive evidence yet" rather than
            // "severity is maxed" as the old `?? 5.0` implied).
            let net = netEvidenceByCategory[cat] ?? 0.0
            let point = vertexPosition(netEvidence: net, axisIndex: i, of: axisCount,
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

    /// Need at least 20 critiques in the window before "Then" (midpoint
    /// snapshot) is a meaningful comparison against "Now."
    private var canCompare: Bool {
        windowed.count >= 20
    }

    /// Net positive-evidence weight per category, summed across the
    /// window. Severity → signed weight (sev 1 → +1.0, 2 → +0.5,
    /// 3 → 0, 4 → −0.5, 5 → −1.0); primary mentions full weight,
    /// secondary mentions half weight. Categories never mentioned are
    /// absent from the result map (callers default missing to 0.0).
    /// Order-insensitive within `critiques`.
    private func netEvidenceByCategory(of critiques: [TaggedCritique]) -> [CategoryID: Double] {
        var net: [CategoryID: Double] = [:]
        for c in critiques {
            let w = positivityWeight(for: c.severity)
            net[c.primaryCategory, default: 0] += w
            for sec in c.secondaryCategories where sec != c.primaryCategory {
                net[sec, default: 0] += w * 0.5
            }
        }
        return net
    }

    private func positivityWeight(for severity: Int) -> Double {
        switch severity {
        case 1: return 1.0
        case 2: return 0.5
        case 3: return 0.0
        case 4: return -0.5
        case 5: return -1.0
        default: return 0.0   // taxonomy clamps 1...5; defensive
        }
    }

    private func thenPolygon(center: CGPoint, radius: CGFloat) -> Path? {
        // Worker promises ascending-by-createdAt (see
        // cloudflare-worker/lib/evolution-aggregation.js buildTaggedCritiques),
        // but the contract is informal — defensively re-sort so the
        // midpoint slice is correct even if upstream ordering shifts.
        let sorted = windowed.sorted { $0.createdAt < $1.createdAt }
        let midpoint = sorted.count / 2
        guard midpoint > 0 else { return nil }
        let earlier = Array(sorted.prefix(midpoint))
        let net = netEvidenceByCategory(of: earlier)
        return polygonPath(netEvidenceByCategory: net, center: center, radius: radius)
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
