//
//  DrawingCanvasView.swift
//  DrawEvolve
//
//  Metal-powered canvas with full layer support, pressure sensitivity, and professional tools.
//

import SwiftUI
import PhotosUI
@preconcurrency import Metal

struct DrawingCanvasView: View {
    /// Visual scaffolding for upcoming social features. Defaults to true so
    /// the icon appears in normal builds; flip to false pre-archive to hide
    /// without removing the layout (no `#if DEBUG` — this is a deliberate
    /// release-time toggle, not a debug-only switch).
    private static let showGlobeIcon = true

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
    @State private var showSymmetrySettings = false

    // Global symmetry / mirror state. Owned by the canvas view so it
    // outlives any single tool selection — symmetry is a persistent mode,
    // not a per-tool toggle. Hydrates from UserDefaults on init.
    @StateObject private var symmetry = SymmetryConfig()

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
    /// Transient "Saved" checkmark on the Save button. Flips to true after a
    /// successful save (first-save or silent overwrite), auto-clears ~1.5s
    /// later so the button returns to its idle label.
    @State private var showSavedConfirmation = false
    @State private var showGallery = false
    @State private var showSettings = false   // Phase 6 — gear in collapsible chrome
    @StateObject private var storageManager = CloudDrawingStorageManager.shared

    // Clear confirmation
    @State private var showClearConfirmation = false

    // Image import (Photos picker)
    @State private var photoPickerItem: PhotosPickerItem?

    // Image export (Photos save)
    @State private var isSavingToPhotos = false
    @State private var showPhotoSaveConfirmation = false
    @State private var photoSaveError: String?

    // Critique history
    @State private var critiqueHistory: [CritiqueEntry] = []

    // Dark mode toggle
    @AppStorage("userPreferredColorScheme") private var userPreferredColorScheme: String = "light"

    var body: some View {
        // Body is split iPhone vs. iPad inside a Group wrapper so the
        // sheets / alerts / fullScreenCover / onChange / onAppear /
        // preferredColorScheme modifiers attach in one place and apply
        // across both branches. Lifting these to the Group from the iPad
        // ZStack is a deliberate, contained deviation from Phase 1's
        // "wholesale-quoted, no refactoring" rule — branched bodies cannot
        // share presentation state via simple duplication. Modifier
        // semantics post-lift are intended to be identical; the iPhone
        // Phase 2 / C1 smoke pass verifies every iPad presentation path
        // still fires correctly.
        Group {
            if DeviceIdiom.isPhone {
                phoneBody
            } else {
                padBody
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
                BrushSettingsView(
                    settings: $canvasState.brushSettings,
                    activeTool: canvasState.currentTool
                )
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
        .sheet(isPresented: $showSymmetrySettings) {
            NavigationView {
                SymmetrySettingsView(symmetry: symmetry)
                    .navigationTitle("Symmetry")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                showSymmetrySettings = false
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
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
        .alert(
            "Couldn't Save to Photos",
            isPresented: Binding(
                get: { photoSaveError != nil },
                set: { if !$0 { photoSaveError = nil } }
            ),
            presenting: photoSaveError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { err in
            Text(err)
        }
        .onChange(of: canvasState.currentTool) { _, _ in
            // When tool changes, commit any active selection
            if canvasState.selectionPixels != nil {
                canvasState.commitSelection()
            }
        }
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    await MainActor.run {
                        canvasState.importImage(uiImage)
                    }
                }
                await MainActor.run { photoPickerItem = nil }
            }
        }
        .onAppear {
            loadExistingDrawing()
        }
        .preferredColorScheme(colorSchemeValue)
    }

    // MARK: - iPhone Phase 2 / C1 skeleton
    //
    // Navbar (Gallery leading / Settings gear trailing) + canvas + Save
    // button only. No tool strip, no action row, no selection bar yet —
    // those land in C2. Tool selection, undo/redo, and the rest of the
    // chrome are unreachable on iPhone in this commit; the user can sign
    // in, see the canvas, hit Save, open Gallery, and reach Settings.
    // That's enough to verify the body-branching plumbing without dragging
    // C2's surface area into C1's diff.
    //
    // Leading nav button is Gallery (not "Close" or "Back") because on
    // iPhone the canvas is always entered from a Gallery presentation or
    // a fresh-canvas launch — Gallery is conceptually a presentation OVER
    // the canvas, not a parent in a nav stack. Presenting GalleryView as
    // a fullScreenCover from the leading button matches the iPad mental
    // model where Gallery is sheet-like; canvas state (layers, undo
    // stack, dirty bit) persists behind the cover. A "Close" button
    // would imply discard/dismiss, which is wrong from a fresh canvas
    // launch and ambiguous mid-session.

    private var phoneBody: some View {
        NavigationStack {
            ZStack {
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
                    },
                    symmetry: symmetry
                )
                .ignoresSafeArea()
                .background(Color(uiColor: .systemGray6))
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showGallery = true }) {
                        Image(systemName: "photo.on.rectangle")
                    }
                    .accessibilityLabel("Gallery")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    phoneSelectionContextBar
                    phoneToolStrip
                    phoneActionRow
                }
                .padding(.top, 8)
                .background(.ultraThinMaterial)
            }
        }
    }

    // MARK: - iPhone tool strip (C2)
    //
    // All 27 tiles, wholesale-quoted from padBody's LazyVGrid in iPad
    // order. Phase 2 is layout-only — content parity (which tools exist,
    // which order, dark-mode toggle in the strip vs. Settings) is a non-
    // goal to break here. If a tile is added / reordered / removed in
    // padBody's LazyVGrid, mirror the change here. The tile bodies are
    // duplicated rather than extracted-and-shared because extracting
    // would force a structural change to padBody, which Phase 2 does not
    // authorize beyond the body-branching modifier lift in C1.
    //
    // Strip extent: 27 × 44 + 26 × 8 = 1396pt. On a 375pt iPhone 13 mini
    // viewport the strip is trivially scrollable.

    private var phoneToolStrip: some View {
        // TODO: v1.1 — scroll affordance (edge fade or transient indicator
        // on first launch). showsIndicators: false matches the iPad chrome
        // aesthetic but first-time iPhone users may not realize the strip
        // scrolls. Worth a once-per-install hint or a permanent gradient
        // fade on the right edge.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Group {
                    ToolButton(icon: DrawingTool.brush.icon, isSelected: canvasState.currentTool == .brush) {
                        canvasState.currentTool = .brush
                    }
                    ToolButton(icon: DrawingTool.eraser.icon, isSelected: canvasState.currentTool == .eraser) {
                        canvasState.currentTool = .eraser
                    }
                    ToolButton(icon: DrawingTool.blur.icon, isSelected: canvasState.currentTool == .blur) {
                        canvasState.currentTool = .blur
                    }
                    ToolButton(icon: DrawingTool.blurAdjustment.icon, isSelected: canvasState.currentTool == .blurAdjustment) {
                        canvasState.currentTool = .blurAdjustment
                    }
                    ToolButton(icon: DrawingTool.line.icon, isSelected: canvasState.currentTool == .line) {
                        canvasState.currentTool = .line
                    }
                    ToolButton(icon: DrawingTool.rectangle.icon, isSelected: canvasState.currentTool == .rectangle) {
                        canvasState.currentTool = .rectangle
                    }
                    ToolButton(icon: DrawingTool.circle.icon, isSelected: canvasState.currentTool == .circle) {
                        canvasState.currentTool = .circle
                    }
                    ToolButton(icon: DrawingTool.paintBucket.icon, isSelected: canvasState.currentTool == .paintBucket) {
                        canvasState.currentTool = .paintBucket
                    }
                    ToolButton(icon: DrawingTool.eyeDropper.icon, isSelected: canvasState.currentTool == .eyeDropper) {
                        canvasState.currentTool = .eyeDropper
                    }
                }
                Group {
                    ToolButton(icon: DrawingTool.rectangleSelect.icon, isSelected: canvasState.currentTool == .rectangleSelect) {
                        canvasState.currentTool = .rectangleSelect
                    }
                    ToolButton(icon: DrawingTool.lasso.icon, isSelected: canvasState.currentTool == .lasso) {
                        canvasState.currentTool = .lasso
                    }
                    ToolButton(icon: DrawingTool.move.icon, isSelected: canvasState.currentTool == .move) {
                        canvasState.currentTool = .move
                    }
                    ToolButton(icon: DrawingTool.text.icon, isSelected: canvasState.currentTool == .text) {
                        canvasState.currentTool = .text
                    }
                    PhotosPicker(selection: $photoPickerItem, matching: .images) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 22))
                            .frame(width: 44, height: 44)
                    }
                    ToolButton(
                        icon: showPhotoSaveConfirmation ? "checkmark" : "arrow.down.to.line",
                        isSelected: false
                    ) {
                        Task { await downloadToPhotos() }
                    }
                    .disabled(isSavingToPhotos)
                    ToolButton(icon: "trash", isSelected: false) {
                        showClearConfirmation = true
                    }
                    Button(action: {
                        guard canvasState.currentTool != .blur,
                              canvasState.currentTool != .blurAdjustment else { return }
                        showColorPicker.toggle()
                    }) {
                        Circle()
                            .fill(Color(canvasState.brushSettings.color))
                            .frame(width: 40, height: 40)
                            .overlay(Circle().stroke(Color.white, lineWidth: 3))
                            .shadow(radius: 2)
                            .opacity(
                                (canvasState.currentTool == .blur ||
                                 canvasState.currentTool == .blurAdjustment) ? 0.4 : 1.0
                            )
                    }
                    .disabled(canvasState.currentTool == .blur || canvasState.currentTool == .blurAdjustment)
                    ToolButton(icon: "slider.horizontal.3", isSelected: showBrushSettings) {
                        showBrushSettings.toggle()
                    }
                }
                Group {
                    ToolButton(icon: "square.stack.3d.up", isSelected: showLayerPanel) {
                        showLayerPanel.toggle()
                    }
                    ToolButton(
                        icon: "square.split.2x1",
                        isSelected: showSymmetrySettings || symmetry.mode != .off
                    ) {
                        showSymmetrySettings.toggle()
                    }
                    ToolButton(
                        icon: userPreferredColorScheme == "dark" ? "sun.max.fill" : "moon.fill",
                        isSelected: false
                    ) {
                        toggleColorScheme()
                    }
                    ToolButton(icon: "arrow.uturn.backward", isSelected: false) {
                        canvasState.undo()
                    }
                    .disabled(!canvasState.historyManager.canUndo)
                    ToolButton(icon: "arrow.uturn.forward", isSelected: false) {
                        canvasState.redo()
                    }
                    .disabled(!canvasState.historyManager.canRedo)
                    ToolButton(
                        icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                        isSelected: canvasState.flipHorizontal
                    ) {
                        canvasState.toggleFlipHorizontal()
                    }
                    .help("Flip canvas horizontally")
                    ToolButton(
                        icon: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                        isSelected: canvasState.flipVertical
                    ) {
                        canvasState.toggleFlipVertical()
                    }
                    .help("Flip canvas vertically")
                    ToolButton(icon: "viewfinder", isSelected: false) {
                        canvasState.resetAllTransforms()
                    }
                    .help("Reset zoom, pan, rotation, and flips")
                    .disabled(canvasState.zoomScale == 1.0
                              && canvasState.panOffset == .zero
                              && canvasState.canvasRotation == .zero
                              && !canvasState.flipHorizontal
                              && !canvasState.flipVertical)
                    ToolButton(icon: "sparkles", isSelected: showFeedback) {
                        if canvasState.feedback != nil {
                            showFeedback.toggle()
                        } else {
                            requestFeedback()
                        }
                    }
                    .disabled(canvasState.isEmpty)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: - iPhone action row (C2)
    //
    // Save + Get Feedback side-by-side, both keeping their existing
    // compact pill styling (option (a) from the Phase 2 plan: "keep
    // 'Save to Gallery / Saved ✓' as-is, frame(maxWidth: .infinity)
    // gives plenty of room"). Centered horizontally; the iPhone width
    // accommodates both natural pill sizes with room to breathe.

    private var phoneActionRow: some View {
        HStack(spacing: 12) {
            saveToGalleryButton
            getFeedbackButton
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - iPhone selection-active context bar (C2)
    //
    // Repositioning of iPad's existing "Selection Active" pill into the
    // bottom safe-area inset (option (a) from the Phase 2 plan). Visual
    // identical to padBody's pill — same caption, same Cancel/Delete
    // buttons, same .ultraThinMaterial card styling. Only difference is
    // the outer positioning: iPad floats it above the bottom-right
    // action stack via padding(.bottom, 200); iPhone slots it above the
    // tool strip + action row via the safeAreaInset VStack ordering.
    //
    // Conditionally rendered — when no selection is active, the safe-
    // area inset contracts and the canvas grows to fill. SwiftUI animates
    // the inset growth/shrinkage by default; the .move(.bottom) +
    // .opacity transition keeps the pill itself smooth as it appears.

    @ViewBuilder
    private var phoneSelectionContextBar: some View {
        if canvasState.activeSelection != nil || canvasState.selectionPath != nil {
            VStack(spacing: 8) {
                Text("Selection Active")
                    .font(.caption)
                    .foregroundColor(.primary)

                HStack(spacing: 12) {
                    Button(action: { canvasState.clearSelection() }) {
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

                    Button(action: { canvasState.deleteSelectedPixels() }) {
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
            .background(.regularMaterial)
            .cornerRadius(12)
            .shadow(radius: 5)
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - iPad layout (unchanged from pre-Phase-2 main)
    //
    // Wholesale-quoted; do NOT edit padBody contents in iPhone Phase 2
    // layout PRs. Phase 2 is layout-only on iPhone. The only structural
    // change relative to pre-Phase-2 is that this used to be the body
    // root directly (with all sheets / alerts / fullScreenCover modifiers
    // attached here); those modifiers are now lifted to the outer Group
    // wrapper in `body` so both branches share them.

    private var padBody: some View {
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
                },
                symmetry: symmetry
            )
            .ignoresSafeArea() // Full screen, edge to edge
            .background(Color(uiColor: .systemGray6))

            // Selection overlays use the MTKView's full-screen coordinate
            // space (the MTKView ignores safe area at line 70). Without
            // .ignoresSafeArea() on each overlay, SwiftUI lays them out
            // inside the safe-area-reduced ZStack frame, shifting them down
            // by safeAreaInsets.top (~20pt iPad portrait). The marching
            // ants then visually misalign with the actual selected pixels
            // by that offset. Any new overlay aligned to canvas pixels
            // needs the same modifier.

            // Blue preview stroke while dragging selection
            if let previewRect = canvasState.previewSelection {
                // Transform preview from document space to screen space
                let screenPreviewRect = canvasState.documentRectToScreen(previewRect)
                Rectangle()
                    .path(in: screenPreviewRect)
                    .stroke(Color.blue, lineWidth: 2)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }

            if let previewPath = canvasState.previewLassoPath, !previewPath.isEmpty {
                // Transform preview path from document space to screen space
                let screenPreviewPath = canvasState.documentPathToScreen(previewPath)
                Path { p in
                    p.move(to: screenPreviewPath[0])
                    for point in screenPreviewPath.dropFirst() {
                        p.addLine(to: point)
                    }
                    // Close the path so the marquee preview draws all 4 edges
                    // of the quad. Lasso traces its own closing edge naturally.
                    p.closeSubpath()
                }
                .stroke(Color.blue, lineWidth: 2)
                .allowsHitTesting(false)
                .ignoresSafeArea()
            }

            // Marching ants selection overlay (after selection is made)
            if let selection = canvasState.activeSelection {
                // Transform selection from document space to screen space
                let screenSelection = canvasState.documentRectToScreen(selection)
                MarchingAntsRectangle(rect: screenSelection)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }

            // Paint-bucket flood fill HUD. Shown over the canvas while the
            // background fill is running; blocks input as a belt-and-
            // suspenders alongside the isFilling re-entrancy guard in
            // MetalCanvasView.touchesBegan. Indeterminate spinner — fill
            // duration on a 4096² canvas is sub-second on iPad Pro.
            if canvasState.isFilling {
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                        Text("Filling…")
                            .font(.subheadline)
                            .foregroundColor(.white)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                }
                .transition(.opacity)
            }

            // Canvas transform indicators (top-right) — zoom % moved into the
            // floating toolbar (Apr 16) so it's no longer hidden behind the
            // gallery button. Rotation indicator stays here.
            VStack(alignment: .trailing, spacing: 4) {
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
            }
            .padding(.top, 8)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .allowsHitTesting(false)

            // Layer indicator — pinned to the bottom center of the screen so
            // it's always visible regardless of which gallery/panels are open.
            // SwiftUI alignment + safe-area padding handles iPad orientation
            // changes automatically (portrait ↔ landscape reflow).
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.caption2)
                Text(canvasState.layers[safe: canvasState.selectedLayerIndex]?.name ?? "Layer")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)
            .cornerRadius(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 12)
            .allowsHitTesting(false)

            if let path = canvasState.selectionPath {
                // Transform path from document space to screen space
                let screenPath = canvasState.documentPathToScreen(path)
                MarchingAntsPath(path: screenPath)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }

            // Symmetry guides — dashed reference lines for the active
            // mirror mode. Static (not animated; marching ants is for
            // selection feedback, guides are persistent). Coordinate
            // pattern matches MarchingAntsPath: doc-space endpoints
            // mapped through canvasState.documentToScreen so the guides
            // rotate / zoom / pan with the canvas. allowsHitTesting(false)
            // is baked into the overlay; ignoresSafeArea handled here so
            // the canvas's full-bleed layout matches.
            SymmetryGuideOverlay(canvasState: canvasState, symmetry: symmetry)
                .ignoresSafeArea()

            // Free-transform handles for the active floating selection
            // (rect/lasso/import). Sits above the marching ants overlays so
            // the handles aren't obscured by the marquee. Hit tests are
            // scoped to the handles themselves; the rest of the overlay's
            // frame is transparent and lets touches fall through to MTKView.
            TransformHandlesOverlay(canvasState: canvasState)
                .ignoresSafeArea()

            // Cancel pill — top-center, only visible while a floating
            // selection exists. Tap-outside / tool-change confirm; this is
            // the only revert path.
            if canvasState.floatingSelectionTexture != nil {
                VStack {
                    HStack {
                        Spacer()
                        TransformCancelPill(canvasState: canvasState)
                        Spacer()
                    }
                    .padding(.top, 60) // below the existing Delete button slot
                    Spacer()
                }
                .ignoresSafeArea()
            }

            blurAdjustmentHUDOverlay

            stampCursorOverlay

            // Delete button for active selection (rect or lasso)
            if canvasState.activeSelection != nil || canvasState.selectionPath != nil {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: {
                            canvasState.deleteSelectedPixels()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                Text("Delete")
                            }
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.red)
                            .cornerRadius(10)
                            .shadow(radius: 3)
                        }
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.top, 12)
                .allowsHitTesting(true)
            }

            // Selection pixels are now rendered in real-time to the texture for fluent animation
            // The duplicate SwiftUI Image overlay is no longer needed

            // Floating toolbar overlay (top layer, left side)
            VStack(alignment: .leading, spacing: 0) {
                if !isToolbarCollapsed {
                    VStack(spacing: 0) {
                    ScrollView {
                        // Zoom % readout at the top of the toolbar (Apr 16).
                        // Always visible so the user can see the current zoom
                        // level without the gallery icon covering it. Tap to
                        // reset zoom/pan/rotation (matches the recenter button).
                        Button(action: { canvasState.resetAllTransforms() }) {
                            Text("\(Int(canvasState.zoomScale * 100))%")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .cornerRadius(6)
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 8)

                        LazyVGrid(columns: [GridItem(.fixed(44)), GridItem(.fixed(44))], spacing: 8) {
                            // Drawing tools
                            ToolButton(icon: DrawingTool.brush.icon, isSelected: canvasState.currentTool == .brush) {
                                canvasState.currentTool = .brush
                            }

                            ToolButton(icon: DrawingTool.eraser.icon, isSelected: canvasState.currentTool == .eraser) {
                                canvasState.currentTool = .eraser
                            }

                            // Blur Brush — paints Gaussian blur freeform
                            ToolButton(icon: DrawingTool.blur.icon, isSelected: canvasState.currentTool == .blur) {
                                canvasState.currentTool = .blur
                            }

                            // Blur Adjustment — Procreate-style scrubber HUD
                            ToolButton(icon: DrawingTool.blurAdjustment.icon, isSelected: canvasState.currentTool == .blurAdjustment) {
                                canvasState.currentTool = .blurAdjustment
                            }

                            // Smudge — stamp-as-you-go pickup/deposit smear
                            ToolButton(icon: DrawingTool.smudge.icon, isSelected: canvasState.currentTool == .smudge) {
                                canvasState.currentTool = .smudge
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

                            ToolButton(icon: DrawingTool.move.icon, isSelected: canvasState.currentTool == .move) {
                                canvasState.currentTool = .move
                            }

                            ToolButton(icon: DrawingTool.text.icon, isSelected: canvasState.currentTool == .text) {
                                canvasState.currentTool = .text
                            }

                            // Image import (Photos picker)
                            PhotosPicker(selection: $photoPickerItem, matching: .images) {
                                Image(systemName: "photo.badge.plus")
                                    .font(.system(size: 22))
                                    .frame(width: 44, height: 44)
                            }

                            // Download composited image to Photos
                            ToolButton(
                                icon: showPhotoSaveConfirmation ? "checkmark" : "arrow.down.to.line",
                                isSelected: false
                            ) {
                                Task { await downloadToPhotos() }
                            }
                            .disabled(isSavingToPhotos)

                            // Clear button
                            ToolButton(icon: "trash", isSelected: false) {
                                showClearConfirmation = true
                            }

                            // Color picker button. Grayed (not hidden) when
                            // blur, blurAdjustment, or smudge is the active
                            // tool — those tools don't read brush color.
                            Button(action: {
                                guard canvasState.currentTool != .blur,
                                      canvasState.currentTool != .blurAdjustment,
                                      canvasState.currentTool != .smudge else { return }
                                showColorPicker.toggle()
                            }) {
                                Circle()
                                    .fill(Color(canvasState.brushSettings.color))
                                    .frame(width: 40, height: 40)
                                    .overlay(Circle().stroke(Color.white, lineWidth: 3))
                                    .shadow(radius: 2)
                                    .opacity(
                                        (canvasState.currentTool == .blur ||
                                         canvasState.currentTool == .blurAdjustment ||
                                         canvasState.currentTool == .smudge) ? 0.4 : 1.0
                                    )
                            }
                            .disabled(canvasState.currentTool == .blur || canvasState.currentTool == .blurAdjustment || canvasState.currentTool == .smudge)

                            // Brush settings
                            ToolButton(icon: "slider.horizontal.3", isSelected: showBrushSettings) {
                                showBrushSettings.toggle()
                            }

                            // Layers
                            ToolButton(icon: "square.stack.3d.up", isSelected: showLayerPanel) {
                                showLayerPanel.toggle()
                            }

                            // Symmetry / mirror sub-nav. Selection state on the
                            // button reflects EITHER the sheet being open OR the
                            // mode being active, so the user can tell at a glance
                            // whether symmetry is on without opening the sheet.
                            ToolButton(
                                icon: "square.split.2x1",
                                isSelected: showSymmetrySettings || symmetry.mode != .off
                            ) {
                                showSymmetrySettings.toggle()
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

                            // Canvas flip — display-only mirrors around the
                            // viewport center. Layer textures unchanged. Used
                            // by artists to spot proportion errors the eye
                            // gets used to. isSelected reflects active flip
                            // state so the user can tell at a glance whether
                            // a flip is on without having to mentally check
                            // "is this canvas mirrored?" — same pattern as
                            // the Symmetry button.
                            ToolButton(
                                icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                                isSelected: canvasState.flipHorizontal
                            ) {
                                canvasState.toggleFlipHorizontal()
                            }
                            .help("Flip canvas horizontally")

                            ToolButton(
                                icon: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                                isSelected: canvasState.flipVertical
                            ) {
                                canvasState.toggleFlipVertical()
                            }
                            .help("Flip canvas vertically")

                            // Canvas Transform Controls
                            // Rotate L/R buttons removed Apr 16 — pinch-rotate
                            // covers the same case on device and these were
                            // toolbar clutter. Recenter button stays.
                            ToolButton(icon: "viewfinder", isSelected: false) {
                                canvasState.resetAllTransforms()
                            }
                            .help("Reset zoom, pan, rotation, and flips")
                            .disabled(canvasState.zoomScale == 1.0
                                      && canvasState.panOffset == .zero
                                      && canvasState.canvasRotation == .zero
                                      && !canvasState.flipHorizontal
                                      && !canvasState.flipVertical)

                            // AI Feedback button
                            ToolButton(icon: "sparkles", isSelected: showFeedback) {
                                if canvasState.feedback != nil {
                                    // Toggle the panel visibility
                                    showFeedback.toggle()
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

                    if Self.showGlobeIcon {
                        Divider()
                        Button(action: {
                            // TODO: Wire to social features when implemented.
                        }) {
                            Image(systemName: "globe")
                                .font(.system(size: 44))
                                .foregroundColor(.primary)
                                .frame(width: 88, height: 88)
                        }
                        .accessibilityLabel("Social")
                    }
                    } // end inner VStack(spacing: 0); contents kept at original
                      // indent to avoid a re-indent churn diff for unrelated lines.
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

            // Top right - Gallery button (always visible) + gear icon
            // (visibility tied to toolbar collapse). The two share a VStack so
            // the gear sits flush below the gallery icon without magic-number
            // padding; only the gear has the move/opacity transition since the
            // gallery icon stays put.
            VStack {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Button(action: { showGallery = true }) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 32))
                                .foregroundColor(.accentColor)
                                .frame(width: 50, height: 50)
                                .background(Color(uiColor: .systemBackground).opacity(0.95))
                                .clipShape(Circle())
                                .shadow(radius: 4)
                        }

                        if !isToolbarCollapsed {
                            settingsGearButton
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                }
                Spacer()
            }

            // Bottom right - Action buttons (collapses with toolbar). Extracted
            // into a computed property because the inline expression pushed
            // the body past the Swift type-checker's tolerance once the gear
            // button landed in Phase 6.
            if !isToolbarCollapsed {
                bottomRightActionButtons
            }
        }
    }

    // MARK: - Blur Adjustment HUD overlay
    //
    // Extracted into a computed property to keep `body` under the Swift
    // type-checker's tolerance — same pattern as `bottomRightActionButtons`.

    @ViewBuilder
    private var blurAdjustmentHUDOverlay: some View {
        if canvasState.blurAdjustmentActive {
            VStack {
                HStack {
                    Spacer()
                    AdjustmentHUD(
                        label: "Blur",
                        valueText: "\(canvasState.blurAdjustmentPercent)%",
                        onCommit: { canvasState.commitBlurAdjustment() },
                        onCancel: { canvasState.cancelBlurAdjustment() }
                    )
                    .frame(maxWidth: 360)
                    Spacer()
                }
                .padding(.top, 12)
                .padding(.horizontal, 12)
                Spacer()
            }
            .ignoresSafeArea()
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Stamp cursor overlay (blur brush; smudge in PR 2)

    @ViewBuilder
    private var stampCursorOverlay: some View {
        if let cursorCenter = canvasState.stampCursorCenter,
           canvasState.stampCursorDiameter > 0 {
            ZStack {
                Circle()
                    .strokeBorder(Color.black.opacity(0.5), lineWidth: 1)
                    .frame(
                        width: canvasState.stampCursorDiameter + 1,
                        height: canvasState.stampCursorDiameter + 1
                    )
                Circle()
                    .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.25)
                    .frame(
                        width: canvasState.stampCursorDiameter,
                        height: canvasState.stampCursorDiameter
                    )
            }
            .position(cursorCenter)
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }

    // MARK: - Bottom-right action buttons (Phase 6 extraction)
    //
    // Pulled out of `body` because the inline expression (gear + Save +
    // Get Feedback all stacked with conditional ProgressView swaps) tipped
    // the Swift type-checker over its tolerance threshold once the gear
    // button was added. Each button is a separate small computed property
    // so future additions don't have to re-do this extraction.

    private var bottomRightActionButtons: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 12) {
                    saveToGalleryButton
                    getFeedbackButton
                }
                .padding(.trailing, 12)
                .padding(.bottom, 12)
            }
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var settingsGearButton: some View {
        Button(action: { showSettings = true }) {
            Image(systemName: "gearshape")
                .font(.system(size: 22))
                .foregroundColor(.primary)
                .frame(width: 44, height: 44)
                .background(Color(uiColor: .systemBackground).opacity(0.95))
                .clipShape(Circle())
                .shadow(radius: 4)
        }
        .accessibilityLabel("Settings")
    }

    private var saveToGalleryButton: some View {
        // First save (currentDrawingID == nil) opens the title-input alert.
        // Subsequent taps on an already-saved drawing skip the alert and
        // overwrite silently — the previously-entered title is reused.
        Button(action: {
            if currentDrawingID == nil {
                showSaveDialog = true
            } else {
                Task { await saveDrawing() }
            }
        }) {
            HStack(spacing: 8) {
                if isSaving {
                    ProgressView().tint(.white)
                } else if showSavedConfirmation {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18))
                    Text("Saved")
                        .font(.headline)
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
    }

    private var getFeedbackButton: some View {
        Button(action: requestFeedback) {
            HStack(spacing: 8) {
                if isRequestingFeedback {
                    ProgressView().tint(.white)
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
        print("  - Storage path: \(drawing.storagePath ?? "<layered/manifest-only>")")

        // Load feedback if exists (but keep panel collapsed - user can tap sparkles to view)
        if let feedback = drawing.feedback {
            canvasState.feedback = feedback
            // Don't auto-show panel - let user tap sparkles button to view
            print("  - Has feedback: YES (loaded, panel collapsed)")
        } else {
            print("  - Has feedback: NO")
        }

        // Load critique history
        critiqueHistory = drawing.critiqueHistory
        print("  - Critique history: \(critiqueHistory.count) entries")

        // Async-load the drawing from the cloud-aware storage manager.
        // ONLINELAYERSTORE.md §6.1: prefer the layered path; if the storage
        // manager reports no manifest (legacy flat drawing), fall back to
        // loadFullImage. The renderer must exist before we touch textures.
        Task {
            // Wait for the renderer to be initialized before loading layered
            // textures (loadLayered builds MTLTextures and needs it ready).
            var attempts = 0
            while canvasState.renderer == nil && attempts < 10 {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                attempts += 1
            }
            guard canvasState.renderer != nil else {
                print("❌ ERROR: Failed to load drawing - renderer not initialized after \(attempts) attempts")
                return
            }

            // Try layered first. nil means "legacy / no manifest" — fall through.
            let layered: LayeredDrawingPayload?
            do {
                layered = try await storageManager.loadLayeredDrawing(for: drawing.id)
            } catch {
                print("⚠️ loadLayeredDrawing threw \(error.localizedDescription) — falling back to flat composite")
                layered = nil
            }

            if let payload = layered {
                await MainActor.run {
                    let result = canvasState.loadLayered(payload)
                    switch result {
                    case .loaded:
                        print("✅ Successfully loaded layered drawing (\(payload.layerPNGs.count) layers)")
                    case .loadedWithIntegrityWarning(let missing):
                        print("⚠️ Loaded layered drawing with \(missing.count) damaged layer(s): ordinals \(missing) replaced with empty layers")
                    case .loadedWithSizeMismatch(let w, let h):
                        print("⚠️ Loaded layered drawing at saved document size \(w)×\(h); current canvas size differs")
                    case .formatTooNew(let saved, let supported):
                        print("❌ Layered manifest version \(saved) is newer than supported \(supported); please update")
                    }
                }
                return
            }

            // Legacy flat fallback — load the composite JPEG into a single layer.
            let imageData: Data?
            do {
                imageData = try await storageManager.loadFullImage(for: drawing.id)
            } catch {
                print("❌ ERROR: loadFullImage threw: \(error)")
                return
            }

            guard let bytes = imageData, let uiImage = UIImage(data: bytes) else {
                print("❌ ERROR: Failed to obtain image bytes for \(drawing.id)")
                return
            }
            print("  - UIImage loaded: \(uiImage.size), \(bytes.count) bytes")

            await MainActor.run {
                canvasState.loadImage(uiImage)
                print("✅ Successfully loaded existing drawing image onto canvas")
            }
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

        // Layered save path (ONLINELAYERSTORE.md §3, §8.2). The producer reads
        // every layer's MTLTexture back as a lossless RGBA PNG and bundles the
        // composite JPEG + thumbnail JPEG; the storage manager handles
        // ordinal/sha rewriting and the legacy → layered upgrade for drawings
        // that started life as a flat composite.
        let payloadDrawingID = currentDrawingID ?? UUID()
        guard let payload = canvasState.exportLayeredPayload(drawingID: payloadDrawingID) else {
            print("❌ ERROR: Failed to build layered payload from canvas state")
            isSaving = false
            return
        }

        print("  - Layered payload built: \(payload.layerPNGs.count) layer PNG(s), composite=\(payload.compositeJPEG?.count ?? 0) bytes, thumb=\(payload.thumbnailJPEG?.count ?? 0) bytes")

        var didSucceed = false
        do {
            if let drawingID = currentDrawingID {
                // Update existing drawing. Pass the canvas's local critique history
                // so the storage manager replaces (not appends to) the stored list.
                // The storage manager used to synthesize a new CritiqueEntry on every
                // save-with-feedback, which duplicated the list indefinitely.
                print("  - Updating existing drawing with ID: \(drawingID)")
                try await storageManager.updateLayeredDrawing(
                    id: drawingID,
                    title: drawingTitle,
                    payload: payload,
                    feedback: canvasState.feedback,
                    context: context,
                    critiqueHistory: critiqueHistory
                )
                print("✅ Drawing updated successfully!")
            } else {
                // Create new drawing. Include any critique entries the user already
                // accumulated in this session before the first save.
                print("  - Creating new drawing")
                let savedDrawing = try await storageManager.saveLayeredDrawing(
                    title: drawingTitle,
                    payload: payload,
                    feedback: canvasState.feedback,
                    context: context,
                    critiqueHistory: critiqueHistory
                )
                // IMPORTANT: Set the currentDrawingID so subsequent saves update instead of creating new
                currentDrawingID = savedDrawing.id
                isEditingExisting = true
                print("✅ Drawing saved successfully with ID: \(savedDrawing.id)")
                print("  - Future saves will UPDATE this drawing, not create new ones")
            }
            didSucceed = true
        } catch {
            print("❌ ERROR: Failed to save drawing: \(error)")
        }

        isSaving = false

        if didSucceed {
            showSavedConfirmation = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                showSavedConfirmation = false
            }
        }
    }

    @MainActor
    private func downloadToPhotos() async {
        guard !isSavingToPhotos else { return }
        guard let image = canvasState.exportImage() else {
            photoSaveError = "Couldn't render the drawing for export."
            return
        }
        isSavingToPhotos = true
        defer { isSavingToPhotos = false }
        do {
            try await PhotoLibrarySaver.save(image)
            showPhotoSaveConfirmation = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                showPhotoSaveConfirmation = false
            }
        } catch {
            photoSaveError = error.localizedDescription
        }
    }

    private func requestFeedback() {
        isRequestingFeedback = true

        Task {
            do {
                let drawingId = try await ensureDrawingPersistedToCloud()
                await canvasState.requestFeedback(for: context, drawingId: drawingId)
            } catch {
                print("❌ requestFeedback prerequisites failed: \(error.localizedDescription)")
                canvasState.errorMessage = error.localizedDescription
                canvasState.showError = true
            }
            isRequestingFeedback = false

            // Phase 5d: the Worker is the sole writer to critique_history in
            // the cloud. We append the server-returned entry to local state
            // for immediate display; the cloud row stays canonical on the
            // next gallery hydrate. Fall back to a synthesized entry if the
            // Worker response didn't include one (e.g. older deployment).
            if let feedback = canvasState.feedback {
                let critiqueEntry = canvasState.lastCritiqueEntry ?? CritiqueEntry(
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

    /// Phase 5b plumbing: every feedback request needs a drawing_id that
    /// already exists in the cloud `drawings` table for the current user.
    ///
    /// If the canvas is already tied to a saved drawing, just await any
    /// in-flight cloud upload and return its id. Otherwise auto-save with a
    /// generated timestamp title ("Sketch · Apr 29, 10:14 AM"), wait for the
    /// cloud upload to finish, and return the new id. Throws if cloud sync
    /// fails — caller should not proceed to the Worker call in that case.
    private func ensureDrawingPersistedToCloud() async throws -> UUID {
        if let id = currentDrawingID {
            try await storageManager.awaitCloudSync(for: id)
            return id
        }

        // Auto-save uses the layered path so the Worker's composite read and
        // the user's next manual save both find a layered row. The
        // composite.jpg sibling that saveLayeredDrawing writes is what the
        // Worker pulls via storage_path — the AI-feedback contract is
        // unchanged (ONLINELAYERSTORE.md §5.5).
        guard let payload = canvasState.exportLayeredPayload(drawingID: UUID()) else {
            throw OpenAIError.imageEncodingFailed
        }

        let title = Self.defaultSketchTitle(for: Date())
        if drawingTitle.isEmpty { drawingTitle = title }

        let saved = try await storageManager.saveLayeredDrawing(
            title: title,
            payload: payload,
            feedback: canvasState.feedback,
            context: context,
            critiqueHistory: critiqueHistory
        )
        currentDrawingID = saved.id
        isEditingExisting = true
        try await storageManager.awaitCloudSync(for: saved.id)
        return saved.id
    }

    private static let sketchTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    private static func defaultSketchTitle(for date: Date) -> String {
        "Sketch · \(sketchTitleFormatter.string(from: date))"
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
