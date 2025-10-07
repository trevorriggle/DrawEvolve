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
    private var blurComputeState: MTLComputePipelineState?
    private var sharpenComputeState: MTLComputePipelineState?

    // Canvas dimensions
    var canvasSize: CGSize = CGSize(width: 2048, height: 2048)

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

        // Texture display pipeline (for showing layers on screen)
        let textureDisplayDescriptor = MTLRenderPipelineDescriptor()
        textureDisplayDescriptor.vertexFunction = quadVertex
        textureDisplayDescriptor.fragmentFunction = textureDisplayFragment
        textureDisplayDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        textureDisplayDescriptor.colorAttachments[0].isBlendingEnabled = true
        textureDisplayDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        textureDisplayDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        textureDisplayDescriptor.colorAttachments[0].rgbBlendOperation = .add

        do {
            brushPipelineState = try device.makeRenderPipelineState(descriptor: brushDescriptor)
            eraserPipelineState = try device.makeRenderPipelineState(descriptor: eraserDescriptor)
            compositePipelineState = try device.makeRenderPipelineState(descriptor: compositeDescriptor)
            textureDisplayPipelineState = try device.makeRenderPipelineState(descriptor: textureDisplayDescriptor)
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
        print("CanvasRenderer: Rendering stroke with \(stroke.points.count) points")
        print("  Screen size: \(screenSize.width)x\(screenSize.height)")
        print("  Texture size: \(texture.width)x\(texture.height)")

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

        // CRITICAL: Scale coordinates from screen space to texture space
        let scaleX = Float(texture.width) / Float(screenSize.width)
        let scaleY = Float(texture.height) / Float(screenSize.height)
        print("  Coordinate scale: \(scaleX)x, \(scaleY)y")

        // Convert stroke points to positions and scale to texture space
        let positions = stroke.points.map { point in
            SIMD2<Float>(
                Float(point.location.x) * scaleX,
                Float(point.location.y) * scaleY
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
        for layer in layers where layer.isVisible {
            // Render layer texture with opacity and blend mode
            // Will implement layer blending
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

    /// Render a texture as a fullscreen quad
    func renderTextureToScreen(
        _ texture: MTLTexture,
        to renderEncoder: MTLRenderCommandEncoder,
        opacity: Float = 1.0
    ) {
        guard let pipeline = textureDisplayPipelineState else { return }

        renderEncoder.setRenderPipelineState(pipeline)
        renderEncoder.setFragmentTexture(texture, index: 0)

        // Pass opacity to shader
        var opacityValue = opacity
        renderEncoder.setFragmentBytes(&opacityValue, length: MemoryLayout<Float>.stride, index: 0)

        // Draw fullscreen quad (6 vertices for 2 triangles)
        // The quadVertexShader generates these automatically
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// Render in-progress stroke preview directly to screen (for real-time feedback)
    func renderStrokePreview(
        _ stroke: BrushStroke,
        to renderEncoder: MTLRenderCommandEncoder,
        viewportSize: CGSize
    ) {
        // Select pipeline based on tool
        let pipeline = stroke.tool == .eraser ? eraserPipelineState : brushPipelineState
        guard let pipelineState = pipeline else { return }

        renderEncoder.setRenderPipelineState(pipelineState)

        // Prepare brush uniforms
        var uniforms = BrushUniforms(
            color: stroke.settings.color,
            size: Float(stroke.settings.size),
            opacity: Float(stroke.settings.opacity),
            hardness: Float(stroke.settings.hardness)
        )

        // Convert stroke points to positions (already in screen space, no scaling needed)
        let positions = stroke.points.map { SIMD2<Float>(Float($0.location.x), Float($0.location.y)) }
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
    func floodFill(at point: CGPoint, with color: UIColor, in texture: MTLTexture) {
        // Will implement flood fill algorithm
        // 1. Sample color at point
        // 2. Recursively fill connected pixels of same color
        // 3. Optimized using Metal compute shaders for performance
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

            do {
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
            } catch {
                print("ERROR: Failed to read texture bytes: \(error)")
                return false
            }
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
}
