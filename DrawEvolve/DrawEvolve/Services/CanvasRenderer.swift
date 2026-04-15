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
    private let commandQueue: MTLCommandQueue
    private var brushPipelineState: MTLRenderPipelineState?
    private var eraserPipelineState: MTLRenderPipelineState?
    private var compositePipelineState: MTLRenderPipelineState?
    private var textureDisplayPipelineState: MTLRenderPipelineState?
    private var textureDisplayWithTransformPipelineState: MTLRenderPipelineState? // For zoom/pan
    private var blurComputeState: MTLComputePipelineState?
    private var sharpenComputeState: MTLComputePipelineState?

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
        let diagonal = ceil(sqrt(screenSize.width * screenSize.width + screenSize.height * screenSize.height))
        // Round up to nearest power of 2 for better GPU performance
        let size = pow(2, ceil(log2(diagonal)))
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
              let compositeFragment = library.makeFunction(name: "compositeFragmentShader"),
              let textureDisplayFragment = library.makeFunction(name: "textureDisplayShader"),
              let blurKernel = library.makeFunction(name: "blurKernel"),
              let sharpenKernel = library.makeFunction(name: "sharpenKernel") else {
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

        do {
            brushPipelineState = try device.makeRenderPipelineState(descriptor: brushDescriptor)
            eraserPipelineState = try device.makeRenderPipelineState(descriptor: eraserDescriptor)
            compositePipelineState = try device.makeRenderPipelineState(descriptor: compositeDescriptor)
            textureDisplayPipelineState = try device.makeRenderPipelineState(descriptor: textureDisplayDescriptor)
            textureDisplayWithTransformPipelineState = try device.makeRenderPipelineState(descriptor: textureDisplayWithTransformDescriptor)
            blurComputeState = try device.makeComputePipelineState(function: blurKernel)
            sharpenComputeState = try device.makeComputePipelineState(function: sharpenKernel)
        } catch {
            print("Failed to create pipeline states: \(error)")
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
    func renderStroke(_ stroke: BrushStroke, to texture: MTLTexture, screenSize: CGSize) {
        print("🎨 CanvasRenderer: Rendering stroke with \(stroke.points.count) points")
        print("  Texture ID: \(ObjectIdentifier(texture))")
        print("  Screen size: \(screenSize.width)x\(screenSize.height)")
        print("  Texture size: \(texture.width)x\(texture.height)")
        print("  Tool: \(stroke.tool)")
        print("  Brush color: \(stroke.settings.color)")
        print("  Brush size: \(stroke.settings.size)")

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("CanvasRenderer: Failed to create command buffer")
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            print("CanvasRenderer: Failed to create render encoder")
            return
        }

        // Select pipeline based on tool
        let pipeline = stroke.tool == .eraser ? eraserPipelineState : brushPipelineState
        guard let pipelineState = pipeline else {
            print("CanvasRenderer: No pipeline state available")
            renderEncoder.endEncoding()
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        print("CanvasRenderer: Pipeline set, rendering points...")

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
        print("  Texture size: \(texture.width)x\(texture.height)")
        print("  Document size passed: \(screenSize.width)x\(screenSize.height)")

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
            // Update pressure for this point
            uniforms.pressure = Float(point.pressure)

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
        commandBuffer.commit()
        // Wait for completion so texture is readable for snapshots
        commandBuffer.waitUntilCompleted()
        print("CanvasRenderer: Stroke completed on GPU")
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
        // Create final texture
        guard let finalTexture = createLayerTexture() else {
            return nil
        }

        // Composite each visible layer
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

        // Blend each layer
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

        // Convert Metal texture to UIImage
        return textureToUIImage(finalTexture)
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
    func renderTextureToScreen(
        _ texture: MTLTexture,
        to renderEncoder: MTLRenderCommandEncoder,
        opacity: Float = 1.0,
        zoomScale: Float = 1.0,
        panOffset: SIMD2<Float> = SIMD2<Float>(0, 0),
        canvasRotation: Float = 0.0,
        viewportSize: SIMD2<Float> = SIMD2<Float>(0, 0)
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

        // Draw fullscreen quad (6 vertices for 2 triangles)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
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
        canvasRotation: Double = 0.0
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
        var uniforms = BrushUniforms(
            color: previewColor,
            size: Float(stroke.settings.size * textureToScreen * zoomScale),
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

            return SIMD2<Float>(Float(x), Float(y))
        }

        // Use the actual viewport size for the preview
        let viewport = SIMD2<Float>(Float(viewportSize.width), Float(viewportSize.height))

        // Render each point as a brush stamp
        var viewportCopy = viewport

        for (index, point) in stroke.points.enumerated() {
            // Update pressure for this point
            uniforms.pressure = Float(point.pressure)

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

    /// Flood fill (paint bucket) algorithm
    func floodFill(at point: CGPoint, with color: UIColor, in texture: MTLTexture, screenSize: CGSize) {
        print("CanvasRenderer: Flood fill at \(point) with color")

        // Scale coordinates from screen space to texture space
        let scaleX = CGFloat(texture.width) / screenSize.width
        let scaleY = CGFloat(texture.height) / screenSize.height
        let texturePoint = CGPoint(x: point.x * scaleX, y: point.y * scaleY)

        let x = Int(texturePoint.x)
        let y = Int(texturePoint.y)

        // Validate coordinates
        guard x >= 0, y >= 0, x < texture.width, y < texture.height else {
            print("ERROR: Point outside texture bounds")
            return
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
        let targetIndex = (y * width + x) * 4
        guard targetIndex + 3 < pixelData.count else {
            print("ERROR: Invalid pixel index")
            return
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
            print("Target and fill colors are the same, skipping fill")
            return
        }

        // Perform flood fill using stack-based approach
        var stack: [(Int, Int)] = [(x, y)]
        var visited = Set<Int>()

        func matches(_ px: Int, _ py: Int) -> Bool {
            guard px >= 0, py >= 0, px < width, py < height else { return false }
            let idx = (py * width + px) * 4
            guard idx + 3 < pixelData.count else { return false }

            let pixelKey = py * width + px
            if visited.contains(pixelKey) { return false }

            let b = pixelData[idx]
            let g = pixelData[idx + 1]
            let r = pixelData[idx + 2]
            let a = pixelData[idx + 3]

            return abs(Int(b) - Int(targetB)) <= tolerance &&
                   abs(Int(g) - Int(targetG)) <= tolerance &&
                   abs(Int(r) - Int(targetR)) <= tolerance &&
                   abs(Int(a) - Int(targetA)) <= tolerance
        }

        func setPixel(_ px: Int, _ py: Int) {
            let idx = (py * width + px) * 4
            guard idx + 3 < pixelData.count else { return }
            pixelData[idx] = fillB
            pixelData[idx + 1] = fillG
            pixelData[idx + 2] = fillR
            pixelData[idx + 3] = fillA
        }

        // Stack-based flood fill (prevents stack overflow)
        var fillCount = 0
        let maxFill = width * height // Safety limit

        while !stack.isEmpty && fillCount < maxFill {
            let (px, py) = stack.removeLast()

            if !matches(px, py) { continue }

            let pixelKey = py * width + px
            visited.insert(pixelKey)
            setPixel(px, py)
            fillCount += 1

            // Add neighbors
            stack.append((px + 1, py))
            stack.append((px - 1, py))
            stack.append((px, py + 1))
            stack.append((px, py - 1))
        }

        print("Filled \(fillCount) pixels")

        // Write modified pixel data back to texture
        pixelData.withUnsafeBytes { ptr in
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

        print("Flood fill complete")
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

    /// Render text to a texture at the specified location
    func renderText(
        _ text: String,
        at location: CGPoint,
        fontSize: CGFloat,
        color: UIColor,
        to texture: MTLTexture,
        screenSize: CGSize
    ) {
        print("CanvasRenderer: Rendering text '\(text)' at \(location)")

        // Create text attributes
        let font = UIFont.systemFont(ofSize: fontSize, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]

        // Calculate text size
        let textSize = (text as NSString).size(withAttributes: attributes)
        print("  Text size: \(textSize)")

        // Scale coordinates from screen space to texture space
        let scaleX = CGFloat(texture.width) / screenSize.width
        let scaleY = CGFloat(texture.height) / screenSize.height
        let scaledLocation = CGPoint(x: location.x * scaleX, y: location.y * scaleY)
        let scaledFontSize = fontSize * max(scaleX, scaleY)
        let scaledFont = UIFont.systemFont(ofSize: scaledFontSize, weight: .regular)
        let scaledAttributes: [NSAttributedString.Key: Any] = [
            .font: scaledFont,
            .foregroundColor: color
        ]
        let scaledTextSize = (text as NSString).size(withAttributes: scaledAttributes)

        print("  Scaled location: \(scaledLocation), scaled size: \(scaledTextSize)")

        // Create a temporary texture to render text into
        let textWidth = Int(ceil(scaledTextSize.width))
        let textHeight = Int(ceil(scaledTextSize.height))

        guard textWidth > 0, textHeight > 0 else {
            print("  ERROR: Invalid text dimensions")
            return
        }

        // Render text to a CGContext
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let bytesPerRow = textWidth * 4

        guard let context = CGContext(
            data: nil,
            width: textWidth,
            height: textHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            print("  ERROR: Failed to create CGContext")
            return
        }

        // Flip coordinate system for correct text orientation
        context.translateBy(x: 0, y: CGFloat(textHeight))
        context.scaleBy(x: 1.0, y: -1.0)

        // Draw text
        (text as NSString).draw(at: .zero, withAttributes: scaledAttributes)

        // Get the pixel data
        guard let data = context.data else {
            print("  ERROR: Failed to get context data")
            return
        }

        // Create a temporary Metal texture from the CGContext data
        let textTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: textWidth,
            height: textHeight,
            mipmapped: false
        )
        textTextureDescriptor.usage = [.shaderRead]

        guard let textTexture = device.makeTexture(descriptor: textTextureDescriptor) else {
            print("  ERROR: Failed to create text texture")
            return
        }

        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: textWidth, height: textHeight, depth: 1)
        )
        textTexture.replace(region: region, mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)

        // Now blit the text texture onto the layer texture at the specified location
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            print("  ERROR: Failed to create command buffer/blit encoder")
            return
        }

        let sourceOrigin = MTLOrigin(x: 0, y: 0, z: 0)
        let sourceSize = MTLSize(width: textWidth, height: textHeight, depth: 1)
        let destinationOrigin = MTLOrigin(
            x: Int(scaledLocation.x),
            y: Int(scaledLocation.y),
            z: 0
        )

        blitEncoder.copy(
            from: textTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: sourceOrigin,
            sourceSize: sourceSize,
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: destinationOrigin
        )

        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        print("  Text rendered successfully")
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

    // MARK: - Blur/Sharpen Effects

    /// Apply blur effect to texture at brush position
    func applyBlur(at point: CGPoint, radius: Float, to texture: MTLTexture, screenSize: CGSize) {
        guard let computeState = blurComputeState else {
            print("ERROR: Blur compute state not available")
            return
        }

        applyEffect(computeState: computeState, at: point, radius: radius, to: texture, screenSize: screenSize, effectName: "Blur")
    }

    /// Apply sharpen effect to texture at brush position
    func applySharpen(at point: CGPoint, radius: Float, to texture: MTLTexture, screenSize: CGSize) {
        guard let computeState = sharpenComputeState else {
            print("ERROR: Sharpen compute state not available")
            return
        }

        applyEffect(computeState: computeState, at: point, radius: radius, to: texture, screenSize: screenSize, effectName: "Sharpen")
    }

    /// Generic effect application (blur/sharpen)
    private func applyEffect(
        computeState: MTLComputePipelineState,
        at point: CGPoint,
        radius: Float,
        to texture: MTLTexture,
        screenSize: CGSize,
        effectName: String
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            print("ERROR: Failed to create command buffer/encoder for \(effectName)")
            return
        }

        computeEncoder.setComputePipelineState(computeState)
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setTexture(texture, index: 1) // Output texture (same as input for in-place operation)

        // Set effect parameters
        var effectRadius = radius
        computeEncoder.setBytes(&effectRadius, length: MemoryLayout<Float>.stride, index: 0)

        // Dispatch compute shader on full texture
        // (For brush-like application, we'd need a custom approach - for now this applies to whole image)
        let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)
        let threadgroups = MTLSize(
            width: (texture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (texture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )

        computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        print("\(effectName) effect applied successfully")
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

        // Read texture data
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

        // Clear pixels in the rect (set to transparent)
        for py in y..<(y + h) {
            for px in x..<(x + w) {
                let idx = (py * width + px) * 4
                guard idx + 3 < pixelData.count else { continue }
                pixelData[idx] = 0     // B
                pixelData[idx + 1] = 0 // G
                pixelData[idx + 2] = 0 // R
                pixelData[idx + 3] = 0 // A
            }
        }

        // Write back to texture
        pixelData.withUnsafeBytes { ptr in
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

        // Read texture data
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

        // Clear pixels inside the path. Test at pixel CENTER (px+0.5, py+0.5)
        // so edge pixels that are mostly-inside get included — testing at the
        // corner drops thin edge slivers.
        var clearedCount = 0
        for py in minY...maxY {
            for px in minX...maxX {
                let point = CGPoint(x: CGFloat(px) + 0.5, y: CGFloat(py) + 0.5)
                if isPointInPolygon(point, polygon: scaledPath) {
                    let idx = (py * width + px) * 4
                    guard idx + 3 < pixelData.count else { continue }
                    pixelData[idx] = 0     // B
                    pixelData[idx + 1] = 0 // G
                    pixelData[idx + 2] = 0 // R
                    pixelData[idx + 3] = 0 // A
                    clearedCount += 1
                }
            }
        }

        // Write back to texture
        pixelData.withUnsafeBytes { ptr in
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

        // Read full texture data
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

        // Extract the selected rectangle into a new buffer
        let selectionBytesPerRow = w * 4
        var selectionData = Data(count: selectionBytesPerRow * h)

        selectionData.withUnsafeMutableBytes { selPtr in
            pixelData.withUnsafeBytes { srcPtr in
                guard let selBase = selPtr.baseAddress,
                      let srcBase = srcPtr.baseAddress else { return }

                for row in 0..<h {
                    let srcOffset = ((y + row) * width + x) * 4
                    let dstOffset = row * w * 4
                    memcpy(selBase + dstOffset, srcBase + srcOffset, w * 4)
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

        // Read full texture data
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

        // Extract pixels in bounding box with alpha mask
        let selectionBytesPerRow = w * 4
        var selectionData = Data(count: selectionBytesPerRow * h)

        selectionData.withUnsafeMutableBytes { selPtr in
            pixelData.withUnsafeBytes { srcPtr in
                guard let selBase = selPtr.baseAddress,
                      let srcBase = srcPtr.baseAddress else { return }

                for row in 0..<h {
                    for col in 0..<w {
                        let texX = minX + col
                        let texY = minY + row
                        // Test pixel CENTER so edge pixels mostly inside the
                        // polygon are included (matches clearPath).
                        let point = CGPoint(x: CGFloat(texX) + 0.5, y: CGFloat(texY) + 0.5)

                        let srcOffset = (texY * width + texX) * 4
                        let dstOffset = (row * w + col) * 4

                        if isPointInPolygon(point, polygon: scaledPath) {
                            // Copy pixel if inside path
                            memcpy(selBase + dstOffset, srcBase + srcOffset, 4)
                        } else {
                            // Set to transparent if outside path
                            (selBase + dstOffset).storeBytes(of: UInt32(0), as: UInt32.self)
                        }
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

        // Read texture, composite, write back.
        let texWidth = texture.width
        let texHeight = texture.height
        let texBytesPerRow = texWidth * 4
        var texPixelData = Data(count: texBytesPerRow * texHeight)

        texPixelData.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            texture.getBytes(
                baseAddress,
                bytesPerRow: texBytesPerRow,
                from: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: texWidth, height: texHeight, depth: 1)
                ),
                mipmapLevel: 0
            )
        }

        texPixelData.withUnsafeMutableBytes { texPtr in
            guard let texBase = texPtr.baseAddress else { return }
            srcData.withMemoryRebound(to: UInt8.self, capacity: w * h * 4) { imgPtr in
                for row in 0..<h {
                    let texY = y + row
                    guard texY >= 0, texY < texHeight else { continue }
                    for col in 0..<w {
                        let texX = x + col
                        guard texX >= 0, texX < texWidth else { continue }

                        let imgOffset = (row * w + col) * 4
                        let texOffset = (texY * texWidth + texX) * 4

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

                        let dstB = Int((texBase + texOffset).load(as: UInt8.self))
                        let dstG = Int((texBase + texOffset + 1).load(as: UInt8.self))
                        let dstR = Int((texBase + texOffset + 2).load(as: UInt8.self))
                        let dstA = Int((texBase + texOffset + 3).load(as: UInt8.self))

                        let invSrcA = 255 - srcA
                        // (dst * invSrcA + 127) / 255  → rounded integer divide
                        let outB = srcB + (dstB * invSrcA + 127) / 255
                        let outG = srcG + (dstG * invSrcA + 127) / 255
                        let outR = srcR + (dstR * invSrcA + 127) / 255
                        let outA = srcA + (dstA * invSrcA + 127) / 255

                        (texBase + texOffset).storeBytes(of: UInt8(min(255, outB)), as: UInt8.self)
                        (texBase + texOffset + 1).storeBytes(of: UInt8(min(255, outG)), as: UInt8.self)
                        (texBase + texOffset + 2).storeBytes(of: UInt8(min(255, outR)), as: UInt8.self)
                        (texBase + texOffset + 3).storeBytes(of: UInt8(min(255, outA)), as: UInt8.self)
                    }
                }
            }
        }

        texPixelData.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            texture.replace(
                region: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: texWidth, height: texHeight, depth: 1)
                ),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: texBytesPerRow
            )
        }
    }
}
