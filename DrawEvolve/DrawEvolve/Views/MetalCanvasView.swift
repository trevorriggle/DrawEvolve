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
        super.touchesBegan(touches, with: event)
        touchDelegate?.touchesBegan(touches, in: self)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        touchDelegate?.touchesMoved(touches, in: self)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        touchDelegate?.touchesEnded(touches, in: self)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
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
        metalView.enableSetNeedsDisplay = true  // Manual control
        metalView.isPaused = true  // Don't draw unless needed
        metalView.framebufferOnly = false
        metalView.clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        metalView.backgroundColor = .white
        metalView.preferredFramesPerSecond = 30  // Limit to 30fps

        // Enable multi-touch and pencil input
        metalView.isMultipleTouchEnabled = true

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
            selectedLayerIndex: $selectedLayerIndex
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
        private var needsTextureInitialization = true

        init(
            layers: Binding<[DrawingLayer]>,
            currentTool: Binding<DrawingTool>,
            brushSettings: Binding<BrushSettings>,
            selectedLayerIndex: Binding<Int>
        ) {
            _layers = layers
            _currentTool = currentTool
            _brushSettings = brushSettings
            _selectedLayerIndex = selectedLayerIndex

            print("Coordinator: Initialized with \(layers.wrappedValue.count) layers")
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Handle view size changes
        }

        func draw(in view: MTKView) {
            guard let device = view.device,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor else {
                return
            }

            // Initialize renderer if needed
            if renderer == nil {
                renderer = CanvasRenderer(metalDevice: device)
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

            renderEncoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        func ensureLayerTextures() {
            guard needsTextureInitialization, let renderer = renderer else { return }

            print("ensureLayerTextures: Starting texture initialization for \(layers.count) layers")

            // Initialize textures - must be on main thread for binding updates
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                for i in 0..<self.layers.count {
                    if self.layers[i].texture == nil {
                        self.layers[i].texture = renderer.createLayerTexture()
                        print("Created texture for layer \(i)")
                    }
                }
                self.needsTextureInitialization = false
                print("Layer textures initialized: \(self.layers.count) layers")
            }
        }

        // Touch handling for drawing
        func touchesBegan(_ touches: Set<UITouch>, in view: MTKView) {
            guard let touch = touches.first else { return }

            // Ensure layer textures exist
            ensureLayerTextures()

            let location = touch.location(in: view)
            let pressure = touch.type == .pencil ? (touch.force > 0 ? touch.force / touch.maximumPossibleForce : 1.0) : 1.0
            let timestamp = touch.timestamp

            print("Touch began at \(location) with pressure \(pressure)")

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
        }

        func touchesMoved(_ touches: Set<UITouch>, in view: MTKView) {
            guard let touch = touches.first,
                  var stroke = currentStroke else { return }

            let location = touch.location(in: view)
            let pressure = touch.type == .pencil ? touch.force / touch.maximumPossibleForce : 1.0
            let timestamp = touch.timestamp

            // Add point to stroke with interpolation for smooth curves
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

            // Render stroke incrementally
            view.setNeedsDisplay()
        }

        func touchesEnded(_ touches: Set<UITouch>, in view: MTKView) {
            guard let stroke = currentStroke else { return }

            print("Touch ended - committing stroke with \(stroke.points.count) points")

            // Commit stroke to layer
            if let selectedLayer = layers[safe: selectedLayerIndex],
               let texture = selectedLayer.texture,
               let renderer = renderer {
                print("Rendering stroke to layer texture")
                renderer.renderStroke(stroke, to: texture)
            } else {
                print("ERROR: Could not render stroke - layer: \(layers[safe: selectedLayerIndex] != nil), texture: \(layers[safe: selectedLayerIndex]?.texture != nil), renderer: \(renderer != nil)")
            }

            currentStroke = nil
            lastPoint = nil
        }

        func touchesCancelled(_ touches: Set<UITouch>, in view: MTKView) {
            currentStroke = nil
            lastPoint = nil
        }
    }
}

// Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
