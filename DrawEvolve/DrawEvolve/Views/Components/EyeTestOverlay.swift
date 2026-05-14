//
//  EyeTestOverlay.swift
//  DrawEvolve
//
//  On-canvas SwiftUI overlay that renders Composition analysis output
//  (top-3 attention hotspot rects and optional Lanczos-upscaled
//  heatmap) on top of MetalCanvasView. Follows the architectural
//  pattern established by ReferenceImageView:
//
//    - Lives in a SwiftUI .overlay above MetalCanvasView. Never
//      enters CanvasStateManager.layers; never participates in
//      compositeLayersToTexture. The composite the AI critique reads
//      is unchanged.
//    - Renders in document coordinates via
//      canvasState.documentToScreen / documentRectToScreen so the
//      markers stay attached to the drawing through canvas zoom /
//      pan / rotation.
//    - Hit-testing disabled — markers don't intercept touches.
//
//  Visibility is gated by the panel's open state (DrawingCanvasView
//  passes `findings: nil` to clear the overlay when the panel
//  closes). Eye Test surface as a whole is gated by the
//  `eye_test_panel` feature flag at the mount site.
//
//  =========================================================================
//  COORDINATE TRANSFORM — verification status: PENDING (hardware tests
//  required before shipping).
//  =========================================================================
//
//  The transform chain is:
//
//    Vision normalized rect  →  document rect  →  screen rect
//    (origin bottom-left,        (origin top-       (via canvasState
//     axes 0..1)                  left, document     .documentRectToScreen)
//                                 pixels)
//
//  Three coordinate verification tests are documented in
//  EYE_TEST_AUDIT_2026-05-14.md section 4.1. They MUST be run on
//  real iPad and iPhone hardware before the feature flips on for
//  general release:
//
//    Test A (center). Draw a single dark dot at exact document
//      center (e.g., 1024, 1024 on a 2048² canvas). Run analysis.
//      Top hotspot should land within ~10% of screen-center at
//      zoom 0.5×, 1.0×, and 2.0×. Failure → zoom math is wrong.
//
//    Test B (corner Y flip). Draw a dot at the bottom-right
//      corner of the document. Run analysis. Top hotspot should
//      land at visual bottom-right of canvas on screen. If it
//      lands at top-right, the Y-axis flip in
//      `visionRectToDocument` is missing or doubled.
//
//    Test C (rotated canvas). Rotate the canvas 90° via the
//      existing rotation gesture. Re-run test B. Marker should
//      follow the document's bottom-right to its new visual
//      location. Failure → `documentRectToScreen` is not handling
//      canvas rotation as expected (it should, by transforming all
//      four corners and returning the bounding box).
//
//  Document outcomes in this file when tests are run.
//

import SwiftUI

struct EyeTestOverlay: View {
    let findings: CompositionFindings?
    let showHeatmap: Bool
    @ObservedObject var canvasState: CanvasStateManager

    var body: some View {
        ZStack {
            if let findings = findings {
                if showHeatmap, let heatmap = findings.attentionHeatmap {
                    heatmapView(heatmap: heatmap)
                }
                if !findings.confidenceLow {
                    ForEach(Array(findings.attentionHotspots.enumerated()), id: \.offset) { index, hotspot in
                        markerView(index: index + 1, hotspot: hotspot)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Heatmap

    private func heatmapView(heatmap: CGImage) -> some View {
        let docRect = CGRect(origin: .zero, size: canvasState.documentSize)
        let screenRect = canvasState.documentRectToScreen(docRect)
        return Image(decorative: heatmap, scale: 1, orientation: .up)
            .resizable()
            .frame(width: screenRect.width, height: screenRect.height)
            .position(x: screenRect.midX, y: screenRect.midY)
            .opacity(0.5)
            .blendMode(.multiply)
    }

    // MARK: - Hotspot markers

    private func markerView(index: Int, hotspot: SaliencyHotspot) -> some View {
        let docRect = visionRectToDocument(hotspot.rect, documentSize: canvasState.documentSize)
        let screenRect = canvasState.documentRectToScreen(docRect)
        let baseColor: Color = hotspot.isTentative ? Color.orange.opacity(0.65) : Color.accentColor
        let lineWidth: CGFloat = hotspot.isTentative ? 2 : 3

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(baseColor, lineWidth: lineWidth)
                .frame(width: screenRect.width, height: screenRect.height)

            HStack(spacing: 4) {
                Text("\(index)")
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(baseColor)
                    .foregroundColor(.white)
                    .cornerRadius(4)
                if hotspot.isTentative {
                    Text("tentative")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.9))
                        .foregroundColor(.white)
                        .cornerRadius(4)
                }
            }
            .padding(4)
            .allowsHitTesting(false)
        }
        .frame(width: screenRect.width, height: screenRect.height)
        .position(x: screenRect.midX, y: screenRect.midY)
    }

    // MARK: - Coord transform

    /// Vision normalized rect (origin bottom-left, axes 0..1) →
    /// document rect (origin top-left, document pixels). The Y flip
    /// is the most common failure mode for Vision overlay code —
    /// Test B above is specifically designed to catch it.
    private func visionRectToDocument(_ visionRect: CGRect, documentSize: CGSize) -> CGRect {
        let x = visionRect.minX * documentSize.width
        let y = (1 - visionRect.minY - visionRect.height) * documentSize.height
        let w = visionRect.width * documentSize.width
        let h = visionRect.height * documentSize.height
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
