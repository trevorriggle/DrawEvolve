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

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }

        metalView.device = device
        metalView.delegate = context.coordinator
        metalView.enableSetNeedsDisplay = true
        metalView.isPaused = true
        metalView.framebufferOnly = false
        metalView.clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        metalView.backgroundColor = .white

        // Enable multi-touch and pencil input
        metalView.isMultipleTouchEnabled = true

        // Connect touch events to coordinator
        metalView.touchDelegate = context.coordinator

        return metalView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // Update coordinator state without triggering view updates
        DispatchQueue.main.async {
            context.coordinator.layers = layers
            context.coordinator.currentTool = currentTool
            context.coordinator.brushSettings = brushSettings
            context.coordinator.selectedLayerIndex = selectedLayerIndex
        }

        // Ensure layer textures are initialized
        context.coordinator.ensureLayerTextures()

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

            guard let commandQueue = device.makeCommandQueue(),
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            // Clear background
            // Layers will composite on top

            // Render current stroke if in progress
            if let stroke = currentStroke, let layerTexture = layers[safe: selectedLayerIndex]?.texture {
                // Render stroke preview
                renderer?.renderStroke(stroke, to: layerTexture)
            }

            renderEncoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        func ensureLayerTextures() {
            guard needsTextureInitialization, let renderer = renderer else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                for i in 0..<self.layers.count {
                    if self.layers[i].texture == nil {
                        self.layers[i].texture = renderer.createLayerTexture()
                    }
                }
                self.needsTextureInitialization = false
            }
        }

        // Touch handling for drawing
        func touchesBegan(_ touches: Set<UITouch>, in view: MTKView) {
            guard let touch = touches.first else { return }

            let location = touch.location(in: view)
            let pressure = touch.type == .pencil ? touch.force / touch.maximumPossibleForce : 1.0
            let timestamp = touch.timestamp

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

            // Commit stroke to layer
            if let selectedLayer = layers[safe: selectedLayerIndex],
               let texture = selectedLayer.texture,
               let renderer = renderer {
                renderer.renderStroke(stroke, to: texture)
            }

            currentStroke = nil
            lastPoint = nil
            view.setNeedsDisplay()
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
