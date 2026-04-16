//
//  CanvasStateManager.swift
//  DrawEvolve
//
//  Manages canvas state including layers, tools, selection, zoom/pan, and history
//

import Foundation
import SwiftUI
import UIKit
import Combine

@MainActor
class CanvasStateManager: ObservableObject {
    @Published var layers: [DrawingLayer] = []
    @Published var selectedLayerIndex = 0
    @Published var currentTool: DrawingTool = .brush
    @Published var brushSettings = BrushSettings()
    @Published var feedback: String?
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var activeSelection: CGRect? = nil // Active selection rectangle
    @Published var selectionPath: [CGPoint]? = nil // For lasso selection
    @Published var selectionOffset: CGPoint = .zero // Offset for moving selection
    @Published var previewSelection: CGRect? = nil // Preview rectangle while dragging
    @Published var previewLassoPath: [CGPoint]? = nil // Preview lasso path while dragging

    // Selection pixel data (extracted when selection is made)
    var selectionPixels: UIImage? = nil
    var selectionOriginalRect: CGRect? = nil // Original position before moving
    var selectionLayerSnapshot: Data? = nil // Snapshot after clearing selection (for real-time rendering)
    var selectionBeforeSnapshot: Data? = nil // Snapshot before extraction (for history/undo)

    // Transform state for selection
    @Published var selectionScale: CGFloat = 1.0 // Scale factor for selection
    @Published var selectionRotation: Angle = .zero // Rotation angle for selection
    @Published var isTransformingSelection = false // True when dragging transform handles

    // Zoom and Pan state (for canvas navigation)
    @Published var zoomScale: CGFloat = 1.0 // Current zoom level (1.0 = 100%)
    @Published var panOffset: CGPoint = .zero // Current pan offset in screen space
    @Published var canvasRotation: Angle = .zero // Current rotation angle

    // Zoom constraints
    let minZoom: CGFloat = 0.1 // 10% minimum zoom
    let maxZoom: CGFloat = 10.0 // 1000% maximum zoom

    // Rotation settings
    let rotationSnappingInterval: Angle = .degrees(15) // Snap to 15° increments
    var enableRotationSnapping: Bool = true

    let historyManager = HistoryManager()
    // Bridge the nested HistoryManager's ObservableObject changes up to this object so
    // SwiftUI views that read `canvasState.historyManager.canUndo / canRedo` actually
    // re-render when those flags flip. Without this bridge the redo button stayed
    // .disabled(true) even after an undo pushed an action onto the redo stack — the
    // visible symptom of bug 2.1. Retain as a property so the subscription lives as
    // long as the state manager.
    private var historyCancellable: AnyCancellable?
    var renderer: CanvasRenderer?
    private var _screenSize: CGSize = .zero
    var screenSize: CGSize {
        get { return _screenSize }
        set {
            _screenSize = newValue
            // Update canvas size based on new screen size
            if let renderer = renderer {
                renderer.updateCanvasSize(for: newValue)
            }
        }
    }

    // Document size is the coordinate space for stored drawing data
    // DYNAMIC SIZE - the canvas is always a square sized to be bigger than the screen diagonal
    // This ensures no clipping/distortion when the canvas is rotated
    var documentSize: CGSize {
        return renderer?.canvasSize ?? CGSize(width: 2048, height: 2048)
    }
    @Published var hasLoadedExistingImage = false // Track if we've loaded an existing drawing

    var isEmpty: Bool {
        // Canvas is empty if:
        // 1. All layers have nil textures, OR
        // 2. All textures exist but have no history (never been drawn on)
        // IMPORTANT: If we've loaded an existing drawing, we should NOT be empty
        if layers.isEmpty {
            return true
        }

        // If we've loaded an existing image, we're not empty
        if hasLoadedExistingImage {
            return false
        }

        // If there's any history, we have content
        if historyManager.canUndo {
            return false
        }

        // Check if all layers have nil or empty textures
        return layers.allSatisfy { $0.texture == nil }
    }

    init() {
        // Forward nested HistoryManager change notifications. `objectWillChange.send()`
        // must fire on the main actor; we're already @MainActor-isolated, so that's
        // guaranteed for callers that mutate historyManager from the main actor (which
        // all our mutation sites do).
        historyCancellable = historyManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        // Start with one layer
        addLayer()
    }

    func addLayer() {
        let layer = DrawingLayer(name: "Layer \(layers.count + 1)")
        layers.append(layer)
        selectedLayerIndex = layers.count - 1
        print("➕ Added '\(layer.name)' - selectedLayerIndex now = \(selectedLayerIndex), total layers = \(layers.count)")
        historyManager.record(.layerAdded(layer))
    }

    func deleteLayer(at index: Int) {
        guard layers.count > 1, layers.indices.contains(index) else { return }
        let layer = layers[index]
        layers.remove(at: index)
        if selectedLayerIndex >= layers.count {
            selectedLayerIndex = layers.count - 1
        }
        historyManager.record(.layerRemoved(layer, index: index))
    }

    func clearCanvas() {
        layers.removeAll()
        addLayer()
        historyManager.clear()
    }

    func undo() {
        guard let action = historyManager.undo() else { return }

        switch action {
        case .stroke(let layerId, let beforeSnapshot, _):
            // Restore the layer texture to its state before the stroke
            if let layer = layers.first(where: { $0.id == layerId }),
               let texture = layer.texture,
               let renderer = renderer {
                renderer.restoreSnapshot(beforeSnapshot, to: texture)
                print("Undo stroke - restored texture from snapshot (\(beforeSnapshot.count) bytes)")

                // Update thumbnail (avoid Sendable warnings by not capturing directly)
                nonisolated(unsafe) let unsafeRenderer = renderer
                nonisolated(unsafe) let unsafeTexture = texture
                Task.detached {
                    if let thumbnail = unsafeRenderer.generateThumbnail(from: unsafeTexture, size: CGSize(width: 44, height: 44)) {
                        await MainActor.run {
                            if let layer = self.layers.first(where: { $0.id == layerId }) {
                                layer.updateThumbnail(thumbnail)
                            }
                        }
                    }
                }
            }

        case .layerAdded(let layer):
            // Remove the layer
            if let index = layers.firstIndex(where: { $0.id == layer.id }) {
                layers.remove(at: index)
                if selectedLayerIndex >= layers.count {
                    selectedLayerIndex = max(0, layers.count - 1)
                }
            }

        case .layerRemoved(let layer, let index):
            // Re-add the layer
            layers.insert(layer, at: min(index, layers.count))

        case .layerMoved(let from, let to):
            // Move layer back
            let layer = layers.remove(at: to)
            layers.insert(layer, at: from)

        case .layerPropertyChanged(let layerId, let property):
            // Restore old property value
            if let layer = layers.first(where: { $0.id == layerId }) {
                switch property {
                case .opacity(let old, _):
                    layer.opacity = old
                case .name(let old, _):
                    layer.name = old
                case .blendMode(let old, _):
                    layer.blendMode = old
                case .visibility(let old, _):
                    layer.isVisible = old
                }
            }
        }
    }

    func redo() {
        guard let action = historyManager.redo() else { return }

        switch action {
        case .stroke(let layerId, _, let afterSnapshot):
            // Restore the layer texture to its state after the stroke
            if let layer = layers.first(where: { $0.id == layerId }),
               let texture = layer.texture,
               let renderer = renderer {
                renderer.restoreSnapshot(afterSnapshot, to: texture)
                print("Redo stroke - restored texture from snapshot (\(afterSnapshot.count) bytes)")

                // Update thumbnail (avoid Sendable warnings by not capturing directly)
                nonisolated(unsafe) let unsafeRenderer = renderer
                nonisolated(unsafe) let unsafeTexture = texture
                Task.detached {
                    if let thumbnail = unsafeRenderer.generateThumbnail(from: unsafeTexture, size: CGSize(width: 44, height: 44)) {
                        await MainActor.run {
                            if let layer = self.layers.first(where: { $0.id == layerId }) {
                                layer.updateThumbnail(thumbnail)
                            }
                        }
                    }
                }
            }

        case .layerAdded(let layer):
            // Re-add the layer
            layers.append(layer)
            selectedLayerIndex = layers.count - 1

        case .layerRemoved(let layer, _):
            // Remove the layer again
            if let currentIndex = layers.firstIndex(where: { $0.id == layer.id }) {
                layers.remove(at: currentIndex)
                if selectedLayerIndex >= layers.count {
                    selectedLayerIndex = max(0, layers.count - 1)
                }
            }

        case .layerMoved(let from, let to):
            // Move layer forward again
            let layer = layers.remove(at: from)
            layers.insert(layer, at: to)

        case .layerPropertyChanged(let layerId, let property):
            // Apply new property value
            if let layer = layers.first(where: { $0.id == layerId }) {
                switch property {
                case .opacity(_, let new):
                    layer.opacity = new
                case .name(_, let new):
                    layer.name = new
                case .blendMode(_, let new):
                    layer.blendMode = new
                case .visibility(_, let new):
                    layer.isVisible = new
                }
            }
        }
    }

    func exportImage() -> UIImage? {
        // Export all layers as single composited image
        guard let renderer = renderer else {
            print("ERROR: Renderer not available for export")
            return nil
        }
        return renderer.exportImage(layers: layers)
    }

    func renderText(_ text: String, at location: CGPoint) {
        guard selectedLayerIndex < layers.count,
              let texture = layers[selectedLayerIndex].texture else {
            print("ERROR: Cannot render text - invalid layer or texture")
            return
        }

        guard let renderer = renderer else {
            print("ERROR: Renderer not available")
            return
        }

        let fontSize: CGFloat = 32

        // `location` arrives in DOCUMENT space (the touch handler ran it
        // through screenToDocument). The renderer scales by texture/screenSize
        // internally — passing UIKit-points `screenSize` was the source of the
        // ~1.7× double-scale that walked the blit destination off the texture
        // and crashed the app. Pass documentSize so the internal scale is 1:1.
        let beforeSnapshot = renderer.captureSnapshot(of: texture)

        renderer.renderText(
            text,
            at: location,
            fontSize: fontSize,
            color: brushSettings.color,
            to: texture,
            screenSize: documentSize
        )

        let afterSnapshot = renderer.captureSnapshot(of: texture)

        if let before = beforeSnapshot, let after = afterSnapshot {
            let layerId = layers[selectedLayerIndex].id
            historyManager.record(.stroke(
                layerId: layerId,
                beforeSnapshot: before,
                afterSnapshot: after
            ))
        }

        let currentLayerIndex = selectedLayerIndex
        nonisolated(unsafe) let unsafeRenderer = renderer
        nonisolated(unsafe) let unsafeTexture = texture
        Task.detached {
            if let thumbnail = unsafeRenderer.generateThumbnail(from: unsafeTexture, size: CGSize(width: 44, height: 44)) {
                await MainActor.run {
                    if let layer = self.layers.first(where: { $0.id == self.layers[currentLayerIndex].id }) {
                        layer.updateThumbnail(thumbnail)
                    }
                }
            }
        }
    }

    func loadImage(_ image: UIImage) {
        guard let renderer = renderer,
              selectedLayerIndex < layers.count,
              let texture = layers[selectedLayerIndex].texture else {
            print("ERROR: Cannot load image - renderer or layer not available")
            return
        }

        renderer.loadImage(image, into: texture)

        // IMPORTANT: Mark that we've loaded an existing image so buttons enable
        hasLoadedExistingImage = true
        print("  - hasLoadedExistingImage set to true (buttons should now be enabled)")

        // Update thumbnail
        nonisolated(unsafe) let unsafeRenderer = renderer
        nonisolated(unsafe) let unsafeTexture = texture
        let layerId = layers[selectedLayerIndex].id
        Task.detached {
            if let thumbnail = unsafeRenderer.generateThumbnail(from: unsafeTexture, size: CGSize(width: 44, height: 44)) {
                await MainActor.run {
                    if let layer = self.layers.first(where: { $0.id == layerId }) {
                        layer.updateThumbnail(thumbnail)
                    }
                }
            }
        }
    }

    /// Import a photo onto a brand-new layer, sized aspect-fit and centered
    /// on the document. The user can reposition with the Move tool.
    /// (Corner scale/rotate handles are deferred — see audit doc.)
    func importImage(_ image: UIImage) {
        guard let renderer = renderer else {
            print("ERROR: Cannot import image - renderer not ready")
            return
        }

        addLayer()
        guard selectedLayerIndex < layers.count else {
            print("ERROR: Cannot import image - selectedLayerIndex out of range")
            return
        }

        // `addLayer` only appends the DrawingLayer; texture creation is lazy
        // inside MetalCanvasView.Coordinator.ensureLayerTextures(), which
        // only runs during a Metal draw cycle. We're synchronously about to
        // render into this layer, so the texture must exist NOW — otherwise
        // the guard below fails silently and the imported image vanishes.
        // (That was the "image import broken" symptom.)
        if layers[selectedLayerIndex].texture == nil {
            layers[selectedLayerIndex].texture = renderer.createLayerTexture()
        }
        guard let texture = layers[selectedLayerIndex].texture else {
            print("ERROR: Cannot import image - failed to create texture")
            return
        }

        // Aspect-fit the image into ~80% of the document
        let docW = documentSize.width
        let docH = documentSize.height
        let imgW = image.size.width
        let imgH = image.size.height
        guard imgW > 0, imgH > 0 else { return }

        let maxW = docW * 0.8
        let maxH = docH * 0.8
        let scale = min(maxW / imgW, maxH / imgH)
        let drawW = imgW * scale
        let drawH = imgH * scale
        let rect = CGRect(
            x: (docW - drawW) / 2,
            y: (docH - drawH) / 2,
            width: drawW,
            height: drawH
        )

        renderer.renderImage(image, at: rect, to: texture, screenSize: documentSize)
        hasLoadedExistingImage = true

        nonisolated(unsafe) let unsafeRenderer = renderer
        nonisolated(unsafe) let unsafeTexture = texture
        let layerId = layers[selectedLayerIndex].id
        Task.detached {
            if let thumbnail = unsafeRenderer.generateThumbnail(from: unsafeTexture, size: CGSize(width: 44, height: 44)) {
                await MainActor.run {
                    if let layer = self.layers.first(where: { $0.id == layerId }) {
                        layer.updateThumbnail(thumbnail)
                    }
                }
            }
        }

        print("📷 Imported image into new layer at \(rect)")
    }

    func requestFeedback(for context: DrawingContext) async {
        guard let image = exportImage() else {
            showError(message: "Failed to export drawing")
            return
        }

        do {
            let feedbackText = try await OpenAIManager.shared.requestFeedback(
                image: image,
                context: context
            )
            feedback = feedbackText
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    private func showError(message: String) {
        errorMessage = message
        showError = true
    }

    // MARK: - Selection Management

    func clearSelection() {
        activeSelection = nil
        selectionPath = nil
        selectionPixels = nil
        selectionOriginalRect = nil
        selectionLayerSnapshot = nil
        selectionBeforeSnapshot = nil
        selectionOffset = .zero
        previewSelection = nil
        previewLassoPath = nil
        selectionScale = 1.0
        selectionRotation = .zero
        isTransformingSelection = false
    }

    func deleteSelectedPixels() {
        guard selectedLayerIndex < layers.count,
              let texture = layers[selectedLayerIndex].texture,
              let renderer = renderer else {
            print("ERROR: Cannot delete selection - invalid layer or texture")
            return
        }

        // Capture before snapshot
        let beforeSnapshot = renderer.captureSnapshot(of: texture)

        // Delete pixels in selection (use documentSize for 1:1 coordinate mapping)
        if let rect = activeSelection {
            renderer.clearRect(rect, in: texture, screenSize: documentSize)
        } else if let path = selectionPath {
            renderer.clearPath(path, in: texture, screenSize: documentSize)
        }

        // Capture after snapshot
        let afterSnapshot = renderer.captureSnapshot(of: texture)

        // Record in history
        if let before = beforeSnapshot, let after = afterSnapshot {
            let layerId = layers[selectedLayerIndex].id
            historyManager.record(.stroke(
                layerId: layerId,
                beforeSnapshot: before,
                afterSnapshot: after
            ))
        }

        // Update thumbnail
        let currentLayerIndex = selectedLayerIndex
        nonisolated(unsafe) let unsafeRenderer = renderer
        nonisolated(unsafe) let unsafeTexture = texture
        Task.detached {
            if let thumbnail = unsafeRenderer.generateThumbnail(from: unsafeTexture, size: CGSize(width: 44, height: 44)) {
                await MainActor.run {
                    if let layer = self.layers.first(where: { $0.id == self.layers[currentLayerIndex].id }) {
                        layer.updateThumbnail(thumbnail)
                    }
                }
            }
        }

        // Clear selection after deleting
        clearSelection()
    }

    /// Extract pixels from the selection and store them for moving
    /// IMPORTANT: This captures snapshots and immediately clears the original pixels for fluent real-time movement
    func extractSelectionPixels() {
        guard selectedLayerIndex < layers.count,
              let texture = layers[selectedLayerIndex].texture,
              let renderer = renderer else {
            print("ERROR: Cannot extract selection - invalid layer or texture")
            return
        }

        // Capture "before" snapshot for history (BEFORE any modifications)
        selectionBeforeSnapshot = renderer.captureSnapshot(of: texture)

        if let rect = activeSelection {
            // Extract pixels from rectangular selection
            // IMPORTANT: rect is in document space, so pass documentSize for 1:1 coordinate mapping
            selectionPixels = renderer.extractPixels(from: rect, in: texture, screenSize: documentSize)
            selectionOriginalRect = rect
            selectionOffset = .zero

            // Verify extraction succeeded
            if selectionPixels == nil {
                print("❌ ERROR: Failed to extract rectangular selection")
                print("  Rect: \(rect), Texture: \(texture.width)x\(texture.height), Document: \(documentSize)")
                clearSelection() // Clear invalid selection
            } else {
                // IMMEDIATELY clear the original pixels - they'll be rendered at the new position in real-time
                renderer.clearRect(rect, in: texture, screenSize: documentSize)
                // Capture snapshot AFTER clearing - this is the "base layer with hole" for real-time rendering
                selectionLayerSnapshot = renderer.captureSnapshot(of: texture)
                print("✂️ Extracted rectangular selection: \(rect) and cleared original")
            }
        } else if let path = selectionPath {
            // Validate path has enough points
            guard path.count >= 3 else {
                print("❌ ERROR: Lasso path too short (\(path.count) points), cannot extract")
                clearSelection() // Clear invalid selection
                return
            }

            // For lasso, find bounding box and extract with mask
            let boundingRect = calculateBoundingRect(for: path)

            // Validate bounding rect is not empty/invalid
            guard boundingRect.width > 0 && boundingRect.height > 0 else {
                print("❌ ERROR: Invalid lasso selection bounding rect: \(boundingRect)")
                clearSelection() // Clear invalid selection
                return
            }

            // IMPORTANT: path is in document space, so pass documentSize for 1:1 coordinate mapping
            selectionPixels = renderer.extractPixels(fromPath: path, in: texture, screenSize: documentSize)
            selectionOriginalRect = boundingRect
            selectionOffset = .zero

            // Verify extraction succeeded
            if selectionPixels == nil {
                print("❌ ERROR: Failed to extract lasso selection")
                print("  Bounding rect: \(boundingRect), Texture: \(texture.width)x\(texture.height), Document: \(documentSize)")
                clearSelection() // Clear invalid selection
            } else {
                // IMMEDIATELY clear the original pixels - they'll be rendered at the new position in real-time
                renderer.clearPath(path, in: texture, screenSize: documentSize)
                // Capture snapshot AFTER clearing - this is the "base layer with hole" for real-time rendering
                selectionLayerSnapshot = renderer.captureSnapshot(of: texture)
                print("✂️ Extracted lasso selection, bounding rect: \(boundingRect) and cleared original")
            }
        }
    }

    /// Render selection pixels in real-time during drag
    /// This provides fluent animation by rendering directly to the texture as the user drags
    func renderSelectionInRealTime() {
        guard selectedLayerIndex < layers.count,
              let texture = layers[selectedLayerIndex].texture,
              let renderer = renderer,
              let pixels = selectionPixels,
              let originalRect = selectionOriginalRect,
              let snapshot = selectionLayerSnapshot else {
            return
        }

        // Step 1: Restore the base layer (with hole where selection was) from snapshot
        renderer.restoreSnapshot(snapshot, to: texture)

        // Step 2: Calculate the current position with offset and scale applied
        let currentRect = CGRect(
            x: originalRect.origin.x + selectionOffset.x,
            y: originalRect.origin.y + selectionOffset.y,
            width: originalRect.width * selectionScale,
            height: originalRect.height * selectionScale
        )

        // Step 3: Render the pixels at the new position (use documentSize for 1:1 coordinate mapping)
        renderer.renderImage(pixels, at: currentRect, to: texture, screenSize: documentSize)
    }

    /// Commit the moved selection to finalize the change
    /// Render the selection pixels to texture at their final position
    func commitSelection() {
        guard selectedLayerIndex < layers.count,
              let texture = layers[selectedLayerIndex].texture,
              let renderer = renderer,
              let beforeSnapshot = selectionBeforeSnapshot else {
            print("ERROR: Cannot commit selection - missing data")
            return
        }

        // IMPORTANT: Render selection pixels to texture at final position one last time
        // During drag, pixels were rendered in real-time synchronously on every touch event
        // This final render ensures the texture has the pixels at their final position
        renderSelectionInRealTime()

        // Capture the current state as "after" for history
        let afterSnapshot = renderer.captureSnapshot(of: texture)

        // Record in history (before = original with pixels, after = current with pixels moved)
        if let after = afterSnapshot {
            let layerId = layers[selectedLayerIndex].id
            historyManager.record(.stroke(
                layerId: layerId,
                beforeSnapshot: beforeSnapshot,
                afterSnapshot: after
            ))
        }

        // Update thumbnail
        let currentLayerIndex = selectedLayerIndex
        nonisolated(unsafe) let unsafeRenderer = renderer
        nonisolated(unsafe) let unsafeTexture = texture
        Task.detached {
            if let thumbnail = unsafeRenderer.generateThumbnail(from: unsafeTexture, size: CGSize(width: 44, height: 44)) {
                await MainActor.run {
                    if let layer = self.layers.first(where: { $0.id == self.layers[currentLayerIndex].id }) {
                        layer.updateThumbnail(thumbnail)
                    }
                }
            }
        }

        // Clear all selection data (pixels, rects, previews, etc.)
        clearSelection()
        print("✅ Selection committed to texture")
    }

    /// Apply scale and rotation transforms to a UIImage
    private func applyTransforms(to image: UIImage, scale: CGFloat, rotation: Angle) -> UIImage {
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        UIGraphicsBeginImageContextWithOptions(size, false, image.scale)
        defer { UIGraphicsEndImageContext() }

        guard let context = UIGraphicsGetCurrentContext() else { return image }

        // Move to center
        context.translateBy(x: size.width / 2, y: size.height / 2)

        // Apply rotation
        context.rotate(by: CGFloat(rotation.radians))

        // Draw image centered
        let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        image.draw(in: rect)

        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }

    /// Calculate bounding rectangle for a path
    func calculateBoundingRect(for path: [CGPoint]) -> CGRect {
        guard !path.isEmpty else { return .zero }

        var minX = path[0].x
        var minY = path[0].y
        var maxX = path[0].x
        var maxY = path[0].y

        for point in path {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Zoom and Pan Management

    // MARK: - Coordinate transforms
    //
    // These must be the exact inverse of the shader's vertex transform in
    // `quadVertexShaderWithTransform`. The shader does (pseudocode):
    //
    //   quadCornerNDC → aspectScaled → screenPos (Y-up pixels)
    //                 → zoomAroundCenter → rotateAroundCenter → screenPos += (pan.x, -pan.y)
    //                 → NDC
    //
    // With identity texCoords, every screen pixel inside the quad samples the
    // texture at the fraction of the quad it falls in. The math below is the
    // UIKit-space (Y-down) inverse of that pipeline. A single-number scale
    // `fitSize = min(viewport.w, viewport.h)` replaces the previous separate
    // aspectScale + canvasScale steps that were overshooting by 1/aspect.
    //
    // The previous implementation overshot doc coords by a factor of the
    // viewport aspect ratio on the longer axis — e.g. touching the right edge
    // of a pillarbox in landscape returned doc.x ≈ 2390 instead of 2048. That
    // was the "strokes offset consistently" symptom after Phase-1 fixes.

    /// Transform a point from view/screen space (UIKit points) to document space.
    func screenToDocument(_ point: CGPoint) -> CGPoint {
        guard point.x.isFinite, point.y.isFinite,
              screenSize.width > 0, screenSize.height > 0,
              documentSize.width > 0, documentSize.height > 0,
              zoomScale.isFinite, zoomScale > 0,
              panOffset.x.isFinite, panOffset.y.isFinite,
              canvasRotation.radians.isFinite else {
            return .zero
        }

        let fitSize = max(screenSize.width, screenSize.height)
        let centerX = screenSize.width / 2
        let centerY = screenSize.height / 2

        // Inverse pan, then translate so (0,0) is the viewport center.
        var pt = CGPoint(x: point.x - panOffset.x - centerX,
                         y: point.y - panOffset.y - centerY)

        // Inverse rotation. The shader applies R(θ) in Y-up pixel space, which
        // reads as a visual CCW rotation by θ on screen. In UIKit Y-down math,
        // the forward matrix that produces visual CCW is R(-θ); the inverse is
        // therefore R(+θ) applied directly to Y-down coords:
        //   x' = x·cos(θ) - y·sin(θ)
        //   y' = x·sin(θ) + y·cos(θ)
        // The previous version had the signs of sinT swapped, which was the
        // cause of strokes "jumping" once any rotation was applied — my
        // screenToDocument was winding the point the wrong way.
        let theta = canvasRotation.radians
        let cosT = cos(theta)
        let sinT = sin(theta)
        let rx = pt.x * cosT - pt.y * sinT
        let ry = pt.x * sinT + pt.y * cosT

        // Inverse zoom (around viewport center, which is (0,0) here).
        let zx = rx / zoomScale
        let zy = ry / zoomScale

        // At this point (zx, zy) is the quad-local coordinate centered at origin,
        // ranging over [-fitSize/2, +fitSize/2] when the touch is inside the
        // aspect-corrected canvas region. Convert to normalized [0,1] fraction
        // and scale by document size.
        let fracX = (zx + fitSize / 2) / fitSize
        let fracY = (zy + fitSize / 2) / fitSize

        return CGPoint(x: fracX * documentSize.width,
                       y: fracY * documentSize.height)
    }

    /// Transform a point from document space to view/screen space (UIKit points).
    func documentToScreen(_ point: CGPoint) -> CGPoint {
        guard point.x.isFinite, point.y.isFinite,
              screenSize.width > 0, screenSize.height > 0,
              documentSize.width > 0, documentSize.height > 0,
              zoomScale.isFinite, zoomScale > 0,
              panOffset.x.isFinite, panOffset.y.isFinite,
              canvasRotation.radians.isFinite else {
            return .zero
        }

        let fitSize = max(screenSize.width, screenSize.height)
        let centerX = screenSize.width / 2
        let centerY = screenSize.height / 2

        // doc → normalized fraction → quad-local (centered) pixels.
        let fracX = point.x / documentSize.width
        let fracY = point.y / documentSize.height
        var pt = CGPoint(x: fracX * fitSize - fitSize / 2,
                         y: fracY * fitSize - fitSize / 2)

        // Zoom around origin (viewport center).
        pt.x *= zoomScale
        pt.y *= zoomScale

        // Rotate around origin. The shader rotates the quad visually CCW by θ
        // (it applies R(θ) in Y-up pixel space). To reproduce visual CCW in
        // UIKit Y-down, apply R(-θ):
        //   x' =  x·cos(θ) + y·sin(θ)
        //   y' = -x·sin(θ) + y·cos(θ)
        let theta = canvasRotation.radians
        let cosT = cos(theta)
        let sinT = sin(theta)
        let rx = pt.x * cosT + pt.y * sinT
        let ry = -pt.x * sinT + pt.y * cosT

        // Translate to viewport center, then apply pan.
        return CGPoint(x: rx + centerX + panOffset.x,
                       y: ry + centerY + panOffset.y)
    }

    /// Apply zoom. `centerPoint` is the pinch location in screen space; currently only
    /// used for future zoom-around-point restoration.
    ///
    /// The previous implementation tried to adjust `panOffset` so the document point
    /// under `centerPoint` stayed fixed, but its math mixed document coordinates with
    /// screen coordinates:
    ///
    ///     panOffset += centerPoint − docPoint * zoomScale
    ///
    /// `docPoint` lives in a 0…2048 document-space range while `centerPoint` lives in a
    /// ~0…1366 screen-space range, so `centerPoint − docPoint*zoomScale` produced
    /// arbitrary values that, reapplied every frame at 60 Hz, grew `panOffset`
    /// roughly geometrically. This was the cause of the 10^48 → 10^121 coordinate
    /// explosion after any pinch on device.
    ///
    /// For now zoom happens around the screen center (no pan compensation). Zoom-to-
    /// pinch-point can be restored later with correct aspect/rotation-aware math.
    func zoom(scale: CGFloat, centerPoint: CGPoint) {
        guard scale.isFinite, scale > 0 else { return }
        guard centerPoint.x.isFinite, centerPoint.y.isFinite else { return }

        let newScale = min(max(scale, minZoom), maxZoom)
        guard newScale.isFinite, newScale > 0 else { return }

        zoomScale = newScale
    }

    /// Pan the canvas by a delta in screen space.
    func pan(delta: CGPoint) {
        guard delta.x.isFinite, delta.y.isFinite else { return }

        panOffset.x += delta.x
        panOffset.y += delta.y

        // Hard clamp so a corrupted frame can't push panOffset to infinity. With a
        // 2048-pt canvas and max 10× zoom, legitimate pan stays well inside ±2×
        // document size; anything past that is runaway state.
        let maxPan = 2 * max(documentSize.width, documentSize.height)
        panOffset.x = min(max(panOffset.x, -maxPan), maxPan)
        panOffset.y = min(max(panOffset.y, -maxPan), maxPan)
    }

    /// Rotate the canvas by an angle increment.
    func rotate(by angle: Angle, snapToGrid: Bool = true) {
        guard angle.radians.isFinite else { return }
        // Prevent rotation if change is negligible
        guard abs(angle.degrees) > 0.1 else { return }

        var newRotation = canvasRotation + angle

        // Normalize to 0-360° to prevent overflow
        newRotation = .degrees(newRotation.degrees.truncatingRemainder(dividingBy: 360))
        if newRotation.degrees < 0 {
            newRotation = .degrees(newRotation.degrees + 360)
        }

        // Snap to grid if enabled (typically only on gesture .ended; passing true here
        // during continuous rotation causes per-frame 15° ratcheting — see the gesture
        // handler comment for the bug this avoids).
        if snapToGrid && enableRotationSnapping {
            let snappedDegrees = round(newRotation.degrees / rotationSnappingInterval.degrees) * rotationSnappingInterval.degrees
            newRotation = .degrees(snappedDegrees)
        }

        canvasRotation = newRotation
    }

    /// Reset rotation to 0°
    func resetRotation() {
        canvasRotation = .zero
    }

    /// Reset zoom, pan, and rotation to defaults
    func resetZoomAndPan() {
        zoomScale = 1.0
        panOffset = .zero
        canvasRotation = .zero
    }

    /// Reset all transforms
    func resetAllTransforms() {
        resetZoomAndPan()
    }

    /// Transform a rectangle from document space to screen space
    /// For rotated canvases, returns the bounding box of the transformed corners
    func documentRectToScreen(_ rect: CGRect) -> CGRect {
        // Transform all four corners
        let topLeft = documentToScreen(CGPoint(x: rect.minX, y: rect.minY))
        let topRight = documentToScreen(CGPoint(x: rect.maxX, y: rect.minY))
        let bottomLeft = documentToScreen(CGPoint(x: rect.minX, y: rect.maxY))
        let bottomRight = documentToScreen(CGPoint(x: rect.maxX, y: rect.maxY))

        // Find bounding box of transformed corners
        let minX = min(topLeft.x, topRight.x, bottomLeft.x, bottomRight.x)
        let minY = min(topLeft.y, topRight.y, bottomLeft.y, bottomRight.y)
        let maxX = max(topLeft.x, topRight.x, bottomLeft.x, bottomRight.x)
        let maxY = max(topLeft.y, topRight.y, bottomLeft.y, bottomRight.y)

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Transform a path from document space to screen space
    func documentPathToScreen(_ path: [CGPoint]) -> [CGPoint] {
        return path.map { documentToScreen($0) }
    }
}
