//
//  ReferenceImage.swift
//  DrawEvolve
//
//  Phase 1 (2026-05-14): floating reference images that live entirely
//  outside the layer stack. Session-only — owned by DrawingCanvasView
//  via @StateObject, dies with the canvas cover.
//
//  ARCHITECTURAL INVARIANT (also documented at
//  CanvasRenderer.compositeLayersToTexture): references rendered through
//  this manager NEVER enter CanvasStateManager.layers. The composite
//  path for save, AI critique, palette generation, and eyedropper
//  sampling reads strictly from `layers`. Routing references through a
//  separate SwiftUI overlay guarantees exclusion by construction.
//

import Foundation
import SwiftUI
import UIKit
import Vision
import CoreImage

/// One floating reference image. Position is in canvas-view (screen)
/// coords, not document coords — references stay put when the canvas
/// pans/zooms, like photos on a desk next to your paper.
struct ReferenceImage: Identifiable, Equatable {
    let id: UUID
    var image: UIImage
    /// Subject-isolated version (Vision). Populated by
    /// ReferenceImageManager.requestIsolation; nil until the user has
    /// asked for isolation at least once on this reference.
    var isolatedImage: UIImage? = nil
    /// Which version to render. Flips between original and isolated.
    /// User toggles via the chrome button.
    var isIsolated: Bool = false
    /// True while a Vision request is in flight. Drives the chrome
    /// button's spinner; the button is disabled to prevent re-queueing.
    var isIsolating: Bool = false
    /// True if the most recent isolation attempt returned no foreground
    /// (Vision couldn't find a subject in the image). Reset to false on
    /// retry. Shown as a subtle indicator next to the isolation button.
    var lastIsolationFailed: Bool = false

    /// When true, the image body is non-hit-testable: brush strokes pass
    /// straight through to the canvas underneath. Default false on add
    /// so the user can drag the reference into position immediately;
    /// they tap lock when they want to draw over it.
    var isLocked: Bool = false

    /// Center of the displayed rect in canvas-view (screen) coords.
    var center: CGPoint
    /// Multiplier on the image's natural size. 1.0 = original pixel dims.
    var scale: CGFloat = 1.0
    /// 0.0 (fully transparent) ... 1.0 (fully opaque). Floor is 0.0 —
    /// near-invisible ghost-tracing is a legitimate workflow. The chrome
    /// bar above the image stays fully visible regardless, so a faded
    /// reference is always findable.
    var opacity: CGFloat = 1.0
    /// Horizontal mirror (left-right).
    var isFlipped: Bool = false
    /// Vertical mirror (top-bottom). Added Pass 3.
    var isFlippedY: Bool = false
    /// When true, the reference renders BEHIND the canvas's drawing
    /// layers via a dedicated Metal pass — strokes appear on top.
    /// Architectural invariant: this rendering is ONLY in the to-screen
    /// path. compositeLayersToTexture (the save/AI/export composite)
    /// still reads only from `layers`. References in back mode are
    /// just as excluded from the AI as references in front mode.
    var isBehindCanvas: Bool = false

    /// When true, `center` is interpreted as DOCUMENT-space coords and
    /// the reference pans/zooms/rotates with the canvas — like a real
    /// layer would. When false (default), `center` is screen-space
    /// coords and the reference stays put as the canvas moves under it.
    ///
    /// Toggling ON: convert center screen→doc, divide scale by zoom
    /// (so visible size stays the same; canvas rotation will start
    /// applying immediately, which may visually rotate the ref).
    /// Toggling OFF: convert center doc→screen, multiply scale by
    /// zoom (so visible size stays the same); canvas rotation no
    /// longer applies, so the ref becomes upright — this is the
    /// "bake current visible state, un-rotate" behavior the user
    /// specified.
    var followsCanvas: Bool = false
    /// Higher = on top. Manager bumps to max+1 on touch.
    var zOrder: Int = 0
}

/// Session-only owner of the active drawing's reference images.
///
/// Created as @StateObject on DrawingCanvasView, so it lives exactly as
/// long as the canvas cover. No cloud sync, no persistence, no migration.
/// Closing the drawing closes the references — that's the entire
/// lifecycle contract.
@MainActor
final class ReferenceImageManager: ObservableObject {
    @Published private(set) var references: [ReferenceImage] = []

    /// Max pixels along the longer edge. Larger inputs are scaled down at
    /// import to bound memory and (Phase 2) Vision request cost.
    private static let maxEdgePixels: CGFloat = 2048

    /// Default scale on add — sized so the reference is ~30% of viewport
    /// width. Conservative starting size; users dial up via the corner
    /// handles if they want it bigger.
    private static let defaultViewportFraction: CGFloat = 0.30

    /// Add a new reference centered in the visible canvas viewport.
    /// Downsampled to maxEdgePixels at import; scaled so its displayed
    /// width is defaultViewportFraction of the viewport.
    func add(_ image: UIImage, viewportSize: CGSize) {
        let downsampled = Self.downsample(image)
        let targetWidth = viewportSize.width * Self.defaultViewportFraction
        let scale = min(1.0, targetWidth / max(downsampled.size.width, 1))
        let newRef = ReferenceImage(
            id: UUID(),
            image: downsampled,
            center: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2),
            scale: scale,
            opacity: 1.0,
            isFlipped: false,
            zOrder: (references.map(\.zOrder).max() ?? 0) + 1,
        )
        references.append(newRef)
    }

    func remove(id: UUID) {
        references.removeAll { $0.id == id }
    }

    func update(_ reference: ReferenceImage) {
        guard let i = references.firstIndex(where: { $0.id == reference.id }) else { return }
        references[i] = reference
    }

    /// Bring a reference to the front of z-order. Called when the user
    /// taps a reference's header so the most-recently-touched is always
    /// on top of newly-added ones.
    func bringToFront(id: UUID) {
        guard let i = references.firstIndex(where: { $0.id == id }) else { return }
        let maxZ = references.map(\.zOrder).max() ?? 0
        guard references[i].zOrder < maxZ else { return }
        references[i].zOrder = maxZ + 1
    }

    func clearAll() {
        references.removeAll()
    }

    /// Toggle the lock state on the reference at the given id.
    /// Locked = brush strokes pass through the body; unlocked =
    /// body is interactive (drag, resize).
    func toggleLock(id: UUID) {
        guard let i = references.firstIndex(where: { $0.id == id }) else { return }
        references[i].isLocked.toggle()
    }

    /// Subject-isolate the reference at the given id using Vision's
    /// VNGenerateForegroundInstanceMaskRequest. First call kicks off
    /// the async request, sets isIsolating, and on completion either
    /// populates isolatedImage + flips isIsolated true, or sets
    /// lastIsolationFailed if no foreground was found. Subsequent
    /// calls just flip isIsolated between original and cached isolated.
    /// Idempotent: re-entrant calls during in-flight work are no-ops.
    func requestIsolation(id: UUID) async {
        guard let i = references.firstIndex(where: { $0.id == id }) else { return }
        guard !references[i].isIsolating else { return }

        // Cached: just toggle on. Clear any prior failure flag.
        if references[i].isolatedImage != nil {
            references[i].isIsolated.toggle()
            references[i].lastIsolationFailed = false
            return
        }

        references[i].isIsolating = true
        references[i].lastIsolationFailed = false
        let source = references[i].image

        let result: UIImage? = await Task.detached(priority: .userInitiated) {
            ReferenceImageManager.isolateSubject(in: source)
        }.value

        guard let j = references.firstIndex(where: { $0.id == id }) else { return }
        references[j].isIsolating = false
        if let isolated = result {
            references[j].isolatedImage = isolated
            references[j].isIsolated = true
            references[j].lastIsolationFailed = false
        } else {
            references[j].lastIsolationFailed = true
        }
    }

    /// Vision foreground-instance mask request. Returns a UIImage with
    /// alpha zeroed outside the detected subject, or nil if Vision
    /// can't find a foreground. Runs off-main via Task.detached.
    /// iOS 17+ (VNGenerateForegroundInstanceMaskRequest requires it).
    nonisolated private static func isolateSubject(in image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)

        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return nil }
            let pixelBuffer = try observation.generateMaskedImage(
                ofInstances: observation.allInstances,
                from: handler,
                croppedToInstancesExtent: false,
            )
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext()
            guard let outputCG = context.createCGImage(ciImage, from: ciImage.extent) else {
                return nil
            }
            return UIImage(cgImage: outputCG, scale: image.scale, orientation: image.imageOrientation)
        } catch {
            return nil
        }
    }

    /// Aspect-fit downsample to maxEdgePixels using UIGraphicsImageRenderer.
    /// Bypasses if the image is already small enough.
    private static func downsample(_ image: UIImage) -> UIImage {
        let maxEdge = max(image.size.width, image.size.height)
        guard maxEdge > maxEdgePixels else { return image }
        let scale = maxEdgePixels / maxEdge
        let newSize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale,
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
