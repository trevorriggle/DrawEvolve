//
//  CanvasRenderer.swift
//  DrawEvolve
//
//  Metal-based rendering engine for drawing canvas.
//

import Foundation
import Metal
import MetalKit
import UIKit
import CoreText

#if DEBUG
enum CanvasStrokeDiagnostics {
    /// Per-stamp / per-frame diagnostic firehose. Burns hundreds of
    /// stderr writes per stroke on a fast scribble — was nominally
    /// "DEBUG-only" but the flag was hardcoded to true, so release
    /// builds paid the cost too. Now defaults to `false` in release
    /// and `true` in debug; the static var stays settable so a debug
    /// build can still toggle it from a breakpoint.
    #if DEBUG
    static var isEnabled = true
    #else
    static var isEnabled = false
    #endif

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        dbgLog("🧪 CANVAS \(message())")
    }

    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    static func format(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    static func format(_ value: Float) -> String {
        String(format: "%.3f", Double(value))
    }

    static func format(_ value: SIMD4<Float>) -> String {
        "(\(format(value.x)), \(format(value.y)), \(format(value.z)), \(format(value.w)))"
    }

    static func format(_ point: CGPoint) -> String {
        "(\(format(point.x)), \(format(point.y)))"
    }

    static func format(_ rect: CGRect) -> String {
        if rect.isNull { return "null" }
        return "x=\(format(rect.origin.x)) y=\(format(rect.origin.y)) w=\(format(rect.width)) h=\(format(rect.height))"
    }

    static func format(_ color: UIColor) -> String {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return "rgba=(\(format(r)), \(format(g)), \(format(b)), \(format(a)))"
        }
        return "rgba=<unresolved>"
    }

    static func format(_ settings: BrushSettings) -> String {
        "size=\(format(settings.size)) opacity=\(format(settings.opacity)) hardness=\(format(settings.hardness)) spacing=\(format(settings.spacing)) grain=\(format(settings.grainDensity)) pressureSens=\(settings.pressureSensitivity) \(format(settings.color))"
    }

    static func ranges(for points: [BrushStroke.StrokePoint]) -> String {
        guard let first = points.first else {
            return "points=0 pressure=n/a pressureAlpha=n/a"
        }
        var minPressure = first.pressure
        var maxPressure = first.pressure
        var minPressureAlpha = first.pressureAlpha
        var maxPressureAlpha = first.pressureAlpha
        for point in points.dropFirst() {
            minPressure = min(minPressure, point.pressure)
            maxPressure = max(maxPressure, point.pressure)
            minPressureAlpha = min(minPressureAlpha, point.pressureAlpha)
            maxPressureAlpha = max(maxPressureAlpha, point.pressureAlpha)
        }
        return "points=\(points.count) pressure=\(format(minPressure))...\(format(maxPressure)) pressureAlpha=\(format(minPressureAlpha))...\(format(maxPressureAlpha))"
    }

    static func stampSource(_ point: BrushStroke.StrokePoint) -> String {
        "input=\(point.inputType.diagnosticName) loc=\(format(point.location)) sourcePressure=\(format(point.pressure)) sourcePressureAlpha=\(format(point.pressureAlpha)) rawForce=\(format(point.rawTouchForce)) rawMaxForce=\(format(point.rawTouchMaxForce))"
    }

    static func uniforms(size: Float, opacity: Float, hardness: Float, pressure: Float, pressureAlpha: Float, color: SIMD4<Float>) -> String {
        "size=\(format(size)) opacity=\(format(opacity)) hardness=\(format(hardness)) pressure=\(format(pressure)) pressureAlpha=\(format(pressureAlpha)) color=\(format(color))"
    }

    static func stampBoundingBox(points: [BrushStroke.StrokePoint], brushSize: CGFloat) -> CGRect {
        guard let first = points.first else { return .null }
        let radius = max(1, brushSize * 0.5)
        var rect = CGRect(
            x: first.location.x - radius,
            y: first.location.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        for point in points.dropFirst() {
            rect = rect.union(CGRect(
                x: point.location.x - radius,
                y: point.location.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
        return rect
    }

    static func tileSummary(_ keys: [TileKey], limit: Int = 24) -> String {
        let sorted = keys.sorted {
            if $0.y == $1.y { return $0.x < $1.x }
            return $0.y < $1.y
        }
        let shown = sorted.prefix(limit).map { "(\($0.x),\($0.y))" }.joined(separator: " ")
        if sorted.count > limit {
            return "count=\(sorted.count) [\(shown) ...]"
        }
        return "count=\(sorted.count) [\(shown)]"
    }
}
#endif

/// Mirror of `ReferenceQuadUniforms` in Shaders.metal. Field order and
/// alignment match the MSL struct exactly. Total stride 40 bytes:
/// 8*3 (three float2) + 4*4 (four float — opacity, flipX, flipY,
/// rotation) = 24 + 16 = 40. The float2 alignment of 8 forces the
/// struct stride up to a multiple of 8 (40 is already a multiple of 8).
fileprivate struct ReferenceQuadUniforms {
    var center: SIMD2<Float>
    var halfSize: SIMD2<Float>
    var viewportSize: SIMD2<Float>
    var opacity: Float
    var flipX: Float
    var flipY: Float
    var rotation: Float
}

class CanvasRenderer: NSObject {
    let device: MTLDevice // Public for GPU sync
    // Long-lived per-device command queue. Exposed so callers (MTKView delegate)
    // can reuse it instead of allocating a fresh queue per frame — a queue is
    // meant to live for the device's lifetime.
    let commandQueue: MTLCommandQueue

    // Stroke-path command-buffer rate limiter. Metal's command queue caps
    // in-flight buffers at 64 per queue; past that, makeCommandBuffer()
    // returns nil and the touch loop's stamp is silently dropped. Big
    // erases / fast brush sweeps at 240 Hz used to hit the cap and leak
    // stamps. We hold a semaphore at 60 (under the hard cap, leaves a
    // few slots for non-stroke Metal work — composite, blur preview,
    // smudge), wait before makeCommandBuffer, and signal in the
    // completion handler. Block-on-saturation is intentional: brief
    // back-pressure on the touch loop is preferable to silent data loss.
    private let strokeCommandSlots = DispatchSemaphore(value: 60)
    private var brushPipelineState: MTLRenderPipelineState?
    private var eraserPipelineState: MTLRenderPipelineState?
    // Experimental brush variants (experiment/brush-variety-v1). Each is
    // the same brush vertex shader + standard alpha blend as
    // `brushPipelineState`; only the fragment function differs. Selected
    // by `pipelineState(forTool:)`.
    private var pencilPipelineState: MTLRenderPipelineState?
    private var markerPipelineState: MTLRenderPipelineState?
    private var airbrushPipelineState: MTLRenderPipelineState?
    private var charcoalPipelineState: MTLRenderPipelineState?
    private var watercolorPipelineState: MTLRenderPipelineState?
    // Wet-ink premultiplied variants (Phase A.5 onward). Each pairs with a
    // *Premul fragment shader that emits (rgb * finalAlpha, finalAlpha).
    // sourceRGBBlendFactor is .one (not .sourceAlpha) so the blend math
    // matches the OLD shader+pipeline framebuffer pixel-for-pixel; same alpha
    // factors. Phase A.5 proves byte-exact equivalence; Phase B+ uses these
    // for the wet-ink deposit pass.
    private var brushPremulPipelineState: MTLRenderPipelineState?
    private var pencilPremulPipelineState: MTLRenderPipelineState?
    private var markerPremulPipelineState: MTLRenderPipelineState?
    private var airbrushPremulPipelineState: MTLRenderPipelineState?
    private var charcoalPremulPipelineState: MTLRenderPipelineState?
    // Wet-ink deposit pipelines (Phase B onward). Same premul shaders as
    // the *Premul* pipelines above, but blend is .max/.max with source &
    // dest factors both .one — so within-stroke overlapping stamps cap
    // at the strongest single-stamp value at each pixel (and don't
    // accumulate). Phase B wires brush; Phase E extends to the rest.
    private var brushScratchDepositPipelineState: MTLRenderPipelineState?
    // Eraser deposit into scratch — reuses the existing eraserFragmentShader
    // (which already emits `(0, 0, 0, alpha)`) with .max/.max blend.
    // Premul vs non-premul doesn't matter for eraser since RGB stays zero.
    private var eraserScratchDepositPipelineState: MTLRenderPipelineState?
    // Wet-ink deposit pipelines for the additive brush variants (Phase E).
    // Each pairs the variant's premul fragment shader with the standard
    // .max/.max within-stroke deposit blend. Commit step is shared with
    // brush (premul-over via wetInkCommitPipelineState).
    private var pencilScratchDepositPipelineState: MTLRenderPipelineState?
    private var markerScratchDepositPipelineState: MTLRenderPipelineState?
    private var airbrushScratchDepositPipelineState: MTLRenderPipelineState?
    private var charcoalScratchDepositPipelineState: MTLRenderPipelineState?
    private var watercolorScratchDepositPipelineState: MTLRenderPipelineState?
    // Wet-ink commit pipeline (Phase C onward). Reads `strokeScratch` (full-
    // canvas quad), writes to `canvasStagingAtlas` with premul-over blend —
    // standard alpha-over compositing of the pre-baked, premultiplied stroke
    // into the layer. See `wetInkCommitShader` in Shaders.metal.
    private var wetInkCommitPipelineState: MTLRenderPipelineState?
    // Eraser variant of the commit: reads scratch.a, emits (0,0,0,a),
    // pipeline blends dest-out. See `wetInkEraserCommitShader`.
    private var wetInkEraserCommitPipelineState: MTLRenderPipelineState?
    private var compositePipelineState: MTLRenderPipelineState?
    private var textureDisplayPipelineState: MTLRenderPipelineState?
    private var textureDisplayWithTransformPipelineState: MTLRenderPipelineState? // For zoom/pan
    private var floatingTexturePipelineState: MTLRenderPipelineState? // For floating selection drag preview
    /// Pipeline for per-tile composite under the tiling migration (Phase 3).
    /// Vertex shader places a quad at the tile's integer pixel rect within
    /// the output canvas; fragment shader samples the tile with NEAREST
    /// filter. Same alpha-over blend as `textureDisplayPipelineState` so the
    /// per-tile composite is bit-exact with the legacy full-canvas-quad
    /// composite given Phase 2's tile<->mono invariant.
    private var compositeTilePipelineState: MTLRenderPipelineState?
    /// Pipeline for tile-direct-to-drawable rendering (Phase 6 / Tier C 9).
    /// `tileDirectVertexShader` applies the full canvas-to-drawable transform
    /// per-tile; fragment shader samples the tile texture with LINEAR (matching
    /// the legacy display path's textureDisplayShader). Standard alpha-over
    /// blend. Eliminates the per-frame canvas-sized tileDisplayIntermediate
    /// that the legacy compose-then-sample path materializes.
    private var tileDirectToDrawablePipelineState: MTLRenderPipelineState?
    /// Wet-ink commit variant of the tile-direct pipeline. Reuses
    /// `tileDirectVertexShader` for canvas-to-drawable transform but pairs
    /// with `wetInkCommitShader` (which outputs scratch sampled as premul)
    /// and uses premul-over blend (sourceRGB=.one, destRGB=.oneMinusSrcAlpha)
    /// — matches the existing wetInkCommitPipelineState's blend state but
    /// targets the drawable directly. Used during touchesMoved to composite
    /// strokeScratch on top of the active layer's tile-direct content.
    private var wetInkCommitToDrawablePipelineState: MTLRenderPipelineState?
    /// Eraser variant: same vertex shader, `wetInkEraserCommitShader`, dest-out
    /// blend. Mirrors wetInkEraserCommitPipelineState but for direct-to-drawable.
    private var wetInkEraserCommitToDrawablePipelineState: MTLRenderPipelineState?
    /// Pipeline for reference-image quads rendered in screen space BETWEEN
    /// the canvas's white paper and the layer composite. ONLY used by the
    /// to-screen path; the save/AI/export composite (compositeLayersToTexture)
    /// never touches this. References in back-canvas mode are visible on
    /// screen but excluded from the export by construction.
    private var referenceQuadPipelineState: MTLRenderPipelineState?
    // Blur tool family (PR 1) — separable Gaussian + masked variant + stamp deposit.
    // gaussianBlurPipelineState writes its result with no blending (raw replace).
    // gaussianBlurMaskedPipelineState ditto; the mask handling is in the shader.
    // stampBlurDepositPipelineState uses standard sourceAlpha blending.
    private var gaussianBlurPipelineState: MTLRenderPipelineState?
    private var gaussianBlurMaskedPipelineState: MTLRenderPipelineState?
    private var stampBlurDepositPipelineState: MTLRenderPipelineState?
    // Smudge tool (PR 2). patch-update writes raw (no blend) into the back
    // patch texture; deposit uses standard premultiplied source-over into
    // the layer (same blend as the brush-blur deposit).
    private var smudgePatchUpdatePipelineState: MTLRenderPipelineState?
    private var smudgeDepositPipelineState: MTLRenderPipelineState?

    // 1x1 white texture used to draw an opaque canvas background quad
    private var whiteTexture: MTLTexture?

    // Default "no-mask" selection mask (PR 3). 1×1 r8Unorm, value 1.0.
    // Bound to fragment texture slot 2 by every brush/eraser/blur-deposit/
    // smudge dispatch when no selection is active. Lets the shaders' mask
    // multiply be a no-op without per-shader branching, and avoids
    // allocating a canvas-sized mask just to fill it with 1.0 — same idiom
    // as `whiteTexture` for the canvas background quad. Created once in
    // `setupPipeline`; never freed.
    private var noMaskTexture: MTLTexture?

    // Cached selection mask for stroke-PREVIEW rendering (PR 3). Populated
    // once at `touchesBegan` via `beginPreviewMask`, read on every preview
    // frame by `renderStrokePreview`, freed at `touchesEnded` /
    // `touchesCancelled` via `endPreviewMask`. Selection geometry is
    // immutable during an in-flight stroke (canvas owns the touch, toolbar
    // can't fire), so a single rasterise at stroke start is sufficient —
    // no per-frame rasterisation cost. Falls back to `noMaskTexture` when
    // nil. Smudge has its own equivalent cache (`smudgeSelectionMask`)
    // for its dispatch path; smudge does not use `renderStrokePreview`
    // because it renders live to the layer texture.
    private var previewSelectionMask: MTLTexture?

    // MARK: - Blur Adjustment (Procreate-style scrubber) state.
    //
    // Allocated by `beginBlurAdjustment`, populated as the user drags, freed by
    // `endBlurAdjustment` (or rolled-over by `commitBlurAdjustment`). The
    // MetalCanvasView's draw loop swaps `blurPreviewTexture` in for display
    // when `blurAdjustmentLayerId != nil` matches the active layer's id.

    /// Lossless copy of the active layer texture at the moment the adjustment
    /// began. Read-only during preview — every Gaussian pass samples from
    /// here so subsequent slider tweaks don't compound on previous output.
    private var blurAdjustmentSource: MTLTexture?

    /// Output of the masked vertical pass — what the user sees while the tool
    /// is active. Display swap target.
    private var blurAdjustmentPreview: MTLTexture?

    /// Intermediate for the horizontal pass.
    private var blurAdjustmentScratch: MTLTexture?

    /// r8Unorm mask sized to the layer texture. 1.0 inside the selection
    /// (or everywhere when no selection is active), 0.0 elsewhere.
    private var blurAdjustmentMask: MTLTexture?

    /// Layer the preview is bound to. Used by MetalCanvasView to decide
    /// whether to swap in the preview texture for display.
    private var blurAdjustmentLayerId: UUID?

    // MARK: - Smudge tool state (PR 2).
    //
    // Two ping-pong patches that hold the "carried paint" of the active
    // stroke. The pickup pass reads the FRONT patch and writes to the BACK
    // patch; we swap the pointers after each pickup so the deposit (and the
    // next pickup) read the just-written carry.
    //
    // `smudgePatchHalfSize` is the world half-size of the patch in layer
    // pixels (= brushSize / 2 at stroke begin; constant for the stroke).
    // `smudgeStampIndex` counts stamps dispatched since `beginSmudgeStroke`
    // — index 0 is the first-stamp pickup-only special case.
    // `smudgeStrokeLayerId` is the layer the patches are sized for; used by
    // `renderSmudgeStamps` to assert the active layer hasn't changed
    // mid-stroke (textures sized to one layer would smudge incorrectly on
    // another, so the assert is a hard sanity check).
    private var smudgePatchFront: MTLTexture?
    private var smudgePatchBack: MTLTexture?
    private var smudgePatchHalfSize: Float = 0
    private var smudgeStampIndex: Int = 0
    private var smudgeStrokeLayerId: UUID?
    private var smudgeDiagnosticStrokeID: UUID?
    // Selection mask for the active smudge stroke (PR 3). Rasterized once
    // in `beginSmudgeStroke` and reused across every `renderSmudgeStamps`
    // batch — selection geometry is fixed for the duration of a stroke.
    // Bound to fragment texture slot 2 in BOTH the patch-update and the
    // deposit encoders: pickup AND deposit clip (Photoshop-correct).
    // Cleared in `endSmudgeStroke`. Falls back to `noMaskTexture` when
    // the stroke begins with no active selection.
    private var smudgeSelectionMask: MTLTexture?

    // Canvas dimensions - dynamically calculated to be a square larger than screen diagonal
    // This ensures no clipping/distortion when rotating the canvas
    private var _canvasSize: CGSize = CGSize(width: 2048, height: 2048)
    var canvasSize: CGSize {
        get { return _canvasSize }
        set { _canvasSize = newValue }
    }

    /// Once set true by `setCanvasSize(matchingDoc:)`, subsequent
    /// `updateCanvasSize(for:)` calls become no-ops. Existing-document
    /// loads override the device-cap-derived screen sizing because the
    /// loaded doc's saved dimensions are authoritative for that session.
    /// Resolves the SwiftUI ordering race documented in slice 7 § "timing
    /// race I caught" — either order (load-then-firstdraw, or firstdraw-
    /// then-load) reaches the same end state.
    ///
    /// Stays true for the renderer's lifetime; each new DrawingCanvasView
    /// spawns a fresh renderer (via MetalCanvasView UIViewRepresentable),
    /// which starts with the flag false. "Clear Canvas" within an
    /// existing-doc session deliberately does NOT reset this flag —
    /// clearing is a within-doc operation, the canvas dimensions stay
    /// at the loaded doc's size.
    private var _canvasSizeLockedToDoc: Bool = false

    /// Device-capability-driven max canvas dimension. Used by both
    /// `updateCanvasSize(for:)` (screen-derived sizing for new docs) and
    /// `setCanvasSize(matchingDoc:)` (clamp on existing-doc load).
    ///
    /// Three-tier gate:
    ///   1. iPhone (any model): 2048². iPhone screens are too small to
    ///      usefully display 4096² content and the form factor isn't the
    ///      platform for high-res canvas work.
    ///   2. iPad with `recommendedMaxWorkingSetSize` < 2 GB: 2048².
    ///      Covers iPad 9th/10th gen, iPad mini 6, iPad Air 4 — devices
    ///      with 3-4 GB total RAM whose Metal heap budget can't safely
    ///      carry the ~1.16 GB renderer footprint at 4096² plus user
    ///      content, AI payloads, and iOS overhead.
    ///   3. iPad with WSS ≥ 2 GB: 4096². iPad Air M1+, iPad Pro M1+,
    ///      iPad mini 7 (A17 Pro). Margin over the ~1.16 GB renderer
    ///      footprint for headroom.
    ///
    /// The 2 GB threshold is sized for renderer working set + margin, not
    /// total system RAM — `recommendedMaxWorkingSetSize` already reports
    /// the Metal-safe budget Apple has provisioned for the app. If
    /// real-device numbers show the renderer fits comfortably at lower
    /// budgets we can lower this; raising it is the safer mistake.
    ///
    /// Gated behind FEATURE_HIGH_RESOLUTION_CANVAS so we can flip both
    /// configs OFF in pbxproj to revert to unconditional 2048² without
    /// touching code.
    var maxCanvasDimension: CGFloat {
        #if FEATURE_HIGH_RESOLUTION_CANVAS
        if DeviceIdiom.isPhone { return 2048 }
        let wss = device.recommendedMaxWorkingSetSize
        let twoGigabytes: UInt64 = 2 * 1024 * 1024 * 1024
        return wss >= twoGigabytes ? 4096 : 2048
        #else
        return 2048
        #endif
    }

    /// One-shot startup log: working-set size + chosen cap. Lets you
    /// verify on a real device which tier the gate selected without a
    /// debugger. Fires the first time `maxCanvasDimension` would matter
    /// (called from the first updateCanvasSize / setCanvasSize). Idempotent
    /// — the guard prevents repeat logging on rotation / doc reload.
    private var _maxCapLogged = false
    private func logMaxCanvasDimensionOnce() {
        guard !_maxCapLogged else { return }
        _maxCapLogged = true
        let wss = device.recommendedMaxWorkingSetSize
        let wssMB = wss / (1024 * 1024)
        let cap = maxCanvasDimension
        let idiom = DeviceIdiom.isPhone ? "phone" : "pad"
        dbgLog("📐 Canvas cap: \(Int(cap))² — idiom=\(idiom), WSS=\(wssMB) MB")
    }

    /// Update canvas size based on screen dimensions
    /// Canvas should be a square with side length = ceil(screen diagonal) to avoid clipping when rotated
    func updateCanvasSize(for screenSize: CGSize) {
        // Once a loaded doc has locked the canvas size, the screen-
        // derived path no-ops — the saved doc dimensions are
        // authoritative for the rest of the session.
        guard !_canvasSizeLockedToDoc else { return }
        logMaxCanvasDimensionOnce()
        let cap = maxCanvasDimension
        let diagonal = ceil(sqrt(screenSize.width * screenSize.width + screenSize.height * screenSize.height))
        // Round up to nearest power of 2 for better GPU performance, cap at maxCanvasDimension to bound memory pressure
        let size = min(pow(2, ceil(log2(diagonal))), cap)
        let newSize = CGSize(width: size, height: size)

        // Only update if size actually changed
        if newSize != _canvasSize {
            dbgLog("📐 Canvas size updated from \(_canvasSize) to \(newSize) based on screen \(screenSize)")
            _canvasSize = newSize
            // Layer composite cache entries are sized to the old canvas;
            // drop them so new entries allocate at the new size. The
            // canvasStagingAtlas / tileDisplayIntermediate / strokeScratch
            // re-allocate lazily on their next ensure call via the same
            // pattern.
            layerCompositeCache.updateCanvasSize(newSize)
        }
    }

    /// Force the canvas size to match a loaded document's saved
    /// dimensions, clamped to `maxCanvasDimension`. Called by
    /// `CanvasStateManager.loadLayered` after parsing the manifest's
    /// `document.width` / `document.height`. Locks the canvas size for
    /// the rest of the session so subsequent screen-driven
    /// `updateCanvasSize` calls don't override it.
    ///
    /// **Why locking is correct.** A loaded doc's saved size is
    /// authoritative — strokes are stored at saved-canvas coordinates,
    /// not screen coordinates. If the renderer's canvas were bumped
    /// back to the device cap after load, the doc's content would
    /// appear shifted in the canvas-pixel coordinate space.
    ///
    /// **Cross-device case.** A doc saved at 4096² on iPad Pro opened
    /// on iPad mini 6: `savedSize=4096×4096`, `maxCanvasDimension=2048`,
    /// clamp drops to 2048×2048. The existing
    /// `LoadedWithSizeMismatch` warning in `loadLayered` still fires;
    /// content beyond the clamped region partially loads (top-left
    /// of the saved 4096² lands in the 2048² grid). Acceptable v1
    /// limitation; proper cross-device support is a downscale-on-import
    /// follow-up.
    func setCanvasSize(matchingDoc savedSize: CGSize) {
        logMaxCanvasDimensionOnce()
        let cap = maxCanvasDimension
        let w = max(256, min(savedSize.width, cap))
        let h = max(256, min(savedSize.height, cap))
        // Round to power of 2 to keep texture allocation paths aligned
        // (atlas, intermediate, scratch all use the same nearest-pow2
        // assumption baked into the legacy diagonal-fit math).
        let w2 = pow(2, ceil(log2(w)))
        let h2 = pow(2, ceil(log2(h)))
        let newSize = CGSize(width: w2, height: h2)
        if newSize != _canvasSize {
            dbgLog("📐 Canvas size set to \(newSize) matching loaded doc (saved=\(savedSize), cap=\(Int(cap))²)")
            _canvasSize = newSize
            layerCompositeCache.updateCanvasSize(newSize)
        }
        _canvasSizeLockedToDoc = true
    }

    init?(metalDevice: MTLDevice) {
        self.device = metalDevice

        guard let queue = device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = queue
        self.layerCompositeCache = LayerCompositeCache(
            device: metalDevice,
            canvasSize: CGSize(width: 2048, height: 2048)
        )

        super.init()

        setupPipeline()
    }

    private func setupPipeline() {
        guard let library = device.makeDefaultLibrary() else {
            dbgLog("Failed to create Metal library")
            return
        }

        // Load shader functions
        guard let brushVertex = library.makeFunction(name: "brushVertexShader"),
              let brushFragment = library.makeFunction(name: "brushFragmentShader"),
              let eraserFragment = library.makeFunction(name: "eraserFragmentShader"),
              let pencilFragment = library.makeFunction(name: "pencilFragmentShader"),
              let markerFragment = library.makeFunction(name: "markerFragmentShader"),
              let airbrushFragment = library.makeFunction(name: "airbrushFragmentShader"),
              let charcoalFragment = library.makeFunction(name: "charcoalFragmentShader"),
              let watercolorFragment = library.makeFunction(name: "watercolorFragmentShader"),
              let brushFragmentPremul = library.makeFunction(name: "brushFragmentShaderPremul"),
              let pencilFragmentPremul = library.makeFunction(name: "pencilFragmentShaderPremul"),
              let markerFragmentPremul = library.makeFunction(name: "markerFragmentShaderPremul"),
              let airbrushFragmentPremul = library.makeFunction(name: "airbrushFragmentShaderPremul"),
              let charcoalFragmentPremul = library.makeFunction(name: "charcoalFragmentShaderPremul"),
              let watercolorFragmentPremul = library.makeFunction(name: "watercolorFragmentShaderPremul"),
              let quadVertex = library.makeFunction(name: "quadVertexShader"),
              let quadVertexWithTransform = library.makeFunction(name: "quadVertexShaderWithTransform"),
              let quadVertexForRect = library.makeFunction(name: "quadVertexShaderForRect"),
              let compositeFragment = library.makeFunction(name: "compositeFragmentShader"),
              let textureDisplayFragment = library.makeFunction(name: "textureDisplayShader"),
              let gaussianBlurFragment = library.makeFunction(name: "gaussianBlurShader"),
              let gaussianBlurMaskedFragment = library.makeFunction(name: "gaussianBlurMaskedShader"),
              let stampBlurDepositFragment = library.makeFunction(name: "stampBlurDepositShader"),
              let smudgePatchUpdateFragment = library.makeFunction(name: "smudgePatchUpdateShader"),
              let smudgeDepositFragment = library.makeFunction(name: "smudgeDepositShader"),
              let compositeTileVertex = library.makeFunction(name: "compositeTileVertexShader"),
              let compositeTileFragment = library.makeFunction(name: "compositeTileFragmentShader"),
              let tileDirectVertex = library.makeFunction(name: "tileDirectVertexShader"),
              let tileDirectFragment = library.makeFunction(name: "tileDirectFragmentShader"),
              let wetInkCommitFragment = library.makeFunction(name: "wetInkCommitShader"),
              let wetInkCommitFragmentLinear = library.makeFunction(name: "wetInkCommitShaderLinear"),
              let wetInkEraserCommitFragment = library.makeFunction(name: "wetInkEraserCommitShader"),
              let wetInkEraserCommitFragmentLinear = library.makeFunction(name: "wetInkEraserCommitShaderLinear") else {
            dbgLog("Failed to load shader functions")
            return
        }

        // Brush pipeline
        let brushDescriptor = MTLRenderPipelineDescriptor()
        brushDescriptor.vertexFunction = brushVertex
        brushDescriptor.fragmentFunction = brushFragment
        brushDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        brushDescriptor.colorAttachments[0].isBlendingEnabled = true
        brushDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        brushDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        brushDescriptor.colorAttachments[0].rgbBlendOperation = .add
        brushDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        brushDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        brushDescriptor.colorAttachments[0].alphaBlendOperation = .add

        // Eraser pipeline (uses zero blend to erase)
        let eraserDescriptor = MTLRenderPipelineDescriptor()
        eraserDescriptor.vertexFunction = brushVertex
        eraserDescriptor.fragmentFunction = eraserFragment
        eraserDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        eraserDescriptor.colorAttachments[0].isBlendingEnabled = true
        eraserDescriptor.colorAttachments[0].sourceRGBBlendFactor = .zero
        eraserDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        eraserDescriptor.colorAttachments[0].rgbBlendOperation = .add
        eraserDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .zero
        eraserDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        eraserDescriptor.colorAttachments[0].alphaBlendOperation = .add

        // Experimental brush-variant pipelines (experiment/brush-variety-v1).
        // Each clones the brush descriptor's blend setup and only swaps the
        // fragment function. A single helper closure keeps the five
        // descriptors honest with the brush descriptor — if `brushDescriptor`
        // ever changes its blend setup, these inherit it for free.
        func makeBrushVariantDescriptor(_ fragment: MTLFunction) -> MTLRenderPipelineDescriptor {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = brushVertex
            d.fragmentFunction = fragment
            d.colorAttachments[0].pixelFormat = brushDescriptor.colorAttachments[0].pixelFormat
            d.colorAttachments[0].isBlendingEnabled = brushDescriptor.colorAttachments[0].isBlendingEnabled
            d.colorAttachments[0].sourceRGBBlendFactor = brushDescriptor.colorAttachments[0].sourceRGBBlendFactor
            d.colorAttachments[0].destinationRGBBlendFactor = brushDescriptor.colorAttachments[0].destinationRGBBlendFactor
            d.colorAttachments[0].rgbBlendOperation = brushDescriptor.colorAttachments[0].rgbBlendOperation
            d.colorAttachments[0].sourceAlphaBlendFactor = brushDescriptor.colorAttachments[0].sourceAlphaBlendFactor
            d.colorAttachments[0].destinationAlphaBlendFactor = brushDescriptor.colorAttachments[0].destinationAlphaBlendFactor
            d.colorAttachments[0].alphaBlendOperation = brushDescriptor.colorAttachments[0].alphaBlendOperation
            return d
        }
        let pencilDescriptor = makeBrushVariantDescriptor(pencilFragment)
        let markerDescriptor = makeBrushVariantDescriptor(markerFragment)
        let airbrushDescriptor = makeBrushVariantDescriptor(airbrushFragment)
        let charcoalDescriptor = makeBrushVariantDescriptor(charcoalFragment)
        let watercolorDescriptor = makeBrushVariantDescriptor(watercolorFragment)

        // Wet-ink premul variants (Phase A.5 onward). Same as makeBrushVariantDescriptor
        // but swaps sourceRGBBlendFactor from .sourceAlpha to .one — paired with shaders
        // that emit premultiplied output. Framebuffer math equivalent to OLD; proven
        // byte-exact by runShaderEquivalencePhaseA5Probe.
        func makeBrushPremulVariantDescriptor(_ fragment: MTLFunction) -> MTLRenderPipelineDescriptor {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = brushVertex
            d.fragmentFunction = fragment
            d.colorAttachments[0].pixelFormat = brushDescriptor.colorAttachments[0].pixelFormat
            d.colorAttachments[0].isBlendingEnabled = true
            d.colorAttachments[0].sourceRGBBlendFactor = .one   // <-- the only delta vs OLD
            d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[0].rgbBlendOperation = .add
            d.colorAttachments[0].sourceAlphaBlendFactor = .one
            d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[0].alphaBlendOperation = .add
            return d
        }
        let brushPremulDescriptor = makeBrushPremulVariantDescriptor(brushFragmentPremul)
        let pencilPremulDescriptor = makeBrushPremulVariantDescriptor(pencilFragmentPremul)
        let markerPremulDescriptor = makeBrushPremulVariantDescriptor(markerFragmentPremul)
        let airbrushPremulDescriptor = makeBrushPremulVariantDescriptor(airbrushFragmentPremul)
        let charcoalPremulDescriptor = makeBrushPremulVariantDescriptor(charcoalFragmentPremul)

        // Wet-ink deposit variants (Phase B onward). Premul-output fragment
        // with .max/.max blend, both source and dest factors .one. Equivalent
        // to "the channel-wise maximum of any stamp deposited at this pixel
        // within the stroke" — commutative, idempotent, no within-stroke
        // accumulation. See §2.2 of WET_INK_DESIGN.md.
        func makeWetInkDepositVariantDescriptor(_ fragment: MTLFunction) -> MTLRenderPipelineDescriptor {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = brushVertex
            d.fragmentFunction = fragment
            d.colorAttachments[0].pixelFormat = brushDescriptor.colorAttachments[0].pixelFormat
            d.colorAttachments[0].isBlendingEnabled = true
            d.colorAttachments[0].sourceRGBBlendFactor = .one
            d.colorAttachments[0].destinationRGBBlendFactor = .one
            d.colorAttachments[0].rgbBlendOperation = .max
            d.colorAttachments[0].sourceAlphaBlendFactor = .one
            d.colorAttachments[0].destinationAlphaBlendFactor = .one
            d.colorAttachments[0].alphaBlendOperation = .max
            return d
        }
        // Pencil + charcoal need INTRA-stroke opacity buildup so artists
        // can shade by scribbling. Same premul shaders as the .max/.max
        // path, but blended with standard premul-over so overlapping
        // stamps within one stroke darken instead of capping. Commit
        // pipeline (wetInkCommitDescriptor) doesn't change — scratch is
        // still composited into the layer the same way.
        func makeWetInkAlphaBlendDepositVariantDescriptor(_ fragment: MTLFunction) -> MTLRenderPipelineDescriptor {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = brushVertex
            d.fragmentFunction = fragment
            d.colorAttachments[0].pixelFormat = brushDescriptor.colorAttachments[0].pixelFormat
            d.colorAttachments[0].isBlendingEnabled = true
            d.colorAttachments[0].sourceRGBBlendFactor = .one
            d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[0].rgbBlendOperation = .add
            d.colorAttachments[0].sourceAlphaBlendFactor = .one
            d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[0].alphaBlendOperation = .add
            return d
        }
        let brushScratchDepositDescriptor = makeWetInkDepositVariantDescriptor(brushFragmentPremul)
        // Eraser deposit reuses the unchanged `eraserFragment` (emits
        // (0, 0, 0, alpha)) with the same .max/.max blend as brush deposit.
        // RGB stays at 0 in scratch; only the alpha channel carries the
        // eraser's footprint into the commit step.
        let eraserScratchDepositDescriptor = makeWetInkDepositVariantDescriptor(eraserFragment)
        // Phase E: deposit descriptors for the additive brush variants.
        // Each uses its premul fragment + the shared .max/.max blend.
        let pencilScratchDepositDescriptor = makeWetInkAlphaBlendDepositVariantDescriptor(pencilFragmentPremul)
        let markerScratchDepositDescriptor = makeWetInkDepositVariantDescriptor(markerFragmentPremul)
        // Watercolor deposits with the same .max/.max blend as marker:
        // flat single-value strokes (the stamp profile IS the stroke
        // cross-section), with cross-stroke overlap deepening at commit.
        let watercolorScratchDepositDescriptor = makeWetInkDepositVariantDescriptor(watercolorFragmentPremul)
        let airbrushScratchDepositDescriptor = makeWetInkDepositVariantDescriptor(airbrushFragmentPremul)
        let charcoalScratchDepositDescriptor = makeWetInkAlphaBlendDepositVariantDescriptor(charcoalFragmentPremul)

        // Wet-ink commit pipeline (Phase C). Full-canvas quad reading
        // strokeScratch, premul-over into the atlas. Sample factors mirror
        // the existing `textureDisplayDescriptor` (which also reads a
        // premultiplied texture and composites alpha-over).
        let wetInkCommitDescriptor = MTLRenderPipelineDescriptor()
        wetInkCommitDescriptor.vertexFunction = quadVertex
        wetInkCommitDescriptor.fragmentFunction = wetInkCommitFragment
        wetInkCommitDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        wetInkCommitDescriptor.colorAttachments[0].isBlendingEnabled = true
        wetInkCommitDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        wetInkCommitDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        wetInkCommitDescriptor.colorAttachments[0].rgbBlendOperation = .add
        wetInkCommitDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        wetInkCommitDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        wetInkCommitDescriptor.colorAttachments[0].alphaBlendOperation = .add

        // Eraser commit pipeline — dest-out blend. dst.rgb = dst.rgb *
        // (1 - srcA), dst.a = dst.a * (1 - srcA). Reads scratch via
        // wetInkEraserCommitShader (which masks RGB to zero). Math
        // verified in §2.5 of WET_INK_DESIGN.md.
        let wetInkEraserCommitDescriptor = MTLRenderPipelineDescriptor()
        wetInkEraserCommitDescriptor.vertexFunction = quadVertex
        wetInkEraserCommitDescriptor.fragmentFunction = wetInkEraserCommitFragment
        wetInkEraserCommitDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        wetInkEraserCommitDescriptor.colorAttachments[0].isBlendingEnabled = true
        wetInkEraserCommitDescriptor.colorAttachments[0].sourceRGBBlendFactor = .zero
        wetInkEraserCommitDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        wetInkEraserCommitDescriptor.colorAttachments[0].rgbBlendOperation = .add
        wetInkEraserCommitDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .zero
        wetInkEraserCommitDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        wetInkEraserCommitDescriptor.colorAttachments[0].alphaBlendOperation = .add

        // Composite pipeline
        let compositeDescriptor = MTLRenderPipelineDescriptor()
        compositeDescriptor.vertexFunction = quadVertex
        compositeDescriptor.fragmentFunction = compositeFragment
        compositeDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        compositeDescriptor.colorAttachments[0].isBlendingEnabled = true
        compositeDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        compositeDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        compositeDescriptor.colorAttachments[0].rgbBlendOperation = .add

        // Texture display pipeline (for showing layers on screen).
        //
        // The canvas texture stores PREMULTIPLIED rgba (the brush pipeline's
        // `.sourceAlpha/.oneMinusSourceAlpha` blend into an initially-transparent
        // texture premultiplies the output). Displaying it back with sourceAlpha
        // would multiply by alpha a second time, producing dark/desaturated
        // halos along soft edges — that's the gray outline around strokes. Use
        // `.one` for the source RGB since it's already premultiplied.
        let textureDisplayDescriptor = MTLRenderPipelineDescriptor()
        textureDisplayDescriptor.vertexFunction = quadVertex
        textureDisplayDescriptor.fragmentFunction = textureDisplayFragment
        textureDisplayDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        textureDisplayDescriptor.colorAttachments[0].isBlendingEnabled = true
        textureDisplayDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        textureDisplayDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        textureDisplayDescriptor.colorAttachments[0].rgbBlendOperation = .add
        textureDisplayDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        textureDisplayDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        textureDisplayDescriptor.colorAttachments[0].alphaBlendOperation = .add

        // Per-tile composite pipeline (Phase 3). Same blend state as
        // textureDisplayDescriptor — premultiplied source RGB + alpha-over —
        // so a back-to-front sequence of per-tile draws produces the same
        // accumulated pixel values as a single full-canvas-quad composite of
        // the corresponding monolithic texture. Vertex shader takes int4
        // tileRect + int2 outputSize, fragment shader uses NEAREST sampler.
        let compositeTileDescriptor = MTLRenderPipelineDescriptor()
        compositeTileDescriptor.vertexFunction = compositeTileVertex
        compositeTileDescriptor.fragmentFunction = compositeTileFragment
        compositeTileDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        compositeTileDescriptor.colorAttachments[0].isBlendingEnabled = true
        compositeTileDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        compositeTileDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        compositeTileDescriptor.colorAttachments[0].rgbBlendOperation = .add
        compositeTileDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        compositeTileDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        compositeTileDescriptor.colorAttachments[0].alphaBlendOperation = .add

        // Tile-direct-to-drawable pipeline (Phase 6 / Tier C 9).
        // tileDirectVertexShader applies the full canvas-to-drawable transform
        // per-tile; tileDirectFragmentShader samples with LINEAR (matches
        // legacy textureDisplayShader for visual consistency). Same standard
        // premul-source-over blend as the per-tile composite + display
        // shaders. Targets the drawable directly, eliminating the per-frame
        // tileDisplayIntermediate materialization.
        let tileDirectToDrawableDescriptor = MTLRenderPipelineDescriptor()
        tileDirectToDrawableDescriptor.vertexFunction = tileDirectVertex
        tileDirectToDrawableDescriptor.fragmentFunction = tileDirectFragment
        tileDirectToDrawableDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        tileDirectToDrawableDescriptor.colorAttachments[0].isBlendingEnabled = true
        tileDirectToDrawableDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        tileDirectToDrawableDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        tileDirectToDrawableDescriptor.colorAttachments[0].rgbBlendOperation = .add
        tileDirectToDrawableDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        tileDirectToDrawableDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        tileDirectToDrawableDescriptor.colorAttachments[0].alphaBlendOperation = .add

        // Wet-ink commit variants targeting the drawable directly. Pair the
        // transform vertex shader with the LINEAR sampler variants of the
        // wet-ink commit / eraser-commit fragment shaders — preview UVs
        // pass through pan/zoom/rotation and are not 1:1 with scratch, so
        // they must match tileDirectFragmentShader's LINEAR sampling to
        // keep committed pixels visually identical to the live preview
        // (high-frequency content — pencil tooth, charcoal grain — would
        // otherwise reshape on stroke release). The 1:1 atlas-commit
        // pipelines above keep the NEAREST variants. Blend state mirrors
        // wetInkCommit + wetInkEraserCommit (premul-over / dest-out).
        let wetInkCommitToDrawableDescriptor = MTLRenderPipelineDescriptor()
        wetInkCommitToDrawableDescriptor.vertexFunction = tileDirectVertex
        wetInkCommitToDrawableDescriptor.fragmentFunction = wetInkCommitFragmentLinear
        wetInkCommitToDrawableDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        wetInkCommitToDrawableDescriptor.colorAttachments[0].isBlendingEnabled = true
        wetInkCommitToDrawableDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        wetInkCommitToDrawableDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        wetInkCommitToDrawableDescriptor.colorAttachments[0].rgbBlendOperation = .add
        wetInkCommitToDrawableDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        wetInkCommitToDrawableDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        wetInkCommitToDrawableDescriptor.colorAttachments[0].alphaBlendOperation = .add

        let wetInkEraserCommitToDrawableDescriptor = MTLRenderPipelineDescriptor()
        wetInkEraserCommitToDrawableDescriptor.vertexFunction = tileDirectVertex
        wetInkEraserCommitToDrawableDescriptor.fragmentFunction = wetInkEraserCommitFragmentLinear
        wetInkEraserCommitToDrawableDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        wetInkEraserCommitToDrawableDescriptor.colorAttachments[0].isBlendingEnabled = true
        wetInkEraserCommitToDrawableDescriptor.colorAttachments[0].sourceRGBBlendFactor = .zero
        wetInkEraserCommitToDrawableDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        wetInkEraserCommitToDrawableDescriptor.colorAttachments[0].rgbBlendOperation = .add
        wetInkEraserCommitToDrawableDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .zero
        wetInkEraserCommitToDrawableDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        wetInkEraserCommitToDrawableDescriptor.colorAttachments[0].alphaBlendOperation = .add

        // Texture display pipeline with zoom/pan transform support — same
        // premultiplied-source blend as above.
        let textureDisplayWithTransformDescriptor = MTLRenderPipelineDescriptor()
        textureDisplayWithTransformDescriptor.vertexFunction = quadVertexWithTransform
        textureDisplayWithTransformDescriptor.fragmentFunction = textureDisplayFragment
        textureDisplayWithTransformDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        textureDisplayWithTransformDescriptor.colorAttachments[0].isBlendingEnabled = true
        textureDisplayWithTransformDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        textureDisplayWithTransformDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        textureDisplayWithTransformDescriptor.colorAttachments[0].rgbBlendOperation = .add
        textureDisplayWithTransformDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        textureDisplayWithTransformDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        textureDisplayWithTransformDescriptor.colorAttachments[0].alphaBlendOperation = .add

        // Floating-texture pipeline — same premultiplied source-over blend as
        // the layer compositor, but uses the rect-based vertex shader so the
        // caller can place the texture anywhere in doc space (selection drag
        // preview, commit-to-layer blit).
        let floatingTextureDescriptor = MTLRenderPipelineDescriptor()
        floatingTextureDescriptor.vertexFunction = quadVertexForRect
        floatingTextureDescriptor.fragmentFunction = textureDisplayFragment
        floatingTextureDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        floatingTextureDescriptor.colorAttachments[0].isBlendingEnabled = true
        floatingTextureDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        floatingTextureDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        floatingTextureDescriptor.colorAttachments[0].rgbBlendOperation = .add
        floatingTextureDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        floatingTextureDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        floatingTextureDescriptor.colorAttachments[0].alphaBlendOperation = .add

        // Reference-quad pipeline — screen-space positioned textured quad
        // for back-canvas reference rendering. Premultiplied-alpha blend
        // matches the rest of the to-screen passes so layered strokes
        // composite correctly on top of the reference.
        let referenceQuadDescriptor = MTLRenderPipelineDescriptor()
        referenceQuadDescriptor.vertexFunction = library.makeFunction(name: "referenceQuadVertexShader")
        referenceQuadDescriptor.fragmentFunction = library.makeFunction(name: "referenceQuadFragmentShader")
        referenceQuadDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        referenceQuadDescriptor.colorAttachments[0].isBlendingEnabled = true
        referenceQuadDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        referenceQuadDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        referenceQuadDescriptor.colorAttachments[0].rgbBlendOperation = .add
        referenceQuadDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        referenceQuadDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        referenceQuadDescriptor.colorAttachments[0].alphaBlendOperation = .add

        // Gaussian blur pipelines (no blending — raw replace into intermediate
        // textures). Both the unmasked and the masked variants write opaque
        // RGBA to their target.
        let gaussianBlurDescriptor = MTLRenderPipelineDescriptor()
        gaussianBlurDescriptor.vertexFunction = quadVertex
        gaussianBlurDescriptor.fragmentFunction = gaussianBlurFragment
        gaussianBlurDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        gaussianBlurDescriptor.colorAttachments[0].isBlendingEnabled = false

        let gaussianBlurMaskedDescriptor = MTLRenderPipelineDescriptor()
        gaussianBlurMaskedDescriptor.vertexFunction = quadVertex
        gaussianBlurMaskedDescriptor.fragmentFunction = gaussianBlurMaskedFragment
        gaussianBlurMaskedDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        gaussianBlurMaskedDescriptor.colorAttachments[0].isBlendingEnabled = false

        // Brush-blur deposit — premultiplied source-over into the layer
        // texture, same blend factors as the brush pipeline.
        // Blending disabled: stampBlurDepositShader uses Metal framebuffer
        // fetch (`[[color(0)]]`) to read the current destination and
        // returns `mix(currentColor, blurred, coverage)` directly. The
        // shader IS the blend — fixed-function blending would compose
        // again on top and re-introduce the alpha-accumulation bug the
        // mix() formulation was added to fix.
        let stampBlurDepositDescriptor = MTLRenderPipelineDescriptor()
        stampBlurDepositDescriptor.vertexFunction = brushVertex
        stampBlurDepositDescriptor.fragmentFunction = stampBlurDepositFragment
        stampBlurDepositDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        stampBlurDepositDescriptor.colorAttachments[0].isBlendingEnabled = false

        // Smudge patch-update — raw replace into the back patch (no blend).
        // The mix happens inside the shader (sample front patch + layer,
        // mix), so the framebuffer write is just an opaque store.
        let smudgePatchUpdateDescriptor = MTLRenderPipelineDescriptor()
        smudgePatchUpdateDescriptor.vertexFunction = quadVertex
        smudgePatchUpdateDescriptor.fragmentFunction = smudgePatchUpdateFragment
        smudgePatchUpdateDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        smudgePatchUpdateDescriptor.colorAttachments[0].isBlendingEnabled = false

        // Smudge deposit — blending disabled, same rationale as the blur
        // deposit. smudgeDepositShader uses framebuffer fetch and returns
        // `mix(currentColor, picked, coverage)` directly.
        let smudgeDepositDescriptor = MTLRenderPipelineDescriptor()
        smudgeDepositDescriptor.vertexFunction = brushVertex
        smudgeDepositDescriptor.fragmentFunction = smudgeDepositFragment
        smudgeDepositDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        smudgeDepositDescriptor.colorAttachments[0].isBlendingEnabled = false

        do {
            brushPipelineState = try device.makeRenderPipelineState(descriptor: brushDescriptor)
            eraserPipelineState = try device.makeRenderPipelineState(descriptor: eraserDescriptor)
            pencilPipelineState = try device.makeRenderPipelineState(descriptor: pencilDescriptor)
            markerPipelineState = try device.makeRenderPipelineState(descriptor: markerDescriptor)
            airbrushPipelineState = try device.makeRenderPipelineState(descriptor: airbrushDescriptor)
            charcoalPipelineState = try device.makeRenderPipelineState(descriptor: charcoalDescriptor)
            watercolorPipelineState = try device.makeRenderPipelineState(descriptor: watercolorDescriptor)
            brushPremulPipelineState = try device.makeRenderPipelineState(descriptor: brushPremulDescriptor)
            pencilPremulPipelineState = try device.makeRenderPipelineState(descriptor: pencilPremulDescriptor)
            markerPremulPipelineState = try device.makeRenderPipelineState(descriptor: markerPremulDescriptor)
            airbrushPremulPipelineState = try device.makeRenderPipelineState(descriptor: airbrushPremulDescriptor)
            charcoalPremulPipelineState = try device.makeRenderPipelineState(descriptor: charcoalPremulDescriptor)
            brushScratchDepositPipelineState = try device.makeRenderPipelineState(descriptor: brushScratchDepositDescriptor)
            eraserScratchDepositPipelineState = try device.makeRenderPipelineState(descriptor: eraserScratchDepositDescriptor)
            pencilScratchDepositPipelineState = try device.makeRenderPipelineState(descriptor: pencilScratchDepositDescriptor)
            markerScratchDepositPipelineState = try device.makeRenderPipelineState(descriptor: markerScratchDepositDescriptor)
            airbrushScratchDepositPipelineState = try device.makeRenderPipelineState(descriptor: airbrushScratchDepositDescriptor)
            charcoalScratchDepositPipelineState = try device.makeRenderPipelineState(descriptor: charcoalScratchDepositDescriptor)
            watercolorScratchDepositPipelineState = try device.makeRenderPipelineState(descriptor: watercolorScratchDepositDescriptor)
            wetInkCommitPipelineState = try device.makeRenderPipelineState(descriptor: wetInkCommitDescriptor)
            wetInkEraserCommitPipelineState = try device.makeRenderPipelineState(descriptor: wetInkEraserCommitDescriptor)
            compositePipelineState = try device.makeRenderPipelineState(descriptor: compositeDescriptor)
            textureDisplayPipelineState = try device.makeRenderPipelineState(descriptor: textureDisplayDescriptor)
            textureDisplayWithTransformPipelineState = try device.makeRenderPipelineState(descriptor: textureDisplayWithTransformDescriptor)
            compositeTilePipelineState = try device.makeRenderPipelineState(descriptor: compositeTileDescriptor)
            tileDirectToDrawablePipelineState = try device.makeRenderPipelineState(descriptor: tileDirectToDrawableDescriptor)
            wetInkCommitToDrawablePipelineState = try device.makeRenderPipelineState(descriptor: wetInkCommitToDrawableDescriptor)
            wetInkEraserCommitToDrawablePipelineState = try device.makeRenderPipelineState(descriptor: wetInkEraserCommitToDrawableDescriptor)
            floatingTexturePipelineState = try device.makeRenderPipelineState(descriptor: floatingTextureDescriptor)
            referenceQuadPipelineState = try device.makeRenderPipelineState(descriptor: referenceQuadDescriptor)
            gaussianBlurPipelineState = try device.makeRenderPipelineState(descriptor: gaussianBlurDescriptor)
            gaussianBlurMaskedPipelineState = try device.makeRenderPipelineState(descriptor: gaussianBlurMaskedDescriptor)
            stampBlurDepositPipelineState = try device.makeRenderPipelineState(descriptor: stampBlurDepositDescriptor)
            smudgePatchUpdatePipelineState = try device.makeRenderPipelineState(descriptor: smudgePatchUpdateDescriptor)
            smudgeDepositPipelineState = try device.makeRenderPipelineState(descriptor: smudgeDepositDescriptor)
        } catch {
            dbgLog("Failed to create pipeline states: \(error)")
        }

        // Create a 1x1 opaque white texture for the canvas background quad
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = [.shaderRead]
        if let tex = device.makeTexture(descriptor: desc) {
            var pixel: [UInt8] = [255, 255, 255, 255] // BGRA white
            tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
            whiteTexture = tex
        }

        // Create the 1×1 r8Unorm no-mask selection texture (PR 3). Value
        // 255 = 1.0 after sampler normalisation, so any UV samples 1.0 =
        // "fully inside selection" = no clipping. Created up-front (not
        // lazily on first stroke) so the brush is correct from the very
        // first dispatch.
        let maskDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        maskDesc.usage = [.shaderRead]
        if let tex = device.makeTexture(descriptor: maskDesc) {
            var byte: UInt8 = 255
            tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &byte, bytesPerRow: 1)
            noMaskTexture = tex
        }
    }

    /// Create an empty TileGrid sized to the renderer's current
    /// canvasSize at the Phase 2 tile size of 256. The grid is empty
    /// (no allocated tiles) — Phase 2 dual-write paths populate it on
    /// first write to each tile.
    ///
    /// Callers are responsible for assigning the returned grid alongside
    /// `layer.texture` so the layer's texture and grid stay paired. The
    /// renderer doesn't know about DrawingLayer.
    func makeEmptyTileGrid() -> TileGrid {
        TileGrid(canvasSize: canvasSize, tileSize: 256, device: device)
    }

    // MARK: - Canvas staging atlas (Phase 4.2 + 4.5c)
    //
    // Lazy-allocated canvas-sized .shared MTLTexture serving as the
    // renderer's shared scratch surface for tile-native operations.
    // Replaces the per-layer monolithic (DrawingLayer.texture) that
    // existed in Phase 0-3 — one shared surface, not N per-layer
    // allocations.
    //
    // Used for both READ and WRITE paths:
    //   - READ (Phase 4.2): blit allocated tiles into the atlas, then
    //     getBytes from atlas (captureSnapshot, floodFill's pre-blit).
    //     Tile textures are .private; CPU readback requires a .shared
    //     intermediate.
    //   - WRITE (Phase 4.5c): dual-write functions render or
    //     texture.replace into the atlas, then blit affected tile
    //     regions back into the tile grid. Replaces the per-layer
    //     .texture monolithic that previously served as the dual-write
    //     scratch surface.
    //
    // Storage: .shared (CPU access needed for read-path getBytes +
    // write-path texture.replace).
    // Usage: [.shaderRead, .renderTarget, .pixelFormatView] —
    // .renderTarget added in 4.5c for the dual-write functions that
    // use render encoders (renderStroke, compositeFloating, flip,
    // translate, blur variants, smudge); .shaderRead for sampler
    // bindings; .pixelFormatView defensive for future blend-state
    // variants.
    //
    // canvasSize change (rare — the 2048 cap in updateCanvasSize keeps
    // it static today, N5 in the master audit) forces a reallocation
    // on the next ensure call.
    //
    // Memory: 16 MB at 2048², 64 MB at 4096². ONE allocation per
    // renderer (vs N allocations under the per-layer model). Allocated
    // lazily on first use so renderers that never snapshot or write
    // don't pay the cost.
    //
    // Concurrency: dual-writes on different layers do not happen
    // simultaneously in DrawEvolve's user model (user draws on one
    // layer at a time). Same-layer concurrency is handled by Metal
    // hazard tracking + the `drainCommandQueue` defense at
    // `restoreSnapshot` (commit 5b15e24).
    private var canvasStagingAtlas: MTLTexture?

    /// Return the renderer's shared canvas-sized .shared staging
    /// MTLTexture, lazy-allocating on first call and reallocating on
    /// canvasSize change. Used by both read-path operations
    /// (captureSnapshot, floodFill) and write-path dual-write
    /// operations (renderStroke, clearRect, renderImage, etc.).
    ///
    /// Returns nil only on Metal allocation failure or zero/negative
    /// canvasSize. Callers should treat nil as a failed operation and
    /// back out cleanly — DO NOT proceed assuming a valid atlas.
    private func ensureCanvasStagingAtlas() -> MTLTexture? {
        let targetW = Int(canvasSize.width)
        let targetH = Int(canvasSize.height)
        guard targetW > 0, targetH > 0 else { return nil }

        if let existing = canvasStagingAtlas,
           existing.width == targetW,
           existing.height == targetH {
            return existing
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: targetW, height: targetH,
            mipmapped: false
        )
        desc.storageMode = .shared
        desc.usage = [.shaderRead, .renderTarget, .pixelFormatView]
        guard let atlas = device.makeTexture(descriptor: desc) else {
            return nil
        }
        canvasStagingAtlas = atlas
        return atlas
    }

    // Pre-zeroed MTLBuffer used as a GPU-side blit source by
    // `clearCanvasStagingAtlasRegion`. Sized to match the atlas
    // (canvasW × canvasH × 4 bytes) so any region up to full-canvas
    // can be cleared with a single buffer→texture blit. `.shared`
    // storage so we can `memset` it once at allocation; on Apple
    // Silicon unified memory makes GPU reads from `.shared` buffers
    // effectively free.
    //
    // Lifecycle mirrors `canvasStagingAtlas`: lazy-allocated, retained
    // for renderer lifetime, reallocated on canvasSize change.
    private var atlasZeroBuffer: MTLBuffer?

    private func ensureAtlasZeroBuffer() -> MTLBuffer? {
        let canvasW = Int(canvasSize.width)
        let canvasH = Int(canvasSize.height)
        let required = canvasW * canvasH * 4
        guard required > 0 else { return nil }
        if let existing = atlasZeroBuffer, existing.length >= required {
            return existing
        }
        guard let buf = device.makeBuffer(length: required, options: .storageModeShared) else {
            return nil
        }
        memset(buf.contents(), 0, required)
        atlasZeroBuffer = buf
        return buf
    }

    /// Clear a region of `canvasStagingAtlas` to (0,0,0,0). Called by
    /// dual-write functions BEFORE their compose-from-tiles step to
    /// eliminate inter-op leakage (Source B fix for the Phase 4.5
    /// blur pink-ring regression).
    ///
    /// **Why it's needed.** The compose-from-tiles step writes only
    /// bbox-intersecting AND allocated tiles into the atlas; any
    /// bbox-intersecting tile that's NOT allocated leaves its atlas
    /// region holding stale pixels from a previous dual-write call
    /// (the atlas is renderer-owned, never auto-cleared). The next
    /// op's `loadAction = .load` then reads those stale pixels and
    /// blends its output over them. Clearing the bbox region to
    /// zero before compose establishes a known-clean baseline:
    /// allocated tiles get their content; unallocated regions stay
    /// transparent.
    ///
    /// **Mechanism.** Blit copy from the pre-zeroed `atlasZeroBuffer`
    /// into the atlas at the region. Uses a fresh blit encoder on the
    /// caller's command buffer — Metal serializes encoders within a
    /// cb in submission order, so the clear lands before any
    /// subsequent compose / render-pass-on-atlas reads.
    ///
    /// Region is clamped to atlas bounds defensively; pass any
    /// MTLRegion and the helper will skip if it lands fully outside.
    private func clearCanvasStagingAtlasRegion(_ region: MTLRegion,
                                                on commandBuffer: MTLCommandBuffer) {
        guard let atlas = ensureCanvasStagingAtlas(),
              let zeros = ensureAtlasZeroBuffer() else { return }

        // Clamp region to atlas bounds.
        let originX = max(0, region.origin.x)
        let originY = max(0, region.origin.y)
        let endX = min(atlas.width, region.origin.x + region.size.width)
        let endY = min(atlas.height, region.origin.y + region.size.height)
        let clampedW = endX - originX
        let clampedH = endY - originY
        guard clampedW > 0, clampedH > 0 else { return }

        let bytesPerRow = clampedW * 4
        let bytesPerImage = bytesPerRow * clampedH

        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(
            from: zeros,
            sourceOffset: 0,
            sourceBytesPerRow: bytesPerRow,
            sourceBytesPerImage: bytesPerImage,
            sourceSize: MTLSize(width: clampedW, height: clampedH, depth: 1),
            to: atlas,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: originX, y: originY, z: 0)
        )
        blit.endEncoding()
    }

    /// Compute the MTLRegion covering the union of the given tile keys'
    /// canvas-pixel rects. Used by Source B clear-before-compose callers
    /// to derive a tile-aligned atlas region from a `bboxKeys` array
    /// (typically the result of `tileGrid.tilesIntersecting(bbox)`).
    ///
    /// Tile-aligned (not raw bbox) because the post-render blit-back
    /// step copies the FULL tile rect (256² or partial-edge) from atlas
    /// back into each tile. A bbox-only clear would leave the in-tile-
    /// but-outside-bbox sliver of an unallocated tile holding stale
    /// pixels, which the blit-back would then persist into the
    /// freshly-allocated tile.
    ///
    /// Returns nil for an empty input.
    private func atlasRegion(coveringTiles keys: [TileKey], tileSize: Int) -> MTLRegion? {
        guard let first = keys.first else { return nil }
        var minTX = first.x, maxTX = first.x
        var minTY = first.y, maxTY = first.y
        for key in keys.dropFirst() {
            if key.x < minTX { minTX = key.x }
            if key.x > maxTX { maxTX = key.x }
            if key.y < minTY { minTY = key.y }
            if key.y > maxTY { maxTY = key.y }
        }
        return MTLRegion(
            origin: MTLOrigin(x: minTX * tileSize, y: minTY * tileSize, z: 0),
            size: MTLSize(
                width: (maxTX - minTX + 1) * tileSize,
                height: (maxTY - minTY + 1) * tileSize,
                depth: 1
            )
        )
    }

    // MARK: - Tile-display intermediate
    //
    // Renderer-owned canvas-sized `.private` MTLTexture. Load-bearing
    // for the **live drawable render path** in MetalCanvasView's
    // `draw(in:)` (since Phase 4.4a, when the display path swapped from
    // monolithic-source to tile-source). Each frame, the per-layer loop
    // composes one layer's tiles into this intermediate, then runs the
    // existing LINEAR-sampling display transform pass on the
    // intermediate to draw onto the drawable. Each visible layer
    // re-uses the same intermediate, alternating compose+draw render
    // passes within a single command buffer.
    //
    // Distinct from `canvasStagingAtlas`:
    //   - Atlas is `.shared` (CPU readback path for snapshots /
    //     floodFill / extractPixels; CPU write path for dual-write
    //     functions' compose-then-render).
    //   - Intermediate is `.private` (GPU-only render target + shader
    //     input; never touched by CPU).
    // Different storage modes, different purposes — never conflate.
    //
    // Memory: 16 MB at 2048², 64 MB at 4096². Lazy-allocated on first
    // tile-display-composite call; retained for renderer lifetime;
    // reused every frame. `canvasSize` change forces reallocation on
    // next ensure call (mirrors the atlas policy).
    //
    // Per-layer reuse semantics (Phase 4.3 H2 fix, preserved by 4.4a's
    // live-drawable swap): each call to
    // `encodeLayerTileCompositeOntoIntermediate` clears the intermediate
    // on load and writes ONE layer's tile content. The per-layer draw
    // pass opens a new render encoder on the drawable with
    // `loadAction = .load` and samples the intermediate. Metal's
    // render-pass hazard tracking serialises the intermediate's writes
    // against subsequent reads — each layer's draw reads its own
    // intermediate state, not the last-composed layer's. (The 4.3b
    // draft, which used a single multi-draw encoder, raced because all
    // draws on one encoder saw the final intermediate state.)
    //
    // `private(set)` exposure: read-only access required by the
    // draw-loop callsite in MetalCanvasView so it can pass the
    // intermediate as the source texture to `renderTextureToScreen`.
    // Writes remain confined to the renderer.
    //
    // Still live on the active path under `FEATURE_TILE_DIRECT_RENDERING`:
    // the move-tool drag-preview carve-out and the eraser wet-ink preview
    // both need an isolated single-layer texture (drawable composite is
    // the wrong destination for renderFloatingTexture's translate and for
    // dest-out erase respectively). Do not delete in a future Slice-6
    // cleanup without retiring both carve-outs first.
    private(set) var tileDisplayIntermediate: MTLTexture?

    /// Per-layer composite cache (Tier B item 6). Holds canvas-sized
    /// intermediates for layers whose tile content hasn't changed since
    /// the prior frame, so the per-frame compose loop in MetalCanvasView's
    /// `draw(in:)` can skip composing them.
    ///
    /// Lazy-allocated at the same point `tileDisplayIntermediate` would be
    /// (first frame after canvas init). Cleared on canvas-size change
    /// (entries are sized to the old canvas; new ones allocate at the new
    /// size). Drained on memory-warning via
    /// `MetalCanvasView.Coordinator.handleMemoryWarning` → `evictDownTo(3)`.
    ///
    /// Default pool size 6 = 96 MB at 2048². Active wet-ink layer
    /// bypasses this cache entirely (see LayerCompositeCache doc comment).
    let layerCompositeCache: LayerCompositeCache

    /// Convenience: cache key for `layer` at its current
    /// `tileGrid.compositeVersion`. Used by the draw loop to look up /
    /// reserve cache entries. Returns nil if the layer has no tileGrid
    /// (invariant violation — every layer should have one post-Phase-4.5e).
    func compositeCacheKey(for layer: DrawingLayer) -> LayerCompositeCache.Key? {
        guard let grid = layer.tileGrid else { return nil }
        return LayerCompositeCache.Key(layerId: layer.id,
                                       compositeVersion: grid.compositeVersion)
    }

    /// Return a canvas-sized .private MTLTexture suitable as a render
    /// target for the tile-composite intermediate. Reused across calls;
    /// reallocates if the renderer's `canvasSize` has changed since the
    /// last call. Returns nil only on Metal allocation failure or
    /// zero/negative canvasSize.
    private func ensureTileDisplayIntermediate() -> MTLTexture? {
        let targetW = Int(canvasSize.width)
        let targetH = Int(canvasSize.height)
        guard targetW > 0, targetH > 0 else { return nil }

        if let existing = tileDisplayIntermediate,
           existing.width == targetW,
           existing.height == targetH {
            return existing
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: targetW, height: targetH,
            mipmapped: false
        )
        desc.storageMode = .private
        desc.usage = [.renderTarget, .shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else {
            return nil
        }
        tileDisplayIntermediate = tex
        return tex
    }

    // MARK: - Wet-ink stroke composition (Phase A: scratch alloc + clear + probe)
    //
    // §2.1 of WET_INK_DESIGN.md. `strokeScratch` is the canvas-sized
    // `.private` `.bgra8Unorm` surface every stamp tool will deposit into
    // (Phase B+); the commit pass at touchesEnded reads it and composites
    // into `canvasStagingAtlas` with the tool's commit blend (premul-over
    // for additive tools, dest-out for eraser). Premultiplied content
    // throughout — same format as tiles, atlas, and tileDisplayIntermediate.
    //
    // Memory: 16 MB at 2048² (the universal cap in updateCanvasSize). One
    // allocation, reused across strokes, reallocated on canvasSize change.
    //
    // Cleared via blit from `atlasZeroBuffer` — never via
    // `loadAction = .clear`. The codebase already avoids `.clear` (it was
    // empirically diagnosed as fragile on Apple Silicon TBDR during the
    // prior wet-ink arc, and this renderer's `clearCanvasStagingAtlasRegion`
    // already uses the blit-from-zero pattern for the same reason).

    private var strokeScratch: MTLTexture?

    /// Return the canvas-sized `.private` MTLTexture used as the wet-ink
    /// scratch. Lazy-allocated on first call; reallocated if canvasSize
    /// changed since the last call. Returns nil only on Metal allocation
    /// failure or zero/negative canvasSize.
    private func ensureStrokeScratch() -> MTLTexture? {
        let targetW = Int(canvasSize.width)
        let targetH = Int(canvasSize.height)
        guard targetW > 0, targetH > 0 else { return nil }

        if let existing = strokeScratch,
           existing.width == targetW,
           existing.height == targetH {
            return existing
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: targetW, height: targetH,
            mipmapped: false
        )
        desc.storageMode = .private
        desc.usage = [.renderTarget, .shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else {
            return nil
        }
        #if DEBUG
        dbgLog("[EVE-AUDIT] STROKE_SCRATCH_ALLOC \(targetW)x\(targetH) storageMode=private") // EVE-RENDER-AUDIT-LOG
        #endif
        strokeScratch = tex
        return tex
    }

    /// Clear `strokeScratch` to (0, 0, 0, 0) by blit-copying from
    /// `atlasZeroBuffer` over the full scratch area. Encoded onto the
    /// caller's command buffer. Mirrors the existing
    /// `clearCanvasStagingAtlasRegion` pattern (same zero-buffer source,
    /// same blit primitive) but covers the entire scratch — wet-ink begins
    /// every stroke with a known-clean surface.
    ///
    /// Metal serialises encoders within a command buffer in submission
    /// order, so a subsequent render encoder on the same buffer with
    /// `loadAction = .load` reads the cleared scratch.
    ///
    /// Silently no-ops on allocation failure (renderer is degraded but
    /// not broken — the next stroke will retry).
    private func clearStrokeScratch(on commandBuffer: MTLCommandBuffer) {
        guard let scratch = ensureStrokeScratch(),
              let zeros = ensureAtlasZeroBuffer() else { return }
        let w = scratch.width
        let h = scratch.height
        let bytesPerRow = w * 4
        let bytesPerImage = bytesPerRow * h
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        #if DEBUG
        dbgLog("[EVE-AUDIT] STROKE_SCRATCH_CLEAR \(w)x\(h)") // EVE-RENDER-AUDIT-LOG
        #endif
        blit.copy(
            from: zeros,
            sourceOffset: 0,
            sourceBytesPerRow: bytesPerRow,
            sourceBytesPerImage: bytesPerImage,
            sourceSize: MTLSize(width: w, height: h, depth: 1),
            to: scratch,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
    }

    #if DEBUG
    /// Phase A sanity probe. NOT a correctness gate — Phase A.5 is the
    /// shader equivalence gate. This probe proves three things:
    ///
    ///   1. `strokeScratch` allocates at the current canvasSize.
    ///   2. `clearStrokeScratch` actually zeros it (corner pixel reads as
    ///      (0, 0, 0, 0) after the blit).
    ///   3. The scratch texture is render-target-capable: rendering one
    ///      brush stamp with the OLD (unmodified) `brushPipelineState`
    ///      produces non-zero output near the stamp center, within ±1 of
    ///      the predicted (0.5, 0.25, 0.75, 1.0) bgra8Unorm byte values
    ///      `(0xBF, 0x40, 0x80, 0xFF)`.
    ///
    /// Phase A does NOT yet modify shaders, blend modes, or any tool
    /// path — only the texture plumbing. Pass/fail is logged both to
    /// stdout (via the existing `print` channel) and to
    /// `Documents/wetink_phase_a.log` so a device run's results can be
    /// retrieved without a Xcode console attached. The log is
    /// append-only across runs.
    func runStrokeScratchPhaseAProbe() {
        let docsDir = FileManager.default.urls(for: .documentDirectory,
                                                in: .userDomainMask).first
        let logURL = docsDir?.appendingPathComponent("wetink_phase_a.log")

        func appendLog(_ text: String) {
            dbgLog("🧪 WETINK-A \(text)")
            guard let logURL = logURL else { return }
            let line = text + "\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        appendLog("=== Phase A probe @ \(stamp) ===")
        appendLog("canvasSize=\(Int(canvasSize.width))×\(Int(canvasSize.height))")

        guard let scratch = ensureStrokeScratch() else {
            appendLog("FAIL: ensureStrokeScratch returned nil")
            appendLog("=== Phase A probe complete FAIL ===")
            return
        }
        appendLog("strokeScratch alloc OK: \(scratch.width)×\(scratch.height) pixelFormat=\(scratch.pixelFormat.rawValue) storage=\(scratch.storageMode.rawValue) usage=\(scratch.usage.rawValue)")

        guard let atlas = ensureCanvasStagingAtlas() else {
            appendLog("FAIL: ensureCanvasStagingAtlas returned nil (needed for CPU readback)")
            appendLog("=== Phase A probe complete FAIL ===")
            return
        }

        guard let cb = commandQueue.makeCommandBuffer() else {
            appendLog("FAIL: makeCommandBuffer returned nil")
            appendLog("=== Phase A probe complete FAIL ===")
            return
        }

        clearStrokeScratch(on: cb)

        let stampCenterX = Int(canvasSize.width / 2)
        let stampCenterY = Int(canvasSize.height / 2)
        appendLog("stamp center planned at (\(stampCenterX), \(stampCenterY))")

        guard let pipeline = brushPipelineState else {
            appendLog("FAIL: brushPipelineState is nil")
            cb.commit()
            cb.waitUntilCompleted()
            appendLog("=== Phase A probe complete FAIL ===")
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = scratch
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        if let enc = cb.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(noMaskTexture, index: 2)

            var uniforms = BrushUniforms(
                color: UIColor(red: 0.5, green: 0.25, blue: 0.75, alpha: 1.0),
                size: 40,
                opacity: 1.0,
                hardness: 1.0,
                tileOrigin: SIMD2<Float>(0, 0),
                grainDensity: 0.5
            )
            uniforms.pressure = 1.0
            uniforms.pressureAlpha = 1.0

            var stampPosition = SIMD2<Float>(Float(stampCenterX), Float(stampCenterY))
            var viewportCopy = SIMD2<Float>(Float(scratch.width), Float(scratch.height))

            enc.setVertexBytes(&stampPosition, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 1)
            enc.setVertexBytes(&viewportCopy, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
            enc.endEncoding()
            appendLog("stamp encoded with OLD brushPipelineState: size=40 opacity=1.0 hardness=1.0 pressureAlpha=1.0 color=(R=0.5, G=0.25, B=0.75, A=1.0)")
        } else {
            appendLog("FAIL: makeRenderCommandEncoder for stamp encoding returned nil")
        }

        if let blit = cb.makeBlitCommandEncoder() {
            blit.copy(
                from: scratch,
                sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: scratch.width, height: scratch.height, depth: 1),
                to: atlas,
                destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        } else {
            appendLog("FAIL: makeBlitCommandEncoder for scratch→atlas readback path returned nil")
        }

        cb.commit()
        cb.waitUntilCompleted()

        // Corner pixel — must be (0, 0, 0, 0) after clearStrokeScratch.
        var cornerBytes = [UInt8](repeating: 0xFF, count: 4)   // sentinel
        let cornerRegion = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                     size: MTLSize(width: 1, height: 1, depth: 1))
        atlas.getBytes(&cornerBytes, bytesPerRow: 4, from: cornerRegion, mipmapLevel: 0)
        let cornerOK = cornerBytes == [0, 0, 0, 0]
        appendLog(String(format: "corner(0,0) bgra hex=(%02X, %02X, %02X, %02X) → \(cornerOK ? "PASS (cleared)" : "FAIL (not cleared)")",
                         cornerBytes[0], cornerBytes[1], cornerBytes[2], cornerBytes[3]))

        // 5×5 block around the stamp center.
        let blockSize = 5
        let halfBlock = blockSize / 2
        var stampBlock = [UInt8](repeating: 0, count: blockSize * blockSize * 4)
        let originX = max(0, stampCenterX - halfBlock)
        let originY = max(0, stampCenterY - halfBlock)
        let stampRegion = MTLRegion(
            origin: MTLOrigin(x: originX, y: originY, z: 0),
            size: MTLSize(width: blockSize, height: blockSize, depth: 1)
        )
        atlas.getBytes(&stampBlock, bytesPerRow: blockSize * 4, from: stampRegion, mipmapLevel: 0)

        let centerByteOffset = (halfBlock * blockSize + halfBlock) * 4
        let centerB = stampBlock[centerByteOffset + 0]
        let centerG = stampBlock[centerByteOffset + 1]
        let centerR = stampBlock[centerByteOffset + 2]
        let centerA = stampBlock[centerByteOffset + 3]
        let centerFloatR = Float(centerR) / 255.0
        let centerFloatG = Float(centerG) / 255.0
        let centerFloatB = Float(centerB) / 255.0
        let centerFloatA = Float(centerA) / 255.0

        // OLD brush shader at center: alpha=1.0, output=(R=0.5, G=0.25, B=0.75, A=1.0)
        // bgra8Unorm bytes: B=round(0.75*255)=191=0xBF, G=64=0x40, R=128=0x80, A=255=0xFF.
        let predictedB: UInt8 = 191
        let predictedG: UInt8 = 64
        let predictedR: UInt8 = 128
        let predictedA: UInt8 = 255
        let tolerance: Int = 1
        func near(_ a: UInt8, _ b: UInt8) -> Bool { abs(Int(a) - Int(b)) <= tolerance }
        let centerOK = near(centerB, predictedB) &&
                       near(centerG, predictedG) &&
                       near(centerR, predictedR) &&
                       near(centerA, predictedA)

        appendLog(String(format: "center(\(originX + halfBlock),\(originY + halfBlock)) bgra hex=(%02X, %02X, %02X, %02X)",
                         centerB, centerG, centerR, centerA))
        appendLog(String(format: "center RGBA float=(%.4f, %.4f, %.4f, %.4f)",
                         centerFloatR, centerFloatG, centerFloatB, centerFloatA))
        appendLog(String(format: "center predicted bgra=(%02X, %02X, %02X, %02X) tol=±\(tolerance) → \(centerOK ? "PASS" : "FAIL")",
                         predictedB, predictedG, predictedR, predictedA))

        // Full 5×5 hex dump for the log (small, cheap, useful when something's off).
        var dump = "5×5 block hex (BGRA per pixel, row-major):"
        for row in 0..<blockSize {
            var rowStr = "\n  row \(row):"
            for col in 0..<blockSize {
                let off = (row * blockSize + col) * 4
                rowStr += String(format: " %02X%02X%02X%02X",
                                 stampBlock[off + 0],
                                 stampBlock[off + 1],
                                 stampBlock[off + 2],
                                 stampBlock[off + 3])
            }
            dump += rowStr
        }
        appendLog(dump)

        let overall = cornerOK && centerOK
        appendLog("=== Phase A probe complete \(overall ? "PASS" : "FAIL") ===")
        appendLog("log path: \(logURL?.path ?? "<no docs dir>")")
    }

    /// Phase A.5 shader-equivalence pre-flight. For each of the 5
    /// additive-family tools (brush, pencil, marker, airbrush,
    /// charcoal), render one stamp via the OLD shader+pipeline pair
    /// (non-premultiplied output + `.sourceAlpha`/`.oneMinusSourceAlpha`
    /// RGB blend), then render the same stamp via the NEW shader+pipeline
    /// pair (premultiplied output + `.one`/`.oneMinusSourceAlpha` RGB
    /// blend). Sample the stamp-center pixel from both, compare
    /// byte-exact. Run at slider opacity 1.0 AND 0.5 per tool.
    ///
    /// 12 readbacks total. Writes results to
    /// `Documents/wetink_phase_a5.log`. PASS = OLD bytes == NEW bytes
    /// channel-for-channel. Failure means the premul math diverged at
    /// some level (shader body, blend factors, or my translation of the
    /// math from §2.2 of the design doc). Phase B must NOT proceed
    /// without all 6 tools × 2 opacities passing.
    ///
    /// This is intentionally exhaustive at the shader level: Phase A
    /// only proved the scratch plumbing works; A.5 is what proves the
    /// shader change is safe. See WET_INK_DESIGN.md §2.10 Phase A.5.
    func runShaderEquivalencePhaseA5Probe() {
        let docsDir = FileManager.default.urls(for: .documentDirectory,
                                                in: .userDomainMask).first
        let logURL = docsDir?.appendingPathComponent("wetink_phase_a5.log")

        func appendLog(_ text: String) {
            dbgLog("🧪 WETINK-A5 \(text)")
            guard let logURL = logURL else { return }
            let line = text + "\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        appendLog("=== Phase A.5 shader-equivalence probe @ \(stamp) ===")
        appendLog("canvasSize=\(Int(canvasSize.width))×\(Int(canvasSize.height))")

        guard let atlas = ensureCanvasStagingAtlas() else {
            appendLog("FAIL: ensureCanvasStagingAtlas returned nil")
            appendLog("=== Phase A.5 probe complete FAIL (setup) ===")
            return
        }

        let stampCenterX = Int(canvasSize.width / 2)
        let stampCenterY = Int(canvasSize.height / 2)
        appendLog("stamp center planned at (\(stampCenterX), \(stampCenterY)); test uniforms: size=40, hardness=1.0, pressureAlpha=1.0, color=(R=0.5, G=0.25, B=0.75, A=1.0)")

        // Test matrix: (toolName, OLD pipeline, NEW pipeline).
        let testTools: [(String, MTLRenderPipelineState?, MTLRenderPipelineState?)] = [
            ("brush",    brushPipelineState,    brushPremulPipelineState),
            ("pencil",   pencilPipelineState,   pencilPremulPipelineState),
            ("marker",   markerPipelineState,   markerPremulPipelineState),
            ("airbrush", airbrushPipelineState, airbrushPremulPipelineState),
            ("charcoal", charcoalPipelineState, charcoalPremulPipelineState),
        ]
        let testOpacities: [Float] = [1.0, 0.5]

        // Helper closure — render one stamp at the canvas center using the
        // given pipeline + opacity on a freshly-cleared atlas, then return
        // the 4-byte BGRA at the stamp center. nil if any GPU step failed.
        func renderOneStampAndReadCenter(pipeline: MTLRenderPipelineState,
                                         opacity: Float) -> [UInt8]? {
            guard let cb = commandQueue.makeCommandBuffer() else { return nil }

            // Clear full atlas via blit-from-zero (same pattern as
            // strokeScratch clear; matches §2.4 of design doc).
            let fullAtlasRegion = MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: atlas.width, height: atlas.height, depth: 1)
            )
            clearCanvasStagingAtlasRegion(fullAtlasRegion, on: cb)

            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = atlas
            renderPassDescriptor.colorAttachments[0].loadAction = .load
            renderPassDescriptor.colorAttachments[0].storeAction = .store

            guard let enc = cb.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return nil }
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(noMaskTexture, index: 2)

            var uniforms = BrushUniforms(
                color: UIColor(red: 0.5, green: 0.25, blue: 0.75, alpha: 1.0),
                size: 40,
                opacity: opacity,
                hardness: 1.0,
                tileOrigin: SIMD2<Float>(0, 0),
                grainDensity: 0.5
            )
            uniforms.pressure = 1.0
            uniforms.pressureAlpha = 1.0

            var stampPosition = SIMD2<Float>(Float(stampCenterX), Float(stampCenterY))
            var viewportCopy = SIMD2<Float>(Float(atlas.width), Float(atlas.height))

            enc.setVertexBytes(&stampPosition, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 1)
            enc.setVertexBytes(&viewportCopy, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
            enc.endEncoding()

            cb.commit()
            cb.waitUntilCompleted()

            var bytes = [UInt8](repeating: 0xFF, count: 4)
            let region = MTLRegion(
                origin: MTLOrigin(x: stampCenterX, y: stampCenterY, z: 0),
                size: MTLSize(width: 1, height: 1, depth: 1)
            )
            atlas.getBytes(&bytes, bytesPerRow: 4, from: region, mipmapLevel: 0)
            return bytes
        }

        var totalTests = 0
        var passingTests = 0

        for (toolName, oldPipelineOpt, newPipelineOpt) in testTools {
            guard let oldPipeline = oldPipelineOpt,
                  let newPipeline = newPipelineOpt else {
                appendLog("\(toolName): SKIP (pipeline unavailable — OLD=\(oldPipelineOpt != nil) NEW=\(newPipelineOpt != nil))")
                continue
            }

            for opacity in testOpacities {
                totalTests += 1

                guard let oldBytes = renderOneStampAndReadCenter(pipeline: oldPipeline, opacity: opacity) else {
                    appendLog("\(toolName) opacity=\(opacity): FAIL (OLD render returned nil)")
                    continue
                }
                guard let newBytes = renderOneStampAndReadCenter(pipeline: newPipeline, opacity: opacity) else {
                    appendLog("\(toolName) opacity=\(opacity): FAIL (NEW render returned nil)")
                    continue
                }

                let pass = (oldBytes == newBytes)
                if pass { passingTests += 1 }

                let oldHex = String(format: "%02X%02X%02X%02X",
                                    oldBytes[0], oldBytes[1], oldBytes[2], oldBytes[3])
                let newHex = String(format: "%02X%02X%02X%02X",
                                    newBytes[0], newBytes[1], newBytes[2], newBytes[3])
                let oldFloat = String(format: "(%.4f, %.4f, %.4f, %.4f)",
                                      Float(oldBytes[2]) / 255.0,
                                      Float(oldBytes[1]) / 255.0,
                                      Float(oldBytes[0]) / 255.0,
                                      Float(oldBytes[3]) / 255.0)
                let newFloat = String(format: "(%.4f, %.4f, %.4f, %.4f)",
                                      Float(newBytes[2]) / 255.0,
                                      Float(newBytes[1]) / 255.0,
                                      Float(newBytes[0]) / 255.0,
                                      Float(newBytes[3]) / 255.0)

                appendLog("\(toolName) opacity=\(opacity): OLD bgra=\(oldHex) RGBA=\(oldFloat) | NEW bgra=\(newHex) RGBA=\(newFloat) → \(pass ? "PASS" : "FAIL")")
            }
        }

        appendLog("=== Phase A.5 probe complete: \(passingTests)/\(totalTests) PASS ===")
        appendLog("log path: \(logURL?.path ?? "<no docs dir>")")
    }

    /// Phase B max-blend deposit probe. Proves that brush stamps depositing
    /// into `strokeScratch` via the wet-ink `.max/.max` blend cap at the
    /// strongest single-stamp value per pixel — i.e. within-stroke
    /// overlapping stamps do NOT accumulate alpha.
    ///
    /// Test plan (5 cases, single sample point at canvas center):
    ///   1. baseline_0.5  — single stamp at opacity=0.5 → bytes_at_0.5
    ///   2. baseline_0.7  — single stamp at opacity=0.7 → bytes_at_0.7
    ///   3. double_0.5    — TWO stamps at opacity=0.5, same position →
    ///                       expect bytes == bytes_at_0.5 (no accumulation)
    ///   4. mixed_low_first  — stamps at 0.3 then 0.7 →
    ///                          expect bytes == bytes_at_0.7
    ///   5. mixed_high_first — stamps at 0.7 then 0.3 →
    ///                          expect bytes == bytes_at_0.7 (commutativity)
    ///
    /// Sample target is `strokeScratch` (not the atlas) — the deposit pass
    /// writes there directly. CPU readback path: blit scratch → atlas →
    /// `getBytes` (atlas is `.shared`).
    ///
    /// Stamps render with the wet-ink deposit pipeline (premul shader +
    /// `.max/.max` blend). Hardness=1.0 at canvas center so brush takes
    /// its explicit `if (hardness >= 0.99)` branch → alpha=1.0 before
    /// opacity multiplication. No ambiguity.
    ///
    /// Writes to `Documents/wetink_phase_b.log`.
    func runMaxBlendDepositPhaseBProbe() {
        let docsDir = FileManager.default.urls(for: .documentDirectory,
                                                in: .userDomainMask).first
        let logURL = docsDir?.appendingPathComponent("wetink_phase_b.log")

        func appendLog(_ text: String) {
            dbgLog("🧪 WETINK-B \(text)")
            guard let logURL = logURL else { return }
            let line = text + "\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        appendLog("=== Phase B max-blend deposit probe @ \(stamp) ===")
        appendLog("canvasSize=\(Int(canvasSize.width))×\(Int(canvasSize.height))")

        guard let scratch = ensureStrokeScratch() else {
            appendLog("FAIL: ensureStrokeScratch returned nil")
            appendLog("=== Phase B probe complete FAIL (setup) ===")
            return
        }
        guard let atlas = ensureCanvasStagingAtlas() else {
            appendLog("FAIL: ensureCanvasStagingAtlas returned nil")
            appendLog("=== Phase B probe complete FAIL (setup) ===")
            return
        }
        guard let depositPipeline = brushScratchDepositPipelineState else {
            appendLog("FAIL: brushScratchDepositPipelineState is nil")
            appendLog("=== Phase B probe complete FAIL (setup) ===")
            return
        }

        let stampCenterX = Int(canvasSize.width / 2)
        let stampCenterY = Int(canvasSize.height / 2)
        appendLog("stamp center planned at (\(stampCenterX), \(stampCenterY)); test color=(R=0.5, G=0.25, B=0.75, A=1.0), size=40, hardness=1.0")

        // Render N stamps at the SAME position with the given opacities,
        // each into a freshly-cleared scratch. After completion, blit
        // scratch → atlas, read 1 pixel at the stamp center.
        func renderStampsAndReadCenter(opacities: [Float]) -> [UInt8]? {
            guard let cb = commandQueue.makeCommandBuffer() else { return nil }

            clearStrokeScratch(on: cb)

            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = scratch
            renderPassDescriptor.colorAttachments[0].loadAction = .load
            renderPassDescriptor.colorAttachments[0].storeAction = .store

            guard let enc = cb.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return nil }
            enc.setRenderPipelineState(depositPipeline)
            enc.setFragmentTexture(noMaskTexture, index: 2)

            var stampPosition = SIMD2<Float>(Float(stampCenterX), Float(stampCenterY))
            var viewportCopy = SIMD2<Float>(Float(scratch.width), Float(scratch.height))

            for opacity in opacities {
                var uniforms = BrushUniforms(
                    color: UIColor(red: 0.5, green: 0.25, blue: 0.75, alpha: 1.0),
                    size: 40,
                    opacity: opacity,
                    hardness: 1.0,
                    tileOrigin: SIMD2<Float>(0, 0),
                    grainDensity: 0.5
                )
                uniforms.pressure = 1.0
                uniforms.pressureAlpha = 1.0

                enc.setVertexBytes(&stampPosition, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                enc.setVertexBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 1)
                enc.setVertexBytes(&viewportCopy, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
                enc.setFragmentBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
            }
            enc.endEncoding()

            // Blit scratch → atlas for CPU readback (atlas is .shared).
            // Only the stamp's bounding region needs blitting — a 64×64
            // square around center is well within the stamp's 40-pixel
            // size + small slack.
            guard let blit = cb.makeBlitCommandEncoder() else { return nil }
            let blitOriginX = max(0, stampCenterX - 32)
            let blitOriginY = max(0, stampCenterY - 32)
            let blitW = min(64, scratch.width - blitOriginX)
            let blitH = min(64, scratch.height - blitOriginY)
            blit.copy(
                from: scratch,
                sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: blitOriginX, y: blitOriginY, z: 0),
                sourceSize: MTLSize(width: blitW, height: blitH, depth: 1),
                to: atlas,
                destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: blitOriginX, y: blitOriginY, z: 0)
            )
            blit.endEncoding()

            cb.commit()
            cb.waitUntilCompleted()

            var bytes = [UInt8](repeating: 0xFF, count: 4)
            let region = MTLRegion(
                origin: MTLOrigin(x: stampCenterX, y: stampCenterY, z: 0),
                size: MTLSize(width: 1, height: 1, depth: 1)
            )
            atlas.getBytes(&bytes, bytesPerRow: 4, from: region, mipmapLevel: 0)
            return bytes
        }

        func hex(_ b: [UInt8]) -> String {
            return String(format: "%02X%02X%02X%02X", b[0], b[1], b[2], b[3])
        }
        func channelMax(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
            return [max(a[0], b[0]), max(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3])]
        }

        var totalTests = 0
        var passingTests = 0

        // Case 1: baseline_0.5
        totalTests += 1
        guard let bytes_at_0_5 = renderStampsAndReadCenter(opacities: [0.5]) else {
            appendLog("FAIL: case 1 (baseline_0.5) render returned nil")
            return
        }
        appendLog("case 1 baseline_0.5: bgra=\(hex(bytes_at_0_5))")
        passingTests += 1  // baseline always 'passes' — it's the reference

        // Case 2: baseline_0.7
        totalTests += 1
        guard let bytes_at_0_7 = renderStampsAndReadCenter(opacities: [0.7]) else {
            appendLog("FAIL: case 2 (baseline_0.7) render returned nil")
            return
        }
        appendLog("case 2 baseline_0.7: bgra=\(hex(bytes_at_0_7))")
        passingTests += 1

        // Case 3: double_0.5 — TWO stamps at opacity=0.5, same position.
        // Expect bytes == bytes_at_0.5 (max-blend with self = identity).
        totalTests += 1
        guard let bytes_double_0_5 = renderStampsAndReadCenter(opacities: [0.5, 0.5]) else {
            appendLog("FAIL: case 3 (double_0.5) render returned nil")
            return
        }
        let case3Pass = (bytes_double_0_5 == bytes_at_0_5)
        if case3Pass { passingTests += 1 }
        appendLog("case 3 double_0.5: bgra=\(hex(bytes_double_0_5)) expected=\(hex(bytes_at_0_5)) → \(case3Pass ? "PASS" : "FAIL (accumulation detected — blend is NOT .max)")")

        // Case 4: mixed_low_first — stamp at 0.3 then stamp at 0.7.
        // Expect bytes == bytes_at_0.7 (.max picks the higher).
        let bytes_at_0_3_only = renderStampsAndReadCenter(opacities: [0.3])
        let expectedMixed: [UInt8] = {
            guard let low = bytes_at_0_3_only else { return bytes_at_0_7 }
            return channelMax(low, bytes_at_0_7)
        }()
        appendLog("ref bytes_at_0_3: \(hex(bytes_at_0_3_only ?? [0,0,0,0])) → channel-max of (0.3, 0.7) = \(hex(expectedMixed))")

        totalTests += 1
        guard let bytes_mixed_low_first = renderStampsAndReadCenter(opacities: [0.3, 0.7]) else {
            appendLog("FAIL: case 4 (mixed_low_first) render returned nil")
            return
        }
        let case4Pass = (bytes_mixed_low_first == expectedMixed)
        if case4Pass { passingTests += 1 }
        appendLog("case 4 mixed_low_first [0.3, 0.7]: bgra=\(hex(bytes_mixed_low_first)) expected=\(hex(expectedMixed)) → \(case4Pass ? "PASS" : "FAIL")")

        // Case 5: mixed_high_first — reversed order. Same expected result
        // (max is commutative).
        totalTests += 1
        guard let bytes_mixed_high_first = renderStampsAndReadCenter(opacities: [0.7, 0.3]) else {
            appendLog("FAIL: case 5 (mixed_high_first) render returned nil")
            return
        }
        let case5Pass = (bytes_mixed_high_first == expectedMixed)
        if case5Pass { passingTests += 1 }
        appendLog("case 5 mixed_high_first [0.7, 0.3]: bgra=\(hex(bytes_mixed_high_first)) expected=\(hex(expectedMixed)) → \(case5Pass ? "PASS (commutative)" : "FAIL")")

        appendLog("=== Phase B probe complete: \(passingTests)/\(totalTests) PASS ===")
        appendLog("log path: \(logURL?.path ?? "<no docs dir>")")
    }

    /// Phase C wet-ink commit pipeline probe. Proves that the commit pass
    /// — full-canvas quad reading `strokeScratch` and premul-over blending
    /// into the atlas — produces "color B over color A = exactly color B"
    /// at full opacity. This is the simplest end-to-end test of the
    /// scratch → atlas commit step and the foundational acceptance
    /// criterion of the wet-ink design (§2.5 of WET_INK_DESIGN.md).
    ///
    /// Test plan (2 cases, both at slider opacity 1.0):
    ///   1. A=red, B=blue   → eyedrop overlap → expect blue exactly
    ///   2. A=blue, B=red   → eyedrop overlap → expect red exactly
    ///
    /// Per-case sequence:
    ///   a. Clear atlas → render A via OLD `brushPipelineState`.
    ///      Verify atlas[center] == A bytes.
    ///   b. Clear scratch → render B via `brushScratchDepositPipelineState`.
    ///      (Don't read scratch yet — leave it set up for commit.)
    ///   c. Run commit pass: full-canvas quad, source=scratch, target=atlas,
    ///      premul-over blend (`wetInkCommitPipelineState`).
    ///   d. Read atlas[center] → expect B bytes exactly.
    ///
    /// Writes to `Documents/wetink_phase_c.log`.
    func runCommitPipelinePhaseCProbe() {
        let docsDir = FileManager.default.urls(for: .documentDirectory,
                                                in: .userDomainMask).first
        let logURL = docsDir?.appendingPathComponent("wetink_phase_c.log")

        func appendLog(_ text: String) {
            dbgLog("🧪 WETINK-C \(text)")
            guard let logURL = logURL else { return }
            let line = text + "\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        appendLog("=== Phase C commit pipeline probe @ \(stamp) ===")
        appendLog("canvasSize=\(Int(canvasSize.width))×\(Int(canvasSize.height))")

        guard let scratch = ensureStrokeScratch() else {
            appendLog("FAIL: ensureStrokeScratch returned nil")
            appendLog("=== Phase C probe complete FAIL (setup) ===")
            return
        }
        guard let atlas = ensureCanvasStagingAtlas() else {
            appendLog("FAIL: ensureCanvasStagingAtlas returned nil")
            appendLog("=== Phase C probe complete FAIL (setup) ===")
            return
        }
        guard let oldBrush = brushPipelineState else {
            appendLog("FAIL: brushPipelineState is nil")
            appendLog("=== Phase C probe complete FAIL (setup) ===")
            return
        }
        guard let depositPipeline = brushScratchDepositPipelineState else {
            appendLog("FAIL: brushScratchDepositPipelineState is nil")
            appendLog("=== Phase C probe complete FAIL (setup) ===")
            return
        }
        guard let commitPipeline = wetInkCommitPipelineState else {
            appendLog("FAIL: wetInkCommitPipelineState is nil")
            appendLog("=== Phase C probe complete FAIL (setup) ===")
            return
        }

        let stampCenterX = Int(canvasSize.width / 2)
        let stampCenterY = Int(canvasSize.height / 2)

        // Render one stamp into `target` (either atlas or scratch) using
        // `pipeline` and the given color at full opacity, hardness 1.0.
        // Clears the target first via blit-from-zero.
        func renderStamp(into target: MTLTexture,
                         using pipeline: MTLRenderPipelineState,
                         color: UIColor) -> Bool {
            guard let cb = commandQueue.makeCommandBuffer() else { return false }

            // Clear via blit-from-zero (works whether target is atlas or scratch).
            if let zeros = ensureAtlasZeroBuffer(),
               let blit = cb.makeBlitCommandEncoder() {
                blit.copy(
                    from: zeros,
                    sourceOffset: 0,
                    sourceBytesPerRow: target.width * 4,
                    sourceBytesPerImage: target.width * target.height * 4,
                    sourceSize: MTLSize(width: target.width, height: target.height, depth: 1),
                    to: target,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                blit.endEncoding()
            }

            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = target
            rp.colorAttachments[0].loadAction = .load
            rp.colorAttachments[0].storeAction = .store

            guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return false }
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(noMaskTexture, index: 2)

            var uniforms = BrushUniforms(
                color: color, size: 40, opacity: 1.0, hardness: 1.0,
                tileOrigin: SIMD2<Float>(0, 0), grainDensity: 0.5
            )
            uniforms.pressure = 1.0
            uniforms.pressureAlpha = 1.0

            var stampPosition = SIMD2<Float>(Float(stampCenterX), Float(stampCenterY))
            var viewportCopy = SIMD2<Float>(Float(target.width), Float(target.height))

            enc.setVertexBytes(&stampPosition, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 1)
            enc.setVertexBytes(&viewportCopy, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
            enc.endEncoding()

            cb.commit()
            cb.waitUntilCompleted()
            return true
        }

        // Run the commit pass: full-canvas quad sampling scratch, premul-over
        // into atlas. atlas is left with `loadAction = .load` so the pre-stroke
        // content (from the earlier OLD-brush stamp of color A) is preserved
        // under the blend.
        func runCommitPass() -> Bool {
            guard let cb = commandQueue.makeCommandBuffer() else { return false }

            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = atlas
            rp.colorAttachments[0].loadAction = .load
            rp.colorAttachments[0].storeAction = .store

            guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return false }
            enc.setRenderPipelineState(commitPipeline)
            enc.setFragmentTexture(scratch, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.endEncoding()

            cb.commit()
            cb.waitUntilCompleted()
            return true
        }

        func readCenterBytes(from texture: MTLTexture) -> [UInt8] {
            // For .private scratch, we can't getBytes directly. The probe
            // only reads from atlas (which is .shared) — caller is
            // responsible for ensuring the texture passed here is .shared.
            var bytes = [UInt8](repeating: 0xFF, count: 4)
            let region = MTLRegion(
                origin: MTLOrigin(x: stampCenterX, y: stampCenterY, z: 0),
                size: MTLSize(width: 1, height: 1, depth: 1)
            )
            texture.getBytes(&bytes, bytesPerRow: 4, from: region, mipmapLevel: 0)
            return bytes
        }

        func hex(_ b: [UInt8]) -> String {
            return String(format: "%02X%02X%02X%02X", b[0], b[1], b[2], b[3])
        }

        struct ColorCase {
            let name: String
            let colorA: UIColor
            let colorB: UIColor
            let expectedABytes: [UInt8]   // BGRA bytes of a full-opacity stamp of colorA via OLD brush
            let expectedBBytes: [UInt8]   // BGRA bytes of a full-opacity stamp of colorB after commit
        }

        // Full-opacity premultiplied bytes for pure red = (R=1, G=0, B=0, A=1)
        // → bgra8Unorm = (B=0x00, G=0x00, R=0xFF, A=0xFF)
        let redBytes: [UInt8] = [0x00, 0x00, 0xFF, 0xFF]
        // Pure blue = (R=0, G=0, B=1, A=1) → bgra8Unorm = (0xFF, 0x00, 0x00, 0xFF)
        let blueBytes: [UInt8] = [0xFF, 0x00, 0x00, 0xFF]

        let cases: [ColorCase] = [
            ColorCase(name: "A=red, B=blue",
                      colorA: UIColor(red: 1, green: 0, blue: 0, alpha: 1),
                      colorB: UIColor(red: 0, green: 0, blue: 1, alpha: 1),
                      expectedABytes: redBytes,
                      expectedBBytes: blueBytes),
            ColorCase(name: "A=blue, B=red",
                      colorA: UIColor(red: 0, green: 0, blue: 1, alpha: 1),
                      colorB: UIColor(red: 1, green: 0, blue: 0, alpha: 1),
                      expectedABytes: blueBytes,
                      expectedBBytes: redBytes),
        ]

        var totalTests = 0
        var passingTests = 0

        for c in cases {
            appendLog("--- Case: \(c.name) ---")

            // Step a: render A into atlas via OLD brush pipeline.
            guard renderStamp(into: atlas, using: oldBrush, color: c.colorA) else {
                appendLog("FAIL (\(c.name)): render A into atlas failed")
                continue
            }
            let afterABytes = readCenterBytes(from: atlas)
            let stepAPass = (afterABytes == c.expectedABytes)
            totalTests += 1
            if stepAPass { passingTests += 1 }
            appendLog("step a (A into atlas): bgra=\(hex(afterABytes)) expected=\(hex(c.expectedABytes)) → \(stepAPass ? "PASS" : "FAIL")")

            // Step b: render B into scratch via wet-ink deposit pipeline.
            // Don't read scratch directly (it's .private).
            guard renderStamp(into: scratch, using: depositPipeline, color: c.colorB) else {
                appendLog("FAIL (\(c.name)): render B into scratch failed")
                continue
            }

            // Step c: run the commit pass — scratch → atlas, premul-over.
            // Atlas still holds A from step a (loadAction=.load).
            guard runCommitPass() else {
                appendLog("FAIL (\(c.name)): commit pass failed")
                continue
            }

            // Step d: read atlas overlap pixel. Expect B exactly.
            let afterCommitBytes = readCenterBytes(from: atlas)
            let commitPass = (afterCommitBytes == c.expectedBBytes)
            totalTests += 1
            if commitPass { passingTests += 1 }
            appendLog("step d (after commit): bgra=\(hex(afterCommitBytes)) expected=\(hex(c.expectedBBytes)) → \(commitPass ? "PASS — B overwrites A exactly" : "FAIL — overlap is NOT exact B")")
        }

        appendLog("=== Phase C probe complete: \(passingTests)/\(totalTests) PASS ===")
        appendLog("log path: \(logURL?.path ?? "<no docs dir>")")
    }

    /// Phase D opacity-scaling end-to-end probe. Headline acceptance
    /// criterion of wet-ink: an N-overlap stroke at slider opacity 0.5
    /// produces visible alpha ~0.5, NOT saturating toward 1.0 like the
    /// OLD `.sourceAlpha` per-stamp blend would.
    ///
    /// Test plan (4 cases — each predicts BGRA bytes on paper FIRST,
    /// then verifies through the full wet-ink chain: deposit into
    /// strokeScratch via `.max/.max`, commit scratch → atlas via
    /// premul-over). All on canvas-center pixel, hardness=1.0.
    ///
    ///   1. Single stamp at opacity=0.5 on blank atlas. Sanity baseline.
    ///   2. TWO stamps at opacity=0.5 same position on blank atlas.
    ///      Tests that no-accumulation survives through commit.
    ///   3. Color B at opacity=0.5 committed over color A at opacity=1.0
    ///      pre-existing on atlas. Tests premul-over math at a partial
    ///      opacity boundary.
    ///   4. TEN stamps at opacity=0.5 same position on blank atlas.
    ///      Saturation-bug-fixed test. The OLD path saturates toward
    ///      1.0 (`1 - (1-0.5)^N` → 0.9990 at N=10); wet-ink stays at 0.5.
    ///
    /// Writes to `Documents/wetink_phase_d.log`. Predictions written to
    /// the log BEFORE measurements so the comparison is honest.
    func runOpacityScalingPhaseDProbe() {
        let docsDir = FileManager.default.urls(for: .documentDirectory,
                                                in: .userDomainMask).first
        let logURL = docsDir?.appendingPathComponent("wetink_phase_d.log")

        func appendLog(_ text: String) {
            dbgLog("🧪 WETINK-D \(text)")
            guard let logURL = logURL else { return }
            let line = text + "\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        appendLog("=== Phase D opacity-scaling probe @ \(stamp) ===")
        appendLog("canvasSize=\(Int(canvasSize.width))×\(Int(canvasSize.height))")
        appendLog("test color (testColor) = (R=0.5, G=0.25, B=0.75, A=1.0); hardness=1.0; size=40")
        appendLog("PREDICTIONS (paper math, declared before measurement):")
        appendLog("  Test 1 single 0.5 on blank: BGRA = 60 20 40 80")
        appendLog("  Test 2 two 0.5s on blank:   BGRA = 60 20 40 80 (no accumulation)")
        appendLog("  Test 3 blue 0.5 over red:   BGRA = 80 00 7F FF (±1 on R for rounding)")
        appendLog("  Test 4 ten 0.5s on blank:   BGRA = 60 20 40 80 (saturation-bug-fixed)")

        guard let scratch = ensureStrokeScratch() else {
            appendLog("FAIL: ensureStrokeScratch returned nil")
            appendLog("=== Phase D probe complete FAIL (setup) ===")
            return
        }
        guard let atlas = ensureCanvasStagingAtlas() else {
            appendLog("FAIL: ensureCanvasStagingAtlas returned nil")
            appendLog("=== Phase D probe complete FAIL (setup) ===")
            return
        }
        guard let oldBrush = brushPipelineState,
              let depositPipeline = brushScratchDepositPipelineState,
              let commitPipeline = wetInkCommitPipelineState else {
            appendLog("FAIL: required pipeline state is nil")
            appendLog("=== Phase D probe complete FAIL (setup) ===")
            return
        }

        let stampCenterX = Int(canvasSize.width / 2)
        let stampCenterY = Int(canvasSize.height / 2)

        func clearTexture(_ target: MTLTexture, on cb: MTLCommandBuffer) {
            guard let zeros = ensureAtlasZeroBuffer(),
                  let blit = cb.makeBlitCommandEncoder() else { return }
            blit.copy(
                from: zeros,
                sourceOffset: 0,
                sourceBytesPerRow: target.width * 4,
                sourceBytesPerImage: target.width * target.height * 4,
                sourceSize: MTLSize(width: target.width, height: target.height, depth: 1),
                to: target,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }

        // Render one stamp at canvas center with given color+opacity via
        // the given pipeline. Encoder reused across stamps when called in
        // a loop (caller manages cb / encoder lifecycle).
        func encodeStamp(_ enc: MTLRenderCommandEncoder,
                         target: MTLTexture,
                         color: UIColor,
                         opacity: Float) {
            var uniforms = BrushUniforms(
                color: color, size: 40, opacity: opacity, hardness: 1.0,
                tileOrigin: SIMD2<Float>(0, 0), grainDensity: 0.5
            )
            uniforms.pressure = 1.0
            uniforms.pressureAlpha = 1.0

            var stampPosition = SIMD2<Float>(Float(stampCenterX), Float(stampCenterY))
            var viewportCopy = SIMD2<Float>(Float(target.width), Float(target.height))

            enc.setVertexBytes(&stampPosition, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 1)
            enc.setVertexBytes(&viewportCopy, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
        }

        // Run a full end-to-end test case:
        //   1. Clear atlas (and optionally pre-paint A via OLD brush).
        //   2. Clear scratch.
        //   3. Deposit N stamps of `depositColor` at opacity `depositOpacity`
        //      via wet-ink deposit pipeline into scratch.
        //   4. Commit scratch → atlas via premul-over.
        //   5. Read atlas center.
        // Returns the BGRA bytes at the stamp center.
        func runEndToEnd(prePaintColor: UIColor?,
                         depositColor: UIColor,
                         depositOpacity: Float,
                         depositCount: Int) -> [UInt8]? {
            guard let cb1 = commandQueue.makeCommandBuffer() else { return nil }
            clearTexture(atlas, on: cb1)
            clearTexture(scratch, on: cb1)
            cb1.commit()
            cb1.waitUntilCompleted()

            // Optional pre-paint of A into atlas (OLD brush path).
            if let prePaintColor = prePaintColor {
                guard let cbA = commandQueue.makeCommandBuffer() else { return nil }
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = atlas
                rp.colorAttachments[0].loadAction = .load
                rp.colorAttachments[0].storeAction = .store
                guard let enc = cbA.makeRenderCommandEncoder(descriptor: rp) else { return nil }
                enc.setRenderPipelineState(oldBrush)
                enc.setFragmentTexture(noMaskTexture, index: 2)
                encodeStamp(enc, target: atlas, color: prePaintColor, opacity: 1.0)
                enc.endEncoding()
                cbA.commit()
                cbA.waitUntilCompleted()
            }

            // Deposit N stamps into scratch on one command buffer.
            guard let cbB = commandQueue.makeCommandBuffer() else { return nil }
            let rpScratch = MTLRenderPassDescriptor()
            rpScratch.colorAttachments[0].texture = scratch
            rpScratch.colorAttachments[0].loadAction = .load
            rpScratch.colorAttachments[0].storeAction = .store
            guard let encScratch = cbB.makeRenderCommandEncoder(descriptor: rpScratch) else { return nil }
            encScratch.setRenderPipelineState(depositPipeline)
            encScratch.setFragmentTexture(noMaskTexture, index: 2)
            for _ in 0..<depositCount {
                encodeStamp(encScratch, target: scratch, color: depositColor, opacity: depositOpacity)
            }
            encScratch.endEncoding()
            cbB.commit()
            cbB.waitUntilCompleted()

            // Commit scratch → atlas.
            guard let cbC = commandQueue.makeCommandBuffer() else { return nil }
            let rpCommit = MTLRenderPassDescriptor()
            rpCommit.colorAttachments[0].texture = atlas
            rpCommit.colorAttachments[0].loadAction = .load
            rpCommit.colorAttachments[0].storeAction = .store
            guard let encCommit = cbC.makeRenderCommandEncoder(descriptor: rpCommit) else { return nil }
            encCommit.setRenderPipelineState(commitPipeline)
            encCommit.setFragmentTexture(scratch, index: 0)
            encCommit.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encCommit.endEncoding()
            cbC.commit()
            cbC.waitUntilCompleted()

            // Read atlas center.
            var bytes = [UInt8](repeating: 0xFF, count: 4)
            let region = MTLRegion(
                origin: MTLOrigin(x: stampCenterX, y: stampCenterY, z: 0),
                size: MTLSize(width: 1, height: 1, depth: 1)
            )
            atlas.getBytes(&bytes, bytesPerRow: 4, from: region, mipmapLevel: 0)
            return bytes
        }

        func hex(_ b: [UInt8]) -> String {
            return String(format: "%02X%02X%02X%02X", b[0], b[1], b[2], b[3])
        }

        // Exact match for tests 1, 2, 4. ±1 tolerance per channel for test 3
        // (premul-over rounding asymmetry on the R byte).
        func bytesMatch(_ a: [UInt8], _ b: [UInt8], tolerance: Int = 0) -> Bool {
            guard a.count == b.count, a.count == 4 else { return false }
            for i in 0..<4 {
                if abs(Int(a[i]) - Int(b[i])) > tolerance { return false }
            }
            return true
        }

        let testColor = UIColor(red: 0.5, green: 0.25, blue: 0.75, alpha: 1.0)
        let red = UIColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        let blue = UIColor(red: 0.0, green: 0.0, blue: 1.0, alpha: 1.0)

        var totalTests = 0
        var passingTests = 0

        // --- Test 1 ---
        totalTests += 1
        let test1Predicted: [UInt8] = [0x60, 0x20, 0x40, 0x80]
        guard let test1Actual = runEndToEnd(prePaintColor: nil, depositColor: testColor, depositOpacity: 0.5, depositCount: 1) else {
            appendLog("Test 1 (single 0.5): FAIL — render returned nil")
            appendLog("=== Phase D probe complete FAIL ===")
            return
        }
        let test1Pass = bytesMatch(test1Actual, test1Predicted, tolerance: 0)
        if test1Pass { passingTests += 1 }
        appendLog("Test 1 single 0.5 on blank: actual=\(hex(test1Actual)) predicted=\(hex(test1Predicted)) → \(test1Pass ? "PASS" : "FAIL")")

        // --- Test 2 ---
        totalTests += 1
        let test2Predicted: [UInt8] = [0x60, 0x20, 0x40, 0x80]
        guard let test2Actual = runEndToEnd(prePaintColor: nil, depositColor: testColor, depositOpacity: 0.5, depositCount: 2) else {
            appendLog("Test 2 (two 0.5s): FAIL — render returned nil")
            appendLog("=== Phase D probe complete FAIL ===")
            return
        }
        let test2Pass = bytesMatch(test2Actual, test2Predicted, tolerance: 0)
        if test2Pass { passingTests += 1 }
        appendLog("Test 2 two 0.5s on blank:   actual=\(hex(test2Actual)) predicted=\(hex(test2Predicted)) → \(test2Pass ? "PASS — no accumulation through commit" : "FAIL — accumulation detected")")

        // --- Test 3 ---
        totalTests += 1
        let test3Predicted: [UInt8] = [0x80, 0x00, 0x7F, 0xFF]
        guard let test3Actual = runEndToEnd(prePaintColor: red, depositColor: blue, depositOpacity: 0.5, depositCount: 1) else {
            appendLog("Test 3 (blue 0.5 over red): FAIL — render returned nil")
            appendLog("=== Phase D probe complete FAIL ===")
            return
        }
        let test3Pass = bytesMatch(test3Actual, test3Predicted, tolerance: 1)
        if test3Pass { passingTests += 1 }
        appendLog("Test 3 blue 0.5 over red:   actual=\(hex(test3Actual)) predicted=\(hex(test3Predicted)) tol=±1 → \(test3Pass ? "PASS — premul-over math correct" : "FAIL")")

        // --- Test 4 ---
        totalTests += 1
        let test4Predicted: [UInt8] = [0x60, 0x20, 0x40, 0x80]
        guard let test4Actual = runEndToEnd(prePaintColor: nil, depositColor: testColor, depositOpacity: 0.5, depositCount: 10) else {
            appendLog("Test 4 (ten 0.5s): FAIL — render returned nil")
            appendLog("=== Phase D probe complete FAIL ===")
            return
        }
        let test4Pass = bytesMatch(test4Actual, test4Predicted, tolerance: 0)
        if test4Pass { passingTests += 1 }
        appendLog("Test 4 ten 0.5s on blank:   actual=\(hex(test4Actual)) predicted=\(hex(test4Predicted)) → \(test4Pass ? "PASS — SATURATION BUG FIXED" : "FAIL — stroke is saturating")")

        appendLog("=== Phase D probe complete: \(passingTests)/\(totalTests) PASS ===")
        appendLog("log path: \(logURL?.path ?? "<no docs dir>")")
    }
    #endif

    // MARK: - Wet-ink stroke lifecycle (live brush path, Phase D-integration)
    //
    // Replaces `renderStroke` for `.brush` strokes with a four-step lifecycle
    // proven byte-exact in Phases A → D:
    //
    //   touchesBegan  → beginWetInkStroke      (clears scratch, opens session)
    //   touchesMoved  → flushWetInkSubStroke   (deposits new stamps into
    //                                            scratch via .max/.max)
    //   draw(in:)     → encodeWetInkPreviewCompositeOntoIntermediate
    //                  (per-frame live preview of scratch over the active
    //                   layer's intermediate, via the same commit pipeline
    //                   used at touchesEnded — preview == eventual commit)
    //   touchesEnded  → commitWetInkStroke     (compose tiles into atlas,
    //                                            scratch → atlas via
    //                                            premul-over, blit modified
    //                                            atlas region back into tiles)
    //
    // Other tools (eraser, blur, smudge, pencil, marker, airbrush, charcoal,
    // shapes) still go through their existing paths in this iteration —
    // Phase E will extend the wet-ink lifecycle to cover them.

    /// In-progress wet-ink stroke. Nil when no stroke is active.
    private struct WetInkStrokeSession {
        let strokeID: UUID
        let tool: DrawingTool
        let settings: BrushSettings
        let layerId: UUID
        let tileGrid: TileGrid
        let selectionMask: MTLTexture
        // Bounding box of every stamp deposited so far in this stroke
        // (doc-pixel space). Grows on each flush; consumed at commit to
        // compute which tiles to compose / blit back.
        var accumulatedBbox: CGRect = .null
    }
    private var activeWetInkSession: WetInkStrokeSession?

    /// Layer id of the active wet-ink session, or nil when no stroke is in
    /// progress. Used by the live-display path (`MetalCanvasView.draw(in:)`)
    /// to decide which layer's composite needs the scratch overlay.
    var activeWetInkLayerId: UUID? {
        return activeWetInkSession?.layerId
    }

    /// Tool of the active wet-ink session, or nil when no stroke is in
    /// progress. Read by the live-display path to take the eraser-isolation
    /// carve-out (dest-out only produces the right pixels against a layer-
    /// isolated intermediate; the standard tile-direct preview path writes
    /// onto the fully-composited drawable).
    var activeWetInkTool: DrawingTool? {
        return activeWetInkSession?.tool
    }

    /// Begin a wet-ink stroke session.
    ///
    /// 1. Clears `strokeScratch` synchronously via blit-from-zero.
    /// 2. Rasterizes the selection mask (or 1×1 no-mask) once for the
    ///    duration of the stroke.
    /// 3. Stores session state.
    ///
    /// Returns false if scratch or the selection mask can't be set up —
    /// caller should fall back to the OLD path or skip the stroke.
    @discardableResult
    func beginWetInkStroke(strokeID: UUID,
                           tool: DrawingTool,
                           settings: BrushSettings,
                           layerId: UUID,
                           tileGrid: TileGrid,
                           selectionPath: [CGPoint]?,
                           documentSize: CGSize) -> Bool {
        activeWetInkSession = nil

        guard ensureStrokeScratch() != nil,
              let cb = commandQueue.makeCommandBuffer() else {
            dbgLog("⚠️ beginWetInkStroke: scratch or command buffer unavailable")
            return false
        }
        clearStrokeScratch(on: cb)
        cb.commit()
        cb.waitUntilCompleted()

        let mask = selectionMaskTexture(for: selectionPath, documentSize: documentSize) ?? noMaskTexture
        guard let selectionMask = mask else {
            dbgLog("⚠️ beginWetInkStroke: selection mask unavailable")
            return false
        }

        activeWetInkSession = WetInkStrokeSession(
            strokeID: strokeID,
            tool: tool,
            settings: settings,
            layerId: layerId,
            tileGrid: tileGrid,
            selectionMask: selectionMask,
            accumulatedBbox: .null
        )

        #if DEBUG
        CanvasStrokeDiagnostics.log("wetInkBegin stroke=\(CanvasStrokeDiagnostics.shortID(strokeID)) tool=\(tool) settings{\(CanvasStrokeDiagnostics.format(settings))}")
        #endif
        return true
    }

    /// Deposit a batch of stamps into `strokeScratch` via the wet-ink
    /// deposit pipeline (`.max/.max` blend on premultiplied output). Each
    /// stamp is drawn as a point sprite; selection clipping is applied by
    /// the fragment shader. Async commit — the deposit lands on the GPU
    /// before any subsequent draw of `strokeScratch`.
    ///
    /// Slot-acquired via `strokeCommandSlots` to match the back-pressure
    /// model `renderStroke` uses (cap of 60 in-flight stroke buffers).
    func flushWetInkSubStroke(stamps: [BrushStroke.StrokePoint], stampIndexBase: Int = 0) {
        guard !stamps.isEmpty,
              var session = activeWetInkSession,
              let scratch = ensureStrokeScratch() else { return }

        // Pick deposit pipeline by tool.
        //   - Eraser uses its alpha-only deposit shader; commit blends dest-out.
        //   - Each additive variant uses its premul fragment shader; commit
        //     blends premul-over.
        //   - Default (brush + shape tools that fall through) uses the brush
        //     premul deposit.
        let depositPipeline: MTLRenderPipelineState?
        switch session.tool {
        case .eraser:
            depositPipeline = eraserScratchDepositPipelineState
        case .pencil:
            depositPipeline = pencilScratchDepositPipelineState
        case .marker:
            depositPipeline = markerScratchDepositPipelineState
        case .airbrush:
            depositPipeline = airbrushScratchDepositPipelineState
        case .charcoal:
            depositPipeline = charcoalScratchDepositPipelineState
        case .watercolor:
            depositPipeline = watercolorScratchDepositPipelineState
        default:
            depositPipeline = brushScratchDepositPipelineState
        }
        guard let pipeline = depositPipeline else { return }

        // Update accumulated bbox.
        let radius = CGFloat(session.settings.size) / 2.0
        var batchBbox: CGRect = .null
        for p in stamps {
            let r = CGRect(x: p.location.x - radius,
                           y: p.location.y - radius,
                           width: radius * 2,
                           height: radius * 2)
            batchBbox = batchBbox.isNull ? r : batchBbox.union(r)
        }
        session.accumulatedBbox = session.accumulatedBbox.isNull
            ? batchBbox
            : session.accumulatedBbox.union(batchBbox)
        activeWetInkSession = session

        strokeCommandSlots.wait()
        guard let cb = commandQueue.makeCommandBuffer() else {
            strokeCommandSlots.signal()
            return
        }

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = scratch
        rp.colorAttachments[0].loadAction = .load
        rp.colorAttachments[0].storeAction = .store

        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else {
            strokeCommandSlots.signal()
            return
        }
        enc.setRenderPipelineState(pipeline)
        #if DEBUG
        dbgLog("[EVE-AUDIT] WETINK_DEPOSIT tool=\(session.tool) stamps=\(stamps.count) stroke=\(session.strokeID.uuidString.prefix(8))") // EVE-RENDER-AUDIT-LOG
        #endif
        enc.setFragmentTexture(session.selectionMask, index: 2)

        var uniforms = BrushUniforms(
            color: session.settings.color,
            size: Float(session.settings.size),
            opacity: Float(session.settings.opacity),
            hardness: Float(session.settings.hardness),
            tileOrigin: SIMD2<Float>(0, 0),
            grainDensity: session.settings.grainDensity
        )
        var viewportCopy = SIMD2<Float>(Float(scratch.width), Float(scratch.height))

        for (i, point) in stamps.enumerated() {
            let safePressure: CGFloat = {
                guard point.pressure.isFinite else { return 1.0 }
                return max(0, min(1, point.pressure))
            }()
            uniforms.pressure = Float(safePressure)
            let safePressureAlpha: CGFloat = {
                guard point.pressureAlpha.isFinite else { return 1.0 }
                return max(0, min(1, point.pressureAlpha))
            }()
            uniforms.pressureAlpha = Float(safePressureAlpha)
            uniforms.strokeDir = Self.strokeDirection(stamps, at: i)

            var position = SIMD2<Float>(Float(point.location.x), Float(point.location.y))

            #if DEBUG
            CanvasStrokeDiagnostics.log("stamp stage=wetInkDeposit stroke=\(CanvasStrokeDiagnostics.shortID(session.strokeID)) idx=\(stampIndexBase + i) tool=\(session.tool) \(CanvasStrokeDiagnostics.stampSource(point)) uniforms{\(CanvasStrokeDiagnostics.uniforms(size: uniforms.size, opacity: uniforms.opacity, hardness: uniforms.hardness, pressure: uniforms.pressure, pressureAlpha: uniforms.pressureAlpha, color: uniforms.color))}")
            #endif

            enc.setVertexBytes(&position, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 1)
            enc.setVertexBytes(&viewportCopy, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
        }
        enc.endEncoding()

        cb.addCompletedHandler { [weak self] _ in
            self?.strokeCommandSlots.signal()
        }
        cb.commit()
    }

    /// Commit the in-progress wet-ink stroke to the active layer's tile
    /// grid. Composes pre-stroke tile state for the accumulated bbox into
    /// `canvasStagingAtlas`, runs the commit pass (scratch → atlas via
    /// premul-over), blits modified atlas tiles back into the tile grid.
    /// Completion fires on main once the GPU pass finishes — that's the
    /// safe point to take an after-snapshot for undo.
    ///
    /// Clears `activeWetInkSession` immediately so the live-preview
    /// composite path no longer contributes. `strokeScratch` itself is
    /// left dirty until the next `beginWetInkStroke` (which clears it).
    func commitWetInkStroke(completion: (() -> Void)? = nil) {
        guard let session = activeWetInkSession,
              let scratch = ensureStrokeScratch(),
              let atlas = ensureCanvasStagingAtlas() else {
            activeWetInkSession = nil
            completion?()
            return
        }
        // Pick commit pipeline by tool. Additive tools blend premul-over
        // onto the layer; eraser blends dest-out (scaling layer pixels by
        // 1 - scratch.a).
        let commitPipelineOpt: MTLRenderPipelineState?
        switch session.tool {
        case .eraser:
            commitPipelineOpt = wetInkEraserCommitPipelineState
        default:
            commitPipelineOpt = wetInkCommitPipelineState
        }
        guard let commitPipeline = commitPipelineOpt else {
            activeWetInkSession = nil
            completion?()
            return
        }

        let bbox = session.accumulatedBbox
        let bboxKeys = (bbox.isNull || bbox.isEmpty)
            ? []
            : session.tileGrid.tilesIntersecting(bbox)
        let tileSize = session.tileGrid.tileSize
        let atlasW = atlas.width
        let atlasH = atlas.height

        #if DEBUG
        CanvasStrokeDiagnostics.log("wetInkCommit stroke=\(CanvasStrokeDiagnostics.shortID(session.strokeID)) tool=\(session.tool) bbox={\(CanvasStrokeDiagnostics.format(bbox))} bboxKeys=\(CanvasStrokeDiagnostics.tileSummary(bboxKeys))")
        #endif

        strokeCommandSlots.wait()
        guard let cb = commandQueue.makeCommandBuffer() else {
            strokeCommandSlots.signal()
            activeWetInkSession = nil
            completion?()
            return
        }

        // Step 1: clear bbox-tile-aligned atlas region (Source B fix —
        // wipes stale pixels at unallocated bbox tile positions so the
        // post-commit blit-back doesn't propagate them into freshly-
        // allocated tiles).
        if let clearRegion = atlasRegion(coveringTiles: bboxKeys, tileSize: tileSize) {
            clearCanvasStagingAtlasRegion(clearRegion, on: cb)
        }

        // Step 2: compose pre-stroke tile state for the bbox into atlas.
        if !bboxKeys.isEmpty, let composeBlit = cb.makeBlitCommandEncoder() {
            for key in bboxKeys {
                guard let tile = session.tileGrid.tile(at: key) else { continue }
                let dstX = key.x * tileSize
                let dstY = key.y * tileSize
                let copyW = min(tileSize, atlasW - dstX)
                let copyH = min(tileSize, atlasH - dstY)
                if copyW <= 0 || copyH <= 0 { continue }
                composeBlit.copy(
                    from: tile.texture,
                    sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                    to: atlas,
                    destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
                )
            }
            composeBlit.endEncoding()
        }

        // Step 3: commit pass — full-canvas quad reading scratch,
        // premul-over into atlas. Scratch is zero outside the stroke's
        // footprint so the blend is a no-op there.
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = atlas
        rp.colorAttachments[0].loadAction = .load
        rp.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: rp) {
            enc.setRenderPipelineState(commitPipeline)
            #if DEBUG
            dbgLog("[EVE-AUDIT] WETINK_COMMIT tool=\(session.tool) stroke=\(session.strokeID.uuidString.prefix(8))") // EVE-RENDER-AUDIT-LOG
            #endif
            enc.setFragmentTexture(scratch, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.endEncoding()
        }

        // Step 4: blit modified atlas tiles back into the tile grid.
        if !bboxKeys.isEmpty {
            for key in bboxKeys {
                _ = session.tileGrid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: cb)
            }
            if let blit = cb.makeBlitCommandEncoder() {
                for key in bboxKeys {
                    let srcX = key.x * tileSize
                    let srcY = key.y * tileSize
                    let blitW = min(tileSize, atlasW - srcX)
                    let blitH = min(tileSize, atlasH - srcY)
                    if blitW <= 0 || blitH <= 0 { continue }
                    session.tileGrid.updateTile(at: key) { tile in
                        blit.copy(
                            from: atlas,
                            sourceSlice: 0, sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                            sourceSize: MTLSize(width: blitW, height: blitH, depth: 1),
                            to: tile.texture,
                            destinationSlice: 0, destinationLevel: 0,
                            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                        )
                    }
                }
                blit.endEncoding()
            }
        }

        cb.addCompletedHandler { [weak self] _ in
            self?.strokeCommandSlots.signal()
            if let completion = completion {
                DispatchQueue.main.async { completion() }
            }
        }
        cb.commit()

        // Tear down session AFTER scheduling the commit so the preview
        // composite stops contributing immediately. Scratch stays as-is;
        // the next beginWetInkStroke clears it.
        activeWetInkSession = nil
    }

    /// Free the session without committing. For `touchesCancelled`. Scratch
    /// is left dirty; the next `beginWetInkStroke` clears it.
    func cancelWetInkStroke() {
        activeWetInkSession = nil
    }

    /// True iff there's currently an active wet-ink stroke. The live-display
    /// path uses this in concert with `activeWetInkLayerId` to decide
    /// whether to add the scratch composite to the active layer's render.
    var hasActiveWetInkStroke: Bool {
        return activeWetInkSession != nil
    }

    /// Composite `strokeScratch` on top of `tileDisplayIntermediate` using
    /// the wet-ink commit pipeline (premul-over for additive tools,
    /// dest-out for eraser). Called from the `draw(in:)` per-layer
    /// composite loop AFTER `encodeLayerTileCompositeOntoIntermediate`
    /// and BEFORE the layer's draw to the drawable. The result is that
    /// the user sees the in-progress wet-ink stroke composited correctly
    /// over the layer's committed tile state — bit-exact with the eventual
    /// touchesEnded commit (modulo the bbox limitation at commit, which
    /// is a no-op since scratch is zero outside the bbox).
    ///
    /// Under `FEATURE_TILE_DIRECT_RENDERING` this is still live on the
    /// active path for the eraser tool only. Additive tools render their
    /// preview directly onto the drawable via
    /// `encodeWetInkPreviewOntoDrawable` (premul-over is target-agnostic,
    /// works on the composite); eraser dest-out requires layer isolation
    /// and goes through this function. See the eraser carve-out at
    /// `MetalCanvasView.swift:draw(in:)`.
    func encodeWetInkPreviewCompositeOntoIntermediate(on commandBuffer: MTLCommandBuffer) {
        guard let session = activeWetInkSession,
              let intermediate = tileDisplayIntermediate,
              let scratch = strokeScratch else { return }
        // Same per-tool pipeline selection as the touchesEnded commit —
        // ensures the live preview matches the eventual commit.
        let pipelineOpt: MTLRenderPipelineState?
        switch session.tool {
        case .eraser:
            pipelineOpt = wetInkEraserCommitPipelineState
        default:
            pipelineOpt = wetInkCommitPipelineState
        }
        guard let pipeline = pipelineOpt else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = intermediate
        rp.colorAttachments[0].loadAction = .load
        rp.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(scratch, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()
    }

    /// Create a new texture for a layer
    func createLayerTexture() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        // Use .shared for CPU access (needed for undo/redo snapshots)
        // On iOS/macOS unified memory, this is efficient
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        // Clear the texture to transparent
        clearTexture(texture)

        return texture
    }

    /// Clear a texture to transparent
    private func clearTexture(_ texture: MTLTexture) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        renderEncoder.endEncoding()
        commandBuffer.commit()
        // Don't wait - this blocks the thread
    }

    /// Render a brush stroke to a texture
    /// Stroke coordinates are in screen space, need to be scaled to texture space
    /// Render a brush/eraser/shape stroke into a layer texture. PR 3 added
    /// `selectionPath`: when non-nil, the stroke is rasterized to a mask and
    /// every stamp's fragment alpha is multiplied by the mask sample. Pass
    /// nil to paint without clipping (default 1×1 `noMaskTexture` is bound).

    /// Bounding box of a brush stroke in document-pixel space, expanded by
    /// `stroke.settings.size / 2` to cover the full footprint of every
    /// stamp. Returns `.null` for an empty stroke, which `TileGrid.tilesIntersecting`
    /// turns into an empty key list.
    private func strokeBoundingBox(_ stroke: BrushStroke) -> CGRect {
        guard let first = stroke.points.first else { return .null }
        let radius = CGFloat(stroke.settings.size) / 2.0
        var minX = first.location.x - radius
        var minY = first.location.y - radius
        var maxX = first.location.x + radius
        var maxY = first.location.y + radius
        for p in stroke.points.dropFirst() {
            let px = p.location.x
            let py = p.location.y
            if px - radius < minX { minX = px - radius }
            if py - radius < minY { minY = py - radius }
            if px + radius > maxX { maxX = px + radius }
            if py + radius > maxY { maxY = py + radius }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func renderStroke(_ stroke: BrushStroke,
                      tileGrid: TileGrid,
                      screenSize: CGSize,
                      selectionPath: [CGPoint]?,
                      stampIndexBase: Int = 0,
                      completion: (() -> Void)? = nil) {
        #if DEBUG
        dbgLog("🎨 CanvasRenderer: Rendering stroke with \(stroke.points.count) points")
        dbgLog("  Screen size: \(screenSize.width)x\(screenSize.height)")
        dbgLog("  Canvas size: \(canvasSize.width)x\(canvasSize.height)")
        dbgLog("  Tool: \(stroke.tool)")
        dbgLog("  Brush color: \(stroke.settings.color)")
        dbgLog("  Brush size: \(stroke.settings.size)")
        #endif

        guard let atlas = ensureCanvasStagingAtlas() else {
            dbgLog("ERROR: renderStroke — failed to ensure staging atlas")
            completion?()
            return
        }

        // Phase 4.5c: compose tile state for the stroke bbox into the atlas
        // so the render encoder's loadAction=.load reads current pixel
        // state. After the render, the bbox tiles get blitted back from
        // the atlas. Bbox is computed before slot acquisition to keep the
        // critical section narrow.
        let bbox = strokeBoundingBox(stroke)
        let bboxKeys = tileGrid.tilesIntersecting(bbox)
        let tileSize = tileGrid.tileSize
        let atlasW = atlas.width
        let atlasH = atlas.height

        #if DEBUG
        CanvasStrokeDiagnostics.log("renderStroke enter stroke=\(CanvasStrokeDiagnostics.shortID(stroke.id)) tool=\(stroke.tool) \(CanvasStrokeDiagnostics.ranges(for: stroke.points)) bbox={\(CanvasStrokeDiagnostics.format(bbox))} bboxKeys=\(CanvasStrokeDiagnostics.tileSummary(bboxKeys)) allocatedBefore=\(CanvasStrokeDiagnostics.tileSummary(tileGrid.allocatedKeys())) settings{\(CanvasStrokeDiagnostics.format(stroke.settings))}")
        #endif

        // Acquire a stroke command-buffer slot. Blocks the caller (touch
        // loop) when the GPU has 60 stroke buffers in flight, releasing
        // as soon as one completes via the addCompletedHandler below.
        // Brief back-pressure under heavy load is the trade-off for
        // never silently dropping a stamp on Metal saturation.
        strokeCommandSlots.wait()

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            #if DEBUG
            dbgLog("CanvasRenderer: Failed to create command buffer")
            #endif
            strokeCommandSlots.signal()
            completion?()
            return
        }

        // Source B fix: clear the bbox-tile-aligned atlas region before
        // compose. The compose loop below only writes ALLOCATED tiles
        // (skips unallocated via `guard let tile = ... else { continue }`),
        // and the atlas retains stale pixels from prior dual-write callers
        // at unallocated tile positions. Without this clear, the render
        // encoder's loadAction=.load reads those stale pixels and blends
        // stamps over them, then the post-render blit-back persists the
        // pollution into freshly-allocated tiles.
        if let clearRegion = atlasRegion(coveringTiles: bboxKeys, tileSize: tileSize) {
            clearCanvasStagingAtlasRegion(clearRegion, on: commandBuffer)
        }

        // Compose-from-tiles into atlas (bbox-limited). Encoders within a
        // command buffer serialize, so the render encoder below sees the
        // post-compose atlas via Metal's automatic hazard tracking.
        if !bboxKeys.isEmpty, let composeBlit = commandBuffer.makeBlitCommandEncoder() {
            for key in bboxKeys {
                guard let tile = tileGrid.tile(at: key) else { continue }
                let dstX = key.x * tileSize
                let dstY = key.y * tileSize
                let copyW = min(tileSize, atlasW - dstX)
                let copyH = min(tileSize, atlasH - dstY)
                if copyW <= 0 || copyH <= 0 { continue }
                composeBlit.copy(
                    from: tile.texture,
                    sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                    to: atlas,
                    destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
                )
            }
            composeBlit.endEncoding()
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = atlas
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            #if DEBUG
            dbgLog("CanvasRenderer: Failed to create render encoder")
            #endif
            strokeCommandSlots.signal()
            completion?()
            return
        }

        // Select pipeline based on tool. Default brush, eraser, and shape
        // tools all share `brushPipelineState` (the shape tools dispatch
        // through their own renderer paths and never reach this branch);
        // the experimental brush variants each have their own pipeline
        // state with the matching fragment shader.
        let pipeline: MTLRenderPipelineState? = {
            switch stroke.tool {
            case .eraser:   return eraserPipelineState
            case .pencil:   return pencilPipelineState
            case .marker:   return markerPipelineState
            case .airbrush: return airbrushPipelineState
            case .charcoal: return charcoalPipelineState
            case .watercolor: return watercolorPipelineState
            default:        return brushPipelineState
            }
        }()
        guard let pipelineState = pipeline else {
            #if DEBUG
            dbgLog("CanvasRenderer: No pipeline state available")
            #endif
            renderEncoder.endEncoding()
            strokeCommandSlots.signal()
            completion?()
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        #if DEBUG
        dbgLog("CanvasRenderer: Pipeline set, rendering points...")
        #endif

        // Selection mask binding (PR 3). Rasterized once at stroke start and
        // bound once before the per-stamp loop — every stamp samples it.
        // `selectionMaskTexture` returns the 1×1 noMaskTexture when the
        // path is nil/empty, so the binding is always valid and cheap.
        let selectionMask = selectionMaskTexture(for: selectionPath, documentSize: screenSize) ?? noMaskTexture
        renderEncoder.setFragmentTexture(selectionMask, index: 2)

        // Prepare brush uniforms
        var uniforms = BrushUniforms(
            color: stroke.settings.color,
            size: Float(stroke.settings.size),
            opacity: Float(stroke.settings.opacity),
            hardness: Float(stroke.settings.hardness),
            tileOrigin: SIMD2<Float>(0, 0),
            grainDensity: stroke.settings.grainDensity
        )

        // CRITICAL FIX: Stroke points are already in document/canvas coordinate space.
        // The screenSize parameter is documentSize (which equals canvas size).
        // Points are already scaled correctly from screenToDocument(), so NO SCALING should be applied.
        #if DEBUG
        dbgLog("  Canvas size: \(canvasSize.width)x\(canvasSize.height)")
        dbgLog("  Document size passed: \(screenSize.width)x\(screenSize.height)")
        #endif

        // Document size and canvas size should be identical (both are the same square canvas)
        if abs(screenSize.width - canvasSize.width) > 1.0 || abs(screenSize.height - canvasSize.height) > 1.0 {
            dbgLog("  ⚠️ WARNING: Document size (\(screenSize)) doesn't match canvas size (\(canvasSize))")
            dbgLog("  This will cause stroke misalignment!")
        }

        // NO SCALING - points are already in canvas-pixel coordinate space
        let positions = stroke.points.map { point in
            SIMD2<Float>(
                Float(point.location.x),
                Float(point.location.y)
            )
        }
        let viewportSize = SIMD2<Float>(Float(atlasW), Float(atlasH))

        // Render each point as a brush stamp
        var viewportSizeCopy = viewportSize

        for (index, point) in stroke.points.enumerated() {
            // Sanitize pressure at the GPU boundary. Defense in depth —
            // touchesMoved already NaN-guards the interpolation, but a
            // history-restored stroke or future code path could feed us a
            // non-finite value and that would silently kill rendering for
            // the whole stroke (NaN → NaN pointSize → no draw).
            let safePressure: CGFloat = {
                guard point.pressure.isFinite else { return 1.0 }
                return max(0, min(1, point.pressure))
            }()
            uniforms.pressure = Float(safePressure)
            let safePressureAlpha: CGFloat = {
                guard point.pressureAlpha.isFinite else { return 1.0 }
                return max(0, min(1, point.pressureAlpha))
            }()
            uniforms.pressureAlpha = Float(safePressureAlpha)
            uniforms.strokeDir = Self.strokeDirection(stroke.points, at: index)

            // Copy position to avoid overlapping access
            var position = positions[index]
            #if DEBUG
            CanvasStrokeDiagnostics.log("stamp stage=renderStroke stroke=\(CanvasStrokeDiagnostics.shortID(stroke.id)) idx=\(stampIndexBase + index) tool=\(stroke.tool) \(CanvasStrokeDiagnostics.stampSource(point)) uniforms{\(CanvasStrokeDiagnostics.uniforms(size: uniforms.size, opacity: uniforms.opacity, hardness: uniforms.hardness, pressure: uniforms.pressure, pressureAlpha: uniforms.pressureAlpha, color: uniforms.color))}")
            #endif

            renderEncoder.setVertexBytes(&position, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 1)
            renderEncoder.setVertexBytes(&viewportSizeCopy, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)

            // Draw point sprite
            renderEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
        }

        renderEncoder.endEncoding()

        // === Phase 4.5c: blit modified bbox region from atlas → tile grid =
        //
        // After the stamp encoder finishes rasterising every point into
        // the atlas, blit the bbox tiles from atlas into the tile grid on
        // the SAME command buffer. Metal serialises encoders within a
        // buffer, so the blits run after the render pass and read the
        // post-render atlas pixels.
        //
        // Bit-exact by construction: every tile pixel is a direct copy of
        // the corresponding atlas pixel. Two-pass structure:
        //   Pass 1: ensureTileWithClearIfNeeded encodes a no-draw
        //           loadAction=.clear render pass for any freshly-allocated
        //           tile, on the same command buffer. Must run before the
        //           blit encoder opens — Metal allows only one active
        //           encoder per buffer at a time.
        //   Pass 2: a single blit encoder copies tile-sized regions of
        //           atlas into each tile.
        if !bboxKeys.isEmpty {
            for key in bboxKeys {
                _ = tileGrid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: commandBuffer)
            }
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                for key in bboxKeys {
                    let srcX = key.x * tileSize
                    let srcY = key.y * tileSize
                    let blitW = min(tileSize, atlasW - srcX)
                    let blitH = min(tileSize, atlasH - srcY)
                    if blitW <= 0 || blitH <= 0 { continue }

                    tileGrid.updateTile(at: key) { tile in
                        blit.copy(
                            from: atlas,
                            sourceSlice: 0, sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                            sourceSize: MTLSize(width: blitW, height: blitH, depth: 1),
                            to: tile.texture,
                            destinationSlice: 0, destinationLevel: 0,
                            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                        )
                    }
                }
                blit.endEncoding()
            }
        }
        // === End atlas → tile blit block =================================

        #if DEBUG
        CanvasStrokeDiagnostics.log("renderStroke scheduled stroke=\(CanvasStrokeDiagnostics.shortID(stroke.id)) tool=\(stroke.tool) allocatedAfter=\(CanvasStrokeDiagnostics.tileSummary(tileGrid.allocatedKeys()))")
        #endif

        if let completion = completion {
            // Async path: caller does its post-stroke work (snapshot, history,
            // thumbnail) inside `completion`, which fires on main once the GPU
            // pass is finished. Lets the touch loop / preview keep running
            // instead of stalling on `waitUntilCompleted` after every commit.
            // The slot signal happens INSIDE addCompletedHandler (on Metal's
            // completion callback queue) rather than waiting for the
            // dispatched main-thread block — that frees the slot the moment
            // the GPU finishes, which is what makes the cap actually breathe
            // under touch-loop pressure.
            commandBuffer.addCompletedHandler { [weak self] _ in
                self?.strokeCommandSlots.signal()
                DispatchQueue.main.async {
                    completion()
                }
            }
            commandBuffer.commit()
        } else {
            // Sync fallback for callers that need the texture readable
            // immediately on return. The async path above is preferred for
            // hot-path stroke commits — that's why the touchesEnded handler
            // passes a completion now.
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            strokeCommandSlots.signal()
        }
    }

    // Metal structure matching shader.
    //
    // `tileOrigin` is mandatory at the init call site even though every
    // current call site passes (0, 0): the missing-parameter shape forces
    // Phase 4 tile-bind sites to opt in explicitly, mirroring the
    // discipline of the shader-side `sampleSelectionMask` helper. A
    // forgotten tile-origin would silently corrupt layer-space lookups
    // (selection mask sampling, procedural grain seeds, canvas-sized
    // texture samples); making it positional and mandatory turns that
    // silent miss into a compile error.
    private struct BrushUniforms {
        var color: SIMD4<Float>
        var size: Float
        var opacity: Float
        var hardness: Float
        var pressure: Float
        var grainDensity: Float
        var tileOrigin: SIMD2<Float>
        // Trailing field (BLOCKER B fix). Drives fragment-side alpha
        // multiply (`alpha *= opacity * pressureAlpha`); decoupled from
        // `pressure` so the finger/mouse size-fudge 0.75 doesn't cap a
        // non-Pencil stroke's first-stamp alpha at 75%. Pencil sets it
        // equal to `pressure`; finger/mouse sets it to 1.0. Trailing
        // position preserves the C-ABI prefix for shaders that don't
        // reference this field (the ink pen, e.g.).
        var pressureAlpha: Float
        // Unit stroke-travel direction at this stamp (5.4). Marker +
        // watercolor band their fiber streaks perpendicular to it; all
        // other shaders ignore it. The float2 aligns to 8 → offset 56,
        // total size stays 64 — matching the MSL struct exactly, with
        // the C-ABI prefix unchanged for every existing shader. Stamp
        // loops set it via central difference over neighbor locations;
        // (1,0) when degenerate (single-point stroke / zero travel).
        var strokeDir: SIMD2<Float>

        init(color: UIColor,
             size: Float,
             opacity: Float,
             hardness: Float,
             tileOrigin: SIMD2<Float>,
             grainDensity: Float = 0.5) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            self.color = SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
            self.size = size
            self.opacity = opacity
            self.hardness = hardness
            self.pressure = 1.0
            self.grainDensity = grainDensity
            self.tileOrigin = tileOrigin
            self.pressureAlpha = 1.0
            self.strokeDir = SIMD2<Float>(1, 0)
        }
    }

    /// Unit stroke-travel direction at stamp `i`, central difference over
    /// neighboring stamp locations (doc space). Feeds
    /// `BrushUniforms.strokeDir` so marker/watercolor fiber streaks run
    /// along the stroke. (1,0) for degenerate cases (single stamp, zero
    /// travel). Symmetry-mirrored stamps appended after the originals get
    /// a wrong direction at the originals/mirror boundary — one stamp per
    /// batch, cosmetically invisible at streak band scale.
    private static func strokeDirection(_ points: [BrushStroke.StrokePoint], at i: Int) -> SIMD2<Float> {
        guard !points.isEmpty else { return SIMD2<Float>(1, 0) }
        let prev = points[max(0, min(i - 1, points.count - 1))].location
        let next = points[min(points.count - 1, i + 1)].location
        let dx = Float(next.x - prev.x)
        let dy = Float(next.y - prev.y)
        let len = (dx * dx + dy * dy).squareRoot()
        guard len.isFinite, len > 0.0001 else { return SIMD2<Float>(1, 0) }
        return SIMD2<Float>(dx / len, dy / len)
    }

    /// Composite all layers into a single image
    func compositeLayersToImage(layers: [DrawingLayer]) -> UIImage? {
        guard let finalTexture = compositeLayersToTexture(layers: layers) else {
            return nil
        }
        return textureToUIImage(finalTexture)
    }

    /// Composite all visible layers onto a fresh white-backed texture and
    /// return it. Used by export and the eyedropper. Output pixels have
    /// alpha = 1.0 and straight (not premultiplied) RGB equal to what the
    /// user sees on screen, since the white background is fully opaque.
    ///
    /// ARCHITECTURAL INVARIANT — DO NOT BREAK BY ADDING NEW SOURCES:
    /// This function reads only from the `layers` parameter. Reference
    /// images (`ReferenceImageManager.references`) are deliberately
    /// rendered as a SwiftUI overlay above MetalCanvasView and live
    /// outside the layer stack — they appear on screen, but they never
    /// enter this composite. That separation is what guarantees
    /// references aren't sent to the AI for critique, baked into saved
    /// drawings, or sampled by the eyedropper. If a future feature needs
    /// "what the user sees" (e.g., a share-screen flow), build a SEPARATE
    /// function — never modify this one to read from anywhere other than
    /// `layers`.
    func compositeLayersToTexture(layers: [DrawingLayer]) -> MTLTexture? {
        // Phase 3 Task 3.2: legacy monolithic-source composite body retired.
        // All callers (compositeLayersToImage / save / export / AI critique,
        // palette "Generate from canvas", eyedropper, CompositionAnalysisService)
        // now read from the tile grid via compositeLayersToTextureViaTiles.
        //
        // Bit-exactness with the legacy monolithic-source output was
        // established by Phase 3.1's composite verifier soak (renamed at
        // Phase 4.3a to verifyParallelDisplayMatchesMonolithic, deleted
        // at Phase 4.5a alongside all other verifier infrastructure).
        // Multi-layer load fix (commit 987153e) was the load-bearing
        // change that made tile-grid keyspace match monolithic content
        // at load time.
        return compositeLayersToTextureViaTiles(layers: layers)
    }

    /// Layout-matched twin of the Metal `TileCompositeUniforms` struct
    /// (Shaders.metal, Phase 3 tile composite). int4 + int2 = 24 bytes; the
    /// struct lays out identically on both sides because SIMD4<Int32> is
    /// 16-byte aligned and SIMD2<Int32> is 8-byte aligned.
    private struct TileCompositeUniformsCPU {
        var tileRect: SIMD4<Int32>
        var outputSize: SIMD2<Int32>
    }

    /// Phase 3 tile-based composite. Same contract as
    /// `compositeLayersToTexture` — white-backed canvas-sized output,
    /// straight RGB, alpha=1.0 — but the source for each visible layer is
    /// its `tileGrid` (sparse), not its `texture` (monolithic). Bit-exact
    /// with the monolithic-based composite given Phase 2's tile<->mono
    /// invariant: per-tile quads land on integer pixel boundaries, NEAREST
    /// sampler, same blend state.
    ///
    /// **Fallback for layers without a tile grid.** A visible layer that has
    /// `texture != nil` but `tileGrid == nil` is an invariant violation
    /// (Phase 2 pairs them at allocation), but if it happens the monolithic
    /// composite would draw its pixels — to preserve correctness this
    /// function draws the full layer texture as a single canvas-sized quad
    /// in that case. Logged in DEBUG so the violation surfaces.
    ///
    /// Phase 3 Task 3.1b; verifier wiring lands in 3.1c.
    func compositeLayersToTextureViaTiles(layers: [DrawingLayer]) -> MTLTexture? {
        guard let finalTexture = createLayerTexture() else { return nil }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = finalTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor),
              let tilePipeline = compositeTilePipelineState else {
            return nil
        }

        renderEncoder.setScissorRect(MTLScissorRect(
            x: 0, y: 0,
            width: finalTexture.width,
            height: finalTexture.height
        ))

        let outputSize = SIMD2<Int32>(Int32(finalTexture.width), Int32(finalTexture.height))

        renderEncoder.setRenderPipelineState(tilePipeline)

        let canvasW = finalTexture.width
        let canvasH = finalTexture.height

        for layer in layers where layer.isVisible {
            guard let grid = layer.tileGrid else { continue }
            var opacityValue = layer.opacity

            let tileSize = grid.tileSize
            let texW = canvasW
            let texH = canvasH

            // Iterate this layer's allocated tiles. Order within a layer
            // doesn't matter because tiles within a single layer don't
            // overlap (sparse grid by definition). Order BETWEEN layers
            // matches `layers` array order — that's what produces the
            // back-to-front alpha-over.
            for key in grid.allocatedKeys() {
                guard let tile = grid.tile(at: key) else { continue }
                let srcX = key.x * tileSize
                let srcY = key.y * tileSize
                let blitW = min(tileSize, texW - srcX)
                let blitH = min(tileSize, texH - srcY)
                if blitW <= 0 || blitH <= 0 { continue }

                var uniforms = TileCompositeUniformsCPU(
                    tileRect: SIMD4<Int32>(Int32(srcX), Int32(srcY), Int32(blitW), Int32(blitH)),
                    outputSize: outputSize
                )
                renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<TileCompositeUniformsCPU>.stride, index: 0)
                renderEncoder.setFragmentTexture(tile.texture, index: 0)
                renderEncoder.setFragmentBytes(&opacityValue, length: MemoryLayout<Float>.stride, index: 0)
                renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        renderEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return finalTexture
    }

    // Internal (was private until Phase 3 of the color system overhaul,
    // 2026-05-13). DrawingCanvasView calls it to compose a UIImage for
    // PaletteGenerator's "Generate from canvas" path. The implementation
    // is unchanged; widening the visibility is the only semantic delta.
    func textureToUIImage(_ texture: MTLTexture) -> UIImage? {
        let width = texture.width
        let height = texture.height
        let rowBytes = width * 4
        let length = rowBytes * height

        let bgraBytes = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: MemoryLayout<UInt8>.alignment)
        defer { bgraBytes.deallocate() }

        texture.getBytes(
            bgraBytes,
            bytesPerRow: rowBytes,
            from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                          size: MTLSize(width: width, height: height, depth: 1)),
            mipmapLevel: 0
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(
            data: bgraBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: rowBytes,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ),
        let cgImage = context.makeImage() else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    /// Lossless PNG bytes of a layer texture, alpha preserved.
    /// Used by the layered save flow (ONLINELAYERSTORE.md §3) to serialize
    /// each `DrawingLayer.texture` independently. Full-texture readback;
    /// see PERF_ISSUES.md item on `getBytes` cost.
    func layerPNGData(of texture: MTLTexture) -> Data? {
        textureToUIImage(texture)?.pngData()
    }

    /// Compose a layer's sparse tile grid into a canvas-sized intermediate
    /// and return the resulting UIImage as PNG bytes. Used by the layered-
    /// save path (ONLINELAYERSTORE.md) — no per-layer monolithic needed.
    func layerPNGData(fromTileGrid tileGrid: TileGrid) -> Data? {
        let canvasWidth = Int(tileGrid.canvasSize.width)
        let canvasHeight = Int(tileGrid.canvasSize.height)
        guard canvasWidth > 0, canvasHeight > 0 else { return nil }

        let intermDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: canvasWidth,
            height: canvasHeight,
            mipmapped: false
        )
        intermDesc.storageMode = .shared
        intermDesc.usage = [.renderTarget, .shaderRead]

        guard let intermediate = device.makeTexture(descriptor: intermDesc),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let tilePipeline = compositeTilePipelineState else {
            return nil
        }

        let composeDesc = MTLRenderPassDescriptor()
        composeDesc.colorAttachments[0].texture = intermediate
        composeDesc.colorAttachments[0].loadAction = .clear
        composeDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        composeDesc.colorAttachments[0].storeAction = .store

        guard let composeEnc = cmdBuf.makeRenderCommandEncoder(descriptor: composeDesc) else {
            return nil
        }

        composeEnc.setRenderPipelineState(tilePipeline)
        let outputSize = SIMD2<Int32>(Int32(canvasWidth), Int32(canvasHeight))
        let tileSize = tileGrid.tileSize
        var opacityValue: Float = 1.0

        for key in tileGrid.allocatedKeys() {
            guard let tile = tileGrid.tile(at: key) else { continue }
            let srcX = key.x * tileSize
            let srcY = key.y * tileSize
            let blitW = min(tileSize, canvasWidth - srcX)
            let blitH = min(tileSize, canvasHeight - srcY)
            if blitW <= 0 || blitH <= 0 { continue }

            var uniforms = TileCompositeUniformsCPU(
                tileRect: SIMD4<Int32>(Int32(srcX), Int32(srcY), Int32(blitW), Int32(blitH)),
                outputSize: outputSize
            )
            composeEnc.setVertexBytes(&uniforms, length: MemoryLayout<TileCompositeUniformsCPU>.stride, index: 0)
            composeEnc.setFragmentTexture(tile.texture, index: 0)
            composeEnc.setFragmentBytes(&opacityValue, length: MemoryLayout<Float>.stride, index: 0)
            composeEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        composeEnc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return textureToUIImage(intermediate)?.pngData()
    }

    /// Generate a thumbnail preview from a layer texture
    /// Phase 3 Task 3.3: tile-grid-sourced per-layer thumbnail.
    ///
    /// Composites the layer's sparse tile grid into a transient canvas-sized
    /// intermediate texture (transparent background — preserves layer
    /// transparency in the thumbnail), then delegates to
    /// `generateThumbnail(from:size:)` for the downsample. Output is
    /// visually equivalent to the monolithic-sourced thumbnail produced
    /// when given `layer.texture`.
    ///
    /// Uses the same per-tile composite pipeline as
    /// `compositeLayersToTextureViaTiles` (integer pixel coords, NEAREST
    /// sampler, alpha-over blend). After Phase 4 removes `layer.texture`,
    /// this is the only path to per-layer thumbnails.
    func generateThumbnail(fromTileGrid tileGrid: TileGrid?, size: CGSize) -> UIImage? {
        guard let tileGrid = tileGrid else { return nil }
        let canvasWidth = Int(tileGrid.canvasSize.width)
        let canvasHeight = Int(tileGrid.canvasSize.height)
        guard canvasWidth > 0, canvasHeight > 0 else { return nil }

        // Intermediate canvas-sized texture, transparent background.
        // Storage .private — GPU-only; the downsample reads it as a
        // shader input, no CPU readback needed at this stage.
        let intermDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: canvasWidth,
            height: canvasHeight,
            mipmapped: false
        )
        intermDesc.storageMode = .private
        intermDesc.usage = [.renderTarget, .shaderRead]

        guard let intermediate = device.makeTexture(descriptor: intermDesc),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let tilePipeline = compositeTilePipelineState else {
            return nil
        }

        let composeDesc = MTLRenderPassDescriptor()
        composeDesc.colorAttachments[0].texture = intermediate
        composeDesc.colorAttachments[0].loadAction = .clear
        composeDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        composeDesc.colorAttachments[0].storeAction = .store

        guard let composeEnc = cmdBuf.makeRenderCommandEncoder(descriptor: composeDesc) else {
            return nil
        }

        composeEnc.setRenderPipelineState(tilePipeline)
        let outputSize = SIMD2<Int32>(Int32(canvasWidth), Int32(canvasHeight))
        let tileSize = tileGrid.tileSize
        var opacityValue: Float = 1.0

        for key in tileGrid.allocatedKeys() {
            guard let tile = tileGrid.tile(at: key) else { continue }
            let srcX = key.x * tileSize
            let srcY = key.y * tileSize
            let blitW = min(tileSize, canvasWidth - srcX)
            let blitH = min(tileSize, canvasHeight - srcY)
            if blitW <= 0 || blitH <= 0 { continue }

            var uniforms = TileCompositeUniformsCPU(
                tileRect: SIMD4<Int32>(Int32(srcX), Int32(srcY), Int32(blitW), Int32(blitH)),
                outputSize: outputSize
            )
            composeEnc.setVertexBytes(&uniforms, length: MemoryLayout<TileCompositeUniformsCPU>.stride, index: 0)
            composeEnc.setFragmentTexture(tile.texture, index: 0)
            composeEnc.setFragmentBytes(&opacityValue, length: MemoryLayout<Float>.stride, index: 0)
            composeEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        composeEnc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return generateThumbnail(from: intermediate, size: size)
    }

    func generateThumbnail(from texture: MTLTexture, size: CGSize) -> UIImage? {
        // Create a smaller texture for the thumbnail
        let thumbnailSize = MTLSize(
            width: Int(size.width),
            height: Int(size.height),
            depth: 1
        )

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: thumbnailSize.width,
            height: thumbnailSize.height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]

        guard let thumbnailTexture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        // Render the full texture scaled down to thumbnail
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = thumbnailTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor),
              let pipeline = textureDisplayPipelineState else {
            return nil
        }

        renderEncoder.setRenderPipelineState(pipeline)
        renderEncoder.setFragmentTexture(texture, index: 0)
        var opacity: Float = 1.0
        renderEncoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        renderEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return textureToUIImage(thumbnailTexture)
    }

    /// Render a texture as a fullscreen quad with optional zoom and pan
    /// Draw an opaque white quad at the canvas position so the gray workbench
    /// doesn't bleed through transparent layer regions.
    func renderCanvasBackground(
        to renderEncoder: MTLRenderCommandEncoder,
        zoomScale: Float = 1.0,
        panOffset: SIMD2<Float> = SIMD2<Float>(0, 0),
        canvasRotation: Float = 0.0,
        viewportSize: SIMD2<Float> = SIMD2<Float>(0, 0),
        flipState: SIMD2<Float> = SIMD2<Float>(0, 0)
    ) {
        guard let tex = whiteTexture else { return }
        renderTextureToScreen(tex, to: renderEncoder, opacity: 1.0,
                              zoomScale: zoomScale, panOffset: panOffset,
                              canvasRotation: canvasRotation,
                              viewportSize: viewportSize,
                              flipState: flipState)
    }

    func renderTextureToScreen(
        _ texture: MTLTexture,
        to renderEncoder: MTLRenderCommandEncoder,
        opacity: Float = 1.0,
        zoomScale: Float = 1.0,
        panOffset: SIMD2<Float> = SIMD2<Float>(0, 0),
        canvasRotation: Float = 0.0,
        viewportSize: SIMD2<Float> = SIMD2<Float>(0, 0),
        flipState: SIMD2<Float> = SIMD2<Float>(0, 0)
    ) {
        // Always use the transform pipeline for consistency
        // Pass identity transform when zoom/pan/rotation is not active
        guard let pipelineState = textureDisplayWithTransformPipelineState else {
            dbgLog("ERROR: Transform pipeline state not available")
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setFragmentTexture(texture, index: 0)

        // Pass opacity to shader
        var opacityValue = opacity
        renderEncoder.setFragmentBytes(&opacityValue, length: MemoryLayout<Float>.stride, index: 0)

        // Pass zoom/pan/rotation transform to vertex shader (always required for transform pipeline)
        var transform = SIMD4<Float>(zoomScale, panOffset.x, panOffset.y, canvasRotation)
        renderEncoder.setVertexBytes(&transform, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)

        var viewport = viewportSize
        renderEncoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)

        // Pass fixed canvas size (2048x2048) to shader
        var canvas = SIMD2<Float>(Float(canvasSize.width), Float(canvasSize.height))
        renderEncoder.setVertexBytes(&canvas, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)

        // Pass flip state (each component 0 or 1) to shader. Buffer index 3
        // matches quadVertexShaderWithTransform's signature in Shaders.metal.
        var flip = flipState
        renderEncoder.setVertexBytes(&flip, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)

        // Draw fullscreen quad (6 vertices for 2 triangles)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// Encode a single render pass on `commandBuffer` that composites
    /// one layer's tile grid into `tileDisplayIntermediate` at
    /// opacity=1.0. The intermediate is cleared on load — any prior
    /// layer's content is wiped, so callers can call this per-layer
    /// in a loop and each invocation gives a fresh intermediate state
    /// containing exactly that layer's tile content.
    ///
    /// Caller responsibility: read the intermediate in a SUBSEQUENT
    /// render pass on the same command buffer. Metal's hazard tracking
    /// serializes the intermediate's write here against the read in
    /// the next render pass — no explicit `waitUntilCompleted` needed
    /// between layers when both compose and draw pass encoders live
    /// on the same cb.
    ///
    /// Per-tile composite uses opacity=1.0 by design: the intermediate
    /// holds raw layer pixels. Layer opacity is applied at the caller's
    /// draw step via `renderTextureToScreen(intermediate, opacity:
    /// layer.opacity, ...)`. This preserves the structural symmetry
    /// with the monolithic display path's
    /// `renderTextureToScreen(layer.texture, opacity: layer.opacity)`
    /// per-layer iteration — both paths apply the (quirky, alpha-only)
    /// shader opacity at the SAME blend step, which makes the parallel-
    /// display verifier bit-exact at tolerance=0 for all opacity values.
    ///
    /// Phase 4.3 H2 fix: replaces the broken `renderTileGridToScreen`
    /// (4.3b) whose single-cb model raced when called multiple times in
    /// a layer loop — the shared intermediate ended up holding the
    /// LAST-composed layer's content while all per-layer draws read it.
    /// The new per-render-pass-on-same-cb pattern relies on Metal
    /// hazard tracking to serialize compose-then-draw across layers.
    func encodeLayerTileCompositeOntoIntermediate(_ tileGrid: TileGrid,
                                                  visibleDocRect: CGRect? = nil,
                                                  on commandBuffer: MTLCommandBuffer) {
        guard let intermediate = ensureTileDisplayIntermediate() else {
            dbgLog("⚠️ encodeLayerTileCompositeOntoIntermediate: intermediate unavailable")
            return
        }
        encodeLayerCompositeIntoTexture(tileGrid,
                                        target: intermediate,
                                        visibleDocRect: visibleDocRect,
                                        on: commandBuffer)
    }

    /// Compose `tileGrid`'s allocated tiles into `target` via the per-tile
    /// composite pipeline. Bit-identical to the long-standing
    /// `encodeLayerTileCompositeOntoIntermediate` path, but parameterised
    /// over the destination texture so the layer-composite cache can
    /// supply its own pooled texture rather than always using the
    /// renderer-owned `tileDisplayIntermediate`.
    ///
    /// `target` must be a `.renderTarget`-usable `.bgra8Unorm` texture
    /// sized to `canvasSize`. The cache's `LayerCompositeCache` allocates
    /// matching textures; the renderer's own `tileDisplayIntermediate`
    /// also satisfies the contract.
    ///
    /// Same `loadAction = .clear (0,0,0,0)` semantics as the legacy path
    /// — unwritten regions stay transparent and contribute nothing when
    /// the result is later sampled by the drawable display draw.
    ///
    /// `visibleDocRect` performs the slice-4 viewport cull when supplied;
    /// nil = iterate all allocated tiles (the layer-composite cache's
    /// miss path passes nil so the cached intermediate captures the full
    /// content regardless of current viewport — see LayerCompositeCache
    /// doc comment for why).
    func encodeLayerCompositeIntoTexture(_ tileGrid: TileGrid,
                                         target: MTLTexture,
                                         visibleDocRect: CGRect? = nil,
                                         on commandBuffer: MTLCommandBuffer) {
        guard let tilePipeline = compositeTilePipelineState else {
            dbgLog("⚠️ encodeLayerCompositeIntoTexture: pipeline unavailable")
            return
        }

        let composeDesc = MTLRenderPassDescriptor()
        composeDesc.colorAttachments[0].texture = target
        composeDesc.colorAttachments[0].loadAction = .clear
        composeDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        composeDesc.colorAttachments[0].storeAction = .store

        guard let composeEnc = commandBuffer.makeRenderCommandEncoder(descriptor: composeDesc) else {
            dbgLog("⚠️ encodeLayerCompositeIntoTexture: failed to create encoder")
            return
        }
        composeEnc.setRenderPipelineState(tilePipeline)

        let canvasW = Int(canvasSize.width)
        let canvasH = Int(canvasSize.height)
        let outputSize = SIMD2<Int32>(Int32(canvasW), Int32(canvasH))
        let tileSize = tileGrid.tileSize
        var tileOpacity: Float = 1.0  // raw layer content; opacity applied at draw step

        // Slice-4 viewport cull when visibleDocRect is supplied. nil = all
        // allocated (export / cache-miss-into-cached-entry paths). See
        // tile-rendering-audit.md Tier B 6/7 for the two-tier rationale.
        let keysToCompose: [TileKey]
        if let rect = visibleDocRect {
            keysToCompose = tileGrid.tilesIntersecting(rect)
        } else {
            keysToCompose = tileGrid.allocatedKeys()
        }

        for key in keysToCompose {
            guard let tile = tileGrid.tile(at: key) else { continue }
            let srcX = key.x * tileSize
            let srcY = key.y * tileSize
            let blitW = min(tileSize, canvasW - srcX)
            let blitH = min(tileSize, canvasH - srcY)
            if blitW <= 0 || blitH <= 0 { continue }

            var uniforms = TileCompositeUniformsCPU(
                tileRect: SIMD4<Int32>(Int32(srcX), Int32(srcY), Int32(blitW), Int32(blitH)),
                outputSize: outputSize
            )
            composeEnc.setVertexBytes(&uniforms, length: MemoryLayout<TileCompositeUniformsCPU>.stride, index: 0)
            composeEnc.setFragmentTexture(tile.texture, index: 0)
            composeEnc.setFragmentBytes(&tileOpacity, length: MemoryLayout<Float>.stride, index: 0)
            composeEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        composeEnc.endEncoding()
    }

    // MARK: - Tile-direct rendering (Phase 6 / Tier C 9)

    /// Layout-matched twin of the Metal `TileDirectUniforms` struct in
    /// Shaders.metal. SIMD4<Int32> + SIMD2<Float> + SIMD4<Float> +
    /// SIMD2<Float> + SIMD2<Float> = 16 + 8 + 16 + 8 + 8 = 56 bytes; SIMD4
    /// alignment of 16 forces the trailing padding to a multiple of 16, so
    /// the stride may round up. We use MemoryLayout<...>.stride at the call
    /// site so the Metal binding picks up the actual stride.
    fileprivate struct TileDirectUniformsCPU {
        var tileRect: SIMD4<Int32>
        var canvasSize: SIMD2<Float>
        var transform: SIMD4<Float>   // [zoom, panX, panY, rotation]
        var viewportSize: SIMD2<Float>
        var flipState: SIMD2<Float>
    }

    /// Render `tileGrid`'s visible tiles directly to the drawable as a
    /// stream of transformed quads — one per tile, each sampling the
    /// tile's texture and applying the canvas-to-drawable transform at
    /// the vertex shader. Replaces the legacy per-layer compose +
    /// drawable-sample pair with a single per-layer pass; the
    /// canvas-sized `tileDisplayIntermediate` is no longer needed.
    ///
    /// **Open the render encoder yourself.** This function takes an
    /// existing render encoder (typically the drawable's render encoder
    /// from the per-layer loop) and appends draw calls to it. Same
    /// pattern as `renderTextureToScreen` etc. — caller owns the
    /// encoder lifecycle (loadAction, scissor, endEncoding).
    ///
    /// `visibleDocRect`: when non-nil, only tiles intersecting it are
    /// drawn (slice-4 viewport cull). nil = all allocated tiles (used
    /// by the verifier for "render full content" fixtures).
    ///
    /// `opacity` is applied as a fragment-shader alpha multiplier —
    /// matches the legacy layer-opacity application point.
    func encodeLayerTilesDirectlyToDrawable(
        _ tileGrid: TileGrid,
        to renderEncoder: MTLRenderCommandEncoder,
        opacity: Float,
        zoomScale: Float,
        panOffset: SIMD2<Float>,
        canvasRotation: Float,
        viewportSize: SIMD2<Float>,
        flipState: SIMD2<Float>,
        visibleDocRect: CGRect? = nil
    ) {
        guard let pipeline = tileDirectToDrawablePipelineState else {
            dbgLog("⚠️ encodeLayerTilesDirectlyToDrawable: pipeline unavailable")
            return
        }

        let canvasW = Int(canvasSize.width)
        let canvasH = Int(canvasSize.height)
        let tileSize = tileGrid.tileSize

        let keysToDraw: [TileKey]
        if let rect = visibleDocRect {
            keysToDraw = tileGrid.tilesIntersecting(rect)
        } else {
            keysToDraw = tileGrid.allocatedKeys()
        }
        if keysToDraw.isEmpty { return }

        renderEncoder.setRenderPipelineState(pipeline)
        var opacityValue = opacity

        for key in keysToDraw {
            guard let tile = tileGrid.tile(at: key) else { continue }
            let srcX = key.x * tileSize
            let srcY = key.y * tileSize
            let blitW = min(tileSize, canvasW - srcX)
            let blitH = min(tileSize, canvasH - srcY)
            if blitW <= 0 || blitH <= 0 { continue }

            var uniforms = TileDirectUniformsCPU(
                tileRect: SIMD4<Int32>(Int32(srcX), Int32(srcY), Int32(blitW), Int32(blitH)),
                canvasSize: SIMD2<Float>(Float(canvasW), Float(canvasH)),
                transform: SIMD4<Float>(zoomScale, Float(panOffset.x), Float(panOffset.y), canvasRotation),
                viewportSize: viewportSize,
                flipState: flipState
            )
            renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<TileDirectUniformsCPU>.stride, index: 0)
            renderEncoder.setFragmentTexture(tile.texture, index: 0)
            renderEncoder.setFragmentBytes(&opacityValue, length: MemoryLayout<Float>.stride, index: 0)
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    /// Composite `strokeScratch` on top of the drawable using the
    /// wet-ink commit pipeline (premul-over for additive tools, dest-out
    /// for eraser). Tile-direct equivalent of
    /// `encodeWetInkPreviewCompositeOntoIntermediate`: instead of
    /// compositing onto `tileDisplayIntermediate`, it draws onto the
    /// caller's drawable encoder directly with the canvas-to-drawable
    /// transform applied.
    ///
    /// The scratch is a full-canvas texture; we treat it as a single
    /// "tile" covering the entire canvas (tileRect = (0, 0, canvasW,
    /// canvasH)) and reuse `tileDirectVertexShader` for the transform.
    /// Same vertex shader as the per-tile direct pass; only fragment +
    /// blend state differ.
    ///
    /// No-op if no wet-ink session is active. Caller is responsible for
    /// invoking this AFTER the active layer's tiles are drawn (so the
    /// premul-over blend composites correctly on top) and BEFORE the
    /// layers above the active layer.
    func encodeWetInkPreviewOntoDrawable(
        to renderEncoder: MTLRenderCommandEncoder,
        zoomScale: Float,
        panOffset: SIMD2<Float>,
        canvasRotation: Float,
        viewportSize: SIMD2<Float>,
        flipState: SIMD2<Float>
    ) {
        guard let session = activeWetInkSession,
              let scratch = strokeScratch else { return }
        let pipelineOpt: MTLRenderPipelineState?
        switch session.tool {
        case .eraser:
            pipelineOpt = wetInkEraserCommitToDrawablePipelineState
        default:
            pipelineOpt = wetInkCommitToDrawablePipelineState
        }
        guard let pipeline = pipelineOpt else { return }

        let canvasW = Int(canvasSize.width)
        let canvasH = Int(canvasSize.height)

        renderEncoder.setRenderPipelineState(pipeline)
        #if DEBUG
        dbgLog("[EVE-AUDIT] WETINK_PREVIEW_DRAWABLE tool=\(session.tool)") // EVE-RENDER-AUDIT-LOG
        #endif
        // Treat the full-canvas scratch as a single tile covering the
        // entire canvas. tileDirectVertexShader's math handles the
        // canvas-fraction → drawable-NDC chain identically to a tile.
        var uniforms = TileDirectUniformsCPU(
            tileRect: SIMD4<Int32>(0, 0, Int32(canvasW), Int32(canvasH)),
            canvasSize: SIMD2<Float>(Float(canvasW), Float(canvasH)),
            transform: SIMD4<Float>(zoomScale, Float(panOffset.x), Float(panOffset.y), canvasRotation),
            viewportSize: viewportSize,
            flipState: flipState
        )
        renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<TileDirectUniformsCPU>.stride, index: 0)
        renderEncoder.setFragmentTexture(scratch, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// Set a scissor on the on-screen encoder that matches the canvas
    /// square's footprint on the drawable. Subsequent draws (background,
    /// references, layer composite, floating textures, stroke preview)
    /// are clipped to this rect so content rendered past the canvas —
    /// e.g. a floating selection dragged off-edge, or a floating-text
    /// box positioned partly outside — doesn't bleed onto the gray
    /// workbench area surrounding the canvas.
    ///
    /// Math mirrors `quadVertexShaderWithTransform` corner-by-corner so
    /// the scissor AABB exactly matches where the canvas pixels land on
    /// the drawable. Rotation produces a rotated quad, not an axis-
    /// aligned rect; we take the AABB of the four rotated corners,
    /// which slightly over-clips into the rotated-canvas-bounds corners
    /// (worst case √2× at 45°) but still bounds the bleed.
    ///
    /// `viewportPoints` is `view.bounds.size`; `drawableSize` is
    /// `view.drawableSize` (pixels). Scissor is set in drawable pixels.
    func setCanvasFootprintScissor(
        on encoder: MTLRenderCommandEncoder,
        drawableSize: CGSize,
        viewportPoints: CGSize,
        zoomScale: CGFloat,
        panOffset: CGPoint,
        canvasRotation: CGFloat,
        flipHorizontal: Bool,
        flipVertical: Bool
    ) {
        let vx = viewportPoints.width
        let vy = viewportPoints.height
        guard vx > 0, vy > 0, drawableSize.width > 0, drawableSize.height > 0 else {
            return
        }

        // Shader fit-to-longest in points: canvas square fills the longer
        // viewport dimension at zoom=1.
        let fitSize = max(vx, vy)
        let halfFit = fitSize * 0.5
        let cx = vx * 0.5
        let cy = vy * 0.5

        // Unit-canvas corners in Y-up viewport-pts space (before zoom/
        // rotate/pan/flip), centered at viewport center.
        var corners: [(x: CGFloat, y: CGFloat)] = [
            (-halfFit, -halfFit), ( halfFit, -halfFit),
            (-halfFit,  halfFit), ( halfFit,  halfFit),
        ]
        // Apply zoom around (0,0), then rotate around (0,0), then re-anchor
        // at viewport center, then pan, then flip — same order as the
        // shader's screenPos math.
        let cosT = cos(canvasRotation)
        let sinT = sin(canvasRotation)
        for i in corners.indices {
            var x = corners[i].x * zoomScale
            var y = corners[i].y * zoomScale
            let rx = x * cosT - y * sinT
            let ry = x * sinT + y * cosT
            x = rx + cx
            y = ry + cy
            // Pan: x += pan.x, y -= pan.y (shader flips pan.y because
            // screenPos here is Y-up but pan is in UIKit Y-down pts).
            x += panOffset.x
            y -= panOffset.y
            if flipHorizontal { x = vx - x }
            if flipVertical   { y = vy - y }
            corners[i] = (x, y)
        }

        // Convert Y-up viewport-pts corners → Y-down drawable-pixel
        // coords. pointToPixel scales x/y identically since drawableSize
        // == bounds * contentScaleFactor on both axes.
        let scaleX = drawableSize.width / vx
        let scaleY = drawableSize.height / vy
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for c in corners {
            let px = c.x * scaleX
            let py = (vy - c.y) * scaleY
            minX = min(minX, px); maxX = max(maxX, px)
            minY = min(minY, py); maxY = max(maxY, py)
        }

        // Clamp to drawable bounds. Floor mins, ceil maxes so the
        // scissor never crops a partially-covered pixel on the canvas
        // edge.
        let dx = drawableSize.width
        let dy = drawableSize.height
        let x0 = Int(max(0, floor(minX)))
        let y0 = Int(max(0, floor(minY)))
        let x1 = Int(min(dx, ceil(maxX)))
        let y1 = Int(min(dy, ceil(maxY)))
        let w = max(0, x1 - x0)
        let h = max(0, y1 - y0)
        encoder.setScissorRect(MTLScissorRect(x: x0, y: y0, width: w, height: h))
    }

    // MARK: - Reference Image (back-canvas mode)

    /// Render a reference image as a screen-positioned textured quad.
    /// ONLY called from the to-screen draw path between the canvas's
    /// white-paper render and the layer composite. Strokes render on
    /// top because this pass paints first.
    ///
    /// ARCHITECTURAL INVARIANT (also documented at
    /// compositeLayersToTexture): this method is NEVER invoked by the
    /// save/AI/export composite path. Reference textures are passed
    /// directly here and never enter the `layers` array. The AI never
    /// sees references regardless of front-or-back mode.
    ///
    /// `center` and `displayedSize` are in DRAWABLE PIXELS (caller
    /// multiplies screen-points by contentScaleFactor).
    func renderReferenceBehindLayers(
        _ texture: MTLTexture,
        center: SIMD2<Float>,
        displayedSize: SIMD2<Float>,
        viewportSize: SIMD2<Float>,
        opacity: Float,
        flipX: Bool,
        flipY: Bool,
        rotation: Float,
        to renderEncoder: MTLRenderCommandEncoder,
    ) {
        guard let pipelineState = referenceQuadPipelineState else {
            dbgLog("⚠️ renderReferenceBehindLayers: pipeline state missing")
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setFragmentTexture(texture, index: 0)

        // Mirror layout matches Shaders.metal's ReferenceQuadUniforms.
        var uniforms = ReferenceQuadUniforms(
            center: center,
            halfSize: SIMD2<Float>(displayedSize.x * 0.5, displayedSize.y * 0.5),
            viewportSize: viewportSize,
            opacity: opacity,
            flipX: flipX ? -1.0 : 1.0,
            flipY: flipY ? -1.0 : 1.0,
            rotation: rotation,
        )
        renderEncoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<ReferenceQuadUniforms>.stride,
            index: 0,
        )

        var opacityValue = opacity
        renderEncoder.setFragmentBytes(
            &opacityValue,
            length: MemoryLayout<Float>.stride,
            index: 0,
        )

        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    // MARK: - Floating Selection Preview (move/rect/lasso drag)

    /// Render a floating-selection texture as a quad covering `docRect`.
    /// Uses the same zoom/pan/rotation transforms as the layer compositor, so
    /// the floating preview tracks the canvas exactly as it sits among the
    /// layers underneath. Caller is responsible for the layer ordering — call
    /// this AFTER the active layer (which has the selection's hole) so the
    /// floating pixels paint on top.
    ///
    /// `docRect` is in DOC space (UIKit Y-down). Move-tool whole-layer drag
    /// uses `(offset.x, offset.y, docW, docH)`; rect/lasso drags use
    /// `(originalRect.origin + offset, originalRect.size * scale)`.
    func renderFloatingTexture(
        _ texture: MTLTexture,
        atDocRect docRect: CGRect,
        rotation: Float = 0.0,
        to renderEncoder: MTLRenderCommandEncoder,
        opacity: Float = 1.0,
        zoomScale: Float = 1.0,
        panOffset: SIMD2<Float> = SIMD2<Float>(0, 0),
        canvasRotation: Float = 0.0,
        viewportSize: SIMD2<Float> = SIMD2<Float>(0, 0),
        flipState: SIMD2<Float> = SIMD2<Float>(0, 0)
    ) {
        guard let pipelineState = floatingTexturePipelineState else {
            dbgLog("ERROR: Floating texture pipeline state not available")
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setFragmentTexture(texture, index: 0)

        var op = opacity
        renderEncoder.setFragmentBytes(&op, length: MemoryLayout<Float>.stride, index: 0)

        var transform = SIMD4<Float>(zoomScale, panOffset.x, panOffset.y, canvasRotation)
        renderEncoder.setVertexBytes(&transform, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)

        var viewport = viewportSize
        renderEncoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)

        var canvas = SIMD2<Float>(Float(canvasSize.width), Float(canvasSize.height))
        renderEncoder.setVertexBytes(&canvas, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)

        var rect = SIMD4<Float>(Float(docRect.origin.x), Float(docRect.origin.y),
                                Float(docRect.width), Float(docRect.height))
        renderEncoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)

        var rot = rotation
        renderEncoder.setVertexBytes(&rot, length: MemoryLayout<Float>.stride, index: 4)

        // Buffer index 5 — matches quadVertexShaderForRect's signature.
        var flip = flipState
        renderEncoder.setVertexBytes(&flip, length: MemoryLayout<SIMD2<Float>>.stride, index: 5)

        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// Composite a floating selection texture INTO a layer texture at `docRect`,
    /// using the same premultiplied source-over blend as on-screen display.
    /// Use this on commit (release) to bake the moved selection into the layer
    /// in a single GPU pass — replaces the per-frame CPU Porter-Duff loop.
    ///
    /// `docRect` is in doc space; the layer's texture is treated as 1:1 with
    /// docSize (matching the rest of the codebase). zoom/pan/rotation are
    /// identity for the bake — we're writing into canvas-space, not screen.
    func compositeFloatingTextureIntoLayer(
        _ floating: MTLTexture,
        tileGrid: TileGrid,
        atDocRect docRect: CGRect,
        rotation: Float = 0.0
    ) {
        guard let pipelineState = floatingTexturePipelineState,
              let atlas = ensureCanvasStagingAtlas(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            dbgLog("ERROR: Cannot composite floating texture")
            return
        }

        let atlasW = atlas.width
        let atlasH = atlas.height
        let tileSize = tileGrid.tileSize

        // Convert doc rect into canvas-pixel rect for shader and bbox calc.
        let scale = CGFloat(atlasW) / canvasSize.width
        let pixelRect = CGRect(
            x: docRect.origin.x * scale,
            y: docRect.origin.y * scale,
            width: docRect.width * scale,
            height: docRect.height * scale
        )

        // Rotated AABB: rotate pixelRect's four corners by `rotation` radians
        // around the rect center, then take the axis-aligned bounding box of
        // the rotated corners. Matches the shader's R(-θ) sign convention
        // exactly so the tile-key set covers every pixel the shader could
        // touch. The `rotation == 0` early return is an optimization; the
        // math degenerates correctly when rotation is 0 (corners map to
        // themselves → AABB == pixelRect).
        let dirtyRect: CGRect = {
            if rotation == 0 { return pixelRect }
            let cx = pixelRect.midX
            let cy = pixelRect.midY
            let cosT = cos(CGFloat(rotation))
            let sinT = sin(CGFloat(rotation))
            let corners: [CGPoint] = [
                CGPoint(x: pixelRect.minX, y: pixelRect.minY),
                CGPoint(x: pixelRect.maxX, y: pixelRect.minY),
                CGPoint(x: pixelRect.minX, y: pixelRect.maxY),
                CGPoint(x: pixelRect.maxX, y: pixelRect.maxY),
            ]
            let rotated = corners.map { p -> CGPoint in
                let rx = p.x - cx
                let ry = p.y - cy
                return CGPoint(
                    x:  rx * cosT + ry * sinT + cx,
                    y: -rx * sinT + ry * cosT + cy
                )
            }
            let xs = rotated.map(\.x)
            let ys = rotated.map(\.y)
            let minX = xs.min()!
            let maxX = xs.max()!
            let minY = ys.min()!
            let maxY = ys.max()!
            return CGRect(x: minX, y: minY,
                          width: maxX - minX, height: maxY - minY)
        }()

        let tileKeys = tileGrid.tilesIntersecting(dirtyRect)

        // Source B fix: clear the rotated-AABB-tile-aligned atlas region
        // before compose. The dirty rect for composite-floating extends
        // outside the input docRect when rotation != 0; unallocated tiles
        // within that rotated extent must not carry stale pixels into the
        // shader's loadAction=.load read.
        if let clearRegion = atlasRegion(coveringTiles: tileKeys, tileSize: tileSize) {
            clearCanvasStagingAtlasRegion(clearRegion, on: commandBuffer)
        }

        // Compose tile state for the dirty bbox into the atlas so the
        // shader's loadAction=.load reads current layer pixels.
        if !tileKeys.isEmpty, let composeBlit = commandBuffer.makeBlitCommandEncoder() {
            for key in tileKeys {
                guard let tile = tileGrid.tile(at: key) else { continue }
                let dstX = key.x * tileSize
                let dstY = key.y * tileSize
                let copyW = min(tileSize, atlasW - dstX)
                let copyH = min(tileSize, atlasH - dstY)
                if copyW <= 0 || copyH <= 0 { continue }
                composeBlit.copy(
                    from: tile.texture,
                    sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                    to: atlas,
                    destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
                )
            }
            composeBlit.endEncoding()
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = atlas
        descriptor.colorAttachments[0].loadAction = .load   // preserve composed pixels
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(floating, index: 0)

        var opacity: Float = 1.0
        encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)

        // Identity transform — we render in canvas/doc space, viewport == atlas size.
        var transform = SIMD4<Float>(1.0, 0.0, 0.0, 0.0)
        encoder.setVertexBytes(&transform, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)

        var viewport = SIMD2<Float>(Float(atlasW), Float(atlasH))
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)

        var canvas = SIMD2<Float>(Float(atlasW), Float(atlasH))
        encoder.setVertexBytes(&canvas, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)

        var rect = SIMD4<Float>(
            Float(pixelRect.origin.x),
            Float(pixelRect.origin.y),
            Float(pixelRect.width),
            Float(pixelRect.height)
        )
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)

        var rot = rotation
        encoder.setVertexBytes(&rot, length: MemoryLayout<Float>.stride, index: 4)

        // Flip is identity here — we're baking into the layer's tiles in
        // canvas-space, where the user's display flip doesn't apply.
        var flip = SIMD2<Float>(0, 0)
        encoder.setVertexBytes(&flip, length: MemoryLayout<SIMD2<Float>>.stride, index: 5)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        // === Phase 4.5c: blit modified atlas region into tile grid ========
        if !tileKeys.isEmpty {
            for key in tileKeys {
                _ = tileGrid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: commandBuffer)
            }
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                for key in tileKeys {
                    let srcX = key.x * tileSize
                    let srcY = key.y * tileSize
                    let blitW = min(tileSize, atlasW - srcX)
                    let blitH = min(tileSize, atlasH - srcY)
                    if blitW <= 0 || blitH <= 0 { continue }

                    tileGrid.updateTile(at: key) { tile in
                        blit.copy(
                            from: atlas,
                            sourceSlice: 0, sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                            sourceSize: MTLSize(width: blitW, height: blitH, depth: 1),
                            to: tile.texture,
                            destinationSlice: 0, destinationLevel: 0,
                            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                        )
                    }
                }
                blit.endEncoding()
            }
        }
        // === End atlas → tile blit block =================================

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Translate a layer texture's pixels by an integer doc-space offset, in
    /// place. Pixels that fall outside the texture are dropped; vacated regions
    /// become transparent. Used by the move tool's whole-layer drag commit:
    /// during the drag we only update an offset uniform (no pixel writes),
    /// then this single GPU pass actually moves the bits when the user lets go.
    func translateLayerTextureInPlace(
        tileGrid: TileGrid,
        byDocOffset offset: CGPoint,
        screenSize: CGSize
    ) {
        guard let atlas = ensureCanvasStagingAtlas() else {
            dbgLog("ERROR: translate-in-place failed to ensure staging atlas")
            return
        }
        let atlasW = atlas.width
        let atlasH = atlas.height
        let scaleX = CGFloat(atlasW) / screenSize.width
        let scaleY = CGFloat(atlasH) / screenSize.height
        let dx = Int((offset.x * scaleX).rounded())
        let dy = Int((offset.y * scaleY).rounded())

        if dx == 0 && dy == 0 { return }

        let tileSize = tileGrid.tileSize
        let preTranslateKeys = tileGrid.allocatedKeys()

        // Temp scratch holds the pre-translate atlas content; we then
        // clear the atlas and blit the temp pixels into the atlas at the
        // shifted offset. Same algorithm as before, just relocated from
        // layer.texture to atlas.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: atlas.pixelFormat,
            width: atlasW,
            height: atlasH,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private

        guard let temp = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            dbgLog("ERROR: translate-in-place failed to allocate temp/command buffer")
            return
        }

        // Source B fix: clear the FULL atlas before compose. Translate
        // copies all-of-atlas into temp at step 2 (regardless of bbox),
        // then step 4 blits a shifted source region from temp back into
        // atlas. If atlas had stale pixels in unallocated tile regions
        // pre-compose, those stale pixels would land in temp, then in
        // the translated atlas, then in the post-translate tile grid.
        // Full-canvas clear required (not tile-aligned) because temp's
        // entire content is read by step 4's offset blit.
        let fullCanvasRegion = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: atlasW, height: atlasH, depth: 1)
        )
        clearCanvasStagingAtlasRegion(fullCanvasRegion, on: commandBuffer)

        // 1. Compose every allocated tile into the atlas at its canvas
        //    position so we have a current-content source to translate.
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            for key in preTranslateKeys {
                guard let tile = tileGrid.tile(at: key) else { continue }
                let dstX = key.x * tileSize
                let dstY = key.y * tileSize
                let copyW = min(tileSize, atlasW - dstX)
                let copyH = min(tileSize, atlasH - dstY)
                if copyW <= 0 || copyH <= 0 { continue }
                blit.copy(
                    from: tile.texture,
                    sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                    to: atlas,
                    destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
                )
            }
            blit.endEncoding()
        }

        // 2. Copy atlas → temp (so we can clear atlas and blit shifted
        //    pixels back without overwriting our source).
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: atlas,
                sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: atlasW, height: atlasH, depth: 1),
                to: temp,
                destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }

        // 3. Clear atlas to transparent.
        let clearDescriptor = MTLRenderPassDescriptor()
        clearDescriptor.colorAttachments[0].texture = atlas
        clearDescriptor.colorAttachments[0].loadAction = .clear
        clearDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        clearDescriptor.colorAttachments[0].storeAction = .store
        if let clearEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: clearDescriptor) {
            clearEncoder.endEncoding()
        }

        // 4. Blit temp → atlas at integer pixel offset, clipping the source
        //    region to the part that lands inside the destination.
        let srcX = max(0, -dx)
        let srcY = max(0, -dy)
        let dstX = max(0, dx)
        let dstY = max(0, dy)
        let copyW = max(0, min(atlasW - srcX, atlasW - dstX))
        let copyH = max(0, min(atlasH - srcY, atlasH - dstY))

        if copyW > 0, copyH > 0, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: temp,
                sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                to: atlas,
                destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
            )
            blit.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // === Phase 4.5c: blit translated atlas into tile grid ==============
        //
        // Result-then-mirror: post-translate pixels live in the atlas.
        // Mirror by:
        //   1. Compute post-translate destination key set: for each pre-
        //      translate allocated key K with pixel rect R_K, the content
        //      lands at R_K + (dx, dy). Union tilesIntersecting of each
        //      shifted rect (clamped to canvas).
        //   2. Drop all pre-translate allocations.
        //   3. For each post-translate key: ensureTile + blit the new
        //      key's pixel rect from post-translate atlas.
        if preTranslateKeys.isEmpty { return }

        var postSet = Set<TileKey>()
        for old in preTranslateKeys {
            let shifted = CGRect(
                x: old.x * tileSize + dx,
                y: old.y * tileSize + dy,
                width: tileSize,
                height: tileSize
            )
            for k in tileGrid.tilesIntersecting(shifted) {
                postSet.insert(k)
            }
        }

        for old in preTranslateKeys {
            tileGrid.dropTile(at: old)
        }

        if let mirrorBuf = commandQueue.makeCommandBuffer() {
            for newKey in postSet {
                _ = tileGrid.ensureTileWithClearIfNeeded(at: newKey, onCommandBuffer: mirrorBuf)
            }
            if let blit2 = mirrorBuf.makeBlitCommandEncoder() {
                for newKey in postSet {
                    let nx = newKey.x * tileSize
                    let ny = newKey.y * tileSize
                    let blitW = min(tileSize, atlasW - nx)
                    let blitH = min(tileSize, atlasH - ny)
                    if blitW <= 0 || blitH <= 0 { continue }

                    tileGrid.updateTile(at: newKey) { tile in
                        blit2.copy(
                            from: atlas,
                            sourceSlice: 0, sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: nx, y: ny, z: 0),
                            sourceSize: MTLSize(width: blitW, height: blitH, depth: 1),
                            to: tile.texture,
                            destinationSlice: 0, destinationLevel: 0,
                            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                        )
                    }
                }
                blit2.endEncoding()
            }
            mirrorBuf.commit()
            mirrorBuf.waitUntilCompleted()
        }
        // === End atlas → tile blit block =================================
    }

    /// Mirror a layer texture's pixel data about its center on the
    /// requested axes, in place. Used by the flip-canvas tool to bake
    /// the flip into pixels — after this returns, the layer's mirrored
    /// content is part of the layer's stored bitmap and no display-time
    /// transform is needed to keep it flipped. Subsequent rotation,
    /// pan, or zoom do not undo the flip.
    ///
    /// Implementation: copy the source layer into a temp texture, then
    /// render a fullscreen quad back into the original layer that
    /// samples from the temp and uses the existing transform-pipeline's
    /// flip math to mirror positions. All work runs on the GPU — no
    /// CPU readback. Pipeline: `textureDisplayWithTransformPipelineState`
    /// (vertex shader `quadVertexShaderWithTransform` already implements
    /// the canvas-flip mirror about viewport center, which lines up
    /// with texture-center for a 1:1 viewport).
    func flipLayerTextureInPlace(tileGrid: TileGrid,
                                  flipHorizontal: Bool,
                                  flipVertical: Bool) {
        if !flipHorizontal && !flipVertical { return }

        guard let atlas = ensureCanvasStagingAtlas() else {
            dbgLog("ERROR: flip-in-place failed to ensure staging atlas")
            return
        }

        let atlasW = atlas.width
        let atlasH = atlas.height
        let tileSize = tileGrid.tileSize
        let preFlipKeys = tileGrid.allocatedKeys()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: atlas.pixelFormat,
            width: atlasW,
            height: atlasH,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private

        guard let temp = device.makeTexture(descriptor: descriptor),
              let pipelineState = textureDisplayWithTransformPipelineState,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            dbgLog("ERROR: flip-in-place failed to allocate temp/pipeline/command buffer")
            return
        }

        // Source B fix: clear the FULL atlas before compose. Flip copies
        // atlas→temp at step 2 then the shader samples temp at flipped
        // UVs to write atlas at step 3. The fragment shader's sampler
        // can pull pixels across tile boundaries (linear interpolation
        // or fractional-UV off-by-one with NEAREST), so any stale pixels
        // in pre-compose atlas at unallocated tile regions could bleed
        // into the flipped output at allocated-tile boundaries. Full-
        // canvas clear required because the shader can sample anywhere
        // in temp.
        let fullCanvasRegion = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: atlasW, height: atlasH, depth: 1)
        )
        clearCanvasStagingAtlasRegion(fullCanvasRegion, on: commandBuffer)

        // 1. Compose every allocated tile into the atlas at its canvas
        //    position so the flip pass has current layer content as a
        //    source.
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            for key in preFlipKeys {
                guard let tile = tileGrid.tile(at: key) else { continue }
                let dstX = key.x * tileSize
                let dstY = key.y * tileSize
                let copyW = min(tileSize, atlasW - dstX)
                let copyH = min(tileSize, atlasH - dstY)
                if copyW <= 0 || copyH <= 0 { continue }
                blit.copy(
                    from: tile.texture,
                    sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                    to: atlas,
                    destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
                )
            }
            blit.endEncoding()
        }

        // 2. Blit atlas → temp so the render pass below has a sampleable
        //    source (it cannot read and write the same texture in one pass).
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: atlas, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: atlasW, height: atlasH, depth: 1),
                to: temp, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }

        // 3. Clear-and-render back into the atlas. The clear + standard
        //    source-over blend resolves to exactly the (flipped) source
        //    pixels.
        let renderDescriptor = MTLRenderPassDescriptor()
        renderDescriptor.colorAttachments[0].texture = atlas
        renderDescriptor.colorAttachments[0].loadAction = .clear
        renderDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderDescriptor) else {
            commandBuffer.commit()
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(temp, index: 0)

        var opacity: Float = 1.0
        encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)

        // Identity transform — no zoom, pan, rotation. The vertex shader
        // applies flip in screen-space relative to the viewport, which
        // here equals the atlas pixel size; mirror-about-viewport-center
        // becomes mirror-about-canvas-center.
        var transform = SIMD4<Float>(1.0, 0.0, 0.0, 0.0)
        encoder.setVertexBytes(&transform, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)

        var viewport = SIMD2<Float>(Float(atlasW), Float(atlasH))
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)

        var canvas = viewport
        encoder.setVertexBytes(&canvas, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)

        var flip = SIMD2<Float>(flipHorizontal ? 1 : 0, flipVertical ? 1 : 0)
        encoder.setVertexBytes(&flip, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // === Phase 4.5c: re-key + blit flipped atlas into tile grid =====
        //
        // Result-then-mirror: after the atlas flip lands, the post-flip
        // pixels live at canvas coordinates the post-flip canvas should
        // show. Tile grid mirror:
        //   1. Bijective re-key: (tx, ty) → (gridW-1-tx, ty) for H-flip,
        //      (tx, gridH-1-ty) for V-flip, both for HV.
        //   2. Drop every pre-flip allocation.
        //   3. For each post-flip key: ensureTile, then blit the new key's
        //      pixel rect from the post-flip atlas into the tile.
        if preFlipKeys.isEmpty { return }

        let gridW = tileGrid.gridWidth
        let gridH = tileGrid.gridHeight

        let postFlipKeys: [TileKey] = preFlipKeys.map { old in
            TileKey(
                x: flipHorizontal ? (gridW - 1 - old.x) : old.x,
                y: flipVertical   ? (gridH - 1 - old.y) : old.y
            )
        }

        for old in preFlipKeys {
            tileGrid.dropTile(at: old)
        }

        if let mirrorBuf = commandQueue.makeCommandBuffer() {
            for newKey in postFlipKeys {
                _ = tileGrid.ensureTileWithClearIfNeeded(at: newKey, onCommandBuffer: mirrorBuf)
            }
            if let blit = mirrorBuf.makeBlitCommandEncoder() {
                for newKey in postFlipKeys {
                    let nx = newKey.x * tileSize
                    let ny = newKey.y * tileSize
                    let blitW = min(tileSize, atlasW - nx)
                    let blitH = min(tileSize, atlasH - ny)
                    if blitW <= 0 || blitH <= 0 { continue }

                    tileGrid.updateTile(at: newKey) { tile in
                        blit.copy(
                            from: atlas,
                            sourceSlice: 0, sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: nx, y: ny, z: 0),
                            sourceSize: MTLSize(width: blitW, height: blitH, depth: 1),
                            to: tile.texture,
                            destinationSlice: 0, destinationLevel: 0,
                            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                        )
                    }
                }
                blit.endEncoding()
            }
            mirrorBuf.commit()
            mirrorBuf.waitUntilCompleted()
        }
        // === End atlas → tile blit block =================================
    }

    /// Upload a UIImage into a fresh Metal texture. Used to build the floating
    /// selection texture once (when extraction completes) so subsequent drag
    /// frames can render it on the GPU without touching the CPU pixels.
    func makeTexture(from image: UIImage) -> MTLTexture? {
        guard let cgImage = image.cgImage else { return nil }
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: w,
            height: h,
            mipmapped: false
        )
        // Must match `createLayerTexture`'s usage flags — this codepath
        // restores layer textures from saved PNGs on reopen, and those
        // textures get used as render targets the moment the user makes
        // their next stroke. iOS 26 simulator's MTLDebug validation
        // makes a missing .renderTarget bit fatal (earlier OSes silently
        // tolerated it for some configurations).
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        // Match layer-texture format (premultipliedFirst BGRA8).
        let bytesPerRow = w * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = context.data else { return nil }

        texture.replace(
            region: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )
        return texture
    }

    /// Render selection pixels as an overlay during drag for smooth animation
    /// This renders at 60fps without writing to texture until drag is complete
    func renderSelectionOverlay(
        _ image: UIImage,
        at rect: CGRect,
        to renderEncoder: MTLRenderCommandEncoder,
        zoomScale: Float,
        panOffset: SIMD2<Float>,
        canvasRotation: Float,
        viewportSize: SIMD2<Float>,
        canvasSize: SIMD2<Float>
    ) {
        // Create a temporary texture from the selection image
        guard let cgImage = image.cgImage else {
            dbgLog("ERROR: Failed to get CGImage from selection")
            return
        }

        let width = cgImage.width
        let height = cgImage.height

        // Create texture descriptor
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            dbgLog("ERROR: Failed to create texture for selection overlay")
            return
        }

        // Convert CGImage to pixel data
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let bytesPerRow = width * 4

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            dbgLog("ERROR: Failed to create CGContext for selection overlay")
            return
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else {
            dbgLog("ERROR: Failed to get context data")
            return
        }

        // Upload to texture
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: width, height: height, depth: 1)
        )
        texture.replace(region: region, mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)

        // Now render this texture at the specified rect with transforms applied
        // Use the same transform pipeline as regular texture rendering
        guard let pipelineState = textureDisplayWithTransformPipelineState else {
            dbgLog("ERROR: Transform pipeline state not available")
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setFragmentTexture(texture, index: 0)

        // Pass full opacity
        var opacity: Float = 1.0
        renderEncoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)

        // Pass transform parameters
        var transform = SIMD4<Float>(zoomScale, panOffset.x, panOffset.y, canvasRotation)
        renderEncoder.setVertexBytes(&transform, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)

        var viewport = viewportSize
        renderEncoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)

        var canvas = canvasSize
        renderEncoder.setVertexBytes(&canvas, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)

        // Draw fullscreen quad
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// Render in-progress stroke preview directly to screen (for real-time feedback)
    func renderStrokePreview(
        _ stroke: BrushStroke,
        to renderEncoder: MTLRenderCommandEncoder,
        viewportSize: CGSize,
        drawableSize: CGSize,
        zoomScale: CGFloat = 1.0,
        panOffset: CGPoint = .zero,
        canvasRotation: Double = 0.0,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false
    ) {
        // Tier-1.5: eraser previews are no longer routed through this path.
        // The eraser writes its stamps live into the active layer texture
        // via `renderStroke` per touchesMoved (see MetalCanvasView), and
        // the every-frame layer composite picks up the cuts immediately.
        // The gray-ghost workaround that used to live here for `.eraser`
        // is gone — `renderStrokePreview` now serves the brush plus the
        // experimental brush variants. Each variant gets its real shader
        // mid-drag so the preview matches the committed look.
        let previewPipeline: MTLRenderPipelineState? = {
            switch stroke.tool {
            case .pencil:   return pencilPipelineState
            case .marker:   return markerPipelineState
            case .airbrush: return airbrushPipelineState
            case .charcoal: return charcoalPipelineState
            case .watercolor: return watercolorPipelineState
            default:        return brushPipelineState
            }
        }()
        guard let pipelineState = previewPipeline else { return }

        renderEncoder.setRenderPipelineState(pipelineState)

        // PR 3 selection-mask binding. Reads the cache populated by the
        // touch handler at stroke start (`beginPreviewMask`); falls back
        // to the 1×1 `noMaskTexture` when no selection is active. The
        // cache is rasterised ONCE at touchdown and reused for every
        // preview frame for the duration of the drag — selection
        // geometry is immutable mid-stroke. No per-frame work here
        // beyond binding the existing texture pointer. Pairs with the
        // committed-stroke clip in `renderStroke`; preview and commit
        // both use the same selection geometry so the visible trail
        // tracks the eventual committed result.
        let previewMask = previewSelectionMask ?? noMaskTexture
        renderEncoder.setFragmentTexture(previewMask, index: 2)

        // Match the committed-on-screen stamp size.
        //
        // The committed stroke renders at `settings.size` TEXTURE pixels into a
        // `canvasSize`-sized texture. The compositor then maps that texture to
        // `fitSize × fitSize` of the DRAWABLE (pixels), further multiplied by
        // zoomScale. The preview, meanwhile, uses Metal `[[point_size]]` which
        // is always in RENDER-TARGET pixels (the drawable), regardless of the
        // point-space viewport we pass the vertex shader.
        //
        // On-screen equivalent size of the committed stroke in drawable pixels:
        //     settings.size * (drawableFit / canvasSize.width) * zoomScale
        //
        // The old preview used `settings.size * zoomScale`, which was off by
        // the texture→screen ratio `drawableFit / canvasSize.width`. On iPad
        // that's ≈2732/2048 ≈ 1.33×, so committed was visibly larger and the
        // absolute gap scaled linearly with brush size.
        let drawableFit = max(drawableSize.width, drawableSize.height)
        let textureToScreen = canvasSize.width > 0 ? drawableFit / canvasSize.width : 1.0

        let previewColor: UIColor = stroke.settings.color
        let previewOpacity: Double = stroke.settings.opacity

        // Clamp the preview's base size to Apple GPU's point sprite cap
        // (~511 px on A-series). Past this, Metal silently fails to render
        // points — this is one of the two causes the user reported as
        // "stroke vanishes mid-stroke" (the other was NaN propagation,
        // fixed in computePressure / touchesMoved). Without the clamp, at
        // brush size 200 + zoom 2 + iPad textureToScreen ≈ 1.33 the raw
        // value would be 532 — past the cap. Visual result of the clamp:
        // very-large brushes at high zoom show truncated preview thickness
        // instead of disappearing. The committed stroke uses
        // settings.size directly into texture pixels (no zoom/aspect
        // multipliers) so it's already safe; the shader-side clamp below
        // belt-and-suspenders that path too.
        let rawPreviewSize = stroke.settings.size * textureToScreen * zoomScale
        let safePreviewSize: CGFloat = rawPreviewSize.isFinite
            ? min(max(rawPreviewSize, 0), 511)
            : 0

        var uniforms = BrushUniforms(
            color: previewColor,
            size: Float(safePreviewSize),
            opacity: Float(previewOpacity),
            hardness: Float(stroke.settings.hardness),
            tileOrigin: SIMD2<Float>(0, 0),
            grainDensity: stroke.settings.grainDensity
        )

        // Transform document-space points to UIKit-screen-space points, matching
        // `CanvasStateManager.documentToScreen`. Must stay in sync with the shader's
        // position transform in `quadVertexShaderWithTransform`.
        let fitSize = max(viewportSize.width, viewportSize.height)
        let centerX = viewportSize.width / 2
        let centerY = viewportSize.height / 2
        let cosAngle = cos(canvasRotation)
        let sinAngle = sin(canvasRotation)

        let positions = stroke.points.map { point -> SIMD2<Float> in
            // doc → normalized fraction → quad-local centered pixels
            let fracX = point.location.x / canvasSize.width
            let fracY = point.location.y / canvasSize.height
            var x = fracX * fitSize - fitSize / 2
            var y = fracY * fitSize - fitSize / 2

            // Zoom around origin (viewport center)
            x *= zoomScale
            y *= zoomScale

            // Rotate around origin. Matches documentToScreen: visual CCW by
            // `canvasRotation` in UIKit Y-down = R(-θ) applied directly.
            let rotatedX = x * cosAngle + y * sinAngle
            let rotatedY = -x * sinAngle + y * cosAngle

            // Translate to viewport center, apply pan
            x = rotatedX + centerX + panOffset.x
            y = rotatedY + centerY + panOffset.y

            // Flip in screen frame, applied LAST. MUST stay in sync with
            // CanvasStateManager.documentToScreen and the shader's
            // quadVertexShaderWithTransform — all three apply flip as the
            // very last positioning step before NDC conversion. If you
            // change the flip rule in one place, change it in all three.
            if flipHorizontal { x = 2 * centerX - x }
            if flipVertical   { y = 2 * centerY - y }

            return SIMD2<Float>(Float(x), Float(y))
        }

        // Use the actual viewport size for the preview
        let viewport = SIMD2<Float>(Float(viewportSize.width), Float(viewportSize.height))

        // Render each point as a brush stamp
        var viewportCopy = viewport

        for (index, point) in stroke.points.enumerated() {
            // Sanitize pressure — NaN here would taint pointSize and the
            // preview point would silently fail to render. See the matching
            // sanitization in renderStroke above.
            let safePressure: CGFloat = {
                guard point.pressure.isFinite else { return 1.0 }
                return max(0, min(1, point.pressure))
            }()
            uniforms.pressure = Float(safePressure)
            let safePressureAlpha: CGFloat = {
                guard point.pressureAlpha.isFinite else { return 1.0 }
                return max(0, min(1, point.pressureAlpha))
            }()
            uniforms.pressureAlpha = Float(safePressureAlpha)
            uniforms.strokeDir = Self.strokeDirection(stroke.points, at: index)

            // Copy position to avoid overlapping access
            var position = positions[index]

            renderEncoder.setVertexBytes(&position, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 1)
            renderEncoder.setVertexBytes(&viewportCopy, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)

            // Draw point sprite
            renderEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
        }
    }

    /// Flood fill (paint bucket).
    ///
    /// Validation (point in bounds, target ≠ fill) and the full-texture
    /// `getBytes` happen synchronously on the caller's thread. The fill loop
    /// itself runs on a background queue — at 4096² this used to block the
    /// main thread for hundreds of ms, so the caller is expected to show a
    /// HUD between the call and `completion`. `texture.replace` and
    /// `completion` fire on the main queue.
    ///
    /// Returns `true` if background work was dispatched (caller should leave
    /// any HUD up until `completion` runs); `false` if the fill was skipped
    /// because the start point was out of bounds or already the fill color
    /// (caller should not show a HUD — completion is **not** invoked in that
    /// case).
    // TODO(perf-followup): drive `floodFillKernel` (Shaders.metal) from this
    // function. The kernel was rewritten to a real connected-component fill
    // primitive but is not wired up yet. Wiring requires: (a) two R8 mask
    // textures, (b) seeding the front mask at the click point, (c) iterating
    // the kernel until convergence (jump-flood / fixed-iteration / atomic
    // change-flag), (d) a final compositing pass that stamps `fillColor`
    // wherever the mask is set, plus undo capture. Until that lands, the CPU
    // path below remains the active flood-fill implementation.
    @discardableResult
    func floodFill(
        at point: CGPoint,
        with color: UIColor,
        tileGrid: TileGrid,
        screenSize: CGSize,
        completion: @escaping () -> Void
    ) -> Bool {
        #if DEBUG
        dbgLog("CanvasRenderer: Flood fill at \(point) with color")
        #endif

        guard let atlas = ensureCanvasStagingAtlas() else {
            dbgLog("ERROR: floodFill — failed to ensure staging atlas")
            return false
        }

        // Scale coordinates from screen space to canvas-pixel space
        let scaleX = CGFloat(atlas.width) / screenSize.width
        let scaleY = CGFloat(atlas.height) / screenSize.height
        let texturePoint = CGPoint(x: point.x * scaleX, y: point.y * scaleY)

        let startX = Int(texturePoint.x)
        let startY = Int(texturePoint.y)

        // Validate coordinates
        guard startX >= 0, startY >= 0, startX < atlas.width, startY < atlas.height else {
            dbgLog("ERROR: Point outside canvas bounds")
            return false
        }

        // Phase 4.2d: read pixel data from the tile grid via the staging
        // atlas instead of getBytes on the monolithic. Same flat-buffer
        // shape (width × height × 4 bytes, zero-filled) so the flood
        // algorithm below runs unchanged.
        //
        // Pre-blit every allocated tile into the atlas at its canvas
        // position (one command buffer, one waitUntilCompleted; same
        // pattern as captureSnapshot). Then per-tile getBytes from the
        // atlas into the flat buffer at the same canvas position.
        // Unallocated tiles contribute nothing — their flat-buffer
        // regions stay zero (transparent), which is the correct content.
        //
        // No drainCommandQueue at entry: Metal's command queue is FIFO,
        // and the atlas-blit's GPU work serializes behind any in-flight
        // tile-write cb. Hazard tracking ensures the blit reads the
        // post-write tile pixels. Drain is only needed for the
        // touchesCancelled-on-restoreSnapshot race shape (5b15e24).
        let width = atlas.width
        let height = atlas.height
        let bytesPerRow = width * 4
        let dataSize = bytesPerRow * height

        let grid = tileGrid
        let tileSize = grid.tileSize
        let allocated = grid.allocatedKeys()

        // Pre-blit allocated tiles into the atlas. Skipped entirely if
        // the layer has no content — flat buffer stays all-zero, the
        // target-color check below sees transparent, and the same-color
        // early-out fires for a transparent fill.
        if !allocated.isEmpty {
            guard let prereadCB = commandQueue.makeCommandBuffer() else {
                dbgLog("ERROR: floodFill — failed to create pre-read command buffer")
                return false
            }
            if let blit = prereadCB.makeBlitCommandEncoder() {
                for key in allocated {
                    guard let tile = grid.tile(at: key) else { continue }
                    let dstX = key.x * tileSize
                    let dstY = key.y * tileSize
                    let copyW = min(tileSize, width - dstX)
                    let copyH = min(tileSize, height - dstY)
                    if copyW <= 0 || copyH <= 0 { continue }
                    blit.copy(
                        from: tile.texture,
                        sourceSlice: 0, sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                        to: atlas,
                        destinationSlice: 0, destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
                    )
                }
                blit.endEncoding()
            }
            prereadCB.commit()
            prereadCB.waitUntilCompleted()
        }

        // Build flat canvas buffer from atlas. Data(count:) zero-fills
        // in Swift, so unallocated tile regions stay transparent.
        // Per-tile getBytes writes into the flat buffer at the tile's
        // canvas-pixel position; dstBytesPerRow = full canvas row stride
        // so each tile row lands at the correct offset.
        var pixelData = Data(count: dataSize)
        pixelData.withUnsafeMutableBytes { ptr in
            guard let basePtr = ptr.baseAddress else { return }
            for key in allocated {
                let dstX = key.x * tileSize
                let dstY = key.y * tileSize
                let copyW = min(tileSize, width - dstX)
                let copyH = min(tileSize, height - dstY)
                if copyW <= 0 || copyH <= 0 { continue }
                let dstOffset = dstY * bytesPerRow + dstX * 4
                atlas.getBytes(
                    basePtr.advanced(by: dstOffset),
                    bytesPerRow: bytesPerRow,
                    from: MTLRegion(
                        origin: MTLOrigin(x: dstX, y: dstY, z: 0),
                        size: MTLSize(width: copyW, height: copyH, depth: 1)
                    ),
                    mipmapLevel: 0
                )
            }
        }

        // Get target color at click point
        let targetIndex = (startY * width + startX) * 4
        guard targetIndex + 3 < pixelData.count else {
            dbgLog("ERROR: Invalid pixel index")
            return false
        }

        let targetB = pixelData[targetIndex]
        let targetG = pixelData[targetIndex + 1]
        let targetR = pixelData[targetIndex + 2]
        let targetA = pixelData[targetIndex + 3]

        // Convert fill color to BGRA
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let fillB = UInt8(b * 255)
        let fillG = UInt8(g * 255)
        let fillR = UInt8(r * 255)
        let fillA = UInt8(a * 255)

        // Check if target and fill colors are the same (within tolerance)
        let tolerance: UInt8 = 5
        if abs(Int(targetB) - Int(fillB)) <= tolerance &&
           abs(Int(targetG) - Int(fillG)) <= tolerance &&
           abs(Int(targetR) - Int(fillR)) <= tolerance &&
           abs(Int(targetA) - Int(fillA)) <= tolerance {
            #if DEBUG
            dbgLog("Target and fill colors are the same, skipping fill")
            #endif
            return false
        }

        // Heavy work runs on a background queue. We capture `pixelData` by
        // value so the GCD block owns its own mutable buffer; texture.replace
        // and `completion` are dispatched back to main once the fill loop
        // finishes.
        DispatchQueue.global(qos: .userInitiated).async {
            var data = pixelData

            // Flat-byte visited mask (1 byte/pixel — 16 MiB on 4096²)
            // replaces the previous `Set<Int>`, which boxed every visited
            // pixel index and triggered hash-table rehashes for large fills.
            // Algorithm and connectivity are unchanged: 4-connected stack
            // flood fill with the same tolerance check.
            var visited = [UInt8](repeating: 0, count: width * height)
            var stack: [(Int, Int)] = [(startX, startY)]
            var fillCount = 0
            let maxFill = width * height // Safety limit

            // Phase 2 Task 4.7: dirty-bbox tracking for the tile mirror.
            // Updated per filled pixel below; 4 integer comparisons per pixel
            // are negligible against the rest of the loop. After the fill
            // completes, the dual-write only touches tiles intersecting this
            // bbox rather than the full canvas.
            var dirtyMinX = startX
            var dirtyMaxX = startX
            var dirtyMinY = startY
            var dirtyMaxY = startY

            data.withUnsafeMutableBytes { rawBuffer in
                guard let basePtr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

                while !stack.isEmpty && fillCount < maxFill {
                    let (px, py) = stack.removeLast()
                    guard px >= 0, py >= 0, px < width, py < height else { continue }
                    let pixelKey = py * width + px
                    if visited[pixelKey] != 0 { continue }
                    let idx = pixelKey * 4
                    let pb = basePtr[idx]
                    let pg = basePtr[idx + 1]
                    let pr = basePtr[idx + 2]
                    let pa = basePtr[idx + 3]
                    if abs(Int(pb) - Int(targetB)) > tolerance ||
                       abs(Int(pg) - Int(targetG)) > tolerance ||
                       abs(Int(pr) - Int(targetR)) > tolerance ||
                       abs(Int(pa) - Int(targetA)) > tolerance {
                        continue
                    }

                    visited[pixelKey] = 1
                    basePtr[idx] = fillB
                    basePtr[idx + 1] = fillG
                    basePtr[idx + 2] = fillR
                    basePtr[idx + 3] = fillA
                    fillCount += 1

                    if px < dirtyMinX { dirtyMinX = px }
                    if px > dirtyMaxX { dirtyMaxX = px }
                    if py < dirtyMinY { dirtyMinY = py }
                    if py > dirtyMaxY { dirtyMaxY = py }

                    stack.append((px + 1, py))
                    stack.append((px - 1, py))
                    stack.append((px, py + 1))
                    stack.append((px, py - 1))
                }
            }

            #if DEBUG
            dbgLog("Filled \(fillCount) pixels")
            #endif

            DispatchQueue.main.async { [weak self] in
                data.withUnsafeBytes { ptr in
                    guard let baseAddress = ptr.baseAddress else { return }
                    atlas.replace(
                        region: MTLRegion(
                            origin: MTLOrigin(x: 0, y: 0, z: 0),
                            size: MTLSize(width: width, height: height, depth: 1)
                        ),
                        mipmapLevel: 0,
                        withBytes: baseAddress,
                        bytesPerRow: bytesPerRow
                    )
                }

                // === Phase 4.5c: blit modified atlas region into tiles ====
                //
                // Full-tile blit from atlas — every affected tile becomes a
                // bit-exact copy of the atlas, which atlas.replace just
                // landed with the final post-fill state. Previous shape
                // used a buffer-to-texture sub-tile blit with two structural
                // problems: (a) freshly-allocated tiles whose tile-bbox
                // extended past the dirty bbox had unfilled pixels left at
                // zero, mismatching monolithic; (b) sourceBytesPerRow
                // alignment requirements aren't universally honored across
                // iOS GPUs for arbitrary widths. Full-tile blit-from-atlas
                // resolves both.
                if fillCount > 0, let self = self {
                    let dirtyRect = CGRect(
                        x: dirtyMinX,
                        y: dirtyMinY,
                        width: dirtyMaxX - dirtyMinX + 1,
                        height: dirtyMaxY - dirtyMinY + 1
                    )
                    let tileKeys = grid.tilesIntersecting(dirtyRect)
                    let tileSize = grid.tileSize
                    let atlasW = atlas.width
                    let atlasH = atlas.height

                    if !tileKeys.isEmpty, let cmdBuf = self.commandQueue.makeCommandBuffer() {
                        for key in tileKeys {
                            _ = grid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: cmdBuf)
                        }
                        if let blit = cmdBuf.makeBlitCommandEncoder() {
                            for key in tileKeys {
                                let srcX = key.x * tileSize
                                let srcY = key.y * tileSize
                                let blitW = min(tileSize, atlasW - srcX)
                                let blitH = min(tileSize, atlasH - srcY)
                                if blitW <= 0 || blitH <= 0 { continue }

                                grid.updateTile(at: key) { tile in
                                    blit.copy(
                                        from: atlas,
                                        sourceSlice: 0, sourceLevel: 0,
                                        sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                                        sourceSize: MTLSize(width: blitW, height: blitH, depth: 1),
                                        to: tile.texture,
                                        destinationSlice: 0, destinationLevel: 0,
                                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                                    )
                                }
                            }
                            blit.endEncoding()
                        }
                        cmdBuf.commit()
                        cmdBuf.waitUntilCompleted()
                    }
                }
                // === End atlas → tile blit block ==========================

                completion()
            }
        }

        return true
    }

    /// Layer snapshot for undo/redo. Tile-native (Phase 4.2b–c).
    ///
    /// Pairs per-tile pixel buffers with the tile-grid keyspace at
    /// capture time. Restoring rebuilds the grid to match
    /// `tiles.keys` exactly so undo/redo across DROP+ADD ops
    /// (translate today; future ops that drop keys later) round-trip
    /// cleanly. Without the keyspace capture, restoreSnapshot would
    /// leave tile grid at whatever-it-was-when-undo-fired — the
    /// composite path (Phase 3) would render blank in any region whose
    /// tiles were dropped between snapshot and restore (the
    /// translate-undo case). Structural prerequisite for Phase 3's
    /// correctness (Phase 2.5 origin, commit 9427258).
    ///
    /// Per-tile buffer layout: each `tiles[key]` Data is sized exactly
    /// `copyW × copyH × 4` bytes where copyW = min(tileSize, canvasWidth
    /// - key.x*tileSize) and similarly for copyH. Partial-edge tiles
    /// (last column/row on a non-tile-aligned canvas) get smaller
    /// buffers. No slop bytes. captureSnapshot is the sole producer.
    ///
    /// `canvasWidth`/`canvasHeight`/`tileSize` carry the geometry
    /// captureSnapshot used so consumers can derive per-tile in-canvas
    /// positions without reading the renderer's state.
    ///
    /// Phase 4.2c stripped the pre-existing bridge computed properties
    /// (`pixels` for full-canvas reassembly, `allocatedKeys` as
    /// `Array(tiles.keys)`). restoreSnapshot reads `tiles` directly now;
    /// no caller needs the legacy shape.
    struct LayerSnapshot {
        let tiles: [TileKey: Data]
        let canvasWidth: Int
        let canvasHeight: Int
        let tileSize: Int

        /// Total byte count across all tile buffers. Used by the
        /// before/after byte-size logging at stroke commit and undo.
        var totalByteCount: Int {
            tiles.values.reduce(0) { $0 + $1.count }
        }
    }

    /// Capture a snapshot of a layer's tile-grid contents for undo/redo.
    /// Tile-native via the shared staging atlas:
    ///   1. Ensure the atlas exists at current canvasSize.
    ///   2. Blit every allocated tile from `tileGrid` into its in-canvas
    ///      position on the atlas, on a single command buffer.
    ///   3. commit + waitUntilCompleted.
    ///   4. getBytes per tile from the atlas into a per-tile Data buffer
    ///      sized exactly to the tile's in-canvas footprint (partial-
    ///      edge tiles get smaller buffers; no slop).
    ///
    /// Returns nil only on Metal allocation failure or invalid canvas
    /// dimensions. The empty-tile-grid case (grid present,
    /// `allocatedKeys().isEmpty`) is supported and produces a snapshot
    /// with empty `tiles` — a legitimate empty-layer snapshot.
    ///
    /// Drain-before-snapshot semantics: production callers snapshot
    /// from `addCompletedHandler` callbacks (renderStroke /
    /// renderBlurStroke / appendBlurStrokeStamps / renderSmudgeStamps
    /// all fire their completion AFTER their async cb drains), so
    /// captureSnapshot itself doesn't drain. The cap-for-op-N+1-while-
    /// op-N-async race shape doesn't reach here in normal use.
    func captureSnapshot(tileGrid: TileGrid) -> LayerSnapshot? {
        let canvasW = Int(canvasSize.width)
        let canvasH = Int(canvasSize.height)
        guard canvasW > 0, canvasH > 0 else {
            dbgLog("ERROR: captureSnapshot — invalid canvas dimensions (\(canvasW)×\(canvasH))")
            return nil
        }

        let grid = tileGrid
        let tileSize = grid.tileSize
        let allocated = grid.allocatedKeys()

        // Empty-grid case is legitimate (just-created layer that has no
        // tiles allocated yet). Return an empty-tiles snapshot — restore
        // interprets `tiles.keys.isEmpty` as "drop everything," which
        // matches the pre-4.2 `allocatedKeys.isEmpty` semantic.
        if allocated.isEmpty {
            return LayerSnapshot(tiles: [:],
                                 canvasWidth: canvasW,
                                 canvasHeight: canvasH,
                                 tileSize: tileSize)
        }

        guard let atlas = ensureCanvasStagingAtlas() else {
            dbgLog("ERROR: captureSnapshot — failed to ensure staging atlas")
            return nil
        }

        guard let cb = commandQueue.makeCommandBuffer() else {
            dbgLog("ERROR: captureSnapshot — failed to create command buffer")
            return nil
        }

        // Blit each allocated tile into its canvas-pixel position on the
        // atlas. Single command buffer; one waitUntilCompleted. Atlas is
        // reused across snapshots — captureSnapshot only consumes it via
        // getBytes in this scope, so any pixels remaining from a previous
        // snapshot's tiles get overwritten by new blits (or sit in tiles
        // not in this snapshot's keyspace; harmless because we only
        // getBytes from the keys we just blitted).
        if let blit = cb.makeBlitCommandEncoder() {
            for key in allocated {
                guard let tile = grid.tile(at: key) else { continue }
                let dstX = key.x * tileSize
                let dstY = key.y * tileSize
                let copyW = min(tileSize, canvasW - dstX)
                let copyH = min(tileSize, canvasH - dstY)
                if copyW <= 0 || copyH <= 0 { continue }
                blit.copy(
                    from: tile.texture,
                    sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                    to: atlas,
                    destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
                )
            }
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()

        // getBytes per tile from the atlas at the tile's in-canvas
        // position. Each per-tile buffer is sized EXACTLY to the tile's
        // in-canvas footprint — partial-edge tiles get smaller buffers,
        // no slop. The bridge `.pixels` computed property inverts this
        // layout on the consumer side.
        var tiles: [TileKey: Data] = [:]
        tiles.reserveCapacity(allocated.count)

        for key in allocated {
            let dstX = key.x * tileSize
            let dstY = key.y * tileSize
            let copyW = min(tileSize, canvasW - dstX)
            let copyH = min(tileSize, canvasH - dstY)
            if copyW <= 0 || copyH <= 0 { continue }

            let bytesPerRow = copyW * 4
            var data = Data(count: bytesPerRow * copyH)
            data.withUnsafeMutableBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                atlas.getBytes(
                    base,
                    bytesPerRow: bytesPerRow,
                    from: MTLRegion(
                        origin: MTLOrigin(x: dstX, y: dstY, z: 0),
                        size: MTLSize(width: copyW, height: copyH, depth: 1)
                    ),
                    mipmapLevel: 0
                )
            }
            tiles[key] = data
        }

        return LayerSnapshot(tiles: tiles,
                             canvasWidth: canvasW,
                             canvasHeight: canvasH,
                             tileSize: tileSize)
    }

    /// Block the caller until every command buffer previously committed
    /// on `commandQueue` has finished GPU execution. Implemented by
    /// committing an empty cb and `waitUntilCompleted` on it — Metal's
    /// queue is FIFO for cbs, so the empty buffer sequences behind all
    /// earlier in-flight work.
    ///
    /// Cost: ~microseconds when the queue is idle; matches the time for
    /// the most-recent in-flight cb to complete when one is pending.
    /// Same latency the caller would pay if they were waiting on the cb
    /// directly.
    ///
    /// Use case: callsites that need to mutate a texture via
    /// `texture.replace` where that texture might still be attached as a
    /// writeable render target on an async-committed
    /// (no-`waitUntilCompleted`) cb. The canonical example is
    /// `restoreSnapshot` called from a touch-cancellation path before
    /// the in-flight stroke cb has drained — Metal's
    /// `_validateReplaceRegion` aborts in that race window.
    private func drainCommandQueue() {
        guard let cb = commandQueue.makeCommandBuffer() else { return }
        cb.commit()
        cb.waitUntilCompleted()
    }

    /// Restore a tile grid from a snapshot. Tile-native — the layer
    /// has no monolithic backing post-Phase-4.5e; the tile grid is the
    /// sole source of truth.
    ///
    /// Flow:
    ///   1. `drainCommandQueue()` — wait for any in-flight async stroke
    ///      cb to drain. Solves the touchesCancelled race where Metal's
    ///      `_validateReplaceRegion` aborted if a still-writeable render
    ///      target was passed to `texture.replace` (commit 5b15e24).
    ///   2. Drop tiles in the current grid that are NOT in the snapshot's
    ///      keyspace (cleans up tiles allocated by intervening ops; those
    ///      regions of the layer become transparent again, matching the
    ///      snapshot's "missing tile = transparent" semantic).
    ///   3. Pre-filter `snapshot.tiles` into a `validRestores` list,
    ///      skipping entries whose key/data shape doesn't match
    ///      captureSnapshot's per-tile layout. Used by every subsequent
    ///      loop.
    ///   4. Empty/all-invalid snapshot: the step-2 drop already made the
    ///      layer fully transparent; return early.
    ///   5. CPU-upload each valid tile's Data into the staging atlas at
    ///      its in-canvas position (`texture.replace` on `.shared` atlas).
    ///   6. `ensureTileWithClearIfNeeded` for each valid key on the cmdBuf
    ///      (allocates a fresh grid tile if absent).
    ///   7. Open blit encoder: per valid key, copy atlas → grid tile.
    ///   8. `commit + waitUntilCompleted`.
    ///
    /// Result: `grid.allocatedKeys()` == `snapshot.tiles.keys` (set-equal),
    /// each grid tile bit-exact with `snapshot.tiles[key]`. The display
    /// path (tile-source since Phase 4.4a) reads the restored content
    /// directly.
    ///
    /// History (kept short — full sequence in master audit Appendix D):
    /// 4.2b made captureSnapshot tile-native; 4.2c stripped the
    /// `.pixels` bridge so restore reads `snapshot.tiles[key]` directly
    /// (~16-64 MB transient allocation eliminated per restore); 4.5d
    /// stripped the atlas → monolithic blit pair (the per-layer
    /// monolithic was deleted at 4.5e).
    func restoreSnapshot(_ snapshot: LayerSnapshot, tileGrid: TileGrid) {
        drainCommandQueue()

        let grid = tileGrid
        let savedKeys = Set(snapshot.tiles.keys)

        // Drop tiles in the current grid that aren't in the snapshot.
        // After this loop, any tile in the grid that's also in the
        // snapshot will get its content overwritten below; any tile
        // not in the snapshot is gone — those regions become
        // transparent (which matched the pre-4.5 monolithic clear).
        for key in grid.allocatedKeys() where !savedKeys.contains(key) {
            grid.dropTile(at: key)
        }

        let tileSize = grid.tileSize
        let canvasW = Int(canvasSize.width)
        let canvasH = Int(canvasSize.height)

        // Pre-filter to validRestores: tuples carrying the per-tile
        // pixel dims so the subsequent loops don't recompute them and
        // so mis-sized entries are skipped wholesale.
        var validRestores: [(key: TileKey, data: Data, copyW: Int, copyH: Int)] = []
        validRestores.reserveCapacity(snapshot.tiles.count)
        for (key, tileData) in snapshot.tiles {
            let dstX = key.x * tileSize
            let dstY = key.y * tileSize
            let copyW = min(tileSize, canvasW - dstX)
            let copyH = min(tileSize, canvasH - dstY)
            if copyW <= 0 || copyH <= 0 { continue }
            if tileData.count != copyW * copyH * 4 { continue }
            validRestores.append((key, tileData, copyW, copyH))
        }

        if validRestores.isEmpty {
            // Empty / all-invalid snapshot — every grid tile is already
            // dropped by the loop above, so the layer is now fully
            // transparent. Nothing more to do.
            return
        }

        guard let atlas = ensureCanvasStagingAtlas() else {
            dbgLog("ERROR: restoreSnapshot — failed to ensure staging atlas")
            return
        }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        // CPU-upload each valid tile's data into the atlas at its canvas
        // position. Atlas is .shared so texture.replace is legal; CPU
        // writes complete before we commit cmdBuf below, so the subsequent
        // GPU blits see the post-upload atlas state.
        for restore in validRestores {
            let dstX = restore.key.x * tileSize
            let dstY = restore.key.y * tileSize
            let bytesPerRow = restore.copyW * 4
            restore.data.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                atlas.replace(
                    region: MTLRegion(
                        origin: MTLOrigin(x: dstX, y: dstY, z: 0),
                        size: MTLSize(width: restore.copyW, height: restore.copyH, depth: 1)
                    ),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: bytesPerRow
                )
            }
        }

        // Allocate-and-clear-if-needed for every saved key. Each call may
        // encode its own no-draw render pass on cmdBuf; safe because no
        // blit encoder is open yet.
        for restore in validRestores {
            _ = grid.ensureTileWithClearIfNeeded(at: restore.key, onCommandBuffer: cmdBuf)
        }

        // Blit atlas → grid tile per valid key.
        if let blit = cmdBuf.makeBlitCommandEncoder() {
            for restore in validRestores {
                let dstX = restore.key.x * tileSize
                let dstY = restore.key.y * tileSize

                grid.updateTile(at: restore.key) { tile in
                    blit.copy(
                        from: atlas,
                        sourceSlice: 0, sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: dstX, y: dstY, z: 0),
                        sourceSize: MTLSize(width: restore.copyW, height: restore.copyH, depth: 1),
                        to: tile.texture,
                        destinationSlice: 0, destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                    )
                }
            }
            blit.endEncoding()
        }
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
    }

    // MARK: - Core Text rasterisation

    /// Rasterise a string + TextSettings to a UIImage at canvas-native
    /// resolution. The single text rasterisation path — used by the
    /// FloatingText pipeline (live preview + commit).
    ///
    /// Returns the image and its doc-space size — anchor + this size is the
    /// rect callers blit into the layer (or pass to `renderFloatingTexture`
    /// for live preview).
    ///
    /// Italic resolution uses UIFontDescriptor.SymbolicTraits.traitItalic
    /// first; if the family has no italic variant, falls back to a 12°
    /// horizontal shear applied via the CGContext text matrix. Trailing
    /// kerning is stripped from the last grapheme (NSAttributedString-level
    /// `.kern` applies to the trailing gap, so the final character would
    /// otherwise add unwanted right padding).
    func rasterizeFloatingText(
        _ floatingText: FloatingText,
        screenSize: CGSize
    ) -> (image: UIImage, docSize: CGSize)? {
        let texSize = canvasSize

        // Route path-bearing FloatingText through TextOnPathRenderer so
        // glyphs ride the arc-length LUT instead of laying out as a flat
        // line. Plain FloatingText takes the straight Core Text path.
        if floatingText.path != nil, floatingText.pathLUT != nil {
            guard let result = TextOnPathRenderer.rasterize(
                floatingText,
                screenSize: screenSize,
                textureSize: texSize
            ) else { return nil }
            // The on-path renderer returns docBounds — its origin is the
            // top-left of the glyph union in doc space. We pass back size
            // here; the caller (CanvasStateManager) places the FloatingText
            // such that anchor + size matches docBounds.
            return (result.image, result.docBounds.size)
        }

        return rasterizeFloatingText(
            content: floatingText.content,
            settings: floatingText.settings,
            screenSize: screenSize,
            textureSize: texSize
        )
    }

    /// Variant that also surfaces the doc-space ORIGIN of the rasterised
    /// content. For on-path rendering the glyph union's origin is not the
    /// FloatingText's anchor — the path layout drifts the bounding box
    /// off into wherever the path goes. CanvasStateManager calls this so
    /// it can set `FloatingText.anchor = bounds.origin` after rasterise,
    /// keeping the displayedRect logic shared with plain text.
    func rasterizeFloatingTextWithDocOrigin(
        _ floatingText: FloatingText,
        screenSize: CGSize
    ) -> (image: UIImage, docBounds: CGRect)? {
        let texSize = canvasSize
        if floatingText.path != nil, floatingText.pathLUT != nil {
            return TextOnPathRenderer.rasterize(
                floatingText,
                screenSize: screenSize,
                textureSize: texSize
            )
        }
        guard let plain = rasterizeFloatingText(
            content: floatingText.content,
            settings: floatingText.settings,
            screenSize: screenSize,
            textureSize: texSize
        ) else { return nil }
        // Plain text: the doc-space origin is the FloatingText's anchor;
        // the caller already knows that. Return a bounds rooted at the
        // anchor for API consistency.
        return (plain.image, CGRect(origin: floatingText.anchor, size: plain.docSize))
    }

    /// Core Text rasterisation primitive. Doc→texture scaling baked in so
    /// the resulting image has native-pixel dimensions and `renderImage`'s
    /// internal scaleX/scaleY math cancels back to 1:1.
    func rasterizeFloatingText(
        content: String,
        settings: TextSettings,
        screenSize: CGSize,
        textureSize: CGSize
    ) -> (image: UIImage, docSize: CGSize)? {
        guard !content.isEmpty,
              screenSize.width > 0, screenSize.height > 0,
              textureSize.width > 0, textureSize.height > 0 else { return nil }

        let scaleX = textureSize.width  / screenSize.width
        let scaleY = textureSize.height / screenSize.height
        let textureScale = max(scaleX, scaleY)

        // Render at texture-pixel size so the rasterised image is sharp at
        // canvas-native resolution. Doc-space sizes (size / leading /
        // tracking / kerning) all scale up by the same factor.
        let renderSize = settings.size * textureScale

        // Resolve font + italic shear fallback.
        let baseFont = UIFont(name: settings.fontFace, size: renderSize)
            ?? UIFont(name: settings.fontFamily, size: renderSize)
            ?? UIFont.systemFont(ofSize: renderSize, weight: .regular)

        var resolvedFont = baseFont
        var shearAngle: CGFloat = 0
        if settings.italic {
            if let italicDescriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                resolvedFont = UIFont(descriptor: italicDescriptor, size: renderSize)
            } else {
                // 12° fallback shear applied via cgctx.textMatrix below.
                shearAngle = 12 * .pi / 180
            }
        }

        // Paragraph style (alignment + leading).
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = settings.alignment.nsTextAlignment
        paragraph.lineSpacing = settings.leading * textureScale

        var attrs: [NSAttributedString.Key: Any] = [
            .font: resolvedFont,
            .foregroundColor: settings.color,
            .paragraphStyle: paragraph,
        ]
        if settings.tracking != 0 {
            // .tracking adds uniform spacing to every glyph (iOS 14+).
            attrs[.tracking] = settings.tracking * textureScale
        }

        var kernValue: CGFloat? = nil
        switch settings.kerning {
        case .auto:           kernValue = nil
        case .none:           kernValue = 0
        case .manual(let v):  kernValue = v * textureScale
        }
        if let k = kernValue {
            attrs[.kern] = k
        }

        // Build attributed string. Strip kerning from the last grapheme
        // cluster so the trailing gap doesn't push the laid-out width past
        // the visible glyph edge.
        let attrStr = NSMutableAttributedString(string: content, attributes: attrs)
        if kernValue != nil {
            let ns = content as NSString
            let length = ns.length
            if length > 0 {
                let last = ns.rangeOfComposedCharacterSequence(at: length - 1)
                attrStr.removeAttribute(.kern, range: last)
            }
        }

        // Layout via CTFramesetter.
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let constraint = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, attrStr.length),
            nil,
            constraint,
            nil
        )
        guard suggested.width > 0, suggested.height > 0 else { return nil }

        // Padding to absorb shear extension and descender clipping. CT
        // returns the typographic bounds, which can clip italic descenders
        // and the right-shifted cap of a sheared glyph.
        let descenderPadding = ceil(renderSize * 0.25)
        let shearExtra: CGFloat = shearAngle > 0
            ? ceil(suggested.height * tan(shearAngle))
            : 0
        let drawW = ceil(suggested.width)  + descenderPadding * 2 + shearExtra
        let drawH = ceil(suggested.height) + descenderPadding * 2

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let imageRenderer = UIGraphicsImageRenderer(size: CGSize(width: drawW, height: drawH),
                                                    format: format)
        let image = imageRenderer.image { ctx in
            let cgctx = ctx.cgContext
            cgctx.textMatrix = .identity
            // Flip to Y-up for Core Text.
            cgctx.translateBy(x: 0, y: drawH)
            cgctx.scaleBy(x: 1, y: -1)

            if shearAngle > 0 {
                // Italic shear: top of glyph (y>0 in CT's frame) shifts
                // right by tan(angle) * y. Applied via the text matrix so
                // CTFrameDraw picks it up.
                let shear = tan(shearAngle)
                cgctx.textMatrix = CGAffineTransform(a: 1, b: 0, c: shear, d: 1, tx: 0, ty: 0)
            }

            let path = CGMutablePath()
            path.addRect(CGRect(
                x: descenderPadding,
                y: descenderPadding,
                width: suggested.width,
                height: suggested.height
            ))
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, attrStr.length), path, nil)
            CTFrameDraw(frame, cgctx)
        }

        let docSize = CGSize(width: drawW / textureScale, height: drawH / textureScale)
        return (image, docSize)
    }

    // MARK: - Load Image

    /// Load a UIImage into a layer's tile grid via the shared canvas
    /// staging atlas. CGImage gets drawn into a CG bitmap at canvas size,
    /// the bytes land in the atlas, and a full-canvas wipe + tile-rebuild
    /// blits each tile from the atlas. No per-layer monolithic detour.
    ///
    /// Synchronous (waits on the GPU before returning). Safe to call
    /// after any prior dual-write completes.
    func loadImage(_ image: UIImage, tileGrid: TileGrid) {
        dbgLog("CanvasRenderer: Loading image into tile grid via staging atlas")

        guard let cgImage = image.cgImage else {
            dbgLog("ERROR: Failed to get CGImage from UIImage")
            return
        }

        guard let atlas = ensureCanvasStagingAtlas() else {
            dbgLog("ERROR: Failed to ensure canvas staging atlas for loadImage")
            return
        }

        let width = atlas.width
        let height = atlas.height
        let bytesPerRow = width * 4

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            dbgLog("ERROR: Failed to create CGContext")
            return
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else {
            dbgLog("ERROR: Failed to get context data")
            return
        }

        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: width, height: height, depth: 1)
        )

        atlas.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )

        // Wipe the entire tile keyspace and rebuild full-canvas from the
        // atlas. Inline what was `populateTileGridFromTexture` — that helper
        // was a Phase-2 dual-write artifact whose only remaining caller is
        // this function.
        for key in tileGrid.allocatedKeys() {
            tileGrid.dropTile(at: key)
        }

        var allKeys: [TileKey] = []
        allKeys.reserveCapacity(tileGrid.gridWidth * tileGrid.gridHeight)
        for ty in 0..<tileGrid.gridHeight {
            for tx in 0..<tileGrid.gridWidth {
                allKeys.append(TileKey(x: tx, y: ty))
            }
        }

        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }
        for key in allKeys {
            _ = tileGrid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: cmdBuf)
        }
        if let blit = cmdBuf.makeBlitCommandEncoder() {
            let tileSize = tileGrid.tileSize
            for key in allKeys {
                let srcX = key.x * tileSize
                let srcY = key.y * tileSize
                let blitW = min(tileSize, width - srcX)
                let blitH = min(tileSize, height - srcY)
                if blitW <= 0 || blitH <= 0 { continue }
                tileGrid.updateTile(at: key) { tile in
                    blit.copy(
                        from: atlas,
                        sourceSlice: 0, sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                        sourceSize: MTLSize(width: blitW, height: blitH, depth: 1),
                        to: tile.texture,
                        destinationSlice: 0, destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                    )
                }
            }
            blit.endEncoding()
        }
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // EMPTY-LAYER-DIAG (Part A): one-shot diagnostic prints + center-tile
        // content readback. Pure logging — allocates a transient .shared 256²
        // scratch, blits one tile into it, scans alpha, then drops the scratch.
        // No persistent state change.
        let __diagAllocated = tileGrid.allocatedKeys().count
        let __diagExpected  = tileGrid.gridWidth * tileGrid.gridHeight
        dbgLog("📥 LOADIMG-A1 allocatedKeys=\(__diagAllocated)/\(__diagExpected) grid=\(tileGrid.gridWidth)×\(tileGrid.gridHeight) tileSize=\(tileGrid.tileSize) canvasSize=\(Int(canvasSize.width))×\(Int(canvasSize.height))")
        do {
            let __probeKey = TileKey(x: min(4, tileGrid.gridWidth - 1),
                                     y: min(4, tileGrid.gridHeight - 1))
            if let __probeTile = tileGrid.tile(at: __probeKey) {
                let __pw = __probeTile.texture.width
                let __ph = __probeTile.texture.height
                let __scratchDesc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm,
                    width: __pw, height: __ph,
                    mipmapped: false
                )
                __scratchDesc.storageMode = .shared
                __scratchDesc.usage = [.shaderRead]
                if let __scratch = device.makeTexture(descriptor: __scratchDesc),
                   let __probeCb = commandQueue.makeCommandBuffer(),
                   let __probeBlit = __probeCb.makeBlitCommandEncoder() {
                    __probeBlit.copy(
                        from: __probeTile.texture,
                        sourceSlice: 0, sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: __pw, height: __ph, depth: 1),
                        to: __scratch,
                        destinationSlice: 0, destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                    )
                    __probeBlit.endEncoding()
                    __probeCb.commit()
                    __probeCb.waitUntilCompleted()
                    let __rowBytes = __pw * 4
                    var __buf = [UInt8](repeating: 0, count: __rowBytes * __ph)
                    __buf.withUnsafeMutableBytes { __raw in
                        guard let __base = __raw.baseAddress else { return }
                        __scratch.getBytes(
                            __base,
                            bytesPerRow: __rowBytes,
                            from: MTLRegion(
                                origin: MTLOrigin(x: 0, y: 0, z: 0),
                                size: MTLSize(width: __pw, height: __ph, depth: 1)
                            ),
                            mipmapLevel: 0
                        )
                    }
                    // BGRA byte order; alpha is the 4th byte per pixel.
                    var __nonzeroAlpha = 0
                    var __maxAlpha: UInt8 = 0
                    var __i = 3
                    while __i < __buf.count {
                        let __a = __buf[__i]
                        if __a > 0 { __nonzeroAlpha += 1 }
                        if __a > __maxAlpha { __maxAlpha = __a }
                        __i += 4
                    }
                    let __totalPixels = __pw * __ph
                    dbgLog("📥 LOADIMG-A2 probeKey=(\(__probeKey.x),\(__probeKey.y)) tileSize=\(__pw)×\(__ph) totalPixels=\(__totalPixels) nonzeroAlphaPixels=\(__nonzeroAlpha) maxAlpha=\(__maxAlpha) wasCleared=\(__probeTile.wasCleared) dirtyVersion=\(__probeTile.dirtyVersion)")
                } else {
                    dbgLog("📥 LOADIMG-A2 probeKey=(\(__probeKey.x),\(__probeKey.y)) ERROR: failed to allocate scratch / cb / blit")
                }
            } else {
                dbgLog("📥 LOADIMG-A2 probeKey=(\(__probeKey.x),\(__probeKey.y)) ERROR: tile not allocated — A1 told the story already")
            }
        }

        #if DEBUG
        dbgLog("✅ Image loaded successfully into tile grid")
        #endif
    }

    // MARK: - Selection Operations

    /// Clear pixels in a rectangular selection
    /// Convert a doc-space rect to an integer texture-pixel rect (x, y, w, h).
    /// Uses floor on the near edge and ceil on the far edge so any pixel the
    /// rect touches is included, then clamps to the texture. Returns nil when
    /// the clamped rect is empty.
    private func texturePixelRect(for rect: CGRect, in texture: MTLTexture, screenSize: CGSize) -> (Int, Int, Int, Int)? {
        let scaleX = CGFloat(texture.width) / screenSize.width
        let scaleY = CGFloat(texture.height) / screenSize.height

        let minFX = rect.origin.x * scaleX
        let minFY = rect.origin.y * scaleY
        let maxFX = (rect.origin.x + rect.width) * scaleX
        let maxFY = (rect.origin.y + rect.height) * scaleY

        let x0 = max(0, Int(floor(minFX)))
        let y0 = max(0, Int(floor(minFY)))
        let x1 = min(texture.width, Int(ceil(maxFX)))
        let y1 = min(texture.height, Int(ceil(maxFY)))

        let w = x1 - x0
        let h = y1 - y0
        guard w > 0, h > 0 else { return nil }
        return (x0, y0, w, h)
    }

    func clearRect(_ rect: CGRect, tileGrid: TileGrid, screenSize: CGSize) {
        #if DEBUG
        dbgLog("CanvasRenderer: Clearing rect \(rect)")
        #endif

        guard let atlas = ensureCanvasStagingAtlas() else {
            dbgLog("ERROR: Failed to ensure canvas staging atlas for clearRect")
            return
        }

        // Convert doc-space rect to integer pixel rect. Use floor/ceil so every
        // pixel the rect touches is included, then clamp to atlas bounds.
        // clearRect and extractPixels MUST use identical integer rects or
        // extracted/cleared regions drift and leave ghost pixels on move.
        guard let (x, y, w, h) = texturePixelRect(for: rect, in: atlas, screenSize: screenSize) else {
            dbgLog("ERROR: Rect outside canvas bounds or empty")
            return
        }

        // Region-local I/O: at 4096² a full-canvas getBytes is 64 MiB on every
        // selection commit. We only need to write zeros into the work
        // rectangle, so allocate a buffer the size of the rect and skip the
        // read entirely (we're overwriting every byte anyway).
        let regionBytesPerRow = w * 4
        let region = MTLRegion(
            origin: MTLOrigin(x: x, y: y, z: 0),
            size: MTLSize(width: w, height: h, depth: 1)
        )
        let zeros = [UInt8](repeating: 0, count: regionBytesPerRow * h)
        zeros.withUnsafeBufferPointer { buf in
            guard let baseAddress = buf.baseAddress else { return }
            atlas.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: regionBytesPerRow
            )
        }

        // === Phase 4.5c: blit zeroed region from staging atlas into tiles ==
        //
        // Canonical pattern (matches renderStroke / compositeFloating / flip /
        // translate). Pass 1: ensureTileWithClearIfNeeded for every
        // intersecting tile — allocates and clears any new tile so its
        // unblitted region is well-defined. Pass 2: full-tile blit from
        // staging atlas, bit-exact by construction.
        let pixelRect = CGRect(x: x, y: y, width: w, height: h)
        let tileKeys = tileGrid.tilesIntersecting(pixelRect)
        let tileSize = tileGrid.tileSize
        let atlasW = atlas.width
        let atlasH = atlas.height

        if !tileKeys.isEmpty, let cmdBuf = commandQueue.makeCommandBuffer() {
            for key in tileKeys {
                _ = tileGrid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: cmdBuf)
            }
            if let blit = cmdBuf.makeBlitCommandEncoder() {
                for key in tileKeys {
                    let srcX = key.x * tileSize
                    let srcY = key.y * tileSize
                    let blitW = min(tileSize, atlasW - srcX)
                    let blitH = min(tileSize, atlasH - srcY)
                    if blitW <= 0 || blitH <= 0 { continue }

                    tileGrid.updateTile(at: key) { tile in
                        blit.copy(
                            from: atlas,
                            sourceSlice: 0, sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                            sourceSize: MTLSize(width: blitW, height: blitH, depth: 1),
                            to: tile.texture,
                            destinationSlice: 0, destinationLevel: 0,
                            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                        )
                    }
                }
                blit.endEncoding()
            }
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
        }
        // === End atlas → tile blit block =================================

        dbgLog("Rect cleared successfully")
    }

    /// Clear pixels along a path (for lasso selection)
    func clearPath(_ path: [CGPoint], tileGrid: TileGrid, screenSize: CGSize) {
        dbgLog("CanvasRenderer: Clearing path with \(path.count) points")

        guard path.count >= 3 else {
            dbgLog("ERROR: Path must have at least 3 points")
            return
        }

        guard let atlas = ensureCanvasStagingAtlas() else {
            dbgLog("ERROR: Failed to ensure canvas staging atlas for clearPath")
            return
        }

        // Scale path from screen space to atlas (canvas-pixel) space
        let scaleX = CGFloat(atlas.width) / screenSize.width
        let scaleY = CGFloat(atlas.height) / screenSize.height
        let scaledPath = path.map { CGPoint(x: $0.x * scaleX, y: $0.y * scaleY) }

        let width = atlas.width
        let height = atlas.height

        // Use point-in-polygon algorithm to determine which pixels to clear
        func isPointInPolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
            var inside = false
            var j = polygon.count - 1
            for i in 0..<polygon.count {
                let xi = polygon[i].x, yi = polygon[i].y
                let xj = polygon[j].x, yj = polygon[j].y

                if ((yi > point.y) != (yj > point.y)) &&
                   (point.x < (xj - xi) * (point.y - yi) / (yj - yi) + xi) {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }

        // Find bounding box of path. floor/ceil so edge pixels aren't shaved.
        let minX = max(0, Int(floor(scaledPath.map { $0.x }.min() ?? 0)))
        let maxX = min(width - 1, Int(ceil(scaledPath.map { $0.x }.max() ?? CGFloat(width))))
        let minY = max(0, Int(floor(scaledPath.map { $0.y }.min() ?? 0)))
        let maxY = min(height - 1, Int(ceil(scaledPath.map { $0.y }.max() ?? CGFloat(height))))
        let regionW = maxX - minX + 1
        let regionH = maxY - minY + 1
        guard regionW > 0, regionH > 0 else {
            dbgLog("Path bbox empty, nothing to clear")
            return
        }

        // Region-local I/O: read only the path's bounding box rather than the
        // whole canvas (a 4096² lasso selection on a 4096² canvas was a
        // 64 MiB read → 16× saving for typical selection sizes).
        //
        // Phase 4.5c: compose tiles intersecting the bbox into the staging
        // atlas so getBytes pulls from current tile state (no monolithic).
        let bboxPixelRect = CGRect(x: minX, y: minY, width: regionW, height: regionH)
        let bboxKeys = tileGrid.tilesIntersecting(bboxPixelRect)
        let tileSize = tileGrid.tileSize

        if !bboxKeys.isEmpty, let composeBuf = commandQueue.makeCommandBuffer() {
            // Source B fix: clear bbox-tile-aligned atlas region before
            // compose. clearPath is read-modify-write — stale pixels in
            // unallocated bbox tiles would flow through getBytes into
            // pixelData, then back out via texture.replace at the bbox.
            if let clearRegion = atlasRegion(coveringTiles: bboxKeys, tileSize: tileSize) {
                clearCanvasStagingAtlasRegion(clearRegion, on: composeBuf)
            }
            if let blit = composeBuf.makeBlitCommandEncoder() {
                for key in bboxKeys {
                    guard let tile = tileGrid.tile(at: key) else { continue }
                    let dstX = key.x * tileSize
                    let dstY = key.y * tileSize
                    let copyW = min(tileSize, width - dstX)
                    let copyH = min(tileSize, height - dstY)
                    if copyW <= 0 || copyH <= 0 { continue }
                    blit.copy(
                        from: tile.texture,
                        sourceSlice: 0, sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                        to: atlas,
                        destinationSlice: 0, destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
                    )
                }
                blit.endEncoding()
            }
            composeBuf.commit()
            composeBuf.waitUntilCompleted()
        }

        let regionBytesPerRow = regionW * 4
        let region = MTLRegion(
            origin: MTLOrigin(x: minX, y: minY, z: 0),
            size: MTLSize(width: regionW, height: regionH, depth: 1)
        )
        var pixelData = Data(count: regionBytesPerRow * regionH)

        pixelData.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            atlas.getBytes(
                baseAddress,
                bytesPerRow: regionBytesPerRow,
                from: region,
                mipmapLevel: 0
            )
        }

        // Clear pixels inside the path. Test at pixel CENTER (px+0.5, py+0.5)
        // so edge pixels that are mostly-inside get included — testing at the
        // corner drops thin edge slivers.
        var clearedCount = 0
        for row in 0..<regionH {
            let py = minY + row
            for col in 0..<regionW {
                let px = minX + col
                let point = CGPoint(x: CGFloat(px) + 0.5, y: CGFloat(py) + 0.5)
                if isPointInPolygon(point, polygon: scaledPath) {
                    let idx = (row * regionW + col) * 4
                    pixelData[idx] = 0     // B
                    pixelData[idx + 1] = 0 // G
                    pixelData[idx + 2] = 0 // R
                    pixelData[idx + 3] = 0 // A
                    clearedCount += 1
                }
            }
        }

        // Write back the modified region into the atlas only.
        pixelData.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            atlas.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: regionBytesPerRow
            )
        }

        // === Phase 4.5c: blit modified region from atlas back into tiles ==
        //
        // Full-tile blit from atlas — sub-tile buffer-to-texture blits had
        // unhonored alignment requirements and didn't repair drift in the
        // non-cleared portion of a tile that earlier callsites may have left
        // misaligned. Full-tile blit from atlas is bit-exact by construction.
        if !bboxKeys.isEmpty, let cmdBuf = commandQueue.makeCommandBuffer() {
            for key in bboxKeys {
                _ = tileGrid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: cmdBuf)
            }
            if let blit = cmdBuf.makeBlitCommandEncoder() {
                for key in bboxKeys {
                    let srcX = key.x * tileSize
                    let srcY = key.y * tileSize
                    let blitW = min(tileSize, width - srcX)
                    let blitH = min(tileSize, height - srcY)
                    if blitW <= 0 || blitH <= 0 { continue }

                    tileGrid.updateTile(at: key) { tile in
                        blit.copy(
                            from: atlas,
                            sourceSlice: 0, sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                            sourceSize: MTLSize(width: blitW, height: blitH, depth: 1),
                            to: tile.texture,
                            destinationSlice: 0, destinationLevel: 0,
                            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                        )
                    }
                }
                blit.endEncoding()
            }
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
        }
        // === End atlas → tile blit block =================================

        dbgLog("Path cleared successfully (\(clearedCount) pixels)")
    }

    // MARK: - Export Image

    /// Exports all visible layers composited into a single image
    func exportImage(layers: [DrawingLayer]) -> UIImage? {
        dbgLog("CanvasRenderer: Exporting image with \(layers.count) layers")
        return compositeLayersToImage(layers: layers)
    }

    // MARK: - Pixel Extraction for Selection Movement

    /// Extract pixels from a rectangular selection
    func extractPixels(from rect: CGRect, tileGrid: TileGrid, screenSize: CGSize) -> UIImage? {
        dbgLog("CanvasRenderer: Extracting pixels from rect \(rect)")

        guard let atlas = ensureCanvasStagingAtlas() else {
            dbgLog("ERROR: extractPixels — failed to ensure staging atlas")
            return nil
        }

        // Must use identical integer rect as clearRect — see note there.
        guard let (x, y, w, h) = texturePixelRect(for: rect, in: atlas, screenSize: screenSize) else {
            dbgLog("ERROR: Rect outside canvas bounds or empty")
            return nil
        }

        // Compose tile state for the selection bbox into the atlas so the
        // getBytes below reads current tile content.
        let pixelRect = CGRect(x: x, y: y, width: w, height: h)
        let tileKeys = tileGrid.tilesIntersecting(pixelRect)
        let tileSize = tileGrid.tileSize
        if !tileKeys.isEmpty, let cb = commandQueue.makeCommandBuffer() {
            // Source B fix: clear bbox-tile-aligned atlas region before
            // compose. extract is read-only (no blit-back), so a raw-bbox
            // clear would suffice — but tile-aligned matches the helper
            // shape used everywhere else and only over-clears the
            // in-tile-outside-bbox sliver, which is bounded and cheap.
            if let clearRegion = atlasRegion(coveringTiles: tileKeys, tileSize: tileSize) {
                clearCanvasStagingAtlasRegion(clearRegion, on: cb)
            }
            if let blit = cb.makeBlitCommandEncoder() {
                for key in tileKeys {
                    guard let tile = tileGrid.tile(at: key) else { continue }
                    let dstX = key.x * tileSize
                    let dstY = key.y * tileSize
                    let copyW = min(tileSize, atlas.width - dstX)
                    let copyH = min(tileSize, atlas.height - dstY)
                    if copyW <= 0 || copyH <= 0 { continue }
                    blit.copy(
                        from: tile.texture,
                        sourceSlice: 0, sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                        to: atlas,
                        destinationSlice: 0, destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
                    )
                }
                blit.endEncoding()
            }
            cb.commit()
            cb.waitUntilCompleted()
        }

        // Region-local read.
        let selectionBytesPerRow = w * 4
        var selectionData = Data(count: selectionBytesPerRow * h)
        let region = MTLRegion(
            origin: MTLOrigin(x: x, y: y, z: 0),
            size: MTLSize(width: w, height: h, depth: 1)
        )

        selectionData.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            atlas.getBytes(
                baseAddress,
                bytesPerRow: selectionBytesPerRow,
                from: region,
                mipmapLevel: 0
            )
        }

        // Convert to UIImage
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: selectionBytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            dbgLog("ERROR: Failed to create CGContext for selection")
            return nil
        }

        selectionData.withUnsafeBytes { ptr in
            guard let srcBase = ptr.baseAddress else { return }
            if let data = context.data {
                memcpy(data, srcBase, selectionData.count)
            }
        }

        guard let cgImage = context.makeImage() else {
            dbgLog("ERROR: Failed to create CGImage from selection")
            return nil
        }

        dbgLog("✂️ Extracted selection: \(w)x\(h) pixels")
        return UIImage(cgImage: cgImage)
    }

    /// Extract pixels from a lasso/path selection with alpha masking
    func extractPixels(fromPath path: [CGPoint], tileGrid: TileGrid, screenSize: CGSize) -> UIImage? {
        dbgLog("CanvasRenderer: Extracting pixels from path with \(path.count) points")

        guard path.count >= 3 else {
            dbgLog("ERROR: Path must have at least 3 points")
            return nil
        }

        guard let atlas = ensureCanvasStagingAtlas() else {
            dbgLog("ERROR: extractPixels(fromPath:) — failed to ensure staging atlas")
            return nil
        }

        // Scale path from screen space to canvas-pixel space
        let scaleX = CGFloat(atlas.width) / screenSize.width
        let scaleY = CGFloat(atlas.height) / screenSize.height
        let scaledPath = path.map { CGPoint(x: $0.x * scaleX, y: $0.y * scaleY) }

        // Find bounding box. floor/ceil so edge pixels aren't shaved.
        let minX = max(0, Int(floor(scaledPath.map { $0.x }.min() ?? 0)))
        let maxX = min(atlas.width - 1, Int(ceil(scaledPath.map { $0.x }.max() ?? CGFloat(atlas.width))))
        let minY = max(0, Int(floor(scaledPath.map { $0.y }.min() ?? 0)))
        let maxY = min(atlas.height - 1, Int(ceil(scaledPath.map { $0.y }.max() ?? CGFloat(atlas.height))))

        let w = maxX - minX + 1
        let h = maxY - minY + 1

        guard w > 0, h > 0 else {
            dbgLog("ERROR: Invalid bounding box")
            return nil
        }

        // Compose tile state for the bbox into the atlas.
        let pixelRect = CGRect(x: minX, y: minY, width: w, height: h)
        let tileKeys = tileGrid.tilesIntersecting(pixelRect)
        let tileSize = tileGrid.tileSize
        if !tileKeys.isEmpty, let cb = commandQueue.makeCommandBuffer() {
            // Source B fix: clear bbox-tile-aligned atlas region before
            // compose. Same shape as extractPixels(from:) — read-only
            // path, but uses the same tile-aligned helper for code
            // uniformity. Stale pixels in unallocated bbox tiles would
            // otherwise flow into the extracted UIImage's lasso-masked
            // bounding box.
            if let clearRegion = atlasRegion(coveringTiles: tileKeys, tileSize: tileSize) {
                clearCanvasStagingAtlasRegion(clearRegion, on: cb)
            }
            if let blit = cb.makeBlitCommandEncoder() {
                for key in tileKeys {
                    guard let tile = tileGrid.tile(at: key) else { continue }
                    let dstX = key.x * tileSize
                    let dstY = key.y * tileSize
                    let copyW = min(tileSize, atlas.width - dstX)
                    let copyH = min(tileSize, atlas.height - dstY)
                    if copyW <= 0 || copyH <= 0 { continue }
                    blit.copy(
                        from: tile.texture,
                        sourceSlice: 0, sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                        to: atlas,
                        destinationSlice: 0, destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
                    )
                }
                blit.endEncoding()
            }
            cb.commit()
            cb.waitUntilCompleted()
        }

        // Region-local read of the path's bounding box. The region buffer
        // is already laid out as the output CGImage wants, so we mask in
        // place (zero pixels outside the polygon) instead of allocating a
        // separate selectionData buffer.
        let selectionBytesPerRow = w * 4
        var selectionData = Data(count: selectionBytesPerRow * h)
        let region = MTLRegion(
            origin: MTLOrigin(x: minX, y: minY, z: 0),
            size: MTLSize(width: w, height: h, depth: 1)
        )

        selectionData.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            atlas.getBytes(
                baseAddress,
                bytesPerRow: selectionBytesPerRow,
                from: region,
                mipmapLevel: 0
            )
        }

        // Point-in-polygon test
        func isPointInPolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
            var inside = false
            var j = polygon.count - 1
            for i in 0..<polygon.count {
                let xi = polygon[i].x, yi = polygon[i].y
                let xj = polygon[j].x, yj = polygon[j].y

                if ((yi > point.y) != (yj > point.y)) &&
                   (point.x < (xj - xi) * (point.y - yi) / (yj - yi) + xi) {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }

        // Mask the region buffer in place: zero out pixels outside the path.
        // Pixels inside stay untouched (already loaded from the texture).
        selectionData.withUnsafeMutableBytes { selPtr in
            guard let selBase = selPtr.baseAddress else { return }
            for row in 0..<h {
                for col in 0..<w {
                    let texX = minX + col
                    let texY = minY + row
                    // Test pixel CENTER so edge pixels mostly inside the
                    // polygon are included (matches clearPath).
                    let point = CGPoint(x: CGFloat(texX) + 0.5, y: CGFloat(texY) + 0.5)
                    if !isPointInPolygon(point, polygon: scaledPath) {
                        let dstOffset = (row * w + col) * 4
                        (selBase + dstOffset).storeBytes(of: UInt32(0), as: UInt32.self)
                    }
                }
            }
        }

        // Convert to UIImage
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: selectionBytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            dbgLog("ERROR: Failed to create CGContext for lasso selection")
            return nil
        }

        selectionData.withUnsafeBytes { ptr in
            guard let srcBase = ptr.baseAddress else { return }
            if let data = context.data {
                memcpy(data, srcBase, selectionData.count)
            }
        }

        guard let cgImage = context.makeImage() else {
            dbgLog("ERROR: Failed to create CGImage from lasso selection")
            return nil
        }

        dbgLog("✂️ Extracted lasso selection: \(w)x\(h) pixels")
        return UIImage(cgImage: cgImage)
    }

    /// Render an image (extracted selection pixels) at a specific position.
    ///
    /// Uses the CGImage's intrinsic pixel dimensions and only computes an
    /// integer pixel OFFSET from `rect.origin`. This guarantees a 1:1 blit
    /// without CoreGraphics resampling — resampling was the source of the
    /// half-alpha edge pixels that showed up as white halos on moved selections.
    ///
    /// Blending math treats both source and destination as PREMULTIPLIED BGRA
    /// (which is how the Metal texture stores pixels with the brush pipeline's
    /// sourceAlpha/oneMinusSourceAlpha blend factors). The previous version
    /// applied a straight-alpha Porter-Duff formula to premultiplied inputs,
    /// double-multiplying by srcA and shifting edge colors.
    func renderImage(_ image: UIImage, at rect: CGRect, tileGrid: TileGrid, screenSize: CGSize) {
        guard let cgImage = image.cgImage else {
            dbgLog("ERROR: Failed to get CGImage")
            return
        }

        guard let atlas = ensureCanvasStagingAtlas() else {
            dbgLog("ERROR: renderImage — failed to ensure staging atlas")
            return
        }

        // Image pixel dimensions — use as-is, no resampling.
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return }

        // Integer pixel offset in canvas-pixel space. We truncate here; the
        // CGImage was extracted at integer pixel bounds, so the render
        // target must also be integer-aligned. Sub-pixel drag jitter is
        // acceptable.
        let scaleX = CGFloat(atlas.width) / screenSize.width
        let scaleY = CGFloat(atlas.height) / screenSize.height
        let x = Int(floor(rect.origin.x * scaleX))
        let y = Int(floor(rect.origin.y * scaleY))

        // Pull image bytes into a premultipliedFirst BGRA buffer at native size.
        // No `context.draw(_, in:)` scaling — we give the context the image's
        // exact dimensions so drawing is a straight copy.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let bytesPerRow = w * 4
        guard let srcContext = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            dbgLog("ERROR: Failed to create CGContext")
            return
        }
        srcContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let srcData = srcContext.data else { return }

        // Region-local I/O: clamp the image's destination rect to canvas
        // bounds and operate only on that intersection. A 256² text run was
        // a 64 MiB full-canvas read+write at 4096²; the clamped region is
        // ~256 KiB.
        let canvasW = atlas.width
        let canvasH = atlas.height
        let dstX = max(0, x)
        let dstY = max(0, y)
        let dstEndX = min(canvasW, x + w)
        let dstEndY = min(canvasH, y + h)
        let regionW = dstEndX - dstX
        let regionH = dstEndY - dstY
        guard regionW > 0, regionH > 0 else { return }

        // Where in the source image the visible top-left corner lives. Equal
        // to (max(0, -x), max(0, -y)) when the image hangs off the canvas.
        let imgStartCol = dstX - x
        let imgStartRow = dstY - y

        // Phase 4.5c: compose intersecting tiles into the atlas so the
        // read sees current tile state.
        let regionPixelRect = CGRect(x: dstX, y: dstY, width: regionW, height: regionH)
        let tileKeys = tileGrid.tilesIntersecting(regionPixelRect)
        let tileSize = tileGrid.tileSize

        if !tileKeys.isEmpty, let composeBuf = commandQueue.makeCommandBuffer() {
            // Source B fix: clear the bbox-tile-aligned atlas region
            // before compose so unallocated bbox tiles read as zero
            // instead of inheriting stale pixels from prior dual-write
            // callers. (loadAction=.load doesn't apply here — we read
            // via getBytes — but the same leak shape applies: stale
            // pixels would flow into the read buffer, then through the
            // Porter-Duff blend, then back into the atlas at the bbox
            // position via texture.replace.)
            if let clearRegion = atlasRegion(coveringTiles: tileKeys, tileSize: tileSize) {
                clearCanvasStagingAtlasRegion(clearRegion, on: composeBuf)
            }
            if let blit = composeBuf.makeBlitCommandEncoder() {
                for key in tileKeys {
                    guard let tile = tileGrid.tile(at: key) else { continue }
                    let posX = key.x * tileSize
                    let posY = key.y * tileSize
                    let copyW = min(tileSize, canvasW - posX)
                    let copyH = min(tileSize, canvasH - posY)
                    if copyW <= 0 || copyH <= 0 { continue }
                    blit.copy(
                        from: tile.texture,
                        sourceSlice: 0, sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                        to: atlas,
                        destinationSlice: 0, destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: posX, y: posY, z: 0)
                    )
                }
                blit.endEncoding()
            }
            composeBuf.commit()
            composeBuf.waitUntilCompleted()
        }

        let regionBytesPerRow = regionW * 4
        var regionData = Data(count: regionBytesPerRow * regionH)
        let region = MTLRegion(
            origin: MTLOrigin(x: dstX, y: dstY, z: 0),
            size: MTLSize(width: regionW, height: regionH, depth: 1)
        )

        regionData.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            atlas.getBytes(
                baseAddress,
                bytesPerRow: regionBytesPerRow,
                from: region,
                mipmapLevel: 0
            )
        }

        regionData.withUnsafeMutableBytes { regionPtr in
            guard let regionBase = regionPtr.baseAddress else { return }
            srcData.withMemoryRebound(to: UInt8.self, capacity: w * h * 4) { imgPtr in
                for row in 0..<regionH {
                    let imgRow = imgStartRow + row
                    for col in 0..<regionW {
                        let imgCol = imgStartCol + col

                        let imgOffset = (imgRow * w + imgCol) * 4
                        let regionOffset = (row * regionW + col) * 4

                        // Both src and dst are PREMULTIPLIED BGRA8. Use premul
                        // Porter-Duff: out = src + dst * (1 - srcA). No extra
                        // multiply by srcA, no divide by outA.
                        let srcB = Int(imgPtr[imgOffset])
                        let srcG = Int(imgPtr[imgOffset + 1])
                        let srcR = Int(imgPtr[imgOffset + 2])
                        let srcA = Int(imgPtr[imgOffset + 3])

                        // Fully transparent source contributes nothing; skip to
                        // preserve the destination exactly (important for lasso
                        // masks outside the polygon).
                        if srcA == 0 { continue }

                        let dstB = Int((regionBase + regionOffset).load(as: UInt8.self))
                        let dstG = Int((regionBase + regionOffset + 1).load(as: UInt8.self))
                        let dstR = Int((regionBase + regionOffset + 2).load(as: UInt8.self))
                        let dstA = Int((regionBase + regionOffset + 3).load(as: UInt8.self))

                        let invSrcA = 255 - srcA
                        // (dst * invSrcA + 127) / 255  → rounded integer divide
                        let outB = srcB + (dstB * invSrcA + 127) / 255
                        let outG = srcG + (dstG * invSrcA + 127) / 255
                        let outR = srcR + (dstR * invSrcA + 127) / 255
                        let outA = srcA + (dstA * invSrcA + 127) / 255

                        (regionBase + regionOffset).storeBytes(of: UInt8(min(255, outB)), as: UInt8.self)
                        (regionBase + regionOffset + 1).storeBytes(of: UInt8(min(255, outG)), as: UInt8.self)
                        (regionBase + regionOffset + 2).storeBytes(of: UInt8(min(255, outR)), as: UInt8.self)
                        (regionBase + regionOffset + 3).storeBytes(of: UInt8(min(255, outA)), as: UInt8.self)
                    }
                }
            }
        }

        regionData.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            atlas.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: regionBytesPerRow
            )
        }

        // === Phase 4.5c: blit modified region from atlas back into tiles ==
        //
        // Full-tile blit from atlas — sub-tile blits had two structural
        // problems: (a) freshly-allocated tiles where the image's region
        // didn't fully cover the tile got zeroed by ensureTileWithClearIfNeeded
        // and only the image rect got blitted, leaving the rest at zero
        // while monolithic kept pre-existing content. Full-tile blit from
        // atlas eliminates that: every affected tile is bit-exact with
        // the atlas, which carries pre-blend pixels everywhere outside
        // the image rect and post-blend pixels inside it.
        if !tileKeys.isEmpty, let cmdBuf = commandQueue.makeCommandBuffer() {
            for key in tileKeys {
                _ = tileGrid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: cmdBuf)
            }
            if let blit = cmdBuf.makeBlitCommandEncoder() {
                for key in tileKeys {
                    let srcX = key.x * tileSize
                    let srcY = key.y * tileSize
                    let blitW = min(tileSize, canvasW - srcX)
                    let blitH = min(tileSize, canvasH - srcY)
                    if blitW <= 0 || blitH <= 0 { continue }

                    tileGrid.updateTile(at: key) { tile in
                        blit.copy(
                            from: atlas,
                            sourceSlice: 0, sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                            sourceSize: MTLSize(width: blitW, height: blitH, depth: 1),
                            to: tile.texture,
                            destinationSlice: 0, destinationLevel: 0,
                            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                        )
                    }
                }
                blit.endEncoding()
            }
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
        }
        // === End atlas → tile blit block =================================
    }

    // MARK: - Blur (PR 1)

    /// Layout-matched twin of the Metal `GaussianUniforms` struct (Shaders.metal).
    private struct GaussianUniformsCPU {
        var direction: SIMD2<Float>
        var sigma: Float
        var kernelHalfWidth: Int32
    }

    /// Cap kernel half-width to keep single-pass tap counts sane on the
    /// lowest-spec target. ceil(3 * sigma) covers ~99.7% of a Gaussian; at
    /// sigma=50 that's 150 taps per direction. We cap at 96 (sigma~32 retains
    /// full quality, larger sigma falls back to a slightly truncated kernel).
    private static let maxBlurKernelHalfWidth: Int32 = 96

    private static func gaussianHalfWidth(for sigma: Float) -> Int32 {
        guard sigma > 0 else { return 0 }
        let raw = Int32(ceil(3.0 * sigma))
        return min(raw, maxBlurKernelHalfWidth)
    }

    /// Texture for an effect intermediate. Same dims as a layer texture but
    /// with usage tuned for the Gaussian pipelines.
    private func makeBlurIntermediateTexture() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private  // GPU-only — never read by CPU.
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        // Phase 4.5 follow-up (blur pink-ring fix, Source A):
        // Metal `.private` textures are uninitialized at allocation
        // and may hold bits from recently-freed memory in Metal's
        // texture pool. The blur Gaussian samples this texture at
        // kernel-half-width offsets from each output pixel — those
        // offsets cross outside the per-stamp scissor's compose
        // region into snapshot territory that the compose-from-tiles
        // step never wrote (unallocated tile regions). Without this
        // clear, any uninitialized garbage in the unwritten regions
        // gets pulled in by the kernel, producing intermittent
        // coloured rings around blur strokes near tile boundaries.
        // Issuing the clear on the same command queue as subsequent
        // compose writes — Metal's FIFO ordering serializes the
        // clear before any later cb reads the texture.
        clearTexture(texture)
        return texture
    }

    /// Single-pass Gaussian. `target` and `source` must be different textures.
    /// `direction` is in UV space (1/width, 0) for horizontal, (0, 1/height)
    /// for vertical. Caller may pass a non-nil `scissorRect` to limit output.
    private func runGaussianPass(
        commandBuffer: MTLCommandBuffer,
        target: MTLTexture,
        source: MTLTexture,
        direction: SIMD2<Float>,
        sigma: Float,
        kernelHalfWidth: Int32,
        scissorRect: MTLScissorRect? = nil,
        loadAction: MTLLoadAction = .dontCare
    ) {
        guard let pipeline = gaussianBlurPipelineState else { return }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = loadAction
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipeline)
        if let rect = scissorRect {
            encoder.setScissorRect(rect)
        }
        encoder.setFragmentTexture(source, index: 0)
        var uniforms = GaussianUniformsCPU(
            direction: direction,
            sigma: sigma,
            kernelHalfWidth: kernelHalfWidth
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GaussianUniformsCPU>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }

    /// Vertical-pass Gaussian + masked composite into `target`. Reads the
    /// already-horizontally-blurred `intermediate`, the original `source`, and
    /// a per-pixel `mask`. Result blended via `mix(source, blurred, mask.r)`.
    private func runGaussianMaskedPass(
        commandBuffer: MTLCommandBuffer,
        target: MTLTexture,
        intermediate: MTLTexture,
        source: MTLTexture,
        mask: MTLTexture,
        sigma: Float,
        kernelHalfWidth: Int32
    ) {
        guard let pipeline = gaussianBlurMaskedPipelineState else { return }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(intermediate, index: 0)
        encoder.setFragmentTexture(source, index: 1)
        encoder.setFragmentTexture(mask, index: 2)
        var uniforms = GaussianUniformsCPU(
            direction: SIMD2<Float>(0, 1.0 / Float(target.height)),
            sigma: sigma,
            kernelHalfWidth: kernelHalfWidth
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GaussianUniformsCPU>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }

    /// Blit `source` into `dest` via a Metal blit encoder. Both textures must
    /// be same dimensions and pixel format. Used for snapshot lifecycle.
    private func blitCopy(commandBuffer: MTLCommandBuffer, source: MTLTexture, dest: MTLTexture) {
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else { return }
        encoder.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
            to: dest,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        encoder.endEncoding()
    }

    /// Resolve a selection mask texture for a brush/eraser/blur/smudge dispatch
    /// (PR 3). When `selectionPath` is non-nil and has ≥3 points, rasterises
    /// it to a fresh canvas-sized r8Unorm mask. Otherwise returns the 1×1
    /// `noMaskTexture` shared singleton — the shader's mask multiply
    /// becomes a no-op without any per-shader branching, and we avoid
    /// allocating canvas² bytes just to fill them with 1.0.
    private func selectionMaskTexture(for selectionPath: [CGPoint]?,
                                      documentSize: CGSize) -> MTLTexture? {
        if let path = selectionPath, path.count >= 3 {
            return rasterizeSelectionMask(path, canvasSize: documentSize)
        }
        return noMaskTexture
    }

    /// Cache the selection mask used by `renderStrokePreview` (PR 3
    /// follow-up). Called from `MetalCanvasView.touchesBegan` immediately
    /// after a brush/eraser/shape stroke is created. Rasterises once and
    /// stashes; every preview frame for the duration of the drag binds
    /// this same texture at fragment slot 2 — no per-frame rasterisation,
    /// no per-frame `==` comparison. Selection geometry can't change
    /// mid-stroke (the canvas owns the touch), so a single rasterise is
    /// sufficient. Pass `selectionPath: nil` (or a path with <3 points)
    /// to leave the cache empty; `renderStrokePreview` falls back to
    /// `noMaskTexture` so the preview is unclipped, matching the
    /// no-selection commit path.
    func beginPreviewMask(selectionPath: [CGPoint]?, documentSize: CGSize) {
        // selectionMaskTexture returns noMaskTexture for nil/empty paths.
        // Keeping that ambiguity OUT of the cache: when there's no real
        // selection we leave previewSelectionMask nil, and the read site
        // does the noMaskTexture fallback. Reduces accidental aliasing
        // (cache holds either a real per-stroke r8Unorm texture or nil).
        if let path = selectionPath, path.count >= 3 {
            previewSelectionMask = rasterizeSelectionMask(path, canvasSize: documentSize)
        } else {
            previewSelectionMask = nil
        }
    }

    /// Free the cached preview mask. Called from `touchesEnded` /
    /// `touchesCancelled`. Idempotent.
    func endPreviewMask() {
        previewSelectionMask = nil
    }

    /// Rasterize a polygon (`selectionPath`, in document-space points) into an
    /// `r8Unorm` mask texture sized to the canvas. Inside the polygon → 1.0,
    /// outside → 0.0. When the path is nil/empty, returns an all-1.0 mask
    /// (whole-layer fallback).
    private func rasterizeSelectionMask(_ selectionPath: [CGPoint]?,
                                        canvasSize: CGSize) -> MTLTexture? {
        let width = Int(canvasSize.width)
        let height = Int(canvasSize.height)
        guard width > 0, height > 0 else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let bytesPerRow = width
        var bytes = [UInt8](repeating: 0, count: width * height)

        if let path = selectionPath, path.count >= 3 {
            // CPU rasterize via CGContext into a single-channel buffer.
            let colorSpace = CGColorSpaceCreateDeviceGray()
            bytes.withUnsafeMutableBytes { rawBuf in
                guard let base = rawBuf.baseAddress,
                      let ctx = CGContext(
                        data: base,
                        width: width,
                        height: height,
                        bitsPerComponent: 8,
                        bytesPerRow: bytesPerRow,
                        space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.none.rawValue
                      ) else { return }
                ctx.setFillColor(gray: 1.0, alpha: 1.0)
                ctx.beginPath()
                ctx.move(to: path[0])
                for p in path.dropFirst() { ctx.addLine(to: p) }
                ctx.closePath()
                ctx.fillPath()
            }
        } else {
            // No selection — fill the whole mask with 1.0 (255 in r8Unorm).
            for i in 0..<bytes.count { bytes[i] = 255 }
        }

        bytes.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: bytesPerRow
            )
        }
        return texture
    }

    // MARK: - Blur Adjustment Tool (Procreate-style HUD scrubber)

    /// True when the renderer is hosting an active blur-adjustment preview
    /// for the given layer. MetalCanvasView checks this to swap the preview
    /// texture into its display loop in place of the layer's own texture.
    func blurAdjustmentPreviewTexture(forLayer layerId: UUID) -> MTLTexture? {
        guard blurAdjustmentLayerId == layerId else { return nil }
        return blurAdjustmentPreview
    }

    /// Allocate snapshot/preview/scratch/mask textures and seed them. Called
    /// when the user enters the blur adjustment tool and on each successful
    /// commit (so they can stack another adjustment).
    func beginBlurAdjustment(
        tileGrid: TileGrid,
        layerId: UUID,
        selectionPath: [CGPoint]?,
        documentSize: CGSize
    ) {
        // Free any prior session.
        endBlurAdjustment()

        // Allocate new textures matching the layer dims.
        guard let snapshot = makeBlurIntermediateTexture(),
              let preview = makeBlurIntermediateTexture(),
              let scratch = makeBlurIntermediateTexture() else {
            dbgLog("⚠️ beginBlurAdjustment: failed to allocate intermediate textures")
            return
        }

        guard let mask = rasterizeSelectionMask(selectionPath, canvasSize: documentSize) else {
            dbgLog("⚠️ beginBlurAdjustment: failed to rasterize selection mask")
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        // Compose every allocated tile into the snapshot at canvas-pixel
        // position — every preview Gaussian samples from this snapshot, so
        // it must reflect the layer's CURRENT tile state.
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            let tileSize = tileGrid.tileSize
            let snapW = snapshot.width
            let snapH = snapshot.height
            for key in tileGrid.allocatedKeys() {
                guard let tile = tileGrid.tile(at: key) else { continue }
                let dstX = key.x * tileSize
                let dstY = key.y * tileSize
                let copyW = min(tileSize, snapW - dstX)
                let copyH = min(tileSize, snapH - dstY)
                if copyW <= 0 || copyH <= 0 { continue }
                blit.copy(
                    from: tile.texture,
                    sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                    to: snapshot,
                    destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
                )
            }
            blit.endEncoding()
        }
        // Initial preview = snapshot (sigma starts at 0%; user sees the
        // unmodified layer until they drag).
        blitCopy(commandBuffer: commandBuffer, source: snapshot, dest: preview)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        blurAdjustmentSource = snapshot
        blurAdjustmentPreview = preview
        blurAdjustmentScratch = scratch
        blurAdjustmentMask = mask
        blurAdjustmentLayerId = layerId
    }

    /// Re-render the preview texture at a given sigma. Called from the HUD's
    /// horizontal-drag handler. Caller is expected to throttle (~30 fps).
    func updateBlurAdjustmentPreview(sigma: Float) {
        guard let snapshot = blurAdjustmentSource,
              let preview = blurAdjustmentPreview,
              let scratch = blurAdjustmentScratch,
              let mask = blurAdjustmentMask,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let halfWidth = Self.gaussianHalfWidth(for: sigma)

        if halfWidth <= 0 {
            // Sigma 0 → preview is just the snapshot. Cheap blit, no kernel.
            blitCopy(commandBuffer: commandBuffer, source: snapshot, dest: preview)
            commandBuffer.commit()
            return
        }

        // Pass 1: horizontal Gaussian, snapshot → scratch. No mask.
        runGaussianPass(
            commandBuffer: commandBuffer,
            target: scratch,
            source: snapshot,
            direction: SIMD2<Float>(1.0 / Float(snapshot.width), 0),
            sigma: sigma,
            kernelHalfWidth: halfWidth
        )

        // Pass 2: vertical Gaussian + masked composite, scratch → preview.
        // mix(snapshot, blurred, mask) so unselected regions stay original.
        runGaussianMaskedPass(
            commandBuffer: commandBuffer,
            target: preview,
            intermediate: scratch,
            source: snapshot,
            mask: mask,
            sigma: sigma,
            kernelHalfWidth: halfWidth
        )

        commandBuffer.commit()
    }

    /// Bake the current preview into the layer's tile grid. Caller
    /// records undo with snapshots taken before/after this call.
    func commitBlurAdjustment(tileGrid: TileGrid) {
        guard let preview = blurAdjustmentPreview,
              let atlas = ensureCanvasStagingAtlas(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        blitCopy(commandBuffer: commandBuffer, source: preview, dest: atlas)

        // === Phase 4.5c: blit atlas → tile grid (wipe + rebuild) ==========
        //
        // Blur adjustment writes a fully-blurred copy of the layer back into
        // the canvas-sized staging atlas. Wipe-and-rebuild rather than
        // refresh-allocated, for one specific reason: Gaussian blur is a
        // convolution that can spread alpha into previously-empty tile
        // regions (e.g., a stroke near a tile boundary blurs outward and
        // deposits faint pixels into the adjacent tile). The tile grid
        // must allocate every tile in bounds to capture that smear; just
        // refreshing currently-allocated tiles would miss the new content.
        //
        // Performed on the SAME command buffer as the preview→atlas blit
        // above. Metal serialises encoders within a buffer, so the per-
        // tile blit reads the post-blur atlas.
        for key in tileGrid.allocatedKeys() {
            tileGrid.dropTile(at: key)
        }
        var allKeys: [TileKey] = []
        allKeys.reserveCapacity(tileGrid.gridWidth * tileGrid.gridHeight)
        for ty in 0..<tileGrid.gridHeight {
            for tx in 0..<tileGrid.gridWidth {
                allKeys.append(TileKey(x: tx, y: ty))
            }
        }
        for key in allKeys {
            _ = tileGrid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: commandBuffer)
        }
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            let tileSize = tileGrid.tileSize
            let atlasW = atlas.width
            let atlasH = atlas.height
            for key in allKeys {
                let srcX = key.x * tileSize
                let srcY = key.y * tileSize
                let blitW = min(tileSize, atlasW - srcX)
                let blitH = min(tileSize, atlasH - srcY)
                if blitW <= 0 || blitH <= 0 { continue }
                tileGrid.updateTile(at: key) { tile in
                    blit.copy(
                        from: atlas,
                        sourceSlice: 0, sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                        sourceSize: MTLSize(width: blitW, height: blitH, depth: 1),
                        to: tile.texture,
                        destinationSlice: 0, destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                    )
                }
            }
            blit.endEncoding()
        }
        // === End atlas → tile blit block =================================

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Free all blur-adjustment textures and clear bookkeeping. Called on
    /// tool change away from blurAdjustment, or before re-allocating in
    /// beginBlurAdjustment.
    func endBlurAdjustment() {
        blurAdjustmentSource = nil
        blurAdjustmentPreview = nil
        blurAdjustmentScratch = nil
        blurAdjustmentMask = nil
        blurAdjustmentLayerId = nil
    }

    // MARK: - Real-time Blur Stroke (PR experimental — see DEPLOYMENT note)
    //
    // Per-stamp dispatch path that mirrors `renderBlurStroke` but spreads
    // the work across multiple command buffers so the blurred deposits
    // appear under the user's finger instead of all at once on lift.
    //
    // Lifecycle (caller-driven from MetalCanvasView's blur-stroke path):
    //   • `beginBlurStroke(...)` snapshots the layer + allocates the two
    //     intermediate textures (scratchH, scratchV). Snapshot is the
    //     stable source for every subsequent stamp — same invariant as
    //     the deferred path: stamps re-blur PRE-stroke pixels, never
    //     each other's deposits, so the final result matches.
    //   • `appendBlurStrokeStamps(_:)` runs the same H+V Gaussian +
    //     stamp deposit math as the deferred loop, but for ONE batch
    //     of new stamps at a time, on a fresh command buffer. Async
    //     commit (no waitUntilCompleted) — the GPU pipelines the work.
    //   • `endBlurStroke(completion:)` clears session state and fires
    //     the optional completion after the GPU drains.
    //   • `cancelBlurStroke()` clears session state without committing
    //     a finalisation buffer (called from touchesCancelled).
    //
    // The legacy `renderBlurStroke(...)` below is unchanged; non-blur
    // tools and the existing test surface still go through that path.

    private struct BlurStrokeSession {
        let strokeID: UUID
        let snapshot: MTLTexture
        let scratchH: MTLTexture
        let scratchV: MTLTexture
        let selectionMask: MTLTexture
        let settings: BrushSettings
        let viewport: SIMD2<Float>
        let sigma: Float
        let kernelHalfWidth: Int32
        let blurStrength: Float
        /// Tile grid captured at session start. Per-batch
        /// `appendBlurStrokeStamps` composes intersecting tiles into the
        /// shared atlas before depositing stamps, then blits the atlas
        /// back into the grid. Reference type, so the grid is the same
        /// instance throughout the stroke.
        let tileGrid: TileGrid
    }

    private var activeBlurStrokeSession: BlurStrokeSession?

    /// Begin a real-time blur stroke. Snapshots `layerTexture`, allocates
    /// the two intermediate scratch textures used for the H+V Gaussian
    /// passes, and rasterises the selection mask once for the whole
    /// stroke. Returns false if any GPU resource isn't available — caller
    /// should fall back to the deferred `renderBlurStroke` path.
    @discardableResult
    func beginBlurStroke(
        strokeID: UUID,
        tileGrid: TileGrid,
        settings: BrushSettings,
        screenSize: CGSize,
        selectionPath: [CGPoint]?
    ) -> Bool {
        // Defensive: end any prior session that didn't get cleaned up
        // (tool change mid-stroke, view teardown, etc.).
        activeBlurStrokeSession = nil

        guard stampBlurDepositPipelineState != nil,
              let snapshot = makeBlurIntermediateTexture(),
              let scratchH = makeBlurIntermediateTexture(),
              let scratchV = makeBlurIntermediateTexture(),
              let cb = commandQueue.makeCommandBuffer() else {
            dbgLog("⚠️ beginBlurStroke: pipeline or intermediate textures unavailable")
            return false
        }

        let mask = selectionMaskTexture(for: selectionPath, documentSize: screenSize) ?? noMaskTexture
        guard let selectionMask = mask else {
            dbgLog("⚠️ beginBlurStroke: selection mask unavailable")
            return false
        }

        // Compose every allocated tile into the snapshot texture at its
        // canvas-pixel position. The snapshot is the "pre-stroke" source
        // for every per-stamp Gaussian — capturing it from the tile grid
        // (instead of layer.texture which is stale post-4.5c) ensures
        // stamps re-blur the layer's CURRENT pixel state.
        if let blit = cb.makeBlitCommandEncoder() {
            let tileSize = tileGrid.tileSize
            let snapW = snapshot.width
            let snapH = snapshot.height
            for key in tileGrid.allocatedKeys() {
                guard let tile = tileGrid.tile(at: key) else { continue }
                let dstX = key.x * tileSize
                let dstY = key.y * tileSize
                let copyW = min(tileSize, snapW - dstX)
                let copyH = min(tileSize, snapH - dstY)
                if copyW <= 0 || copyH <= 0 { continue }
                blit.copy(
                    from: tile.texture,
                    sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                    to: snapshot,
                    destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
                )
            }
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()

        let sigma = max(0.0, Float(settings.size) * 0.5)
        let halfWidth = Self.gaussianHalfWidth(for: sigma)
        let blurStrength = max(0.0, min(1.0, settings.blurStrength))
        let viewport = SIMD2<Float>(Float(snapshot.width), Float(snapshot.height))

        activeBlurStrokeSession = BlurStrokeSession(
            strokeID: strokeID,
            snapshot: snapshot,
            scratchH: scratchH,
            scratchV: scratchV,
            selectionMask: selectionMask,
            settings: settings,
            viewport: viewport,
            sigma: sigma,
            kernelHalfWidth: halfWidth,
            blurStrength: blurStrength,
            tileGrid: tileGrid
        )
        return true
    }

    /// Run H+V Gaussian + stamp deposit for each point in `points` on
    /// a single fresh command buffer, async-committed. No-op if there's
    /// no active session (caller bailed before begin succeeded).
    func appendBlurStrokeStamps(_ points: [BrushStroke.StrokePoint], stampIndexBase: Int = 0) {
        guard !points.isEmpty,
              let s = activeBlurStrokeSession,
              let depositPipeline = stampBlurDepositPipelineState,
              let atlas = ensureCanvasStagingAtlas() else {
            return
        }

        // Back-pressure (blur-crash fix): this is the ONLY per-touchesMoved
        // stroke path that was async-committing command buffers WITHOUT
        // holding a strokeCommandSlots slot. Each buffer here carries two
        // scissored Gaussian passes per stamp — far heavier than a brush
        // deposit — so a fast 240 Hz Pencil scribble piled up in-flight
        // buffers past Metal's ~64-per-queue hard cap. Past the cap the
        // queue's dispatch thread traps (EXC_BREAKPOINT on
        // com.Metal.CommandQueueDispatch + libxpc "Malformed Mach
        // message" — the parked blur-brush crash). Same wait/signal
        // pattern as flushWetInkSubStroke / renderStroke: wait before
        // makeCommandBuffer, signal on every early exit, signal in the
        // completed handler.
        strokeCommandSlots.wait()
        guard let cb = commandQueue.makeCommandBuffer() else {
            strokeCommandSlots.signal()
            return
        }

        var uniforms = BrushUniforms(
            color: s.settings.color,
            size: Float(s.settings.size),
            opacity: Float(s.settings.opacity),
            hardness: Float(s.settings.hardness),
            tileOrigin: SIMD2<Float>(0, 0)
        )
        var blurStrength = s.blurStrength
        var viewportCopy = s.viewport

        let atlasW = atlas.width
        let atlasH = atlas.height

        // Accumulate per-stamp scissor rects into a batch bbox so we can
        // compose tile state for the bbox into the atlas before the
        // deposits run, and blit the modified atlas region back into the
        // tile grid afterwards.
        var batchBbox: CGRect = .null
        var stampPlans: [(stampIndex: Int, point: BrushStroke.StrokePoint, scissor: MTLScissorRect)] = []
        stampPlans.reserveCapacity(points.count)

        for (index, point) in points.enumerated() {
            let safePressure: CGFloat = {
                guard point.pressure.isFinite else { return 1.0 }
                return max(0, min(1, point.pressure))
            }()

            let radiusOnLayer = max(1, Int(ceil(s.settings.size * 0.5 * safePressure)))
            let kernelMargin = Int(s.kernelHalfWidth) + 4
            let footprint = radiusOnLayer + kernelMargin

            let cx = Int(point.location.x.rounded())
            let cy = Int(point.location.y.rounded())

            let x0 = max(0, cx - footprint)
            let y0 = max(0, cy - footprint)
            let x1 = min(atlasW, cx + footprint)
            let y1 = min(atlasH, cy + footprint)
            let rectW = x1 - x0
            let rectH = y1 - y0
            if rectW <= 0 || rectH <= 0 { continue }
            let scissor = MTLScissorRect(x: x0, y: y0, width: rectW, height: rectH)
            stampPlans.append((stampIndex: stampIndexBase + index, point: point, scissor: scissor))

            let stampRect = CGRect(x: x0, y: y0, width: rectW, height: rectH)
            batchBbox = batchBbox.isNull ? stampRect : batchBbox.union(stampRect)
        }

        if stampPlans.isEmpty {
            cb.addCompletedHandler { [weak self] _ in
                self?.strokeCommandSlots.signal()
            }
            cb.commit()
            return
        }

        // Compose tile state for the batch bbox into the atlas so the
        // deposit's loadAction=.load reads current layer pixels.
        let bboxKeys = (batchBbox.isNull || batchBbox.isEmpty)
            ? []
            : s.tileGrid.tilesIntersecting(batchBbox)
        let tileSize = s.tileGrid.tileSize

        #if DEBUG
        CanvasStrokeDiagnostics.log("blurRealtime flush stroke=\(CanvasStrokeDiagnostics.shortID(s.strokeID)) tool=blur \(CanvasStrokeDiagnostics.ranges(for: points)) bbox={\(CanvasStrokeDiagnostics.format(batchBbox))} bboxKeys=\(CanvasStrokeDiagnostics.tileSummary(bboxKeys)) settings{\(CanvasStrokeDiagnostics.format(s.settings))}")
        #endif

        // Source B fix: tile-aligned clear before compose. The post-batch
        // blit-back at this function's tail (line ~5180) copies the FULL
        // tile rect from atlas to tile for each bbox tile, so an
        // in-tile-outside-bbox sliver of stale pixels would survive into
        // the freshly-allocated tile via ensureTile→blit.
        if let clearRegion = atlasRegion(coveringTiles: bboxKeys, tileSize: tileSize) {
            clearCanvasStagingAtlasRegion(clearRegion, on: cb)
        }

        if !bboxKeys.isEmpty, let composeBlit = cb.makeBlitCommandEncoder() {
            for key in bboxKeys {
                guard let tile = s.tileGrid.tile(at: key) else { continue }
                let dstX = key.x * tileSize
                let dstY = key.y * tileSize
                let copyW = min(tileSize, atlasW - dstX)
                let copyH = min(tileSize, atlasH - dstY)
                if copyW <= 0 || copyH <= 0 { continue }
                composeBlit.copy(
                    from: tile.texture,
                    sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                    to: atlas,
                    destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
                )
            }
            composeBlit.endEncoding()
        }

        for plan in stampPlans {
            let point = plan.point
            let scissor = plan.scissor
            let safePressure: CGFloat = {
                guard point.pressure.isFinite else { return 1.0 }
                return max(0, min(1, point.pressure))
            }()
            uniforms.pressure = Float(safePressure)
            let safePressureAlpha: CGFloat = {
                guard point.pressureAlpha.isFinite else { return 1.0 }
                return max(0, min(1, point.pressureAlpha))
            }()
            uniforms.pressureAlpha = Float(safePressureAlpha)

            // Pass 1: horizontal Gaussian, scissored.
            runGaussianPass(
                commandBuffer: cb,
                target: s.scratchH,
                source: s.snapshot,
                direction: SIMD2<Float>(1.0 / Float(s.snapshot.width), 0),
                sigma: s.sigma,
                kernelHalfWidth: s.kernelHalfWidth,
                scissorRect: scissor
            )

            // Pass 2: vertical Gaussian, scissored.
            runGaussianPass(
                commandBuffer: cb,
                target: s.scratchV,
                source: s.scratchH,
                direction: SIMD2<Float>(0, 1.0 / Float(s.scratchH.height)),
                sigma: s.sigma,
                kernelHalfWidth: s.kernelHalfWidth,
                scissorRect: scissor
            )

            // Pass 3: stamp deposit into the staging atlas.
            let depositDescriptor = MTLRenderPassDescriptor()
            depositDescriptor.colorAttachments[0].texture = atlas
            depositDescriptor.colorAttachments[0].loadAction = .load
            depositDescriptor.colorAttachments[0].storeAction = .store
            guard let depositEncoder = cb.makeRenderCommandEncoder(descriptor: depositDescriptor) else {
                continue
            }
            depositEncoder.setRenderPipelineState(depositPipeline)
            depositEncoder.setScissorRect(scissor)
            depositEncoder.setFragmentTexture(s.scratchV, index: 0)
            depositEncoder.setFragmentTexture(s.selectionMask, index: 2)

            var stampPosition = SIMD2<Float>(Float(point.location.x), Float(point.location.y))
            #if DEBUG
            CanvasStrokeDiagnostics.log("stamp stage=blurRealtime stroke=\(CanvasStrokeDiagnostics.shortID(s.strokeID)) idx=\(plan.stampIndex) tool=blur \(CanvasStrokeDiagnostics.stampSource(point)) uniforms{\(CanvasStrokeDiagnostics.uniforms(size: uniforms.size, opacity: uniforms.opacity, hardness: uniforms.hardness, pressure: uniforms.pressure, pressureAlpha: uniforms.pressureAlpha, color: uniforms.color))}")
            #endif
            depositEncoder.setVertexBytes(&stampPosition, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            depositEncoder.setVertexBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 1)
            depositEncoder.setVertexBytes(&viewportCopy, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            depositEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)
            depositEncoder.setFragmentBytes(&blurStrength, length: MemoryLayout<Float>.stride, index: 1)
            depositEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
            depositEncoder.endEncoding()
        }

        // === Phase 4.5c: blit modified atlas region into tile grid ========
        //
        // Mirror this batch's deposits into the tile grid by blitting
        // every tile intersecting the accumulated stamp bbox from the
        // post-deposit atlas. Same command buffer as the deposits — Metal
        // serialises encoders within a buffer, so the blit reads the
        // post-deposit atlas. Async commit (no waitUntilCompleted) per
        // the function's existing contract.
        if !bboxKeys.isEmpty {
            for key in bboxKeys {
                _ = s.tileGrid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: cb)
            }
            if let blit = cb.makeBlitCommandEncoder() {
                for key in bboxKeys {
                    let srcX = key.x * tileSize
                    let srcY = key.y * tileSize
                    let blitW = min(tileSize, atlasW - srcX)
                    let blitH = min(tileSize, atlasH - srcY)
                    if blitW <= 0 || blitH <= 0 { continue }
                    s.tileGrid.updateTile(at: key) { tile in
                        blit.copy(
                            from: atlas,
                            sourceSlice: 0, sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                            sourceSize: MTLSize(width: blitW, height: blitH, depth: 1),
                            to: tile.texture,
                            destinationSlice: 0, destinationLevel: 0,
                            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                        )
                    }
                }
                blit.endEncoding()
            }
        }
        // === End atlas → tile blit block =================================

        #if DEBUG
        CanvasStrokeDiagnostics.log("blurRealtime scheduled stroke=\(CanvasStrokeDiagnostics.shortID(s.strokeID)) tool=blur allocatedAfter=\(CanvasStrokeDiagnostics.tileSummary(s.tileGrid.allocatedKeys()))")
        #endif

        cb.addCompletedHandler { [weak self] _ in
            self?.strokeCommandSlots.signal()
        }
        cb.commit()
        // No waitUntilCompleted — let the GPU pipeline this batch behind
        // any prior appendBlurStrokeStamps batch on the same queue. The
        // slot held since the wait above bounds how many of these batches
        // can be in flight at once.
    }

    /// Tear down the session. If `completion` is provided, fires after
    /// the GPU drains via a no-op finalisation buffer; the caller (the
    /// touch handler that records HistoryAction.stroke) needs that
    /// drain to happen before calling captureSnapshot or the AFTER
    /// snapshot races against in-flight stamp deposits.
    func endBlurStroke(completion: (() -> Void)? = nil) {
        guard activeBlurStrokeSession != nil else {
            completion?()
            return
        }
        activeBlurStrokeSession = nil

        if let completion = completion, let cb = commandQueue.makeCommandBuffer() {
            cb.addCompletedHandler { _ in
                DispatchQueue.main.async { completion() }
            }
            cb.commit()
        } else {
            completion?()
        }
    }

    /// Free the in-progress session without firing any finalisation
    /// buffer. Called from touchesCancelled / tool-change paths.
    func cancelBlurStroke() {
        activeBlurStrokeSession = nil
    }

    var hasActiveBlurStroke: Bool {
        activeBlurStrokeSession != nil
    }

    // MARK: - Brush-blur Stroke (paints Gaussian blur freeform)

    /// Per-stroke blur dispatch — mirrors `renderStroke` but performs a
    /// scissored two-pass Gaussian + stamp deposit at each interpolated point.
    /// Deferred batch: every stamp is enqueued on a single command buffer at
    /// touchesEnded, same as the brush.
    func renderBlurStroke(
        _ stroke: BrushStroke,
        tileGrid: TileGrid,
        screenSize: CGSize,
        selectionPath: [CGPoint]?,
        completion: @escaping () -> Void
    ) {
        guard let depositPipeline = stampBlurDepositPipelineState,
              let snapshot = makeBlurIntermediateTexture(),
              let scratchH = makeBlurIntermediateTexture(),
              let scratchV = makeBlurIntermediateTexture(),
              let atlas = ensureCanvasStagingAtlas() else {
            dbgLog("⚠️ renderBlurStroke: pipeline or intermediate textures unavailable")
            completion()
            return
        }

        // Same strokeCommandSlots back-pressure as renderStroke /
        // appendBlurStrokeStamps — one async buffer per stroke, but it
        // still counts against Metal's per-queue in-flight cap.
        strokeCommandSlots.wait()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            strokeCommandSlots.signal()
            dbgLog("⚠️ renderBlurStroke: command buffer unavailable")
            completion()
            return
        }

        // Selection mask (PR 3) — rasterized once at stroke start, sampled
        // per stamp by stampBlurDepositShader. nil/empty path → 1×1
        // noMaskTexture (no clipping).
        let selectionMask = selectionMaskTexture(for: selectionPath, documentSize: screenSize) ?? noMaskTexture

        // Compose every allocated tile into the snapshot at canvas-pixel
        // position so the per-stamp Gaussian re-blurs the layer's CURRENT
        // pixel state. Replaces the prior layerTexture blit (which would
        // sample stale monolithic pixels post-4.5c).
        let tileSize = tileGrid.tileSize
        if let composeBlit = commandBuffer.makeBlitCommandEncoder() {
            let snapW = snapshot.width
            let snapH = snapshot.height
            for key in tileGrid.allocatedKeys() {
                guard let tile = tileGrid.tile(at: key) else { continue }
                let dstX = key.x * tileSize
                let dstY = key.y * tileSize
                let copyW = min(tileSize, snapW - dstX)
                let copyH = min(tileSize, snapH - dstY)
                if copyW <= 0 || copyH <= 0 { continue }
                composeBlit.copy(
                    from: tile.texture,
                    sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                    to: snapshot,
                    destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
                )
            }
            composeBlit.endEncoding()
        }

        // Sigma derived from brush size only (per directive). Hardness drives
        // the stamp's edge falloff in the deposit shader; it does not affect
        // kernel width.
        let sigma = max(0.0, Float(stroke.settings.size) * 0.5)
        let halfWidth = Self.gaussianHalfWidth(for: sigma)
        let blurStrengthValue = max(0.0, min(1.0, stroke.settings.blurStrength))

        var uniforms = BrushUniforms(
            color: stroke.settings.color,
            size: Float(stroke.settings.size),
            opacity: Float(stroke.settings.opacity),
            hardness: Float(stroke.settings.hardness),
            tileOrigin: SIMD2<Float>(0, 0)
        )
        var blurStrength = blurStrengthValue

        let atlasW = atlas.width
        let atlasH = atlas.height
        let viewport = SIMD2<Float>(Float(atlasW), Float(atlasH))
        var viewportCopy = viewport

        // First pass: compute every stamp's scissor, accumulate strokeBbox,
        // then compose tile state for that bbox into the atlas. Second pass
        // runs the per-stamp Gaussian + deposit into atlas.
        var strokeBbox: CGRect = .null
        var stampPlans: [(stampIndex: Int, point: BrushStroke.StrokePoint, scissor: MTLScissorRect)] = []
        stampPlans.reserveCapacity(stroke.points.count)

        for (index, point) in stroke.points.enumerated() {
            let safePressure: CGFloat = {
                guard point.pressure.isFinite else { return 1.0 }
                return max(0, min(1, point.pressure))
            }()

            let radiusOnLayer = max(1, Int(ceil(stroke.settings.size * 0.5 * safePressure)))
            let kernelMargin = Int(halfWidth) + 4
            let footprint = radiusOnLayer + kernelMargin

            let cx = Int(point.location.x.rounded())
            let cy = Int(point.location.y.rounded())

            let x0 = max(0, cx - footprint)
            let y0 = max(0, cy - footprint)
            let x1 = min(atlasW, cx + footprint)
            let y1 = min(atlasH, cy + footprint)
            let rectW = x1 - x0
            let rectH = y1 - y0
            if rectW <= 0 || rectH <= 0 { continue }
            let scissor = MTLScissorRect(x: x0, y: y0, width: rectW, height: rectH)
            stampPlans.append((stampIndex: index, point: point, scissor: scissor))

            let stampRect = CGRect(x: x0, y: y0, width: rectW, height: rectH)
            strokeBbox = strokeBbox.isNull ? stampRect : strokeBbox.union(stampRect)
        }

        let bboxKeys = (strokeBbox.isNull || strokeBbox.isEmpty)
            ? []
            : tileGrid.tilesIntersecting(strokeBbox)

        #if DEBUG
        CanvasStrokeDiagnostics.log("renderBlurStroke enter stroke=\(CanvasStrokeDiagnostics.shortID(stroke.id)) tool=\(stroke.tool) \(CanvasStrokeDiagnostics.ranges(for: stroke.points)) bbox={\(CanvasStrokeDiagnostics.format(strokeBbox))} bboxKeys=\(CanvasStrokeDiagnostics.tileSummary(bboxKeys)) allocatedBefore=\(CanvasStrokeDiagnostics.tileSummary(tileGrid.allocatedKeys())) settings{\(CanvasStrokeDiagnostics.format(stroke.settings))}")
        #endif

        // Source B fix: tile-aligned clear before compose. Same shape as
        // appendBlurStrokeStamps (this is the deferred-batch variant).
        // Tile-aligned (not raw bbox) because the post-stroke blit-back
        // at the function's tail copies the FULL tile rect from atlas
        // to tile; the in-tile-outside-bbox sliver of an unallocated
        // tile must be cleared, or it leaks into the freshly-allocated
        // tile.
        if let clearRegion = atlasRegion(coveringTiles: bboxKeys, tileSize: tileSize) {
            clearCanvasStagingAtlasRegion(clearRegion, on: commandBuffer)
        }

        // Compose bbox tile state into atlas so the deposit's loadAction=.load
        // reads current layer pixels.
        if !bboxKeys.isEmpty, let atlasCompose = commandBuffer.makeBlitCommandEncoder() {
            for key in bboxKeys {
                guard let tile = tileGrid.tile(at: key) else { continue }
                let dstX = key.x * tileSize
                let dstY = key.y * tileSize
                let copyW = min(tileSize, atlasW - dstX)
                let copyH = min(tileSize, atlasH - dstY)
                if copyW <= 0 || copyH <= 0 { continue }
                atlasCompose.copy(
                    from: tile.texture,
                    sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                    to: atlas,
                    destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
                )
            }
            atlasCompose.endEncoding()
        }

        for plan in stampPlans {
            let point = plan.point
            let scissor = plan.scissor
            let safePressure: CGFloat = {
                guard point.pressure.isFinite else { return 1.0 }
                return max(0, min(1, point.pressure))
            }()
            uniforms.pressure = Float(safePressure)
            let safePressureAlpha: CGFloat = {
                guard point.pressureAlpha.isFinite else { return 1.0 }
                return max(0, min(1, point.pressureAlpha))
            }()
            uniforms.pressureAlpha = Float(safePressureAlpha)

            runGaussianPass(
                commandBuffer: commandBuffer,
                target: scratchH,
                source: snapshot,
                direction: SIMD2<Float>(1.0 / Float(snapshot.width), 0),
                sigma: sigma,
                kernelHalfWidth: halfWidth,
                scissorRect: scissor
            )
            runGaussianPass(
                commandBuffer: commandBuffer,
                target: scratchV,
                source: scratchH,
                direction: SIMD2<Float>(0, 1.0 / Float(scratchH.height)),
                sigma: sigma,
                kernelHalfWidth: halfWidth,
                scissorRect: scissor
            )

            let depositDescriptor = MTLRenderPassDescriptor()
            depositDescriptor.colorAttachments[0].texture = atlas
            depositDescriptor.colorAttachments[0].loadAction = .load
            depositDescriptor.colorAttachments[0].storeAction = .store
            guard let depositEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: depositDescriptor) else {
                continue
            }
            depositEncoder.setRenderPipelineState(depositPipeline)
            depositEncoder.setScissorRect(scissor)
            depositEncoder.setFragmentTexture(scratchV, index: 0)
            depositEncoder.setFragmentTexture(selectionMask, index: 2)

            var stampPosition = SIMD2<Float>(Float(point.location.x), Float(point.location.y))
            #if DEBUG
            CanvasStrokeDiagnostics.log("stamp stage=renderBlurStroke stroke=\(CanvasStrokeDiagnostics.shortID(stroke.id)) idx=\(plan.stampIndex) tool=\(stroke.tool) \(CanvasStrokeDiagnostics.stampSource(point)) uniforms{\(CanvasStrokeDiagnostics.uniforms(size: uniforms.size, opacity: uniforms.opacity, hardness: uniforms.hardness, pressure: uniforms.pressure, pressureAlpha: uniforms.pressureAlpha, color: uniforms.color))}")
            #endif
            depositEncoder.setVertexBytes(&stampPosition, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            depositEncoder.setVertexBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 1)
            depositEncoder.setVertexBytes(&viewportCopy, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            depositEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)
            depositEncoder.setFragmentBytes(&blurStrength, length: MemoryLayout<Float>.stride, index: 1)
            depositEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
            depositEncoder.endEncoding()
        }

        // === Phase 4.5c: blit stroke-bbox region from atlas → tile grid ===
        if !bboxKeys.isEmpty {
            for key in bboxKeys {
                _ = tileGrid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: commandBuffer)
            }
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                for key in bboxKeys {
                    let srcX = key.x * tileSize
                    let srcY = key.y * tileSize
                    let blitW = min(tileSize, atlasW - srcX)
                    let blitH = min(tileSize, atlasH - srcY)
                    if blitW <= 0 || blitH <= 0 { continue }
                    tileGrid.updateTile(at: key) { tile in
                        blit.copy(
                            from: atlas,
                            sourceSlice: 0, sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                            sourceSize: MTLSize(width: blitW, height: blitH, depth: 1),
                            to: tile.texture,
                            destinationSlice: 0, destinationLevel: 0,
                            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                        )
                    }
                }
                blit.endEncoding()
            }
        }
        // === End atlas → tile blit block =================================

        #if DEBUG
        CanvasStrokeDiagnostics.log("renderBlurStroke scheduled stroke=\(CanvasStrokeDiagnostics.shortID(stroke.id)) tool=\(stroke.tool) allocatedAfter=\(CanvasStrokeDiagnostics.tileSummary(tileGrid.allocatedKeys()))")
        #endif

        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.strokeCommandSlots.signal()
            DispatchQueue.main.async { completion() }
        }
        commandBuffer.commit()
    }

    // MARK: - Smudge Stroke (PR 2)

    /// Layout-matched twin of the Metal `SmudgeUniforms` struct (Shaders.metal).
    /// `_pad` makes Swift's `MemoryLayout<...>.stride` 32 bytes — same as the
    /// Metal struct, which rounds up to its 8-byte (float2) alignment — so
    /// `setFragmentBytes(_:length:index:)` writes a buffer the shader can
    /// read without UB. Memberwise init takes only the meaningful fields.
    private struct SmudgeUniformsCPU {
        var stampCenter: SIMD2<Float>
        var patchHalfSize: SIMD2<Float>
        var layerSize: SIMD2<Float>
        var weight: Float
        var _pad: Float = 0

        init(stampCenter: SIMD2<Float>,
             patchHalfSize: SIMD2<Float>,
             layerSize: SIMD2<Float>,
             weight: Float) {
            self.stampCenter = stampCenter
            self.patchHalfSize = patchHalfSize
            self.layerSize = layerSize
            self.weight = weight
        }
    }

    /// Allocate a smudge patch texture sized to fit a stamp of the given
    /// brush size (≥ ceil(brushSize) on each side, capped to keep memory
    /// sane on the lowest-spec target). Format matches the active layer's
    /// pixelFormat (bgra8Unorm) so the patch can be sampled directly from
    /// the layer with the same color space and premultiplication.
    private func makeSmudgePatchTexture(brushSize: CGFloat) -> MTLTexture? {
        // Patch is 1:1 layer-pixel:patch-pixel near the stamp center, so the
        // patch's pixel side equals the stamp's full pixel diameter at max
        // pressure (≈ brushSize). Cap at 256 — beyond that the patch starts
        // costing real memory and the smudge feel doesn't meaningfully
        // improve (large brushes also have soft falloff so the patch's
        // outer rows contribute little to the deposit).
        let raw = max(2, Int(ceil(brushSize)))
        let side = min(raw, 256)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: side,
            height: side,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private  // GPU-only — never read by CPU.
        return device.makeTexture(descriptor: descriptor)
    }

    /// Clear a patch texture to fully transparent. Uses a one-shot
    /// command buffer; cheap (textures are tiny). Sync because callers
    /// expect a cleared patch on return from `beginSmudgeStroke`.
    private func clearSmudgePatch(_ patch: MTLTexture) {
        guard let cb = commandQueue.makeCommandBuffer() else { return }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = patch
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        descriptor.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: descriptor) {
            enc.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
    }

    /// Allocate the front/back smudge patches and zero them. Called from
    /// `MetalCanvasView.touchesBegan` when the smudge tool is active. Caller
    /// records the active layer's id; later calls to `renderSmudgeStamps`
    /// assert the layer hasn't changed mid-stroke (textures are sized to
    /// the layer at this point in time).
    func beginSmudgeStroke(strokeID: UUID,
                           brushSize: CGFloat,
                           layerId: UUID,
                           selectionPath: [CGPoint]?,
                           documentSize: CGSize) -> Bool {
        endSmudgeStroke()
        guard let front = makeSmudgePatchTexture(brushSize: brushSize),
              let back  = makeSmudgePatchTexture(brushSize: brushSize) else {
            dbgLog("⚠️ beginSmudgeStroke: failed to allocate patch textures")
            return false
        }
        clearSmudgePatch(front)
        clearSmudgePatch(back)
        smudgePatchFront = front
        smudgePatchBack = back
        smudgePatchHalfSize = Float(brushSize) * 0.5
        smudgeStampIndex = 0
        smudgeStrokeLayerId = layerId
        smudgeDiagnosticStrokeID = strokeID
        // PR 3 — selection mask cached for the duration of the stroke.
        // Selection geometry is fixed across a stroke, so we rasterize
        // once here and reuse for every patch-update + deposit pair.
        // Falls back to noMaskTexture for nil/empty selectionPath.
        smudgeSelectionMask = selectionMaskTexture(for: selectionPath, documentSize: documentSize) ?? noMaskTexture
        return true
    }

    /// Free patch textures and clear bookkeeping. Idempotent — safe to call
    /// from `touchesEnded`, `touchesCancelled`, or `beginSmudgeStroke`'s
    /// startup reset.
    func endSmudgeStroke() {
        smudgePatchFront = nil
        smudgePatchBack = nil
        smudgePatchHalfSize = 0
        smudgeStampIndex = 0
        smudgeStrokeLayerId = nil
        smudgeDiagnosticStrokeID = nil
        smudgeSelectionMask = nil
    }

    /// Dispatch a batch of smudge stamps — one (patch-update, deposit) pair
    /// per stamp — on a single command buffer. Called from
    /// `MetalCanvasView.touchesMoved` per coalesced sub-batch (NOT per
    /// stamp). Patches mutate in-order on the GPU; we swap front/back in
    /// Swift after each pickup pass so the next pickup reads the just-
    /// written carry.
    ///
    /// First-stamp pickup-only: when the renderer's internal stamp counter
    /// is 0, the first stamp in this batch dispatches a pickup at weight =
    /// 1.0 (so `mix(empty_patch, layer, 1.0)` initialises the patch to the
    /// layer sample) and skips its deposit. All subsequent stamps use
    /// weight = `settings.smudgeStrength * pressure` and deposit normally.
    func renderSmudgeStamps(
        _ stamps: [BrushStroke.StrokePoint],
        settings: BrushSettings,
        layerId: UUID,
        tileGrid: TileGrid,
        screenSize: CGSize
    ) {
        guard !stamps.isEmpty else { return }
        guard let patchUpdatePipeline = smudgePatchUpdatePipelineState,
              let depositPipeline = smudgeDepositPipelineState,
              var front = smudgePatchFront,
              var back = smudgePatchBack,
              let atlas = ensureCanvasStagingAtlas() else {
            dbgLog("⚠️ renderSmudgeStamps: pipeline / patch / atlas unavailable")
            return
        }
        // Hard sanity: layer must not change mid-stroke (patch is sized to
        // the layer captured at beginSmudgeStroke). If this trips, the
        // touch handler let the user switch layers under an active stroke
        // — that's a logic bug, not user error.
        assert(smudgeStrokeLayerId == layerId,
               "Smudge layer changed mid-stroke (was \(String(describing: smudgeStrokeLayerId)), now \(layerId))")
        guard smudgeStrokeLayerId == layerId else {
            dbgLog("⚠️ renderSmudgeStamps: layerId mismatch — refusing to render")
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let strength = max(0, min(1, settings.smudgeStrength))
        let halfSize = SIMD2<Float>(smudgePatchHalfSize, smudgePatchHalfSize)
        let atlasW = atlas.width
        let atlasH = atlas.height
        let layerSize = SIMD2<Float>(Float(atlasW), Float(atlasH))
        var viewport = SIMD2<Float>(Float(atlasW), Float(atlasH))

        // Pre-compute the bbox covering every stamp's pickup region
        // (stampCenter ± patchHalfSize). The patch-update samples layer
        // pixels in that region, and the deposit footprint is bounded by
        // the same region (radius ≤ halfSize), so a single composed bbox
        // serves both reads and the post-batch blit-back.
        let pickupHalf = Int(ceil(CGFloat(smudgePatchHalfSize))) + 4
        var composeBbox: CGRect = .null
        for stamp in stamps {
            let cx = Int(stamp.location.x.rounded())
            let cy = Int(stamp.location.y.rounded())
            let x0 = max(0, cx - pickupHalf)
            let y0 = max(0, cy - pickupHalf)
            let x1 = min(atlasW, cx + pickupHalf)
            let y1 = min(atlasH, cy + pickupHalf)
            let rectW = x1 - x0
            let rectH = y1 - y0
            if rectW <= 0 || rectH <= 0 { continue }
            let stampRect = CGRect(x: x0, y: y0, width: rectW, height: rectH)
            composeBbox = composeBbox.isNull ? stampRect : composeBbox.union(stampRect)
        }

        let composeKeys = (composeBbox.isNull || composeBbox.isEmpty)
            ? []
            : tileGrid.tilesIntersecting(composeBbox)
        let tileSize = tileGrid.tileSize

        #if DEBUG
        let diagnosticStrokeID = smudgeDiagnosticStrokeID
        if let diagnosticStrokeID {
            CanvasStrokeDiagnostics.log("smudge flush stroke=\(CanvasStrokeDiagnostics.shortID(diagnosticStrokeID)) tool=smudge \(CanvasStrokeDiagnostics.ranges(for: stamps)) bbox={\(CanvasStrokeDiagnostics.format(composeBbox))} bboxKeys=\(CanvasStrokeDiagnostics.tileSummary(composeKeys)) settings{\(CanvasStrokeDiagnostics.format(settings))}")
        }
        #endif

        // Source B fix: tile-aligned clear before compose. Smudge has
        // TWO atlas read paths (patch-update samples atlas as a texture
        // input; deposit reads atlas via loadAction=.load) — both would
        // pull stale pixels from unallocated bbox tiles without this
        // clear. Tile-aligned (not raw bbox) for the same reason as the
        // other dual-write functions: the post-batch blit-back copies
        // whole tile rects from atlas to tile.
        if let clearRegion = atlasRegion(coveringTiles: composeKeys, tileSize: tileSize) {
            clearCanvasStagingAtlasRegion(clearRegion, on: commandBuffer)
        }

        // Compose-from-tiles into atlas so the per-stamp patch-update + the
        // deposit's loadAction=.load both read current layer pixels.
        if !composeKeys.isEmpty, let composeBlit = commandBuffer.makeBlitCommandEncoder() {
            for key in composeKeys {
                guard let tile = tileGrid.tile(at: key) else { continue }
                let dstX = key.x * tileSize
                let dstY = key.y * tileSize
                let copyW = min(tileSize, atlasW - dstX)
                let copyH = min(tileSize, atlasH - dstY)
                if copyW <= 0 || copyH <= 0 { continue }
                composeBlit.copy(
                    from: tile.texture,
                    sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                    to: atlas,
                    destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
                )
            }
            composeBlit.endEncoding()
        }

        // PR 3 — selection mask cached at beginSmudgeStroke. Defensive
        // fallback: if it's unexpectedly nil (e.g. caller skipped begin),
        // bind the 1×1 noMaskTexture so the shader's mask multiply is a
        // no-op rather than reading from an unbound slot.
        let selectionMask = smudgeSelectionMask ?? noMaskTexture

        // Brush uniforms — color is unused by the deposit shader (smudge
        // doesn't paint the brush color), but the struct is shared with
        // the brush vertex shader so we still pass it. `pressure` is set
        // per-stamp below.
        var brushUniforms = BrushUniforms(
            color: settings.color,
            size: Float(settings.size),
            opacity: Float(settings.opacity),
            hardness: Float(settings.hardness),
            tileOrigin: SIMD2<Float>(0, 0)
        )

        for stamp in stamps {
            let currentStampIndex = smudgeStampIndex
            let safePressure: Float = {
                guard stamp.pressure.isFinite else { return 1.0 }
                return Float(max(0, min(1, stamp.pressure)))
            }()
            let safePressureAlpha: Float = {
                guard stamp.pressureAlpha.isFinite else { return 1.0 }
                return Float(max(0, min(1, stamp.pressureAlpha)))
            }()

            let isFirstStamp = (smudgeStampIndex == 0)
            // Pickup weight: first stamp is full-replace (initialise patch
            // to layer sample); subsequent stamps mix at strength * pressure.
            let pickupWeight: Float = isFirstStamp ? 1.0 : (strength * safePressure)

            let stampCenter = SIMD2<Float>(Float(stamp.location.x), Float(stamp.location.y))
            var smudgeUniforms = SmudgeUniformsCPU(
                stampCenter: stampCenter,
                patchHalfSize: halfSize,
                layerSize: layerSize,
                weight: pickupWeight
            )

            #if DEBUG
            if let diagnosticStrokeID {
                CanvasStrokeDiagnostics.log("stamp stage=smudgePickup stroke=\(CanvasStrokeDiagnostics.shortID(diagnosticStrokeID)) idx=\(currentStampIndex) tool=smudge \(CanvasStrokeDiagnostics.stampSource(stamp)) pickupWeight=\(CanvasStrokeDiagnostics.format(pickupWeight))")
            }
            #endif

            // ----- Pass 1: patch update — full quad on the BACK patch.
            // Reads FRONT patch + atlas (composed layer state), mixes,
            // writes BACK.
            let updateDescriptor = MTLRenderPassDescriptor()
            updateDescriptor.colorAttachments[0].texture = back
            updateDescriptor.colorAttachments[0].loadAction = .dontCare
            updateDescriptor.colorAttachments[0].storeAction = .store
            guard let updateEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: updateDescriptor) else {
                continue
            }
            updateEncoder.setRenderPipelineState(patchUpdatePipeline)
            updateEncoder.setFragmentTexture(front, index: 0)
            updateEncoder.setFragmentTexture(atlas, index: 1)
            updateEncoder.setFragmentTexture(selectionMask, index: 2)
            updateEncoder.setFragmentBytes(&smudgeUniforms, length: MemoryLayout<SmudgeUniformsCPU>.stride, index: 0)
            updateEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            updateEncoder.endEncoding()

            // After the pickup pass, BACK holds the just-updated carry.
            // Swap so it becomes the new FRONT for the deposit + next stamp.
            swap(&front, &back)

            // ----- Pass 2: deposit — point sprite into the layer. Skipped
            // for the first stamp (patch was empty before pickup; the
            // pickup just initialised it, nothing to deposit yet).
            if !isFirstStamp {
                let radiusOnLayer = max(1, Int(ceil(settings.size * 0.5 * CGFloat(safePressure))))
                let footprint = radiusOnLayer + 4  // small margin for soft edges
                let cx = Int(stamp.location.x.rounded())
                let cy = Int(stamp.location.y.rounded())
                let x0 = max(0, cx - footprint)
                let y0 = max(0, cy - footprint)
                let x1 = min(atlasW, cx + footprint)
                let y1 = min(atlasH, cy + footprint)
                let rectW = x1 - x0
                let rectH = y1 - y0
                if rectW > 0 && rectH > 0 {
                    let scissor = MTLScissorRect(x: x0, y: y0, width: rectW, height: rectH)

                    let depositDescriptor = MTLRenderPassDescriptor()
                    depositDescriptor.colorAttachments[0].texture = atlas
                    depositDescriptor.colorAttachments[0].loadAction = .load
                    depositDescriptor.colorAttachments[0].storeAction = .store
                    if let depositEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: depositDescriptor) {
                        depositEncoder.setRenderPipelineState(depositPipeline)
                        depositEncoder.setScissorRect(scissor)
                        depositEncoder.setFragmentTexture(front, index: 0)  // updated patch
                        depositEncoder.setFragmentTexture(selectionMask, index: 2)

                        brushUniforms.pressure = safePressure
                        brushUniforms.pressureAlpha = safePressureAlpha

                        var stampPosition = stampCenter
                        #if DEBUG
                        if let diagnosticStrokeID {
                            CanvasStrokeDiagnostics.log("stamp stage=smudgeDeposit stroke=\(CanvasStrokeDiagnostics.shortID(diagnosticStrokeID)) idx=\(currentStampIndex) tool=smudge \(CanvasStrokeDiagnostics.stampSource(stamp)) uniforms{\(CanvasStrokeDiagnostics.uniforms(size: brushUniforms.size, opacity: brushUniforms.opacity, hardness: brushUniforms.hardness, pressure: brushUniforms.pressure, pressureAlpha: brushUniforms.pressureAlpha, color: brushUniforms.color))}")
                        }
                        #endif
                        depositEncoder.setVertexBytes(&stampPosition, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                        depositEncoder.setVertexBytes(&brushUniforms, length: MemoryLayout<BrushUniforms>.stride, index: 1)
                        depositEncoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
                        depositEncoder.setFragmentBytes(&brushUniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)
                        depositEncoder.setFragmentBytes(&smudgeUniforms, length: MemoryLayout<SmudgeUniformsCPU>.stride, index: 1)
                        depositEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
                        depositEncoder.endEncoding()
                    }
                }
            }

            smudgeStampIndex += 1
        }

        // Persist the (possibly swapped) patch refs so the next batch picks
        // up where this one left off. `front` here points at whatever was
        // last written (the most recent BACK after the final swap).
        smudgePatchFront = front
        smudgePatchBack = back

        // === Phase 4.5c: blit modified atlas region into tile grid ========
        //
        // Mirror this batch's deposits into the tile grid by blitting
        // every tile in composeBbox from the post-deposit atlas. Same
        // command buffer as the deposits — Metal serialises encoders
        // within a buffer, so the blit reads the post-deposit atlas.
        // composeBbox covers every stamp's pickup region (≥ deposit
        // footprint), so the blit-back stays in sync with what the
        // deposits actually changed.
        //
        // Async commit (no waitUntilCompleted) per the function's hot-
        // path contract. Subsequent ops on the same queue serialise
        // behind this batch.
        if !composeKeys.isEmpty {
            for key in composeKeys {
                _ = tileGrid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: commandBuffer)
            }
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                for key in composeKeys {
                    let srcX = key.x * tileSize
                    let srcY = key.y * tileSize
                    let blitW = min(tileSize, atlasW - srcX)
                    let blitH = min(tileSize, atlasH - srcY)
                    if blitW <= 0 || blitH <= 0 { continue }
                    tileGrid.updateTile(at: key) { tile in
                        blit.copy(
                            from: atlas,
                            sourceSlice: 0, sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                            sourceSize: MTLSize(width: blitW, height: blitH, depth: 1),
                            to: tile.texture,
                            destinationSlice: 0, destinationLevel: 0,
                            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                        )
                    }
                }
                blit.endEncoding()
            }
        }
        // === End atlas → tile blit block =================================

        #if DEBUG
        if let diagnosticStrokeID {
            CanvasStrokeDiagnostics.log("smudge scheduled stroke=\(CanvasStrokeDiagnostics.shortID(diagnosticStrokeID)) tool=smudge allocatedAfter=\(CanvasStrokeDiagnostics.tileSummary(tileGrid.allocatedKeys()))")
        }
        #endif

        commandBuffer.commit()
        // Don't waitUntilCompleted — touchesMoved is hot path. Subsequent
        // dispatches will queue behind on the same command queue; Metal
        // serialises within the queue so each stamp's writes are visible
        // to the next stamp's reads.
    }
}
