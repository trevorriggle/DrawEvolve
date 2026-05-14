//
//  CompositionAnalysisService.swift
//  DrawEvolve
//
//  Backs the Composition panel (internal codename: "Eye Test"). Wraps
//  Apple Vision's saliency requests with a drawing-readiness gate, a
//  composite-keyed cache, and confidence-threshold handling. Repurposed
//  from the M0 spike (commit 644c878).
//
//  =========================================================================
//  SHIPPED WITHOUT EMPIRICAL VALIDATION ON DRAWINGS — READ THIS BEFORE
//  TOUCHING THIS FILE.
//  =========================================================================
//
//  The original plan called for a hardware spike (M0) to verify that
//  `VNGenerateAttentionBasedSaliencyImageRequest` produces credible
//  output on real DrawEvolve drawings before milestone work began. The
//  spike was built but the device fleet wasn't available to run it
//  before the build had to proceed. Rather than abandon the feature or
//  fall back to GPT-4o-only composition reasoning (path 3 in
//  EYE_TEST_AUDIT_2026-05-14.md), we shipped on a defensive
//  architecture. The bet is documented below.
//
//  WHAT BET WAS MADE.
//    1. Drawing-readiness gating refuses analysis often enough that
//       the model's worst failure modes (sparse WIP on white, pure
//       line drawings with no luminance variance, mostly empty canvas)
//       never reach the user. Defenses: CompositeReadinessGate below.
//    2. Confidence thresholding catches the rest. Hotspots below 0.5
//       confidence render as "tentative" in the panel. When every
//       attention hotspot is tentative, the panel shows "Vision
//       couldn't read this drawing clearly" instead of confident-
//       looking markers. Defenses: SaliencyHotspot.isTentative and
//       CompositionFindings.confidenceLow.
//    3. Honest UI copy ("Vision's attention model estimates… read it
//       as one perspective, not ground truth") sets expectations such
//       that even partial failures don't damage user trust. Defenses:
//       CompositionPanel header (M2).
//    4. Two decoupled remote feature flags (panel + Eve integration)
//       let us disable the surface without forcing an app update.
//       Defenses: AppFeatureFlags (M2 + M4).
//    5. Beta-only first. Both flags default off for general release.
//       Minimum two weeks of TestFlight data before either flag flips
//       for general.
//
//  WHAT TRIGGERS PULLING THE KILL SWITCH.
//    - Multiple TestFlight reports of confidently wrong findings ("the
//      analysis said X is the focal point but it should obviously be
//      Y"). One or two reports might be the model on bad input;
//      sustained pattern is the model itself being unreliable.
//    - User trust feedback patterns: "I don't trust this", "feels
//      random", "doesn't match what I see in my drawing".
//    - Analytics: pattern of users opening the panel and immediately
//      closing without engagement.
//    - Vision API crashes, stalls, or pathological latencies on real
//      device.
//    - Beta data shows the readiness gate is too lenient — too many
//      visibly-wrong analyses get through. Tighten the gate before
//      pulling, but be prepared to pull.
//
//  FALLBACK PATH IF THE KILL SWITCH IS PULLED.
//    Path 3 from EYE_TEST_AUDIT_2026-05-14.md: drop local Vision and
//    delegate composition reasoning to the existing GPT-4o critique
//    pipeline. The model has already been validated on drawings via
//    the critique pipeline, so it doesn't have the
//    drawing-vs-photograph failure mode this service has. Loses: the
//    instant-feedback panel, the local heatmap, the standalone Eye
//    Test surface. The `compositionFindings` field on the critique
//    row stays; the source of those findings just becomes GPT-4o
//    instead of local Vision.
//
//  CACHE-KEY GAP TO BE AWARE OF.
//    `layerMutationCounter` (CanvasStateManager.swift:38) is bumped on
//    visibility toggles, layer add/remove/reorder, stroke commits,
//    undo/redo, and clear — but NOT on opacity slider drags
//    (endOpacityDrag at CanvasStateManager.swift:454 records history
//    only; no bump). Fixing the bump in that path would silently
//    change auto-save behavior elsewhere, so this service uses a
//    summary-tuple cache key (counter + per-layer opacity + per-layer
//    visibility) to catch the gap locally without touching the
//    canvas state contract. See `CompositionCacheKey`.
//

import Combine
import CoreGraphics
import CoreImage
import Foundation
import UIKit
import Vision

/// Cache key for composition analysis. Combines the structural
/// mutation counter with a per-layer opacity/visibility snapshot so
/// mid-session opacity-slider changes invalidate correctly even though
/// `layerMutationCounter` doesn't bump on those.
private struct CompositionCacheKey: Equatable {
    let mutationCounter: Int
    let opacities: [Float]
    let visibilities: [Bool]

    @MainActor
    init(canvasState: CanvasStateManager) {
        self.mutationCounter = canvasState.layerMutationCounter
        self.opacities = canvasState.layers.map { $0.opacity }
        self.visibilities = canvasState.layers.map { $0.isVisible }
    }
}

/// Drawing-readiness gate. Runs BEFORE the Vision pass per condition 1
/// of the M1 build plan. Refuses analysis when the composite is in a
/// state where the model's known failure modes dominate.
///
/// Thresholds are tunable in code. Adjust after observing real-user
/// data; do not surface as user-facing settings.
enum CompositeReadinessGate {
    /// Refuse analysis when more than this fraction of sampled pixels
    /// are at or above the near-white luminance threshold. Calibrated
    /// to catch sparse WIP-on-white drawings — the failure mode where
    /// the model latches onto the only marks and reports them as the
    /// focal point regardless of compositional intent.
    static let nearWhiteRatioCeiling: Double = 0.85

    /// Refuse analysis when fewer than this fraction of sampled pixels
    /// fall within the midtone band. Calibrated to catch pure line
    /// drawings — bimodal distributions of pure-black-on-pure-white
    /// have no midtones, and the attention model has no luminance
    /// gradient to read.
    static let midtoneRatioFloor: Double = 0.10

    /// Pixels at or above this 8-bit luminance count as "near white."
    static let nearWhiteLuminance: UInt8 = 240

    /// Pixels in [midtoneLowerBound, midtoneUpperBound] count as midtones.
    static let midtoneLowerBound: UInt8 = 40
    static let midtoneUpperBound: UInt8 = 215

    /// Sample size for the readiness analysis. 128×128 is plenty for
    /// ratio statistics and runs in well under a millisecond on a
    /// modern iPad. Larger sizes do not change the verdict in any case
    /// we care about.
    static let sampleEdge: Int = 128

    static func evaluate(composite: UIImage) -> CompositeReadinessReport {
        guard let cgImage = composite.cgImage else {
            return CompositeReadinessReport(
                isReady: false,
                reason: .analysisFailed,
                nearWhiteRatio: 0,
                midtoneRatio: 0
            )
        }

        let edge = sampleEdge
        var pixels = [UInt8](repeating: 0, count: edge * edge)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &pixels,
            width: edge,
            height: edge,
            bitsPerComponent: 8,
            bytesPerRow: edge,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return CompositeReadinessReport(
                isReady: false,
                reason: .analysisFailed,
                nearWhiteRatio: 0,
                midtoneRatio: 0
            )
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: edge, height: edge))

        var nearWhiteCount = 0
        var midtoneCount = 0
        for px in pixels {
            if px >= nearWhiteLuminance {
                nearWhiteCount += 1
            }
            if px >= midtoneLowerBound, px <= midtoneUpperBound {
                midtoneCount += 1
            }
        }

        let total = Double(pixels.count)
        let nearWhiteRatio = Double(nearWhiteCount) / total
        let midtoneRatio = Double(midtoneCount) / total

        if nearWhiteRatio > nearWhiteRatioCeiling {
            return CompositeReadinessReport(
                isReady: false,
                reason: .tooSparse,
                nearWhiteRatio: nearWhiteRatio,
                midtoneRatio: midtoneRatio
            )
        }
        if midtoneRatio < midtoneRatioFloor {
            return CompositeReadinessReport(
                isReady: false,
                reason: .lacksValueStructure,
                nearWhiteRatio: nearWhiteRatio,
                midtoneRatio: midtoneRatio
            )
        }

        return CompositeReadinessReport(
            isReady: true,
            reason: nil,
            nearWhiteRatio: nearWhiteRatio,
            midtoneRatio: midtoneRatio
        )
    }
}

/// Raw output of one Vision pass, internal to the service. Decoupled
/// from `CompositionFindings` so the readiness/cache layers can
/// compose the public surface without leaking Vision types upward.
private struct RawSaliencyResult {
    let attentionHotspots: [SaliencyHotspot]
    let objectnessHotspots: [SaliencyHotspot]
    let heatmap: CGImage?
    let attentionElapsedMs: Double
    let objectnessElapsedMs: Double
}

/// Production service for composition analysis. Lifecycle is tied to
/// the canvas view (`@StateObject` on DrawingCanvasView). The cache
/// dies with the canvas — opening a different drawing resets state.
@MainActor
final class CompositionAnalysisService: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastResult: CompositionAnalysisResult?

    private var cache: (key: CompositionCacheKey, result: CompositionAnalysisResult)?

    /// Run composition analysis against the current canvas state.
    /// Reads the composite via the same path the AI critique uses
    /// (CanvasRenderer.compositeLayersToTexture). Returns the cached
    /// result when the canvas hasn't changed since the last run.
    func analyze(canvasState: CanvasStateManager) async -> CompositionAnalysisResult {
        let key = CompositionCacheKey(canvasState: canvasState)
        if let cache, cache.key == key {
            lastResult = cache.result
            return cache.result
        }

        guard let renderer = canvasState.renderer,
              let texture = renderer.compositeLayersToTexture(layers: canvasState.layers),
              let composite = renderer.textureToUIImage(texture) else {
            let report = CompositeReadinessReport(
                isReady: false,
                reason: .analysisFailed,
                nearWhiteRatio: 0,
                midtoneRatio: 0
            )
            let result: CompositionAnalysisResult = .notReady(report)
            cache = (key, result)
            lastResult = result
            return result
        }

        let readiness = CompositeReadinessGate.evaluate(composite: composite)
        guard readiness.isReady else {
            let result: CompositionAnalysisResult = .notReady(readiness)
            cache = (key, result)
            lastResult = result
            return result
        }

        isRunning = true
        defer { isRunning = false }

        do {
            let raw = try await runVision(on: composite)
            let confidenceLow = raw.attentionHotspots.isEmpty
                || raw.attentionHotspots.allSatisfy { $0.isTentative }
            let findings = CompositionFindings(
                attentionHotspots: raw.attentionHotspots,
                objectnessHotspots: raw.objectnessHotspots,
                attentionHeatmap: raw.heatmap,
                confidenceLow: confidenceLow,
                attentionElapsedMs: raw.attentionElapsedMs,
                objectnessElapsedMs: raw.objectnessElapsedMs,
                compositeSize: composite.size,
                readiness: readiness
            )
            let result: CompositionAnalysisResult = .ready(findings)
            cache = (key, result)
            lastResult = result
            return result
        } catch {
            let result: CompositionAnalysisResult = .visionError(error.localizedDescription)
            // Intentionally NOT caching errors — retry on next attempt.
            lastResult = result
            return result
        }
    }

    /// Discard the cached result. Call when the cache must be busted
    /// outside the normal layer-state flow (e.g. user explicitly
    /// requests re-analysis from the panel).
    func invalidateCache() {
        cache = nil
    }

    /// Build a Codable payload for the critique pipeline (M4). Pulls
    /// from the most recent `.ready` result; returns nil when the
    /// service hasn't produced one (gate refused, error, never run).
    /// The intent marker is provided by the caller — it lives on the
    /// Drawing row, not in the service's state.
    func currentFindingsPayload(intentMarker: IntentMarker?) -> CompositionFindingsPayload? {
        guard case .ready(let findings) = lastResult else {
            return nil
        }
        return CompositionFindingsPayload(
            attentionHotspots: findings.attentionHotspots,
            objectnessHotspots: findings.objectnessHotspots,
            confidenceLow: findings.confidenceLow,
            readinessReason: findings.readiness.reason,
            intentMarker: intentMarker
        )
    }

    // MARK: - Vision

    private func runVision(on image: UIImage) async throws -> RawSaliencyResult {
        guard let visionImage = VisionImage.make(from: image) else {
            throw VisionServiceError.imageEncodingFailed
        }

        let attentionRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        let attentionStart = Date()
        _ = try await VisionService.shared.perform([attentionRequest], on: visionImage)
        let attentionMs = Date().timeIntervalSince(attentionStart) * 1000

        let objectnessRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
        let objectnessStart = Date()
        _ = try await VisionService.shared.perform([objectnessRequest], on: visionImage)
        let objectnessMs = Date().timeIntervalSince(objectnessStart) * 1000

        let attentionObservation = attentionRequest.results?.first
        let objectnessObservation = objectnessRequest.results?.first

        let attentionHotspots = Self.top3(from: attentionObservation)
        let objectnessHotspots = Self.top3(from: objectnessObservation)
        let heatmap = Self.renderAttentionHeatmap(
            from: attentionObservation,
            targetSize: image.size
        )

        return RawSaliencyResult(
            attentionHotspots: attentionHotspots,
            objectnessHotspots: objectnessHotspots,
            heatmap: heatmap,
            attentionElapsedMs: attentionMs,
            objectnessElapsedMs: objectnessMs
        )
    }

    private static func top3(from observation: VNSaliencyImageObservation?) -> [SaliencyHotspot] {
        guard let salientObjects = observation?.salientObjects else { return [] }
        return salientObjects
            .sorted { $0.confidence > $1.confidence }
            .prefix(3)
            .map { SaliencyHotspot(rect: $0.boundingBox, confidence: $0.confidence) }
    }

    /// Lanczos-upscale the 68×68 attention heatmap to the composite's
    /// pixel size. M1 ships monochrome; M5 swaps in the viridis ramp
    /// via CIColorMap.
    private static func renderAttentionHeatmap(
        from observation: VNSaliencyImageObservation?,
        targetSize: CGSize
    ) -> CGImage? {
        guard let pixelBuffer = observation?.pixelBuffer else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceSize = ciImage.extent.size
        guard sourceSize.width > 0, sourceSize.height > 0,
              targetSize.width > 0, targetSize.height > 0 else {
            return nil
        }

        let scaleY = targetSize.height / sourceSize.height
        let aspectRatio = (targetSize.width / sourceSize.width) / scaleY

        let scaled = ciImage.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scaleY,
            kCIInputAspectRatioKey: aspectRatio
        ])

        let context = CIContext()
        let extent = CGRect(origin: .zero, size: targetSize)
        return context.createCGImage(scaled, from: extent)
    }
}
