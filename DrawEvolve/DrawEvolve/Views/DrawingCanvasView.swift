//
//  DrawingCanvasView.swift
//  DrawEvolve
//
//  Metal-powered canvas with full layer support, pressure sensitivity, and professional tools.
//

import SwiftUI
@preconcurrency import Metal

struct DrawingCanvasView: View {
    @Binding var context: DrawingContext
    let existingDrawing: Drawing? // Optional existing drawing to load

    // Canvas state
    @StateObject private var canvasState = CanvasStateManager()
    @State private var showFeedback = false
    @State private var isRequestingFeedback = false
    @State private var isEditingExisting = false
    @State private var currentDrawingID: UUID?

    // Tool and layer controls
    @State private var showColorPicker = false
    @State private var showLayerPanel = false
    @State private var showBrushSettings = false

    // Text tool
    @State private var showTextInput = false
    @State private var textInputLocation: CGPoint = .zero
    @State private var textToRender = ""

    // Toolbar collapse state
    @State private var isToolbarCollapsed = false

    // Save state
    @State private var showSaveDialog = false
    @State private var drawingTitle = ""
    @State private var isSaving = false
    @State private var showGallery = false
    @StateObject private var storageManager = DrawingStorageManager.shared

    // Clear confirmation
    @State private var showClearConfirmation = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Main canvas - FULLSCREEN (bottom layer)
            MetalCanvasView(
                layers: $canvasState.layers,
                currentTool: $canvasState.currentTool,
                brushSettings: $canvasState.brushSettings,
                selectedLayerIndex: $canvasState.selectedLayerIndex,
                canvasState: canvasState,
                onTextRequest: { location in
                    textInputLocation = location
                    textToRender = ""
                    showTextInput = true
                }
            )
            .ignoresSafeArea() // Full screen, edge to edge
            .background(Color(uiColor: .systemGray6))

            // Floating toolbar overlay (top layer, left side)
            VStack(alignment: .leading, spacing: 0) {
                if !isToolbarCollapsed {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.fixed(44)), GridItem(.fixed(44))], spacing: 8) {
                            // Drawing tools
                            ToolButton(icon: DrawingTool.brush.icon, isSelected: canvasState.currentTool == .brush) {
                                canvasState.currentTool = .brush
                            }

                            ToolButton(icon: DrawingTool.eraser.icon, isSelected: canvasState.currentTool == .eraser) {
                                canvasState.currentTool = .eraser
                            }

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

                            // Fill and color tools
                            ToolButton(icon: DrawingTool.paintBucket.icon, isSelected: canvasState.currentTool == .paintBucket) {
                                canvasState.currentTool = .paintBucket
                            }

                            ToolButton(icon: DrawingTool.eyeDropper.icon, isSelected: canvasState.currentTool == .eyeDropper) {
                                canvasState.currentTool = .eyeDropper
                            }

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

                            ToolButton(icon: DrawingTool.smudge.icon, isSelected: canvasState.currentTool == .smudge) {
                                canvasState.currentTool = .smudge
                            }

                            // Effect tools
                            ToolButton(icon: DrawingTool.blur.icon, isSelected: canvasState.currentTool == .blur) {
                                canvasState.currentTool = .blur
                            }

                            ToolButton(icon: DrawingTool.sharpen.icon, isSelected: canvasState.currentTool == .sharpen) {
                                canvasState.currentTool = .sharpen
                            }

                            ToolButton(icon: DrawingTool.cloneStamp.icon, isSelected: canvasState.currentTool == .cloneStamp) {
                                canvasState.currentTool = .cloneStamp
                            }

                            ToolButton(icon: DrawingTool.move.icon, isSelected: canvasState.currentTool == .move) {
                                canvasState.currentTool = .move
                            }

                            // Transform tools
                            ToolButton(icon: DrawingTool.rotate.icon, isSelected: canvasState.currentTool == .rotate) {
                                canvasState.currentTool = .rotate
                            }

                            ToolButton(icon: DrawingTool.scale.icon, isSelected: canvasState.currentTool == .scale) {
                                canvasState.currentTool = .scale
                            }

                            ToolButton(icon: DrawingTool.text.icon, isSelected: canvasState.currentTool == .text) {
                                canvasState.currentTool = .text
                            }

                            // Clear button
                            ToolButton(icon: "trash", isSelected: false) {
                                showClearConfirmation = true
                            }

                            // Color picker button
                            Button(action: { showColorPicker.toggle() }) {
                                Circle()
                                    .fill(Color(canvasState.brushSettings.color))
                                    .frame(width: 40, height: 40)
                                    .overlay(Circle().stroke(Color.white, lineWidth: 3))
                                    .shadow(radius: 2)
                            }

                            // Brush settings
                            ToolButton(icon: "slider.horizontal.3", isSelected: showBrushSettings) {
                                showBrushSettings.toggle()
                            }

                            // Layers
                            ToolButton(icon: "square.stack.3d.up", isSelected: showLayerPanel) {
                                showLayerPanel.toggle()
                            }

                            // Undo/Redo
                            ToolButton(icon: "arrow.uturn.backward", isSelected: false) {
                                canvasState.undo()
                            }
                            .disabled(!canvasState.historyManager.canUndo)

                            ToolButton(icon: "arrow.uturn.forward", isSelected: false) {
                                canvasState.redo()
                            }
                            .disabled(!canvasState.historyManager.canRedo)

                            // Gallery button
                            ToolButton(icon: "photo.on.rectangle", isSelected: false) {
                                showGallery = true
                            }
                        }
                        .padding(.top, 12)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                    .frame(width: 104) // 2 columns of 44px + padding
                    .background(Color(uiColor: .systemBackground).opacity(0.95))
                    .cornerRadius(12)
                    .shadow(radius: 5)
                    .padding(.leading, 8)
                    .padding(.top, 8)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                // Collapse/Expand button at bottom of toolbar
                Button(action: {
                    withAnimation(.spring(response: 0.3)) {
                        isToolbarCollapsed.toggle()
                    }
                }) {
                    Image(systemName: isToolbarCollapsed ? "chevron.right" : "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44)
                        .background(Color(uiColor: .systemBackground).opacity(0.95))
                        .cornerRadius(8)
                        .shadow(radius: 5)
                }
                .padding(.leading, 8)
                .padding(.top, isToolbarCollapsed ? 8 : 4)
            }

            // Floating feedback panel
            if showFeedback, canvasState.feedback != nil {
                FloatingFeedbackPanel(
                    feedback: canvasState.feedback,
                    isPresented: $showFeedback
                )
            }

            // Selection actions overlay
            if canvasState.activeSelection != nil || canvasState.selectionPath != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            Text("Selection Active")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack(spacing: 12) {
                                // Cancel selection button
                                Button(action: {
                                    canvasState.clearSelection()
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 16))
                                        Text("Cancel")
                                            .font(.subheadline)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(Color.gray)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                }

                                // Delete selection button
                                Button(action: {
                                    canvasState.deleteSelectedPixels()
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "trash.fill")
                                            .font(.system(size: 16))
                                        Text("Delete")
                                            .font(.subheadline)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(Color.red)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                }
                            }
                        }
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                        .shadow(radius: 5)
                        .padding(.trailing, 12)
                        .padding(.bottom, 200) // Position above Save/Feedback buttons
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            // Top right - Gallery button (always visible)
            VStack {
                HStack {
                    Spacer()

                    Button(action: { showGallery = true }) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 32))
                            .foregroundColor(.accentColor)
                            .frame(width: 50, height: 50)
                            .background(Color(uiColor: .systemBackground).opacity(0.95))
                            .clipShape(Circle())
                            .shadow(radius: 4)
                    }
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                }
                Spacer()
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))

            // Bottom right - Action buttons (collapses with toolbar)
            if !isToolbarCollapsed {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()

                        VStack(spacing: 12) {
                            // Save to Gallery button
                            Button(action: {
                                showSaveDialog = true
                            }) {
                                HStack(spacing: 8) {
                                    if isSaving {
                                        ProgressView()
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "square.and.arrow.down")
                                            .font(.system(size: 18))
                                        Text("Save to Gallery")
                                            .font(.headline)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 14)
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                                .shadow(radius: 4)
                            }
                            .disabled(isSaving || canvasState.isEmpty)
                            .opacity(canvasState.isEmpty ? 0.5 : 1.0)

                            // Get Feedback button
                            Button(action: requestFeedback) {
                                HStack(spacing: 8) {
                                    if isRequestingFeedback {
                                        ProgressView()
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 18))
                                        Text("Get Feedback")
                                            .font(.headline)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 14)
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                                .shadow(radius: 4)
                            }
                            .disabled(isRequestingFeedback || canvasState.isEmpty)
                            .opacity(canvasState.isEmpty ? 0.5 : 1.0)
                        }
                        .padding(.trailing, 12)
                        .padding(.bottom, 12)
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
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
        .alert("Feedback Error", isPresented: $canvasState.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(canvasState.errorMessage)
        }
        .alert("Add Text", isPresented: $showTextInput) {
            TextField("Enter text", text: $textToRender)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                if !textToRender.isEmpty {
                    canvasState.renderText(textToRender, at: textInputLocation)
                }
            }
        } message: {
            Text("Enter the text you want to add to the canvas")
        }
        .alert("Save Drawing", isPresented: $showSaveDialog) {
            TextField("Title", text: $drawingTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task {
                    await saveDrawing()
                }
            }
        } message: {
            Text("Enter a title for your drawing")
        }
        .fullScreenCover(isPresented: $showGallery) {
            GalleryView()
        }
        .onChange(of: showGallery) { _, isShowing in
            if !isShowing {
                // Gallery was dismissed - refresh to show any changes
                print("Gallery dismissed, canvas state preserved")
            }
        }
        .alert("Clear Canvas", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                canvasState.clearCanvas()
            }
        } message: {
            Text("Are you sure you want to clear the canvas? This cannot be undone.")
        }
        .onAppear {
            loadExistingDrawing()
        }
    }

    private func loadExistingDrawing() {
        guard let drawing = existingDrawing else {
            print("DrawingCanvasView: No existing drawing to load")
            return
        }

        // Load the drawing state
        isEditingExisting = true
        currentDrawingID = drawing.id
        drawingTitle = drawing.title

        print("DrawingCanvasView: Loading existing drawing")
        print("  - Drawing ID: \(drawing.id)")
        print("  - Title: \(drawing.title)")
        print("  - Image data size: \(drawing.imageData.count) bytes")

        // Load feedback if exists
        if let feedback = drawing.feedback {
            canvasState.feedback = feedback
            print("  - Has feedback: YES")
        } else {
            print("  - Has feedback: NO")
        }

        // Load the image onto the canvas - delay until renderer is ready
        if let uiImage = UIImage(data: drawing.imageData) {
            print("  - UIImage created successfully: \(uiImage.size)")
            // Retry loading until renderer is initialized
            Task {
                var attempts = 0
                while canvasState.renderer == nil && attempts < 10 {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    attempts += 1
                }

                await MainActor.run {
                    if canvasState.renderer != nil {
                        canvasState.loadImage(uiImage)
                        print("✅ Successfully loaded existing drawing image onto canvas")
                    } else {
                        print("❌ ERROR: Failed to load drawing - renderer not initialized after \(attempts) attempts")
                    }
                }
            }
        } else {
            print("❌ ERROR: Failed to create UIImage from drawing data")
        }
    }

    private func saveDrawing() async {
        guard !drawingTitle.isEmpty else {
            print("❌ Save cancelled: Title is empty")
            return
        }

        isSaving = true

        print("💾 Saving drawing...")
        print("  - Title: \(drawingTitle)")
        print("  - Current Drawing ID: \(currentDrawingID?.uuidString ?? "nil (new drawing)")")
        print("  - Is editing existing: \(isEditingExisting)")

        guard let image = canvasState.exportImage(),
              let imageData = image.pngData() else {
            print("❌ ERROR: Failed to export image")
            isSaving = false
            return
        }

        print("  - Image exported: \(imageData.count) bytes")

        do {
            if let drawingID = currentDrawingID {
                // Update existing drawing
                print("  - Updating existing drawing with ID: \(drawingID)")
                try await storageManager.updateDrawing(
                    id: drawingID,
                    title: drawingTitle,
                    imageData: imageData,
                    feedback: canvasState.feedback,
                    context: context
                )
                print("✅ Drawing updated successfully!")
            } else {
                // Create new drawing
                print("  - Creating new drawing")
                let savedDrawing = try await storageManager.saveDrawing(
                    title: drawingTitle,
                    imageData: imageData,
                    feedback: canvasState.feedback,
                    context: context
                )
                // IMPORTANT: Set the currentDrawingID so subsequent saves update instead of creating new
                currentDrawingID = savedDrawing.id
                isEditingExisting = true
                print("✅ Drawing saved successfully with ID: \(savedDrawing.id)")
                print("  - Future saves will UPDATE this drawing, not create new ones")
            }
        } catch {
            print("❌ ERROR: Failed to save drawing: \(error)")
        }

        isSaving = false
    }

    private func requestFeedback() {
        isRequestingFeedback = true

        Task {
            await canvasState.requestFeedback(for: context)
            isRequestingFeedback = false

            // Show floating panel after feedback is received
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
    @Published var activeSelection: CGRect? = nil // Active selection rectangle
    @Published var selectionPath: [CGPoint]? = nil // For lasso selection

    let historyManager = HistoryManager()
    var renderer: CanvasRenderer?
    var screenSize: CGSize = .zero
    var hasLoadedExistingImage = false // Track if we've loaded an existing drawing

    var isEmpty: Bool {
        // Canvas is empty if:
        // 1. All layers have nil textures, OR
        // 2. All textures exist but have no history (never been drawn on)
        // IMPORTANT: If we've loaded an existing drawing, we should NOT be empty
        if layers.isEmpty {
            return true
        }

        // If we've loaded an existing image, we're not empty
        if hasLoadedExistingImage {
            return false
        }

        // If there's any history, we have content
        if historyManager.canUndo {
            return false
        }

        // Check if all layers have nil or empty textures
        return layers.allSatisfy { $0.texture == nil }
    }

    init() {
        // Start with one layer
        addLayer()
    }

    func addLayer() {
        let layer = DrawingLayer(name: "Layer \(layers.count + 1)")
        layers.append(layer)
        selectedLayerIndex = layers.count - 1
        historyManager.record(.layerAdded(layer))
    }

    func deleteLayer(at index: Int) {
        guard layers.count > 1, layers.indices.contains(index) else { return }
        let layer = layers[index]
        layers.remove(at: index)
        if selectedLayerIndex >= layers.count {
            selectedLayerIndex = layers.count - 1
        }
        historyManager.record(.layerRemoved(layer, index: index))
    }

    func clearCanvas() {
        layers.removeAll()
        addLayer()
        historyManager.clear()
    }

    func undo() {
        guard let action = historyManager.undo() else { return }

        switch action {
        case .stroke(let layerId, let beforeSnapshot, _):
            // Restore the layer texture to its state before the stroke
            if let layer = layers.first(where: { $0.id == layerId }),
               let texture = layer.texture,
               let renderer = renderer {
                renderer.restoreSnapshot(beforeSnapshot, to: texture)
                print("Undo stroke - restored texture from snapshot (\(beforeSnapshot.count) bytes)")

                // Update thumbnail (avoid Sendable warnings by not capturing directly)
                nonisolated(unsafe) let unsafeRenderer = renderer
                nonisolated(unsafe) let unsafeTexture = texture
                Task.detached {
                    if let thumbnail = unsafeRenderer.generateThumbnail(from: unsafeTexture, size: CGSize(width: 44, height: 44)) {
                        await MainActor.run {
                            if let layer = self.layers.first(where: { $0.id == layerId }) {
                                layer.updateThumbnail(thumbnail)
                            }
                        }
                    }
                }
            }

        case .layerAdded(let layer):
            // Remove the layer
            if let index = layers.firstIndex(where: { $0.id == layer.id }) {
                layers.remove(at: index)
                if selectedLayerIndex >= layers.count {
                    selectedLayerIndex = max(0, layers.count - 1)
                }
            }

        case .layerRemoved(let layer, let index):
            // Re-add the layer
            layers.insert(layer, at: min(index, layers.count))

        case .layerMoved(let from, let to):
            // Move layer back
            let layer = layers.remove(at: to)
            layers.insert(layer, at: from)

        case .layerPropertyChanged(let layerId, let property):
            // Restore old property value
            if let layer = layers.first(where: { $0.id == layerId }) {
                switch property {
                case .opacity(let old, _):
                    layer.opacity = old
                case .name(let old, _):
                    layer.name = old
                case .blendMode(let old, _):
                    layer.blendMode = old
                case .visibility(let old, _):
                    layer.isVisible = old
                }
            }
        }
    }

    func redo() {
        guard let action = historyManager.redo() else { return }

        switch action {
        case .stroke(let layerId, _, let afterSnapshot):
            // Restore the layer texture to its state after the stroke
            if let layer = layers.first(where: { $0.id == layerId }),
               let texture = layer.texture,
               let renderer = renderer {
                renderer.restoreSnapshot(afterSnapshot, to: texture)
                print("Redo stroke - restored texture from snapshot (\(afterSnapshot.count) bytes)")

                // Update thumbnail (avoid Sendable warnings by not capturing directly)
                nonisolated(unsafe) let unsafeRenderer = renderer
                nonisolated(unsafe) let unsafeTexture = texture
                Task.detached {
                    if let thumbnail = unsafeRenderer.generateThumbnail(from: unsafeTexture, size: CGSize(width: 44, height: 44)) {
                        await MainActor.run {
                            if let layer = self.layers.first(where: { $0.id == layerId }) {
                                layer.updateThumbnail(thumbnail)
                            }
                        }
                    }
                }
            }

        case .layerAdded(let layer):
            // Re-add the layer
            layers.append(layer)
            selectedLayerIndex = layers.count - 1

        case .layerRemoved(let layer, _):
            // Remove the layer again
            if let currentIndex = layers.firstIndex(where: { $0.id == layer.id }) {
                layers.remove(at: currentIndex)
                if selectedLayerIndex >= layers.count {
                    selectedLayerIndex = max(0, layers.count - 1)
                }
            }

        case .layerMoved(let from, let to):
            // Move layer forward again
            let layer = layers.remove(at: from)
            layers.insert(layer, at: to)

        case .layerPropertyChanged(let layerId, let property):
            // Apply new property value
            if let layer = layers.first(where: { $0.id == layerId }) {
                switch property {
                case .opacity(_, let new):
                    layer.opacity = new
                case .name(_, let new):
                    layer.name = new
                case .blendMode(_, let new):
                    layer.blendMode = new
                case .visibility(_, let new):
                    layer.isVisible = new
                }
            }
        }
    }

    func exportImage() -> UIImage? {
        // Export all layers as single composited image
        guard let renderer = renderer else {
            print("ERROR: Renderer not available for export")
            return nil
        }
        return renderer.exportImage(layers: layers)
    }

    func renderText(_ text: String, at location: CGPoint) {
        guard selectedLayerIndex < layers.count,
              let texture = layers[selectedLayerIndex].texture else {
            print("ERROR: Cannot render text - invalid layer or texture")
            return
        }

        guard let renderer = renderer else {
            print("ERROR: Renderer not available")
            return
        }

        let fontSize: CGFloat = 32

        renderer.renderText(
            text,
            at: location,
            fontSize: fontSize,
            color: brushSettings.color,
            to: texture,
            screenSize: screenSize
        )
    }

    func loadImage(_ image: UIImage) {
        guard let renderer = renderer,
              selectedLayerIndex < layers.count,
              let texture = layers[selectedLayerIndex].texture else {
            print("ERROR: Cannot load image - renderer or layer not available")
            return
        }

        renderer.loadImage(image, into: texture)

        // IMPORTANT: Mark that we've loaded an existing image so buttons enable
        hasLoadedExistingImage = true
        print("  - hasLoadedExistingImage set to true (buttons should now be enabled)")

        // Update thumbnail
        nonisolated(unsafe) let unsafeRenderer = renderer
        nonisolated(unsafe) let unsafeTexture = texture
        let layerId = layers[selectedLayerIndex].id
        Task.detached {
            if let thumbnail = unsafeRenderer.generateThumbnail(from: unsafeTexture, size: CGSize(width: 44, height: 44)) {
                await MainActor.run {
                    if let layer = self.layers.first(where: { $0.id == layerId }) {
                        layer.updateThumbnail(thumbnail)
                    }
                }
            }
        }
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

    // MARK: - Selection Management

    func clearSelection() {
        activeSelection = nil
        selectionPath = nil
    }

    func deleteSelectedPixels() {
        guard selectedLayerIndex < layers.count,
              let texture = layers[selectedLayerIndex].texture,
              let renderer = renderer else {
            print("ERROR: Cannot delete selection - invalid layer or texture")
            return
        }

        // Capture before snapshot
        let beforeSnapshot = renderer.captureSnapshot(of: texture)

        // Delete pixels in selection
        if let rect = activeSelection {
            renderer.clearRect(rect, in: texture, screenSize: screenSize)
        } else if let path = selectionPath {
            renderer.clearPath(path, in: texture, screenSize: screenSize)
        }

        // Capture after snapshot
        let afterSnapshot = renderer.captureSnapshot(of: texture)

        // Record in history
        if let before = beforeSnapshot, let after = afterSnapshot {
            let layerId = layers[selectedLayerIndex].id
            historyManager.record(.stroke(
                layerId: layerId,
                beforeSnapshot: before,
                afterSnapshot: after
            ))
        }

        // Update thumbnail
        let currentLayerIndex = selectedLayerIndex
        nonisolated(unsafe) let unsafeRenderer = renderer
        nonisolated(unsafe) let unsafeTexture = texture
        Task.detached {
            if let thumbnail = unsafeRenderer.generateThumbnail(from: unsafeTexture, size: CGSize(width: 44, height: 44)) {
                await MainActor.run {
                    if let layer = self.layers.first(where: { $0.id == self.layers[currentLayerIndex].id }) {
                        layer.updateThumbnail(thumbnail)
                    }
                }
            }
        }

        // Clear selection after deleting
        clearSelection()
    }
}

#Preview {
    DrawingCanvasView(
        context: .constant(DrawingContext(
            subject: "Portrait",
            style: "Realism"
        )),
        existingDrawing: nil
    )
}
