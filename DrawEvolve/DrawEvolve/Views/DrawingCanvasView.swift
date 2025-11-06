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

    // Critique history
    @State private var critiqueHistory: [CritiqueEntry] = []

    // Dark mode toggle
    @AppStorage("userPreferredColorScheme") private var userPreferredColorScheme: String = "light"

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

            // Blue preview stroke while dragging selection
            if let previewRect = canvasState.previewSelection {
                // Transform preview from document space to screen space
                let screenPreviewRect = canvasState.documentRectToScreen(previewRect)
                Rectangle()
                    .path(in: screenPreviewRect)
                    .stroke(Color.blue, lineWidth: 2)
                    .allowsHitTesting(false)
            }

            if let previewPath = canvasState.previewLassoPath, !previewPath.isEmpty {
                // Transform preview path from document space to screen space
                let screenPreviewPath = canvasState.documentPathToScreen(previewPath)
                Path { p in
                    p.move(to: screenPreviewPath[0])
                    for point in screenPreviewPath.dropFirst() {
                        p.addLine(to: point)
                    }
                }
                .stroke(Color.blue, lineWidth: 2)
                .allowsHitTesting(false)
            }

            // Marching ants selection overlay (after selection is made)
            if let selection = canvasState.activeSelection {
                // Transform selection from document space to screen space
                let screenSelection = canvasState.documentRectToScreen(selection)
                MarchingAntsRectangle(rect: screenSelection)
                    .allowsHitTesting(false)

                // Transform handles for rectangular selection
                SelectionTransformHandles(rect: screenSelection, canvasState: canvasState)
            }

            // Canvas transform indicators (top-right)
            VStack(alignment: .trailing, spacing: 4) {
                // Zoom indicator
                if canvasState.zoomScale != 1.0 {
                    Text("\(Int(canvasState.zoomScale * 100))%")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .transition(.opacity)
                }

                // Rotation indicator
                if canvasState.canvasRotation.degrees != 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "rotate.right")
                            .font(.caption2)
                        Text("\(Int(canvasState.canvasRotation.degrees))°")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .transition(.opacity)
                }

                // Layer indicator - always show current layer
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.caption2)
                    Text(canvasState.layers[safe: canvasState.selectedLayerIndex]?.name ?? "Layer")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)
                .cornerRadius(8)
            }
            .padding(.top, 8)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .allowsHitTesting(false)

            if let path = canvasState.selectionPath {
                // Transform path from document space to screen space
                let screenPath = canvasState.documentPathToScreen(path)
                MarchingAntsPath(path: screenPath)
                    .allowsHitTesting(false)

                // Transform handles for lasso selection (use bounding rect)
                let boundingRect = canvasState.calculateBoundingRect(for: path)
                let screenBoundingRect = canvasState.documentRectToScreen(boundingRect)
                SelectionTransformHandles(rect: screenBoundingRect, canvasState: canvasState)
            }

            // Show selection pixels being moved/transformed
            if let pixels = canvasState.selectionPixels,
               let originalRect = canvasState.selectionOriginalRect {
                // Apply transforms to selection pixels
                let hasOffset = canvasState.selectionOffset != .zero
                let hasScale = canvasState.selectionScale != 1.0
                let hasRotation = canvasState.selectionRotation != .zero

                if hasOffset || hasScale || hasRotation {
                    Image(uiImage: pixels)
                        .resizable()
                        .frame(
                            width: originalRect.width * canvasState.selectionScale,
                            height: originalRect.height * canvasState.selectionScale
                        )
                        .rotationEffect(canvasState.selectionRotation)
                        .position(
                            x: originalRect.origin.x + originalRect.width / 2 + canvasState.selectionOffset.x,
                            y: originalRect.origin.y + originalRect.height / 2 + canvasState.selectionOffset.y
                        )
                        .allowsHitTesting(false)
                        .opacity(0.8) // Slightly transparent to show it's being transformed
                }
            }

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

                            // Dark mode toggle
                            ToolButton(
                                icon: userPreferredColorScheme == "dark" ? "sun.max.fill" : "moon.fill",
                                isSelected: false
                            ) {
                                toggleColorScheme()
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

                            // Canvas Transform Controls
                            ToolButton(icon: "rotate.left", isSelected: false) {
                                canvasState.rotate(by: .degrees(-90), snapToGrid: true)
                            }
                            .help("Rotate canvas left 90°")

                            ToolButton(icon: "rotate.right", isSelected: false) {
                                canvasState.rotate(by: .degrees(90), snapToGrid: true)
                            }
                            .help("Rotate canvas right 90°")

                            ToolButton(icon: "arrow.counterclockwise", isSelected: false) {
                                canvasState.resetAllTransforms()
                            }
                            .help("Reset zoom, pan, and rotation")
                            .disabled(canvasState.zoomScale == 1.0 && canvasState.panOffset == .zero && canvasState.canvasRotation == .zero)

                            // AI Feedback button
                            ToolButton(icon: "sparkles", isSelected: showFeedback) {
                                if canvasState.feedback != nil {
                                    // If we have feedback, show the panel
                                    showFeedback = true
                                } else {
                                    // If no feedback yet, request it
                                    requestFeedback()
                                }
                            }
                            .disabled(canvasState.isEmpty)
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
                    critiqueHistory: critiqueHistory,
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
                                .foregroundColor(.primary)

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
        .onChange(of: canvasState.currentTool) { _, _ in
            // When tool changes, commit any active selection
            if canvasState.selectionPixels != nil {
                canvasState.commitSelection()
            }
        }
        .onAppear {
            loadExistingDrawing()
        }
        .preferredColorScheme(colorSchemeValue)
    }

    private var colorSchemeValue: ColorScheme? {
        switch userPreferredColorScheme {
        case "light":
            return .light
        case "dark":
            return .dark
        default:
            return .light // Default to light mode
        }
    }

    private func toggleColorScheme() {
        // Simple toggle between light and dark
        userPreferredColorScheme = (userPreferredColorScheme == "dark") ? "light" : "dark"
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
            showFeedback = true // Show feedback panel immediately
            print("  - Has feedback: YES (showing feedback panel)")
        } else {
            print("  - Has feedback: NO")
        }

        // Load critique history
        critiqueHistory = drawing.critiqueHistory
        print("  - Critique history: \(critiqueHistory.count) entries")

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

            // Add new feedback to critique history
            if let feedback = canvasState.feedback {
                let critiqueEntry = CritiqueEntry(
                    feedback: feedback,
                    timestamp: Date(),
                    context: context
                )
                critiqueHistory.append(critiqueEntry)
                print("Added critique to history (now \(critiqueHistory.count) entries)")

                // Show floating panel after feedback is received
                withAnimation {
                    showFeedback = true
                }
            }
        }
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
