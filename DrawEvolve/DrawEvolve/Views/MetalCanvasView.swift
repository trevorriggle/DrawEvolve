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
    /// Callback for the .textOnPath tool **in freehand mode**. Fires on
    /// touchesEnded with the raw doc-space stroke samples plus the
    /// screen-space first/last touch points (used by
    /// `PathSmoothing.isClosedByEndpoint` and the 30pt closed-loop
    /// threshold). Owner calls `canvasState.beginTextOnPath(...)`.
    var onTextOnPathRequest: ((_ rawPoints: [CGPoint],
                               _ firstScreen: CGPoint,
                               _ lastScreen: CGPoint) -> Void)?

    /// Callback for the .textOnPath tool **in circle mode**. Fires on
    /// touchesEnded with the doc-space center (touchdown location) and
    /// radius (Euclidean distance from center to lift location). Owner
    /// calls `canvasState.beginTextOnPathCircle(...)`.
    var onTextOnPathCircleRequest: ((_ center: CGPoint,
                                     _ radius: CGFloat) -> Void)?

    /// Which input mode the .textOnPath tool currently uses. Toggled by
    /// the user via the top-center pill in DrawingCanvasView. Read by
    /// the touch handlers to branch between freehand polyline capture
    /// and tap-center / drag-radius capture. Defaults to `.freehand`
    /// so the iPhone caller (which doesn't expose path-text input) can
    /// omit the parameter.
    var typeOnPathMode: TypeOnPathPathMode = .freehand

    /// Global symmetry / mirror config. Plain reference (not @ObservedObject)
    /// — the touch handlers read `symmetry.mode` per-stamp; we don't need
    /// SwiftUI re-evaluations of MetalCanvasView when the mode flips. Same
    /// pattern as `canvasState`.
    var symmetry: SymmetryConfig

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

        // Push the latest typeOnPathMode value into the Coordinator on
        // every render. The pill toggle in DrawingCanvasView updates an
        // @AppStorage-backed value passed in here; the Coordinator
        // branches on this in the .textOnPath touch handlers.
        context.coordinator.typeOnPathMode = typeOnPathMode

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
            onTextRequest: onTextRequest,
            onTextOnPathRequest: onTextOnPathRequest,
            onTextOnPathCircleRequest: onTextOnPathCircleRequest,
            typeOnPathMode: typeOnPathMode,
            symmetry: symmetry
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
        private var onTextOnPathRequest: ((_ rawPoints: [CGPoint],
                                          _ firstScreen: CGPoint,
                                          _ lastScreen: CGPoint) -> Void)?
        private var onTextOnPathCircleRequest: ((_ center: CGPoint,
                                                _ radius: CGFloat) -> Void)?
        /// Updated from `MetalCanvasView.updateUIView` so the Coordinator
        /// always sees the live mode value. Read in the .textOnPath
        /// touch handlers to branch between freehand polyline capture
        /// and tap-center / drag-radius capture.
        var typeOnPathMode: TypeOnPathPathMode = .freehand
        private let symmetry: SymmetryConfig

        // textOnPath circle-mode state. `circleDrawingCenter` is the
        // touch-down location (doc space); set in touchesBegan when the
        // mode is `.circle`. Cleared on touchesEnded / Cancelled.
        private var circleDrawingCenter: CGPoint?

        // textOnPath path-drawing state. Populated during touchesMoved while
        // the .textOnPath tool is active; flushed to onTextOnPathRequest in
        // touchesEnded. Doc-space samples; screen-space firstScreen +
        // lastScreen used by the 30pt closed-loop endpoint threshold.
        private var textOnPathRawPoints: [CGPoint] = []
        private var textOnPathFirstScreen: CGPoint = .zero
        private var textOnPathLastScreen: CGPoint = .zero
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

        // Blur Adjustment scrubber state.
        // Anchor for horizontal drag (touchdown screen point) + the sigma value
        // captured at touchdown. Each new drag re-anchors so values don't
        // accumulate across drags. lastUpdateAt throttles preview re-renders
        // to ~30 fps regardless of pencil sample rate.
        private var blurAdjustmentTouchStartScreen: CGPoint?
        private var blurAdjustmentTouchStartSigma: Float = 0.0
        private var blurAdjustmentLastUpdateAt: TimeInterval = 0
        private static let blurAdjustmentThrottleInterval: TimeInterval = 1.0 / 30.0

        // Smudge tool state (PR 2).
        // Smudge is stamp-as-you-go (each stamp depends on the previous
        // stamp's deposit), so it doesn't go through `currentStroke` /
        // `touchesEnded`'s batch-dispatch path. Instead the renderer holds
        // ping-pong patch textures across the stroke; we dispatch new
        // stamps from `touchesMoved` and capture the undo snapshot pair
        // around the whole stroke (before in `touchesBegan`, after in
        // `touchesEnded`).
        private var isSmudgeStrokeActive = false
        private var smudgeStrokeLayerIndex: Int?
        private var smudgeStrokeLayerId: UUID?
        // Stamp 0 of the stroke is the touchdown point — captured here in
        // `touchesBegan` and prepended to the first `renderSmudgeStamps`
        // batch in `touchesMoved` (so it dispatches as the pickup-only
        // first stamp). Cleared after the first batch.
        private var smudgePendingTouchdown: BrushStroke.StrokePoint?
        private var smudgeBeforeSnapshot: Data?

        // Eraser real-time commit (Tier 1.5). The gray-ghost preview is
        // gone — eraser stamps now write straight into the active layer
        // texture as they arrive, and the every-frame layer composite
        // picks up the cuts. We capture `eraserBeforeSnapshot` once at
        // touchesBegan so undo and touchesCancelled have an authoritative
        // pre-stroke state to roll back to (the layer mutates throughout
        // the stroke, so capturing at touchesEnded — like the brush path
        // does — would record post-mutation pixels).
        // `eraserCommittedPointCount` tracks how many points of
        // `currentStroke` have already been rendered into the layer, so
        // each touchesMoved only flushes the *new* sub-stroke instead of
        // re-rendering the whole accumulated stroke.
        private var eraserBeforeSnapshot: Data?
        private var eraserCommittedPointCount: Int = 0

        // FloatingText body-drag state. The transform handles overlay (a
        // SwiftUI sibling) handles scale/rotate via .gesture; this path
        // covers the body-drag (move) gesture inside the canvas's MTKView.
        private var isDraggingFloatingText = false
        private var floatingTextDragStartDoc: CGPoint?
        private var floatingTextDragOriginAnchor: CGPoint?

        // Snap-to-line state. While a brush/eraser/blur stroke is in progress,
        // a 600ms stationary timer waits for the touch to settle (<2pt screen-
        // space movement) and then replaces the wobbly in-progress geometry
        // with a clean straight line from the stroke's first point to the
        // current touch position. Continued movement after engagement keeps
        // updating the endpoint (with 15° snap when within 3° of an
        // increment); lift commits as a normal stroke through the existing
        // touchesEnded path.
        private var snapToLineTimer: Timer?
        private var isSnappedToLine = false
        private var snapToLineStartDoc: CGPoint?
        private var snapToLineAnchorScreen: CGPoint?
        private var snapLatestDoc: CGPoint = .zero
        private var snapLatestPressure: CGFloat = 1.0
        private var snapLatestTimestamp: TimeInterval = 0
        private static let snapToLineHoldDuration: TimeInterval = 0.6
        private static let snapToLineMovementThreshold: CGFloat = 2.0   // screen pts
        private static let snapToLineAngleIncrement: CGFloat = 15.0     // degrees
        private static let snapToLineAngleTolerance: CGFloat = 3.0      // degrees

        init(
            layers: Binding<[DrawingLayer]>,
            currentTool: Binding<DrawingTool>,
            brushSettings: Binding<BrushSettings>,
            selectedLayerIndex: Binding<Int>,
            canvasState: CanvasStateManager?,
            onTextRequest: ((CGPoint) -> Void)?,
            onTextOnPathRequest: ((_ rawPoints: [CGPoint],
                                  _ firstScreen: CGPoint,
                                  _ lastScreen: CGPoint) -> Void)?,
            onTextOnPathCircleRequest: ((_ center: CGPoint,
                                        _ radius: CGFloat) -> Void)?,
            typeOnPathMode: TypeOnPathPathMode,
            symmetry: SymmetryConfig
        ) {
            _layers = layers
            _currentTool = currentTool
            _brushSettings = brushSettings
            _selectedLayerIndex = selectedLayerIndex
            self.canvasState = canvasState
            self.onTextRequest = onTextRequest
            self.onTextOnPathRequest = onTextOnPathRequest
            self.onTextOnPathCircleRequest = onTextOnPathCircleRequest
            self.typeOnPathMode = typeOnPathMode
            self.symmetry = symmetry

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

            // Reuse the renderer's long-lived command queue instead of
            // allocating a new MTLCommandQueue per frame. A queue is meant to
            // live for the device's lifetime; allocating one each draw was
            // pure overhead on every tool, every frame.
            guard let drawCommandQueue = renderer?.commandQueue,
                  let commandBuffer = drawCommandQueue.makeCommandBuffer(),
                  let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            // Get zoom, pan, rotation, and flip state for rendering
            let zoomScale = MainActor.assumeIsolated {
                canvasState?.zoomScale ?? 1.0
            }
            let panOffset = MainActor.assumeIsolated {
                canvasState?.panOffset ?? .zero
            }
            let rotation = MainActor.assumeIsolated {
                canvasState?.canvasRotation.radians ?? 0.0
            }
            let flipH = MainActor.assumeIsolated { canvasState?.flipHorizontal ?? false }
            let flipV = MainActor.assumeIsolated { canvasState?.flipVertical ?? false }
            let flipState = SIMD2<Float>(flipH ? 1 : 0, flipV ? 1 : 0)

            // Draw opaque white canvas background so the gray workbench
            // doesn't show through transparent layer regions
            renderer?.renderCanvasBackground(
                to: renderEncoder,
                zoomScale: Float(zoomScale),
                panOffset: SIMD2<Float>(Float(panOffset.x), Float(panOffset.y)),
                canvasRotation: Float(rotation),
                viewportSize: SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height)),
                flipState: flipState
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
                selectionRotationRad,
                documentSize
            ): (Bool, Int, MTLTexture?, CGRect?, CGPoint, CGSize, CGFloat, CGSize) = MainActor.assumeIsolated {
                guard let canvasState = canvasState else {
                    return (false, -1, MTLTexture?.none, CGRect?.none, CGPoint.zero,
                            CGSize(width: 1, height: 1), CGFloat(0), CGSize.zero)
                }
                return (
                    canvasState.isTranslatingActiveLayer,
                    canvasState.selectedLayerIndex,
                    canvasState.floatingSelectionTexture,
                    canvasState.selectionOriginalRect,
                    canvasState.selectionOffset,
                    canvasState.selectionScale,
                    canvasState.selectionRotation.radians,
                    canvasState.documentSize
                )
            }

            // Composite all visible layers to screen with zoom/pan/rotation transform.
            // When the move tool is mid-drag with no rect/lasso selection, the
            // active layer is rendered at an offset doc rect so the user sees
            // a real-time preview without any per-frame texture writes.
            for (index, layer) in layers.enumerated() where layer.isVisible {
                // Blur adjustment preview swap: while the blurAdjustment tool
                // is active for this layer, the renderer hosts a preview
                // texture (filterPreviewTexture) holding the live-blurred
                // result. Display that instead of the layer's own texture so
                // the user sees the in-progress blur until they ✓/✕.
                let displayTexture: MTLTexture? = {
                    if index == activeLayerIndex,
                       let preview = renderer?.blurAdjustmentPreviewTexture(forLayer: layer.id) {
                        return preview
                    }
                    return layer.texture
                }()
                guard let texture = displayTexture else { continue }

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
                        viewportSize: SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height)),
                        flipState: flipState
                    )
                } else {
                    renderer?.renderTextureToScreen(
                        texture,
                        to: renderEncoder,
                        opacity: layer.opacity,
                        zoomScale: Float(zoomScale),
                        panOffset: SIMD2<Float>(Float(panOffset.x), Float(panOffset.y)),
                        canvasRotation: Float(rotation),
                        viewportSize: SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height)),
                        flipState: flipState
                    )
                }
            }

            // Floating selection (rect/lasso, or move on top of an existing
            // selection, or imported image). The active layer has a hole
            // (or is empty for imports); the floating texture is composited
            // on top at originalRect + offset, scaled per-axis and rotated
            // around its center, every frame.
            if let floating = floatingTexture, let original = selectionOriginalRect {
                let docRect = CGRect(
                    x: original.origin.x + selectionOffsetDoc.x,
                    y: original.origin.y + selectionOffsetDoc.y,
                    width: original.width * selectionScale.width,
                    height: original.height * selectionScale.height
                )
                renderer?.renderFloatingTexture(
                    floating,
                    atDocRect: docRect,
                    rotation: Float(selectionRotationRad),
                    to: renderEncoder,
                    opacity: 1.0,
                    zoomScale: Float(zoomScale),
                    panOffset: SIMD2<Float>(Float(panOffset.x), Float(panOffset.y)),
                    canvasRotation: Float(rotation),
                    viewportSize: SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height)),
                    flipState: flipState
                )
            }

            // FloatingText live preview. Composited on top of the layer
            // stack (and any floating selection) using the same shader the
            // floating selection uses — rotation included. The text's
            // doc-space `displayedRect` already encodes scale, so we don't
            // pass a scale uniform.
            let (floatingTextTexture, floatingTextDocRect, floatingTextRotation): (MTLTexture?, CGRect, CGFloat) = MainActor.assumeIsolated {
                guard let ft = canvasState?.floatingText, let tex = ft.cachedTexture else {
                    return (MTLTexture?.none, CGRect.zero, CGFloat(0))
                }
                return (tex, ft.displayedRect, ft.rotation.radians)
            }
            if let ftTex = floatingTextTexture, floatingTextDocRect.width > 0, floatingTextDocRect.height > 0 {
                renderer?.renderFloatingTexture(
                    ftTex,
                    atDocRect: floatingTextDocRect,
                    rotation: Float(floatingTextRotation),
                    to: renderEncoder,
                    opacity: 1.0,
                    zoomScale: Float(zoomScale),
                    panOffset: SIMD2<Float>(Float(panOffset.x), Float(panOffset.y)),
                    canvasRotation: Float(rotation),
                    viewportSize: SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height)),
                    flipState: flipState
                )
            }

            // IMPORTANT: Render current stroke preview on top
            // Preview stroke points are in document space, so apply transforms for display.
            // Skip the preview for the blur tool — its in-progress stamps don't
            // produce visible color (the blur output materialises only on commit).
            // The stamp cursor SwiftUI overlay handles user feedback during the drag.
            // Skip the eraser too (Tier-1.5): eraser stamps now write straight
            // into the active layer texture in `touchesMoved`, and the every-
            // frame layer composite picks up the cuts — there's no separate
            // preview to draw on the drawable.
            if let stroke = currentStroke, !stroke.points.isEmpty,
               stroke.tool != .blur, stroke.tool != .eraser {
                let zoomScale = MainActor.assumeIsolated { canvasState?.zoomScale ?? 1.0 }
                let panOffset = MainActor.assumeIsolated { canvasState?.panOffset ?? .zero }
                let rotation = MainActor.assumeIsolated { canvasState?.canvasRotation.radians ?? 0.0 }
                let flipH = MainActor.assumeIsolated { canvasState?.flipHorizontal ?? false }
                let flipV = MainActor.assumeIsolated { canvasState?.flipVertical ?? false }

                renderer?.renderStrokePreview(
                    stroke,
                    to: renderEncoder,
                    viewportSize: view.bounds.size,
                    drawableSize: view.drawableSize,
                    zoomScale: zoomScale,
                    panOffset: panOffset,
                    canvasRotation: rotation,
                    flipHorizontal: flipH,
                    flipVertical: flipV
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

            // Active-layer bounds guard. Multiple downstream sites in this
            // function index `layers[selectedLayerIndex]` without a local
            // bounds check (e.g. the brush-stroke path's
            // `layerId: layers[selectedLayerIndex].id`). If the canvas state
            // ever transiently holds an empty `layers` array (or a stale
            // index), the unguarded subscript would crash. Bail silently
            // here — touches with no valid active layer are no-ops.
            guard !layers.isEmpty,
                  layers.indices.contains(selectedLayerIndex) else {
                print("⚠️ touchesBegan ignored: no valid active layer (layers.count=\(layers.count), selectedLayerIndex=\(selectedLayerIndex))")
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

            // Handle blur adjustment tool — horizontal-drag scrubber for sigma.
            // No stroke is created; touchdown anchors the drag, touchesMoved
            // updates sigma, touchesEnded clears the anchor.
            if currentTool == .blurAdjustment {
                blurAdjustmentTouchStartScreen = screenLocation
                if let cs = canvasState {
                    blurAdjustmentTouchStartSigma = MainActor.assumeIsolated { cs.blurAdjustmentSigma }
                }
                blurAdjustmentLastUpdateAt = touch.timestamp
                return
            }

            // Handle smudge tool — allocate ping-pong patches, capture undo
            // before-snapshot, stash the touchdown stamp for the first
            // `renderSmudgeStamps` batch in `touchesMoved`. We bypass the
            // standard `currentStroke` flow because smudge dispatches stamps
            // incrementally from `touchesMoved` (each stamp depends on the
            // layer state the previous one wrote).
            if currentTool == .smudge {
                guard selectedLayerIndex < layers.count,
                      let layerTexture = layers[selectedLayerIndex].texture,
                      let renderer = renderer else {
                    print("Smudge: cannot begin stroke — invalid layer or texture")
                    return
                }
                let layerId = layers[selectedLayerIndex].id
                // Selection geometry is fixed for the duration of a stroke;
                // pass it once at begin and the renderer rasterises + caches.
                let smudgeSelectionPath = MainActor.assumeIsolated { canvasState?.selectionPath }
                let smudgeDocSize = MainActor.assumeIsolated { canvasState?.documentSize ?? view.bounds.size }
                if !renderer.beginSmudgeStroke(brushSize: brushSettings.size,
                                               layerId: layerId,
                                               selectionPath: smudgeSelectionPath,
                                               documentSize: smudgeDocSize) {
                    print("Smudge: renderer failed to allocate patch textures")
                    return
                }
                smudgeBeforeSnapshot = renderer.captureSnapshot(of: layerTexture)
                smudgeStrokeLayerIndex = selectedLayerIndex
                smudgeStrokeLayerId = layerId
                smudgePendingTouchdown = BrushStroke.StrokePoint(
                    location: location,
                    pressure: pressure,
                    timestamp: timestamp
                )
                isSmudgeStrokeActive = true
                lastPoint = location
                lastTimestamp = timestamp

                // Stamp cursor outline — same overlay as the blur brush.
                if let cs = canvasState {
                    let diameter = stampScreenDiameter(forSize: brushSettings.size)
                    MainActor.assumeIsolated {
                        cs.stampCursorCenter = screenLocation
                        cs.stampCursorDiameter = diameter
                    }
                }
                print("Smudge: began stroke on layer \(selectedLayerIndex) at \(location)")
                return
            }

            // Handle text tool — three branches based on the current
            // FloatingText state:
            //   1. tap inside an active float's bounds → drag the body
            //   2. tap outside the bounds            → commit and consume
            //   3. no active float                    → open the input alert
            //
            // Selection masking note: text rendering goes through renderImage
            // / compositeFloatingTextureIntoLayer (the CPU/Porter-Duff path),
            // not the brush pipeline. PR #35 deliberately did NOT thread
            // selectionPath through these — same behaviour as floating
            // selection's own commit. Floating text doesn't clip against an
            // active selection mask. Deferred to v1.1; documented in the PR.
            if currentTool == .text {
                let activeFloat: FloatingText? = MainActor.assumeIsolated {
                    canvasState?.floatingText
                }
                if let ft = activeFloat {
                    if ft.containsDocPoint(location) {
                        // Body drag is plain-text only — path-bearing text
                        // can't move freely (the path is fixed). User
                        // re-positions on-path text via PathStartHandle.
                        if ft.path == nil {
                            isDraggingFloatingText = true
                            floatingTextDragStartDoc = location
                            floatingTextDragOriginAnchor = ft.anchor
                            print("Text tool: began body drag at \(location)")
                        }
                        return
                    } else {
                        // Multi-finger touchesBegan is the leading edge of an
                        // incoming pinch / two-finger-pan / rotation gesture
                        // — the gesture recognizers haven't claimed the
                        // touches yet, but the user clearly wants to
                        // navigate, not commit the float. Bail before the
                        // tap-outside-commit fires.
                        if (event?.allTouches?.count ?? 1) > 1 {
                            return
                        }
                        // Tap outside the float bakes it into the layer.
                        // The tap itself is consumed — the user has to tap
                        // again to start a new text.
                        print("Text tool: tap outside floating text → commit")
                        if let cs = canvasState {
                            MainActor.assumeIsolated { cs.commitFloatingText() }
                        }
                        return
                    }
                }
                print("Text tool: requesting text input at \(location)")
                onTextRequest?(location)
                return
            }

            // .textOnPath: tap-and-drag draws the path. The first touch
            // initialises the buffer; subsequent moves accumulate samples.
            // touchesEnded smooths + fires onTextOnPathRequest.
            if currentTool == .textOnPath {
                let activeFloat: FloatingText? = MainActor.assumeIsolated {
                    canvasState?.floatingText
                }
                if let ft = activeFloat {
                    // Tap inside the laid-out text bounds → no-op (the user
                    // shouldn't accidentally redraw the path on the text);
                    // tap outside commits and consumes. Same outside-commit
                    // semantics as plain text.
                    if ft.containsDocPoint(location) {
                        return
                    } else {
                        // Same multi-finger guard as the .text branch above —
                        // pinch / two-finger-pan / rotation begin with one
                        // touch landing before their recognizers claim, and
                        // we don't want that leading-edge touchesBegan to
                        // commit the path-text float.
                        if (event?.allTouches?.count ?? 1) > 1 {
                            return
                        }
                        print("Text-on-path: tap outside → commit")
                        if let cs = canvasState {
                            MainActor.assumeIsolated { cs.commitFloatingText() }
                        }
                        return
                    }
                }
                // Begin a new path-drawing session. Branch on the
                // current input mode (set by the toggle pill in
                // DrawingCanvasView).
                switch typeOnPathMode {
                case .freehand:
                    textOnPathRawPoints = [location]
                    textOnPathFirstScreen = screenLocation
                    textOnPathLastScreen = screenLocation
                    if let cs = canvasState {
                        MainActor.assumeIsolated {
                            cs.previewTextOnPathPoints = [location]
                        }
                    }
                case .circle:
                    // Touch-down records the circle center; touchesMoved
                    // updates the radius in the preview; touchesEnded
                    // commits via onTextOnPathCircleRequest.
                    circleDrawingCenter = location
                    if let cs = canvasState {
                        MainActor.assumeIsolated {
                            cs.previewTextOnPathCircle = TypeOnPathCirclePreview(
                                center: location,
                                radius: 0
                            )
                        }
                    }
                }
                return
            }

            // Handle paint bucket tool - flood fill
            if currentTool == .paintBucket {
                print("Paint bucket: filling at \(location)")
                guard selectedLayerIndex < layers.count,
                      let texture = layers[selectedLayerIndex].texture,
                      let renderer = renderer,
                      let canvasState = canvasState else {
                    print("ERROR: Cannot fill - invalid layer or texture")
                    return
                }

                // Re-entrancy guard: ignore taps while a previous fill is
                // still running on the background queue. The HUD over the
                // canvas also blocks hits, but this is the authoritative
                // check.
                if canvasState.isFilling {
                    print("Paint bucket: ignoring tap, fill already in progress")
                    return
                }

                // Capture before snapshot (stays on main, like other tools).
                let beforeSnapshot = renderer.captureSnapshot(of: texture)

                let documentSize = MainActor.assumeIsolated { canvasState.documentSize }
                let currentLayerIndex = selectedLayerIndex
                let layerId = layers[selectedLayerIndex].id

                let dispatched = renderer.floodFill(
                    at: location,
                    with: brushSettings.color,
                    in: texture,
                    screenSize: documentSize
                ) { [weak self] in
                    // Back on main, after texture.replace has landed.
                    let afterSnapshot = renderer.captureSnapshot(of: texture)
                    if let before = beforeSnapshot, let after = afterSnapshot {
                        canvasState.historyManager.record(.stroke(
                            layerId: layerId,
                            beforeSnapshot: before,
                            afterSnapshot: after
                        ))
                    }

                    // Update thumbnail (existing pattern). [weak self] above
                    // is what this nested block needs; the outer closure
                    // itself doesn't reference self otherwise.
                    DispatchQueue.global(qos: .utility).async {
                        if let thumbnail = renderer.generateThumbnail(from: texture, size: CGSize(width: 44, height: 44)) {
                            DispatchQueue.main.async {
                                self?.layers[currentLayerIndex].updateThumbnail(thumbnail)
                            }
                        }
                    }

                    canvasState.isFilling = false
                }

                if dispatched {
                    canvasState.isFilling = true
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

                // Tap-outside-commit: a tap that didn't fall into the floating
                // selection's hit area (or onto a transform handle, which the
                // SwiftUI overlay already consumed before reaching here) means
                // the user is choosing to act on the canvas elsewhere. Bake
                // the floating selection into its layer first, then continue
                // with the tap's normal behavior. Mirrors Procreate's
                // "tap outside to confirm transform."
                let needsCommit = MainActor.assumeIsolated {
                    canvasState.floatingSelectionTexture != nil || canvasState.isTranslatingActiveLayer
                }
                if needsCommit {
                    MainActor.assumeIsolated {
                        if canvasState.floatingSelectionTexture != nil {
                            canvasState.commitSelection()
                        } else if canvasState.isTranslatingActiveLayer {
                            canvasState.commitActiveLayerTranslation()
                        }
                    }
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

            // Symmetry: mirror the initial stamp too. A single tap (no drag)
            // should still produce mirrored stamps. `lastPoint` stays at the
            // original location only — the spacing-interpolation chain in
            // touchesMoved follows the user's actual finger/pencil path; the
            // mirrors piggyback per stamp without participating in the chain.
            let symmetryDocSize = MainActor.assumeIsolated {
                canvasState?.documentSize ?? .zero
            }
            let initialMirrors = mirroredPoints([point], in: symmetryDocSize, mode: symmetry.mode)
            let initialPoints = [point] + initialMirrors

            currentStroke = BrushStroke(
                points: initialPoints,
                settings: brushSettings,
                tool: currentTool,
                layerId: layers[selectedLayerIndex].id
            )

            lastPoint = location
            lastTimestamp = timestamp
            print("Created stroke with \(initialPoints.count) point(s) (1 + \(initialMirrors.count) mirror)")

            // Tier-1.5 eraser real-time commit. Capture the pre-stroke
            // snapshot here (not in touchesEnded — by the time the user
            // lifts, the layer is already mutated by mid-stroke writes
            // and a fresh capture would be the post-stroke state). Then
            // immediately flush the initial stamps so the very first dot
            // shows up on the layer without waiting for the next move.
            if currentTool == .eraser,
               let texture = layers[selectedLayerIndex].texture,
               let renderer = renderer {
                eraserBeforeSnapshot = renderer.captureSnapshot(of: texture)
                eraserCommittedPointCount = 0
                flushEraserSubStroke(view: view)
            }

            // Cache the selection mask for the wet-ink preview. Rasterised
            // once here and reused for every preview frame for the duration
            // of the drag — selection geometry is immutable mid-stroke
            // because the canvas owns the touch. Pairs with the cleanup in
            // touchesEnded / touchesCancelled. Blur (.blur) doesn't render
            // a preview at all, so the cache will be allocated but unused —
            // harmless; freed on lift.
            let previewSelectionPath = MainActor.assumeIsolated { canvasState?.selectionPath }
            let previewDocSize = MainActor.assumeIsolated { canvasState?.documentSize ?? view.bounds.size }
            renderer?.beginPreviewMask(selectionPath: previewSelectionPath, documentSize: previewDocSize)

            // Snap-to-line: arm the stationary timer for brush-like tools.
            // Shape tools, selection tools, and effects don't participate.
            // Mutating currentStroke.points happens upstream of the masked
            // commit path — the snapped-line stroke flows through
            // renderStroke(...,  selectionPath:) just like any wobbly stroke,
            // so the mask still applies if a selection is active.
            if canSnapToLine {
                snapToLineStartDoc = location
                snapToLineAnchorScreen = screenLocation
                snapLatestDoc = location
                snapLatestPressure = pressure
                snapLatestTimestamp = timestamp
                isSnappedToLine = false
                armStationaryTimer()
            }

            // Stamp cursor for the blur tool (smudge in PR 2). The brush
            // doesn't render a stamp preview for blur (its blurred output
            // doesn't materialise until commit), so the cursor outline is the
            // user's only feedback during the drag.
            if currentTool == .blur, let cs = canvasState {
                let diameter = stampScreenDiameter(forSize: brushSettings.size)
                MainActor.assumeIsolated {
                    cs.stampCursorCenter = screenLocation
                    cs.stampCursorDiameter = diameter
                }
            }
        }

        func touchesMoved(_ touches: Set<UITouch>, in view: MTKView, with event: UIEvent?) {
            guard let touch = touches.first else {
                print("touchesMoved: No touch in set")
                return
            }

            // Active-layer bounds guard — see touchesBegan for rationale.
            // touchesMoved indexes `layers[selectedLayerIndex]` for stroke
            // dispatch and the smudge-tool layer-id match check.
            guard !layers.isEmpty,
                  layers.indices.contains(selectedLayerIndex) else {
                return
            }

            // Latest single-point location — used by selection/preview paths that only
            // care about the most recent finger/pencil position, not every sub-sample.
            let latestScreenLocation = touch.location(in: view)
            let latestLocation = canvasState?.screenToDocument(latestScreenLocation) ?? latestScreenLocation

            // Blur adjustment scrubber — horizontal drag delta maps to sigma
            // delta from the touchdown anchor. Throttled to ~30fps so the
            // Gaussian preview keeps up with the drag without saturating the
            // GPU at 240Hz pencil sample rate.
            if currentTool == .blurAdjustment, let startScreen = blurAdjustmentTouchStartScreen,
               let cs = canvasState {
                let now = touch.timestamp
                if now - blurAdjustmentLastUpdateAt < Self.blurAdjustmentThrottleInterval {
                    return
                }
                blurAdjustmentLastUpdateAt = now

                let dragRange = max(1, view.bounds.width * 0.7)
                let delta = latestScreenLocation.x - startScreen.x
                let maxSigma = MainActor.assumeIsolated { cs.blurAdjustmentMaxSigma }
                let newSigma = blurAdjustmentTouchStartSigma + Float(delta / dragRange) * maxSigma
                Task { @MainActor in
                    cs.setBlurAdjustmentSigma(newSigma)
                }
                return
            }

            // Update stamp cursor during a blur-tool drag.
            if currentTool == .blur, let cs = canvasState {
                let diameter = stampScreenDiameter(forSize: brushSettings.size)
                MainActor.assumeIsolated {
                    cs.stampCursorCenter = latestScreenLocation
                    cs.stampCursorDiameter = diameter
                }
            }

            // Smudge: dispatch stamps incrementally — one command buffer
            // per touchesMoved call. Build a batch from coalesced samples
            // (Apple Pencil at ~240 Hz produces several samples per
            // top-level touchesMoved, same as the brush path), interpolate
            // along each segment using brushSettings.spacing, prepend the
            // pending touchdown stamp on the very first batch, and hand
            // the whole list to the renderer.
            if currentTool == .smudge, isSmudgeStrokeActive, let renderer = renderer {
                guard let strokeLayerIndex = smudgeStrokeLayerIndex,
                      let strokeLayerId = smudgeStrokeLayerId,
                      strokeLayerIndex < layers.count,
                      let layerTexture = layers[strokeLayerIndex].texture,
                      layers[strokeLayerIndex].id == strokeLayerId else {
                    // Layer changed mid-stroke (or texture went away).
                    // Sanity-assert and bail. The renderer's own assert in
                    // `renderSmudgeStamps` is the authoritative guard;
                    // this is the early-out so we don't even try.
                    assertionFailure("Smudge: layer mismatch during touchesMoved")
                    return
                }

                var batch: [BrushStroke.StrokePoint] = []
                if let touchdown = smudgePendingTouchdown {
                    batch.append(touchdown)
                    smudgePendingTouchdown = nil
                }

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
                                let prevPressure = batch.last?.pressure ?? samplePressure
                                let safePrev = prevPressure.isFinite ? prevPressure : samplePressure
                                let safeSample = samplePressure.isFinite ? samplePressure : 1.0
                                let interpPressure = (1 - t) * safePrev + t * safeSample
                                batch.append(BrushStroke.StrokePoint(
                                    location: interpLocation,
                                    pressure: interpPressure.isFinite ? interpPressure : 1.0,
                                    timestamp: sampleTimestamp
                                ))
                            }
                            lastPoint = sampleLoc
                            lastTimestamp = sampleTimestamp
                        }
                    } else {
                        lastPoint = sampleLoc
                        lastTimestamp = sampleTimestamp
                    }
                }

                if !batch.isEmpty {
                    let docSize = MainActor.assumeIsolated {
                        canvasState?.documentSize ?? view.bounds.size
                    }
                    renderer.renderSmudgeStamps(
                        batch,
                        settings: brushSettings,
                        to: layerTexture,
                        layerId: strokeLayerId,
                        screenSize: docSize
                    )
                }

                // Stamp cursor follows the finger.
                if let cs = canvasState {
                    let diameter = stampScreenDiameter(forSize: brushSettings.size)
                    MainActor.assumeIsolated {
                        cs.stampCursorCenter = latestScreenLocation
                        cs.stampCursorDiameter = diameter
                    }
                }
                return
            }

            // .textOnPath: accumulate raw doc-space samples while the user
            // drags out the path. Coalesced touches at ~240 Hz give us a
            // dense polyline; PathSmoothing.catmullRom is what cleans it
            // up at lift. Live preview is the same array, published via
            // canvasState.previewTextOnPathPoints for the SwiftUI overlay.
            if currentTool == .textOnPath, !textOnPathRawPoints.isEmpty {
                let samples = event?.coalescedTouches(for: touch) ?? [touch]
                for sample in samples {
                    let sampleScreen = sample.location(in: view)
                    let sampleDoc = canvasState?.screenToDocument(sampleScreen) ?? sampleScreen
                    textOnPathRawPoints.append(sampleDoc)
                    textOnPathLastScreen = sampleScreen
                }
                if let cs = canvasState {
                    let copy = textOnPathRawPoints
                    MainActor.assumeIsolated {
                        cs.previewTextOnPathPoints = copy
                    }
                }
                return
            }

            // textOnPath circle-mode: update the radius preview as the
            // user drags away from the touch-down center. `latestLocation`
            // is already in doc-space (computed at the top of
            // touchesMoved).
            if currentTool == .textOnPath, let center = circleDrawingCenter {
                let radius = hypot(latestLocation.x - center.x,
                                   latestLocation.y - center.y)
                if let cs = canvasState {
                    MainActor.assumeIsolated {
                        cs.previewTextOnPathCircle = TypeOnPathCirclePreview(
                            center: center,
                            radius: radius
                        )
                    }
                }
                return
            }

            // FloatingText body drag — update anchor in doc space. The
            // floating-text texture composites at the new anchor on the
            // next frame via renderFloatingTexture in draw().
            if isDraggingFloatingText,
               let start = floatingTextDragStartDoc,
               let originalAnchor = floatingTextDragOriginAnchor,
               let cs = canvasState {
                let newAnchor = CGPoint(
                    x: originalAnchor.x + (latestLocation.x - start.x),
                    y: originalAnchor.y + (latestLocation.y - start.y)
                )
                MainActor.assumeIsolated {
                    cs.floatingText?.anchor = newAnchor
                }
                view.setNeedsDisplay()
                return
            }

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
                let originals: [BrushStroke.StrokePoint]
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
                    originals = screenPoints.map { sp in
                        BrushStroke.StrokePoint(
                            location: canvasState.screenToDocument(sp.location),
                            pressure: sp.pressure,
                            timestamp: sp.timestamp
                        )
                    }
                } else {
                    originals = generateShapePoints(
                        from: startPoint,
                        to: latestLocation,
                        tool: currentTool,
                        pressure: endPressure,
                        timestamp: touch.timestamp
                    )
                }
                // Symmetry: shape stroke.points are wholesale-replaced on
                // every touchesMoved (the current shape is regenerated as
                // the user drags). Pass the SAME mirroredPoints function
                // that the brush/eraser path uses — guaranteed identical
                // mirror rules — and replace with originals + mirrors.
                let docSize = MainActor.assumeIsolated {
                    canvasState?.documentSize ?? .zero
                }
                let mirrors = mirroredPoints(originals, in: docSize, mode: symmetry.mode)
                stroke.points = originals + mirrors
                currentStroke = stroke
            } else {
                // Snap-to-line: track latest sample and stationarity for the
                // 600ms hold-to-snap timer. Once snapped, replace the in-progress
                // stroke with a clean straight line from start to current touch
                // (with 15° angle snap when within 3°) and skip the normal
                // sample-accumulation pass.
                if canSnapToLine {
                    let samples = event?.coalescedTouches(for: touch) ?? [touch]
                    let lastSample = samples.last ?? touch
                    let lastSampleScreen = lastSample.location(in: view)
                    let lastSampleDoc = canvasState?.screenToDocument(lastSampleScreen) ?? lastSampleScreen
                    snapLatestDoc = lastSampleDoc
                    snapLatestPressure = computePressure(for: lastSample)
                    snapLatestTimestamp = lastSample.timestamp

                    if isSnappedToLine, let start = snapToLineStartDoc {
                        stroke.points = buildSnapLineGeometry(start: start, target: lastSampleDoc)
                        currentStroke = stroke
                        return
                    }

                    if let anchor = snapToLineAnchorScreen {
                        let dist = hypot(lastSampleScreen.x - anchor.x, lastSampleScreen.y - anchor.y)
                        if dist >= Self.snapToLineMovementThreshold {
                            snapToLineAnchorScreen = lastSampleScreen
                            armStationaryTimer()
                        }
                        // else: leave the timer running — the user is still settling.
                    }
                }

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
                            // Track the index where this batch's originals
                            // begin so we can slice them out for mirroring
                            // after the inner loop. Mirrors are appended as
                            // a single batch AFTER the originals so the
                            // inner loop's `previousPressure` read keeps
                            // chaining off the original side, not a mirror.
                            let originalsStartIndex = stroke.points.count
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
                            // Symmetry: mirror the originals we just
                            // appended (this batch only, not the whole
                            // stroke). When mode == .off this is a no-op.
                            // Mid-stroke mode change applies to NEW stamps
                            // only — earlier stamps stay where they were
                            // (per spec, by natural property of this
                            // batch-based integration).
                            if symmetry.mode != .off {
                                let docSize = MainActor.assumeIsolated {
                                    canvasState?.documentSize ?? .zero
                                }
                                let originalsBatch = Array(stroke.points[originalsStartIndex..<stroke.points.count])
                                let mirrors = mirroredPoints(originalsBatch, in: docSize, mode: symmetry.mode)
                                stroke.points.append(contentsOf: mirrors)
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

                // Tier-1.5 eraser real-time commit: flush the new sub-stroke
                // (points appended this batch) into the layer texture so the
                // erase shows up live as the user drags, instead of waiting
                // for touchesEnded.
                if currentTool == .eraser {
                    flushEraserSubStroke(view: view)
                }

                // Print every 10th point to avoid spam
                if stroke.points.count % 10 == 0 {
                    print("touchesMoved: stroke has \(stroke.points.count) points (coalesced samples: \(samples.count))")
                }
            }

            // No need to call setNeedsDisplay - continuous drawing is enabled
        }

        // Flush any new eraser sub-stroke points (those past
        // `eraserCommittedPointCount`) into the active layer texture via
        // the real eraser pipeline. Each call is one async render-pass —
        // the GPU rate-limits via PR #54's stroke command-buffer
        // semaphore. Completion fires on main once the GPU pass is done;
        // pass `nil` for callers that just want to fire-and-forget.
        // See touchesBegan / touchesMoved / touchesEnded for the live-
        // commit lifecycle around this helper.
        private func flushEraserSubStroke(view: MTKView, completion: (() -> Void)? = nil) {
            let onDone = completion ?? {}
            guard let stroke = currentStroke,
                  stroke.tool == .eraser,
                  stroke.points.count > eraserCommittedPointCount,
                  selectedLayerIndex < layers.count,
                  let texture = layers[selectedLayerIndex].texture,
                  let renderer = renderer else {
                onDone()
                return
            }
            let documentSize = MainActor.assumeIsolated {
                canvasState?.documentSize ?? view.bounds.size
            }
            let selPath = MainActor.assumeIsolated { canvasState?.selectionPath }
            let newPoints = Array(stroke.points[eraserCommittedPointCount..<stroke.points.count])
            let subStroke = BrushStroke(
                points: newPoints,
                settings: stroke.settings,
                tool: .eraser,
                layerId: stroke.layerId
            )
            eraserCommittedPointCount = stroke.points.count
            renderer.renderStroke(
                subStroke,
                to: texture,
                screenSize: documentSize,
                selectionPath: selPath,
                completion: onDone
            )
        }

        func touchesEnded(_ touches: Set<UITouch>, in view: MTKView, with event: UIEvent?) {
            print("=== TOUCH ENDED ===")

            // Active-layer bounds guard — see touchesBegan for rationale.
            // touchesEnded reads `layers[selectedLayerIndex]` for stroke
            // commit + thumbnail refresh. Bail before any of that runs.
            guard !layers.isEmpty,
                  layers.indices.contains(selectedLayerIndex) else {
                return
            }

            // Blur adjustment: clear the touchdown anchor — no commit on lift.
            // Sigma is held at whatever value the last drag tick set it to;
            // commit happens only via the HUD's ✓ button.
            if currentTool == .blurAdjustment {
                blurAdjustmentTouchStartScreen = nil
                blurAdjustmentLastUpdateAt = 0
                return
            }

            // Smudge: capture after-snapshot, record undo, free patches.
            // The patch was being mutated incrementally during the drag, so
            // the layer texture already holds the final state — no extra
            // dispatch needed at lift, just bookkeeping.
            if isSmudgeStrokeActive {
                isSmudgeStrokeActive = false
                let strokeLayerIndex = smudgeStrokeLayerIndex
                let strokeLayerId = smudgeStrokeLayerId
                let beforeSnapshot = smudgeBeforeSnapshot
                smudgeStrokeLayerIndex = nil
                smudgeStrokeLayerId = nil
                smudgePendingTouchdown = nil
                smudgeBeforeSnapshot = nil

                if let renderer = renderer {
                    if let li = strokeLayerIndex,
                       let lid = strokeLayerId,
                       li < layers.count,
                       layers[li].id == lid,
                       let layerTexture = layers[li].texture {
                        // Drain the in-flight smudge command buffers before
                        // reading back. We don't have a handle to them
                        // here, but `captureSnapshot` issues a blit with
                        // waitUntilCompleted internally — that drain
                        // serialises behind any pending smudge dispatches
                        // on the same queue.
                        let afterSnapshot = renderer.captureSnapshot(of: layerTexture)
                        if let before = beforeSnapshot, let after = afterSnapshot,
                           let canvasState = canvasState {
                            canvasState.historyManager.record(.stroke(
                                layerId: lid,
                                beforeSnapshot: before,
                                afterSnapshot: after
                            ))
                            print("Smudge: recorded stroke undo (before: \(before.count)B, after: \(after.count)B)")
                        }
                        // Refresh thumbnail off-thread.
                        DispatchQueue.global(qos: .utility).async { [weak self] in
                            if let thumbnail = renderer.generateThumbnail(from: layerTexture, size: CGSize(width: 44, height: 44)) {
                                DispatchQueue.main.async {
                                    self?.layers[li].updateThumbnail(thumbnail)
                                }
                            }
                        }
                    }
                    renderer.endSmudgeStroke()
                }

                lastPoint = nil
                lastTimestamp = 0
                if let cs = canvasState {
                    MainActor.assumeIsolated {
                        cs.stampCursorCenter = nil
                        cs.stampCursorDiameter = 0
                    }
                }
                return
            }

            // FloatingText body drag — lift commits the position change but
            // doesn't bake to the layer. Commit happens on tap-outside or
            // tool-change; this branch only resets drag bookkeeping.
            if isDraggingFloatingText {
                isDraggingFloatingText = false
                floatingTextDragStartDoc = nil
                floatingTextDragOriginAnchor = nil
                return
            }

            // .textOnPath: lift fires the text-input alert. Caller (Drawing
            // CanvasView) calls canvasState.beginTextOnPath(...) on Add.
            // Cancel button discards.
            if currentTool == .textOnPath, !textOnPathRawPoints.isEmpty {
                let pts = textOnPathRawPoints
                let firstScreen = textOnPathFirstScreen
                let lastScreen = textOnPathLastScreen
                textOnPathRawPoints = []
                onTextOnPathRequest?(pts, firstScreen, lastScreen)
                return
            }

            // textOnPath circle mode: lift commits the (center, radius)
            // pair. Sub-4pt radii are bailed silently in
            // `beginTextOnPathCircle` so the callback can fire
            // unconditionally. Preview cleared here so the gray-circle
            // overlay vanishes on lift regardless of whether the radius
            // qualified.
            if currentTool == .textOnPath, let center = circleDrawingCenter {
                circleDrawingCenter = nil
                if let cs = canvasState {
                    MainActor.assumeIsolated {
                        cs.previewTextOnPathCircle = nil
                    }
                }
                if let touch = touches.first {
                    let screenLoc = touch.location(in: view)
                    let docPoint = canvasState?.screenToDocument(screenLoc) ?? screenLoc
                    let radius = hypot(docPoint.x - center.x, docPoint.y - center.y)
                    onTextOnPathCircleRequest?(center, radius)
                }
                return
            }

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

            // Tier-1.5 eraser real-time commit fast path: the layer texture
            // was already mutated incrementally during touchesMoved. Final
            // flush of any straggler points, capture the after-snapshot,
            // record history with the touchesBegan-captured before-snapshot,
            // and bail before the standard brush commit path runs (which
            // would re-render the entire stroke and double-erase).
            if stroke.tool == .eraser {
                guard selectedLayerIndex < layers.count,
                      let texture = layers[selectedLayerIndex].texture,
                      let renderer = renderer else {
                    currentStroke = nil
                    lastPoint = nil
                    shapeStartPoint = nil
                    shapeStartScreen = nil
                    eraserBeforeSnapshot = nil
                    eraserCommittedPointCount = 0
                    renderer?.endPreviewMask()
                    return
                }
                let beforeSnapshot = eraserBeforeSnapshot
                let layerId = stroke.layerId
                let currentLayerIndex = selectedLayerIndex
                let capturedCanvasState = canvasState
                flushEraserSubStroke(view: view) { [weak self] in
                    let afterSnapshot = renderer.captureSnapshot(of: texture)
                    if let before = beforeSnapshot,
                       let after = afterSnapshot,
                       let cs = capturedCanvasState {
                        cs.historyManager.record(.stroke(
                            layerId: layerId,
                            beforeSnapshot: before,
                            afterSnapshot: after
                        ))
                        print("Recorded eraser stroke in history (before: \(before.count) bytes, after: \(after.count) bytes)")
                    }
                    DispatchQueue.global(qos: .utility).async {
                        if let thumbnail = renderer.generateThumbnail(from: texture, size: CGSize(width: 44, height: 44)) {
                            DispatchQueue.main.async {
                                guard let self = self,
                                      currentLayerIndex < self.layers.count else { return }
                                self.layers[currentLayerIndex].updateThumbnail(thumbnail)
                            }
                        }
                    }
                }
                currentStroke = nil
                lastPoint = nil
                shapeStartPoint = nil
                shapeStartScreen = nil
                eraserBeforeSnapshot = nil
                eraserCommittedPointCount = 0
                renderer.endPreviewMask()
                resetSnapToLineState()
                if let cs = canvasState {
                    MainActor.assumeIsolated {
                        cs.stampCursorCenter = nil
                        cs.stampCursorDiameter = 0
                    }
                }
                return
            }

            // Commit stroke to layer
            guard selectedLayerIndex < layers.count else {
                print("ERROR: Invalid layer index \(selectedLayerIndex)")
                currentStroke = nil
                lastPoint = nil
                renderer?.endPreviewMask()
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

                let currentLayerIndex = selectedLayerIndex
                let layerId = layer.id
                let capturedCanvasState = canvasState

                // Async stroke commit: GPU pass runs without blocking the main
                // thread on `waitUntilCompleted`. The completion fires on main
                // once the GPU is done — that's the safe point to take the
                // AFTER snapshot, record undo, and kick off the thumbnail.
                // PR 3: pass the active selection path so the GPU clips the
                // stroke. nil = no selection = no clipping.
                let strokeSelectionPath = MainActor.assumeIsolated { canvasState?.selectionPath }
                let dispatchStroke: (@escaping () -> Void) -> Void = { completion in
                    if stroke.tool == .blur {
                        renderer.renderBlurStroke(stroke, to: texture, screenSize: documentSize, selectionPath: strokeSelectionPath, completion: completion)
                    } else {
                        renderer.renderStroke(stroke, to: texture, screenSize: documentSize, selectionPath: strokeSelectionPath, completion: completion)
                    }
                }
                dispatchStroke { [weak self] in
                    print("Stroke committed successfully - texture should now contain the stroke")

                    print("Capturing AFTER snapshot...")
                    let afterSnapshot = renderer.captureSnapshot(of: texture)
                    if afterSnapshot == nil {
                        print("WARNING: Failed to capture after snapshot")
                    }

                    if let before = beforeSnapshot, let after = afterSnapshot,
                       let canvasState = capturedCanvasState {
                        canvasState.historyManager.record(.stroke(
                            layerId: layerId,
                            beforeSnapshot: before,
                            afterSnapshot: after
                        ))
                        print("Recorded stroke in history (before: \(before.count) bytes, after: \(after.count) bytes)")
                    }

                    DispatchQueue.global(qos: .utility).async {
                        if let thumbnail = renderer.generateThumbnail(from: texture, size: CGSize(width: 44, height: 44)) {
                            DispatchQueue.main.async {
                                self?.layers[currentLayerIndex].updateThumbnail(thumbnail)
                            }
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
            // Free the cached preview selection mask. The committed stroke
            // dispatched above rasterises its own mask internally; the
            // preview cache only existed for the wet-ink trail.
            renderer?.endPreviewMask()
            resetSnapToLineState()
            // Hide stamp cursor on lift.
            if let cs = canvasState {
                MainActor.assumeIsolated {
                    cs.stampCursorCenter = nil
                    cs.stampCursorDiameter = 0
                }
            }
            print("Stroke cleared from preview, should now be visible in layer texture")
        }

        func touchesCancelled(_ touches: Set<UITouch>, in view: MTKView, with event: UIEvent?) {
            // Tier-1.5 eraser: the layer texture was mutated mid-stroke, so
            // a system-cancel needs to roll the layer back to its pre-stroke
            // state. Brush doesn't need this — its preview path doesn't
            // touch the layer, so its layer is already in the pre-stroke
            // state and the standard "discard currentStroke" cleanup below
            // is sufficient.
            if currentTool == .eraser,
               let beforeSnapshot = eraserBeforeSnapshot,
               selectedLayerIndex < layers.count,
               let texture = layers[selectedLayerIndex].texture,
               let renderer = renderer {
                renderer.restoreSnapshot(beforeSnapshot, to: texture)
                print("Eraser cancelled — restored layer to pre-stroke snapshot")
            }
            eraserBeforeSnapshot = nil
            eraserCommittedPointCount = 0

            currentStroke = nil
            lastPoint = nil
            shapeStartPoint = nil
            shapeStartScreen = nil
            marqueeStartScreen = nil
            lassoPath = []
            isDraggingSelection = false
            selectionDragStart = nil
            blurAdjustmentTouchStartScreen = nil
            blurAdjustmentLastUpdateAt = 0
            // Free the cached preview selection mask if any. Idempotent —
            // safe even when no stroke was in flight.
            renderer?.endPreviewMask()

            // Smudge: discard the in-progress stroke (no commit, no undo
            // record). Layer texture is left in its partially-mutated
            // state; the user can undo if they want to roll back. This
            // matches how the brush handles cancellation today.
            if isSmudgeStrokeActive {
                isSmudgeStrokeActive = false
                smudgeStrokeLayerIndex = nil
                smudgeStrokeLayerId = nil
                smudgePendingTouchdown = nil
                smudgeBeforeSnapshot = nil
                renderer?.endSmudgeStroke()
            }

            isDraggingFloatingText = false
            floatingTextDragStartDoc = nil
            floatingTextDragOriginAnchor = nil
            textOnPathRawPoints = []
            circleDrawingCenter = nil
            if let cs = canvasState {
                Task { @MainActor in
                    cs.previewTextOnPathPoints = nil
                    cs.previewTextOnPathCircle = nil
                }
            }
            resetSnapToLineState()

            // Clear selection previews + stamp cursor.
            if let canvasState = canvasState {
                Task { @MainActor in
                    canvasState.previewSelection = nil
                    canvasState.previewLassoPath = nil
                    canvasState.stampCursorCenter = nil
                    canvasState.stampCursorDiameter = 0
                }
            }
        }

        // MARK: - Symmetry mirroring
        //
        // Single source of truth used by BOTH the brush/eraser path
        // (touchesMoved per-stamp batches) and the shape path
        // (generateShapePoints results). Returns ONLY the mirrored copies —
        // callers already have the originals. Empty when symmetry is off
        // or in radial mode (radial lands in C3).

        /// Reflect a list of stroke points according to the current symmetry
        /// mode. Caller passes in the originals; we return the mirror set
        /// (excluding the originals). Doc-space input/output: mirror axes
        /// run through the center of the document, which means under canvas
        /// rotation the axes rotate with the canvas for free — the touch
        /// handlers already work in doc space (`screenToDocument` is
        /// rotation-aware).
        private func mirroredPoints(_ points: [BrushStroke.StrokePoint],
                                    in docSize: CGSize,
                                    mode: SymmetryConfig.Mode) -> [BrushStroke.StrokePoint] {
            guard !points.isEmpty,
                  docSize.width > 0,
                  docSize.height > 0 else { return [] }
            switch mode {
            case .off:
                return []
            case .axis(let cfg):
                return axisMirroredPoints(points, in: docSize, config: cfg)
            case .radial(let sections):
                return radialMirroredPoints(points, in: docSize, sections: sections)
            }
        }

        /// Pure axis reflection. Produces 1, 1, or 3 mirror copies per
        /// original depending on which axes are active:
        ///   - Y-axis only:   (x, y) → (W − x, y)
        ///   - X-axis only:   (x, y) → (x, H − y)
        ///   - Both axes:     above two PLUS the diagonal (W − x, H − y)
        /// Empty input or both-flags-false yields []. Pressure and
        /// timestamp copy through unchanged — mirrors share the same
        /// dynamics as their originals.
        private func axisMirroredPoints(_ points: [BrushStroke.StrokePoint],
                                        in docSize: CGSize,
                                        config: SymmetryConfig.AxisConfig) -> [BrushStroke.StrokePoint] {
            guard config.yAxis || config.xAxis else { return [] }
            let W = docSize.width
            let H = docSize.height
            var result: [BrushStroke.StrokePoint] = []
            // Reserve up to 3 mirror copies per point so the array doesn't
            // realloc during a long stroke append.
            result.reserveCapacity(points.count * 3)

            if config.yAxis {
                for p in points {
                    result.append(BrushStroke.StrokePoint(
                        location: CGPoint(x: W - p.location.x, y: p.location.y),
                        pressure: p.pressure,
                        timestamp: p.timestamp
                    ))
                }
            }
            if config.xAxis {
                for p in points {
                    result.append(BrushStroke.StrokePoint(
                        location: CGPoint(x: p.location.x, y: H - p.location.y),
                        pressure: p.pressure,
                        timestamp: p.timestamp
                    ))
                }
            }
            if config.yAxis && config.xAxis {
                for p in points {
                    result.append(BrushStroke.StrokePoint(
                        location: CGPoint(x: W - p.location.x, y: H - p.location.y),
                        pressure: p.pressure,
                        timestamp: p.timestamp
                    ))
                }
            }
            return result
        }

        /// Pure rotation around the canvas center. For each original
        /// stamp, produces `sections - 1` additional stamps at angles
        /// 2π·k/N for k ∈ 1..<N around (W/2, H/2). No reflection
        /// (kaleidoscope is explicitly out of v1 spec).
        ///
        /// Math (per locked spec, do not reorder):
        ///   rotated_x = cx + (x − cx)·cos(θ) − (y − cy)·sin(θ)
        ///   rotated_y = cy + (x − cx)·sin(θ) + (y − cy)·cos(θ)
        ///
        /// Edge cases:
        /// - sections < 2 returns [] (1 section is a no-op; spec lower
        ///   bound is 2). The picker's stepper is also clamped to 2…16.
        /// - A stamp landing exactly on the center point produces
        ///   `sections - 1` copies all at the center. Visually identical
        ///   to a single stamp; not a crash, no special handling needed.
        /// - Trig precision at N=16 is well within float tolerance —
        ///   ~1 ULP per cos/sin call, invisible at canvas pixel scale.
        private func radialMirroredPoints(_ points: [BrushStroke.StrokePoint],
                                          in docSize: CGSize,
                                          sections: Int) -> [BrushStroke.StrokePoint] {
            guard sections >= 2, !points.isEmpty else { return [] }
            let cx = docSize.width / 2
            let cy = docSize.height / 2

            var result: [BrushStroke.StrokePoint] = []
            result.reserveCapacity(points.count * (sections - 1))

            // k = 1..<sections; k = 0 is the original (caller already has it).
            for k in 1..<sections {
                let theta = 2.0 * Double.pi * Double(k) / Double(sections)
                let cosT = CGFloat(cos(theta))
                let sinT = CGFloat(sin(theta))
                for p in points {
                    let dx = p.location.x - cx
                    let dy = p.location.y - cy
                    let rotatedX = cx + dx * cosT - dy * sinT
                    let rotatedY = cy + dx * sinT + dy * cosT
                    result.append(BrushStroke.StrokePoint(
                        location: CGPoint(x: rotatedX, y: rotatedY),
                        pressure: p.pressure,
                        timestamp: p.timestamp
                    ))
                }
            }
            return result
        }

        // Approximate doc-pixel → screen-pixel conversion for the stamp
        // cursor. The display is roughly square-fit and zoomable; canvas
        // rotation is ignored in the diameter (rotation rotates the whole
        // canvas, not the stamp shape). Good enough for a cursor outline.
        private func stampScreenDiameter(forSize docSize: CGFloat) -> CGFloat {
            guard let cs = canvasState else { return docSize }
            let docWidth = MainActor.assumeIsolated { cs.documentSize.width }
            let screenWidth = MainActor.assumeIsolated { cs.screenSize.width }
            let zoom = MainActor.assumeIsolated { cs.zoomScale }
            guard docWidth > 0 else { return docSize }
            return docSize * (screenWidth / docWidth) * zoom
        }

        // MARK: - Snap-to-Line

        /// Whether the active tool participates in snap-to-line. Brush, eraser,
        /// and blur all build their stroke through the per-stamp accumulation
        /// path in touchesMoved; replacing that geometry with a clean line is
        /// safe for all three. Shape tools have their own dedicated line tool;
        /// selection / fill / eyedropper / text don't produce strokes at all.
        private var canSnapToLine: Bool {
            switch currentTool {
            case .brush, .eraser, .blur:
                return true
            default:
                return false
            }
        }

        /// (Re)arm the 600ms stationary timer. Adds to the run loop in
        /// `.common` mode so it actually fires during touch tracking — the
        /// default UIKit run loop mode would not.
        private func armStationaryTimer() {
            cancelStationaryTimer()
            let timer = Timer(timeInterval: Self.snapToLineHoldDuration, repeats: false) { [weak self] _ in
                self?.engageSnapToLine()
            }
            RunLoop.main.add(timer, forMode: .common)
            snapToLineTimer = timer
        }

        private func cancelStationaryTimer() {
            snapToLineTimer?.invalidate()
            snapToLineTimer = nil
        }

        /// Reset all snap-to-line state. Called from touchesEnded /
        /// touchesCancelled.
        private func resetSnapToLineState() {
            cancelStationaryTimer()
            isSnappedToLine = false
            snapToLineStartDoc = nil
            snapToLineAnchorScreen = nil
        }

        /// Fired by `snapToLineTimer` after 600ms of stationary touch.
        /// Engages the snapped state and replaces the stroke geometry with a
        /// clean line from the stroke start to the latest tracked sample.
        /// Subsequent touchesMoved events refresh the geometry as the user
        /// adjusts the endpoint.
        private func engageSnapToLine() {
            snapToLineTimer = nil
            guard var stroke = currentStroke,
                  let start = snapToLineStartDoc else { return }
            isSnappedToLine = true
            stroke.points = buildSnapLineGeometry(start: start, target: snapLatestDoc)
            currentStroke = stroke
        }

        /// Build the snapped-line stroke point list, including symmetry mirrors.
        /// Uses the existing `generateLinePoints` so brush spacing/scaling is
        /// identical to a manual stroke.
        private func buildSnapLineGeometry(start: CGPoint, target: CGPoint) -> [BrushStroke.StrokePoint] {
            let snappedTarget = applyAngleSnap(start: start, target: target)
            let originals = generateLinePoints(
                from: start,
                to: snappedTarget,
                pressure: snapLatestPressure,
                timestamp: snapLatestTimestamp
            )
            let docSize = MainActor.assumeIsolated {
                canvasState?.documentSize ?? .zero
            }
            let mirrors = mirroredPoints(originals, in: docSize, mode: symmetry.mode)
            return originals + mirrors
        }

        /// Snap the line's angle to a 15° increment when the current angle is
        /// within 3° of one. Length follows the finger naturally (only the
        /// direction is constrained).
        private func applyAngleSnap(start: CGPoint, target: CGPoint) -> CGPoint {
            let dx = target.x - start.x
            let dy = target.y - start.y
            let length = hypot(dx, dy)
            guard length > 0.0001 else { return target }

            let angleDeg = atan2(dy, dx) * 180 / .pi
            let nearest = (angleDeg / Self.snapToLineAngleIncrement).rounded() * Self.snapToLineAngleIncrement
            let raw = abs(angleDeg - nearest)
            // Wrap deltas across the ±180° seam (e.g. -179° vs 180° are 1° apart).
            let delta = min(raw, 360 - raw)
            guard delta < Self.snapToLineAngleTolerance else { return target }

            let snapRad = nearest * .pi / 180
            return CGPoint(
                x: start.x + cos(snapRad) * length,
                y: start.y + sin(snapRad) * length
            )
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

            // Fallback for floating selections that don't define a marquee
            // (image import currently). Hit-test the texture's displayed
            // bounds — same rect the renderer is drawing on screen.
            if let original = canvasState.selectionOriginalRect, canvasState.floatingSelectionTexture != nil {
                let displayed = CGRect(
                    x: original.origin.x + canvasState.selectionOffset.x,
                    y: original.origin.y + canvasState.selectionOffset.y,
                    width: original.width * canvasState.selectionScale.width,
                    height: original.height * canvasState.selectionScale.height
                )
                // Hit-test against the rotated rect by inverse-rotating the
                // point around the displayed rect's center, then checking
                // axis-aligned containment. Required so taps inside a
                // rotated selection still register; required by the user's
                // explicit "rotation applied before hit-testing" rule.
                let theta = canvasState.selectionRotation.radians
                if theta == 0 {
                    return displayed.contains(point)
                }
                let cx = displayed.midX
                let cy = displayed.midY
                let dx = point.x - cx
                let dy = point.y - cy
                // Inverse of doc-space R(-θ) used by the shader is R(+θ) on
                // doc Y-down coords:  x' = x cosθ - y sinθ,  y' = x sinθ + y cosθ
                let cosT = cos(theta)
                let sinT = sin(theta)
                let localX = dx * cosT - dy * sinT
                let localY = dx * sinT + dy * cosT
                return abs(localX) <= displayed.width  / 2 &&
                       abs(localY) <= displayed.height / 2
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

            // Read just the 1×1 pixel we need. The previous version asked for
            // a full row (`width × 1`, ~16 KiB on a 4096-wide texture) when
            // we only consume 4 bytes — same Metal call, single-pixel region.
            var pixelData = [UInt8](repeating: 0, count: 4)
            let region = MTLRegion(
                origin: MTLOrigin(x: x, y: y, z: 0),
                size: MTLSize(width: 1, height: 1, depth: 1)
            )

            pixelData.withUnsafeMutableBufferPointer { buf in
                guard let baseAddress = buf.baseAddress else { return }
                texture.getBytes(baseAddress, bytesPerRow: 4, from: region, mipmapLevel: 0)
            }

            // Extract BGRA color components (Metal uses BGRA format).
            // Stored values are premultiplied by alpha (per the brush fragment
            // shader), so divide RGB by alpha to recover the visible color.
            let bp = CGFloat(pixelData[0]) / 255.0
            let gp = CGFloat(pixelData[1]) / 255.0
            let rp = CGFloat(pixelData[2]) / 255.0
            let a  = CGFloat(pixelData[3]) / 255.0

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
