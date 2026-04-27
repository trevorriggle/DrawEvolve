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
            delegate.touchesBegan(touches, in: self, with: event)
        } else {
            print("TouchEnabledMTKView: WARNING - No touch delegate!")
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        touchDelegate?.touchesMoved(touches, in: self, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("TouchEnabledMTKView: touchesEnded received")
        super.touchesEnded(touches, with: event)
        touchDelegate?.touchesEnded(touches, in: self, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("TouchEnabledMTKView: touchesCancelled received")
        super.touchesCancelled(touches, with: event)
        touchDelegate?.touchesCancelled(touches, in: self, with: event)
    }
}

protocol TouchHandling: AnyObject {
    func touchesBegan(_ touches: Set<UITouch>, in view: MTKView, with event: UIEvent?)
    func touchesMoved(_ touches: Set<UITouch>, in view: MTKView, with event: UIEvent?)
    func touchesEnded(_ touches: Set<UITouch>, in view: MTKView, with event: UIEvent?)
    func touchesCancelled(_ touches: Set<UITouch>, in view: MTKView, with event: UIEvent?)
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
        // Off-canvas workbench is light gray so the canvas boundary is visible
        // when zoomed/panned out. At default zoom the canvas fills the viewport.
        metalView.clearColor = MTLClearColor(red: 0.753, green: 0.753, blue: 0.753, alpha: 1)
        metalView.backgroundColor = UIColor(red: 0.753, green: 0.753, blue: 0.753, alpha: 1.0)
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
        private var shapeStartPoint: CGPoint? // For shape tools (doc space)
        // Screen-space start for shape tools that should ignore canvas rotation
        // (rectangle, circle). Line is rotation-invariant so it can use the
        // doc-space start directly.
        private var shapeStartScreen: CGPoint?
        private var lassoPath: [CGPoint] = [] // For lasso selection
        private var canvasState: CanvasStateManager?
        private var onTextRequest: ((CGPoint) -> Void)?
        private var isDraggingSelection = false // Track if we're dragging a selection
        private var selectionDragStart: CGPoint? // Where the drag started (doc space)
        // Screen-space start of a rectangle-marquee drag. We store the SCREEN
        // point (not just doc point) so that under canvas rotation we can build
        // a screen-axis-aligned rectangle from the user's drag and then map its
        // 4 corners to doc space — yielding a rotated quad that faithfully
        // matches what the user actually dragged. Storing only the doc-space
        // start and using min/max gives a doc-axis-aligned rect which is wrong
        // when the canvas is rotated.
        private var marqueeStartScreen: CGPoint?
        private var coordDiagLogsRemaining = 3 // One-time on-device coordinate-pipeline diagnostic logs

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
            // IMPORTANT: MTKView delegate callbacks are on the main thread; update
            // synchronously so the next touch/draw sees the new size. The previous
            // `Task { @MainActor }` raced with touches that landed before the Task flushed.
            if let canvasState = canvasState, let renderer = renderer {
                MainActor.assumeIsolated {
                    canvasState.screenSize = view.bounds.size
                    // Update canvas size to match new screen dimensions (via diagonal calculation)
                    // Use drawable pixel size (not bounds.size in points) so
                    // the canvas texture matches the display's native
                    // resolution. Otherwise the 2048² texture is upscaled
                    // ~1.33× to a ~2732px-wide drawable on iPad Pro, producing
                    // blocky/low-res stroke edges. Doc coord system scales
                    // with texture size; brush defaults compensated below.
                    renderer.updateCanvasSize(for: view.drawableSize)
                    print("  - Updated canvasState.screenSize to \(view.bounds.size) (bounds, not drawable size)")
                    print("  - Canvas size updated to \(renderer.canvasSize)")
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
                if let canvasState = canvasState, let renderer = renderer {
                    // IMPORTANT: Set screen size first, which will trigger canvas size calculation
                    canvasState.screenSize = view.bounds.size
                    canvasState.renderer = renderer
                    // Ensure canvas size is immediately updated based on screen size
                    // Use drawable pixel size (not bounds.size in points) so
                    // the canvas texture matches the display's native
                    // resolution. Otherwise the 2048² texture is upscaled
                    // ~1.33× to a ~2732px-wide drawable on iPad Pro, producing
                    // blocky/low-res stroke edges. Doc coord system scales
                    // with texture size; brush defaults compensated below.
                    renderer.updateCanvasSize(for: view.drawableSize)
                    print("MetalCanvasView.draw: Shared renderer with canvas state")
                    print("  - Screen size: \(view.bounds.size)")
                    print("  - Canvas size: \(renderer.canvasSize)")
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

            // Draw opaque white canvas background so the gray workbench
            // doesn't show through transparent layer regions
            renderer?.renderCanvasBackground(
                to: renderEncoder,
                zoomScale: Float(zoomScale),
                panOffset: SIMD2<Float>(Float(panOffset.x), Float(panOffset.y)),
                canvasRotation: Float(rotation),
                viewportSize: SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height))
            )

            // Selection-drag preview state (read once so the layer loop and the
            // floating overlay below see a consistent snapshot).
            let (
                isTranslatingActiveLayer,
                activeLayerIndex,
                floatingTexture,
                selectionOriginalRect,
                selectionOffsetDoc,
                selectionScale,
                documentSize
            ): (Bool, Int, MTLTexture?, CGRect?, CGPoint, CGFloat, CGSize) = MainActor.assumeIsolated {
                guard let canvasState = canvasState else {
                    return (false, -1, MTLTexture?.none, CGRect?.none, CGPoint.zero, CGFloat(1.0), CGSize.zero)
                }
                return (
                    canvasState.isTranslatingActiveLayer,
                    canvasState.selectedLayerIndex,
                    canvasState.floatingSelectionTexture,
                    canvasState.selectionOriginalRect,
                    canvasState.selectionOffset,
                    canvasState.selectionScale,
                    canvasState.documentSize
                )
            }

            // Composite all visible layers to screen with zoom/pan/rotation transform.
            // When the move tool is mid-drag with no rect/lasso selection, the
            // active layer is rendered at an offset doc rect so the user sees
            // a real-time preview without any per-frame texture writes.
            for (index, layer) in layers.enumerated() where layer.isVisible {
                guard let texture = layer.texture else { continue }

                if isTranslatingActiveLayer && index == activeLayerIndex && documentSize.width > 0 {
                    let docRect = CGRect(
                        x: selectionOffsetDoc.x,
                        y: selectionOffsetDoc.y,
                        width: documentSize.width,
                        height: documentSize.height
                    )
                    renderer?.renderFloatingTexture(
                        texture,
                        atDocRect: docRect,
                        to: renderEncoder,
                        opacity: layer.opacity,
                        zoomScale: Float(zoomScale),
                        panOffset: SIMD2<Float>(Float(panOffset.x), Float(panOffset.y)),
                        canvasRotation: Float(rotation),
                        viewportSize: SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height))
                    )
                } else {
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

            // Floating selection (rect/lasso, or move on top of an existing
            // selection). The active layer has a hole where the selection
            // came from; the floating texture is composited on top at
            // originalRect + offset every frame.
            if let floating = floatingTexture, let original = selectionOriginalRect {
                let docRect = CGRect(
                    x: original.origin.x + selectionOffsetDoc.x,
                    y: original.origin.y + selectionOffsetDoc.y,
                    width: original.width * selectionScale,
                    height: original.height * selectionScale
                )
                renderer?.renderFloatingTexture(
                    floating,
                    atDocRect: docRect,
                    to: renderEncoder,
                    opacity: 1.0,
                    zoomScale: Float(zoomScale),
                    panOffset: SIMD2<Float>(Float(panOffset.x), Float(panOffset.y)),
                    canvasRotation: Float(rotation),
                    viewportSize: SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height))
                )
            }

            // IMPORTANT: Render current stroke preview on top
            // Preview stroke points are in document space, so apply transforms for display
            if let stroke = currentStroke, !stroke.points.isEmpty {
                let zoomScale = MainActor.assumeIsolated { canvasState?.zoomScale ?? 1.0 }
                let panOffset = MainActor.assumeIsolated { canvasState?.panOffset ?? .zero }
                let rotation = MainActor.assumeIsolated { canvasState?.canvasRotation.radians ?? 0.0 }

                renderer?.renderStrokePreview(
                    stroke,
                    to: renderEncoder,
                    viewportSize: view.bounds.size,
                    drawableSize: view.drawableSize,
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

        // MARK: - Pressure
        //
        // `size * pressure` is applied in the brush vertex shader, so the value we put
        // into `StrokePoint.pressure` directly scales the brush dot. Previously the
        // code used `touch.force / maximumPossibleForce` for Pencil and a constant 1.0
        // for fingers, which made Pencil strokes systematically thinner than finger
        // strokes and ignored `BrushSettings.pressureSensitivity` entirely. (Bugs 1.3, 3.1)
        //
        // New behavior:
        //   - Pencil + pressureSensitivity on  → remap raw force through
        //     [minPressureSize, maxPressureSize].
        //   - Pencil + pressureSensitivity off → 1.0 (no variation).
        //   - Finger (or any non-pencil type)   → fixed 0.75 so finger and Pencil widths
        //     feel comparable at the same brush size.
        private func computePressure(for touch: UITouch) -> CGFloat {
            let settings = brushSettings
            if touch.type == .pencil {
                guard settings.pressureSensitivity else { return 1.0 }
                // Apple Pencil firmware has been observed to occasionally
                // return NaN for `touch.force` under heavy pressure or palm
                // rejection. Swift's `max(0, NaN)` returns NaN (NaN
                // comparisons never satisfy `>`, so the fallback path
                // returns NaN rather than 0). NaN pressure → NaN pointSize
                // in the brush vertex shader → silent fail to render →
                // "stroke vanishes mid-stroke" symptom from the Apr 15
                // hardware audit. Bail to neutral pressure 1.0 if any
                // input is non-finite or out of range.
                guard touch.maximumPossibleForce.isFinite,
                      touch.maximumPossibleForce > 0,
                      touch.force.isFinite else {
                    return 1.0
                }
                let raw = max(0, min(1, touch.force / touch.maximumPossibleForce))
                guard raw.isFinite else { return 1.0 }
                let lo = settings.minPressureSize
                let hi = settings.maxPressureSize
                let result = lo + raw * (hi - lo)
                return result.isFinite ? result : 1.0
            } else {
                // Fingers have no reliable pressure on iPad. Use a fixed mid-range value.
                return 0.75
            }
        }

        // Touch handling for drawing
        func touchesBegan(_ touches: Set<UITouch>, in view: MTKView, with event: UIEvent?) {
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

            let pressure = computePressure(for: touch)
            let timestamp = touch.timestamp

            // One-time coordinate-pipeline diagnostic for bug 1.1 (stroke offset).
            // Logs the first few touches so we can confirm on-device whether screenSize
            // and documentSize are what we expect at the moment of input.
            if coordDiagLogsRemaining > 0, let cs = canvasState {
                coordDiagLogsRemaining -= 1
                let bounds = view.bounds.size
                let drawable = view.drawableSize
                print("🧭 COORD DIAG [\(3 - coordDiagLogsRemaining)/3]")
                print("  screenLocation (UIKit pts): \(screenLocation)")
                print("  document (after screenToDocument): \(location)")
                print("  view.bounds.size (pts): \(bounds)")
                print("  view.drawableSize (px): \(drawable)")
                print("  canvasState.screenSize: \(cs.screenSize)")
                print("  canvasState.documentSize: \(cs.documentSize)")
                print("  zoomScale: \(cs.zoomScale)  panOffset: \(cs.panOffset)  rotation: \(cs.canvasRotation.degrees)°")
                print("  touch.type: \(touch.type.rawValue)  force: \(touch.force)/\(touch.maximumPossibleForce)")
            }

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

            // Handle eyedropper tool - pick color from canvas. Sample the
            // composite of visible layers (not just the active layer) so the
            // user picks the color they actually see.
            if currentTool == .eyeDropper {
                print("Eyedropper: picking color at \(location)")
                guard let renderer = renderer,
                      let composite = renderer.compositeLayersToTexture(layers: layers) else {
                    print("ERROR: Cannot pick color - composite unavailable")
                    return
                }

                let documentSize = MainActor.assumeIsolated { canvasState?.documentSize ?? view.bounds.size }
                if let pickedColor = getColorAt(location, in: composite, screenSize: documentSize) {
                    brushSettings.color = pickedColor
                    print("Picked color: \(pickedColor)")
                }

                return
            }

            // Handle move tool — drag the entire active layer when there's no
            // prior rect/lasso selection. We skip pixel extraction entirely;
            // the shader translates the layer texture each frame and a single
            // Metal blit moves the bits on commit. (If a rect/lasso selection
            // already exists, fall through to the standard floating-selection
            // drag below.)
            if currentTool == .move, let canvasState = canvasState {
                let alreadyHasSelection = MainActor.assumeIsolated {
                    canvasState.floatingSelectionTexture != nil || canvasState.selectionPixels != nil
                }
                if !alreadyHasSelection {
                    MainActor.assumeIsolated {
                        canvasState.beginActiveLayerTranslation()
                    }
                    isDraggingSelection = true
                    selectionDragStart = location
                    print("Move tool: began whole-layer translation drag")
                    return
                }
            }

            // Check if we're touching inside an existing selection (for any tool)
            if let canvasState = canvasState {
                let shouldStartDragging = MainActor.assumeIsolated {
                    guard canvasState.floatingSelectionTexture != nil else { return false }
                    // Move tool always drags from any tap — the selection
                    // covers the whole layer so isPointInSelection is moot.
                    if currentTool == .move { return true }
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

            // Handle selection tools (rectangleSelect, lasso)
            let isSelectionTool = [.rectangleSelect, .lasso].contains(currentTool)

            if isSelectionTool {
                // For selection tools, store start point and clear any existing selection
                shapeStartPoint = location
                // Store screen-space start too — the marquee needs this to build a
                // screen-axis-aligned quad that survives canvas rotation.
                marqueeStartScreen = screenLocation
                print("Selection tool: stored start point \(location) (screen: \(screenLocation))")

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
                shapeStartScreen = screenLocation
                print("Shape tool: stored start point \(location) (screen: \(screenLocation))")
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

        func touchesMoved(_ touches: Set<UITouch>, in view: MTKView, with event: UIEvent?) {
            guard let touch = touches.first else {
                print("touchesMoved: No touch in set")
                return
            }

            // Latest single-point location — used by selection/preview paths that only
            // care about the most recent finger/pencil position, not every sub-sample.
            let latestScreenLocation = touch.location(in: view)
            let latestLocation = canvasState?.screenToDocument(latestScreenLocation) ?? latestScreenLocation

            // Handle dragging an existing selection. We *only* update the
            // doc-space offset here — the draw loop renders the floating
            // texture (or the active layer, for whole-layer move) at offset
            // each frame on the GPU. No CPU pixel work per touch event.
            if isDraggingSelection, let dragStart = selectionDragStart, let canvasState = canvasState {
                let offset = CGPoint(
                    x: latestLocation.x - dragStart.x,
                    y: latestLocation.y - dragStart.y
                )

                MainActor.assumeIsolated {
                    canvasState.selectionOffset = offset
                }
                view.setNeedsDisplay()

                if hypot(offset.x, offset.y) > 5 {
                    print("Dragging selection with offset: \(offset)")
                }
                return
            }

            // Handle selection tools
            if currentTool == .rectangleSelect, let startScreen = marqueeStartScreen {
                // Build the 4 screen-axis-aligned corners of the user's drag,
                // then transform each to doc space. This gives a rotated quad
                // in doc space under canvas rotation — matching what the user
                // sees. Using doc-space min/max would make the selection
                // axis-aligned in DOC space, which visually diverges from the
                // user's drag whenever rotation is non-zero.
                let endScreen = latestScreenLocation
                let corners = marqueeCorners(screenStart: startScreen, screenEnd: endScreen)
                let docCorners: [CGPoint] = corners.map {
                    canvasState?.screenToDocument($0) ?? $0
                }

                if let canvasState = canvasState {
                    Task { @MainActor in
                        canvasState.previewSelection = nil
                        canvasState.previewLassoPath = docCorners
                    }
                }
                return
            }

            if currentTool == .lasso {
                // For lasso, append every coalesced sample so the path captures fine detail
                // on Apple Pencil (~240 Hz) instead of the ~60 Hz top-level events.
                let samples = event?.coalescedTouches(for: touch) ?? [touch]
                for sample in samples {
                    let sampleScreen = sample.location(in: view)
                    let sampleDoc = canvasState?.screenToDocument(sampleScreen) ?? sampleScreen
                    lassoPath.append(sampleDoc)
                }

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

            // Check if this is a shape tool
            let isShapeTool = [.line, .rectangle, .circle].contains(currentTool)

            if isShapeTool, let startPoint = shapeStartPoint {
                // Shape tools only care about start/end; use the latest coalesced sample.
                let endPressure = computePressure(for: touch)
                // Rectangle and circle should be SCREEN-axis-aligned regardless
                // of canvas rotation/zoom/pan. We generate their path in
                // screen space and map each point back through screenToDocument
                // — which undoes the active canvas transform — so that when
                // the committed stamps are displayed via the compositor
                // (which re-applies the transform) they end up screen-aligned.
                // Line is rotation-invariant so it stays in doc space.
                if let canvasState = canvasState,
                   let startScreen = shapeStartScreen,
                   (currentTool == .rectangle || currentTool == .circle) {
                    // Generate the shape in SCREEN space with the same
                    // generator (it's coordinate-agnostic), then map each
                    // point back through screenToDocument.
                    let endScreen = latestScreenLocation
                    let screenPoints = generateShapePoints(
                        from: startScreen,
                        to: endScreen,
                        tool: currentTool,
                        pressure: endPressure,
                        timestamp: touch.timestamp
                    )
                    stroke.points = screenPoints.map { sp in
                        BrushStroke.StrokePoint(
                            location: canvasState.screenToDocument(sp.location),
                            pressure: sp.pressure,
                            timestamp: sp.timestamp
                        )
                    }
                } else {
                    stroke.points = generateShapePoints(
                        from: startPoint,
                        to: latestLocation,
                        tool: currentTool,
                        pressure: endPressure,
                        timestamp: touch.timestamp
                    )
                }
                currentStroke = stroke
            } else {
                // Regular brush/eraser: iterate every coalesced sample so Apple Pencil
                // input at 240 Hz isn't undersampled. For each sample, keep the original
                // distance/spacing interpolation from the previous committed point, which
                // is what produces smooth curves at low sample rates.
                let samples = event?.coalescedTouches(for: touch) ?? [touch]

                for sample in samples {
                    let sampleScreen = sample.location(in: view)
                    let sampleLoc = canvasState?.screenToDocument(sampleScreen) ?? sampleScreen
                    let samplePressure = computePressure(for: sample)
                    let sampleTimestamp = sample.timestamp

                    if let last = lastPoint {
                        let distance = hypot(sampleLoc.x - last.x, sampleLoc.y - last.y)
                        let spacing = brushSettings.size * brushSettings.spacing

                        if distance > spacing {
                            let steps = Int(ceil(distance / spacing))
                            for i in 1...steps {
                                let t = CGFloat(i) / CGFloat(steps)
                                let interpLocation = CGPoint(
                                    x: last.x + (sampleLoc.x - last.x) * t,
                                    y: last.y + (sampleLoc.y - last.y) * t
                                )
                                let previousPressure = stroke.points.last?.pressure ?? samplePressure
                                // NaN-guard the interpolation. If either
                                // operand isn't finite, fall back to a safe
                                // value. Without these guards a single bad
                                // Pencil sample (NaN force) propagates NaN
                                // through every subsequent point in the
                                // stroke via previousPressure, and the
                                // entire rest of the stroke fails to render.
                                let safePrev = previousPressure.isFinite ? previousPressure : samplePressure
                                let safeSample = samplePressure.isFinite ? samplePressure : 1.0
                                let interpPressure = (lastTimestamp > 0)
                                    ? (1 - t) * safePrev + t * safeSample
                                    : safeSample

                                stroke.points.append(BrushStroke.StrokePoint(
                                    location: interpLocation,
                                    pressure: interpPressure.isFinite ? interpPressure : 1.0,
                                    timestamp: sampleTimestamp
                                ))
                            }
                            // Only advance lastPoint AFTER stamps are
                            // committed. Updating it on every sample
                            // unconditionally caused the "large brush
                            // doesn't draw" bug: at brush size 200 with
                            // default spacing 0.1 the threshold is 20 doc
                            // pixels, but Pencil samples land ~2 doc px
                            // apart at typical drawing speed. With the
                            // unconditional update, distance "reset" every
                            // sample and never accumulated past 20 → no
                            // stamps ever fired → user lifted with a
                            // single-stamp stroke. Now distance accumulates
                            // from the last stamped point until it earns
                            // a stamp.
                            lastPoint = sampleLoc
                            lastTimestamp = sampleTimestamp
                        }
                        // else: distance < spacing — keep lastPoint where
                        // it was so subsequent samples can accumulate.
                    } else {
                        // Defensive: if lastPoint is somehow nil mid-stroke
                        // (shouldn't happen — touchesBegan seeds it), seed
                        // here so the next sample has an anchor.
                        lastPoint = sampleLoc
                        lastTimestamp = sampleTimestamp
                    }
                }

                currentStroke = stroke

                // Print every 10th point to avoid spam
                if stroke.points.count % 10 == 0 {
                    print("touchesMoved: stroke has \(stroke.points.count) points (coalesced samples: \(samples.count))")
                }
            }

            // No need to call setNeedsDisplay - continuous drawing is enabled
        }

        func touchesEnded(_ touches: Set<UITouch>, in view: MTKView, with event: UIEvent?) {
            print("=== TOUCH ENDED ===")

            // Handle ending a selection drag
            if isDraggingSelection {
                print("Finished dragging selection, committing to layer")
                isDraggingSelection = false
                selectionDragStart = nil

                // Move-tool whole-layer drag goes through the in-place blit
                // path (single GPU pass, no UIImage ever built). Floating-
                // texture drags (rect/lasso, or move on top of an existing
                // selection) go through the GPU composite path.
                if let canvasState = canvasState {
                    Task { @MainActor in
                        if canvasState.isTranslatingActiveLayer {
                            canvasState.commitActiveLayerTranslation()
                        } else {
                            canvasState.commitSelection()
                        }
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

            if currentTool == .rectangleSelect, let startScreen = marqueeStartScreen {
                // Build the 4 screen-axis-aligned corners, map each to doc space.
                // Under rotation this produces a rotated quad in doc space that
                // exactly matches what the user dragged on screen.
                let endScreen = screenEndLocation
                let corners = marqueeCorners(screenStart: startScreen, screenEnd: endScreen)
                let docCorners: [CGPoint] = corners.map {
                    canvasState?.screenToDocument($0) ?? $0
                }
                print("Rectangle select: creating polygon selection with corners \(docCorners)")

                // Store selection in canvas state as a 4-point polygon and
                // extract pixels via the lasso code path. activeSelection stays
                // nil — selectionPath is the ground truth under rotation.
                if let canvasState = canvasState {
                    Task { @MainActor in
                        canvasState.previewSelection = nil
                        canvasState.previewLassoPath = nil
                        canvasState.activeSelection = nil
                        canvasState.selectionPath = docCorners
                        print("Rectangle selection created as polygon: \(docCorners)")
                        canvasState.extractSelectionPixels()
                        // Floating texture is now composited on top of the
                        // active layer (which has the hole) by the draw loop —
                        // no need to render anything back into the layer.
                        view.setNeedsDisplay()
                    }
                }

                shapeStartPoint = nil
                shapeStartScreen = nil
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
                shapeStartScreen = nil
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
                shapeStartScreen = nil
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
                        // Extract pixels for moving. Floating texture is now
                        // composited on top of the active layer by the draw
                        // loop, so we don't need to render the pixels back into
                        // the layer at original position.
                        canvasState.extractSelectionPixels()
                        view.setNeedsDisplay()
                    }
                }

                // Clear lasso path
                lassoPath = []
                shapeStartPoint = nil
                shapeStartScreen = nil
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
                // IMPORTANT: Pass document size (not texture size) to ensure 1:1 coordinate mapping
                let documentSize = MainActor.assumeIsolated { canvasState?.documentSize ?? view.bounds.size }
                print("✏️ Drawing to Layer \(selectedLayerIndex) '\(layer.name)' - Texture ID: \(ObjectIdentifier(texture))")
                print("  Texture size: \(texture.width)x\(texture.height)")
                print("  Document size: \(documentSize.width)x\(documentSize.height)")

                // Capture snapshot BEFORE rendering stroke
                print("Capturing BEFORE snapshot...")
                let beforeSnapshot = renderer.captureSnapshot(of: texture)
                if beforeSnapshot == nil {
                    print("WARNING: Failed to capture before snapshot")
                }

                // Render the stroke (stroke points are in document/texture space already)
                renderer.renderStroke(stroke, to: texture, screenSize: documentSize)
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
            shapeStartScreen = nil
            marqueeStartScreen = nil
            print("Stroke cleared from preview, should now be visible in layer texture")
        }

        func touchesCancelled(_ touches: Set<UITouch>, in view: MTKView, with event: UIEvent?) {
            currentStroke = nil
            lastPoint = nil
            shapeStartPoint = nil
            shapeStartScreen = nil
            marqueeStartScreen = nil
            lassoPath = []
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

            // Bug 1.4: previously when start == end both radii were 0, so the Ramanujan
            // ellipse-perimeter formula below did 0/0 → NaN → `Int(perimeter/spacing)`
            // trapped and crashed the app. Guard against a degenerate circle (any point
            // drag < 1 pixel) and against non-positive spacing.
            let spacing = brushSettings.size * brushSettings.spacing
            guard radiusX > 0.5 || radiusY > 0.5 else {
                // Too small to be a meaningful shape; emit nothing.
                return []
            }
            guard spacing > 0 else { return [] }

            // Calculate number of points based on perimeter approximation
            // Ramanujan's approximation for ellipse perimeter
            let h = pow((radiusX - radiusY), 2) / pow((radiusX + radiusY), 2)
            let perimeter = .pi * (radiusX + radiusY) * (1 + (3 * h) / (10 + sqrt(4 - 3 * h)))
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

        // MARK: - Selection Helpers

        /// Check if a point is inside the current selection
        @MainActor
        /// Build the 4 corners of the screen-axis-aligned rectangle defined by
        /// the user's drag endpoints. Order: TL, TR, BR, BL — a closed quad
        /// suitable for point-in-polygon testing after mapping to doc space.
        private func marqueeCorners(screenStart: CGPoint, screenEnd: CGPoint) -> [CGPoint] {
            let minX = min(screenStart.x, screenEnd.x)
            let minY = min(screenStart.y, screenEnd.y)
            let maxX = max(screenStart.x, screenEnd.x)
            let maxY = max(screenStart.y, screenEnd.y)
            return [
                CGPoint(x: minX, y: minY),
                CGPoint(x: maxX, y: minY),
                CGPoint(x: maxX, y: maxY),
                CGPoint(x: minX, y: maxY)
            ]
        }

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

            // Extract BGRA color components (Metal uses BGRA format).
            // Stored values are premultiplied by alpha (per the brush fragment
            // shader), so divide RGB by alpha to recover the visible color.
            let pixelIndex = x * 4
            let bp = CGFloat(pixelData[pixelIndex])     / 255.0
            let gp = CGFloat(pixelData[pixelIndex + 1]) / 255.0
            let rp = CGFloat(pixelData[pixelIndex + 2]) / 255.0
            let a  = CGFloat(pixelData[pixelIndex + 3]) / 255.0

            // Bail on transparent pixels — picking "nothing" should be a no-op,
            // not silently set the brush to fully transparent black.
            guard a > 0.01 else {
                print("Eyedropper: pixel at \(point) is transparent, ignoring")
                return nil
            }

            let r = min(rp / a, 1.0)
            let g = min(gp / a, 1.0)
            let b = min(bp / a, 1.0)

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
                // CRITICAL: capture `gesture.scale` synchronously BEFORE resetting and
                // BEFORE dispatching state mutation. Previously the read lived inside
                // `Task { @MainActor in … }`, which ran after `gesture.scale = 1.0`
                // executed later on the same runloop turn, so the effective scale delta
                // was always 1.0 and zoom never changed (device bug report).
                let scaleDelta = gesture.scale
                gesture.scale = 1.0

                guard scaleDelta.isFinite, scaleDelta > 0 else { return }

                // Gesture callbacks are main-actor; run the mutation synchronously.
                MainActor.assumeIsolated {
                    let newScale = canvasState.zoomScale * scaleDelta
                    canvasState.zoom(scale: newScale, centerPoint: location)
                }

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
                gesture.setTranslation(.zero, in: view)

                guard translation.x.isFinite, translation.y.isFinite else { return }

                MainActor.assumeIsolated {
                    canvasState.pan(delta: translation)
                }

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
                // Capture delta BEFORE resetting. Do NOT snap during `.changed`: the
                // previous code passed `snapToGrid: true` on every incremental event,
                // which at 60 Hz rounded each small delta to the nearest 15° and
                // produced "rotation jumps by 130°+ per gesture" (device bug report).
                // We accumulate the raw delta here and snap only on `.ended`.
                // UIRotationGestureRecognizer reports clockwise as positive
                // (UIKit Y-down), but the shader rotates in Y-up space, so
                // negate to match the user's finger direction.
                let rotationAngle = Angle(radians: -gesture.rotation)
                gesture.rotation = 0

                guard rotationAngle.radians.isFinite else { return }

                MainActor.assumeIsolated {
                    canvasState.rotate(by: rotationAngle, snapToGrid: false)
                }

            case .ended:
                print("Rotation ended, final rotation: \(canvasState.canvasRotation.degrees)°")

                // Optionally snap to nearest 90° on release if very close.
                MainActor.assumeIsolated {
                    let currentDegrees = canvasState.canvasRotation.degrees
                    let nearest90 = round(currentDegrees / 90) * 90
                    if abs(currentDegrees - nearest90) < 5 {
                        canvasState.canvasRotation = .degrees(nearest90)
                        print("Snapped to nearest 90°: \(nearest90)°")
                    }
                }

            default:
                break
            }
        }

        // MARK: - UIGestureRecognizerDelegate

        /// Allow pinch, pan, and rotation to recognize simultaneously with each other,
        /// but NOT with any non-transform recognizer that might get attached (e.g. system
        /// edge gestures). Previously this returned `true` unconditionally, which let the
        /// MTKView's internal touch path race with our transform gestures and effectively
        /// prevented pan/pinch from ever winning on device (bug 1.2).
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return Coordinator.isTransformGesture(gestureRecognizer)
                && Coordinator.isTransformGesture(otherGestureRecognizer)
        }

        /// Allow transform gestures to begin even mid-stroke. When UIKit then claims the
        /// touches for the gesture, it will call `touchesCancelled` on the MTKView, which
        /// clears `currentStroke` via `touchesCancelled(_:in:)` above. Previously this
        /// returned `false` whenever a stroke was in progress, which meant any 2-finger
        /// pan/pinch/rotation was rejected because `touchesBegan` had already started a
        /// stroke on the first finger (bug 1.2).
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if Coordinator.isTransformGesture(gestureRecognizer) {
                return true
            }
            // Non-transform gestures (should be none on our MTKView) fall back to the
            // previous conservative behavior.
            return currentStroke == nil
        }

        private static func isTransformGesture(_ gr: UIGestureRecognizer) -> Bool {
            return gr is UIPinchGestureRecognizer
                || gr is UIPanGestureRecognizer
                || gr is UIRotationGestureRecognizer
        }
    }
}

// Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
