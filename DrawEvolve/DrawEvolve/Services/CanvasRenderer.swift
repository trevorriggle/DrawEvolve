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

class CanvasRenderer: NSObject {
    let device: MTLDevice // Public for GPU sync
    // Long-lived per-device command queue. Exposed so callers (MTKView delegate)
    // can reuse it instead of allocating a fresh queue per frame — a queue is
    // meant to live for the device's lifetime.
    let commandQueue: MTLCommandQueue
    private var brushPipelineState: MTLRenderPipelineState?
    private var eraserPipelineState: MTLRenderPipelineState?
    private var compositePipelineState: MTLRenderPipelineState?
    private var textureDisplayPipelineState: MTLRenderPipelineState?
    private var textureDisplayWithTransformPipelineState: MTLRenderPipelineState? // For zoom/pan
    private var floatingTexturePipelineState: MTLRenderPipelineState? // For floating selection drag preview
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
              let quadVertex = library.makeFunction(name: "quadVertexShader"),
              let quadVertexWithTransform = library.makeFunction(name: "quadVertexShaderWithTransform"),
              let quadVertexForRect = library.makeFunction(name: "quadVertexShaderForRect"),
              let compositeFragment = library.makeFunction(name: "compositeFragmentShader"),
              let textureDisplayFragment = library.makeFunction(name: "textureDisplayShader"),
              let gaussianBlurFragment = library.makeFunction(name: "gaussianBlurShader"),
              let gaussianBlurMaskedFragment = library.makeFunction(name: "gaussianBlurMaskedShader"),
              let stampBlurDepositFragment = library.makeFunction(name: "stampBlurDepositShader"),
              let smudgePatchUpdateFragment = library.makeFunction(name: "smudgePatchUpdateShader"),
              let smudgeDepositFragment = library.makeFunction(name: "smudgeDepositShader") else {
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
            compositePipelineState = try device.makeRenderPipelineState(descriptor: compositeDescriptor)
            textureDisplayPipelineState = try device.makeRenderPipelineState(descriptor: textureDisplayDescriptor)
            textureDisplayWithTransformPipelineState = try device.makeRenderPipelineState(descriptor: textureDisplayWithTransformDescriptor)
            floatingTexturePipelineState = try device.makeRenderPipelineState(descriptor: floatingTextureDescriptor)
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
    func renderStroke(_ stroke: BrushStroke, to texture: MTLTexture, screenSize: CGSize, completion: (() -> Void)? = nil) {
        #if DEBUG
        print("🎨 CanvasRenderer: Rendering stroke with \(stroke.points.count) points")
        print("  Texture ID: \(ObjectIdentifier(texture))")
        print("  Screen size: \(screenSize.width)x\(screenSize.height)")
        print("  Texture size: \(texture.width)x\(texture.height)")
        print("  Tool: \(stroke.tool)")
        print("  Brush color: \(stroke.settings.color)")
        print("  Brush size: \(stroke.settings.size)")
        #endif

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("CanvasRenderer: Failed to create command buffer")
            completion?()
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            print("CanvasRenderer: Failed to create render encoder")
            completion?()
            return
        }

        // Select pipeline based on tool
        let pipeline = stroke.tool == .eraser ? eraserPipelineState : brushPipelineState
        guard let pipelineState = pipeline else {
            print("CanvasRenderer: No pipeline state available")
            renderEncoder.endEncoding()
            completion?()
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        #if DEBUG
        print("CanvasRenderer: Pipeline set, rendering points...")
        #endif

        // Prepare brush uniforms
        var uniforms = BrushUniforms(
            color: stroke.settings.color,
            size: Float(stroke.settings.size),
            opacity: Float(stroke.settings.opacity),
            hardness: Float(stroke.settings.hardness)
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

        if let completion = completion {
            // Async path: caller does its post-stroke work (snapshot, history,
            // thumbnail) inside `completion`, which fires on main once the GPU
            // pass is finished. Lets the touch loop / preview keep running
            // instead of stalling on `waitUntilCompleted` after every commit.
            commandBuffer.addCompletedHandler { _ in
                DispatchQueue.main.async {
                    #if DEBUG
                    print("CanvasRenderer: Stroke completed on GPU (async)")
                    #endif
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
            #if DEBUG
            print("CanvasRenderer: Stroke completed on GPU")
            #endif
        }
    }

    // Metal structure matching shader
    private struct BrushUniforms {
        var color: SIMD4<Float>
        var size: Float
        var opacity: Float
        var hardness: Float
        var pressure: Float

        init(color: UIColor, size: Float, opacity: Float, hardness: Float) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            self.color = SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
            self.size = size
            self.opacity = opacity
            self.hardness = hardness
            self.pressure = 1.0
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
    func compositeLayersToTexture(layers: [DrawingLayer]) -> MTLTexture? {
        guard let finalTexture = createLayerTexture() else {
            return nil
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = finalTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return nil
        }

        guard let pipeline = textureDisplayPipelineState else {
            print("ERROR: textureDisplayPipelineState not available")
            return nil
        }

        renderEncoder.setRenderPipelineState(pipeline)

        for layer in layers where layer.isVisible {
            guard let layerTexture = layer.texture else {
                continue
            }

            renderEncoder.setFragmentTexture(layerTexture, index: 0)
            var opacityValue = layer.opacity
            renderEncoder.setFragmentBytes(&opacityValue, length: MemoryLayout<Float>.stride, index: 0)
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        renderEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return finalTexture
    }

    private func textureToUIImage(_ texture: MTLTexture) -> UIImage? {
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
        byDocOffset offset: CGPoint,
        screenSize: CGSize
    ) {
        let scaleX = CGFloat(texture.width) / screenSize.width
        let scaleY = CGFloat(texture.height) / screenSize.height
        let dx = Int((offset.x * scaleX).rounded())
        let dy = Int((offset.y * scaleY).rounded())

        if dx == 0 && dy == 0 { return }

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
        descriptor.usage = [.shaderRead]
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
        // The eraser pipeline zeroes out destination alpha, which on the drawable
        // would erase the composited image itself. Instead, render the eraser
        // preview as a ghost trail via the brush pipeline: semi-transparent gray
        // so the user sees the path being erased without destroying the preview.
        let isEraser = stroke.tool == .eraser
        guard let pipelineState = brushPipelineState else { return }

        renderEncoder.setRenderPipelineState(pipelineState)

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

        let previewColor: UIColor = isEraser
            ? UIColor(white: 0.55, alpha: 0.45)
            : stroke.settings.color
        let previewOpacity: Double = isEraser ? 1.0 : stroke.settings.opacity

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
            hardness: Float(stroke.settings.hardness)
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

        // Read pixel data from texture
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        let dataSize = bytesPerRow * height

        var pixelData = Data(count: dataSize)

        pixelData.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            texture.getBytes(
                baseAddress,
                bytesPerRow: bytesPerRow,
                from: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: width, height: height, depth: 1)
                ),
                mipmapLevel: 0
            )
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

                    stack.append((px + 1, py))
                    stack.append((px - 1, py))
                    stack.append((px, py + 1))
                    stack.append((px, py - 1))
                }
            }

            #if DEBUG
            print("Filled \(fillCount) pixels")
            #endif

            DispatchQueue.main.async {
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
                #if DEBUG
                print("Flood fill complete")
                #endif
                completion()
            }
        }

        return true
    }

    /// Capture a snapshot of a texture's pixel data for undo/redo
    func captureSnapshot(of texture: MTLTexture) -> Data? {
        // Verify texture is readable (iOS only supports .shared for CPU access)
        #if os(iOS)
        guard texture.storageMode == .shared else {
            print("ERROR: Cannot capture snapshot - texture storage mode is \(texture.storageMode.rawValue) (need .shared)")
            return nil
        }
        #else
        guard texture.storageMode == .shared || texture.storageMode == .managed else {
            print("ERROR: Cannot capture snapshot - texture storage mode is \(texture.storageMode.rawValue) (need .shared or .managed)")
            return nil
        }
        #endif

        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        let dataSize = bytesPerRow * height

        guard dataSize > 0 else {
            print("ERROR: Invalid texture size for snapshot")
            return nil
        }

        var pixelData = Data(count: dataSize)

        let success = pixelData.withUnsafeMutableBytes { ptr -> Bool in
            guard let baseAddress = ptr.baseAddress else {
                print("ERROR: Failed to get base address for pixel data")
                return false
            }

            texture.getBytes(
                baseAddress,
                bytesPerRow: bytesPerRow,
                from: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: width, height: height, depth: 1)
                ),
                mipmapLevel: 0
            )
            return true
        }

        return success ? pixelData : nil
    }

    /// Restore a texture from a snapshot
    func restoreSnapshot(_ snapshot: Data, to texture: MTLTexture) {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4

        snapshot.withUnsafeBytes { ptr in
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
    }

    /// Render text to a texture at the specified location.
    ///
    /// Caller passes `location` in DOC space and `screenSize` = documentSize
    /// (so the internal doc→texture scale is 1:1 in the current architecture).
    ///
    /// Two bugs the previous implementation had:
    ///   1. Crash — it double-scaled `location` (callers were passing UIKit
    ///      points as `screenSize` while `location` was already doc-space),
    ///      so `destinationOrigin + sourceSize` walked off the texture and
    ///      `blitEncoder.copy` Metal-asserted.
    ///   2. White rectangle — the blit was a raw byte copy, so the entire
    ///      rasterized text rect (transparent margins included) overwrote
    ///      whatever was underneath. On an empty layer the rectangular hole
    ///      revealed the white canvas background, hence the visible "white box".
    ///
    /// New approach: rasterize the text to a UIImage at scale=1.0 (so its
    /// pixel dims match texture pixels), then route through `renderImage`,
    /// which uses the same proven premultiplied-alpha Porter-Duff blend that
    /// moved selections rely on. Same blend, same coordinate handling, no
    /// new edge cases to debug.
    func renderText(
        _ text: String,
        at location: CGPoint,
        fontSize: CGFloat,
        color: UIColor,
        to texture: MTLTexture,
        screenSize: CGSize
    ) {
        print("CanvasRenderer: Rendering text '\(text)' at \(location)")

        // Doc→texture scale. With current architecture both equal canvasSize
        // and this is 1.0. Computed anyway so the math holds if they ever
        // diverge.
        let scaleX = CGFloat(texture.width) / screenSize.width
        let scaleY = CGFloat(texture.height) / screenSize.height
        let textureScale = max(scaleX, scaleY)

        // Render text at the texture-pixel font size so the rasterized image
        // is sharp at native canvas resolution. (Equivalent to `fontSize` in
        // doc units when scale is 1:1.)
        let renderFontSize = fontSize * textureScale
        let font = UIFont.systemFont(ofSize: renderFontSize, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]

        let textSizePx = (text as NSString).size(withAttributes: attributes)
        guard textSizePx.width > 0, textSizePx.height > 0 else {
            print("  ERROR: Invalid text dimensions")
            return
        }

        // Rasterize to a transparent-background UIImage at scale=1.0 so the
        // backing CGImage's pixel dimensions equal `textSizePx`. Without
        // forcing scale=1.0, UIGraphicsImageRenderer uses the device's main
        // screen scale (2× or 3×), which would blow the image up and break
        // the 1:1 doc→texture mapping renderImage relies on.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let imageRenderer = UIGraphicsImageRenderer(size: textSizePx, format: format)
        let textImage = imageRenderer.image { _ in
            (text as NSString).draw(at: .zero, withAttributes: attributes)
        }

        // Convert the texture-pixel size back to doc units for renderImage,
        // which re-applies texture/screenSize scaling internally. The two
        // scale factors cancel and the image lands at pixel-perfect 1:1.
        let docW = textSizePx.width / textureScale
        let docH = textSizePx.height / textureScale
        let destRect = CGRect(x: location.x, y: location.y, width: docW, height: docH)

        renderImage(textImage, at: destRect, to: texture, screenSize: screenSize)

        print("  Text rendered via renderImage at doc rect \(destRect)")
    }

    // MARK: - Load Image

    /// Load a UIImage into a texture (for editing existing drawings)
    func loadImage(_ image: UIImage, into texture: MTLTexture) {
        print("CanvasRenderer: Loading image into texture")
        print("  Texture ID: \(ObjectIdentifier(texture))")
        print("  Texture size: \(texture.width)x\(texture.height)")
        print("  Texture usage: \(texture.usage.rawValue)")
        print("  Texture storage mode: \(texture.storageMode.rawValue)")

        guard let cgImage = image.cgImage else {
            print("ERROR: Failed to get CGImage from UIImage")
            return
        }

        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4

        // Create a CGContext to render the image
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

        // Draw the image into the context (scaling to fit texture)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Get pixel data
        guard let data = context.data else {
            print("ERROR: Failed to get context data")
            return
        }

        // Copy pixel data into the texture
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: width, height: height, depth: 1)
        )

        texture.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )

        print("✅ Image loaded successfully into texture")
        print("  First 4 pixels (BGRA): ", terminator: "")
        data.withMemoryRebound(to: UInt8.self, capacity: 16) { ptr in
            for i in 0..<16 {
                print("\(ptr[i])", terminator: i % 4 == 3 ? " " : ",")
            }
        }
        print()
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

    func clearRect(_ rect: CGRect, in texture: MTLTexture, screenSize: CGSize) {
        print("CanvasRenderer: Clearing rect \(rect)")

        // Convert doc-space rect to integer pixel rect. Use floor/ceil so every
        // pixel the rect touches is included, then clamp to texture bounds.
        // clearRect and extractPixels MUST use identical integer rects or
        // extracted/cleared regions drift and leave ghost pixels on move.
        guard let (x, y, w, h) = texturePixelRect(for: rect, in: texture, screenSize: screenSize) else {
            print("ERROR: Rect outside texture bounds or empty")
            return
        }

        // Region-local I/O: at 4096² a full-texture getBytes is 64 MiB on every
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
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: regionBytesPerRow
            )
        }

        print("Rect cleared successfully")
    }

    /// Clear pixels along a path (for lasso selection)
    func clearPath(_ path: [CGPoint], in texture: MTLTexture, screenSize: CGSize) {
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
    func renderImage(_ image: UIImage, at rect: CGRect, to texture: MTLTexture, screenSize: CGSize) {
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
    func commitBlurAdjustment(into layerTexture: MTLTexture) {
        guard let preview = blurAdjustmentPreview,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        blitCopy(commandBuffer: commandBuffer, source: preview, dest: layerTexture)
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

    // MARK: - Brush-blur Stroke (paints Gaussian blur freeform)

    /// Per-stroke blur dispatch — mirrors `renderStroke` but performs a
    /// scissored two-pass Gaussian + stamp deposit at each interpolated point.
    /// Deferred batch: every stamp is enqueued on a single command buffer at
    /// touchesEnded, same as the brush.
    func renderBlurStroke(
        _ stroke: BrushStroke,
        to layerTexture: MTLTexture,
        screenSize: CGSize,
        completion: (() -> Void)? = nil
    ) {
        guard let depositPipeline = stampBlurDepositPipelineState,
              let snapshot = makeBlurIntermediateTexture(),
              let scratchH = makeBlurIntermediateTexture(),
              let scratchV = makeBlurIntermediateTexture(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("⚠️ renderBlurStroke: pipeline or intermediate textures unavailable")
            completion?()
            return
        }

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
            hardness: Float(stroke.settings.hardness)
        )
        var blurStrength = blurStrengthValue

        let layerWidth = layerTexture.width
        let layerHeight = layerTexture.height
        let viewport = SIMD2<Float>(Float(layerWidth), Float(layerHeight))
        var viewportCopy = viewport

        // Scissor footprint per stamp = bbox of (radius + kernel half-width)
        // around the stamp center, with a small rounding margin. Computed
        // inline below since `radiusOnLayer` uses per-stamp pressure.

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

            var stampPosition = SIMD2<Float>(Float(point.location.x), Float(point.location.y))
            depositEncoder.setVertexBytes(&stampPosition, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            depositEncoder.setVertexBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 1)
            depositEncoder.setVertexBytes(&viewportCopy, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            depositEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)
            depositEncoder.setFragmentBytes(&blurStrength, length: MemoryLayout<Float>.stride, index: 1)
            depositEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
            depositEncoder.endEncoding()
        }

        if let completion = completion {
            commandBuffer.addCompletedHandler { _ in
                DispatchQueue.main.async { completion() }
            }
            commandBuffer.commit()
        } else {
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
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
    func beginSmudgeStroke(brushSize: CGFloat, layerId: UUID) -> Bool {
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

        // Brush uniforms — color is unused by the deposit shader (smudge
        // doesn't paint the brush color), but the struct is shared with
        // the brush vertex shader so we still pass it. `pressure` is set
        // per-stamp below.
        var brushUniforms = BrushUniforms(
            color: settings.color,
            size: Float(settings.size),
            opacity: Float(settings.opacity),
            hardness: Float(settings.hardness)
        )

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

                    let depositDescriptor = MTLRenderPassDescriptor()
                    depositDescriptor.colorAttachments[0].texture = layerTexture
                    depositDescriptor.colorAttachments[0].loadAction = .load
                    depositDescriptor.colorAttachments[0].storeAction = .store
                    if let depositEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: depositDescriptor) {
                        depositEncoder.setRenderPipelineState(depositPipeline)
                        depositEncoder.setScissorRect(scissor)
                        depositEncoder.setFragmentTexture(front, index: 0)  // updated patch

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

        commandBuffer.commit()
        // Don't waitUntilCompleted — touchesMoved is hot path. Subsequent
        // dispatches will queue behind on the same command queue; Metal
        // serialises within the queue so each stamp's writes are visible
        // to the next stamp's reads.
    }
}
