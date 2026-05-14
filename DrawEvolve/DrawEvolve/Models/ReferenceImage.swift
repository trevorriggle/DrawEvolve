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

/// One floating reference image. Position is in canvas-view (screen)
/// coords, not document coords — references stay put when the canvas
/// pans/zooms, like photos on a desk next to your paper.
///
/// Equatable note (Phase 2 follow-up): UIImage equality is pointer
/// identity, not pixel content. Fine for Phase 1 since `image` is only
/// set at init and never mutated; when Phase 2 adds `isolatedImage`,
/// revisit whether two references with the same source image but
/// different isolation states should compare equal.
struct ReferenceImage: Identifiable, Equatable {
    let id: UUID
    var image: UIImage
    /// Phase 2 (Vision subject isolation). Always nil in Phase 1.
    var isolatedImage: UIImage? = nil
    /// Phase 2. UI hidden in Phase 1; field reserved.
    var isIsolated: Bool = false

    /// Center of the displayed rect in canvas-view (screen) coords.
    var center: CGPoint
    /// Multiplier on the image's natural size. 1.0 = original pixel dims.
    var scale: CGFloat = 1.0
    /// 0.0 (fully transparent) ... 1.0 (fully opaque). Floor is 0.0 —
    /// near-invisible ghost-tracing is a legitimate workflow. The chrome
    /// bar above the image stays fully visible regardless, so a faded
    /// reference is always findable.
    var opacity: CGFloat = 1.0
    var isFlipped: Bool = false
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
