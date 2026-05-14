//
//  CompositionSpikeView.swift
//  DrawEvolve
//
//  M0 EMPIRICAL GATE — THROWAWAY UI.
//
//  Modal sheet that displays the saliency results from CompositionSpike.swift
//  overlaid on the current drawing's composite. Used to visually answer:
//  "did the top-3 hotspots land where a human would say the eye actually goes?"
//
//  NOT for production. Do not merge to main. See CompositionSpike.swift
//  header for the broader M0 context.
//

#if DEBUG

import SwiftUI

struct CompositionSpikeView: View {
    let composite: UIImage
    let result: CompositionSpikeResult
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

                    compositeBlock

                    controls

                    Divider()

                    numericReadout
                }
                .padding()
            }
            .navigationTitle("M0 Saliency Spike")
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
            Text("Vision attention model + objectness model on the current composite. Attention rects in red, objectness rects in blue. Heatmap is the upscaled 68×68 attention map (Lanczos). Throwaway — does not ship to main.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var compositeBlock: some View {
        GeometryReader { geo in
            let imageFrame = aspectFitFrame(imageSize: composite.size, container: geo.size)

            ZStack(alignment: .topLeading) {
                Image(uiImage: composite)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)

                if showHeatmap, let heatmap = result.attentionHeatmap {
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
                        hotspots: result.attentionHotspots,
                        color: .red,
                        prefix: "A",
                        imageFrame: imageFrame
                    )
                }

                if showObjectness {
                    overlayRects(
                        hotspots: result.objectnessHotspots,
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
        hotspots: [CompositionSpikeHotspot],
        color: Color,
        prefix: String,
        imageFrame: CGRect
    ) -> some View {
        ForEach(Array(hotspots.enumerated()), id: \.offset) { index, hotspot in
            let displayRect = visionRectToDisplayRect(hotspot.rect, imageFrame: imageFrame)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .strokeBorder(color, lineWidth: 2.5)
                    .frame(width: displayRect.width, height: displayRect.height)
                Text("\(prefix)\(index + 1) \(String(format: "%.2f", hotspot.confidence))")
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(color)
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

    private var numericReadout: some View {
        VStack(alignment: .leading, spacing: 12) {
            readoutSection(
                title: "Attention",
                elapsedMs: result.attentionElapsedMs,
                hotspots: result.attentionHotspots
            )
            readoutSection(
                title: "Objectness",
                elapsedMs: result.objectnessElapsedMs,
                hotspots: result.objectnessHotspots
            )
            Text("Composite: \(Int(result.compositeSize.width)) × \(Int(result.compositeSize.height))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func readoutSection(title: String, elapsedMs: Double, hotspots: [CompositionSpikeHotspot]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) — \(String(format: "%.0f", elapsedMs))ms")
                .font(.subheadline.bold())
            if hotspots.isEmpty {
                Text("  <no salient objects returned>")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(hotspots.enumerated()), id: \.offset) { index, hotspot in
                    Text("  [\(index + 1)] \(formatRect(hotspot.rect))  conf=\(String(format: "%.3f", hotspot.confidence))")
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
    // pixels with a Y flip. This is the throwaway version — milestone M2
    // re-derives this transform in production and adds canvas zoom/pan/
    // rotation. The audit's coordinate-verification plan (tests A/B/C
    // in section 4.1) belongs in M2, NOT here.

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
