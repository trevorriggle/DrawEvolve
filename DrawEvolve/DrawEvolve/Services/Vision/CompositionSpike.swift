//
//  CompositionSpike.swift
//  DrawEvolve
//
//  M0 EMPIRICAL GATE — THROWAWAY CODE.
//
//  Read EYE_TEST_AUDIT_2026-05-14.md Part 6 before touching this file.
//
//  This file exists to answer a single question before milestone 1 of the
//  Composition / "Eye Test" feature begins: does
//  VNGenerateAttentionBasedSaliencyImageRequest produce credible output on
//  drawings (not just photographs)? The model was trained on photographic
//  imagery and is expected to fail in known ways on stylized / line / WIP
//  drawings.
//
//  Run on real iPad and iPhone hardware. Vision throws com.apple.Vision #9
//  in the iOS Simulator (see MEMORY.md project_vision_pose_simulator.md).
//
//  Do NOT merge this file to main. Do NOT integrate with the critique
//  pipeline, the Drawing model, or any persistence path. After M0 outcome
//  is documented and a path forward is approved, this file is deleted.
//

#if DEBUG

import CoreImage
import CoreVideo
import Foundation
import UIKit
import Vision

struct CompositionSpikeHotspot {
    /// Vision's normalized rect — origin BOTTOM-LEFT, axes 0..1.
    /// Convert to UIKit screen coords at render time; do not pre-flip here.
    let rect: CGRect
    let confidence: Float
}

struct CompositionSpikeResult {
    let attentionHotspots: [CompositionSpikeHotspot]
    let objectnessHotspots: [CompositionSpikeHotspot]
    /// Lanczos-upscaled monochrome heatmap from the attention request,
    /// rendered to the composite's pixel dimensions. nil if the source
    /// CVPixelBuffer was missing or upscale failed.
    let attentionHeatmap: CGImage?
    let attentionElapsedMs: Double
    let objectnessElapsedMs: Double
    let compositeSize: CGSize
}

enum CompositionSpikeError: Error {
    case noComposite
    case visionUnavailable(underlying: Error)
}

enum CompositionSpike {
    /// Runs both attention + objectness saliency against `image`. Returns
    /// the top-3 hotspots (by confidence) for each, plus the upscaled
    /// attention heatmap. Logs structured output to the Xcode console.
    static func run(on image: UIImage, label: String) async throws -> CompositionSpikeResult {
        guard let visionImage = VisionImage.make(from: image) else {
            throw CompositionSpikeError.noComposite
        }

        let attentionRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        let attentionStart = Date()
        do {
            _ = try await VisionService.shared.perform([attentionRequest], on: visionImage)
        } catch {
            throw CompositionSpikeError.visionUnavailable(underlying: error)
        }
        let attentionMs = Date().timeIntervalSince(attentionStart) * 1000

        let objectnessRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
        let objectnessStart = Date()
        do {
            _ = try await VisionService.shared.perform([objectnessRequest], on: visionImage)
        } catch {
            throw CompositionSpikeError.visionUnavailable(underlying: error)
        }
        let objectnessMs = Date().timeIntervalSince(objectnessStart) * 1000

        let attentionObs = attentionRequest.results?.first
        let objectnessObs = objectnessRequest.results?.first

        let attentionHotspots = extractTop3(from: attentionObs)
        let objectnessHotspots = extractTop3(from: objectnessObs)
        let heatmap = renderHeatmap(from: attentionObs, targetSize: image.size)

        let result = CompositionSpikeResult(
            attentionHotspots: attentionHotspots,
            objectnessHotspots: objectnessHotspots,
            attentionHeatmap: heatmap,
            attentionElapsedMs: attentionMs,
            objectnessElapsedMs: objectnessMs,
            compositeSize: image.size
        )

        logResult(result, label: label)
        return result
    }

    private static func extractTop3(from observation: VNSaliencyImageObservation?) -> [CompositionSpikeHotspot] {
        guard let salientObjects = observation?.salientObjects else { return [] }
        return salientObjects
            .sorted { $0.confidence > $1.confidence }
            .prefix(3)
            .map { CompositionSpikeHotspot(rect: $0.boundingBox, confidence: $0.confidence) }
    }

    private static func renderHeatmap(from observation: VNSaliencyImageObservation?, targetSize: CGSize) -> CGImage? {
        guard let pixelBuffer = observation?.pixelBuffer else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceSize = ciImage.extent.size
        guard sourceSize.width > 0, sourceSize.height > 0,
              targetSize.width > 0, targetSize.height > 0 else { return nil }

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

    private static func logResult(_ result: CompositionSpikeResult, label: String) {
        let banner = String(repeating: "=", count: 60)
        print("\n\(banner)")
        print("M0 SALIENCY SPIKE — \(label)")
        print("composite size: \(Int(result.compositeSize.width))x\(Int(result.compositeSize.height))")
        print(banner)

        print("ATTENTION (\(String(format: "%.0f", result.attentionElapsedMs))ms)")
        if result.attentionHotspots.isEmpty {
            print("  <no salient objects>")
        } else {
            for (i, h) in result.attentionHotspots.enumerated() {
                print("  [\(i + 1)] rect=\(formatRect(h.rect))  conf=\(String(format: "%.3f", h.confidence))")
            }
        }

        print("OBJECTNESS (\(String(format: "%.0f", result.objectnessElapsedMs))ms)")
        if result.objectnessHotspots.isEmpty {
            print("  <no salient objects>")
        } else {
            for (i, h) in result.objectnessHotspots.enumerated() {
                print("  [\(i + 1)] rect=\(formatRect(h.rect))  conf=\(String(format: "%.3f", h.confidence))")
            }
        }

        print("\(banner)\n")
    }

    private static func formatRect(_ r: CGRect) -> String {
        return "x=\(String(format: "%.3f", r.minX)) y=\(String(format: "%.3f", r.minY)) w=\(String(format: "%.3f", r.width)) h=\(String(format: "%.3f", r.height))"
    }
}

#endif
