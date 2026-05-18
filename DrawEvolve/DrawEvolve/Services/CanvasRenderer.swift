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
    private var inkPenPipelineState: MTLRenderPipelineState?
    private var markerPipelineState: MTLRenderPipelineState?
    private var airbrushPipelineState: MTLRenderPipelineState?
    private var charcoalPipelineState: MTLRenderPipelineState?
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

    /// Update canvas size based on screen dimensions
    /// Canvas should be a square with side length = ceil(screen diagonal) to avoid clipping when rotated
    func updateCanvasSize(for screenSize: CGSize) {
        let maxTextureDimension: CGFloat = 2048
        let diagonal = ceil(sqrt(screenSize.width * screenSize.width + screenSize.height * screenSize.height))
        // Round up to nearest power of 2 for better GPU performance, but cap at 2048 to avoid memory pressure on device
        let size = min(pow(2, ceil(log2(diagonal))), maxTextureDimension)
        let newSize = CGSize(width: size, height: size)

        // Only update if size actually changed
        if newSize != _canvasSize {
            print("📐 Canvas size updated from \(_canvasSize) to \(newSize) based on screen \(screenSize)")
            _canvasSize = newSize
        }
    }

    init?(metalDevice: MTLDevice) {
        self.device = metalDevice

        guard let queue = device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = queue

        super.init()

        setupPipeline()
    }

    private func setupPipeline() {
        guard let library = device.makeDefaultLibrary() else {
            print("Failed to create Metal library")
            return
        }

        // Load shader functions
        guard let brushVertex = library.makeFunction(name: "brushVertexShader"),
              let brushFragment = library.makeFunction(name: "brushFragmentShader"),
              let eraserFragment = library.makeFunction(name: "eraserFragmentShader"),
              let pencilFragment = library.makeFunction(name: "pencilFragmentShader"),
              let inkPenFragment = library.makeFunction(name: "inkPenFragmentShader"),
              let markerFragment = library.makeFunction(name: "markerFragmentShader"),
              let airbrushFragment = library.makeFunction(name: "airbrushFragmentShader"),
              let charcoalFragment = library.makeFunction(name: "charcoalFragmentShader"),
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
              let compositeTileFragment = library.makeFunction(name: "compositeTileFragmentShader") else {
            print("Failed to load shader functions")
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
        let inkPenDescriptor = makeBrushVariantDescriptor(inkPenFragment)
        let markerDescriptor = makeBrushVariantDescriptor(markerFragment)
        let airbrushDescriptor = makeBrushVariantDescriptor(airbrushFragment)
        let charcoalDescriptor = makeBrushVariantDescriptor(charcoalFragment)

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
        let stampBlurDepositDescriptor = MTLRenderPipelineDescriptor()
        stampBlurDepositDescriptor.vertexFunction = brushVertex
        stampBlurDepositDescriptor.fragmentFunction = stampBlurDepositFragment
        stampBlurDepositDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        stampBlurDepositDescriptor.colorAttachments[0].isBlendingEnabled = true
        stampBlurDepositDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one  // source pre-multiplied
        stampBlurDepositDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        stampBlurDepositDescriptor.colorAttachments[0].rgbBlendOperation = .add
        stampBlurDepositDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        stampBlurDepositDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        stampBlurDepositDescriptor.colorAttachments[0].alphaBlendOperation = .add

        // Smudge patch-update — raw replace into the back patch (no blend).
        // The mix happens inside the shader (sample front patch + layer,
        // mix), so the framebuffer write is just an opaque store.
        let smudgePatchUpdateDescriptor = MTLRenderPipelineDescriptor()
        smudgePatchUpdateDescriptor.vertexFunction = quadVertex
        smudgePatchUpdateDescriptor.fragmentFunction = smudgePatchUpdateFragment
        smudgePatchUpdateDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        smudgePatchUpdateDescriptor.colorAttachments[0].isBlendingEnabled = false

        // Smudge deposit — premultiplied source-over into the layer, same
        // blend factors as the brush-blur deposit (the patch holds
        // premultiplied content from the layer; the deposit shader returns
        // patchSample * alpha which composites cleanly).
        let smudgeDepositDescriptor = MTLRenderPipelineDescriptor()
        smudgeDepositDescriptor.vertexFunction = brushVertex
        smudgeDepositDescriptor.fragmentFunction = smudgeDepositFragment
        smudgeDepositDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        smudgeDepositDescriptor.colorAttachments[0].isBlendingEnabled = true
        smudgeDepositDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        smudgeDepositDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        smudgeDepositDescriptor.colorAttachments[0].rgbBlendOperation = .add
        smudgeDepositDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        smudgeDepositDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        smudgeDepositDescriptor.colorAttachments[0].alphaBlendOperation = .add

        do {
            brushPipelineState = try device.makeRenderPipelineState(descriptor: brushDescriptor)
            eraserPipelineState = try device.makeRenderPipelineState(descriptor: eraserDescriptor)
            pencilPipelineState = try device.makeRenderPipelineState(descriptor: pencilDescriptor)
            inkPenPipelineState = try device.makeRenderPipelineState(descriptor: inkPenDescriptor)
            markerPipelineState = try device.makeRenderPipelineState(descriptor: markerDescriptor)
            airbrushPipelineState = try device.makeRenderPipelineState(descriptor: airbrushDescriptor)
            charcoalPipelineState = try device.makeRenderPipelineState(descriptor: charcoalDescriptor)
            compositePipelineState = try device.makeRenderPipelineState(descriptor: compositeDescriptor)
            textureDisplayPipelineState = try device.makeRenderPipelineState(descriptor: textureDisplayDescriptor)
            textureDisplayWithTransformPipelineState = try device.makeRenderPipelineState(descriptor: textureDisplayWithTransformDescriptor)
            compositeTilePipelineState = try device.makeRenderPipelineState(descriptor: compositeTileDescriptor)
            floatingTexturePipelineState = try device.makeRenderPipelineState(descriptor: floatingTextureDescriptor)
            referenceQuadPipelineState = try device.makeRenderPipelineState(descriptor: referenceQuadDescriptor)
            gaussianBlurPipelineState = try device.makeRenderPipelineState(descriptor: gaussianBlurDescriptor)
            gaussianBlurMaskedPipelineState = try device.makeRenderPipelineState(descriptor: gaussianBlurMaskedDescriptor)
            stampBlurDepositPipelineState = try device.makeRenderPipelineState(descriptor: stampBlurDepositDescriptor)
            smudgePatchUpdatePipelineState = try device.makeRenderPipelineState(descriptor: smudgePatchUpdateDescriptor)
            smudgeDepositPipelineState = try device.makeRenderPipelineState(descriptor: smudgeDepositDescriptor)
        } catch {
            print("Failed to create pipeline states: \(error)")
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

    // MARK: - Tile-display intermediate (Phase 4.3)
    //
    // Renderer-owned canvas-sized .private MTLTexture used as the
    // per-layer tile-composite intermediate for the parallel-display
    // verifier's tile-source shadow path. Distinct from the snapshot
    // staging atlas: the atlas is .shared for CPU readback during
    // snapshots/floodFill; this intermediate is .private because it's
    // a GPU-only render target + shader input feeding the display
    // path's transform pass. Different storage modes, different
    // purposes — never conflate them.
    //
    // Memory: 16 MB at 2048², 64 MB at 4096². Allocated lazily on first
    // tile-display-composite call; retained for renderer lifetime;
    // reused across every frame's tile-display composite. canvasSize
    // change forces reallocation on next ensure call (mirrors the
    // snapshot atlas's policy).
    //
    // Per-layer reuse semantics (Phase 4.3 H2 fix): each call to
    // `encodeLayerTileCompositeOntoIntermediate` clears the intermediate
    // on load and writes ONE layer's tile content. Callers iterate
    // layers within a single command buffer, interleaving compose
    // passes with draw passes onto the shadow target. Metal's render-
    // pass hazard tracking serializes the intermediate's writes
    // against subsequent reads — each layer's draw pass reads its own
    // intermediate state, not the last-composed layer's state. The
    // original 4.3b design (single shared intermediate read by a
    // single multi-draw encoder) raced under multi-layer because all
    // draws on a single encoder read the final intermediate state.
    //
    // Phase 4.3b decision γ (audit § 4.1 + dispatch): per-tile-to-screen
    // under transforms is architecturally unsolvable without 1-pixel
    // tile borders (Phase 2 redesign, out of scope). Instead sequence
    // two already-validated operations: per-layer tile composite to the
    // canvas-sized intermediate (bit-exact with the layer's monolithic
    // texture at tolerance=0 — Phase 3 invariant), then the existing
    // display path's LINEAR-sampling transform pass on the intermediate.
    // Both steps reuse tested shaders; no new sampler-dilemma surface.
    /// Exposed via `private(set)` so the Coordinator's parallel-display
    /// verifier (DEBUG-only, MetalCanvasView Phase 4.3c) can bind it as
    /// a fragment input in the per-layer draw pass without going through
    /// an accessor. Writes still confined to the renderer.
    private(set) var tileDisplayIntermediate: MTLTexture?

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
                      to texture: MTLTexture,
                      tileGrid: TileGrid? = nil,
                      screenSize: CGSize,
                      selectionPath: [CGPoint]?,
                      completion: (() -> Void)? = nil) {
        #if DEBUG
        print("🎨 CanvasRenderer: Rendering stroke with \(stroke.points.count) points")
        print("  Texture ID: \(ObjectIdentifier(texture))")
        print("  Screen size: \(screenSize.width)x\(screenSize.height)")
        print("  Texture size: \(texture.width)x\(texture.height)")
        print("  Tool: \(stroke.tool)")
        print("  Brush color: \(stroke.settings.color)")
        print("  Brush size: \(stroke.settings.size)")
        #endif

        // Acquire a stroke command-buffer slot. Blocks the caller (touch
        // loop) when the GPU has 60 stroke buffers in flight, releasing
        // as soon as one completes via the addCompletedHandler below.
        // Brief back-pressure under heavy load is the trade-off for
        // never silently dropping a stamp on Metal saturation.
        strokeCommandSlots.wait()

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            #if DEBUG
            print("CanvasRenderer: Failed to create command buffer")
            #endif
            strokeCommandSlots.signal()
            completion?()
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            #if DEBUG
            print("CanvasRenderer: Failed to create render encoder")
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
            case .inkPen:   return inkPenPipelineState
            case .marker:   return markerPipelineState
            case .airbrush: return airbrushPipelineState
            case .charcoal: return charcoalPipelineState
            default:        return brushPipelineState
            }
        }()
        guard let pipelineState = pipeline else {
            #if DEBUG
            print("CanvasRenderer: No pipeline state available")
            #endif
            renderEncoder.endEncoding()
            strokeCommandSlots.signal()
            completion?()
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        #if DEBUG
        print("CanvasRenderer: Pipeline set, rendering points...")
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

        // CRITICAL FIX: Stroke points are already in document/texture coordinate space
        // The screenSize parameter is actually documentSize (which should equal texture size)
        // Points are already scaled correctly from screenToDocument(), so NO SCALING should be applied
        #if DEBUG
        print("  Texture size: \(texture.width)x\(texture.height)")
        print("  Document size passed: \(screenSize.width)x\(screenSize.height)")
        #endif

        // Document size and texture size should be identical (both are square canvas)
        if abs(screenSize.width - CGFloat(texture.width)) > 1.0 || abs(screenSize.height - CGFloat(texture.height)) > 1.0 {
            print("  ⚠️ WARNING: Document size (\(screenSize)) doesn't match texture size (\(texture.width)x\(texture.height))")
            print("  This will cause stroke misalignment!")
        }

        // NO SCALING - points are already in texture coordinate space
        let positions = stroke.points.map { point in
            SIMD2<Float>(
                Float(point.location.x),
                Float(point.location.y)
            )
        }
        let viewportSize = SIMD2<Float>(Float(texture.width), Float(texture.height))

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

            // Copy position to avoid overlapping access
            var position = positions[index]

            renderEncoder.setVertexBytes(&position, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 1)
            renderEncoder.setVertexBytes(&viewportSizeCopy, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)

            // Draw point sprite
            renderEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
        }

        renderEncoder.endEncoding()

        // === Phase 2 Task 4.1: tile-grid dual-write (blit from monolithic) =
        //
        // After the monolithic encoder finishes rasterising every stamp,
        // blit the affected tiles from monolithic into the layer's
        // TileGrid on the SAME command buffer. Metal serialises encoders
        // within a buffer in submission order, so the blits run after the
        // render pass and read the post-render monolithic pixels.
        //
        // Bit-exact by construction: every tile pixel is a direct copy of
        // the corresponding monolithic pixel. Replaces the original
        // per-tile re-rasterisation approach (Phase 2 first cut), which
        // produced ±1 LSB GPU rasterizer noise per stamp that compounded
        // through alpha-over into ±8-15 visible drift over overlapping
        // stamps. The blit approach matches what flip / translate /
        // floodFill / renderImage / clearRect / clearPath / composite-
        // FloatingTextureIntoLayer all use — one consistent dual-write
        // pattern.
        //
        // Two-pass structure (same as other blit-only callsites):
        //   Pass 1: ensureTileWithClearIfNeeded encodes a no-draw
        //           loadAction=.clear render pass for any freshly-allocated
        //           tile, on the same command buffer. Must run before the
        //           blit encoder opens — Metal allows only one active
        //           encoder per buffer at a time.
        //   Pass 2: a single blit encoder copies tile-sized regions of
        //           monolithic into each tile.
        //
        // The completion handler still fires once both passes finish.
        if let grid = tileGrid {
            let bbox = strokeBoundingBox(stroke)
            let tileKeys = grid.tilesIntersecting(bbox)
            let tileSize = grid.tileSize
            let texW = texture.width
            let texH = texture.height

            if !tileKeys.isEmpty {
                for key in tileKeys {
                    _ = grid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: commandBuffer)
                }
                if let blit = commandBuffer.makeBlitCommandEncoder() {
                    for key in tileKeys {
                        let srcX = key.x * tileSize
                        let srcY = key.y * tileSize
                        let blitW = min(tileSize, texW - srcX)
                        let blitH = min(tileSize, texH - srcY)
                        if blitW <= 0 || blitH <= 0 { continue }

                        grid.updateTile(at: key) { tile in
                            blit.copy(
                                from: texture,
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
        }
        // === End dual-write block ========================================

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
        }
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

        for layer in layers where layer.isVisible {
            guard let layerTexture = layer.texture else { continue }
            var opacityValue = layer.opacity

            // Fallback: layer has a monolithic but no tile grid (invariant
            // violation). Draw the full layer texture as a single quad so
            // the composite stays correct.
            guard let grid = layer.tileGrid else {
                #if DEBUG
                print("⚠️ compositeLayersToTextureViaTiles: layer '\(layer.name)' has texture but no tileGrid — falling back to full-canvas quad")
                #endif
                var fallback = TileCompositeUniformsCPU(
                    tileRect: SIMD4<Int32>(0, 0, Int32(layerTexture.width), Int32(layerTexture.height)),
                    outputSize: outputSize
                )
                renderEncoder.setVertexBytes(&fallback, length: MemoryLayout<TileCompositeUniformsCPU>.stride, index: 0)
                renderEncoder.setFragmentTexture(layerTexture, index: 0)
                renderEncoder.setFragmentBytes(&opacityValue, length: MemoryLayout<Float>.stride, index: 0)
                renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                continue
            }

            let tileSize = grid.tileSize
            let texW = layerTexture.width
            let texH = layerTexture.height

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
            print("ERROR: Transform pipeline state not available")
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
                                                  on commandBuffer: MTLCommandBuffer) {
        guard let intermediate = ensureTileDisplayIntermediate(),
              let tilePipeline = compositeTilePipelineState else {
            print("⚠️ encodeLayerTileCompositeOntoIntermediate: intermediate / pipeline unavailable")
            return
        }

        let composeDesc = MTLRenderPassDescriptor()
        composeDesc.colorAttachments[0].texture = intermediate
        composeDesc.colorAttachments[0].loadAction = .clear
        composeDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        composeDesc.colorAttachments[0].storeAction = .store

        guard let composeEnc = commandBuffer.makeRenderCommandEncoder(descriptor: composeDesc) else {
            print("⚠️ encodeLayerTileCompositeOntoIntermediate: failed to create encoder")
            return
        }
        composeEnc.setRenderPipelineState(tilePipeline)

        let canvasW = Int(canvasSize.width)
        let canvasH = Int(canvasSize.height)
        let outputSize = SIMD2<Int32>(Int32(canvasW), Int32(canvasH))
        let tileSize = tileGrid.tileSize
        var tileOpacity: Float = 1.0  // raw layer content; opacity applied at draw step

        for key in tileGrid.allocatedKeys() {
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
            print("⚠️ renderReferenceBehindLayers: pipeline state missing")
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
            print("ERROR: Floating texture pipeline state not available")
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
        into layer: MTLTexture,
        tileGrid: TileGrid? = nil,
        atDocRect docRect: CGRect,
        rotation: Float = 0.0
    ) {
        guard let pipelineState = floatingTexturePipelineState,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("ERROR: Cannot composite floating texture")
            return
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = layer
        descriptor.colorAttachments[0].loadAction = .load   // preserve existing layer pixels
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(floating, index: 0)

        var opacity: Float = 1.0
        encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)

        // Identity transform — we render in canvas/doc space, viewport == layer size.
        var transform = SIMD4<Float>(1.0, 0.0, 0.0, 0.0)
        encoder.setVertexBytes(&transform, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)

        var viewport = SIMD2<Float>(Float(layer.width), Float(layer.height))
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)

        // canvasSize uniform must match the texture-pixel coordinate space we're
        // writing into. Layer pixel dims serve as both viewport and canvas here
        // because the doc-space rect maps 1:1 onto layer pixels.
        var canvas = SIMD2<Float>(Float(layer.width), Float(layer.height))
        encoder.setVertexBytes(&canvas, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)

        // Convert doc rect into layer-pixel-space rect for the shader. Rest of
        // the codebase treats docSize == layer size 1:1, but we scale through
        // canvasSize.width to be explicit so this stays correct if that ever
        // changes.
        let scale = CGFloat(layer.width) / canvasSize.width
        var rect = SIMD4<Float>(
            Float(docRect.origin.x * scale),
            Float(docRect.origin.y * scale),
            Float(docRect.width * scale),
            Float(docRect.height * scale)
        )
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)

        var rot = rotation
        encoder.setVertexBytes(&rot, length: MemoryLayout<Float>.stride, index: 4)

        // Flip is identity here — we're baking into the layer texture in
        // canvas-space, where the user's display flip doesn't apply.
        // Layer textures are unaffected by the display flip; only the
        // per-frame screen composite mirrors. Passing zero ensures the
        // shader's required buffer slot is bound.
        var flip = SIMD2<Float>(0, 0)
        encoder.setVertexBytes(&flip, length: MemoryLayout<SIMD2<Float>>.stride, index: 5)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        // === Phase 2 Task 4.3: tile-grid dual-write (blit from monolithic) =
        //
        // After the monolithic composite ends, blit the affected tiles
        // from `layer` (monolithic) into the TileGrid on the SAME command
        // buffer. Bit-exact by construction. Replaces the original
        // per-tile re-render approach (with the viewport+canvasSize
        // substitution trick), which inherited renderStroke's
        // ±1 LSB rasterizer drift via the alpha-over blend (the
        // post-renderStroke tile state diverged slightly from monolithic,
        // and the composite preserved that divergence — visible in soak
        // as catastrophic ±16+ mismatches).
        //
        // Selection rotation is applied by the shader (R(-θ) around rect
        // center, Shaders.metal:309-346). Pixel content in monolithic IS
        // the post-rotation result — we copy verbatim from monolithic to
        // tiles. But the tile-key set must cover the rotated extent, not
        // the un-rotated input rect, because shader-rotation moves pixels
        // outside pixelRect's AABB. Master audit C2.
        if let grid = tileGrid {
            // pixelRect: docRect converted to layer-pixel space, same
            // scale the monolithic pass used above.
            let pixelRect = CGRect(
                x: docRect.origin.x * scale,
                y: docRect.origin.y * scale,
                width: docRect.width * scale,
                height: docRect.height * scale
            )

            // Rotated AABB: rotate pixelRect's four corners by `rotation`
            // radians around the rect center, then take the axis-aligned
            // bounding box of the rotated corners. Matches the shader's
            // R(-θ) sign convention exactly so the tile-key set covers
            // every pixel the shader could touch.
            //
            // The `rotation == 0` early return is an OPTIMIZATION, not a
            // correctness requirement — the rotated-AABB math degenerates
            // correctly when rotation is exactly 0 (cosθ=1, sinθ=0 → each
            // corner maps to itself → AABB == pixelRect) or tiny-but-
            // nonzero. Future readers should not treat the early return
            // as a special case to preserve when refactoring.
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

            let tileKeys = grid.tilesIntersecting(dirtyRect)
            let tileSize = grid.tileSize
            let texW = layer.width
            let texH = layer.height

            if !tileKeys.isEmpty {
                for key in tileKeys {
                    _ = grid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: commandBuffer)
                }
                if let blit = commandBuffer.makeBlitCommandEncoder() {
                    for key in tileKeys {
                        let srcX = key.x * tileSize
                        let srcY = key.y * tileSize
                        let blitW = min(tileSize, texW - srcX)
                        let blitH = min(tileSize, texH - srcY)
                        if blitW <= 0 || blitH <= 0 { continue }

                        grid.updateTile(at: key) { tile in
                            blit.copy(
                                from: layer,
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
        }
        // === End dual-write block ========================================

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Translate a layer texture's pixels by an integer doc-space offset, in
    /// place. Pixels that fall outside the texture are dropped; vacated regions
    /// become transparent. Used by the move tool's whole-layer drag commit:
    /// during the drag we only update an offset uniform (no pixel writes),
    /// then this single GPU pass actually moves the bits when the user lets go.
    func translateLayerTextureInPlace(
        _ texture: MTLTexture,
        tileGrid: TileGrid? = nil,
        byDocOffset offset: CGPoint,
        screenSize: CGSize
    ) {
        let scaleX = CGFloat(texture.width) / screenSize.width
        let scaleY = CGFloat(texture.height) / screenSize.height
        let dx = Int((offset.x * scaleX).rounded())
        let dy = Int((offset.y * scaleY).rounded())

        if dx == 0 && dy == 0 { return }

        // Capture pre-translate allocated keys BEFORE the monolithic pass.
        // The monolithic op doesn't touch the tile grid, so this is just
        // for intent clarity — the set wouldn't change either way.
        let preTranslateKeys: [TileKey] = tileGrid?.allocatedKeys() ?? []

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared

        guard let temp = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("ERROR: translate-in-place failed to allocate temp/command buffer")
            return
        }

        // 1. Copy current layer to temp.
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: texture,
                sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                to: temp,
                destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }

        // 2. Clear layer to transparent.
        let clearDescriptor = MTLRenderPassDescriptor()
        clearDescriptor.colorAttachments[0].texture = texture
        clearDescriptor.colorAttachments[0].loadAction = .clear
        clearDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        clearDescriptor.colorAttachments[0].storeAction = .store
        if let clearEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: clearDescriptor) {
            clearEncoder.endEncoding()
        }

        // 3. Blit temp → layer at integer pixel offset, clipping the source
        //    region to the part that lands inside the destination.
        let srcX = max(0, -dx)
        let srcY = max(0, -dy)
        let dstX = max(0, dx)
        let dstY = max(0, dy)
        let copyW = max(0, min(texture.width  - srcX, texture.width  - dstX))
        let copyH = max(0, min(texture.height - srcY, texture.height - dstY))

        if copyW > 0, copyH > 0, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: temp,
                sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                to: texture,
                destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
            )
            blit.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // === Phase 2 Task 4.9: tile-grid dual-write (shift + blit) =======
        //
        // Result-then-mirror: post-translate pixels live in `texture`.
        // Mirror by:
        //   1. Compute post-translate destination key set: for each pre-
        //      translate allocated key K with pixel rect R_K, the content
        //      lands at R_K + (dx, dy). Union the tilesIntersecting of
        //      each shifted rect (clamped to canvas).
        //   2. Drop all pre-translate allocations (their content has moved
        //      or been clipped off-canvas).
        //   3. For each post-translate key: ensureTile + blit the new
        //      key's pixel rect from post-translate monolithic.
        //
        // For sub-tile offsets (the typical drag case), a single source
        // tile contributes content to up to 4 destination tiles. The
        // post-translate set captures that 1→4 fan-out automatically via
        // tilesIntersecting.
        //
        // Blit width/height = min(tileSize, texture.width/height - origin),
        // so on canvas dims that are exact multiples of tileSize the blit
        // is full-tile and partial-edge undefined-pixel concerns don't
        // arise. Non-multiple canvas dims hit the same partial-edge case
        // as flip; Task 5's allocation-clear fix covers it.
        if let grid = tileGrid, !preTranslateKeys.isEmpty {
            let tileSize = grid.tileSize
            let texW = texture.width
            let texH = texture.height

            var postSet = Set<TileKey>()
            for old in preTranslateKeys {
                let shifted = CGRect(
                    x: old.x * tileSize + dx,
                    y: old.y * tileSize + dy,
                    width: tileSize,
                    height: tileSize
                )
                for k in grid.tilesIntersecting(shifted) {
                    postSet.insert(k)
                }
            }

            // Drop pre-translate allocations FIRST so dropTile/ensureTile
            // pairs that hit the same key (small offsets where a source
            // tile partially overlaps itself) don't leak stale content.
            for old in preTranslateKeys {
                grid.dropTile(at: old)
            }

            if let mirrorBuf = commandQueue.makeCommandBuffer() {
                // Pass 1: allocate-and-clear-if-needed for freshly-ensured
                // tiles. Each call may encode an empty-clear render pass on
                // mirrorBuf; can't overlap with an active blit encoder.
                for newKey in postSet {
                    _ = grid.ensureTileWithClearIfNeeded(at: newKey, onCommandBuffer: mirrorBuf)
                }
                // Pass 2: blit data into tiles.
                if let blit2 = mirrorBuf.makeBlitCommandEncoder() {
                    for newKey in postSet {
                        let srcX = newKey.x * tileSize
                        let srcY = newKey.y * tileSize
                        let blitW = min(tileSize, texW - srcX)
                        let blitH = min(tileSize, texH - srcY)
                        if blitW <= 0 || blitH <= 0 { continue }

                        // try? only catches encoder-construction failure
                        // inside the closure; blit.copy can't throw and the
                        // encoder is guarded above. Present only to satisfy
                        // updateTile's rethrows signature.
                        grid.updateTile(at: newKey) { tile in
                            blit2.copy(
                                from: texture,
                                sourceSlice: 0, sourceLevel: 0,
                                sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
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
        }
        // === End dual-write block ========================================
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
    func flipLayerTextureInPlace(_ texture: MTLTexture,
                                  tileGrid: TileGrid? = nil,
                                  flipHorizontal: Bool,
                                  flipVertical: Bool) {
        if !flipHorizontal && !flipVertical { return }

        // Capture pre-flip allocated keys BEFORE the monolithic op. The
        // monolithic pass doesn't touch the tile grid, so reading
        // allocatedKeys() here vs after the monolithic pass would give the
        // same set — capturing before is just clearer about intent.
        let preFlipKeys: [TileKey] = tileGrid?.allocatedKeys() ?? []

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared

        guard let temp = device.makeTexture(descriptor: descriptor),
              let pipelineState = textureDisplayWithTransformPipelineState,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("ERROR: flip-in-place failed to allocate temp/pipeline/command buffer")
            return
        }

        // 1. Blit source pixels into the temp texture so the subsequent
        //    render pass has something to sample (it cannot read and
        //    write the same texture in one pass).
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                to: temp, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }

        // 2. Clear-and-render back into the layer. The clear + standard
        //    source-over blend resolves to exactly the (flipped) source
        //    pixels.
        let renderDescriptor = MTLRenderPassDescriptor()
        renderDescriptor.colorAttachments[0].texture = texture
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
        // here equals the layer pixel size; mirror-about-viewport-center
        // becomes mirror-about-layer-center.
        var transform = SIMD4<Float>(1.0, 0.0, 0.0, 0.0)
        encoder.setVertexBytes(&transform, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)

        var viewport = SIMD2<Float>(Float(texture.width), Float(texture.height))
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)

        // canvasSize uniform is unused by the shader but the buffer
        // slot must be bound. Pass the viewport for a benign value.
        var canvas = viewport
        encoder.setVertexBytes(&canvas, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)

        var flip = SIMD2<Float>(flipHorizontal ? 1 : 0, flipVertical ? 1 : 0)
        encoder.setVertexBytes(&flip, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // === Phase 2 Task 4.8: tile-grid dual-write (re-key + blit) ======
        //
        // Result-then-mirror: after the monolithic flip lands, the post-
        // flip pixels live at the same coordinates in `texture` as the
        // post-flip canvas should show. The tile grid mirror is:
        //
        //   1. Compute the bijective re-key: (tx, ty) → (gridW-1-tx, ty)
        //      for horizontal, (tx, gridH-1-ty) for vertical, both for HV.
        //   2. Drop every pre-flip allocation (its content has moved).
        //   3. For each post-flip key: ensureTile, then blit the new key's
        //      pixel rect from post-flip monolithic into the tile.
        //
        // Works regardless of canvas alignment to tileSize. For partial-
        // edge tiles (canvas not a multiple of tileSize) the blit covers
        // only the in-canvas portion; the rest of the .private tile
        // texture is undefined — Task 5's allocation-clear fix handles
        // that case. Our canvas sizes (2048², 4096²) are exact multiples
        // of 256, so partial tiles don't arise today.
        if let grid = tileGrid, !preFlipKeys.isEmpty {
            let gridW = grid.gridWidth
            let gridH = grid.gridHeight
            let tileSize = grid.tileSize
            let texW = texture.width
            let texH = texture.height

            let postFlipKeys: [TileKey] = preFlipKeys.map { old in
                TileKey(
                    x: flipHorizontal ? (gridW - 1 - old.x) : old.x,
                    y: flipVertical   ? (gridH - 1 - old.y) : old.y
                )
            }

            // Drop pre-flip allocations FIRST so dropTile/ensureTile pairs
            // that hit the same key (e.g., the middle column under H-flip
            // on an odd grid width) don't leak stale content.
            for old in preFlipKeys {
                grid.dropTile(at: old)
            }

            if let mirrorBuf = commandQueue.makeCommandBuffer() {
                // Pass 1: allocate-and-clear-if-needed for freshly-ensured
                // tiles. Each call may encode an empty-clear render pass on
                // mirrorBuf; can't overlap with an active blit encoder.
                for newKey in postFlipKeys {
                    _ = grid.ensureTileWithClearIfNeeded(at: newKey, onCommandBuffer: mirrorBuf)
                }
                // Pass 2: blit data into tiles.
                if let blit = mirrorBuf.makeBlitCommandEncoder() {
                    for newKey in postFlipKeys {
                        let srcX = newKey.x * tileSize
                        let srcY = newKey.y * tileSize
                        let blitW = min(tileSize, texW - srcX)
                        let blitH = min(tileSize, texH - srcY)
                        if blitW <= 0 || blitH <= 0 { continue }

                        // try? only catches encoder-construction failure
                        // inside the closure; blit.copy can't throw and the
                        // encoder is guarded above. Present only to satisfy
                        // updateTile's rethrows signature.
                        grid.updateTile(at: newKey) { tile in
                            blit.copy(
                                from: texture,
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
                mirrorBuf.commit()
                mirrorBuf.waitUntilCompleted()
            }
        }
        // === End dual-write block ========================================
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
            print("ERROR: Failed to get CGImage from selection")
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
            print("ERROR: Failed to create texture for selection overlay")
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
            print("ERROR: Failed to create CGContext for selection overlay")
            return
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else {
            print("ERROR: Failed to get context data")
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
            print("ERROR: Transform pipeline state not available")
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
        // mid-drag so the wet-ink preview matches the committed look.
        let previewPipeline: MTLRenderPipelineState? = {
            switch stroke.tool {
            case .pencil:   return pencilPipelineState
            case .inkPen:   return inkPenPipelineState
            case .marker:   return markerPipelineState
            case .airbrush: return airbrushPipelineState
            case .charcoal: return charcoalPipelineState
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
        in texture: MTLTexture,
        tileGrid: TileGrid? = nil,
        screenSize: CGSize,
        completion: @escaping () -> Void
    ) -> Bool {
        #if DEBUG
        print("CanvasRenderer: Flood fill at \(point) with color")
        #endif

        // Scale coordinates from screen space to texture space
        let scaleX = CGFloat(texture.width) / screenSize.width
        let scaleY = CGFloat(texture.height) / screenSize.height
        let texturePoint = CGPoint(x: point.x * scaleX, y: point.y * scaleY)

        let startX = Int(texturePoint.x)
        let startY = Int(texturePoint.y)

        // Validate coordinates
        guard startX >= 0, startY >= 0, startX < texture.width, startY < texture.height else {
            print("ERROR: Point outside texture bounds")
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
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        let dataSize = bytesPerRow * height

        guard let grid = tileGrid else {
            print("ERROR: floodFill — tileGrid required (Phase 4.2d)")
            return false
        }

        guard let atlas = ensureCanvasStagingAtlas() else {
            print("ERROR: floodFill — failed to ensure staging atlas")
            return false
        }

        let tileSize = grid.tileSize
        let allocated = grid.allocatedKeys()

        // Pre-blit allocated tiles into the atlas. Skipped entirely if
        // the layer has no content — flat buffer stays all-zero, the
        // target-color check below sees transparent, and the same-color
        // early-out fires for a transparent fill.
        if !allocated.isEmpty {
            guard let prereadCB = commandQueue.makeCommandBuffer() else {
                print("ERROR: floodFill — failed to create pre-read command buffer")
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
            print("ERROR: Invalid pixel index")
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
            print("Target and fill colors are the same, skipping fill")
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
            print("Filled \(fillCount) pixels")
            #endif

            DispatchQueue.main.async { [weak self] in
                data.withUnsafeBytes { ptr in
                    guard let baseAddress = ptr.baseAddress else { return }
                    texture.replace(
                        region: MTLRegion(
                            origin: MTLOrigin(x: 0, y: 0, z: 0),
                            size: MTLSize(width: width, height: height, depth: 1)
                        ),
                        mipmapLevel: 0,
                        withBytes: baseAddress,
                        bytesPerRow: bytesPerRow
                    )
                }

                // === Phase 2 Task 4.7: tile-grid dual-write (blit from monolithic) =
                //
                // Canonical pattern. Previous shape used a buffer-to-texture
                // sub-tile blit from a full-canvas MTLBuffer of the post-fill
                // CPU data; that had two structural problems:
                //   (a) freshly-allocated tiles got cleared to zero by
                //       ensureTileWithClearIfNeeded, then only the
                //       dirtyRect-intersection got blitted. Pixels inside the
                //       tile but outside the dirtyRect stayed at zero while
                //       monolithic at those pixels retained pre-fill content
                //       (the canvas already-painted area the fill didn't
                //       reach). That's a guaranteed mismatch for any new
                //       allocation whose tile-bbox extends past the dirty bbox.
                //   (b) sourceBytesPerRow alignment requirements aren't
                //       universally honored across iOS GPUs for arbitrary
                //       widths.
                //
                // Full-tile blit-from-monolithic eliminates both: every
                // affected tile becomes a bit-exact copy of monolithic, which
                // texture.replace just landed with the final post-fill state.
                if let grid = tileGrid, fillCount > 0, let self = self {
                    let dirtyRect = CGRect(
                        x: dirtyMinX,
                        y: dirtyMinY,
                        width: dirtyMaxX - dirtyMinX + 1,
                        height: dirtyMaxY - dirtyMinY + 1
                    )
                    let tileKeys = grid.tilesIntersecting(dirtyRect)
                    let tileSize = grid.tileSize
                    let texW = texture.width
                    let texH = texture.height

                    if !tileKeys.isEmpty, let cmdBuf = self.commandQueue.makeCommandBuffer() {
                        for key in tileKeys {
                            _ = grid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: cmdBuf)
                        }
                        if let blit = cmdBuf.makeBlitCommandEncoder() {
                            for key in tileKeys {
                                let srcX = key.x * tileSize
                                let srcY = key.y * tileSize
                                let blitW = min(tileSize, texW - srcX)
                                let blitH = min(tileSize, texH - srcY)
                                if blitW <= 0 || blitH <= 0 { continue }

                                grid.updateTile(at: key) { tile in
                                    blit.copy(
                                        from: texture,
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
                // === End dual-write block ================================

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
    /// Tile-native via the shared staging atlas (Phase 4.2b):
    ///   1. Ensure the atlas exists at current canvasSize.
    ///   2. Blit every allocated tile from `grid` into its in-canvas
    ///      position on the atlas, on a single command buffer.
    ///   3. commit + waitUntilCompleted.
    ///   4. getBytes per tile from the atlas into a per-tile Data buffer
    ///      sized exactly to the tile's in-canvas footprint (partial-
    ///      edge tiles get smaller buffers; no slop).
    ///
    /// Returns nil on Metal allocation failure or a missing tileGrid.
    /// nil-tileGrid is no longer a supported path (Phase 4.5 removes the
    /// optional entirely); the empty-tile-grid case (grid present,
    /// `allocatedKeys().isEmpty`) IS supported and produces a snapshot
    /// with empty `tiles` — a legitimate empty-layer snapshot.
    ///
    /// The `texture` parameter is no longer read for pixel content
    /// (post-4.2b reads come from tile textures via the atlas) but is
    /// retained for caller-side ergonomics + the canvas-pixel
    /// dimensions. Phase 4.5 removes the parameter.
    ///
    /// TODO: audit whether captureSnapshot needs drainCommandQueue
    /// protection from in-flight strokes (race shape: cap-for-op-N+1
    /// while op-N deposit still async). Different from the
    /// touchesCancelled race fixed in restoreSnapshot.
    func captureSnapshot(of texture: MTLTexture, tileGrid: TileGrid? = nil) -> LayerSnapshot? {
        let canvasW = texture.width
        let canvasH = texture.height
        guard canvasW > 0, canvasH > 0 else {
            print("ERROR: captureSnapshot — invalid texture dimensions (\(canvasW)×\(canvasH))")
            return nil
        }

        guard let grid = tileGrid else {
            // nil tileGrid path is deprecated. Pre-Phase-4.2 it read the
            // monolithic via getBytes; post-4.2b, tile-grid is the source
            // of truth and a nil grid means no content to snapshot.
            // Return nil so callers fail explicitly rather than silently
            // storing zeros. Phase 4.5 removes the optional entirely.
            print("ERROR: captureSnapshot — nil tileGrid is no longer supported (Phase 4.2b)")
            return nil
        }

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
            print("ERROR: captureSnapshot — failed to ensure staging atlas")
            return nil
        }

        guard let cb = commandQueue.makeCommandBuffer() else {
            print("ERROR: captureSnapshot — failed to create command buffer")
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

    /// Restore a texture + tile grid from a snapshot. Tile-native via
    /// the shared staging atlas (Phase 4.2c).
    ///
    /// Flow:
    ///   1. drainCommandQueue() — wait for any in-flight async stroke cb
    ///      to drain (touchesCancelled race fix, commit 5b15e24).
    ///   2. Drop tiles in the current grid that are NOT in the snapshot's
    ///      keyspace (cleans up tiles allocated by intervening ops).
    ///   3. Pre-filter snapshot.tiles into a validRestores list, skipping
    ///      entries whose key/data shape doesn't match captureSnapshot's
    ///      per-tile layout. Used by every subsequent loop.
    ///   4. CPU-upload each valid tile's Data into the staging atlas at
    ///      its in-canvas position (texture.replace, .shared atlas).
    ///   5. Clear monolithic via render encoder loadAction=.clear.
    ///      Regions outside the saved-tile set stay transparent — matches
    ///      the legacy "drop tiles not in keyspace → those regions become
    ///      transparent" semantic.
    ///   6. ensureTileWithClearIfNeeded for each valid key (allocates a
    ///      fresh grid tile if absent; encoded on the cmdBuf).
    ///   7. Open blit encoder: per valid key, copy atlas → grid tile AND
    ///      atlas → monolithic at canvas position.
    ///   8. commit + waitUntilCompleted.
    ///   9. Verifier (drain-before / verify-after symmetry from C1, commit
    ///      73e54d5).
    ///
    /// Result: `grid.allocatedKeys()` == `snapshot.tiles.keys` set-equal,
    /// each grid tile + corresponding monolithic region bit-exact with
    /// `snapshot.tiles[key]`. Display path (still reading monolithic in
    /// Phase 2/3) shows the snapshot's content; composite path (tile-
    /// sourced in Phase 3) shows the same.
    ///
    /// Phase 4.2c migration: stripped the bridge `.pixels` reassembly +
    /// `.allocatedKeys` array that 4.2b carried through. Restore now
    /// reads `snapshot.tiles[key]` directly. No 16-64 MB transient
    /// allocation per restore; only per-tile work proportional to the
    /// number of saved tiles.
    ///
    /// Phase 4.5 will delete the atlas → monolithic blit pair entirely
    /// when monolithic goes away.
    func restoreSnapshot(_ snapshot: LayerSnapshot, to texture: MTLTexture, tileGrid: TileGrid? = nil) {
        drainCommandQueue()

        guard let grid = tileGrid else { return }

        let savedKeys = Set(snapshot.tiles.keys)

        // Drop tiles in the current grid that aren't in the snapshot.
        // After this loop, any tile in the grid that's also in the
        // snapshot will get its content overwritten below; any tile
        // not in the snapshot is gone (and the monolithic clear at
        // step 5 zeros its region of the canvas to match).
        for key in grid.allocatedKeys() where !savedKeys.contains(key) {
            grid.dropTile(at: key)
        }

        let tileSize = grid.tileSize
        let canvasW = texture.width
        let canvasH = texture.height

        // Pre-filter to validRestores: tuples carrying the per-tile
        // pixel dims so the subsequent loops don't recompute them and
        // so mis-sized entries are skipped wholesale (rather than the
        // bridge's silent skip-the-row-but-still-blit-stale-pixels).
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

        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        // Step 5: clear monolithic. Even on empty-snapshot restore (no
        // valid tiles to write back) the clear is correct: result is a
        // fully-transparent layer, matching the legacy
        // `allocatedKeys.isEmpty → drop everything` semantic.
        //
        // texture.usage at createLayerTexture includes .renderTarget so
        // this is valid. Encoder ends immediately; the render pass'
        // .clear loadAction does the work. No draw calls needed.
        let clearDesc = MTLRenderPassDescriptor()
        clearDesc.colorAttachments[0].texture = texture
        clearDesc.colorAttachments[0].loadAction = .clear
        clearDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        clearDesc.colorAttachments[0].storeAction = .store
        if let clearEnc = cmdBuf.makeRenderCommandEncoder(descriptor: clearDesc) {
            clearEnc.endEncoding()
        }

        if validRestores.isEmpty {
            // Empty / all-invalid snapshot — just the clear suffices.
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
            return
        }

        // Step 4: CPU-upload each valid tile's data into the atlas at its
        // canvas position. Atlas is .shared so texture.replace is legal;
        // CPU writes complete before we commit the cmdBuf below, so the
        // subsequent GPU blits see the post-upload atlas state.
        guard let atlas = ensureCanvasStagingAtlas() else {
            print("ERROR: restoreSnapshot — failed to ensure staging atlas")
            return
        }
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

        // Step 6: allocate-and-clear-if-needed for every saved key.
        // Each call may encode its own no-draw render pass on cmdBuf;
        // safe because no blit encoder is open yet.
        for restore in validRestores {
            _ = grid.ensureTileWithClearIfNeeded(at: restore.key, onCommandBuffer: cmdBuf)
        }

        // Step 7: blit atlas → grid tile + atlas → monolithic per valid key.
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

                blit.copy(
                    from: atlas,
                    sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: dstX, y: dstY, z: 0),
                    sourceSize: MTLSize(width: restore.copyW, height: restore.copyH, depth: 1),
                    to: texture,
                    destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0)
                )
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
        for texture: MTLTexture,
        screenSize: CGSize
    ) -> (image: UIImage, docSize: CGSize)? {
        let texSize = CGSize(width: CGFloat(texture.width), height: CGFloat(texture.height))

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
        for texture: MTLTexture,
        screenSize: CGSize
    ) -> (image: UIImage, docBounds: CGRect)? {
        let texSize = CGSize(width: CGFloat(texture.width), height: CGFloat(texture.height))
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

    /// Load a UIImage into a texture (for editing existing drawings)
    /// Phase 2/3 helper: rebuild a tile grid to be bit-exact with a layer
    /// texture that was written to wholesale (full-canvas overwrite).
    /// Drops the entire current keyspace, allocates every tile in grid
    /// bounds, and blit-from-monolithic into each.
    ///
    /// Used by:
    /// - `loadImage(_:into:tileGrid:)` — single-image drawing load.
    /// - Multi-layer drawing load (per-layer PNG path in CanvasStateManager).
    /// - Any future op that does a full-canvas texture overwrite.
    ///
    /// Sync: creates its own command buffer and waits for completion before
    /// returning. Safe to call after the caller has finalised its own
    /// monolithic write (`texture.replace` or finished render encoder).
    ///
    /// The rule going forward (per Phase 3.1 soak findings): every sync
    /// dual-write path must call the verifier at end. Async batched-deposit
    /// paths still skip it (documented race).
    func populateTileGridFromTexture(_ texture: MTLTexture,
                                     tileGrid: TileGrid,
                                     callsite: String) {
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
            let texW = texture.width
            let texH = texture.height
            for key in allKeys {
                let srcX = key.x * tileSize
                let srcY = key.y * tileSize
                let blitW = min(tileSize, texW - srcX)
                let blitH = min(tileSize, texH - srcY)
                if blitW <= 0 || blitH <= 0 { continue }
                tileGrid.updateTile(at: key) { tile in
                    blit.copy(
                        from: texture,
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

    func loadImage(_ image: UIImage, tileGrid: TileGrid) {
        print("CanvasRenderer: Loading image into tile grid via staging atlas")

        guard let cgImage = image.cgImage else {
            print("ERROR: Failed to get CGImage from UIImage")
            return
        }

        guard let atlas = ensureCanvasStagingAtlas() else {
            print("ERROR: Failed to ensure canvas staging atlas for loadImage")
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
            print("ERROR: Failed to create CGContext")
            return
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else {
            print("ERROR: Failed to get context data")
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

        // Phase 4.5c: monolithic write removed. Image lands in the shared
        // staging atlas, then the tile grid is rebuilt full-canvas via the
        // existing blit-from-monolithic helper (now sourcing from atlas).
        populateTileGridFromTexture(atlas, tileGrid: tileGrid, callsite: "loadImage")

        print("✅ Image loaded successfully into tile grid")
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
        print("CanvasRenderer: Clearing rect \(rect)")

        guard let atlas = ensureCanvasStagingAtlas() else {
            print("ERROR: Failed to ensure canvas staging atlas for clearRect")
            return
        }

        // Convert doc-space rect to integer pixel rect. Use floor/ceil so every
        // pixel the rect touches is included, then clamp to atlas bounds.
        // clearRect and extractPixels MUST use identical integer rects or
        // extracted/cleared regions drift and leave ghost pixels on move.
        guard let (x, y, w, h) = texturePixelRect(for: rect, in: atlas, screenSize: screenSize) else {
            print("ERROR: Rect outside canvas bounds or empty")
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

        print("Rect cleared successfully")
    }

    /// Clear pixels along a path (for lasso selection)
    func clearPath(_ path: [CGPoint], in texture: MTLTexture, tileGrid: TileGrid? = nil, screenSize: CGSize) {
        print("CanvasRenderer: Clearing path with \(path.count) points")

        guard path.count >= 3 else {
            print("ERROR: Path must have at least 3 points")
            return
        }

        // Scale path from screen space to texture space
        let scaleX = CGFloat(texture.width) / screenSize.width
        let scaleY = CGFloat(texture.height) / screenSize.height
        let scaledPath = path.map { CGPoint(x: $0.x * scaleX, y: $0.y * scaleY) }

        let width = texture.width
        let height = texture.height

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
            print("Path bbox empty, nothing to clear")
            return
        }

        // Region-local I/O: read only the path's bounding box rather than the
        // whole texture (a 4096² lasso selection on a 4096² canvas was a
        // 64 MiB read → 16× saving for typical selection sizes).
        let regionBytesPerRow = regionW * 4
        let region = MTLRegion(
            origin: MTLOrigin(x: minX, y: minY, z: 0),
            size: MTLSize(width: regionW, height: regionH, depth: 1)
        )
        var pixelData = Data(count: regionBytesPerRow * regionH)

        pixelData.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            texture.getBytes(
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

        // Write back the region only.
        pixelData.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: regionBytesPerRow
            )
        }

        // === Phase 2 Task 4.5: tile-grid dual-write (blit from monolithic) =
        //
        // Canonical pattern. Same rationale as clearRect — sub-tile
        // buffer-to-texture blits had unhonored alignment requirements and
        // didn't repair drift in the non-cleared portion of a tile that
        // earlier callsites may have left misaligned. Full-tile blit from
        // monolithic is bit-exact by construction.
        if let grid = tileGrid, regionW > 0, regionH > 0 {
            let bboxPixelRect = CGRect(x: minX, y: minY, width: regionW, height: regionH)
            let tileKeys = grid.tilesIntersecting(bboxPixelRect)
            let tileSize = grid.tileSize
            let texW = texture.width
            let texH = texture.height

            if !tileKeys.isEmpty, let cmdBuf = commandQueue.makeCommandBuffer() {
                for key in tileKeys {
                    _ = grid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: cmdBuf)
                }
                if let blit = cmdBuf.makeBlitCommandEncoder() {
                    for key in tileKeys {
                        let srcX = key.x * tileSize
                        let srcY = key.y * tileSize
                        let blitW = min(tileSize, texW - srcX)
                        let blitH = min(tileSize, texH - srcY)
                        if blitW <= 0 || blitH <= 0 { continue }

                        grid.updateTile(at: key) { tile in
                            blit.copy(
                                from: texture,
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
        // === End dual-write block ========================================

        print("Path cleared successfully (\(clearedCount) pixels)")
    }

    // MARK: - Export Image

    /// Exports all visible layers composited into a single image
    func exportImage(layers: [DrawingLayer]) -> UIImage? {
        print("CanvasRenderer: Exporting image with \(layers.count) layers")
        return compositeLayersToImage(layers: layers)
    }

    // MARK: - Pixel Extraction for Selection Movement

    /// Extract pixels from a rectangular selection
    func extractPixels(from rect: CGRect, in texture: MTLTexture, screenSize: CGSize) -> UIImage? {
        print("CanvasRenderer: Extracting pixels from rect \(rect)")

        // Must use identical integer rect as clearRect — see note there.
        guard let (x, y, w, h) = texturePixelRect(for: rect, in: texture, screenSize: screenSize) else {
            print("ERROR: Rect outside texture bounds or empty")
            return nil
        }

        // Region-local read: pull only the selection rect, not the whole
        // texture. Buffer is laid out exactly as the CGImage wants, so the
        // intermediate full-texture → row-copy → selectionData step the
        // previous version did is unnecessary.
        let selectionBytesPerRow = w * 4
        var selectionData = Data(count: selectionBytesPerRow * h)
        let region = MTLRegion(
            origin: MTLOrigin(x: x, y: y, z: 0),
            size: MTLSize(width: w, height: h, depth: 1)
        )

        selectionData.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            texture.getBytes(
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
            print("ERROR: Failed to create CGContext for selection")
            return nil
        }

        selectionData.withUnsafeBytes { ptr in
            guard let srcBase = ptr.baseAddress else { return }
            if let data = context.data {
                memcpy(data, srcBase, selectionData.count)
            }
        }

        guard let cgImage = context.makeImage() else {
            print("ERROR: Failed to create CGImage from selection")
            return nil
        }

        print("✂️ Extracted selection: \(w)x\(h) pixels")
        return UIImage(cgImage: cgImage)
    }

    /// Extract pixels from a lasso/path selection with alpha masking
    func extractPixels(fromPath path: [CGPoint], in texture: MTLTexture, screenSize: CGSize) -> UIImage? {
        print("CanvasRenderer: Extracting pixels from path with \(path.count) points")

        guard path.count >= 3 else {
            print("ERROR: Path must have at least 3 points")
            return nil
        }

        // Scale path from screen space to texture space
        let scaleX = CGFloat(texture.width) / screenSize.width
        let scaleY = CGFloat(texture.height) / screenSize.height
        let scaledPath = path.map { CGPoint(x: $0.x * scaleX, y: $0.y * scaleY) }

        // Find bounding box. floor/ceil so edge pixels aren't shaved.
        let minX = max(0, Int(floor(scaledPath.map { $0.x }.min() ?? 0)))
        let maxX = min(texture.width - 1, Int(ceil(scaledPath.map { $0.x }.max() ?? CGFloat(texture.width))))
        let minY = max(0, Int(floor(scaledPath.map { $0.y }.min() ?? 0)))
        let maxY = min(texture.height - 1, Int(ceil(scaledPath.map { $0.y }.max() ?? CGFloat(texture.height))))

        let w = maxX - minX + 1
        let h = maxY - minY + 1

        guard w > 0, h > 0 else {
            print("ERROR: Invalid bounding box")
            return nil
        }

        // Region-local read of the path's bounding box. The region buffer is
        // already laid out as the output CGImage wants, so we mask in place
        // (zero pixels outside the polygon) instead of allocating a separate
        // selectionData buffer.
        let selectionBytesPerRow = w * 4
        var selectionData = Data(count: selectionBytesPerRow * h)
        let region = MTLRegion(
            origin: MTLOrigin(x: minX, y: minY, z: 0),
            size: MTLSize(width: w, height: h, depth: 1)
        )

        selectionData.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            texture.getBytes(
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
            print("ERROR: Failed to create CGContext for lasso selection")
            return nil
        }

        selectionData.withUnsafeBytes { ptr in
            guard let srcBase = ptr.baseAddress else { return }
            if let data = context.data {
                memcpy(data, srcBase, selectionData.count)
            }
        }

        guard let cgImage = context.makeImage() else {
            print("ERROR: Failed to create CGImage from lasso selection")
            return nil
        }

        print("✂️ Extracted lasso selection: \(w)x\(h) pixels")
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
    func renderImage(_ image: UIImage, at rect: CGRect, to texture: MTLTexture, tileGrid: TileGrid? = nil, screenSize: CGSize) {
        guard let cgImage = image.cgImage else {
            print("ERROR: Failed to get CGImage")
            return
        }

        // Image pixel dimensions — use as-is, no resampling.
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return }

        // Integer pixel offset in texture space. We truncate here; the CGImage
        // was extracted at integer pixel bounds, so the render target must also
        // be integer-aligned. Sub-pixel drag jitter is acceptable.
        let scaleX = CGFloat(texture.width) / screenSize.width
        let scaleY = CGFloat(texture.height) / screenSize.height
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
            print("ERROR: Failed to create CGContext")
            return
        }
        srcContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let srcData = srcContext.data else { return }

        // Region-local I/O: clamp the image's destination rect to texture bounds
        // and operate only on that intersection. A 256² text run was a 64 MiB
        // full-texture read+write at 4096²; the clamped region is ~256 KiB.
        let texWidth = texture.width
        let texHeight = texture.height
        let dstX = max(0, x)
        let dstY = max(0, y)
        let dstEndX = min(texWidth, x + w)
        let dstEndY = min(texHeight, y + h)
        let regionW = dstEndX - dstX
        let regionH = dstEndY - dstY
        guard regionW > 0, regionH > 0 else { return }

        // Where in the source image the visible top-left corner lives. Equal
        // to (max(0, -x), max(0, -y)) when the image hangs off the texture.
        let imgStartCol = dstX - x
        let imgStartRow = dstY - y

        let regionBytesPerRow = regionW * 4
        var regionData = Data(count: regionBytesPerRow * regionH)
        let region = MTLRegion(
            origin: MTLOrigin(x: dstX, y: dstY, z: 0),
            size: MTLSize(width: regionW, height: regionH, depth: 1)
        )

        regionData.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            texture.getBytes(
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
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: regionBytesPerRow
            )
        }

        // === Phase 2 Task 4.6: tile-grid dual-write (blit from monolithic) =
        //
        // Canonical pattern. Same rationale as floodFill — freshly-allocated
        // tiles where the image's region didn't fully cover the tile would
        // previously be cleared to zero by ensureTileWithClearIfNeeded and
        // then only the sub-tile blit landed inside the image's rect,
        // leaving the rest of the tile at zero while monolithic kept its
        // pre-existing content. Full-tile blit from monolithic is bit-exact.
        if let grid = tileGrid, regionW > 0, regionH > 0 {
            let regionPixelRect = CGRect(x: dstX, y: dstY, width: regionW, height: regionH)
            let tileKeys = grid.tilesIntersecting(regionPixelRect)
            let tileSize = grid.tileSize
            let texW = texture.width
            let texH = texture.height

            if !tileKeys.isEmpty, let cmdBuf = commandQueue.makeCommandBuffer() {
                for key in tileKeys {
                    _ = grid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: cmdBuf)
                }
                if let blit = cmdBuf.makeBlitCommandEncoder() {
                    for key in tileKeys {
                        let srcX = key.x * tileSize
                        let srcY = key.y * tileSize
                        let blitW = min(tileSize, texW - srcX)
                        let blitH = min(tileSize, texH - srcY)
                        if blitW <= 0 || blitH <= 0 { continue }

                        grid.updateTile(at: key) { tile in
                            blit.copy(
                                from: texture,
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
        // === End dual-write block ========================================
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
        return device.makeTexture(descriptor: descriptor)
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
        sourceTexture: MTLTexture,
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
            print("⚠️ beginBlurAdjustment: failed to allocate intermediate textures")
            return
        }

        guard let mask = rasterizeSelectionMask(selectionPath, canvasSize: documentSize) else {
            print("⚠️ beginBlurAdjustment: failed to rasterize selection mask")
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        // Snapshot the current layer state — every preview Gaussian samples
        // from this, so subsequent slider tweaks don't compound on previous
        // output.
        blitCopy(commandBuffer: commandBuffer, source: sourceTexture, dest: snapshot)
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

    /// Bake the current preview into the supplied layer texture. Caller
    /// records undo with snapshots taken before/after this call.
    func commitBlurAdjustment(into layerTexture: MTLTexture, tileGrid: TileGrid? = nil) {
        guard let preview = blurAdjustmentPreview,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        blitCopy(commandBuffer: commandBuffer, source: preview, dest: layerTexture)

        // === Phase 2 hole #6 fix: tile-grid dual-write (wipe + rebuild) ====
        //
        // Blur adjustment writes a fully-blurred copy of the layer back into
        // the layer texture (canvas-sized). Same wipe-and-rebuild semantic
        // as loadImage rather than the refresh-allocated semantic of
        // restoreSnapshot, for one specific reason: Gaussian blur is a
        // convolution that can spread alpha into previously-empty tile
        // regions (e.g., a stroke near a tile boundary blurs outward and
        // deposits faint pixels into the adjacent tile). The tile grid
        // must allocate every tile in bounds to capture that smear; just
        // refreshing currently-allocated tiles would miss the new content.
        //
        // Performed on the SAME command buffer as the preview→layer blit
        // above. Metal serialises encoders within a buffer, so the per-
        // tile blit reads the post-blur monolithic.
        if let grid = tileGrid {
            for key in grid.allocatedKeys() {
                grid.dropTile(at: key)
            }
            var allKeys: [TileKey] = []
            allKeys.reserveCapacity(grid.gridWidth * grid.gridHeight)
            for ty in 0..<grid.gridHeight {
                for tx in 0..<grid.gridWidth {
                    allKeys.append(TileKey(x: tx, y: ty))
                }
            }
            for key in allKeys {
                _ = grid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: commandBuffer)
            }
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                let tileSize = grid.tileSize
                let texW = layerTexture.width
                let texH = layerTexture.height
                for key in allKeys {
                    let srcX = key.x * tileSize
                    let srcY = key.y * tileSize
                    let blitW = min(tileSize, texW - srcX)
                    let blitH = min(tileSize, texH - srcY)
                    if blitW <= 0 || blitH <= 0 { continue }
                    grid.updateTile(at: key) { tile in
                        blit.copy(
                            from: layerTexture,
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
        // === End dual-write block ========================================

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
        let layerTexture: MTLTexture
        let snapshot: MTLTexture
        let scratchH: MTLTexture
        let scratchV: MTLTexture
        let selectionMask: MTLTexture
        let settings: BrushSettings
        let viewport: SIMD2<Float>
        let sigma: Float
        let kernelHalfWidth: Int32
        let blurStrength: Float
        /// Phase 2 hole #3: tile grid captured at session start. Per-batch
        /// `appendBlurStrokeStamps` reads this for the dual-write; the grid
        /// is the same instance throughout the stroke since DrawingLayer
        /// is a reference type.
        let tileGrid: TileGrid?
    }

    private var activeBlurStrokeSession: BlurStrokeSession?

    /// Begin a real-time blur stroke. Snapshots `layerTexture`, allocates
    /// the two intermediate scratch textures used for the H+V Gaussian
    /// passes, and rasterises the selection mask once for the whole
    /// stroke. Returns false if any GPU resource isn't available — caller
    /// should fall back to the deferred `renderBlurStroke` path.
    @discardableResult
    func beginBlurStroke(
        to layerTexture: MTLTexture,
        settings: BrushSettings,
        screenSize: CGSize,
        selectionPath: [CGPoint]?,
        tileGrid: TileGrid? = nil
    ) -> Bool {
        // Defensive: end any prior session that didn't get cleaned up
        // (tool change mid-stroke, view teardown, etc.).
        activeBlurStrokeSession = nil

        guard stampBlurDepositPipelineState != nil,
              let snapshot = makeBlurIntermediateTexture(),
              let scratchH = makeBlurIntermediateTexture(),
              let scratchV = makeBlurIntermediateTexture(),
              let cb = commandQueue.makeCommandBuffer() else {
            print("⚠️ beginBlurStroke: pipeline or intermediate textures unavailable")
            return false
        }

        let mask = selectionMaskTexture(for: selectionPath, documentSize: screenSize) ?? noMaskTexture
        guard let selectionMask = mask else {
            print("⚠️ beginBlurStroke: selection mask unavailable")
            return false
        }

        // Snapshot layer → scratch source. waitUntilCompleted ensures the
        // first appendBlurStrokeStamps sees the pre-stroke pixels even
        // if it follows immediately on the same run loop.
        blitCopy(commandBuffer: cb, source: layerTexture, dest: snapshot)
        cb.commit()
        cb.waitUntilCompleted()

        let sigma = max(0.0, Float(settings.size) * 0.5)
        let halfWidth = Self.gaussianHalfWidth(for: sigma)
        let blurStrength = max(0.0, min(1.0, settings.blurStrength))
        let viewport = SIMD2<Float>(Float(layerTexture.width), Float(layerTexture.height))

        activeBlurStrokeSession = BlurStrokeSession(
            layerTexture: layerTexture,
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
    func appendBlurStrokeStamps(_ points: [BrushStroke.StrokePoint]) {
        guard !points.isEmpty,
              let s = activeBlurStrokeSession,
              let depositPipeline = stampBlurDepositPipelineState,
              let cb = commandQueue.makeCommandBuffer() else {
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

        let layerWidth = s.layerTexture.width
        let layerHeight = s.layerTexture.height

        // Phase 2 hole #3: accumulate per-stamp scissor rects into a batch
        // bbox. The bbox feeds the post-loop tile-grid dual-write so the
        // tiles touched by THIS batch's deposits get refreshed from
        // monolithic. Bbox stays in CGRect (not MTLScissorRect) so
        // `tilesIntersecting` can union/clip cleanly.
        var batchBbox: CGRect = .null

        for point in points {
            let safePressure: CGFloat = {
                guard point.pressure.isFinite else { return 1.0 }
                return max(0, min(1, point.pressure))
            }()
            uniforms.pressure = Float(safePressure)

            let radiusOnLayer = max(1, Int(ceil(s.settings.size * 0.5 * safePressure)))
            let kernelMargin = Int(s.kernelHalfWidth) + 4
            let footprint = radiusOnLayer + kernelMargin

            let cx = Int(point.location.x.rounded())
            let cy = Int(point.location.y.rounded())

            let x0 = max(0, cx - footprint)
            let y0 = max(0, cy - footprint)
            let x1 = min(layerWidth, cx + footprint)
            let y1 = min(layerHeight, cy + footprint)
            let rectW = x1 - x0
            let rectH = y1 - y0
            if rectW <= 0 || rectH <= 0 { continue }
            let scissor = MTLScissorRect(x: x0, y: y0, width: rectW, height: rectH)

            // Accumulate into batch bbox for the post-loop dual-write.
            let stampRect = CGRect(x: x0, y: y0, width: rectW, height: rectH)
            batchBbox = batchBbox.isNull ? stampRect : batchBbox.union(stampRect)

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

            // Pass 3: stamp deposit into the live layer.
            let depositDescriptor = MTLRenderPassDescriptor()
            depositDescriptor.colorAttachments[0].texture = s.layerTexture
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
            depositEncoder.setVertexBytes(&stampPosition, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            depositEncoder.setVertexBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 1)
            depositEncoder.setVertexBytes(&viewportCopy, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            depositEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)
            depositEncoder.setFragmentBytes(&blurStrength, length: MemoryLayout<Float>.stride, index: 1)
            depositEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
            depositEncoder.endEncoding()
        }

        // === Phase 2 hole #3 fix: tile-grid dual-write (batched-deposit) ====
        //
        // Mirror this batch's deposits into the tile grid by blitting every
        // tile intersecting the accumulated stamp bbox from the post-deposit
        // monolithic. Same command buffer as the deposits — Metal serialises
        // encoders within a buffer, so the blit reads the post-deposit
        // layer texture.
        //
        // Async commit (no waitUntilCompleted) per the function's existing
        // contract. Tile-grid metadata mutations (updateTile,
        // ensureTileWithClearIfNeeded) happen at submit time; actual tile
        // pixels become bit-exact with monolithic at GPU completion time.
        // Trust GPU queue ordering: subsequent ops on the same command
        // queue serialise behind this batch's command buffer, so they read
        // post-completion tile pixels. Matches the renderStroke async path's
        // risk profile. No verifier call here — async commit means the
        // verifier would race against the not-yet-completed blit. Next
        // dual-write callsite's verifier (next stroke commit, next save)
        // catches divergence if any.
        if let grid = s.tileGrid, !batchBbox.isNull, !batchBbox.isEmpty {
            let tileKeys = grid.tilesIntersecting(batchBbox)
            if !tileKeys.isEmpty {
                for key in tileKeys {
                    _ = grid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: cb)
                }
                if let blit = cb.makeBlitCommandEncoder() {
                    let tileSize = grid.tileSize
                    for key in tileKeys {
                        let srcX = key.x * tileSize
                        let srcY = key.y * tileSize
                        let blitW = min(tileSize, layerWidth - srcX)
                        let blitH = min(tileSize, layerHeight - srcY)
                        if blitW <= 0 || blitH <= 0 { continue }
                        grid.updateTile(at: key) { tile in
                            blit.copy(
                                from: s.layerTexture,
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
        }
        // === End dual-write block ========================================

        cb.commit()
        // No waitUntilCompleted — let the GPU pipeline this batch behind
        // any prior appendBlurStrokeStamps batch on the same queue.
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
        to layerTexture: MTLTexture,
        tileGrid: TileGrid? = nil,
        screenSize: CGSize,
        selectionPath: [CGPoint]?,
        completion: @escaping () -> Void
    ) {
        guard let depositPipeline = stampBlurDepositPipelineState,
              let snapshot = makeBlurIntermediateTexture(),
              let scratchH = makeBlurIntermediateTexture(),
              let scratchV = makeBlurIntermediateTexture(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("⚠️ renderBlurStroke: pipeline or intermediate textures unavailable")
            completion()
            return
        }

        // Selection mask (PR 3) — rasterized once at stroke start, sampled
        // per stamp by stampBlurDepositShader. nil/empty path → 1×1
        // noMaskTexture (no clipping).
        let selectionMask = selectionMaskTexture(for: selectionPath, documentSize: screenSize) ?? noMaskTexture

        // Snapshot the layer at stroke start. Every stamp samples from here.
        blitCopy(commandBuffer: commandBuffer, source: layerTexture, dest: snapshot)

        // Sigma derived from brush size only (per directive). Hardness drives
        // the stamp's edge falloff in the deposit shader; it does not affect
        // kernel width.
        let sigma = max(0.0, Float(stroke.settings.size) * 0.5)
        let halfWidth = Self.gaussianHalfWidth(for: sigma)
        let blurStrengthValue = max(0.0, min(1.0, stroke.settings.blurStrength))

        // Brush uniforms shared across all stamps in the stroke (only
        // pressure varies per-point).
        var uniforms = BrushUniforms(
            color: stroke.settings.color,
            size: Float(stroke.settings.size),
            opacity: Float(stroke.settings.opacity),
            hardness: Float(stroke.settings.hardness),
            tileOrigin: SIMD2<Float>(0, 0)
        )
        var blurStrength = blurStrengthValue

        let layerWidth = layerTexture.width
        let layerHeight = layerTexture.height
        let viewport = SIMD2<Float>(Float(layerWidth), Float(layerHeight))
        var viewportCopy = viewport

        // Scissor footprint per stamp = bbox of (radius + kernel half-width)
        // around the stamp center, with a small rounding margin. Computed
        // inline below since `radiusOnLayer` uses per-stamp pressure.

        // Phase 2 hole #4: stroke-wide bbox for the post-loop tile dual-write.
        var strokeBbox: CGRect = .null

        for point in stroke.points {
            let safePressure: CGFloat = {
                guard point.pressure.isFinite else { return 1.0 }
                return max(0, min(1, point.pressure))
            }()
            uniforms.pressure = Float(safePressure)

            let radiusOnLayer = max(1, Int(ceil(stroke.settings.size * 0.5 * safePressure)))
            let kernelMargin = Int(halfWidth) + 4
            let footprint = radiusOnLayer + kernelMargin

            let cx = Int(point.location.x.rounded())
            let cy = Int(point.location.y.rounded())

            let x0 = max(0, cx - footprint)
            let y0 = max(0, cy - footprint)
            let x1 = min(layerWidth, cx + footprint)
            let y1 = min(layerHeight, cy + footprint)
            let rectW = x1 - x0
            let rectH = y1 - y0
            if rectW <= 0 || rectH <= 0 {
                continue
            }
            let scissor = MTLScissorRect(x: x0, y: y0, width: rectW, height: rectH)

            // Accumulate for the post-loop dual-write.
            let stampRect = CGRect(x: x0, y: y0, width: rectW, height: rectH)
            strokeBbox = strokeBbox.isNull ? stampRect : strokeBbox.union(stampRect)

            // Pass 1: horizontal Gaussian, scissored.
            runGaussianPass(
                commandBuffer: commandBuffer,
                target: scratchH,
                source: snapshot,
                direction: SIMD2<Float>(1.0 / Float(snapshot.width), 0),
                sigma: sigma,
                kernelHalfWidth: halfWidth,
                scissorRect: scissor
            )

            // Pass 2: vertical Gaussian, scissored. Result is a fully blurred
            // copy of the snapshot inside the scissor footprint.
            runGaussianPass(
                commandBuffer: commandBuffer,
                target: scratchV,
                source: scratchH,
                direction: SIMD2<Float>(0, 1.0 / Float(scratchH.height)),
                sigma: sigma,
                kernelHalfWidth: halfWidth,
                scissorRect: scissor
            )

            // Pass 3: stamp deposit into the layer with scissor + brush
            // hardness mask. Standard sourceAlpha/oneMinusSourceAlpha blend.
            let depositDescriptor = MTLRenderPassDescriptor()
            depositDescriptor.colorAttachments[0].texture = layerTexture
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
            depositEncoder.setVertexBytes(&stampPosition, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            depositEncoder.setVertexBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 1)
            depositEncoder.setVertexBytes(&viewportCopy, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            depositEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)
            depositEncoder.setFragmentBytes(&blurStrength, length: MemoryLayout<Float>.stride, index: 1)
            depositEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
            depositEncoder.endEncoding()
        }

        // === Phase 2 hole #4 fix: tile-grid dual-write (batched-deposit) ====
        //
        // One-shot variant of the appendBlurStrokeStamps pattern (hole #3).
        // Mirror the entire stroke's deposits into the tile grid via
        // blit-from-monolithic for tiles intersecting strokeBbox, on the
        // SAME command buffer as the deposits. Metal serialises encoders
        // within a buffer; the blit reads the post-deposit layer texture.
        //
        // Commit path is async via addCompletedHandler — caller must
        // provide completion (signature is @escaping () -> Void, not
        // optional, per master audit N3). Same async-commit risk profile
        // as hole #3. No verifier call here (would race against the
        // not-yet-completed blit). Prior sync-fallback path (else branch
        // with waitUntilCompleted) was dead code and got deleted with N3.
        if let grid = tileGrid, !strokeBbox.isNull, !strokeBbox.isEmpty {
            let tileKeys = grid.tilesIntersecting(strokeBbox)
            if !tileKeys.isEmpty {
                for key in tileKeys {
                    _ = grid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: commandBuffer)
                }
                if let blit = commandBuffer.makeBlitCommandEncoder() {
                    let tileSize = grid.tileSize
                    for key in tileKeys {
                        let srcX = key.x * tileSize
                        let srcY = key.y * tileSize
                        let blitW = min(tileSize, layerWidth - srcX)
                        let blitH = min(tileSize, layerHeight - srcY)
                        if blitW <= 0 || blitH <= 0 { continue }
                        grid.updateTile(at: key) { tile in
                            blit.copy(
                                from: layerTexture,
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
        }
        // === End dual-write block ========================================

        commandBuffer.addCompletedHandler { _ in
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
    func beginSmudgeStroke(brushSize: CGFloat,
                           layerId: UUID,
                           selectionPath: [CGPoint]?,
                           documentSize: CGSize) -> Bool {
        endSmudgeStroke()
        guard let front = makeSmudgePatchTexture(brushSize: brushSize),
              let back  = makeSmudgePatchTexture(brushSize: brushSize) else {
            print("⚠️ beginSmudgeStroke: failed to allocate patch textures")
            return false
        }
        clearSmudgePatch(front)
        clearSmudgePatch(back)
        smudgePatchFront = front
        smudgePatchBack = back
        smudgePatchHalfSize = Float(brushSize) * 0.5
        smudgeStampIndex = 0
        smudgeStrokeLayerId = layerId
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
        to layerTexture: MTLTexture,
        layerId: UUID,
        tileGrid: TileGrid? = nil,
        screenSize: CGSize
    ) {
        guard !stamps.isEmpty else { return }
        guard let patchUpdatePipeline = smudgePatchUpdatePipelineState,
              let depositPipeline = smudgeDepositPipelineState,
              var front = smudgePatchFront,
              var back = smudgePatchBack else {
            print("⚠️ renderSmudgeStamps: pipeline or patch textures unavailable")
            return
        }
        // Hard sanity: layer must not change mid-stroke (patch is sized to
        // the layer captured at beginSmudgeStroke). If this trips, the
        // touch handler let the user switch layers under an active stroke
        // — that's a logic bug, not user error.
        assert(smudgeStrokeLayerId == layerId,
               "Smudge layer changed mid-stroke (was \(String(describing: smudgeStrokeLayerId)), now \(layerId))")
        guard smudgeStrokeLayerId == layerId else {
            print("⚠️ renderSmudgeStamps: layerId mismatch — refusing to render")
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let strength = max(0, min(1, settings.smudgeStrength))
        let halfSize = SIMD2<Float>(smudgePatchHalfSize, smudgePatchHalfSize)
        let layerSize = SIMD2<Float>(Float(layerTexture.width), Float(layerTexture.height))
        var viewport = SIMD2<Float>(Float(layerTexture.width), Float(layerTexture.height))

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

        // Phase 2 hole #5: accumulate deposit scissor rects into a batch
        // bbox for the post-loop tile-grid dual-write. Only the deposit
        // pass writes to layerTexture; patch-update passes write to the
        // patch textures (front/back), which are session-internal and
        // not mirrored into the tile grid. First-stamp pickup-only path
        // contributes nothing to bbox by construction.
        var batchBbox: CGRect = .null

        for stamp in stamps {
            let safePressure: Float = {
                guard stamp.pressure.isFinite else { return 1.0 }
                return Float(max(0, min(1, stamp.pressure)))
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

            // ----- Pass 1: patch update — full quad on the BACK patch.
            // Reads FRONT patch + layer, mixes, writes BACK.
            let updateDescriptor = MTLRenderPassDescriptor()
            updateDescriptor.colorAttachments[0].texture = back
            updateDescriptor.colorAttachments[0].loadAction = .dontCare
            updateDescriptor.colorAttachments[0].storeAction = .store
            guard let updateEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: updateDescriptor) else {
                continue
            }
            updateEncoder.setRenderPipelineState(patchUpdatePipeline)
            updateEncoder.setFragmentTexture(front, index: 0)
            updateEncoder.setFragmentTexture(layerTexture, index: 1)
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
                let x1 = min(layerTexture.width, cx + footprint)
                let y1 = min(layerTexture.height, cy + footprint)
                let rectW = x1 - x0
                let rectH = y1 - y0
                if rectW > 0 && rectH > 0 {
                    let scissor = MTLScissorRect(x: x0, y: y0, width: rectW, height: rectH)
                    let stampRect = CGRect(x: x0, y: y0, width: rectW, height: rectH)
                    batchBbox = batchBbox.isNull ? stampRect : batchBbox.union(stampRect)

                    let depositDescriptor = MTLRenderPassDescriptor()
                    depositDescriptor.colorAttachments[0].texture = layerTexture
                    depositDescriptor.colorAttachments[0].loadAction = .load
                    depositDescriptor.colorAttachments[0].storeAction = .store
                    if let depositEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: depositDescriptor) {
                        depositEncoder.setRenderPipelineState(depositPipeline)
                        depositEncoder.setScissorRect(scissor)
                        depositEncoder.setFragmentTexture(front, index: 0)  // updated patch
                        depositEncoder.setFragmentTexture(selectionMask, index: 2)

                        brushUniforms.pressure = safePressure

                        var stampPosition = stampCenter
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

        // === Phase 2 hole #5 fix: tile-grid dual-write (batched-deposit) ====
        //
        // Same pattern as appendBlurStrokeStamps (hole #3). Mirror this
        // batch's deposits into the tile grid via blit-from-monolithic for
        // tiles intersecting batchBbox, on the SAME command buffer as the
        // per-stamp render encoders. Metal serialises encoders within a
        // buffer; the blit reads the post-deposit layer texture.
        //
        // Async commit (no waitUntilCompleted) per the function's hot-path
        // contract. Trust GPU queue ordering: subsequent ops on the same
        // command queue serialise behind this batch. No verifier call —
        // async commit means the verifier would race the not-yet-completed
        // blit.
        if let grid = tileGrid, !batchBbox.isNull, !batchBbox.isEmpty {
            let tileKeys = grid.tilesIntersecting(batchBbox)
            if !tileKeys.isEmpty {
                for key in tileKeys {
                    _ = grid.ensureTileWithClearIfNeeded(at: key, onCommandBuffer: commandBuffer)
                }
                if let blit = commandBuffer.makeBlitCommandEncoder() {
                    let tileSize = grid.tileSize
                    let texW = layerTexture.width
                    let texH = layerTexture.height
                    for key in tileKeys {
                        let srcX = key.x * tileSize
                        let srcY = key.y * tileSize
                        let blitW = min(tileSize, texW - srcX)
                        let blitH = min(tileSize, texH - srcY)
                        if blitW <= 0 || blitH <= 0 { continue }
                        grid.updateTile(at: key) { tile in
                            blit.copy(
                                from: layerTexture,
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
        }
        // === End dual-write block ========================================

        commandBuffer.commit()
        // Don't waitUntilCompleted — touchesMoved is hot path. Subsequent
        // dispatches will queue behind on the same command queue; Metal
        // serialises within the queue so each stamp's writes are visible
        // to the next stamp's reads.
    }
}
