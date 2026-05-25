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

/// Snapshot of every canvas-state field that `draw(in:)` reads.
/// Compared in `MetalCanvasView.updateUIView` to decide whether the
/// SwiftUI body re-eval actually warrants a GPU redraw. Two snapshots
/// being equal means "nothing draw(in:) would render differently"
/// — safe to skip `setNeedsDisplay()`. See updateUIView's header
/// comment for the battery rationale.
///
/// Adding a render-affecting field to draw(in:)?
///   1. Add it to this struct as a value-Equatable field.
///   2. Capture it in the `init(canvasState:...)` initializer.
///   3. Build a debug case where only that field changes and verify
///      the canvas redraws.
///
/// Texture references compare by ObjectIdentifier — pixel-level
/// changes within a texture don't change identity, so they must go
/// through layerMutationCounter (or a dedicated revision) to be
/// caught here.
struct CanvasRenderSnapshot: Equatable {
    // Viewport
    let zoomScale: CGFloat
    let panOffset: CGPoint
    let canvasRotationRadians: Double
    let flipHorizontal: Bool
    let flipVertical: Bool
    let documentSize: CGSize

    // Layer composite. `layerMutationCounter` catches add/remove/
    // reorder/visibility-toggle/stroke commit/clear/fill/text
    // commit/selection delete/undo/redo. Per-layer opacity and
    // visibility tuples are belt-and-suspenders for the gap noted
    // in CompositionAnalysisService.swift's doc block: opacity
    // slider drags don't bump the counter.
    let layerMutationCounter: Int
    let layerCount: Int
    let layerOpacities: [Float]
    let layerVisibilities: [Bool]
    let layerTextureIDs: [ObjectIdentifier?]

    // Move / selection state
    let isTranslatingActiveLayer: Bool
    let selectedLayerIndex: Int
    let floatingSelectionTextureID: ObjectIdentifier?
    let selectionOriginalRect: CGRect?
    let selectionOffset: CGPoint
    let selectionScale: CGSize
    let selectionRotationRadians: Double

    // Floating text live preview
    let floatingTextTextureID: ObjectIdentifier?
    let floatingTextRect: CGRect
    let floatingTextRotationRadians: Double

    // Note: the in-progress stroke lives on the Coordinator, not on
    // canvasState, so we can't snapshot it from here. That's OK —
    // every touchesBegan/Moved/Ended call site already invokes
    // setNeedsDisplay() explicitly (see the 11 grep'd sites in
    // BATTERY_AUDIT_2026-05-15.md), which bypasses this gate.

    // Back-canvas references (renderBackCanvasReferences reads count
    // + ids; pixel updates inside a reference image are out of scope
    // — they don't happen in the current code).
    let backCanvasReferenceCount: Int
    let backCanvasReferenceIDs: [UUID]

    // textOnPath mode (Coordinator reads in touch handlers; doesn't
    // strictly affect draw(in:), but updateUIView pushes it into the
    // Coordinator from this same call, so a mode change should
    // trigger the redraw anyway for visual mode chrome reasons).
    let typeOnPathMode: TypeOnPathPathMode

    @MainActor
    init(
        canvasState: CanvasStateManager?,
        backCanvasReferences: [ReferenceImage],
        typeOnPathMode: TypeOnPathPathMode
    ) {
        if let state = canvasState {
            self.zoomScale = state.zoomScale
            self.panOffset = state.panOffset
            self.canvasRotationRadians = state.canvasRotation.radians
            self.flipHorizontal = state.flipHorizontal
            self.flipVertical = state.flipVertical
            self.documentSize = state.documentSize
            self.layerMutationCounter = state.layerMutationCounter
            self.layerCount = state.layers.count
            self.layerOpacities = state.layers.map { $0.opacity }
            self.layerVisibilities = state.layers.map { $0.isVisible }
            self.layerTextureIDs = state.layers.map {
                $0.tileGrid.map { ObjectIdentifier($0) }
            }
            self.isTranslatingActiveLayer = state.isTranslatingActiveLayer
            self.selectedLayerIndex = state.selectedLayerIndex
            self.floatingSelectionTextureID = state.floatingSelectionTexture.map(ObjectIdentifier.init)
            self.selectionOriginalRect = state.selectionOriginalRect
            self.selectionOffset = state.selectionOffset
            self.selectionScale = state.selectionScale
            self.selectionRotationRadians = state.selectionRotation.radians
            if let ft = state.floatingText {
                self.floatingTextTextureID = ft.cachedTexture.map(ObjectIdentifier.init)
                self.floatingTextRect = ft.displayedRect
                self.floatingTextRotationRadians = ft.rotation.radians
            } else {
                self.floatingTextTextureID = nil
                self.floatingTextRect = .zero
                self.floatingTextRotationRadians = 0
            }
        } else {
            self.zoomScale = 1
            self.panOffset = .zero
            self.canvasRotationRadians = 0
            self.flipHorizontal = false
            self.flipVertical = false
            self.documentSize = .zero
            self.layerMutationCounter = -1
            self.layerCount = 0
            self.layerOpacities = []
            self.layerVisibilities = []
            self.layerTextureIDs = []
            self.isTranslatingActiveLayer = false
            self.selectedLayerIndex = -1
            self.floatingSelectionTextureID = nil
            self.selectionOriginalRect = nil
            self.selectionOffset = .zero
            self.selectionScale = CGSize(width: 1, height: 1)
            self.selectionRotationRadians = 0
            self.floatingTextTextureID = nil
            self.floatingTextRect = .zero
            self.floatingTextRotationRadians = 0
        }
        self.backCanvasReferenceCount = backCanvasReferences.count
        self.backCanvasReferenceIDs = backCanvasReferences.map { $0.id }
        self.typeOnPathMode = typeOnPathMode
    }

    /// True if `self` differs from `other` ONLY in continuously-mutated
    /// transform fields. Used by MetalCanvasView.updateUIView's snapshot
    /// gate to route gesture-driven 120 Hz transform spam through a 60 Hz
    /// throttle while keeping every other state change at native cadence.
    ///
    /// **Throttleable (transform) set:**
    ///   - Viewport: zoomScale, panOffset, canvasRotationRadians,
    ///     flipHorizontal, flipVertical
    ///   - Selection drag: selectionOffset, selectionScale,
    ///     selectionRotationRadians
    ///   - Floating-text drag: floatingTextRect, floatingTextRotationRadians
    ///
    /// **Non-throttleable** (any of these differing → return false → fire
    /// the redraw immediately): everything else in the snapshot —
    /// composite content, layer counts/opacities/visibilities/texture IDs,
    /// selection lifecycle (create/destroy/mask), floating-text identity
    /// (font/size/content changes swap the texture ID), document size,
    /// reference images, type-on-path mode.
    ///
    /// Notable policy calls baked into the field split below:
    ///   - **Layer opacities are not throttled.** Slider input is already
    ///     ~60 Hz from UIKit; throttling adds no win and risks visible lag
    ///     on a hard yank. Easy to flip later if profiling disagrees.
    ///   - **Selection mask vs. selection transform are split** —
    ///     selectionOriginalRect (mask) and floatingSelectionTextureID
    ///     (lifecycle) live outside the throttle; selectionOffset/Scale/
    ///     RotationRadians (drag-time transform) live inside.
    ///   - **Floating-text font/size vs. position is split** —
    ///     floatingTextTextureID (re-raster on font/size/content) lives
    ///     outside; floatingTextRect/RotationRadians (position drag) live
    ///     inside.
    ///
    /// Caller contract: only meaningful when `self != other`. If every
    /// non-transform field matches but no transform field differs either,
    /// this returns true vacuously; the caller is expected to have
    /// short-circuited on the equality check before calling.
    ///
    /// Adding a new field to CanvasRenderSnapshot? Decide whether it's
    /// throttleable and either add a guard here (non-throttleable) or
    /// extend the docstring (throttleable). Default to non-throttleable
    /// when in doubt — "fires too often" is invisible; "missed a redraw"
    /// is a visible bug.
    func differsOnlyInTransform(from other: CanvasRenderSnapshot) -> Bool {
        // Composite content + identity. Any flip here = pixel change.
        if layerMutationCounter != other.layerMutationCounter { return false }
        if layerCount != other.layerCount { return false }
        if layerOpacities != other.layerOpacities { return false }
        if layerVisibilities != other.layerVisibilities { return false }
        if layerTextureIDs != other.layerTextureIDs { return false }

        // Selection lifecycle (mask geometry + presence of a floating
        // texture). Drag-time transform fields are intentionally excluded
        // and stay throttleable.
        if isTranslatingActiveLayer != other.isTranslatingActiveLayer { return false }
        if selectedLayerIndex != other.selectedLayerIndex { return false }
        if floatingSelectionTextureID != other.floatingSelectionTextureID { return false }
        if selectionOriginalRect != other.selectionOriginalRect { return false }

        // Floating-text identity. The texture ID swaps on font / size /
        // content change; position-only drag keeps the same texture and
        // only mutates the throttled floatingTextRect.
        if floatingTextTextureID != other.floatingTextTextureID { return false }

        // One-shot canvas-level state.
        if documentSize != other.documentSize { return false }
        if backCanvasReferenceCount != other.backCanvasReferenceCount { return false }
        if backCanvasReferenceIDs != other.backCanvasReferenceIDs { return false }
        if typeOnPathMode != other.typeOnPathMode { return false }

        // Every non-transform field matches; any diff is exclusively in
        // the throttleable transform set.
        return true
    }
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

    /// Back-canvas reference images. Pushed to the Coordinator each
    /// updateUIView; the Coordinator caches textures by id and renders
    /// them BETWEEN the white-paper pass and the layer composite. These
    /// references are NEVER added to `layers` and NEVER enter the AI/
    /// save/export composite — they live only in the to-screen path.
    var backCanvasReferences: [ReferenceImage] = []

    /// Apple Pencil hover callback (iPadOS 16.1+, iPad Pro M2+). Fires
    /// with the hover screen point while the pencil is detected above
    /// the screen, and with nil when the pencil leaves hover range or
    /// touches down. UIHoverGestureRecognizer is a no-op on hardware
    /// without hover support, so there's no compatibility branching
    /// needed — non-supported devices simply never invoke this closure.
    var onHoverChange: ((CGPoint?) -> Void)? = nil

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
        // Fix 1.1: render-on-demand. The MTKView only draws when something
        // explicitly calls setNeedsDisplay() — touch handlers do so after each
        // dispatch (touchesBegan/Moved/Ended/Cancelled), and updateUIView
        // already calls it on SwiftUI state changes (line below). Idle canvas
        // = no per-frame work. Background pause is handled by the Coordinator's
        // didEnterBackground / willEnterForeground observers (Fix 1.2).
        metalView.enableSetNeedsDisplay = true
        metalView.isPaused = false
        // framebufferOnly = true lets Metal optimise the drawable as
        // write-only — on TBDR Apple GPUs the drawable's tile memory
        // doesn't have to be materialised back to DRAM between frames,
        // which lowers memory bandwidth and thermal load. The live draw
        // path NEVER reads the drawable's texture back: every getBytes
        // and blit-copy targets the canvasStagingAtlas, a tile texture,
        // or a transient intermediate. Save / AI / thumbnail / palette
        // paths all read from `tileDisplayIntermediate` or
        // `canvasStagingAtlas`, never from `view.currentDrawable`.
        // (Verified by `grep drawable.texture` across the iOS target —
        // only render-target colour-attachment assignments, no reads.)
        metalView.framebufferOnly = true
        // Off-canvas workbench is light gray so the canvas boundary is visible
        // when zoomed/panned out. At default zoom the canvas fills the viewport.
        metalView.clearColor = MTLClearColor(red: 0.753, green: 0.753, blue: 0.753, alpha: 1)
        metalView.backgroundColor = UIColor(red: 0.753, green: 0.753, blue: 0.753, alpha: 1.0)
        // Fix 1.1: ProMotion. MTKView exposes `preferredFramesPerSecond`;
        // iOS clamps to the display's capability (120 on ProMotion iPad Pro,
        // 60 on non-ProMotion). Throttles down automatically if the GPU
        // can't keep up on a heavy stroke — graceful degradation, no crash.
        // (MTKView doesn't expose CADisplayLink.preferredFrameRateRange
        // directly, so we use the Int property and rely on iOS clamping.)
        metalView.preferredFramesPerSecond = 120

        // Enable multi-touch and pencil input
        metalView.isMultipleTouchEnabled = true

        // CRITICAL: Enable user interaction so touches are received
        metalView.isUserInteractionEnabled = true

        // Connect touch events to coordinator
        metalView.touchDelegate = context.coordinator

        // Weak ref so the Coordinator's background/foreground handlers can
        // flip isPaused without depending on a per-touch view reference.
        context.coordinator.metalView = metalView

        // Apply current thermal state to the MTKView's frame rate. The
        // notification only fires on transitions, so without this initial
        // call the app would stay at 120 Hz until iOS first reports a
        // change — including the case where it launched into `.serious`.
        context.coordinator.applyThermalState()

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

        // Apple Pencil hover (iPadOS 16.1+, iPad Pro M2+ / Pencil 2/Pro).
        // Inert on unsupported hardware — never fires. No compatibility
        // branching needed; the closure on Coordinator just stays unused.
        let hoverGesture = UIHoverGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleHover(_:)))
        metalView.addGestureRecognizer(hoverGesture)

        print("MetalCanvasView: MTKView configured successfully with gesture recognizers (pinch, pan, rotation, hover)")

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

        // Push the latest back-canvas references. The Coordinator handles
        // texture caching (upload on first sight, drop when removed) and
        // renders them in draw(in:) before the layer composite. Never
        // enters compositeLayersToTexture / the AI/save path.
        context.coordinator.backCanvasReferences = backCanvasReferences

        // Battery: gate setNeedsDisplay on whether anything draw(in:)
        // actually reads has changed. Without this gate, every
        // @Published mutation on CanvasStateManager (34 of them —
        // color picker, brush slider, tool switch, etc.) cascades into
        // a full GPU redraw + 8-layer composite, even when the result
        // is identical pixels. See BATTERY_AUDIT_2026-05-15.md
        // finding #1 for the diagnosis.
        //
        // Touch handlers already call setNeedsDisplay() explicitly
        // (touchesBegan/Moved/Ended at the 11 sites grep'd in the
        // audit), so active drawing isn't affected — the gate only
        // deduplicates SwiftUI-state-only redraw signals.
        //
        // If a snapshot field is missed and a needed redraw is dropped,
        // the canvas appears frozen until another setNeedsDisplay()
        // fires (any touch, pan, zoom, or external state bump). That's
        // a real failure mode — if you spot it, add the missing field
        // to CanvasRenderSnapshot below rather than ripping the gate out.
        let snapshot = CanvasRenderSnapshot(
            canvasState: canvasState,
            backCanvasReferences: backCanvasReferences,
            typeOnPathMode: typeOnPathMode
        )
        if context.coordinator.lastRenderSnapshot != snapshot {
            // Field-aware throttle. Diffs that touch ONLY the throttleable
            // transform set (viewport gestures, selection / floating-text
            // drag transforms) coalesce to 60 Hz via requestThrottledRedraw;
            // diffs that touch anything else (composite content, layer ops,
            // selection lifecycle, font/text re-raster, mode toggles, etc.)
            // fire immediately. See CanvasRenderSnapshot.differsOnlyInTransform
            // for the policy and field-by-field rationale.
            let transformOnly = context.coordinator.lastRenderSnapshot?
                .differsOnlyInTransform(from: snapshot) ?? false
            context.coordinator.lastRenderSnapshot = snapshot
            if transformOnly {
                context.coordinator.requestThrottledRedraw()
            } else {
                uiView.setNeedsDisplay()
            }
        }
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
            symmetry: symmetry,
            onHoverChange: onHoverChange
        )
    }

    class Coordinator: NSObject, MTKViewDelegate, TouchHandling, UIGestureRecognizerDelegate {
        @Binding var layers: [DrawingLayer]
        @Binding var currentTool: DrawingTool
        @Binding var brushSettings: BrushSettings
        @Binding var selectedLayerIndex: Int

        private var renderer: CanvasRenderer?

        #if DEBUG
        // Wet-ink Phase A: one-shot guard for the strokeScratch sanity probe.
        // See WET_INK_DESIGN.md §4 + CanvasRenderer.runStrokeScratchPhaseAProbe.
        private var wetInkPhaseAProbeRun = false
        // Wet-ink Phase A.5: one-shot guard for the shader-equivalence probe.
        // See WET_INK_DESIGN.md §2.10 + CanvasRenderer.runShaderEquivalencePhaseA5Probe.
        private var wetInkPhaseA5ProbeRun = false
        // Wet-ink Phase B: one-shot guard for the max-blend deposit probe.
        // See WET_INK_DESIGN.md §2.10 + CanvasRenderer.runMaxBlendDepositPhaseBProbe.
        private var wetInkPhaseBProbeRun = false
        // Wet-ink Phase C: one-shot guard for the commit pipeline probe.
        // See WET_INK_DESIGN.md §2.10 + CanvasRenderer.runCommitPipelinePhaseCProbe.
        private var wetInkPhaseCProbeRun = false
        // Wet-ink Phase D: one-shot guard for the opacity-scaling probe.
        // See WET_INK_DESIGN.md §2.10 + CanvasRenderer.runOpacityScalingPhaseDProbe.
        private var wetInkPhaseDProbeRun = false
        #endif

        // Wet-ink live state. Tool-agnostic — currently routes .brush and
        // .eraser through the wet-ink lifecycle. Phase E extends to the
        // remaining additive tools and shape tools.
        //
        // Capture BEFORE snapshot at touchesBegan, flush new stamps per
        // touchesMoved batch via the renderer's deposit pipeline (picked
        // by tool: premul-additive for brush family, eraser-alpha-only
        // for eraser), commit at touchesEnded and capture the AFTER
        // snapshot in the completion to record HistoryAction.stroke.
        private var wetInkActive: Bool = false
        private var wetInkBeforeSnapshot: CanvasRenderer.LayerSnapshot?
        private var wetInkLayerIndex: Int?
        private var wetInkLayerId: UUID?
        private var wetInkCommittedPointCount: Int = 0

        // Tools that route through the wet-ink lifecycle. Brush, eraser,
        // and the 5 additive variants (Phase E). Shape tools (line, rect,
        // circle) stay on OLD renderStroke until Phase H.
        private func isWetInkTool(_ tool: DrawingTool) -> Bool {
            switch tool {
            case .brush, .eraser, .pencil, .inkPen, .marker, .airbrush, .charcoal:
                return true
            default:
                return false
            }
        }

        private var currentStroke: BrushStroke?
        private var lastPoint: CGPoint?
        private var lastTimestamp: TimeInterval = 0
        private var shapeStartPoint: CGPoint? // For shape tools (doc space)
        // Screen-space start for shape tools that should ignore canvas rotation
        // (rectangle, circle). Line is rotation-invariant so it can use the
        // doc-space start directly.
        private var shapeStartScreen: CGPoint?
        // Pressure captured at touchdown for shape tools. Shape strokes
        // regenerate their whole point list on every touchesMoved; reading
        // `computePressure(for: touch)` per frame made the live preview
        // track the Pencil's instantaneous force during the drag, then
        // the commit froze on whatever the last (typically low, mid-lift)
        // sample happened to be — strokes visibly snapped thinner on
        // release. Locking the pressure at touchdown makes preview and
        // commit identical for the whole stroke.
        private var shapeStartPressure: CGFloat?
        // Companion alpha-pressure captured at shape touchdown. Diverges
        // from `shapeStartPressure` for non-Pencil input (size 0.75, alpha
        // 1.0) so shape strokes don't inherit the size-fudge's alpha-
        // capping side effect. See `computePressure(for:)`.
        private var shapeStartPressureAlpha: CGFloat?
        private var shapeStartInputType: BrushStroke.InputType?
        private var shapeStartRawTouchForce: CGFloat?
        private var shapeStartRawTouchMaxForce: CGFloat?
        // Two-finger perfect-shape constraint.
        // `shapePrimaryTouchID` is the touch that opened the shape stroke;
        // any additional touches that land while the shape is in progress
        // are tracked in `shapeConstraintTouchIDs`. While that set is
        // non-empty, the shape generators snap to square / circle / 45°
        // line. Lifting the last secondary touch (without lifting the
        // primary) releases the constraint and the shape returns to
        // freeform on the next preview frame.
        private var shapePrimaryTouchID: ObjectIdentifier?
        private var shapeConstraintTouchIDs: Set<ObjectIdentifier> = []
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

        /// Snapshot of canvas state from the last `updateUIView` call.
        /// Compared against a fresh snapshot to decide whether to call
        /// `setNeedsDisplay()`. nil means "no snapshot yet — render the
        /// first frame unconditionally." See updateUIView for the
        /// rationale (battery: stop cascading GPU redraws on @Published
        /// changes that don't actually affect pixels).
        var lastRenderSnapshot: CanvasRenderSnapshot?
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
        private var smudgeStrokeID: UUID?
        // Stamp 0 of the stroke is the touchdown point — captured here in
        // `touchesBegan` and prepended to the first `renderSmudgeStamps`
        // batch in `touchesMoved` (so it dispatches as the pickup-only
        // first stamp). Cleared after the first batch.
        private var smudgePendingTouchdown: BrushStroke.StrokePoint?
        private var smudgeBeforeSnapshot: CanvasRenderer.LayerSnapshot?

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
        private var eraserBeforeSnapshot: CanvasRenderer.LayerSnapshot?
        private var eraserCommittedPointCount: Int = 0

        // Real-time blur stroke session (experiment/blur-brush-realtime).
        // Mirrors the eraser substroke flush pattern: capture before-snapshot
        // at touchesBegan, peel off newly-arrived points each touchesMoved
        // and dispatch them via the renderer's persistent blur session,
        // finalize at touchesEnded with the same after-snapshot + history
        // recording the deferred path uses.
        private var blurStrokeActive = false
        private var blurStrokeBeforeSnapshot: CanvasRenderer.LayerSnapshot?
        private var blurStrokeLayerIndex: Int?
        private var blurStrokeLayerId: UUID?
        private var blurCommittedPointCount: Int = 0

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
        // Companion alpha-pressure for snap-to-line. Same rationale as
        // `shapeStartPressureAlpha`.
        private var snapLatestPressureAlpha: CGFloat = 1.0
        private var snapLatestInputType: BrushStroke.InputType = .unknown
        private var snapLatestRawTouchForce: CGFloat = 0
        private var snapLatestRawTouchMaxForce: CGFloat = 0
        private var snapLatestTimestamp: TimeInterval = 0
        private static let snapToLineHoldDuration: TimeInterval = 0.6
        private static let snapToLineMovementThreshold: CGFloat = 2.0   // screen pts
        private static let snapToLineAngleIncrement: CGFloat = 15.0     // degrees
        private static let snapToLineAngleTolerance: CGFloat = 3.0      // degrees

        /// Weak ref to the MTKView, captured in `makeUIView`. Used by the
        /// background/foreground notification handlers to flip `isPaused`
        /// without depending on a per-touch view reference. Weak so the
        /// Coordinator doesn't pin the view's lifetime.
        weak var metalView: MTKView?

        /// Back-canvas references pushed in from MetalCanvasView each
        /// updateUIView. Read in draw(in:) to render the pre-layer pass.
        var backCanvasReferences: [ReferenceImage] = []

        /// MTLTexture cache for back-canvas references, keyed by ref id.
        /// Lazily populated on first sight in draw(in:); entries are
        /// dropped when the id is no longer in backCanvasReferences. The
        /// images themselves are immutable post-import (subject isolation
        /// produces a new image but stores it as `isolatedImage` on the
        /// reference; we cache one entry per reference id regardless).
        private var referenceTextureCache: [UUID: MTLTexture] = [:]
        /// Tracks whether the cached texture is for the original or
        /// isolated image — flipping the toggle invalidates the cache.
        private var referenceTextureCacheKey: [UUID: Bool] = [:]

        /// Apple Pencil hover callback, set from MetalCanvasView's init.
        /// Invoked with the screen-space hover point while the pencil
        /// is detected above the screen, and with nil on hover-end.
        var onHoverChange: ((CGPoint?) -> Void)?

        /// Paint-bucket fill deferred from touchesBegan to touchesEnded so a
        /// second finger (the leading edge of a pinch / two-finger pan) can
        /// suppress the fill before it commits. Set on single-finger touchdown
        /// over the paint-bucket tool; cleared on multi-touch begin, on
        /// touchesCancelled (which UIKit fires when a transform gesture
        /// claims the touches), or after the fill dispatches in touchesEnded.
        private var pendingPaintBucketFill: PendingPaintBucketFill?
        private struct PendingPaintBucketFill {
            let docLocation: CGPoint
            let layerIndex: Int
            let layerId: UUID
            let beforeSnapshot: CanvasRenderer.LayerSnapshot?
        }

        /// True while a touch-driven stroke is in flight on this MTKView.
        /// Used to suppress the Apple Pencil hover cursor from flickering
        /// in mid-stroke (e.g. trackpad-pointer hover events arriving while
        /// the user is also drawing with a finger). Reset on touchesEnded
        /// and touchesCancelled.
        private var isStrokeInProgress = false

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
            symmetry: SymmetryConfig,
            onHoverChange: ((CGPoint?) -> Void)?
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
            self.onHoverChange = onHoverChange

            super.init()

            // Background pause (Fix 1.2). Suspend the display link when the
            // app is backgrounded so the canvas stops generating frames the
            // user can't see; restore on foreground and schedule one redraw
            // so the visible state refreshes. Selector-based observers are
            // auto-removed on Coordinator deinit (since iOS 9).
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAppDidEnterBackground),
                name: UIApplication.didEnterBackgroundNotification,
                object: nil,
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAppWillEnterForeground),
                name: UIApplication.willEnterForegroundNotification,
                object: nil,
            )

            // Thermal pressure (tile-rendering-audit Tier A item 2). iOS
            // exposes `ProcessInfo.thermalState`; the notification fires
            // on transitions. We mirror it onto `preferredFramesPerSecond`
            // so a hot device drops to 60 / 30 fps instead of pushing the
            // GPU at 120 Hz until iOS throttles us itself. Initial state
            // applied below — the notification only fires on changes.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleThermalStateChange),
                name: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
            )

            // Memory pressure (tile-rendering-audit Tier A item 6). iOS
            // sends UIApplication.didReceiveMemoryWarningNotification when
            // the system is asking foreground apps to shed memory before
            // it starts killing background apps. The handler currently
            // just logs — Tier B+ work will populate it with undo-snapshot
            // shedding, hidden-layer tile drops, and reference-texture
            // cache eviction. Logging now means the signal lands in
            // CrashReporter's persistent log if the next thing that
            // happens is a memory-kill.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleMemoryWarning),
                name: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
            )

            print("Coordinator: Initialized with \(layers.wrappedValue.count) layers")
        }

        @objc private func handleAppDidEnterBackground() {
            DispatchQueue.main.async { [weak self] in
                self?.metalView?.isPaused = true
            }
        }

        @objc private func handleAppWillEnterForeground() {
            DispatchQueue.main.async { [weak self] in
                guard let view = self?.metalView else { return }
                // Order matters: un-pause the display link first so the
                // setNeedsDisplay call below has somewhere to land.
                view.isPaused = false
                view.setNeedsDisplay()
            }
        }

        /// Map `ProcessInfo.thermalState` to a `preferredFramesPerSecond`
        /// target. iPad ProMotion runs the canvas at 120 Hz by default;
        /// under thermal pressure we step down rather than wait for iOS to
        /// throttle us harder. The ladder is intentionally coarse for v1 —
        /// if `.fair` shows up regularly during real drawing sessions a
        /// softer rung (e.g. .fair → 90) is the obvious follow-up. The
        /// notification only fires on transitions, so `applyThermalState`
        /// is also called once after metalView is wired up in makeUIView.
        @objc private func handleThermalStateChange() {
            DispatchQueue.main.async { [weak self] in
                self?.applyThermalState()
            }
        }

        /// Memory-warning hook. Logging-only handler for now; populated by
        /// Tier B+ work in tile-rendering-audit.md (shed undo snapshots,
        /// drop hidden-layer tiles, clear reference-texture caches).
        /// Logging through CrashReporter (not raw `print`) so the signal
        /// is persisted in case the next thing iOS does is kill the app.
        @objc private func handleMemoryWarning() {
            CrashReporter.shared.logWarning(
                "Received UIApplication.didReceiveMemoryWarningNotification",
                context: "MetalCanvasView.Coordinator"
            )
        }

        // MARK: - Throttled redraw

        // Throttle for non-stroke redraw requests (gesture-driven viewport
        // transforms, selection drag, floating-text drag). Leading-edge
        // fires immediately; subsequent calls within the interval coalesce
        // into a trailing-edge fire that guarantees the final state lands
        // within `throttledRedrawInterval` of the last request.
        //
        // 60 Hz is the conservative starting value — half of ProMotion's
        // 120 Hz native cadence. If profile data shows ProMotion devices
        // can tolerate a faster rung without thermal regression, this is
        // the one-line edit. Raise to 1.0 / 90.0 or 1.0 / 80.0 to try a
        // softer cap.
        private static let throttledRedrawInterval: CFTimeInterval = 1.0 / 60.0

        private var lastThrottledRedrawAt: CFTimeInterval = 0
        private var pendingThrottledRedrawScheduled = false

        /// Request a redraw that may be coalesced under the
        /// `throttledRedrawInterval` cap. Safe to call at the input event
        /// rate; the trailing-edge fire ensures the final state always
        /// lands within the interval of the last request.
        ///
        /// Stroke paths must NOT route through here — they call
        /// `view.setNeedsDisplay()` directly so brush/eraser/smudge/blur
        /// render at native input rate. The discriminator is implicit at
        /// every call site: the SwiftUI snapshot gate's transform-only
        /// branch + the selection / floating-text touch drags route here;
        /// stroke touchesBegan/Moved/Ended bypass.
        ///
        /// No-op if the metalView ref is gone (Coordinator outliving view
        /// during teardown).
        func requestThrottledRedraw() {
            guard let view = metalView else { return }
            let now = CACurrentMediaTime()
            let elapsed = now - lastThrottledRedrawAt
            if elapsed >= Self.throttledRedrawInterval {
                // Leading edge: fire immediately, reset window.
                lastThrottledRedrawAt = now
                pendingThrottledRedrawScheduled = false
                view.setNeedsDisplay()
            } else if !pendingThrottledRedrawScheduled {
                // Trailing edge: schedule a fire at the end of the current
                // window so the final state always renders. Don't double-
                // schedule — repeated requests within the window collapse
                // to one trailing fire.
                pendingThrottledRedrawScheduled = true
                let delay = Self.throttledRedrawInterval - elapsed
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.flushPendingThrottledRedraw()
                }
            }
        }

        private func flushPendingThrottledRedraw() {
            pendingThrottledRedrawScheduled = false
            guard let view = metalView else { return }
            lastThrottledRedrawAt = CACurrentMediaTime()
            view.setNeedsDisplay()
        }

        /// Apply the current `ProcessInfo.thermalState` to the MTKView's
        /// `preferredFramesPerSecond`. Idempotent — safe to call from
        /// makeUIView for the initial state AND from the notification
        /// handler on every transition. No-op if the target rate already
        /// matches what's set.
        func applyThermalState() {
            guard let view = metalView else { return }
            let state = ProcessInfo.processInfo.thermalState
            let target: Int
            switch state {
            case .nominal, .fair:
                target = 120
            case .serious:
                target = 60
            case .critical:
                target = 30
            @unknown default:
                target = 120
            }
            guard view.preferredFramesPerSecond != target else { return }
            view.preferredFramesPerSecond = target
            view.setNeedsDisplay()
            #if DEBUG
            print("🌡️ Thermal state \(state) — preferredFramesPerSecond → \(target)")
            #endif
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

        /// Single-shot snapshot of every `canvasState` field the draw loop
        /// reads. Populated under one `MainActor.assumeIsolated` hop at the
        /// top of `draw(in:)` instead of the previous 7 individual hops.
        ///
        /// Behaviour-preserving by construction: each field's nil-state
        /// fallback mirrors the value the old per-read block returned when
        /// `canvasState` was nil. The MTKView delegate runs on the main
        /// thread by default; this struct doesn't change that — it just
        /// consolidates the reads.
        private struct DrawFrameSnapshot {
            // Canvas transform.
            let zoomScale: CGFloat
            let panOffset: CGPoint
            let canvasRotation: CGFloat  // radians
            let flipHorizontal: Bool
            let flipVertical: Bool

            // Active-layer drag preview.
            let isTranslatingActiveLayer: Bool
            let activeLayerIndex: Int
            let floatingSelectionTexture: MTLTexture?
            let selectionOriginalRect: CGRect?
            let selectionOffset: CGPoint
            let selectionScale: CGSize
            let selectionRotation: CGFloat  // radians
            let documentSize: CGSize

            // Floating-text overlay (read in the overlay pass below).
            let floatingTextTexture: MTLTexture?
            let floatingTextDocRect: CGRect
            let floatingTextRotation: CGFloat  // radians

            static let empty = DrawFrameSnapshot(
                zoomScale: 1.0,
                panOffset: .zero,
                canvasRotation: 0,
                flipHorizontal: false,
                flipVertical: false,
                isTranslatingActiveLayer: false,
                activeLayerIndex: -1,
                floatingSelectionTexture: nil,
                selectionOriginalRect: nil,
                selectionOffset: .zero,
                selectionScale: CGSize(width: 1, height: 1),
                selectionRotation: 0,
                documentSize: .zero,
                floatingTextTexture: nil,
                floatingTextDocRect: .zero,
                floatingTextRotation: 0
            )

            @MainActor
            init(canvasState: CanvasStateManager) {
                self.zoomScale = canvasState.zoomScale
                self.panOffset = canvasState.panOffset
                self.canvasRotation = canvasState.canvasRotation.radians
                self.flipHorizontal = canvasState.flipHorizontal
                self.flipVertical = canvasState.flipVertical
                self.isTranslatingActiveLayer = canvasState.isTranslatingActiveLayer
                self.activeLayerIndex = canvasState.selectedLayerIndex
                self.floatingSelectionTexture = canvasState.floatingSelectionTexture
                self.selectionOriginalRect = canvasState.selectionOriginalRect
                self.selectionOffset = canvasState.selectionOffset
                self.selectionScale = canvasState.selectionScale
                self.selectionRotation = canvasState.selectionRotation.radians
                self.documentSize = canvasState.documentSize
                if let ft = canvasState.floatingText, let tex = ft.cachedTexture {
                    self.floatingTextTexture = tex
                    self.floatingTextDocRect = ft.displayedRect
                    self.floatingTextRotation = ft.rotation.radians
                } else {
                    self.floatingTextTexture = nil
                    self.floatingTextDocRect = .zero
                    self.floatingTextRotation = 0
                }
            }

            private init(
                zoomScale: CGFloat, panOffset: CGPoint, canvasRotation: CGFloat,
                flipHorizontal: Bool, flipVertical: Bool,
                isTranslatingActiveLayer: Bool, activeLayerIndex: Int,
                floatingSelectionTexture: MTLTexture?, selectionOriginalRect: CGRect?,
                selectionOffset: CGPoint, selectionScale: CGSize,
                selectionRotation: CGFloat, documentSize: CGSize,
                floatingTextTexture: MTLTexture?, floatingTextDocRect: CGRect,
                floatingTextRotation: CGFloat
            ) {
                self.zoomScale = zoomScale
                self.panOffset = panOffset
                self.canvasRotation = canvasRotation
                self.flipHorizontal = flipHorizontal
                self.flipVertical = flipVertical
                self.isTranslatingActiveLayer = isTranslatingActiveLayer
                self.activeLayerIndex = activeLayerIndex
                self.floatingSelectionTexture = floatingSelectionTexture
                self.selectionOriginalRect = selectionOriginalRect
                self.selectionOffset = selectionOffset
                self.selectionScale = selectionScale
                self.selectionRotation = selectionRotation
                self.documentSize = documentSize
                self.floatingTextTexture = floatingTextTexture
                self.floatingTextDocRect = floatingTextDocRect
                self.floatingTextRotation = floatingTextRotation
            }
        }

        func draw(in view: MTKView) {
            guard let device = view.device,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor else {
                #if DEBUG
                print("MetalCanvasView.draw: Failed to get device/drawable/descriptor")
                #endif
                return
            }

            // Initialize renderer if needed
            if renderer == nil {
                #if DEBUG
                print("MetalCanvasView.draw: Initializing renderer")
                #endif
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
                    #if DEBUG
                    print("MetalCanvasView.draw: Shared renderer with canvas state")
                    print("  - Screen size: \(view.bounds.size)")
                    print("  - Canvas size: \(renderer.canvasSize)")
                    #endif

                    #if DEBUG
                    // Wet-ink Phase A sanity probe. One-shot, runs once per
                    // process lifetime after the first updateCanvasSize.
                    // Writes pass/fail + raw bytes to
                    // Documents/wetink_phase_a.log for offline review.
                    // See WET_INK_DESIGN.md §4 for the contract.
                    if !wetInkPhaseAProbeRun {
                        wetInkPhaseAProbeRun = true
                        renderer.runStrokeScratchPhaseAProbe()
                    }
                    // Wet-ink Phase A.5 shader-equivalence probe. Runs once
                    // immediately after Phase A so both probes share the
                    // same first-frame init window. Writes to
                    // Documents/wetink_phase_a5.log. See WET_INK_DESIGN.md
                    // §2.10 Phase A.5.
                    if !wetInkPhaseA5ProbeRun {
                        wetInkPhaseA5ProbeRun = true
                        renderer.runShaderEquivalencePhaseA5Probe()
                    }
                    // Wet-ink Phase B max-blend deposit probe. Runs once
                    // after A.5, proves .max/.max into strokeScratch behaves
                    // as the within-stroke no-accumulation rule requires.
                    // Writes to Documents/wetink_phase_b.log. See
                    // WET_INK_DESIGN.md §2.10 Phase B.
                    if !wetInkPhaseBProbeRun {
                        wetInkPhaseBProbeRun = true
                        renderer.runMaxBlendDepositPhaseBProbe()
                    }
                    // Wet-ink Phase C commit pipeline probe. Proves color B
                    // (full opacity) committed over color A produces exact
                    // B at the overlap pixel. Writes to
                    // Documents/wetink_phase_c.log. See WET_INK_DESIGN.md
                    // §2.10 Phase C.
                    if !wetInkPhaseCProbeRun {
                        wetInkPhaseCProbeRun = true
                        renderer.runCommitPipelinePhaseCProbe()
                    }
                    // Wet-ink Phase D opacity-scaling probe. Headline test:
                    // proves saturation-toward-1.0 bug is fixed and partial
                    // opacity behaves linearly. Writes
                    // Documents/wetink_phase_d.log. See WET_INK_DESIGN.md
                    // §2.10 Phase D.
                    if !wetInkPhaseDProbeRun {
                        wetInkPhaseDProbeRun = true
                        renderer.runOpacityScalingPhaseDProbe()
                    }
                    #endif
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

            // One-shot snapshot of every canvasState field this frame reads.
            // Replaces seven separate `MainActor.assumeIsolated` hops with a
            // single block. Behaviour-preserving: nil-state defaults match
            // what the previous per-read fallbacks returned.
            let snap: DrawFrameSnapshot = MainActor.assumeIsolated {
                guard let canvasState = canvasState else { return .empty }
                return DrawFrameSnapshot(canvasState: canvasState)
            }
            let zoomScale = snap.zoomScale
            let panOffset = snap.panOffset
            let rotation = snap.canvasRotation
            let flipH = snap.flipHorizontal
            let flipV = snap.flipVertical
            let flipState = SIMD2<Float>(flipH ? 1 : 0, flipV ? 1 : 0)

            // Clip every subsequent draw on this encoder to the canvas's
            // footprint on the drawable. Stops floating-text boxes,
            // dragged selections, and active-layer drag previews from
            // bleeding onto the gray workbench area outside the canvas
            // square. Background, references, layers, floating textures,
            // and the stroke preview all share this encoder.
            renderer?.setCanvasFootprintScissor(
                on: renderEncoder,
                drawableSize: view.drawableSize,
                viewportPoints: view.bounds.size,
                zoomScale: zoomScale,
                panOffset: panOffset,
                canvasRotation: rotation,
                flipHorizontal: flipH,
                flipVertical: flipV
            )

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

            // Back-canvas references — rendered AFTER the white paper
            // and BEFORE the layer composite, so strokes paint on top.
            // ARCHITECTURAL INVARIANT: these references never enter the
            // layer stack or compositeLayersToTexture. The AI/save/export
            // composite path is entirely unaware of them.
            renderBackCanvasReferences(view: view, encoder: renderEncoder)

            // Selection-drag preview state — sourced from the up-front snapshot
            // so the layer loop and the floating overlay below see a
            // consistent view (same guarantee the previous tuple read provided).
            let isTranslatingActiveLayer = snap.isTranslatingActiveLayer
            let activeLayerIndex = snap.activeLayerIndex
            let floatingTexture = snap.floatingSelectionTexture
            let selectionOriginalRect = snap.selectionOriginalRect
            let selectionOffsetDoc = snap.selectionOffset
            let selectionScale = snap.selectionScale
            let selectionRotationRad = snap.selectionRotation
            let documentSize = snap.documentSize

            // Phase 4.4a: end the background/references encoder before the
            // per-layer composite. The tile-path layer composite uses
            // alternating compose-onto-intermediate + draw-onto-drawable
            // render passes, which can't share an encoder with the
            // background pass (each render pass is its own encoder).
            renderEncoder.endEncoding()

            // Composite all visible layers via the tile path — encodes one
            // compose render pass into the renderer's
            // `tileDisplayIntermediate` per layer, then one draw render
            // pass onto the drawable with .load (preserving background +
            // back-references + prior layers' contributions).
            //
            // Per-layer compose+draw within ONE command buffer relies on
            // Metal's render-pass hazard tracking to serialize the
            // intermediate's writes against subsequent reads, so each
            // layer's draw reads its own intermediate state. Same pattern
            // as 4.3c's encodeLayerComposite(useTilePath: true), promoted
            // here from shadow rendering to live drawable rendering.
            //
            // Move-tool whole-layer translate preview retained: when the
            // active layer is mid-drag, its draw pass uses
            // renderFloatingTexture at the offset docRect instead of
            // renderTextureToScreen at the normal position.
            //
            // Blur-adjustment preview swap retained: when the active layer
            // has a blur preview, the source for its draw pass is the
            // renderer-owned monolithic preview texture (no tile compose).
            for (index, layer) in layers.enumerated() where layer.isVisible {
                // Determine the source texture for this layer's draw pass:
                //   - Blur preview active for this layer: renderer-owned
                //     canvas-sized preview texture (no compose pass needed).
                //   - Else: compose this layer's tiles into the tile-display
                //     intermediate, use intermediate as source.
                //   - tileGrid nil: invariant violation post-Phase-4.5e —
                //     skip the layer (no content to draw).
                let blurPreviewTex: MTLTexture? = {
                    if index == activeLayerIndex {
                        return renderer?.blurAdjustmentPreviewTexture(forLayer: layer.id)
                    }
                    return nil
                }()

                let sourceTexture: MTLTexture?
                if let preview = blurPreviewTex {
                    sourceTexture = preview
                } else if let grid = layer.tileGrid {
                    renderer?.encodeLayerTileCompositeOntoIntermediate(grid, on: commandBuffer)
                    // Wet-ink live preview: if a wet-ink stroke is active
                    // on THIS layer, composite strokeScratch on top of the
                    // tile-composited intermediate via the same commit
                    // pipeline used at touchesEnded. The preview matches
                    // the eventual commit bit-for-bit; the user sees the
                    // in-progress stroke composited correctly with
                    // within-stroke max-cap behavior already applied.
                    if renderer?.activeWetInkLayerId == layer.id {
                        renderer?.encodeWetInkPreviewCompositeOntoIntermediate(on: commandBuffer)
                    }
                    sourceTexture = renderer?.tileDisplayIntermediate
                } else {
                    // Phase 4.5e: layer.texture is gone. No tileGrid means
                    // the layer has no content to draw — skip it.
                    continue
                }
                guard let source = sourceTexture else { continue }

                // Open a new render pass on the drawable with .load to
                // preserve background + back-references + prior layers'
                // contributions. Scissor needs to be set per-encoder.
                let drawDesc = MTLRenderPassDescriptor()
                drawDesc.colorAttachments[0].texture = drawable.texture
                drawDesc.colorAttachments[0].loadAction = .load
                drawDesc.colorAttachments[0].storeAction = .store
                guard let drawEnc = commandBuffer.makeRenderCommandEncoder(descriptor: drawDesc) else { continue }
                renderer?.setCanvasFootprintScissor(
                    on: drawEnc,
                    drawableSize: view.drawableSize,
                    viewportPoints: view.bounds.size,
                    zoomScale: zoomScale,
                    panOffset: panOffset,
                    canvasRotation: rotation,
                    flipHorizontal: flipH,
                    flipVertical: flipV
                )

                if isTranslatingActiveLayer && index == activeLayerIndex && documentSize.width > 0 {
                    let docRect = CGRect(
                        x: selectionOffsetDoc.x,
                        y: selectionOffsetDoc.y,
                        width: documentSize.width,
                        height: documentSize.height
                    )
                    renderer?.renderFloatingTexture(
                        source,
                        atDocRect: docRect,
                        to: drawEnc,
                        opacity: layer.opacity,
                        zoomScale: Float(zoomScale),
                        panOffset: SIMD2<Float>(Float(panOffset.x), Float(panOffset.y)),
                        canvasRotation: Float(rotation),
                        viewportSize: SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height)),
                        flipState: flipState
                    )
                } else {
                    renderer?.renderTextureToScreen(
                        source,
                        to: drawEnc,
                        opacity: layer.opacity,
                        zoomScale: Float(zoomScale),
                        panOffset: SIMD2<Float>(Float(panOffset.x), Float(panOffset.y)),
                        canvasRotation: Float(rotation),
                        viewportSize: SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height)),
                        flipState: flipState
                    )
                }

                drawEnc.endEncoding()
            }

            // Overlays render pass: floating selection + floating text +
            // stroke preview on a final encoder with .load to preserve the
            // layer-composited drawable contents below.
            let overlayDesc = MTLRenderPassDescriptor()
            overlayDesc.colorAttachments[0].texture = drawable.texture
            overlayDesc.colorAttachments[0].loadAction = .load
            overlayDesc.colorAttachments[0].storeAction = .store
            guard let overlayEnc = commandBuffer.makeRenderCommandEncoder(descriptor: overlayDesc) else {
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }
            renderer?.setCanvasFootprintScissor(
                on: overlayEnc,
                drawableSize: view.drawableSize,
                viewportPoints: view.bounds.size,
                zoomScale: zoomScale,
                panOffset: panOffset,
                canvasRotation: rotation,
                flipHorizontal: flipH,
                flipVertical: flipV
            )

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
                    to: overlayEnc,
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
            // pass a scale uniform. Values come from the up-front frame
            // snapshot, same as every other canvasState field this frame uses.
            let floatingTextTexture = snap.floatingTextTexture
            let floatingTextDocRect = snap.floatingTextDocRect
            let floatingTextRotation = snap.floatingTextRotation
            if let ftTex = floatingTextTexture, floatingTextDocRect.width > 0, floatingTextDocRect.height > 0 {
                renderer?.renderFloatingTexture(
                    ftTex,
                    atDocRect: floatingTextDocRect,
                    rotation: Float(floatingTextRotation),
                    to: overlayEnc,
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
            // Skip every wet-ink tool: brush, eraser, and the 5 additive
            // variants (pencil/inkPen/marker/airbrush/charcoal). Their
            // strokes are already visible via the scratch-over-intermediate
            // composite encoded earlier in the per-layer loop; running
            // renderStrokePreview on top would double-deposit.
            // Shape tools (line/rect/circle) still need the preview path
            // until Phase H lands.
            if let stroke = currentStroke, !stroke.points.isEmpty,
               stroke.tool != .blur,
               !isWetInkTool(stroke.tool) {
                renderer?.renderStrokePreview(
                    stroke,
                    to: overlayEnc,
                    viewportSize: view.bounds.size,
                    drawableSize: view.drawableSize,
                    zoomScale: zoomScale,
                    panOffset: panOffset,
                    canvasRotation: rotation,
                    flipHorizontal: flipH,
                    flipVertical: flipV
                )
            }

            overlayEnc.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        func ensureLayerTextures() {
            guard let renderer = renderer else { return }

            var created = false

            // Check all layers for missing tile grids
            for i in 0..<layers.count {
                if layers[i].tileGrid == nil {
                    #if DEBUG
                    print("⚠️ Layer \(i) '\(layers[i].name)' has NIL tileGrid - creating new one. Layer ID: \(layers[i].id)")
                    #endif
                    layers[i].tileGrid = renderer.makeEmptyTileGrid()
                    if layers[i].tileGrid != nil {
                        created = true
                    }
                }
            }

            if created {
                #if DEBUG
                print("📋 Current layer state:")
                for (i, layer) in layers.enumerated() {
                    let gridState = layer.tileGrid != nil ? "tileGrid ready" : "❌ NO GRID"
                    print("  Layer \(i) '\(layer.name)' [ID: \(layer.id)]: \(gridState)")
                }
                #endif
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
        // Returns (size, alpha). The two fields drive separate uniforms:
        // `uniforms.pressure` (vertex shader pointSize) and
        // `uniforms.pressureAlpha` (fragment shader alpha multiply). For
        // Pencil they're equal — pressing harder both grows and darkens
        // the stamp. For non-Pencil input we keep `size = 0.75` so finger
        // strokes feel size-comparable to Pencil (the original rationale
        // for the 0.75 fudge), but `alpha = 1.0` so the user's opacity
        // slider isn't silently capped at 75% on the first stamp of a
        // non-Pencil stroke. Premul-over stamp accumulation in the same
        // stroke still saturates toward fully opaque (the accepted
        // pre-Phase-4.6 behaviour); the split prevents the size-fudge
        // from being mistaken for an alpha-fudge.
        private func computePressure(for touch: UITouch) -> (size: CGFloat, alpha: CGFloat) {
            let settings = brushSettings
            if touch.type == .pencil {
                guard settings.pressureSensitivity else { return (1.0, 1.0) }
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
                    return (1.0, 1.0)
                }
                let raw = max(0, min(1, touch.force / touch.maximumPossibleForce))
                guard raw.isFinite else { return (1.0, 1.0) }
                let lo = settings.minPressureSize
                let hi = settings.maxPressureSize
                let result = lo + raw * (hi - lo)
                let safe = result.isFinite ? result : 1.0
                return (safe, safe)
            } else {
                // Fingers have no reliable pressure on iPad. 0.75 keeps
                // finger strokes size-comparable to Pencil at the same
                // brush size; alpha 1.0 honours the opacity slider.
                return (0.75, 1.0)
            }
        }

        private func diagnosticInputType(for touch: UITouch) -> BrushStroke.InputType {
            switch touch.type {
            case .direct:
                return .direct
            case .indirect:
                return .indirect
            case .pencil:
                return .pencil
            case .indirectPointer:
                return .indirectPointer
            @unknown default:
                return .unknown
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

            // Perfect-shape two-finger constraint. A new touch landing on
            // the canvas while a shape stroke is mid-drag is the modifier
            // that snaps the in-progress rectangle/circle/line to a square
            // /circle/45° line. We don't start a competing stroke for the
            // modifier finger — it's parked in `shapeConstraintTouchIDs`
            // until lift. Force a redraw so the preview reflects the
            // constraint immediately even if the primary touch hasn't moved.
            if [.line, .rectangle, .circle].contains(currentTool),
               shapeStartPoint != nil,
               shapePrimaryTouchID != nil {
                for t in touches where ObjectIdentifier(t) != shapePrimaryTouchID {
                    shapeConstraintTouchIDs.insert(ObjectIdentifier(t))
                }
                view.setNeedsDisplay()
                return
            }

            // Ensure layer textures exist
            ensureLayerTextures()

            // A touch is now active — kill the Apple Pencil hover cursor.
            // Trackpad / mouse pointers on iPad can keep firing hover
            // events while a finger is also touching the screen, and a
            // ghost cursor lingering mid-stroke is the bug this guards
            // against. Cleared on touchesEnded / touchesCancelled.
            if !isStrokeInProgress {
                onHoverChange?(nil)
            }
            isStrokeInProgress = true

            // Get touch location and transform from screen space to document space
            let screenLocation = touch.location(in: view)
            let location = canvasState?.screenToDocument(screenLocation) ?? screenLocation

            let (pressure, pressureAlpha) = computePressure(for: touch)
            let inputType = diagnosticInputType(for: touch)
            let rawTouchForce = touch.force
            let rawTouchMaxForce = touch.maximumPossibleForce
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
                print("   Will draw to: '\(layer.name)' - has tile grid: \(layer.tileGrid != nil)")
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
                      layers[selectedLayerIndex].tileGrid != nil,
                      let renderer = renderer else {
                    print("Smudge: cannot begin stroke — invalid layer or tile grid")
                    return
                }
                let layerId = layers[selectedLayerIndex].id
                // Selection geometry is fixed for the duration of a stroke;
                // pass it once at begin and the renderer rasterises + caches.
                let smudgeSelectionPath = MainActor.assumeIsolated { canvasState?.selectionPath }
                let smudgeDocSize = MainActor.assumeIsolated { canvasState?.documentSize ?? view.bounds.size }
                let strokeID = UUID()
                if !renderer.beginSmudgeStroke(strokeID: strokeID,
                                               brushSize: brushSettings.size,
                                               layerId: layerId,
                                               selectionPath: smudgeSelectionPath,
                                               documentSize: smudgeDocSize) {
                    print("Smudge: renderer failed to allocate patch textures")
                    return
                }
                smudgeBeforeSnapshot = layers[selectedLayerIndex].tileGrid.flatMap { renderer.captureSnapshot(tileGrid: $0) }
                smudgeStrokeLayerIndex = selectedLayerIndex
                smudgeStrokeLayerId = layerId
                smudgeStrokeID = strokeID
                smudgePendingTouchdown = BrushStroke.StrokePoint(
                    location: location,
                    pressure: pressure,
                    pressureAlpha: pressureAlpha,
                    inputType: inputType,
                    rawTouchForce: rawTouchForce,
                    rawTouchMaxForce: rawTouchMaxForce,
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
                #if DEBUG
                CanvasStrokeDiagnostics.log("stroke begin stroke=\(CanvasStrokeDiagnostics.shortID(strokeID)) tool=smudge input=\(inputType.diagnosticName) slider{\(CanvasStrokeDiagnostics.format(brushSettings))} pressure=\(CanvasStrokeDiagnostics.format(pressure)) pressureAlpha=\(CanvasStrokeDiagnostics.format(pressureAlpha)) start=\(CanvasStrokeDiagnostics.format(location))")
                #endif
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

            // Handle paint bucket tool — flood fill is DEFERRED to
            // touchesEnded so a second finger landing (the leading edge of
            // a pinch / two-finger pan) can suppress the fill before it
            // commits. Previously this dispatched the fill synchronously
            // on touchdown, which meant attempts to pinch-zoom while the
            // paint-bucket tool was active always painted the canvas
            // first. The flow now:
            //
            //   touchesBegan (one finger):  capture before-snapshot, stash
            //                               request, no GPU work yet.
            //   touchesBegan (>1 finger):   drop the pending request and
            //                               return — multi-touch means the
            //                               user is starting a transform.
            //   touchesCancelled:           UIKit fires this on the MTKView
            //                               when a pinch/pan/rotation
            //                               gesture claims the touches;
            //                               that clears pendingPaintBucketFill
            //                               in the cancellation handler.
            //   touchesEnded (single tap):  execute the dispatched fill.
            //
            // For a real single-finger tap the deferral is imperceptible
            // (touchdown→liftoff is a few tens of ms), and a pre-captured
            // before-snapshot keeps the undo record identical to the
            // previous synchronous path.
            if currentTool == .paintBucket {
                // Multi-touch guard: if a second touch is already on the
                // screen we're at the leading edge of a transform gesture,
                // not a tap-to-fill. Drop any pending fill from a prior
                // single-finger touchdown.
                if (touches.count > 1) || ((event?.allTouches?.count ?? 1) > 1) {
                    pendingPaintBucketFill = nil
                    print("Paint bucket: multi-touch detected on begin, suppressing pending fill")
                    return
                }
                guard selectedLayerIndex < layers.count,
                      layers[selectedLayerIndex].tileGrid != nil,
                      let renderer = renderer,
                      let canvasState = canvasState else {
                    print("ERROR: Cannot prepare paint-bucket fill - invalid layer or tile grid")
                    pendingPaintBucketFill = nil
                    return
                }
                // Re-entrancy guard: ignore taps while a previous fill is
                // still running on the background queue. The HUD over the
                // canvas also blocks hits, but this is the authoritative
                // check.
                if canvasState.isFilling {
                    print("Paint bucket: ignoring tap, fill already in progress")
                    pendingPaintBucketFill = nil
                    return
                }
                pendingPaintBucketFill = PendingPaintBucketFill(
                    docLocation: location,
                    layerIndex: selectedLayerIndex,
                    layerId: layers[selectedLayerIndex].id,
                    beforeSnapshot: layers[selectedLayerIndex].tileGrid.flatMap { renderer.captureSnapshot(tileGrid: $0) }
                )
                print("Paint bucket: pending fill captured at \(location) (awaiting touchesEnded)")
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
                    // Phase 3 (Color System Overhaul, 2026-05-13):
                    // every eyedropper pick also lands in the recent-
                    // colors strip so the user can re-tap a previously-
                    // sampled color without having to eyedropper-pick
                    // the same pixel again. PaletteManager handles
                    // dedupe + capping.
                    MainActor.assumeIsolated {
                        PaletteManager.shared.addRecentColor(pickedColor)
                    }
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
                    // Body-grab is also a "transform" for UI purposes —
                    // hide marching ants while the user moves the
                    // selection content. Cleared in touchesEnded /
                    // touchesCancelled. See SelectionOverlays' handle
                    // gestures for the matching set on scale/rotation.
                    MainActor.assumeIsolated {
                        canvasState.isTransformingSelection = true
                    }
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
                // Lock the touchdown pressure for the duration of the
                // drag; preview and commit both read it.
                shapeStartPressure = pressure
                shapeStartPressureAlpha = pressureAlpha
                shapeStartInputType = inputType
                shapeStartRawTouchForce = rawTouchForce
                shapeStartRawTouchMaxForce = rawTouchMaxForce
                // Track the primary touch ID so a second finger landing
                // mid-drag can be routed into the perfect-shape
                // constraint path instead of starting a competing stroke.
                shapePrimaryTouchID = ObjectIdentifier(touch)
                shapeConstraintTouchIDs.removeAll()
                print("Shape tool: stored start point \(location) (screen: \(screenLocation))")
            }

            // Start new stroke
            let point = BrushStroke.StrokePoint(
                location: location,
                pressure: pressure,
                pressureAlpha: pressureAlpha,
                inputType: inputType,
                rawTouchForce: rawTouchForce,
                rawTouchMaxForce: rawTouchMaxForce,
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
            #if DEBUG
            if let currentStroke {
                CanvasStrokeDiagnostics.log("stroke begin stroke=\(CanvasStrokeDiagnostics.shortID(currentStroke.id)) tool=\(currentTool) input=\(inputType.diagnosticName) slider{\(CanvasStrokeDiagnostics.format(brushSettings))} pressure=\(CanvasStrokeDiagnostics.format(pressure)) pressureAlpha=\(CanvasStrokeDiagnostics.format(pressureAlpha)) start=\(CanvasStrokeDiagnostics.format(location))")
            }
            #endif

            // Wet-ink real-time session. Routes every wet-ink-enabled
            // tool (brush, eraser, pencil, inkPen, marker, airbrush,
            // charcoal) through the unified lifecycle: deposit stamps
            // into strokeScratch via .max/.max (no within-stroke
            // accumulation), commit at touchesEnded (premul-over for
            // additive, dest-out for eraser). Shape tools (line, rect,
            // circle) stay on OLD renderStroke until Phase H.
            //
            // If beginWetInkStroke fails, wetInkActive stays false and
            // the OLD per-tool fallback blocks below take over.
            if isWetInkTool(currentTool),
               let tileGrid = layers[selectedLayerIndex].tileGrid,
               let renderer = renderer {
                let wetInkSelectionPath = MainActor.assumeIsolated { canvasState?.selectionPath }
                let wetInkDocSize = MainActor.assumeIsolated {
                    canvasState?.documentSize ?? view.bounds.size
                }
                wetInkBeforeSnapshot = renderer.captureSnapshot(tileGrid: tileGrid)
                wetInkLayerIndex = selectedLayerIndex
                wetInkLayerId = layers[selectedLayerIndex].id
                wetInkCommittedPointCount = 0
                wetInkActive = renderer.beginWetInkStroke(
                    strokeID: currentStroke?.id ?? UUID(),
                    tool: currentTool,
                    settings: brushSettings,
                    layerId: layers[selectedLayerIndex].id,
                    tileGrid: tileGrid,
                    selectionPath: wetInkSelectionPath,
                    documentSize: wetInkDocSize
                )
                if wetInkActive {
                    flushWetInkSession()
                }
            }

            // Tier-1.5 eraser real-time commit — OLD path, retained as
            // fallback when wet-ink failed to begin. Skipped when
            // wetInkActive is true (eraser now flows through wet-ink).
            if !wetInkActive,
               currentTool == .eraser,
               let tileGrid = layers[selectedLayerIndex].tileGrid,
               let renderer = renderer {
                eraserBeforeSnapshot = renderer.captureSnapshot(tileGrid: tileGrid)
                eraserCommittedPointCount = 0
                flushEraserSubStroke(view: view)
            }

            // Real-time blur stroke: snapshot the layer + open a renderer
            // session here so subsequent touchesMoved can deposit blurred
            // stamps under the user's finger instead of waiting for
            // touchesEnded. If beginBlurStroke fails (intermediate
            // textures unavailable), blurStrokeActive stays false and
            // the deferred dispatchStroke path at touchesEnded still
            // runs as a fallback.
            if currentTool == .blur,
               let tileGrid = layers[selectedLayerIndex].tileGrid,
               let renderer = renderer {
                let blurSelectionPath = MainActor.assumeIsolated { canvasState?.selectionPath }
                let blurDocSize = MainActor.assumeIsolated {
                    canvasState?.documentSize ?? view.bounds.size
                }
                blurStrokeBeforeSnapshot = renderer.captureSnapshot(tileGrid: tileGrid)
                blurStrokeLayerIndex = selectedLayerIndex
                blurStrokeLayerId = layers[selectedLayerIndex].id
                blurCommittedPointCount = 0
                blurStrokeActive = renderer.beginBlurStroke(
                    strokeID: currentStroke?.id ?? UUID(),
                    tileGrid: tileGrid,
                    settings: brushSettings,
                    screenSize: blurDocSize,
                    selectionPath: blurSelectionPath
                )
                if blurStrokeActive {
                    flushBlurSubStroke()
                }
            }

            // Cache the selection mask for the stroke preview. Rasterised
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
                snapLatestPressureAlpha = pressureAlpha
                snapLatestInputType = inputType
                snapLatestRawTouchForce = rawTouchForce
                snapLatestRawTouchMaxForce = rawTouchMaxForce
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
            view.setNeedsDisplay()
        }

        func touchesMoved(_ touches: Set<UITouch>, in view: MTKView, with event: UIEvent?) {
            // Filter out perfect-shape constraint touches. Their movement is
            // irrelevant — only their existence matters (the constraint flag
            // is set in touchesBegan; their lift clears it in touchesEnded).
            // Without this filter, `touches.first` could be the constraint
            // touch and the shape geometry would track the wrong finger.
            let touch: UITouch? = {
                if !shapeConstraintTouchIDs.isEmpty {
                    if let primary = shapePrimaryTouchID,
                       let primaryTouch = touches.first(where: { ObjectIdentifier($0) == primary }) {
                        return primaryTouch
                    }
                    return touches.first(where: { !shapeConstraintTouchIDs.contains(ObjectIdentifier($0)) })
                }
                return touches.first
            }()
            guard let touch = touch else {
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
                      let strokeTileGrid = layers[strokeLayerIndex].tileGrid,
                      layers[strokeLayerIndex].id == strokeLayerId else {
                    // Layer changed mid-stroke (or tile grid went away).
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
                    let (samplePressure, samplePressureAlpha) = computePressure(for: sample)
                    let sampleInputType = diagnosticInputType(for: sample)
                    let sampleRawForce = sample.force
                    let sampleRawMaxForce = sample.maximumPossibleForce
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
                                let prevPressureAlpha = batch.last?.pressureAlpha ?? samplePressureAlpha
                                let safePrevAlpha = prevPressureAlpha.isFinite ? prevPressureAlpha : samplePressureAlpha
                                let safeSampleAlpha = samplePressureAlpha.isFinite ? samplePressureAlpha : 1.0
                                let interpPressureAlpha = (1 - t) * safePrevAlpha + t * safeSampleAlpha
                                batch.append(BrushStroke.StrokePoint(
                                    location: interpLocation,
                                    pressure: interpPressure.isFinite ? interpPressure : 1.0,
                                    pressureAlpha: interpPressureAlpha.isFinite ? interpPressureAlpha : 1.0,
                                    inputType: sampleInputType,
                                    rawTouchForce: sampleRawForce,
                                    rawTouchMaxForce: sampleRawMaxForce,
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
                        layerId: strokeLayerId,
                        tileGrid: strokeTileGrid,
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
                // Floating-text drag — throttleable. The trailing-edge fire
                // guarantees the final position renders within the throttle
                // interval of touchesEnded.
                requestThrottledRedraw()
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
                // Selection drag — throttleable, same rationale as the
                // floating-text drag above.
                requestThrottledRedraw()

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
                // Pressure is locked at touchdown (see shapeStartPressure
                // doc) so preview width stays stable and matches commit.
                let touchdownPressure = computePressure(for: touch)
                let endPressure = shapeStartPressure ?? touchdownPressure.size
                let endPressureAlpha = shapeStartPressureAlpha ?? touchdownPressure.alpha
                let endInputType = shapeStartInputType ?? diagnosticInputType(for: touch)
                let endRawTouchForce = shapeStartRawTouchForce ?? touch.force
                let endRawTouchMaxForce = shapeStartRawTouchMaxForce ?? touch.maximumPossibleForce
                let constrainPerfect = !shapeConstraintTouchIDs.isEmpty
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
                        pressureAlpha: endPressureAlpha,
                        inputType: endInputType,
                        rawTouchForce: endRawTouchForce,
                        rawTouchMaxForce: endRawTouchMaxForce,
                        timestamp: touch.timestamp,
                        constrainPerfect: constrainPerfect
                    )
                    originals = screenPoints.map { sp in
                        BrushStroke.StrokePoint(
                            location: canvasState.screenToDocument(sp.location),
                            pressure: sp.pressure,
                            pressureAlpha: sp.pressureAlpha,
                            inputType: sp.inputType,
                            rawTouchForce: sp.rawTouchForce,
                            rawTouchMaxForce: sp.rawTouchMaxForce,
                            timestamp: sp.timestamp
                        )
                    }
                } else {
                    originals = generateShapePoints(
                        from: startPoint,
                        to: latestLocation,
                        tool: currentTool,
                        pressure: endPressure,
                        pressureAlpha: endPressureAlpha,
                        inputType: endInputType,
                        rawTouchForce: endRawTouchForce,
                        rawTouchMaxForce: endRawTouchMaxForce,
                        timestamp: touch.timestamp,
                        constrainPerfect: constrainPerfect
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
                    let snapSamplePressure = computePressure(for: lastSample)
                    snapLatestPressure = snapSamplePressure.size
                    snapLatestPressureAlpha = snapSamplePressure.alpha
                    snapLatestInputType = diagnosticInputType(for: lastSample)
                    snapLatestRawTouchForce = lastSample.force
                    snapLatestRawTouchMaxForce = lastSample.maximumPossibleForce
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
                    let (samplePressure, samplePressureAlpha) = computePressure(for: sample)
                    let sampleInputType = diagnosticInputType(for: sample)
                    let sampleRawForce = sample.force
                    let sampleRawMaxForce = sample.maximumPossibleForce
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

                                let previousPressureAlpha = stroke.points.last?.pressureAlpha ?? samplePressureAlpha
                                let safePrevAlpha = previousPressureAlpha.isFinite ? previousPressureAlpha : samplePressureAlpha
                                let safeSampleAlpha = samplePressureAlpha.isFinite ? samplePressureAlpha : 1.0
                                let interpPressureAlpha = (lastTimestamp > 0)
                                    ? (1 - t) * safePrevAlpha + t * safeSampleAlpha
                                    : safeSampleAlpha

                                stroke.points.append(BrushStroke.StrokePoint(
                                    location: interpLocation,
                                    pressure: interpPressure.isFinite ? interpPressure : 1.0,
                                    pressureAlpha: interpPressureAlpha.isFinite ? interpPressureAlpha : 1.0,
                                    inputType: sampleInputType,
                                    rawTouchForce: sampleRawForce,
                                    rawTouchMaxForce: sampleRawMaxForce,
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
                // Eraser real-time. Prefer the wet-ink path when active;
                // fall back to the OLD per-stamp commit otherwise.
                if currentTool == .eraser {
                    if wetInkActive {
                        flushWetInkSession()
                    } else {
                        flushEraserSubStroke(view: view)
                    }
                }
                // Real-time blur stroke (experiment/blur-brush-realtime):
                // peel off the new points and dispatch them through the
                // active blur session. No-op when the session never
                // started (intermediate-texture allocation failed in
                // touchesBegan); deferred-path fallback at touchesEnded
                // still runs in that case.
                if currentTool == .blur {
                    flushBlurSubStroke()
                }
                // Wet-ink real-time deposit for brush + additive variants
                // (pencil, inkPen, marker, airbrush, charcoal). Eraser is
                // handled in its own branch above. No-op when wetInkActive
                // is false (begin failed); OLD renderStroke fallback runs
                // at touchesEnded in that case.
                if currentTool == .brush ||
                   currentTool == .pencil ||
                   currentTool == .inkPen ||
                   currentTool == .marker ||
                   currentTool == .airbrush ||
                   currentTool == .charcoal {
                    flushWetInkSession()
                }

                // Print every 10th point to avoid spam
                if stroke.points.count % 10 == 0 {
                    print("touchesMoved: stroke has \(stroke.points.count) points (coalesced samples: \(samples.count))")
                }
            }

            // Fix 1.1: render-on-demand mode. Each Pencil event schedules
            // the next frame; idle = no frames until something changes.
            view.setNeedsDisplay()
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
                  let tileGrid = layers[selectedLayerIndex].tileGrid,
                  let renderer = renderer else {
                onDone()
                return
            }
            let documentSize = MainActor.assumeIsolated {
                canvasState?.documentSize ?? view.bounds.size
            }
            let selPath = MainActor.assumeIsolated { canvasState?.selectionPath }
            let stampIndexBase = eraserCommittedPointCount
            let newPoints = Array(stroke.points[eraserCommittedPointCount..<stroke.points.count])
            let subStroke = BrushStroke(
                id: stroke.id,
                points: newPoints,
                settings: stroke.settings,
                tool: .eraser,
                layerId: stroke.layerId
            )
            eraserCommittedPointCount = stroke.points.count
            renderer.renderStroke(
                subStroke,
                tileGrid: tileGrid,
                screenSize: documentSize,
                selectionPath: selPath,
                stampIndexBase: stampIndexBase,
                completion: onDone
            )
        }

        /// Real-time blur substroke flush — peels off any points appended
        /// to `currentStroke.points` since the last call and hands them to
        /// the renderer's active blur session. Idempotent / no-op when
        /// the session isn't active or no new points have arrived.
        private func flushBlurSubStroke() {
            guard blurStrokeActive,
                  let stroke = currentStroke,
                  stroke.tool == .blur,
                  let renderer = renderer,
                  stroke.points.count > blurCommittedPointCount else {
                return
            }
            let newPoints = Array(stroke.points[blurCommittedPointCount..<stroke.points.count])
            let stampIndexBase = blurCommittedPointCount
            blurCommittedPointCount = stroke.points.count
            renderer.appendBlurStrokeStamps(newPoints, stampIndexBase: stampIndexBase)
        }

        /// Wet-ink brush real-time deposit. Mirrors `flushBlurSubStroke`:
        /// slices off `[committedCount..<count]` from currentStroke.points
        /// and hands them to the renderer for deposit into strokeScratch.
        /// No-op when the session isn't active or no new points have
        /// arrived since the last call.
        private func flushWetInkSession() {
            guard wetInkActive,
                  let stroke = currentStroke,
                  isWetInkTool(stroke.tool),
                  let renderer = renderer,
                  stroke.points.count > wetInkCommittedPointCount else {
                return
            }
            let newPoints = Array(stroke.points[wetInkCommittedPointCount..<stroke.points.count])
            let stampIndexBase = wetInkCommittedPointCount
            wetInkCommittedPointCount = stroke.points.count
            renderer.flushWetInkSubStroke(stamps: newPoints, stampIndexBase: stampIndexBase)
        }

        func touchesEnded(_ touches: Set<UITouch>, in view: MTKView, with event: UIEvent?) {
            print("=== TOUCH ENDED ===")

            // Hover-cursor suppression flag rides every early return in
            // this function. defer covers them all from one place.
            defer {
                // Re-enable hover only when this was the last touch in the
                // event — otherwise (e.g. a two-finger pinch where the
                // second finger lifts first) we'd flicker the cursor back
                // on mid-gesture. UIEvent.allTouches.count counts every
                // touch the event still tracks, including the ones in the
                // touches set that are ending right now; subtract them.
                let endingCount = touches.count
                let totalTouches = event?.allTouches?.count ?? endingCount
                if totalTouches - endingCount <= 0 {
                    isStrokeInProgress = false
                }
            }

            // Active-layer bounds guard — see touchesBegan for rationale.
            // touchesEnded reads `layers[selectedLayerIndex]` for stroke
            // commit + thumbnail refresh. Bail before any of that runs.
            guard !layers.isEmpty,
                  layers.indices.contains(selectedLayerIndex) else {
                return
            }

            // Perfect-shape constraint lifecycle. If only a secondary
            // (constraint) touch lifted, drop it from the set and force a
            // redraw so the preview reverts to freeform if no constraint
            // touches remain. The primary touch is still down, so the shape
            // stroke must NOT be finalized here.
            if !shapeConstraintTouchIDs.isEmpty {
                var droppedAny = false
                for t in touches {
                    if shapeConstraintTouchIDs.remove(ObjectIdentifier(t)) != nil {
                        droppedAny = true
                    }
                }
                let primaryEnded = shapePrimaryTouchID.map { primary in
                    touches.contains(where: { ObjectIdentifier($0) == primary })
                } ?? false
                if droppedAny && !primaryEnded {
                    view.setNeedsDisplay()
                    return
                }
            }

            // Blur adjustment: clear the touchdown anchor — no commit on lift.
            // Sigma is held at whatever value the last drag tick set it to;
            // commit happens only via the HUD's ✓ button.
            if currentTool == .blurAdjustment {
                blurAdjustmentTouchStartScreen = nil
                blurAdjustmentLastUpdateAt = 0
                return
            }

            // Paint bucket: execute the deferred fill captured at touchdown.
            // pendingPaintBucketFill is cleared by touchesCancelled if a
            // transform gesture grabbed the touches first; the nil-check
            // here is what makes the gesture gate actually work. The
            // dispatch body is identical to the previous synchronous
            // path in touchesBegan — only the trigger moved.
            if currentTool == .paintBucket, let pending = pendingPaintBucketFill {
                pendingPaintBucketFill = nil
                guard pending.layerIndex < layers.count,
                      layers[pending.layerIndex].id == pending.layerId,
                      let tileGrid = layers[pending.layerIndex].tileGrid,
                      let renderer = renderer,
                      let canvasState = canvasState else {
                    print("Paint bucket: pending fill abandoned — layer changed before lift")
                    return
                }
                if canvasState.isFilling {
                    return
                }
                let documentSize = MainActor.assumeIsolated { canvasState.documentSize }
                let currentLayerIndex = pending.layerIndex
                let layerId = pending.layerId
                let beforeSnapshot = pending.beforeSnapshot
                let capturedTileGrid: TileGrid = tileGrid
                let dispatched = renderer.floodFill(
                    at: pending.docLocation,
                    with: brushSettings.color,
                    tileGrid: tileGrid,
                    screenSize: documentSize
                ) { [weak self] in
                    let afterSnapshot = renderer.captureSnapshot(tileGrid: capturedTileGrid)
                    if let before = beforeSnapshot, let after = afterSnapshot {
                        canvasState.historyManager.record(.stroke(
                            layerId: layerId,
                            beforeSnapshot: before,
                            afterSnapshot: after
                        ))
                    }
                    canvasState.bumpLayerMutation()
                    DispatchQueue.global(qos: .utility).async {
                        if let thumbnail = renderer.generateThumbnail(fromTileGrid: capturedTileGrid, size: CGSize(width: 44, height: 44)) {
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
                smudgeStrokeID = nil
                smudgePendingTouchdown = nil
                smudgeBeforeSnapshot = nil

                if let renderer = renderer {
                    if let li = strokeLayerIndex,
                       let lid = strokeLayerId,
                       li < layers.count,
                       layers[li].id == lid,
                       let smudgeTileGrid = layers[li].tileGrid {
                        // Drain the in-flight smudge command buffers before
                        // reading back. We don't have a handle to them
                        // here, but `captureSnapshot` issues a blit with
                        // waitUntilCompleted internally — that drain
                        // serialises behind any pending smudge dispatches
                        // on the same queue.
                        let afterSnapshot = renderer.captureSnapshot(tileGrid: smudgeTileGrid)
                        if let before = beforeSnapshot, let after = afterSnapshot,
                           let canvasState = canvasState {
                            canvasState.historyManager.record(.stroke(
                                layerId: lid,
                                beforeSnapshot: before,
                                afterSnapshot: after
                            ))
                            print("Smudge: recorded stroke undo (before: \(before.totalByteCount)B, after: \(after.totalByteCount)B)")
                        }
                        // Refresh thumbnail off-thread.
                        let smudgeTileGrid: TileGrid? = layers[li].tileGrid
                        DispatchQueue.global(qos: .utility).async { [weak self] in
                            if let thumbnail = renderer.generateThumbnail(fromTileGrid: smudgeTileGrid, size: CGSize(width: 44, height: 44)) {
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
                        canvasState.isTransformingSelection = false
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

                resetShapeToolState()
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
                    resetShapeToolState()
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
                    resetShapeToolState()
                    if let canvasState = canvasState {
                        Task { @MainActor in
                            canvasState.previewLassoPath = nil
                        }
                    }
                    return
                }

                // Simplify the path with Ramer–Douglas–Peucker before
                // closing. Apple Pencil at 240Hz appends every coalesced
                // touch sample during touchesMoved, so a leisurely loop
                // can land 2–5k near-duplicate points in lassoPath. Every
                // downstream consumer (point-in-polygon hit tests, the
                // CanvasRenderer mask rasteriser, the SwiftUI marching-
                // ants Path) walks the polygon linearly per use, so the
                // un-simplified shape blows the finalize budget and the
                // animated-stroke per-frame budget alike. RDP with a
                // ~1 doc-unit tolerance preserves the visible silhouette
                // (the eye can't see sub-pixel polygon detail) while
                // typically cutting the point count by 10–50×. Selection
                // semantics are untouched: the polygon is still a closed
                // ring in doc space.
                let preSimplifyCount = lassoPath.count
                lassoPath = simplifyPathRDP(lassoPath, epsilon: 1.0)
                print("Lasso: simplified \(preSimplifyCount) → \(lassoPath.count) points")

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
                resetShapeToolState()
                return
            }

            guard let stroke = currentStroke else {
                print("ERROR: No current stroke to commit")
                return
            }

            print("Committing stroke with \(stroke.points.count) points")

            // Ensure textures are initialized before committing
            ensureLayerTextures()

            // Tier-1.5 eraser real-time commit fast path — OLD path.
            // Skipped when wetInkActive is true (the wet-ink eraser
            // commit branch below handles it). Retained as fallback for
            // the rare case beginWetInkStroke failed in touchesBegan.
            if !wetInkActive, stroke.tool == .eraser {
                guard selectedLayerIndex < layers.count,
                      let capturedTileGrid = layers[selectedLayerIndex].tileGrid,
                      let renderer = renderer else {
                    currentStroke = nil
                    lastPoint = nil
                    resetShapeToolState()
                    eraserBeforeSnapshot = nil
                    eraserCommittedPointCount = 0
                    renderer?.endPreviewMask()
                    return
                }
                let beforeSnapshot = eraserBeforeSnapshot
                let layerId = stroke.layerId
                let currentLayerIndex = selectedLayerIndex
                let capturedCanvasState = canvasState
                #if DEBUG
                CanvasStrokeDiagnostics.log("eraser commit begin stroke=\(CanvasStrokeDiagnostics.shortID(stroke.id)) \(CanvasStrokeDiagnostics.ranges(for: stroke.points)) strokeSettingsAtBegin{\(CanvasStrokeDiagnostics.format(stroke.settings))} slidersAtCommit{\(CanvasStrokeDiagnostics.format(brushSettings))}")
                #endif
                flushEraserSubStroke(view: view) { [weak self] in
                    let afterSnapshot = renderer.captureSnapshot(tileGrid: capturedTileGrid)
                    if let before = beforeSnapshot,
                       let after = afterSnapshot,
                       let cs = capturedCanvasState {
                        cs.historyManager.record(.stroke(
                            layerId: layerId,
                            beforeSnapshot: before,
                            afterSnapshot: after
                        ))
                        print("Recorded eraser stroke in history (before: \(before.totalByteCount) bytes, after: \(after.totalByteCount) bytes)")
                    }
                    DispatchQueue.global(qos: .utility).async {
                        if let thumbnail = renderer.generateThumbnail(fromTileGrid: capturedTileGrid, size: CGSize(width: 44, height: 44)) {
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
                resetShapeToolState()
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

            // Real-time blur stroke finalisation: stamps were already
            // deposited during touchesMoved via the renderer's blur
            // session, so all that's left is to drain the GPU queue,
            // capture the AFTER snapshot, record HistoryAction.stroke
            // using the BEFORE snapshot we took at touchesBegan, and
            // refresh the layer thumbnail. This branch returns early
            // and skips the deferred dispatchStroke path below.
            if blurStrokeActive,
               stroke.tool == .blur,
               layer.tileGrid != nil,
               let renderer = renderer {
                flushBlurSubStroke()  // final tail of points
                let beforeSnapshot = blurStrokeBeforeSnapshot
                let strokeLayerIndex = blurStrokeLayerIndex ?? selectedLayerIndex
                let strokeLayerId = blurStrokeLayerId ?? layer.id
                guard let capturedTileGrid = layers[strokeLayerIndex].tileGrid else { return }
                let capturedCanvasState = canvasState
                blurStrokeActive = false
                blurStrokeBeforeSnapshot = nil
                blurStrokeLayerIndex = nil
                blurStrokeLayerId = nil
                blurCommittedPointCount = 0

                renderer.endBlurStroke { [weak self] in
                    let afterSnapshot = renderer.captureSnapshot(tileGrid: capturedTileGrid)
                    if let before = beforeSnapshot,
                       let after = afterSnapshot,
                       let cs = capturedCanvasState {
                        cs.historyManager.record(.stroke(
                            layerId: strokeLayerId,
                            beforeSnapshot: before,
                            afterSnapshot: after
                        ))
                    }
                    DispatchQueue.global(qos: .utility).async {
                        if let thumbnail = renderer.generateThumbnail(fromTileGrid: capturedTileGrid, size: CGSize(width: 44, height: 44)) {
                            DispatchQueue.main.async {
                                guard let self = self,
                                      strokeLayerIndex < self.layers.count else { return }
                                self.layers[strokeLayerIndex].updateThumbnail(thumbnail)
                            }
                        }
                    }
                }

                currentStroke = nil
                lastPoint = nil
                resetShapeToolState()
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

            // Wet-ink real-time finalisation (Phase D-integration onward).
            // Routes .brush AND .eraser. Stamps were deposited into
            // strokeScratch during touchesMoved; touchesEnded runs the
            // commit pass (scratch → atlas via the tool's commit blend:
            // premul-over for brush, dest-out for eraser → blit-back
            // into tile grid) and uses the completion to capture the
            // AFTER snapshot for undo. Skips the deferred dispatchStroke
            // path below.
            if wetInkActive,
               isWetInkTool(stroke.tool),
               layer.tileGrid != nil,
               let renderer = renderer {
                flushWetInkSession()  // tail flush of any straggler points
                let beforeSnapshot = wetInkBeforeSnapshot
                let strokeLayerIndex = wetInkLayerIndex ?? selectedLayerIndex
                let strokeLayerId = wetInkLayerId ?? layer.id
                guard let capturedTileGrid = layers[strokeLayerIndex].tileGrid else {
                    wetInkActive = false
                    wetInkBeforeSnapshot = nil
                    wetInkLayerIndex = nil
                    wetInkLayerId = nil
                    wetInkCommittedPointCount = 0
                    renderer.cancelWetInkStroke()
                    return
                }
                let capturedCanvasState = canvasState
                wetInkActive = false
                wetInkBeforeSnapshot = nil
                wetInkLayerIndex = nil
                wetInkLayerId = nil
                wetInkCommittedPointCount = 0

                renderer.commitWetInkStroke { [weak self] in
                    let afterSnapshot = renderer.captureSnapshot(tileGrid: capturedTileGrid)
                    if let before = beforeSnapshot,
                       let after = afterSnapshot,
                       let cs = capturedCanvasState {
                        cs.historyManager.record(.stroke(
                            layerId: strokeLayerId,
                            beforeSnapshot: before,
                            afterSnapshot: after
                        ))
                    }
                    // Mark drawing dirty so the 30s autosave timer picks
                    // up the change. Mirrors the bumpLayerMutation that
                    // the OLD dispatchStroke path runs below.
                    if let canvasState = capturedCanvasState {
                        DispatchQueue.main.async {
                            canvasState.bumpLayerMutation()
                        }
                    }
                    DispatchQueue.global(qos: .utility).async {
                        if let thumbnail = renderer.generateThumbnail(fromTileGrid: capturedTileGrid, size: CGSize(width: 44, height: 44)) {
                            DispatchQueue.main.async {
                                guard let self = self,
                                      strokeLayerIndex < self.layers.count else { return }
                                self.layers[strokeLayerIndex].updateThumbnail(thumbnail)
                            }
                        }
                    }
                }

                currentStroke = nil
                lastPoint = nil
                resetShapeToolState()
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

            if let tileGrid = layer.tileGrid, let renderer = renderer {
                // Stroke points are in document space which matches canvas space
                // IMPORTANT: Pass document size to ensure 1:1 coordinate mapping
                let documentSize = MainActor.assumeIsolated { canvasState?.documentSize ?? view.bounds.size }
                print("✏️ Drawing to Layer \(selectedLayerIndex) '\(layer.name)'")
                print("  Document size: \(documentSize.width)x\(documentSize.height)")

                // Capture snapshot BEFORE rendering stroke
                print("Capturing BEFORE snapshot...")
                let beforeSnapshot = renderer.captureSnapshot(tileGrid: tileGrid)
                if beforeSnapshot == nil {
                    print("WARNING: Failed to capture before snapshot")
                }

                let currentLayerIndex = selectedLayerIndex
                let layerId = layer.id
                let capturedTileGrid: TileGrid = tileGrid
                let capturedCanvasState = canvasState

                // Async stroke commit: GPU pass runs without blocking the main
                // thread on `waitUntilCompleted`. The completion fires on main
                // once the GPU is done — that's the safe point to take the
                // AFTER snapshot, record undo, and kick off the thumbnail.
                // PR 3: pass the active selection path so the GPU clips the
                // stroke. nil = no selection = no clipping.
                let strokeSelectionPath = MainActor.assumeIsolated { canvasState?.selectionPath }
                #if DEBUG
                CanvasStrokeDiagnostics.log("stroke commit begin stroke=\(CanvasStrokeDiagnostics.shortID(stroke.id)) tool=\(stroke.tool) \(CanvasStrokeDiagnostics.ranges(for: stroke.points)) strokeSettingsAtBegin{\(CanvasStrokeDiagnostics.format(stroke.settings))} slidersAtCommit{\(CanvasStrokeDiagnostics.format(brushSettings))}")
                #endif
                let dispatchStroke: (@escaping () -> Void) -> Void = { completion in
                    if stroke.tool == .blur {
                        renderer.renderBlurStroke(stroke, tileGrid: tileGrid, screenSize: documentSize, selectionPath: strokeSelectionPath, completion: completion)
                    } else {
                        renderer.renderStroke(stroke, tileGrid: tileGrid, screenSize: documentSize, selectionPath: strokeSelectionPath, completion: completion)
                    }
                }
                dispatchStroke { [weak self] in
                    print("Stroke committed successfully - texture should now contain the stroke")

                    print("Capturing AFTER snapshot...")
                    let afterSnapshot = renderer.captureSnapshot(tileGrid: capturedTileGrid)
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
                        print("Recorded stroke in history (before: \(before.totalByteCount) bytes, after: \(after.totalByteCount) bytes)")
                    }

                    // Mark the drawing dirty for auto-save. Stroke commit
                    // is the most common edit event by far; this single
                    // bump is what makes the 30s auto-save timer actually
                    // pick up brush / eraser / shape / line / blur / smudge
                    // changes — they all funnel through dispatchStroke.
                    // Bump on main since `bumpLayerMutation` writes a
                    // @Published property.
                    if let canvasState = capturedCanvasState {
                        DispatchQueue.main.async {
                            canvasState.bumpLayerMutation()
                        }
                    }

                    DispatchQueue.global(qos: .utility).async {
                        if let thumbnail = renderer.generateThumbnail(fromTileGrid: capturedTileGrid, size: CGSize(width: 44, height: 44)) {
                            DispatchQueue.main.async {
                                self?.layers[currentLayerIndex].updateThumbnail(thumbnail)
                            }
                        }
                    }
                }
            } else {
                print("ERROR: Could not render stroke")
                print("  - Tile grid exists: \(layer.tileGrid != nil)")
                print("  - Renderer exists: \(renderer != nil)")
            }

            // Clear current stroke so preview stops rendering
            currentStroke = nil
            lastPoint = nil
            resetShapeToolState()
            marqueeStartScreen = nil
            // Free the cached preview selection mask. The committed stroke
            // dispatched above rasterises its own mask internally.
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
            view.setNeedsDisplay()
        }

        func touchesCancelled(_ touches: Set<UITouch>, in view: MTKView, with event: UIEvent?) {
            // Tier-1.5 eraser OLD path: the layer texture was mutated
            // mid-stroke, so a system-cancel needs to roll the layer back
            // to its pre-stroke state. Skipped when wetInkActive is true
            // (the wet-ink eraser path defers all layer mutation to
            // touchesEnded; the wet-ink cleanup block below handles the
            // cancel and clears scratch on next begin).
            if !wetInkActive,
               currentTool == .eraser,
               let beforeSnapshot = eraserBeforeSnapshot,
               selectedLayerIndex < layers.count,
               let tileGrid = layers[selectedLayerIndex].tileGrid,
               let renderer = renderer {
                renderer.restoreSnapshot(beforeSnapshot, tileGrid: tileGrid)
                print("Eraser cancelled — restored layer to pre-stroke snapshot")
            }
            eraserBeforeSnapshot = nil
            eraserCommittedPointCount = 0

            // Real-time blur stroke: same rollback semantics as eraser.
            // Stamps were deposited mid-stroke, so a system-cancel must
            // restore the pre-stroke layer. The renderer session's
            // scratch textures get released via cancelBlurStroke (no
            // finalisation buffer).
            if blurStrokeActive,
               let beforeSnapshot = blurStrokeBeforeSnapshot,
               let li = blurStrokeLayerIndex, li < layers.count,
               let tileGrid = layers[li].tileGrid,
               let renderer = renderer {
                renderer.restoreSnapshot(beforeSnapshot, tileGrid: tileGrid)
                renderer.cancelBlurStroke()
                print("Blur cancelled — restored layer to pre-stroke snapshot")
            }
            blurStrokeActive = false
            blurStrokeBeforeSnapshot = nil
            blurStrokeLayerIndex = nil
            blurStrokeLayerId = nil
            blurCommittedPointCount = 0

            // Wet-ink brush cancellation. Restore the before-snapshot if
            // any tiles were mutated by a partial commit (none should be,
            // since commit only runs at touchesEnded, but defensively
            // restore anyway). Scratch stays dirty until next begin.
            if wetInkActive,
               let beforeSnapshot = wetInkBeforeSnapshot,
               let li = wetInkLayerIndex, li < layers.count,
               let tileGrid = layers[li].tileGrid,
               let renderer = renderer {
                renderer.restoreSnapshot(beforeSnapshot, tileGrid: tileGrid)
                renderer.cancelWetInkStroke()
                print("Wet-ink brush cancelled — restored layer to pre-stroke snapshot")
            } else if let renderer = renderer {
                renderer.cancelWetInkStroke()
            }
            wetInkActive = false
            wetInkBeforeSnapshot = nil
            wetInkLayerIndex = nil
            wetInkLayerId = nil
            wetInkCommittedPointCount = 0

            currentStroke = nil
            lastPoint = nil
            resetShapeToolState()
            marqueeStartScreen = nil
            lassoPath = []
            isDraggingSelection = false
            selectionDragStart = nil
            blurAdjustmentTouchStartScreen = nil
            blurAdjustmentLastUpdateAt = 0
            // Drop any pending paint-bucket fill — touchesCancelled fires
            // when a pinch/pan/rotation gesture claims the touches, which
            // is exactly the case the gate is built to suppress.
            pendingPaintBucketFill = nil
            isStrokeInProgress = false
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
                smudgeStrokeID = nil
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
                    // Cancellation always exits any in-flight transform —
                    // ants should reappear on the (still-active) selection.
                    canvasState.isTransformingSelection = false
                }
            }
            view.setNeedsDisplay()
        }

        // MARK: - Back-canvas references

        /// Render each back-canvas reference via the renderer's
        /// reference-quad pass. Manages the texture cache (load on first
        /// sight, drop when removed, reload when isolation state flips).
        /// Sorted by zOrder so layered references composite correctly.
        private func renderBackCanvasReferences(view: MTKView, encoder: MTLRenderCommandEncoder) {
            guard !backCanvasReferences.isEmpty, let renderer = renderer else { return }

            syncReferenceTextureCache()

            let drawableSize = view.drawableSize
            let scale = Float(view.contentScaleFactor)
            let viewport = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))

            // Snapshot canvas transform once per frame for follow-mode refs.
            let canvasZoom: CGFloat
            let canvasRotationRad: CGFloat
            if let cs = canvasState {
                (canvasZoom, canvasRotationRad) = MainActor.assumeIsolated {
                    (cs.zoomScale, cs.canvasRotation.radians)
                }
            } else {
                (canvasZoom, canvasRotationRad) = (1.0, 0.0)
            }

            for ref in backCanvasReferences.sorted(by: { $0.zOrder < $1.zOrder }) {
                guard let texture = referenceTextureCache[ref.id] else { continue }

                // Resolve effective screen-space center, scale, rotation.
                // Follow mode: reference.center is doc-space; transform
                // it via canvasState.documentToScreen (this applies
                // canvas pan/zoom/rotation in one shot). Apparent size
                // scales with canvas zoom. Apparent rotation = canvas
                // rotation.
                let screenCenter: CGPoint
                let displayedScale: CGFloat
                let rotationRad: CGFloat
                if ref.followsCanvas, let cs = canvasState {
                    screenCenter = MainActor.assumeIsolated { cs.documentToScreen(ref.center) }
                    displayedScale = ref.scale * canvasZoom
                    rotationRad = canvasRotationRad
                } else {
                    screenCenter = ref.center
                    displayedScale = ref.scale
                    rotationRad = 0
                }

                let displayedPointWidth = Float(ref.image.size.width * displayedScale)
                let displayedPointHeight = Float(ref.image.size.height * displayedScale)

                renderer.renderReferenceBehindLayers(
                    texture,
                    center: SIMD2<Float>(
                        Float(screenCenter.x) * scale,
                        Float(screenCenter.y) * scale,
                    ),
                    displayedSize: SIMD2<Float>(
                        displayedPointWidth * scale,
                        displayedPointHeight * scale,
                    ),
                    viewportSize: viewport,
                    opacity: Float(ref.opacity),
                    flipX: ref.isFlipped,
                    flipY: ref.isFlippedY,
                    rotation: Float(rotationRad),
                    to: encoder,
                )
            }
        }

        /// Maintain `referenceTextureCache` against the current list:
        /// upload textures for newly-seen ids, drop entries for ids that
        /// have disappeared, reload when the isolation flag flipped.
        private func syncReferenceTextureCache() {
            let currentIDs = Set(backCanvasReferences.map(\.id))
            for id in referenceTextureCache.keys where !currentIDs.contains(id) {
                referenceTextureCache.removeValue(forKey: id)
                referenceTextureCacheKey.removeValue(forKey: id)
            }

            guard let device = metalView?.device else { return }
            let loader = MTKTextureLoader(device: device)

            for ref in backCanvasReferences {
                let needsReload = referenceTextureCacheKey[ref.id] != ref.isIsolated
                if referenceTextureCache[ref.id] == nil || needsReload {
                    let source = (ref.isIsolated ? ref.isolatedImage : ref.image) ?? ref.image
                    guard let cgImage = source.cgImage else { continue }
                    if let texture = try? loader.newTexture(
                        cgImage: cgImage,
                        options: [
                            .SRGB: NSNumber(value: true),
                            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                        ],
                    ) {
                        referenceTextureCache[ref.id] = texture
                        referenceTextureCacheKey[ref.id] = ref.isIsolated
                    }
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
                        pressureAlpha: p.pressureAlpha,
                        inputType: p.inputType,
                        rawTouchForce: p.rawTouchForce,
                        rawTouchMaxForce: p.rawTouchMaxForce,
                        timestamp: p.timestamp
                    ))
                }
            }
            if config.xAxis {
                for p in points {
                    result.append(BrushStroke.StrokePoint(
                        location: CGPoint(x: p.location.x, y: H - p.location.y),
                        pressure: p.pressure,
                        pressureAlpha: p.pressureAlpha,
                        inputType: p.inputType,
                        rawTouchForce: p.rawTouchForce,
                        rawTouchMaxForce: p.rawTouchMaxForce,
                        timestamp: p.timestamp
                    ))
                }
            }
            if config.yAxis && config.xAxis {
                for p in points {
                    result.append(BrushStroke.StrokePoint(
                        location: CGPoint(x: W - p.location.x, y: H - p.location.y),
                        pressure: p.pressure,
                        pressureAlpha: p.pressureAlpha,
                        inputType: p.inputType,
                        rawTouchForce: p.rawTouchForce,
                        rawTouchMaxForce: p.rawTouchMaxForce,
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
                        pressureAlpha: p.pressureAlpha,
                        inputType: p.inputType,
                        rawTouchForce: p.rawTouchForce,
                        rawTouchMaxForce: p.rawTouchMaxForce,
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
            case .brush, .eraser, .blur,
                 .pencil, .inkPen, .marker, .airbrush, .charcoal:
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
                pressureAlpha: snapLatestPressureAlpha,
                inputType: snapLatestInputType,
                rawTouchForce: snapLatestRawTouchForce,
                rawTouchMaxForce: snapLatestRawTouchMaxForce,
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

        /// Clear all shape-tool transient state. Called from every
        /// shape-stroke termination site (commit, cancel, selection-drag
        /// branches that double as bail-outs). Centralised so adding new
        /// per-stroke state — the perfect-shape constraint touches landed
        /// alongside — only needs to be nilled out in one place.
        private func resetShapeToolState() {
            shapeStartPoint = nil
            shapeStartScreen = nil
            shapeStartPressure = nil
            shapeStartPressureAlpha = nil
            shapeStartInputType = nil
            shapeStartRawTouchForce = nil
            shapeStartRawTouchMaxForce = nil
            shapePrimaryTouchID = nil
            shapeConstraintTouchIDs.removeAll()
        }

        /// Generate points for shape tools (line, rectangle, circle).
        /// When `constrainPerfect` is true, the end point is snapped to
        /// produce a square (rectangle), circle (ellipse), or 45°-snapped
        /// line — driven by the two-finger constraint gesture.
        private func generateShapePoints(
            from start: CGPoint,
            to end: CGPoint,
            tool: DrawingTool,
            pressure: CGFloat,
            pressureAlpha: CGFloat,
            inputType: BrushStroke.InputType,
            rawTouchForce: CGFloat,
            rawTouchMaxForce: CGFloat,
            timestamp: TimeInterval,
            constrainPerfect: Bool = false
        ) -> [BrushStroke.StrokePoint] {
            let constrainedEnd = constrainPerfect
                ? perfectShapeEnd(from: start, to: end, tool: tool)
                : end
            switch tool {
            case .line:
                return generateLinePoints(from: start, to: constrainedEnd, pressure: pressure, pressureAlpha: pressureAlpha, inputType: inputType, rawTouchForce: rawTouchForce, rawTouchMaxForce: rawTouchMaxForce, timestamp: timestamp)
            case .rectangle:
                return generateRectanglePoints(from: start, to: constrainedEnd, pressure: pressure, pressureAlpha: pressureAlpha, inputType: inputType, rawTouchForce: rawTouchForce, rawTouchMaxForce: rawTouchMaxForce, timestamp: timestamp)
            case .circle:
                return generateCirclePoints(from: start, to: constrainedEnd, pressure: pressure, pressureAlpha: pressureAlpha, inputType: inputType, rawTouchForce: rawTouchForce, rawTouchMaxForce: rawTouchMaxForce, timestamp: timestamp)
            default:
                return []
            }
        }

        /// Snap an end-point so the resulting shape is a perfect square /
        /// circle / 45°-snapped line. Preserves the directional sign of the
        /// drag so the shape grows in the quadrant the user pulled toward.
        private func perfectShapeEnd(from start: CGPoint, to end: CGPoint, tool: DrawingTool) -> CGPoint {
            let dx = end.x - start.x
            let dy = end.y - start.y
            switch tool {
            case .rectangle, .circle:
                // Square / circle: use the larger axis as the side length
                // so the shape grows past the finger, not under it (matches
                // Photos / Procreate convention).
                let side = max(abs(dx), abs(dy))
                let sx: CGFloat = dx >= 0 ? 1 : -1
                let sy: CGFloat = dy >= 0 ? 1 : -1
                return CGPoint(x: start.x + sx * side, y: start.y + sy * side)
            case .line:
                // 45° snap: round the drag's angle to the nearest 45° and
                // keep the drag length. atan2 handles the (0,0) edge case
                // by returning 0, which collapses to a degenerate point —
                // generateLinePoints already guards against that.
                let length = hypot(dx, dy)
                guard length > 0 else { return end }
                let step = CGFloat.pi / 4
                let snapped = (atan2(dy, dx) / step).rounded() * step
                return CGPoint(x: start.x + cos(snapped) * length,
                               y: start.y + sin(snapped) * length)
            default:
                return end
            }
        }

        private func generateLinePoints(
            from start: CGPoint,
            to end: CGPoint,
            pressure: CGFloat,
            pressureAlpha: CGFloat,
            inputType: BrushStroke.InputType,
            rawTouchForce: CGFloat,
            rawTouchMaxForce: CGFloat,
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
                    pressureAlpha: pressureAlpha,
                    inputType: inputType,
                    rawTouchForce: rawTouchForce,
                    rawTouchMaxForce: rawTouchMaxForce,
                    timestamp: timestamp
                ))
            }
            return points
        }

        private func generateRectanglePoints(
            from start: CGPoint,
            to end: CGPoint,
            pressure: CGFloat,
            pressureAlpha: CGFloat,
            inputType: BrushStroke.InputType,
            rawTouchForce: CGFloat,
            rawTouchMaxForce: CGFloat,
            timestamp: TimeInterval
        ) -> [BrushStroke.StrokePoint] {
            let spacing = brushSettings.size * brushSettings.spacing
            var points: [BrushStroke.StrokePoint] = []

            // Top edge (start to top-right)
            let topRight = CGPoint(x: end.x, y: start.y)
            points.append(contentsOf: generateLineSegment(from: start, to: topRight, spacing: spacing, pressure: pressure, pressureAlpha: pressureAlpha, inputType: inputType, rawTouchForce: rawTouchForce, rawTouchMaxForce: rawTouchMaxForce, timestamp: timestamp))

            // Right edge (top-right to end)
            points.append(contentsOf: generateLineSegment(from: topRight, to: end, spacing: spacing, pressure: pressure, pressureAlpha: pressureAlpha, inputType: inputType, rawTouchForce: rawTouchForce, rawTouchMaxForce: rawTouchMaxForce, timestamp: timestamp))

            // Bottom edge (end to bottom-left)
            let bottomLeft = CGPoint(x: start.x, y: end.y)
            points.append(contentsOf: generateLineSegment(from: end, to: bottomLeft, spacing: spacing, pressure: pressure, pressureAlpha: pressureAlpha, inputType: inputType, rawTouchForce: rawTouchForce, rawTouchMaxForce: rawTouchMaxForce, timestamp: timestamp))

            // Left edge (bottom-left back to start)
            points.append(contentsOf: generateLineSegment(from: bottomLeft, to: start, spacing: spacing, pressure: pressure, pressureAlpha: pressureAlpha, inputType: inputType, rawTouchForce: rawTouchForce, rawTouchMaxForce: rawTouchMaxForce, timestamp: timestamp))

            return points
        }

        private func generateCirclePoints(
            from start: CGPoint,
            to end: CGPoint,
            pressure: CGFloat,
            pressureAlpha: CGFloat,
            inputType: BrushStroke.InputType,
            rawTouchForce: CGFloat,
            rawTouchMaxForce: CGFloat,
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
                    pressureAlpha: pressureAlpha,
                    inputType: inputType,
                    rawTouchForce: rawTouchForce,
                    rawTouchMaxForce: rawTouchMaxForce,
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
            pressureAlpha: CGFloat,
            inputType: BrushStroke.InputType,
            rawTouchForce: CGFloat,
            rawTouchMaxForce: CGFloat,
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
                    pressureAlpha: pressureAlpha,
                    inputType: inputType,
                    rawTouchForce: rawTouchForce,
                    rawTouchMaxForce: rawTouchMaxForce,
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

        /// Point-in-polygon test using ray casting algorithm. Bbox-
        /// gated so out-of-bounds points skip the ray-cast entirely —
        /// the bbox loop is the same O(n) walk as the polygon test
        /// but with branch-light comparisons, so the early-out pays
        /// for itself the moment a single coordinate falls outside.
        private func pointInPolygon(point: CGPoint, polygon: [CGPoint]) -> Bool {
            guard polygon.count >= 3 else { return false }

            // Bounding-box pre-check. We don't cache the bbox here
            // because pointInPolygon is called once per touchesBegan,
            // not in a hot loop — the linear pass is cheap and avoids
            // a second source of truth. If a future call site iterates,
            // hoist this into a stored bbox alongside selectionPath.
            var minX = polygon[0].x, maxX = polygon[0].x
            var minY = polygon[0].y, maxY = polygon[0].y
            for i in 1..<polygon.count {
                let p = polygon[i]
                if p.x < minX { minX = p.x } else if p.x > maxX { maxX = p.x }
                if p.y < minY { minY = p.y } else if p.y > maxY { maxY = p.y }
            }
            if point.x < minX || point.x > maxX || point.y < minY || point.y > maxY {
                return false
            }

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

        /// Ramer–Douglas–Peucker path simplification. Drops near-collinear
        /// points whose perpendicular distance to the chord between two
        /// kept neighbors is below `epsilon`. Iterative-with-explicit-stack
        /// so a degenerate spiral can't blow the recursion limit on a
        /// 5k-point Pencil-coalesced sample. Preserves first and last
        /// points (essential — caller relies on path[0] for the close).
        private func simplifyPathRDP(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
            guard pts.count > 2 else { return pts }
            let epsSq = epsilon * epsilon
            var keep = [Bool](repeating: false, count: pts.count)
            keep[0] = true
            keep[pts.count - 1] = true

            // Explicit stack of (start, end) index pairs to process.
            var stack: [(Int, Int)] = [(0, pts.count - 1)]
            while let (start, end) = stack.popLast() {
                if end <= start + 1 { continue }
                let a = pts[start], b = pts[end]
                let dx = b.x - a.x, dy = b.y - a.y
                let lenSq = dx * dx + dy * dy
                var maxDistSq: CGFloat = 0
                var maxIndex = start
                for i in (start + 1)..<end {
                    let p = pts[i]
                    let distSq: CGFloat
                    if lenSq == 0 {
                        let ex = p.x - a.x, ey = p.y - a.y
                        distSq = ex * ex + ey * ey
                    } else {
                        // |cross(b-a, p-a)|² / |b-a|² = perp-dist²
                        let cross = dx * (a.y - p.y) - dy * (a.x - p.x)
                        distSq = cross * cross / lenSq
                    }
                    if distSq > maxDistSq {
                        maxDistSq = distSq
                        maxIndex = i
                    }
                }
                if maxDistSq > epsSq {
                    keep[maxIndex] = true
                    stack.append((start, maxIndex))
                    stack.append((maxIndex, end))
                }
            }

            var out: [CGPoint] = []
            out.reserveCapacity(pts.count)
            for i in 0..<pts.count where keep[i] {
                out.append(pts[i])
            }
            return out
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

        /// Apple Pencil hover (iPadOS 16.1+, iPad Pro M2+ / Pencil 2/Pro).
        /// UIHoverGestureRecognizer is inert on hardware without hover
        /// support — this method simply never fires on unsupported
        /// devices. Trackpad/mouse hover on iPad with a Magic Keyboard
        /// or pointer device also fires this; the cursor still reads
        /// as useful in those cases.
        ///
        /// Two coordinate / state corrections vs. the original wiring:
        ///   1. Suppress while a stroke is in flight. UIHoverGestureRecognizer
        ///      keeps firing for a trackpad pointer even while the user is
        ///      drawing with a finger, which left a ghost cursor floating
        ///      mid-stroke. `isStrokeInProgress` is set/cleared from the
        ///      touch handlers; while set, every hover event is force-nil'd.
        ///   2. Round-trip through screenToDocument / documentToScreen so
        ///      the cursor lands at the same visual screen point the
        ///      brush shader will commit a stroke to. Strokes get sampled
        ///      in screen space, projected into doc space, and rendered
        ///      back through the canvas transform — the doc round-trip
        ///      normalises any difference between the raw MTKView point
        ///      and the canvas-aligned screen pipeline.
        @objc func handleHover(_ gesture: UIHoverGestureRecognizer) {
            let view = gesture.view
            let rawPoint = gesture.location(in: view)
            switch gesture.state {
            case .began, .changed:
                if isStrokeInProgress {
                    // Hover events arriving mid-stroke would re-light a
                    // stale cursor over the canvas. Drop them on the
                    // floor; touchesEnded re-enables hover by clearing
                    // the flag.
                    onHoverChange?(nil)
                    return
                }
                let aligned: CGPoint
                if let canvasState = canvasState {
                    aligned = MainActor.assumeIsolated {
                        let doc = canvasState.screenToDocument(rawPoint)
                        return canvasState.documentToScreen(doc)
                    }
                } else {
                    aligned = rawPoint
                }
                onHoverChange?(aligned)
            case .ended, .cancelled, .failed:
                onHoverChange?(nil)
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
