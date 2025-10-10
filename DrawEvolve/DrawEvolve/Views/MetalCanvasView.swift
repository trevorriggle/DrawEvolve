//
//  MetalCanvasView.swift
//  DrawEvolve
//
//  Metal-powered canvas with layer support and pressure sensitivity.
//

import SwiftUI
import MetalKit
import UIKit

// Custom MTKView that forwards touches
class TouchEnabledMTKView: MTKView {
    weak var touchDelegate: TouchHandling?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("TouchEnabledMTKView: touchesBegan received \(touches.count) touches")
        super.touchesBegan(touches, with: event)
        if let delegate = touchDelegate {
            print("TouchEnabledMTKView: Forwarding to delegate")
            delegate.touchesBegan(touches, in: self)
        } else {
            print("TouchEnabledMTKView: WARNING - No touch delegate!")
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        touchDelegate?.touchesMoved(touches, in: self)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("TouchEnabledMTKView: touchesEnded received")
        super.touchesEnded(touches, with: event)
        touchDelegate?.touchesEnded(touches, in: self)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("TouchEnabledMTKView: touchesCancelled received")
        super.touchesCancelled(touches, with: event)
        touchDelegate?.touchesCancelled(touches, in: self)
    }
}

protocol TouchHandling: AnyObject {
    func touchesBegan(_ touches: Set<UITouch>, in view: MTKView)
    func touchesMoved(_ touches: Set<UITouch>, in view: MTKView)
    func touchesEnded(_ touches: Set<UITouch>, in view: MTKView)
    func touchesCancelled(_ touches: Set<UITouch>, in view: MTKView)
}

struct MetalCanvasView: UIViewRepresentable {
    @Binding var layers: [DrawingLayer]
    @Binding var currentTool: DrawingTool
    @Binding var brushSettings: BrushSettings
    @Binding var selectedLayerIndex: Int

    var canvasState: CanvasStateManager? // For sharing renderer/screen size
    var onTextRequest: ((CGPoint) -> Void)? // Callback for text tool

    func makeUIView(context: Context) -> MTKView {
        let metalView = TouchEnabledMTKView()

        print("MetalCanvasView: Creating MTKView")

        guard let device = MTLCreateSystemDefaultDevice() else {
            print("MetalCanvasView: FATAL - Metal not supported!")
            // Return a basic view that just shows white instead of crashing
            metalView.backgroundColor = .white
            return metalView
        }

        print("MetalCanvasView: Metal device created: \(device.name)")

        metalView.device = device
        metalView.delegate = context.coordinator
        metalView.enableSetNeedsDisplay = false  // Use continuous drawing mode
        metalView.isPaused = false  // Continuous updates at preferredFramesPerSecond
        metalView.framebufferOnly = false  // Allow texture readback
        metalView.clearColor = MTLClearColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)  // Light gray to see canvas
        metalView.backgroundColor = .systemGray6  // Light gray background
        metalView.preferredFramesPerSecond = 60  // Smooth drawing at 60fps

        // Enable multi-touch and pencil input
        metalView.isMultipleTouchEnabled = true

        // CRITICAL: Enable user interaction so touches are received
        metalView.isUserInteractionEnabled = true

        // Connect touch events to coordinator
        metalView.touchDelegate = context.coordinator

        print("MetalCanvasView: MTKView configured successfully")

        return metalView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // IMPORTANT: Don't modify @Binding values here - causes infinite loop!
        // Coordinator already has access to bindings via init

        // Just trigger a redraw when something changes
        uiView.setNeedsDisplay()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            layers: $layers,
            currentTool: $currentTool,
            brushSettings: $brushSettings,
            selectedLayerIndex: $selectedLayerIndex,
            canvasState: canvasState,
            onTextRequest: onTextRequest
        )
    }

    class Coordinator: NSObject, MTKViewDelegate, TouchHandling {
        @Binding var layers: [DrawingLayer]
        @Binding var currentTool: DrawingTool
        @Binding var brushSettings: BrushSettings
        @Binding var selectedLayerIndex: Int

        private var renderer: CanvasRenderer?
        private var currentStroke: BrushStroke?
        private var lastPoint: CGPoint?
        private var lastTimestamp: TimeInterval = 0
        private var shapeStartPoint: CGPoint? // For shape tools
        private var lassoPath: [CGPoint] = [] // For lasso selection
        private var canvasState: CanvasStateManager?
        private var onTextRequest: ((CGPoint) -> Void)?

        init(
            layers: Binding<[DrawingLayer]>,
            currentTool: Binding<DrawingTool>,
            brushSettings: Binding<BrushSettings>,
            selectedLayerIndex: Binding<Int>,
            canvasState: CanvasStateManager?,
            onTextRequest: ((CGPoint) -> Void)?
        ) {
            _layers = layers
            _currentTool = currentTool
            _brushSettings = brushSettings
            _selectedLayerIndex = selectedLayerIndex
            self.canvasState = canvasState
            self.onTextRequest = onTextRequest

            print("Coordinator: Initialized with \(layers.wrappedValue.count) layers")
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Handle view size changes
        }

        func draw(in view: MTKView) {
            guard let device = view.device,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor else {
                print("MetalCanvasView.draw: Failed to get device/drawable/descriptor")
                return
            }

            // Initialize renderer if needed
            if renderer == nil {
                print("MetalCanvasView.draw: Initializing renderer")
                renderer = CanvasRenderer(metalDevice: device)

                // Share renderer and screen size with canvas state (for text rendering)
                if let canvasState = canvasState {
                    canvasState.renderer = renderer
                    canvasState.screenSize = view.bounds.size
                    print("MetalCanvasView.draw: Shared renderer with canvas state, screen size: \(view.bounds.size)")
                }
            }

            // Ensure textures exist (only runs once)
            ensureLayerTextures()

            guard let commandQueue = device.makeCommandQueue(),
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            // Composite all visible layers to screen
            for layer in layers where layer.isVisible {
                if let texture = layer.texture {
                    renderer?.renderTextureToScreen(texture, to: renderEncoder, opacity: layer.opacity)
                }
            }

            // IMPORTANT: Render current stroke preview on top
            // Use bounds.size (screen space) for preview, matching touch coordinates
            if let stroke = currentStroke, !stroke.points.isEmpty {
                renderer?.renderStrokePreview(stroke, to: renderEncoder, viewportSize: view.bounds.size)
            }

            renderEncoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        func ensureLayerTextures() {
            guard let renderer = renderer else { return }

            // ALWAYS check all layers, not just on first run
            // This ensures new layers get textures when added
            var createdCount = 0
            for i in 0..<layers.count {
                if layers[i].texture == nil {
                    layers[i].texture = renderer.createLayerTexture()
                    createdCount += 1
                    print("Created texture for layer \(i): \(layers[i].name)")
                }
            }

            if createdCount > 0 {
                print("ensureLayerTextures: Created \(createdCount) new textures, total layers: \(layers.count)")
            }
        }

        // Touch handling for drawing
        func touchesBegan(_ touches: Set<UITouch>, in view: MTKView) {
            print("=== TOUCH BEGAN ===")
            guard let touch = touches.first else {
                print("ERROR: No touch in set")
                return
            }

            // Ensure layer textures exist
            ensureLayerTextures()

            let location = touch.location(in: view)
            let pressure = touch.type == .pencil ? (touch.force > 0 ? touch.force / touch.maximumPossibleForce : 1.0) : 1.0
            let timestamp = touch.timestamp

            print("Touch began at \(location) with pressure \(pressure), tool: \(currentTool)")
            print("Selected layer: \(selectedLayerIndex), total layers: \(layers.count)")
            print("Layer has texture: \(layers[safe: selectedLayerIndex]?.texture != nil)")

            // Handle text tool - show text input dialog
            if currentTool == .text {
                print("Text tool: requesting text input at \(location)")
                onTextRequest?(location)
                return
            }

            // Handle paint bucket tool - flood fill
            if currentTool == .paintBucket {
                print("Paint bucket: filling at \(location)")
                guard selectedLayerIndex < layers.count,
                      let texture = layers[selectedLayerIndex].texture,
                      let renderer = renderer else {
                    print("ERROR: Cannot fill - invalid layer or texture")
                    return
                }

                // Capture before snapshot
                let beforeSnapshot = renderer.captureSnapshot(of: texture)

                // Perform flood fill
                renderer.floodFill(at: location, with: brushSettings.color, in: texture, screenSize: view.bounds.size)

                // Capture after snapshot
                let afterSnapshot = renderer.captureSnapshot(of: texture)

                // Record in history
                if let before = beforeSnapshot, let after = afterSnapshot, let canvasState = canvasState {
                    let layerId = layers[selectedLayerIndex].id
                    Task { @MainActor in
                        canvasState.historyManager.record(.stroke(
                            layerId: layerId,
                            beforeSnapshot: before,
                            afterSnapshot: after
                        ))
                    }
                }

                // Update thumbnail
                let currentLayerIndex = selectedLayerIndex
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    if let thumbnail = renderer.generateThumbnail(from: texture, size: CGSize(width: 44, height: 44)) {
                        DispatchQueue.main.async {
                            self?.layers[currentLayerIndex].updateThumbnail(thumbnail)
                        }
                    }
                }

                return
            }

            // Handle eyedropper tool - pick color from canvas
            if currentTool == .eyeDropper {
                print("Eyedropper: picking color at \(location)")
                guard selectedLayerIndex < layers.count,
                      let texture = layers[selectedLayerIndex].texture,
                      let renderer = renderer else {
                    print("ERROR: Cannot pick color - invalid layer or texture")
                    return
                }

                // Read pixel color at location
                if let pickedColor = getColorAt(location, in: texture, screenSize: view.bounds.size) {
                    // Update brush color
                    brushSettings.color = pickedColor
                    print("Picked color: \(pickedColor)")
                }

                return
            }

            // Handle blur tool - apply blur effect on tap/drag
            if currentTool == .blur {
                print("Blur: applying blur at \(location)")
                guard selectedLayerIndex < layers.count,
                      let texture = layers[selectedLayerIndex].texture,
                      let renderer = renderer else {
                    print("ERROR: Cannot apply blur - invalid layer or texture")
                    return
                }

                // Capture before snapshot
                let beforeSnapshot = renderer.captureSnapshot(of: texture)

                // Apply blur effect
                let radius = brushSettings.size / 10.0 // Use brush size to control blur radius
                renderer.applyBlur(at: location, radius: Float(radius), to: texture, screenSize: view.bounds.size)

                // Capture after snapshot
                let afterSnapshot = renderer.captureSnapshot(of: texture)

                // Record in history
                if let before = beforeSnapshot, let after = afterSnapshot, let canvasState = canvasState {
                    let layerId = layers[selectedLayerIndex].id
                    Task { @MainActor in
                        canvasState.historyManager.record(.stroke(
                            layerId: layerId,
                            beforeSnapshot: before,
                            afterSnapshot: after
                        ))
                    }
                }

                // Update thumbnail
                let currentLayerIndex = selectedLayerIndex
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    if let thumbnail = renderer.generateThumbnail(from: texture, size: CGSize(width: 44, height: 44)) {
                        DispatchQueue.main.async {
                            self?.layers[currentLayerIndex].updateThumbnail(thumbnail)
                        }
                    }
                }

                return
            }

            // Handle sharpen tool - apply sharpen effect on tap/drag
            if currentTool == .sharpen {
                print("Sharpen: applying sharpen at \(location)")
                guard selectedLayerIndex < layers.count,
                      let texture = layers[selectedLayerIndex].texture,
                      let renderer = renderer else {
                    print("ERROR: Cannot apply sharpen - invalid layer or texture")
                    return
                }

                // Capture before snapshot
                let beforeSnapshot = renderer.captureSnapshot(of: texture)

                // Apply sharpen effect
                let radius = brushSettings.size / 10.0 // Use brush size to control sharpen radius
                renderer.applySharpen(at: location, radius: Float(radius), to: texture, screenSize: view.bounds.size)

                // Capture after snapshot
                let afterSnapshot = renderer.captureSnapshot(of: texture)

                // Record in history
                if let before = beforeSnapshot, let after = afterSnapshot, let canvasState = canvasState {
                    let layerId = layers[selectedLayerIndex].id
                    Task { @MainActor in
                        canvasState.historyManager.record(.stroke(
                            layerId: layerId,
                            beforeSnapshot: before,
                            afterSnapshot: after
                        ))
                    }
                }

                // Update thumbnail
                let currentLayerIndex = selectedLayerIndex
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    if let thumbnail = renderer.generateThumbnail(from: texture, size: CGSize(width: 44, height: 44)) {
                        DispatchQueue.main.async {
                            self?.layers[currentLayerIndex].updateThumbnail(thumbnail)
                        }
                    }
                }

                return
            }

            // Handle selection tools (rectangleSelect, lasso)
            let isSelectionTool = [.rectangleSelect, .lasso].contains(currentTool)

            if isSelectionTool {
                // For selection tools, store start point and clear any existing selection
                shapeStartPoint = location
                print("Selection tool: stored start point \(location)")

                // For lasso, start building the path
                if currentTool == .lasso {
                    lassoPath = [location]
                    print("Lasso: started path with point \(location)")
                }

                // Clear previous selection when starting new one
                if let canvasState = canvasState {
                    Task { @MainActor in
                        canvasState.clearSelection()
                    }
                }

                // Don't create a stroke for selection tools - they just define the selection area
                return
            }

            // Check if this is a shape tool
            let isShapeTool = [.line, .rectangle, .circle].contains(currentTool)

            if isShapeTool {
                // For shape tools, just store the start point
                shapeStartPoint = location
                print("Shape tool: stored start point \(location)")
            }

            // Start new stroke
            let point = BrushStroke.StrokePoint(
                location: location,
                pressure: pressure,
                timestamp: timestamp
            )

            currentStroke = BrushStroke(
                points: [point],
                settings: brushSettings,
                tool: currentTool,
                layerId: layers[selectedLayerIndex].id
            )

            lastPoint = location
            lastTimestamp = timestamp
            print("Created stroke with 1 point")
        }

        func touchesMoved(_ touches: Set<UITouch>, in view: MTKView) {
            guard let touch = touches.first else {
                print("touchesMoved: No touch in set")
                return
            }

            let location = touch.location(in: view)

            // Handle selection tools
            if currentTool == .rectangleSelect {
                // For rectangle select, we just need start and current point
                // The selection rectangle will be created in touchesEnded
                print("Rectangle select: dragging to \(location)")
                return
            }

            if currentTool == .lasso {
                // For lasso, build up the path as we drag
                lassoPath.append(location)
                if lassoPath.count % 5 == 0 { // Log every 5th point to reduce spam
                    print("Lasso: path now has \(lassoPath.count) points")
                }
                return
            }

            // Regular tools need a current stroke
            guard var stroke = currentStroke else {
                print("touchesMoved: No current stroke")
                return
            }

            let pressure = touch.type == .pencil ? touch.force / touch.maximumPossibleForce : 1.0
            let timestamp = touch.timestamp

            // Check if this is a shape tool
            let isShapeTool = [.line, .rectangle, .circle].contains(currentTool)

            if isShapeTool, let startPoint = shapeStartPoint {
                // For shape tools, regenerate the shape from start to current point
                stroke.points = generateShapePoints(
                    from: startPoint,
                    to: location,
                    tool: currentTool,
                    pressure: pressure,
                    timestamp: timestamp
                )
                currentStroke = stroke
            } else {
                // Regular brush/eraser: Add point to stroke with interpolation for smooth curves
                if let last = lastPoint {
                    let distance = hypot(location.x - last.x, location.y - last.y)
                    let spacing = brushSettings.size * brushSettings.spacing

                    if distance > spacing {
                        // Interpolate points for smoother strokes
                        let steps = Int(ceil(distance / spacing))
                        for i in 1...steps {
                            let t = CGFloat(i) / CGFloat(steps)
                            let interpLocation = CGPoint(
                                x: last.x + (location.x - last.x) * t,
                                y: last.y + (location.y - last.y) * t
                            )
                            let interpPressure = (lastTimestamp > 0) ?
                                (1 - t) * (stroke.points.last?.pressure ?? 1.0) + t * pressure : pressure

                            let point = BrushStroke.StrokePoint(
                                location: interpLocation,
                                pressure: interpPressure,
                                timestamp: timestamp
                            )
                            stroke.points.append(point)
                        }
                    }
                }

                currentStroke = stroke
                lastPoint = location
                lastTimestamp = timestamp

                // Print every 10th point to avoid spam
                if stroke.points.count % 10 == 0 {
                    print("touchesMoved: stroke has \(stroke.points.count) points")
                }
            }

            // No need to call setNeedsDisplay - continuous drawing is enabled
        }

        func touchesEnded(_ touches: Set<UITouch>, in view: MTKView) {
            print("=== TOUCH ENDED ===")

            // Handle selection tools
            guard let touch = touches.first else {
                print("ERROR: No touch in set")
                return
            }

            let endLocation = touch.location(in: view)

            if currentTool == .rectangleSelect, let startPoint = shapeStartPoint {
                print("Rectangle select: creating selection from \(startPoint) to \(endLocation)")

                // Create selection rectangle
                let minX = min(startPoint.x, endLocation.x)
                let minY = min(startPoint.y, endLocation.y)
                let maxX = max(startPoint.x, endLocation.x)
                let maxY = max(startPoint.y, endLocation.y)

                let selectionRect = CGRect(
                    x: minX,
                    y: minY,
                    width: maxX - minX,
                    height: maxY - minY
                )

                // Store selection in canvas state
                if let canvasState = canvasState {
                    Task { @MainActor in
                        canvasState.activeSelection = selectionRect
                        print("Rectangle selection created: \(selectionRect)")
                    }
                }

                shapeStartPoint = nil
                return
            }

            if currentTool == .lasso {
                print("Lasso: creating selection from path with \(lassoPath.count) points")

                // Close the path by connecting back to start
                if !lassoPath.isEmpty {
                    lassoPath.append(lassoPath[0])

                    // Store selection in canvas state
                    if let canvasState = canvasState {
                        let pathCopy = lassoPath
                        Task { @MainActor in
                            canvasState.selectionPath = pathCopy
                            print("Lasso selection created with \(pathCopy.count) points")
                        }
                    }
                }

                // Clear lasso path
                lassoPath = []
                shapeStartPoint = nil
                return
            }

            guard let stroke = currentStroke else {
                print("ERROR: No current stroke to commit")
                return
            }

            print("Committing stroke with \(stroke.points.count) points")
            print("Selected layer index: \(selectedLayerIndex)")
            print("Total layers: \(layers.count)")

            // Ensure textures are initialized before committing
            ensureLayerTextures()

            // Commit stroke to layer
            guard selectedLayerIndex < layers.count else {
                print("ERROR: Invalid layer index \(selectedLayerIndex)")
                currentStroke = nil
                lastPoint = nil
                return
            }

            let layer = layers[selectedLayerIndex]
            print("Layer \(selectedLayerIndex) name: \(layer.name)")
            print("Layer has texture: \(layer.texture != nil)")

            if let texture = layer.texture, let renderer = renderer {
                print("Rendering stroke to layer \(selectedLayerIndex) texture (width: \(texture.width), height: \(texture.height))")
                print("View size: \(view.bounds.size.width)x\(view.bounds.size.height)")

                // Capture snapshot BEFORE rendering stroke
                print("Capturing BEFORE snapshot...")
                let beforeSnapshot = renderer.captureSnapshot(of: texture)
                if beforeSnapshot == nil {
                    print("WARNING: Failed to capture before snapshot")
                }

                // Render the stroke (waits for GPU completion)
                renderer.renderStroke(stroke, to: texture, screenSize: view.bounds.size)
                print("Stroke committed successfully - texture should now contain the stroke")

                // Capture snapshot AFTER rendering stroke (GPU is done now)
                print("Capturing AFTER snapshot...")
                let afterSnapshot = renderer.captureSnapshot(of: texture)
                if afterSnapshot == nil {
                    print("WARNING: Failed to capture after snapshot")
                }

                // Record in history for undo/redo (on main actor)
                if let before = beforeSnapshot, let after = afterSnapshot {
                    // Use canvasState to record history if available
                    if let canvasState = canvasState {
                        let layerId = layer.id
                        Task { @MainActor in
                            canvasState.historyManager.record(.stroke(
                                layerId: layerId,
                                beforeSnapshot: before,
                                afterSnapshot: after
                            ))
                            print("Recorded stroke in history (before: \(before.count) bytes, after: \(after.count) bytes)")
                        }
                    }
                }

                // Update thumbnail for layer panel preview (async, don't block drawing)
                let currentLayerIndex = selectedLayerIndex
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    if let thumbnail = renderer.generateThumbnail(from: texture, size: CGSize(width: 44, height: 44)) {
                        DispatchQueue.main.async {
                            self?.layers[currentLayerIndex].updateThumbnail(thumbnail)
                        }
                    }
                }
            } else {
                print("ERROR: Could not render stroke")
                print("  - Texture exists: \(layer.texture != nil)")
                print("  - Renderer exists: \(renderer != nil)")
            }

            // Clear current stroke so preview stops rendering
            currentStroke = nil
            lastPoint = nil
            shapeStartPoint = nil
            print("Stroke cleared from preview, should now be visible in layer texture")
        }

        func touchesCancelled(_ touches: Set<UITouch>, in view: MTKView) {
            currentStroke = nil
            lastPoint = nil
            shapeStartPoint = nil
            lassoPath = []
        }

        // MARK: - Shape Generation

        /// Generate points for shape tools (line, rectangle, circle)
        private func generateShapePoints(
            from start: CGPoint,
            to end: CGPoint,
            tool: DrawingTool,
            pressure: CGFloat,
            timestamp: TimeInterval
        ) -> [BrushStroke.StrokePoint] {
            switch tool {
            case .line:
                return generateLinePoints(from: start, to: end, pressure: pressure, timestamp: timestamp)
            case .rectangle:
                return generateRectanglePoints(from: start, to: end, pressure: pressure, timestamp: timestamp)
            case .circle:
                return generateCirclePoints(from: start, to: end, pressure: pressure, timestamp: timestamp)
            default:
                return []
            }
        }

        private func generateLinePoints(
            from start: CGPoint,
            to end: CGPoint,
            pressure: CGFloat,
            timestamp: TimeInterval
        ) -> [BrushStroke.StrokePoint] {
            let distance = hypot(end.x - start.x, end.y - start.y)
            let spacing = brushSettings.size * brushSettings.spacing
            let steps = max(Int(distance / spacing), 2)

            var points: [BrushStroke.StrokePoint] = []
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let location = CGPoint(
                    x: start.x + (end.x - start.x) * t,
                    y: start.y + (end.y - start.y) * t
                )
                points.append(BrushStroke.StrokePoint(
                    location: location,
                    pressure: pressure,
                    timestamp: timestamp
                ))
            }
            return points
        }

        private func generateRectanglePoints(
            from start: CGPoint,
            to end: CGPoint,
            pressure: CGFloat,
            timestamp: TimeInterval
        ) -> [BrushStroke.StrokePoint] {
            let spacing = brushSettings.size * brushSettings.spacing
            var points: [BrushStroke.StrokePoint] = []

            // Top edge (start to top-right)
            let topRight = CGPoint(x: end.x, y: start.y)
            points.append(contentsOf: generateLineSegment(from: start, to: topRight, spacing: spacing, pressure: pressure, timestamp: timestamp))

            // Right edge (top-right to end)
            points.append(contentsOf: generateLineSegment(from: topRight, to: end, spacing: spacing, pressure: pressure, timestamp: timestamp))

            // Bottom edge (end to bottom-left)
            let bottomLeft = CGPoint(x: start.x, y: end.y)
            points.append(contentsOf: generateLineSegment(from: end, to: bottomLeft, spacing: spacing, pressure: pressure, timestamp: timestamp))

            // Left edge (bottom-left back to start)
            points.append(contentsOf: generateLineSegment(from: bottomLeft, to: start, spacing: spacing, pressure: pressure, timestamp: timestamp))

            return points
        }

        private func generateCirclePoints(
            from start: CGPoint,
            to end: CGPoint,
            pressure: CGFloat,
            timestamp: TimeInterval
        ) -> [BrushStroke.StrokePoint] {
            // Calculate center point and radii for ellipse
            let center = CGPoint(
                x: (start.x + end.x) / 2,
                y: (start.y + end.y) / 2
            )
            let radiusX = abs(end.x - start.x) / 2
            let radiusY = abs(end.y - start.y) / 2

            // Calculate number of points based on perimeter approximation
            // Ramanujan's approximation for ellipse perimeter
            let h = pow((radiusX - radiusY), 2) / pow((radiusX + radiusY), 2)
            let perimeter = .pi * (radiusX + radiusY) * (1 + (3 * h) / (10 + sqrt(4 - 3 * h)))
            let spacing = brushSettings.size * brushSettings.spacing
            let steps = max(Int(perimeter / spacing), 16)

            var points: [BrushStroke.StrokePoint] = []
            for i in 0...steps {
                let angle = (CGFloat(i) / CGFloat(steps)) * 2 * .pi
                let location = CGPoint(
                    x: center.x + radiusX * cos(angle),
                    y: center.y + radiusY * sin(angle)
                )
                points.append(BrushStroke.StrokePoint(
                    location: location,
                    pressure: pressure,
                    timestamp: timestamp
                ))
            }
            return points
        }

        private func generateLineSegment(
            from start: CGPoint,
            to end: CGPoint,
            spacing: CGFloat,
            pressure: CGFloat,
            timestamp: TimeInterval
        ) -> [BrushStroke.StrokePoint] {
            let distance = hypot(end.x - start.x, end.y - start.y)
            let steps = max(Int(distance / spacing), 1)

            var points: [BrushStroke.StrokePoint] = []
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let location = CGPoint(
                    x: start.x + (end.x - start.x) * t,
                    y: start.y + (end.y - start.y) * t
                )
                points.append(BrushStroke.StrokePoint(
                    location: location,
                    pressure: pressure,
                    timestamp: timestamp
                ))
            }
            return points
        }

        // MARK: - Eyedropper Helper

        /// Read color from texture at a specific point
        private func getColorAt(_ point: CGPoint, in texture: MTLTexture, screenSize: CGSize) -> UIColor? {
            // Scale coordinates from screen space to texture space
            let scaleX = CGFloat(texture.width) / screenSize.width
            let scaleY = CGFloat(texture.height) / screenSize.height
            let x = Int(point.x * scaleX)
            let y = Int(point.y * scaleY)

            // Bounds check
            guard x >= 0, y >= 0, x < texture.width, y < texture.height else {
                print("Eyedropper: point \(point) out of bounds")
                return nil
            }

            // Read pixel data from texture
            let width = texture.width
            let bytesPerRow = width * 4  // BGRA format, 1 byte per channel
            var pixelData = Data(count: bytesPerRow)

            let region = MTLRegion(
                origin: MTLOrigin(x: 0, y: y, z: 0),
                size: MTLSize(width: width, height: 1, depth: 1)
            )

            pixelData.withUnsafeMutableBytes { ptr in
                guard let baseAddress = ptr.baseAddress else { return }
                texture.getBytes(baseAddress, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
            }

            // Extract BGRA color components (Metal uses BGRA format)
            let pixelIndex = x * 4
            let b = CGFloat(pixelData[pixelIndex]) / 255.0
            let g = CGFloat(pixelData[pixelIndex + 1]) / 255.0
            let r = CGFloat(pixelData[pixelIndex + 2]) / 255.0
            let a = CGFloat(pixelData[pixelIndex + 3]) / 255.0

            return UIColor(red: r, green: g, blue: b, alpha: a)
        }
    }
}

// Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
