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
            guard let touch = touches.first,
                  var stroke = currentStroke else {
                print("touchesMoved: No touch or no current stroke")
                return
            }

            let location = touch.location(in: view)
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
                let beforeSnapshot = renderer.captureSnapshot(of: texture)

                // Render the stroke
                renderer.renderStroke(stroke, to: texture, screenSize: view.bounds.size)
                print("Stroke committed successfully - texture should now contain the stroke")

                // Capture snapshot AFTER rendering stroke
                let afterSnapshot = renderer.captureSnapshot(of: texture)

                // Record in history for undo/redo
                if let before = beforeSnapshot, let after = afterSnapshot {
                    // Use canvasState to record history if available
                    if let canvasState = canvasState {
                        canvasState.historyManager.record(.stroke(
                            layerId: layer.id,
                            beforeSnapshot: before,
                            afterSnapshot: after
                        ))
                        print("Recorded stroke in history (before: \(before.count) bytes, after: \(after.count) bytes)")
                    }
                }

                // Update thumbnail for layer panel preview (async, don't block drawing)
                DispatchQueue.global(qos: .utility).async {
                    if let thumbnail = renderer.generateThumbnail(from: texture, size: CGSize(width: 44, height: 44)) {
                        DispatchQueue.main.async {
                            self.layers[selectedLayerIndex].updateThumbnail(thumbnail)
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
            let center = CGPoint(
                x: (start.x + end.x) / 2,
                y: (start.y + end.y) / 2
            )
            let radius = hypot(end.x - start.x, end.y - start.y) / 2

            // Calculate number of points based on circumference
            let circumference = 2 * .pi * radius
            let spacing = brushSettings.size * brushSettings.spacing
            let steps = max(Int(circumference / spacing), 16)

            var points: [BrushStroke.StrokePoint] = []
            for i in 0...steps {
                let angle = (CGFloat(i) / CGFloat(steps)) * 2 * .pi
                let location = CGPoint(
                    x: center.x + radius * cos(angle),
                    y: center.y + radius * sin(angle)
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
    }
}

// Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
