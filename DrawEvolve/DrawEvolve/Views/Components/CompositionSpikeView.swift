//
//  CompositionSpikeView.swift
//  DrawEvolve
//
//  M1 TRANSITIONAL VISUAL DEBUG — STILL THROWAWAY.
//
//  Modal sheet that displays a CompositionAnalysisResult on top of the
//  composite. Used to visually evaluate the M1 service's behavior:
//  whether the readiness gate fires correctly, whether the top-3
//  hotspots land where the eye would actually go, whether the
//  heatmap upscale is usable.
//
//  Deleted in M2 when the production EyeTestPanel ships. The orange
//  flask button in DrawingCanvasView is its only entry point.
//

#if DEBUG

import SwiftUI

struct CompositionSpikeView: View {
    let composite: UIImage
    let result: CompositionAnalysisResult
    let drawingLabel: String
    let onClose: () -> Void

    @State private var showHeatmap: Bool = true
    @State private var showAttention: Bool = true
    @State private var showObjectness: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    switch result {
                    case .ready(let findings):
                        readyContent(findings: findings)
                    case .notReady(let report):
                        notReadyContent(report: report)
                    case .visionError(let message):
                        errorContent(message: message)
                    }
                }
                .padding()
            }
            .navigationTitle("M1 Composition Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", action: onClose)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(drawingLabel)
                .font(.headline)
            Text("Production CompositionAnalysisService output. Attention rects in red, objectness rects in blue. Heatmap is the upscaled 68×68 attention map (Lanczos). Production panel UI lands in M2.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func readyContent(findings: CompositionFindings) -> some View {
        if findings.confidenceLow {
            VStack(alignment: .leading, spacing: 8) {
                Label("Vision couldn't read this drawing clearly", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
                Text("Every attention hotspot is below the tentative-confidence threshold (\(String(format: "%.2f", SaliencyHotspot.tentativeConfidenceThreshold))). Production panel will hide markers in this case — debug view still shows them so you can see what the model returned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.orange.opacity(0.12))
            .cornerRadius(8)
        }

        compositeBlock(findings: findings)
        controls
        Divider()
        numericReadout(findings: findings)
    }

    @ViewBuilder
    private func notReadyContent(report: CompositeReadinessReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Drawing-readiness gate refused analysis", systemImage: "hand.raised.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.orange)
            Text(CompositeReadinessReport.notReadyMessage)
                .font(.body)
            Text("Reason: \(reasonDescription(report.reason))")
                .font(.caption.monospaced())
            Text("Near-white ratio: \(String(format: "%.2f", report.nearWhiteRatio)) (ceiling \(String(format: "%.2f", CompositeReadinessGate.nearWhiteRatioCeiling)))")
                .font(.caption.monospaced())
            Text("Midtone ratio: \(String(format: "%.2f", report.midtoneRatio)) (floor \(String(format: "%.2f", CompositeReadinessGate.midtoneRatioFloor)))")
                .font(.caption.monospaced())
        }
        .padding(12)
        .background(Color.orange.opacity(0.15))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func errorContent(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Vision error", systemImage: "exclamationmark.octagon.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.red)
            Text("Run on real iPad or iPhone — Vision throws com.apple.Vision #9 in the simulator.")
                .font(.callout)
            Text(message)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.red.opacity(0.12))
        .cornerRadius(8)
    }

    private func reasonDescription(_ reason: CompositeReadinessReport.NotReadyReason?) -> String {
        switch reason {
        case .tooSparse: return "too sparse (> 85% near-white pixels)"
        case .lacksValueStructure: return "lacks value structure (< 10% midtone pixels)"
        case .analysisFailed: return "analysis failed"
        case nil: return "unknown"
        }
    }

    private func compositeBlock(findings: CompositionFindings) -> some View {
        GeometryReader { geo in
            let imageFrame = aspectFitFrame(imageSize: composite.size, container: geo.size)

            ZStack(alignment: .topLeading) {
                Image(uiImage: composite)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)

                if showHeatmap, let heatmap = findings.attentionHeatmap {
                    Image(decorative: heatmap, scale: 1, orientation: .up)
                        .resizable()
                        .frame(width: imageFrame.width, height: imageFrame.height)
                        .offset(x: imageFrame.minX, y: imageFrame.minY)
                        .opacity(0.55)
                        .blendMode(.multiply)
                        .allowsHitTesting(false)
                }

                if showAttention {
                    overlayRects(
                        hotspots: findings.attentionHotspots,
                        color: .red,
                        prefix: "A",
                        imageFrame: imageFrame
                    )
                }

                if showObjectness {
                    overlayRects(
                        hotspots: findings.objectnessHotspots,
                        color: .blue,
                        prefix: "O",
                        imageFrame: imageFrame
                    )
                }
            }
        }
        .frame(height: 480)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func overlayRects(
        hotspots: [SaliencyHotspot],
        color: Color,
        prefix: String,
        imageFrame: CGRect
    ) -> some View {
        ForEach(Array(hotspots.enumerated()), id: \.offset) { index, hotspot in
            let displayRect = visionRectToDisplayRect(hotspot.rect, imageFrame: imageFrame)
            let baseColor = hotspot.isTentative ? color.opacity(0.45) : color
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .strokeBorder(baseColor, lineWidth: hotspot.isTentative ? 1.5 : 2.5)
                    .frame(width: displayRect.width, height: displayRect.height)
                HStack(spacing: 2) {
                    Text("\(prefix)\(index + 1) \(String(format: "%.2f", hotspot.confidence))")
                        .font(.caption2.monospaced())
                    if hotspot.isTentative {
                        Text("tentative")
                            .font(.caption2.bold())
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(baseColor)
                .foregroundColor(.white)
                .offset(x: 2, y: 2)
            }
            .offset(x: displayRect.minX, y: displayRect.minY)
            .allowsHitTesting(false)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Attention heatmap", isOn: $showHeatmap)
            Toggle("Attention rects (red)", isOn: $showAttention)
            Toggle("Objectness rects (blue)", isOn: $showObjectness)
        }
        .font(.callout)
    }

    private func numericReadout(findings: CompositionFindings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            readoutSection(
                title: "Attention",
                elapsedMs: findings.attentionElapsedMs,
                hotspots: findings.attentionHotspots
            )
            readoutSection(
                title: "Objectness",
                elapsedMs: findings.objectnessElapsedMs,
                hotspots: findings.objectnessHotspots
            )
            Text("Composite: \(Int(findings.compositeSize.width)) × \(Int(findings.compositeSize.height))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("Readiness: nearWhite=\(String(format: "%.2f", findings.readiness.nearWhiteRatio))  midtones=\(String(format: "%.2f", findings.readiness.midtoneRatio))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("confidenceLow=\(findings.confidenceLow ? "true" : "false")")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func readoutSection(title: String, elapsedMs: Double, hotspots: [SaliencyHotspot]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) — \(String(format: "%.0f", elapsedMs))ms")
                .font(.subheadline.bold())
            if hotspots.isEmpty {
                Text("  <no salient objects returned>")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(hotspots.enumerated()), id: \.offset) { index, hotspot in
                    Text("  [\(index + 1)] \(formatRect(hotspot.rect))  conf=\(String(format: "%.3f", hotspot.confidence))\(hotspot.isTentative ? "  (tentative)" : "")")
                        .font(.caption.monospaced())
                }
            }
        }
    }

    // MARK: - Coord helpers
    //
    // Vision returns normalized rects (origin bottom-left, axes 0..1).
    // The composite is displayed inside `imageFrame` (top-left origin)
    // via .aspectRatio(.fit), so we map vision normalized → image-frame
    // pixels with a Y flip. M2 reimplements this transform in
    // production code with canvas zoom/pan/rotation, plus runs
    // coordinate verification tests A/B/C from the audit.

    private func aspectFitFrame(imageSize: CGSize, container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else {
            return .zero
        }
        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = container.width / container.height
        if imageAspect > containerAspect {
            let h = container.width / imageAspect
            return CGRect(x: 0, y: (container.height - h) / 2, width: container.width, height: h)
        } else {
            let w = container.height * imageAspect
            return CGRect(x: (container.width - w) / 2, y: 0, width: w, height: container.height)
        }
    }

    private func visionRectToDisplayRect(_ rect: CGRect, imageFrame: CGRect) -> CGRect {
        let x = imageFrame.minX + rect.minX * imageFrame.width
        let y = imageFrame.minY + (1 - rect.minY - rect.height) * imageFrame.height
        let w = rect.width * imageFrame.width
        let h = rect.height * imageFrame.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func formatRect(_ r: CGRect) -> String {
        return "x=\(String(format: "%.3f", r.minX)) y=\(String(format: "%.3f", r.minY)) w=\(String(format: "%.3f", r.width)) h=\(String(format: "%.3f", r.height))"
    }
}

#endif
