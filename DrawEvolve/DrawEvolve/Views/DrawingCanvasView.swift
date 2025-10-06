//
//  DrawingCanvasView.swift
//  DrawEvolve
//
//  Metal-powered canvas with full layer support, pressure sensitivity, and professional tools.
//

import SwiftUI

struct DrawingCanvasView: View {
    @Binding var context: DrawingContext

    // Canvas state
    @StateObject private var canvasState = CanvasStateManager()
    @State private var showFeedback = false
    @State private var isRequestingFeedback = false

    // Tool and layer controls
    @State private var showColorPicker = false
    @State private var showLayerPanel = false
    @State private var showBrushSettings = false

    var body: some View {
        NavigationView {
            ZStack {
                // Main canvas
                MetalCanvasView(
                    layers: $canvasState.layers,
                    currentTool: $canvasState.currentTool,
                    brushSettings: $canvasState.brushSettings,
                    selectedLayerIndex: $canvasState.selectedLayerIndex
                )
                .background(Color(uiColor: .systemGray6))

                // Feedback overlay
                if showFeedback, let feedback = canvasState.feedback {
                    FeedbackOverlay(
                        feedback: feedback,
                        isPresented: $showFeedback,
                        canvasImage: canvasState.exportImage()
                    )
                    .transition(.move(edge: .trailing))
                }

                // Side toolbar
                HStack {
                    VStack(spacing: 12) {
                        Spacer()

                        // Drawing tools
                        ToolButton(icon: DrawingTool.brush.icon, isSelected: canvasState.currentTool == .brush) {
                            canvasState.currentTool = .brush
                        }

                        ToolButton(icon: DrawingTool.eraser.icon, isSelected: canvasState.currentTool == .eraser) {
                            canvasState.currentTool = .eraser
                        }

                        Divider()

                        // Shape tools
                        ToolButton(icon: DrawingTool.line.icon, isSelected: canvasState.currentTool == .line) {
                            canvasState.currentTool = .line
                        }

                        ToolButton(icon: DrawingTool.rectangle.icon, isSelected: canvasState.currentTool == .rectangle) {
                            canvasState.currentTool = .rectangle
                        }

                        ToolButton(icon: DrawingTool.circle.icon, isSelected: canvasState.currentTool == .circle) {
                            canvasState.currentTool = .circle
                        }

                        ToolButton(icon: DrawingTool.polygon.icon, isSelected: canvasState.currentTool == .polygon) {
                            canvasState.currentTool = .polygon
                        }

                        Divider()

                        // Fill and color tools
                        ToolButton(icon: DrawingTool.paintBucket.icon, isSelected: canvasState.currentTool == .paintBucket) {
                            canvasState.currentTool = .paintBucket
                        }

                        ToolButton(icon: DrawingTool.eyeDropper.icon, isSelected: canvasState.currentTool == .eyeDropper) {
                            canvasState.currentTool = .eyeDropper
                        }

                        Divider()

                        // Selection tools
                        ToolButton(icon: DrawingTool.rectangleSelect.icon, isSelected: canvasState.currentTool == .rectangleSelect) {
                            canvasState.currentTool = .rectangleSelect
                        }

                        ToolButton(icon: DrawingTool.lasso.icon, isSelected: canvasState.currentTool == .lasso) {
                            canvasState.currentTool = .lasso
                        }

                        ToolButton(icon: DrawingTool.magicWand.icon, isSelected: canvasState.currentTool == .magicWand) {
                            canvasState.currentTool = .magicWand
                        }

                        Divider()

                        // Effect tools
                        ToolButton(icon: DrawingTool.smudge.icon, isSelected: canvasState.currentTool == .smudge) {
                            canvasState.currentTool = .smudge
                        }

                        ToolButton(icon: DrawingTool.blur.icon, isSelected: canvasState.currentTool == .blur) {
                            canvasState.currentTool = .blur
                        }

                        ToolButton(icon: DrawingTool.sharpen.icon, isSelected: canvasState.currentTool == .sharpen) {
                            canvasState.currentTool = .sharpen
                        }

                        ToolButton(icon: DrawingTool.cloneStamp.icon, isSelected: canvasState.currentTool == .cloneStamp) {
                            canvasState.currentTool = .cloneStamp
                        }

                        Divider()

                        // Transform tools
                        ToolButton(icon: DrawingTool.move.icon, isSelected: canvasState.currentTool == .move) {
                            canvasState.currentTool = .move
                        }

                        ToolButton(icon: DrawingTool.rotate.icon, isSelected: canvasState.currentTool == .rotate) {
                            canvasState.currentTool = .rotate
                        }

                        ToolButton(icon: DrawingTool.scale.icon, isSelected: canvasState.currentTool == .scale) {
                            canvasState.currentTool = .scale
                        }

                        ToolButton(icon: DrawingTool.text.icon, isSelected: canvasState.currentTool == .text) {
                            canvasState.currentTool = .text
                        }

                        Divider()

                        // Color picker button
                        Button(action: { showColorPicker.toggle() }) {
                            Circle()
                                .fill(Color(canvasState.brushSettings.color))
                                .frame(width: 40, height: 40)
                                .overlay(Circle().stroke(Color.white, lineWidth: 3))
                                .shadow(radius: 2)
                        }

                        Divider()

                        // Brush settings
                        ToolButton(icon: "slider.horizontal.3", isSelected: showBrushSettings) {
                            showBrushSettings.toggle()
                        }

                        // Layers
                        ToolButton(icon: "square.stack.3d.up", isSelected: showLayerPanel) {
                            showLayerPanel.toggle()
                        }

                        Spacer()

                        // Undo/Redo
                        ToolButton(icon: "arrow.uturn.backward", isSelected: false) {
                            canvasState.undo()
                        }
                        .disabled(!canvasState.historyManager.canUndo)

                        ToolButton(icon: "arrow.uturn.forward", isSelected: false) {
                            canvasState.redo()
                        }
                        .disabled(!canvasState.historyManager.canRedo)
                    }
                    .padding(.vertical, 20)
                    .padding(.horizontal, 12)
                    .background(Color(uiColor: .systemBackground).opacity(0.95))
                    .cornerRadius(16)
                    .shadow(radius: 5)
                    .padding()

                    Spacer()
                }

                // Bottom action bar
                VStack {
                    Spacer()
                    HStack(spacing: 16) {
                        Button(action: { canvasState.clearCanvas() }) {
                            VStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .font(.system(size: 20))
                                Text("Clear")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.red.opacity(0.1))
                            .foregroundColor(.red)
                            .cornerRadius(12)
                        }

                        Button(action: requestFeedback) {
                            VStack(spacing: 4) {
                                if isRequestingFeedback {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 20))
                                    Text("Get Feedback")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(isRequestingFeedback || canvasState.isEmpty)
                        .opacity(canvasState.isEmpty ? 0.5 : 1.0)
                    }
                    .padding(.horizontal, 80) // Offset for left toolbar
                    .padding(.bottom, 20)
                }
            }
            .navigationTitle("Create")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showColorPicker) {
                NavigationView {
                    AdvancedColorPicker(selectedColor: $canvasState.brushSettings.color)
                        .navigationTitle("Color")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") {
                                    showColorPicker = false
                                }
                            }
                        }
                }
            }
            .sheet(isPresented: $showLayerPanel) {
                NavigationView {
                    LayerPanelView(
                        layers: $canvasState.layers,
                        selectedIndex: $canvasState.selectedLayerIndex,
                        onAddLayer: { canvasState.addLayer() },
                        onDeleteLayer: { index in canvasState.deleteLayer(at: index) }
                    )
                    .navigationTitle("Layers")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                showLayerPanel = false
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showBrushSettings) {
                NavigationView {
                    BrushSettingsView(settings: $canvasState.brushSettings)
                        .navigationTitle("Brush Settings")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") {
                                    showBrushSettings = false
                                }
                            }
                        }
                }
            }
        }
        .alert("Feedback Error", isPresented: $canvasState.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(canvasState.errorMessage)
        }
    }

    private func requestFeedback() {
        isRequestingFeedback = true

        Task {
            await canvasState.requestFeedback(for: context)
            isRequestingFeedback = false
            if canvasState.feedback != nil {
                withAnimation {
                    showFeedback = true
                }
            }
        }
    }
}

struct ToolButton: View {
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(isSelected ? .white : .primary)
                .frame(width: 44, height: 44)
                .background(isSelected ? Color.accentColor : Color.clear)
                .cornerRadius(8)
        }
    }
}

// Canvas state manager
@MainActor
class CanvasStateManager: ObservableObject {
    @Published var layers: [DrawingLayer] = []
    @Published var selectedLayerIndex = 0
    @Published var currentTool: DrawingTool = .brush
    @Published var brushSettings = BrushSettings()
    @Published var feedback: String?
    @Published var showError = false
    @Published var errorMessage = ""

    let historyManager = HistoryManager()

    var isEmpty: Bool {
        layers.allSatisfy { $0.texture == nil }
    }

    init() {
        // Start with one layer
        addLayer()
    }

    func addLayer() {
        let layer = DrawingLayer(name: "Layer \(layers.count + 1)")
        layers.append(layer)
        selectedLayerIndex = layers.count - 1
    }

    func deleteLayer(at index: Int) {
        guard layers.count > 1, layers.indices.contains(index) else { return }
        layers.remove(at: index)
        if selectedLayerIndex >= layers.count {
            selectedLayerIndex = layers.count - 1
        }
    }

    func clearCanvas() {
        layers.removeAll()
        addLayer()
        historyManager.clear()
    }

    func undo() {
        guard historyManager.undo() != nil else { return }
        // TODO: Apply undo action
    }

    func redo() {
        guard historyManager.redo() != nil else { return }
        // TODO: Apply redo action
    }

    func exportImage() -> UIImage? {
        // Export all layers as single composited image
        return nil // Will implement with renderer
    }

    func requestFeedback(for context: DrawingContext) async {
        guard let image = exportImage() else {
            showError(message: "Failed to export drawing")
            return
        }

        do {
            let feedbackText = try await OpenAIManager.shared.requestFeedback(
                image: image,
                context: context
            )
            feedback = feedbackText
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    private func showError(message: String) {
        errorMessage = message
        showError = true
    }
}

#Preview {
    DrawingCanvasView(context: .constant(DrawingContext(
        subject: "Portrait",
        style: "Realism"
    )))
}
