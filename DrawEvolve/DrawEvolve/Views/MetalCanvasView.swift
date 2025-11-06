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

        // Add gesture recognizers for zoom, pan, and rotation
        let pinchGesture = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinchGesture.delegate = context.coordinator
        metalView.addGestureRecognizer(pinchGesture)

        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        panGesture.minimumNumberOfTouches = 2 // Two-finger pan for canvas navigation
        panGesture.maximumNumberOfTouches = 2
        panGesture.delegate = context.coordinator
        metalView.addGestureRecognizer(panGesture)

        let rotationGesture = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotation(_:)))
        rotationGesture.delegate = context.coordinator
        metalView.addGestureRecognizer(rotationGesture)

        print("MetalCanvasView: MTKView configured successfully with gesture recognizers (pinch, pan, rotation)")

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

    class Coordinator: NSObject, MTKViewDelegate, TouchHandling, UIGestureRecognizerDelegate {
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
        private var polygonPoints: [CGPoint] = [] // For polygon tool
        private var canvasState: CanvasStateManager?
        private var onTextRequest: ((CGPoint) -> Void)?
        private var isDraggingSelection = false // Track if we're dragging a selection
        private var selectionDragStart: CGPoint? // Where the drag started

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
            // Handle view size changes (e.g., rotation)
            print("MTKView: Drawable size changed to \(size)")

            // Update screen size in canvas state (use bounds, not drawable size)
            // Touch coordinates are in bounds space (logical points), not pixels
            if let canvasState = canvasState {
                Task { @MainActor in
                    canvasState.screenSize = view.bounds.size
                    print("  - Updated canvasState.screenSize to \(view.bounds.size) (bounds, not drawable size)")
                }
            }
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

            // Get zoom, pan, and rotation state for rendering
            let zoomScale = MainActor.assumeIsolated {
                canvasState?.zoomScale ?? 1.0
            }
            let panOffset = MainActor.assumeIsolated {
                canvasState?.panOffset ?? .zero
            }
            let rotation = MainActor.assumeIsolated {
                canvasState?.canvasRotation.radians ?? 0.0
            }

            // Composite all visible layers to screen with zoom/pan/rotation transform
            for layer in layers where layer.isVisible {
                if let texture = layer.texture {
                    renderer?.renderTextureToScreen(
                        texture,
                        to: renderEncoder,
                        opacity: layer.opacity,
                        zoomScale: Float(zoomScale),
                        panOffset: SIMD2<Float>(Float(panOffset.x), Float(panOffset.y)),
                        canvasRotation: Float(rotation),
                        viewportSize: SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height))
                    )
                }
            }

            // IMPORTANT: Render current stroke preview on top
            // Preview stroke points are in document space, so apply transforms for display
            // DON'T show preview for eraser - it looks weird
            if let stroke = currentStroke, !stroke.points.isEmpty, stroke.tool != .eraser {
                let zoomScale = MainActor.assumeIsolated { canvasState?.zoomScale ?? 1.0 }
                let panOffset = MainActor.assumeIsolated { canvasState?.panOffset ?? .zero }
                let rotation = MainActor.assumeIsolated { canvasState?.canvasRotation.radians ?? 0.0 }

                renderer?.renderStrokePreview(
                    stroke,
                    to: renderEncoder,
                    viewportSize: view.bounds.size,
                    zoomScale: zoomScale,
                    panOffset: panOffset,
                    canvasRotation: rotation
                )
            }

            renderEncoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        func ensureLayerTextures() {
            guard let renderer = renderer else { return }

            var created = false

            // Check all layers for missing textures
            for i in 0..<layers.count {
                if layers[i].texture == nil {
                    print("⚠️ Layer \(i) '\(layers[i].name)' has NIL texture - creating new one. Layer ID: \(layers[i].id)")
                    layers[i].texture = renderer.createLayerTexture()
                    if let tex = layers[i].texture {
                        print("   ✅ Created texture: \(ObjectIdentifier(tex))")
                        created = true
                    } else {
                        print("   ❌ FAILED to create texture!")
                    }
                }
            }

            // Only verify if we created textures
            if created {
                print("📋 Current layer state:")
                for (i, layer) in layers.enumerated() {
                    if let tex = layer.texture {
                        print("  Layer \(i) '\(layer.name)' [ID: \(layer.id)]: Texture \(ObjectIdentifier(tex))")
                    } else {
                        print("  Layer \(i) '\(layer.name)' [ID: \(layer.id)]: ❌ NO TEXTURE")
                    }
                }
            }
        }

        // Touch handling for drawing
        func touchesBegan(_ touches: Set<UITouch>, in view: MTKView) {
            print("👆 === TOUCH BEGAN ===")
            guard let touch = touches.first else {
                print("ERROR: No touch in set")
                return
            }

            // Ensure layer textures exist
            ensureLayerTextures()

            // Get touch location and transform from screen space to document space
            let screenLocation = touch.location(in: view)
            let location = canvasState?.screenToDocument(screenLocation) ?? screenLocation

            let pressure = touch.type == .pencil ? (touch.force > 0 ? touch.force / touch.maximumPossibleForce : 1.0) : 1.0
            let timestamp = touch.timestamp

            print("Touch began at screen: \(screenLocation) → document: \(location) with pressure \(pressure), tool: \(currentTool)")
            print("📍 Selected layer INDEX: \(selectedLayerIndex) of \(layers.count) total layers")
            if let layer = layers[safe: selectedLayerIndex] {
                print("   Will draw to: '\(layer.name)' - has texture: \(layer.texture != nil)")
                if let texture = layer.texture {
                    print("   Texture ID: \(ObjectIdentifier(texture))")
                }
            } else {
                print("   ❌ ERROR: selectedLayerIndex \(selectedLayerIndex) is OUT OF BOUNDS!")
            }

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

                // Perform flood fill (using document size for coordinate scaling)
                let documentSize = MainActor.assumeIsolated { canvasState?.documentSize ?? view.bounds.size }
                renderer.floodFill(at: location, with: brushSettings.color, in: texture, screenSize: documentSize)

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
                      let texture = layers[selectedLayerIndex].texture else {
                    print("ERROR: Cannot pick color - invalid layer or texture")
                    return
                }

                // Read pixel color at location (using document size for coordinate scaling)
                let documentSize = MainActor.assumeIsolated { canvasState?.documentSize ?? view.bounds.size }
                if let pickedColor = getColorAt(location, in: texture, screenSize: documentSize) {
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

                // Apply blur effect (using document size for coordinate scaling)
                let radius = brushSettings.size / 10.0 // Use brush size to control blur radius
                let documentSize = MainActor.assumeIsolated { canvasState?.documentSize ?? view.bounds.size }
                renderer.applyBlur(at: location, radius: Float(radius), to: texture, screenSize: documentSize)

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

                // Apply sharpen effect (using document size for coordinate scaling)
                let radius = brushSettings.size / 10.0 // Use brush size to control sharpen radius
                let documentSize = MainActor.assumeIsolated { canvasState?.documentSize ?? view.bounds.size }
                renderer.applySharpen(at: location, radius: Float(radius), to: texture, screenSize: documentSize)

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

            // Handle polygon tool - multi-tap to add points
            if currentTool == .polygon {
                print("Polygon: adding point \(location)")

                // Check if we're closing the polygon (tap near first point)
                if polygonPoints.count >= 3 {
                    let firstPoint = polygonPoints[0]
                    let distanceToFirst = hypot(location.x - firstPoint.x, location.y - firstPoint.y)

                    // If within 40 points of first point, close the polygon
                    if distanceToFirst < 40 {
                        print("Polygon: closing polygon with \(polygonPoints.count) points")

                        // Generate stroke from polygon points
                        let points = generatePolygonPoints(polygonPoints: polygonPoints, pressure: pressure, timestamp: timestamp)

                        // Create and commit the stroke
                        let stroke = BrushStroke(
                            points: points,
                            settings: brushSettings,
                            tool: currentTool,
                            layerId: layers[selectedLayerIndex].id
                        )

                        // Commit stroke immediately (using document size for coordinate scaling)
                        if let texture = layers[selectedLayerIndex].texture, let renderer = renderer {
                            let beforeSnapshot = renderer.captureSnapshot(of: texture)
                            let documentSize = MainActor.assumeIsolated { canvasState?.documentSize ?? view.bounds.size }
                            renderer.renderStroke(stroke, to: texture, screenSize: documentSize)
                            let afterSnapshot = renderer.captureSnapshot(of: texture)

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
                        }

                        // Clear polygon points
                        polygonPoints = []
                        return
                    }
                }

                // Add point to polygon
                polygonPoints.append(location)
                print("Polygon: now has \(polygonPoints.count) points")

                // Don't create a stroke - polygon is built from taps
                return
            }

            // Check if we're touching inside an existing selection (for any tool)
            if let canvasState = canvasState {
                let shouldStartDragging = MainActor.assumeIsolated {
                    guard canvasState.selectionPixels != nil else { return false }
                    return isPointInSelection(location)
                }

                if shouldStartDragging {
                    // Start dragging the selection
                    isDraggingSelection = true
                    selectionDragStart = location
                    print("Started dragging selection at \(location)")
                    return
                }
            }

            // Handle smudge tool - blend/smear pixels
            if currentTool == .smudge {
                print("Smudge: starting smudge at \(location)")
                // Smudge works like brush but samples and blends pixels
                // We'll treat it like a regular stroke but use special rendering
            }

            // Handle magic wand tool - select contiguous pixels of similar color
            if currentTool == .magicWand {
                print("Magic wand: selecting similar pixels at \(location)")
                guard selectedLayerIndex < layers.count,
                      let texture = layers[selectedLayerIndex].texture,
                      renderer != nil else {
                    print("ERROR: Cannot use magic wand - invalid layer or texture")
                    return
                }

                // Get the clicked color (using document size for coordinate scaling)
                let documentSize = MainActor.assumeIsolated { canvasState?.documentSize ?? view.bounds.size }
                guard let targetColor = getColorAt(location, in: texture, screenSize: documentSize) else {
                    print("ERROR: Could not get color at location")
                    return
                }

                // Perform flood fill selection to find contiguous pixels
                let tolerance: CGFloat = 0.1 // Color similarity tolerance (0.0 = exact match, 1.0 = any color)
                let selectionPath = magicWandSelection(at: location, targetColor: targetColor, tolerance: tolerance, in: texture, screenSize: documentSize)

                // Store selection in canvas state
                if let canvasState = canvasState, !selectionPath.isEmpty {
                    Task { @MainActor in
                        canvasState.selectionPath = selectionPath
                        print("Magic wand selection created with \(selectionPath.count) points")
                        // Extract pixels for moving/deleting
                        canvasState.extractSelectionPixels()
                        // Render them back immediately at original position so they don't disappear
                        canvasState.renderSelectionInRealTime()
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

            // Get touch location and transform from screen space to document space
            let screenLocation = touch.location(in: view)
            let location = canvasState?.screenToDocument(screenLocation) ?? screenLocation

            // Handle dragging an existing selection
            if isDraggingSelection, let dragStart = selectionDragStart, let canvasState = canvasState {
                // Calculate offset in document space
                let offset = CGPoint(
                    x: location.x - dragStart.x,
                    y: location.y - dragStart.y
                )

                Task { @MainActor in
                    canvasState.selectionOffset = offset
                    // Render selection pixels in real-time for fluent animation
                    canvasState.renderSelectionInRealTime()
                }

                if hypot(offset.x, offset.y) > 5 { // Log only if moved more than 5 points
                    print("Dragging selection with offset: \(offset)")
                }
                return
            }

            // Handle selection tools
            if currentTool == .rectangleSelect, let startPoint = shapeStartPoint {
                // For rectangle select, show preview while dragging
                let minX = min(startPoint.x, location.x)
                let minY = min(startPoint.y, location.y)
                let maxX = max(startPoint.x, location.x)
                let maxY = max(startPoint.y, location.y)

                let previewRect = CGRect(
                    x: minX,
                    y: minY,
                    width: maxX - minX,
                    height: maxY - minY
                )

                if let canvasState = canvasState {
                    Task { @MainActor in
                        canvasState.previewSelection = previewRect
                    }
                }

                if hypot(location.x - startPoint.x, location.y - startPoint.y) > 10 {
                    print("Rectangle select: dragging preview \(previewRect)")
                }
                return
            }

            if currentTool == .lasso {
                // For lasso, build up the path as we drag and show preview
                lassoPath.append(location)

                if let canvasState = canvasState {
                    Task { @MainActor in
                        canvasState.previewLassoPath = lassoPath
                    }
                }

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

            // Handle ending a selection drag
            if isDraggingSelection {
                print("Finished dragging selection, committing to layer")
                isDraggingSelection = false
                selectionDragStart = nil

                // Commit the selection to the layer
                if let canvasState = canvasState {
                    Task { @MainActor in
                        canvasState.commitSelection()
                    }
                }
                return
            }

            // Handle selection tools
            guard let touch = touches.first else {
                print("ERROR: No touch in set")
                return
            }

            // Get touch location and transform from screen space to document space
            let screenEndLocation = touch.location(in: view)
            let endLocation = canvasState?.screenToDocument(screenEndLocation) ?? screenEndLocation

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

                // Store selection in canvas state and extract pixels
                if let canvasState = canvasState {
                    Task { @MainActor in
                        canvasState.previewSelection = nil // Clear preview
                        canvasState.activeSelection = selectionRect
                        print("Rectangle selection created: \(selectionRect)")
                        // Extract pixels for moving
                        canvasState.extractSelectionPixels()
                        // Render them back immediately at original position so they don't disappear
                        canvasState.renderSelectionInRealTime()
                    }
                }

                shapeStartPoint = nil
                return
            }

            if currentTool == .lasso {
                print("Lasso: creating selection from path with \(lassoPath.count) points")

                // IMPORTANT: Need at least 3 unique points for a valid lasso selection
                // (After closing the path with the first point, we need at least 4 total)
                if lassoPath.count < 3 {
                    print("Lasso: path too short (\(lassoPath.count) points), ignoring selection")
                    // Clear lasso path and preview
                    lassoPath = []
                    shapeStartPoint = nil
                    if let canvasState = canvasState {
                        Task { @MainActor in
                            canvasState.previewLassoPath = nil
                        }
                    }
                    return
                }

                // Validate the path covers a minimum area (avoid tiny accidental selections)
                let minX = lassoPath.map { $0.x }.min() ?? 0
                let maxX = lassoPath.map { $0.x }.max() ?? 0
                let minY = lassoPath.map { $0.y }.min() ?? 0
                let maxY = lassoPath.map { $0.y }.max() ?? 0
                let width = maxX - minX
                let height = maxY - minY
                let minSelectionSize: CGFloat = 10 // Minimum 10x10 pixel area

                if width < minSelectionSize || height < minSelectionSize {
                    print("Lasso: selection too small (\(width)x\(height)), ignoring")
                    // Clear lasso path and preview
                    lassoPath = []
                    shapeStartPoint = nil
                    if let canvasState = canvasState {
                        Task { @MainActor in
                            canvasState.previewLassoPath = nil
                        }
                    }
                    return
                }

                // Close the path by connecting back to start
                lassoPath.append(lassoPath[0])

                // Store selection in canvas state and extract pixels
                if let canvasState = canvasState {
                    let pathCopy = lassoPath
                    Task { @MainActor in
                        canvasState.previewLassoPath = nil // Clear preview
                        canvasState.selectionPath = pathCopy
                        print("Lasso selection created with \(pathCopy.count) points")
                        // Extract pixels for moving
                        canvasState.extractSelectionPixels()
                        // Render them back immediately at original position so they don't disappear
                        canvasState.renderSelectionInRealTime()
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

            if let texture = layer.texture, let renderer = renderer {
                // Stroke points are in document space which matches texture space
                // Use texture size directly for 1:1 coordinate mapping
                let textureSize = CGSize(width: texture.width, height: texture.height)
                print("✏️ Drawing to Layer \(selectedLayerIndex) '\(layer.name)' - Texture ID: \(ObjectIdentifier(texture))")
                print("  Texture size: \(textureSize.width)x\(textureSize.height)")

                // Capture snapshot BEFORE rendering stroke
                print("Capturing BEFORE snapshot...")
                let beforeSnapshot = renderer.captureSnapshot(of: texture)
                if beforeSnapshot == nil {
                    print("WARNING: Failed to capture before snapshot")
                }

                // Render the stroke (stroke points are in document/texture space already)
                renderer.renderStroke(stroke, to: texture, screenSize: textureSize)
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
            polygonPoints = []
            isDraggingSelection = false
            selectionDragStart = nil

            // Clear selection previews
            if let canvasState = canvasState {
                Task { @MainActor in
                    canvasState.previewSelection = nil
                    canvasState.previewLassoPath = nil
                }
            }
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

        private func generatePolygonPoints(
            polygonPoints: [CGPoint],
            pressure: CGFloat,
            timestamp: TimeInterval
        ) -> [BrushStroke.StrokePoint] {
            guard polygonPoints.count >= 2 else { return [] }

            let spacing = brushSettings.size * brushSettings.spacing
            var points: [BrushStroke.StrokePoint] = []

            // Draw lines between all consecutive points
            for i in 0..<polygonPoints.count {
                let nextIndex = (i + 1) % polygonPoints.count
                let start = polygonPoints[i]
                let end = polygonPoints[nextIndex]

                points.append(contentsOf: generateLineSegment(
                    from: start,
                    to: end,
                    spacing: spacing,
                    pressure: pressure,
                    timestamp: timestamp
                ))
            }

            return points
        }

        // MARK: - Selection Helpers

        /// Check if a point is inside the current selection
        @MainActor
        private func isPointInSelection(_ point: CGPoint) -> Bool {
            guard let canvasState = canvasState else { return false }

            // Check rectangle selection
            if let rect = canvasState.activeSelection {
                return rect.contains(point)
            }

            // Check lasso selection using point-in-polygon test
            if let path = canvasState.selectionPath, !path.isEmpty {
                return pointInPolygon(point: point, polygon: path)
            }

            return false
        }

        /// Point-in-polygon test using ray casting algorithm
        private func pointInPolygon(point: CGPoint, polygon: [CGPoint]) -> Bool {
            guard polygon.count >= 3 else { return false }

            var inside = false
            var j = polygon.count - 1

            for i in 0..<polygon.count {
                let xi = polygon[i].x, yi = polygon[i].y
                let xj = polygon[j].x, yj = polygon[j].y

                let intersect = ((yi > point.y) != (yj > point.y)) &&
                    (point.x < (xj - xi) * (point.y - yi) / (yj - yi) + xi)

                if intersect {
                    inside = !inside
                }

                j = i
            }

            return inside
        }

        // MARK: - Magic Wand Helper

        /// Perform magic wand selection using flood fill algorithm
        private func magicWandSelection(at point: CGPoint, targetColor: UIColor, tolerance: CGFloat, in texture: MTLTexture, screenSize: CGSize) -> [CGPoint] {
            // Scale coordinates from screen space to texture space
            let scaleX = CGFloat(texture.width) / screenSize.width
            let scaleY = CGFloat(texture.height) / screenSize.height
            let startX = Int(point.x * scaleX)
            let startY = Int(point.y * scaleY)

            // Bounds check
            guard startX >= 0, startY >= 0, startX < texture.width, startY < texture.height else {
                print("Magic wand: starting point out of bounds")
                return []
            }

            // Read entire texture data (this is expensive but necessary for flood fill)
            let width = texture.width
            let height = texture.height
            let bytesPerRow = width * 4  // BGRA format
            var pixelData = Data(count: height * bytesPerRow)

            let region = MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: width, height: height, depth: 1)
            )

            pixelData.withUnsafeMutableBytes { ptr in
                guard let baseAddress = ptr.baseAddress else { return }
                texture.getBytes(baseAddress, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
            }

            // Extract target color components
            var targetR: CGFloat = 0, targetG: CGFloat = 0, targetB: CGFloat = 0, targetA: CGFloat = 0
            targetColor.getRed(&targetR, green: &targetG, blue: &targetB, alpha: &targetA)

            // Flood fill to find connected pixels
            var visited = Set<Int>() // Use 1D index: y * width + x
            var stack: [(Int, Int)] = [(startX, startY)]
            var selectedPixels: [(Int, Int)] = []

            let maxPixels = 100_000 // Safety limit
            let pixelBytes = pixelData.withUnsafeBytes { $0.bindMemory(to: UInt8.self) }

            while !stack.isEmpty && selectedPixels.count < maxPixels {
                let (x, y) = stack.removeLast()
                let index = y * width + x

                // Skip if already visited or out of bounds
                guard x >= 0, y >= 0, x < width, y < height, !visited.contains(index) else {
                    continue
                }

                visited.insert(index)

                // Get pixel color (BGRA format)
                let pixelIndex = (y * width + x) * 4
                let b = CGFloat(pixelBytes[pixelIndex]) / 255.0
                let g = CGFloat(pixelBytes[pixelIndex + 1]) / 255.0
                let r = CGFloat(pixelBytes[pixelIndex + 2]) / 255.0
                let a = CGFloat(pixelBytes[pixelIndex + 3]) / 255.0

                // Check if color matches within tolerance
                let colorDistance = sqrt(
                    pow(r - targetR, 2) +
                    pow(g - targetG, 2) +
                    pow(b - targetB, 2) +
                    pow(a - targetA, 2)
                ) / 2.0  // Normalize to 0-1 range

                if colorDistance <= tolerance {
                    selectedPixels.append((x, y))

                    // Add neighbors to stack
                    stack.append((x + 1, y))
                    stack.append((x - 1, y))
                    stack.append((x, y + 1))
                    stack.append((x, y - 1))
                }
            }

            print("Magic wand: found \(selectedPixels.count) matching pixels")

            // Convert selected pixels to a path (boundary tracing)
            // For simplicity, we'll create a path from the bounding box of selected pixels
            // A more advanced implementation would trace the actual boundary
            if selectedPixels.isEmpty {
                return []
            }

            // Create a path that traces the boundary of selected pixels
            // We'll use marching squares algorithm for a better boundary
            let boundaryPath = traceBoundary(selectedPixels: Set(selectedPixels.map { $0.1 * width + $0.0 }), width: width, height: height)

            // Convert back to screen space
            let screenPath = boundaryPath.map { point in
                CGPoint(
                    x: point.x / scaleX,
                    y: point.y / scaleY
                )
            }

            return screenPath
        }

        /// Trace the boundary of selected pixels to create a selection path
        private func traceBoundary(selectedPixels: Set<Int>, width: Int, height: Int) -> [CGPoint] {
            // Simple boundary tracing: find edge pixels and create a path
            var boundaryPoints: [CGPoint] = []

            // Find all edge pixels (pixels that have at least one non-selected neighbor)
            for index in selectedPixels {
                let x = index % width
                let y = index / width

                // Check if this pixel is on the edge
                let neighbors = [
                    (x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)
                ]

                let isEdge = neighbors.contains { (nx, ny) in
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { return true }
                    return !selectedPixels.contains(ny * width + nx)
                }

                if isEdge {
                    boundaryPoints.append(CGPoint(x: x, y: y))
                }
            }

            // Sort boundary points to create a continuous path (simple convex hull)
            // For better results, use a proper boundary tracing algorithm
            if boundaryPoints.isEmpty {
                return []
            }

            // For now, return bounding box as a simple path
            let xs = boundaryPoints.map { $0.x }
            let ys = boundaryPoints.map { $0.y }
            let minX = xs.min()!
            let maxX = xs.max()!
            let minY = ys.min()!
            let maxY = ys.max()!

            return [
                CGPoint(x: minX, y: minY),
                CGPoint(x: maxX, y: minY),
                CGPoint(x: maxX, y: maxY),
                CGPoint(x: minX, y: maxY),
                CGPoint(x: minX, y: minY)  // Close the path
            ]
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

        // MARK: - Gesture Recognizers

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let canvasState = canvasState, let view = gesture.view else { return }

            let location = gesture.location(in: view)

            switch gesture.state {
            case .began:
                print("Pinch began at \(location), scale: \(gesture.scale)")

            case .changed:
                // Apply zoom centered at pinch location
                Task { @MainActor in
                    let currentScale = canvasState.zoomScale
                    let newScale = currentScale * gesture.scale
                    canvasState.zoom(scale: newScale, centerPoint: location)
                }
                // Reset gesture scale so we get incremental changes
                gesture.scale = 1.0

            case .ended, .cancelled:
                print("Pinch ended, final zoom: \(canvasState.zoomScale)")

            default:
                break
            }
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let canvasState = canvasState, let view = gesture.view else { return }

            switch gesture.state {
            case .began:
                print("Two-finger pan began")

            case .changed:
                let translation = gesture.translation(in: view)
                // Apply pan delta
                Task { @MainActor in
                    canvasState.pan(delta: translation)
                }
                // Reset translation so we get incremental changes
                gesture.setTranslation(.zero, in: view)

            case .ended, .cancelled:
                print("Two-finger pan ended")

            default:
                break
            }
        }

        @objc func handleRotation(_ gesture: UIRotationGestureRecognizer) {
            guard let canvasState = canvasState else { return }

            switch gesture.state {
            case .began:
                print("Rotation began")

            case .changed:
                let rotationAngle = Angle(radians: gesture.rotation)

                Task { @MainActor in
                    // Disable snapping if user holds down option key (on iPad with keyboard)
                    let snapToGrid = !gesture.modifierFlags.contains(.alternate)
                    canvasState.rotate(by: rotationAngle, snapToGrid: snapToGrid)
                }

                // Reset rotation so we get incremental changes
                gesture.rotation = 0

            case .ended:
                print("Rotation ended, final rotation: \(canvasState.canvasRotation.degrees)°")

                // Optionally snap to nearest 90° on release if very close
                let currentDegrees = canvasState.canvasRotation.degrees
                let nearest90 = round(currentDegrees / 90) * 90

                if abs(currentDegrees - nearest90) < 5 {  // Within 5° of 90° increment
                    Task { @MainActor in
                        canvasState.canvasRotation = .degrees(nearest90)
                        print("Snapped to nearest 90°: \(nearest90)°")
                    }
                }

            default:
                break
            }
        }

        // MARK: - UIGestureRecognizerDelegate

        /// Allow pinch, pan, and rotation gestures to work simultaneously
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Allow all transform gestures to work together (pinch + pan + rotation)
            return true
        }

        /// Block transform gestures while actively drawing
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // Disable transform gestures while actively drawing
            if currentStroke != nil {
                return false
            }
            return true
        }
    }
}

// Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
