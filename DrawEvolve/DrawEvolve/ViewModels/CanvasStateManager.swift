//
//  CanvasStateManager.swift
//  DrawEvolve
//
//  Manages canvas state including layers, tools, selection, zoom/pan, and history
//

import Foundation
import SwiftUI
import UIKit

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
    var renderer: CanvasRenderer?
    var screenSize: CGSize = .zero // Current viewport/screen size

    // Document size is the coordinate space for stored drawing data
    // FIXED SIZE - the canvas is always square, like a piece of paper
    // The screen size can change (rotation), but the canvas never changes
    var documentSize: CGSize {
        return CGSize(width: 2048, height: 2048)
    }
    var hasLoadedExistingImage = false // Track if we've loaded an existing drawing

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

        renderer.renderText(
            text,
            at: location,
            fontSize: fontSize,
            color: brushSettings.color,
            to: texture,
            screenSize: screenSize
        )
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

        // Delete pixels in selection
        if let rect = activeSelection {
            renderer.clearRect(rect, in: texture, screenSize: screenSize)
        } else if let path = selectionPath {
            renderer.clearPath(path, in: texture, screenSize: screenSize)
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
            selectionPixels = renderer.extractPixels(from: rect, in: texture, screenSize: screenSize)
            selectionOriginalRect = rect
            selectionOffset = .zero

            // Verify extraction succeeded
            if selectionPixels == nil {
                print("❌ ERROR: Failed to extract rectangular selection")
                clearSelection() // Clear invalid selection
            } else {
                // IMMEDIATELY clear the original pixels - they'll be rendered at the new position in real-time
                renderer.clearRect(rect, in: texture, screenSize: screenSize)
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

            selectionPixels = renderer.extractPixels(fromPath: path, in: texture, screenSize: screenSize)
            selectionOriginalRect = boundingRect
            selectionOffset = .zero

            // Verify extraction succeeded
            if selectionPixels == nil {
                print("❌ ERROR: Failed to extract lasso selection")
                clearSelection() // Clear invalid selection
            } else {
                // IMMEDIATELY clear the original pixels - they'll be rendered at the new position in real-time
                renderer.clearPath(path, in: texture, screenSize: screenSize)
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

        // Step 3: Render the pixels at the new position
        renderer.renderImage(pixels, at: currentRect, to: texture, screenSize: screenSize)
    }

    /// Commit the moved selection to finalize the change
    /// With real-time rendering, pixels are already at their final position, so we just record history
    func commitSelection() {
        guard selectedLayerIndex < layers.count,
              let texture = layers[selectedLayerIndex].texture,
              let renderer = renderer,
              let beforeSnapshot = selectionBeforeSnapshot else {
            print("ERROR: Cannot commit selection - missing data")
            return
        }

        // Pixels are already rendered at final position by real-time rendering
        // Just capture the current state as "after" for history
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

    /// Transform a point from view/screen space to document space (accounting for zoom, pan, and rotation)
    func screenToDocument(_ point: CGPoint) -> CGPoint {
        // Screen center (viewport - changes with rotation)
        let screenCenterX = screenSize.width / 2
        let screenCenterY = screenSize.height / 2

        // Document center (fixed - never changes)
        let docCenterX = documentSize.width / 2
        let docCenterY = documentSize.height / 2

        // Step 1: Remove pan (screen space)
        var pt = CGPoint(
            x: point.x - panOffset.x,
            y: point.y - panOffset.y
        )

        // Step 2: Translate to screen origin
        pt.x -= screenCenterX
        pt.y -= screenCenterY

        // Step 3: Apply inverse rotation
        let angle = -canvasRotation.radians
        let cosAngle = cos(angle)
        let sinAngle = sin(angle)
        let rotatedX = pt.x * cosAngle - pt.y * sinAngle
        let rotatedY = pt.x * sinAngle + pt.y * cosAngle

        // Step 4: Apply inverse zoom
        pt.x = rotatedX / zoomScale
        pt.y = rotatedY / zoomScale

        // Step 5: Translate to document center (map to fixed canvas space)
        pt.x += docCenterX
        pt.y += docCenterY

        return pt
    }

    /// Transform a point from document space to view/screen space (applying zoom, pan, and rotation)
    func documentToScreen(_ point: CGPoint) -> CGPoint {
        // Screen center (viewport - changes with rotation)
        let screenCenterX = screenSize.width / 2
        let screenCenterY = screenSize.height / 2

        // Document center (fixed - never changes)
        let docCenterX = documentSize.width / 2
        let docCenterY = documentSize.height / 2

        // Step 1: Translate to document origin
        var pt = CGPoint(
            x: point.x - docCenterX,
            y: point.y - docCenterY
        )

        // Step 2: Apply zoom
        pt.x *= zoomScale
        pt.y *= zoomScale

        // Step 3: Apply rotation
        let angle = canvasRotation.radians
        let cosAngle = cos(angle)
        let sinAngle = sin(angle)
        let rotatedX = pt.x * cosAngle - pt.y * sinAngle
        let rotatedY = pt.x * sinAngle + pt.y * cosAngle

        // Step 4: Translate to screen center and apply pan
        pt = CGPoint(
            x: rotatedX + screenCenterX + panOffset.x,
            y: rotatedY + screenCenterY + panOffset.y
        )

        return pt
    }

    /// Apply zoom centered at a specific point in screen space
    func zoom(scale: CGFloat, centerPoint: CGPoint) {
        // Clamp the new scale to min/max bounds
        let newScale = min(max(scale, minZoom), maxZoom)

        // Calculate the document-space point that should remain fixed
        let docPoint = screenToDocument(centerPoint)

        // Update the zoom scale
        zoomScale = newScale

        // Adjust pan offset so the document point stays at the same screen position
        let newScreenPoint = CGPoint(x: docPoint.x * zoomScale, y: docPoint.y * zoomScale)
        panOffset.x += centerPoint.x - newScreenPoint.x
        panOffset.y += centerPoint.y - newScreenPoint.y
    }

    /// Pan the canvas by a delta in screen space
    func pan(delta: CGPoint) {
        panOffset.x += delta.x
        panOffset.y += delta.y
    }

    /// Rotate the canvas by an angle increment
    func rotate(by angle: Angle, snapToGrid: Bool = true) {
        // Prevent rotation if change is negligible
        guard abs(angle.degrees) > 0.1 else { return }

        var newRotation = canvasRotation + angle

        // Normalize to 0-360° to prevent overflow
        newRotation = .degrees(newRotation.degrees.truncatingRemainder(dividingBy: 360))
        if newRotation.degrees < 0 {
            newRotation = .degrees(newRotation.degrees + 360)
        }

        // Snap to grid if enabled
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
