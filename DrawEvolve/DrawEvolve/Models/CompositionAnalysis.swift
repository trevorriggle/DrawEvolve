//
//  CompositionAnalysis.swift
//  DrawEvolve
//
//  Wire types for the Composition / "Eye Test" feature. Codable so they
//  round-trip cleanly to the critique pipeline (M4) and persist on the
//  critique row.
//
//  All coordinates are Vision-normalized: origin bottom-left, axes 0..1.
//  UIKit screen-coord conversion happens at render time; never pre-flip
//  here. The intent marker uses the same normalized convention but
//  document-relative, top-left origin (so it composes naturally with
//  documentToScreen on the canvas state).
//

import CoreGraphics
import Foundation

/// One saliency hotspot — a region the Vision model thinks pulls attention.
/// Confidence ∈ [0, 1]; below 0.5 is "tentative" per the confidence-
/// threshold defense (see CompositionAnalysisService doc block).
struct SaliencyHotspot: Codable, Equatable, Hashable {
    /// Vision's normalized bounding box, origin bottom-left, axes 0..1.
    /// Render-side code is responsible for the Y flip and any pan/zoom/
    /// rotation transforms when projecting onto screen.
    let rect: CGRect
    let confidence: Float

    /// True when this hotspot's confidence is below the tentative-
    /// treatment threshold. UI must render tentative hotspots distinctly
    /// (reduced opacity, low-confidence badge) per the M2 panel spec.
    var isTentative: Bool {
        return confidence < SaliencyHotspot.tentativeConfidenceThreshold
    }

    /// Confidence threshold below which a hotspot is rendered as
    /// "tentative." Tunable in code, not surfaced as a user setting.
    /// Calibrated conservatively because the underlying model was
    /// trained on photographs and may produce confidently wrong output
    /// on stylized work.
    static let tentativeConfidenceThreshold: Float = 0.5

    enum CodingKeys: String, CodingKey {
        case rect
        case confidence
    }

    init(rect: CGRect, confidence: Float) {
        self.rect = rect
        self.confidence = confidence
    }
}

/// Result of the drawing-readiness gate that runs BEFORE saliency.
/// The gate refuses to run Vision when the composite is in a state
/// where the model's known failure modes (sparse WIP on white, no
/// luminance variance, mostly empty canvas) are likely to dominate.
struct CompositeReadinessReport: Codable, Equatable {
    enum NotReadyReason: String, Codable, Equatable {
        /// Too much pure-white / near-white pixel area. Drawing is too
        /// sparse for the model to read attention pulls reliably.
        case tooSparse

        /// Not enough midtone coverage. Pure line drawings on white
        /// fall here — value range is bimodal-extreme with no midtones.
        case lacksValueStructure

        /// Composite could not be obtained or analyzed. Treated as
        /// not-ready to keep the gate fail-closed.
        case analysisFailed
    }

    let isReady: Bool
    let reason: NotReadyReason?
    /// 0..1 — fraction of sampled pixels at or above the near-white
    /// luminance threshold.
    let nearWhiteRatio: Double
    /// 0..1 — fraction of sampled pixels within the midtone band.
    let midtoneRatio: Double

    /// User-facing message when the gate refuses. Same wording for both
    /// reasons by design — the user doesn't need to distinguish "too
    /// sparse" from "no midtones," they need to know the analysis isn't
    /// going to be useful yet.
    static let notReadyMessage = "Add more values and shapes before running analysis."
}

/// Output of a successful composition analysis. This is what gets
/// rendered in the panel AND eventually serialized into the
/// critique-request payload at M4. Codable for transit; the heatmap
/// CGImage is intentionally excluded from serialization (only the
/// structured hotspots make sense to send to the AI).
struct CompositionFindings: Equatable {
    /// Top-3 attention hotspots, sorted by descending confidence.
    let attentionHotspots: [SaliencyHotspot]
    /// Top-3 objectness hotspots, sorted by descending confidence.
    /// Surfaced as a secondary mode in the panel.
    let objectnessHotspots: [SaliencyHotspot]
    /// Lanczos-upscaled attention heatmap rendered to the composite's
    /// pixel dimensions. Local-only — not serialized. nil if Vision did
    /// not return a usable pixelBuffer.
    let attentionHeatmap: CGImage?
    /// True when every attention hotspot is tentative (all below the
    /// confidence threshold). UI must render "Vision couldn't read this
    /// drawing clearly" in this case rather than markers.
    let confidenceLow: Bool
    /// Vision wall time, attention request, milliseconds.
    let attentionElapsedMs: Double
    /// Vision wall time, objectness request, milliseconds.
    let objectnessElapsedMs: Double
    /// Composite pixel size at the moment of analysis. Used by the
    /// renderer to size the heatmap and project hotspots.
    let compositeSize: CGSize
    /// Snapshot of the readiness report that allowed this analysis to
    /// proceed. Useful for telemetry and for the panel's "computed from"
    /// affordance.
    let readiness: CompositeReadinessReport
}

/// Codable subset of `CompositionFindings` for transit to the critique
/// worker (M4). Excludes the heatmap (local-only) and timing data.
/// Hotspots are wire-equivalent to the local model.
struct CompositionFindingsPayload: Codable, Equatable {
    let attentionHotspots: [SaliencyHotspot]
    let objectnessHotspots: [SaliencyHotspot]
    let confidenceLow: Bool
    let readinessReason: CompositeReadinessReport.NotReadyReason?
    /// Optional intent-marker location in normalized document coords,
    /// top-left origin. nil when the user hasn't marked intent.
    let intentMarker: IntentMarker?

    enum CodingKeys: String, CodingKey {
        case attentionHotspots = "attention_hotspots"
        case objectnessHotspots = "objectness_hotspots"
        case confidenceLow = "confidence_low"
        case readinessReason = "readiness_reason"
        case intentMarker = "intent_marker"
    }
}

/// User-marked intended focal point. Stored on the Drawing row as
/// jsonb. Normalized document coords, **top-left origin** (consistent
/// with how iOS would convert via documentToScreen). The wrapper struct
/// — rather than a raw CGPoint — is for naming clarity at call sites
/// and to decouple persistence from CoreGraphics, NOT because CGPoint
/// can't encode. CGPoint has been Codable since Swift 4.1.
///
/// v1: single intent point. v2 may extend to multiple ranked points;
/// callers should treat this as "the" intent, not "a" intent.
struct IntentMarker: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
}

/// The three terminal states `CompositionAnalysisService.analyze`
/// returns. UI must handle all three explicitly.
enum CompositionAnalysisResult: Equatable {
    /// Analysis succeeded and produced findings the panel can render.
    case ready(CompositionFindings)
    /// Drawing-readiness gate refused to run Vision. Panel shows the
    /// `notReadyMessage` and a "Re-run when ready" affordance.
    case notReady(CompositeReadinessReport)
    /// Vision threw — typically `com.apple.Vision #9` in simulator, or
    /// neural-engine unavailability on shouldn't-happen device states.
    /// Panel shows a generic "Couldn't run analysis" with the option to
    /// retry. Underlying error captured in `localizedDescription`.
    case visionError(String)

    static func == (lhs: CompositionAnalysisResult, rhs: CompositionAnalysisResult) -> Bool {
        switch (lhs, rhs) {
        case (.ready(let a), .ready(let b)):
            return a == b
        case (.notReady(let a), .notReady(let b)):
            return a == b
        case (.visionError(let a), .visionError(let b)):
            return a == b
        default:
            return false
        }
    }
}
