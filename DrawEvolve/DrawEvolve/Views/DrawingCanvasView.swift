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

    // Pose-reference overlay state. Session-only (no persistence). Reads
    // from canvasState for geometry; never writes back. The detection
    // sheet is bound to `poseDetectionRequest` — `nil` = sheet closed,
    // `.hand`/`.body` = sheet open for that kind.
    @StateObject private var poseOverlayManager = PoseOverlayManager()
    @State private var poseDetectionRequest: PoseSkeletonKind?

    // Type session (Tier-1.4). The bar appears when the Type tool is
    // selected and persists until the user taps the checkmark or selects
    // another tool. Tier-1.4 dropped the More inspector; the checkmark
    // also no longer commits the float — it just stops the typing portion
    // of the session and hides the bar, leaving the float alive with its
    // existing transform handles. `typeBarSuspended` gates the bar after
    // a checkmark so it stays hidden until either the float commits (tap
    // outside in .text) or a brand-new float begins.
    @State private var typeBarSuspended = false
    @State private var previousNonTypeTool: DrawingTool = .brush

    // Path mode for the .textOnPath tool. Persisted across launches so
    // the user's last choice is the default next session. Toggled by
    // the top-center pill that's visible only while .textOnPath is the
    // active tool AND no float / preview is in progress.
    @AppStorage("typeOnPath.pathMode") private var typeOnPathPathModeRaw: String = TypeOnPathPathMode.freehand.rawValue
    private var typeOnPathPathMode: TypeOnPathPathMode {
        TypeOnPathPathMode(rawValue: typeOnPathPathModeRaw) ?? .freehand
    }

    // Toolbar collapse state
    @State private var isToolbarCollapsed = false

    // iPhone tool-panel expand state. Inverse default of iPad's
    // isToolbarCollapsed (false = collapsed) because iPhone has less
    // vertical space and benefits from collapse-by-default. Drives
    // phoneToolPanel visibility; never co-fires with isToolbarCollapsed
    // since they live in disjoint body branches (phoneBody vs padBody).
    @State private var isToolPanelExpanded = false

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
    /// Opt-in trigger for the beta-transparency notice. Was auto-presented
    /// on first launch via ContentView's cascade; replaced with a manual
    /// (!) info button below the gear — see `betaInfoButton` and the
    /// iPhone toolbar item near the settings gear.
    @State private var showBetaInfo = false
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
        .overlay(typingPathOverlay)
        .overlay(typeBarOverlay)
        .onChange(of: canvasState.currentTool) { newTool in
            // Capture the last non-Type tool so future restoration knows
            // where to return. Re-entering a Type tool resets the bar's
            // suspended flag so a fresh tap on the canvas brings it back.
            if newTool != .text && newTool != .textOnPath {
                previousNonTypeTool = newTool
            } else {
                typeBarSuspended = false
            }
        }
        .onChange(of: canvasState.floatingText == nil) { isNil in
            // Brand-new float created → bar should re-show on next render.
            // (Going to nil means tap-outside committed; suspended flag
            // doesn't need a reset there because the bar is already
            // hidden by `shouldShowTypeBar`'s float check on `.textOnPath`
            // and a fresh `.text` tap will create a new float and trigger
            // this same handler with `isNil == false`.)
            if !isNil {
                typeBarSuspended = false
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
                    onDeleteLayer: { index in canvasState.deleteLayer(at: index) },
                    onMoveLayer: { from, to in canvasState.moveLayer(from: from, to: to) },
                    onBeginOpacityDrag: { index in canvasState.beginOpacityDrag(forLayerAt: index) },
                    onEndOpacityDrag: { index in canvasState.endOpacityDrag(forLayerAt: index) },
                    onBeginRename: { index in canvasState.beginLayerRename(forLayerAt: index) },
                    onCommitRename: { index in canvasState.commitLayerRename(forLayerAt: index) },
                    poseManager: poseOverlayManager
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
        .sheet(item: $poseDetectionRequest) { kind in
            PoseDetectionSheet(
                kind: kind,
                poseManager: poseOverlayManager,
                canvasState: canvasState
            )
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
        // Tier-1.4: the More-button half-sheet (italic, kerning kind,
        // manual kern, on-path toggles) was retired alongside the bar's
        // More button. If those controls return they'll mount through a
        // different surface; for now they're simply unreachable from the
        // bar — TypeInspectorView.swift remains in the project for that
        // future re-wiring.
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
        .sheet(isPresented: $showBetaInfo) {
            BetaTransparencyPopup(isPresented: $showBetaInfo)
        }
        .alert("Feedback Error", isPresented: $canvasState.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(canvasState.errorMessage)
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
                        canvasState.beginText(at: location, content: "")
                    },
                    symmetry: symmetry
                )
                .ignoresSafeArea()
                .background(Color(uiColor: .systemGray6))

                TextEntryOverlay(canvasState: canvasState)
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showBetaInfo = true }) {
                        Image(systemName: "exclamationmark.circle")
                    }
                    .accessibilityLabel("Beta information")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    phoneSelectionContextBar
                    phoneActionRow
                    if isToolPanelExpanded {
                        phoneToolPanel
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 4)
                .background(.regularMaterial)
            }
            // iPhone Phase 4: half-sheet for FloatingFeedbackPanel.
            // iPad's path renders the panel inline inside padBody's ZStack
            // (the existing `if showFeedback, canvasState.feedback != nil
            // { FloatingFeedbackPanel(...) }` block), so this .sheet lives
            // here in phoneBody and only fires on iPhone — no double
            // presentation, no state duplication. Detents .medium and
            // .large are the iOS-standard half-sheet sizes.
            //
            // Idiom-specific presentation modifiers attach inside the
            // idiom body (here), not on the outer Group from Phase 2.
            // Phase 2's modifier lift was for shared modifiers (sheets /
            // alerts / fullScreenCover that fire identically on both
            // idioms); idiom-specific presentations stay inside the
            // relevant idiom body.
            .sheet(isPresented: $showFeedback) {
                if canvasState.feedback != nil {
                    FloatingFeedbackPanel(
                        feedback: canvasState.feedback,
                        critiqueHistory: critiqueHistory,
                        isPresented: $showFeedback
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            }
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
                    // Tier-1 inline input: begin a FloatingText with empty
                    // content; the TextEntryOverlay rises immediately and
                    // every keystroke flows through setFloatingTextContent.
                    canvasState.beginText(at: location, content: "")
                },
                onTextOnPathRequest: { rawPoints, firstScreen, lastScreen in
                    canvasState.beginTextOnPath(
                        rawPoints: rawPoints,
                        firstScreen: firstScreen,
                        lastScreen: lastScreen,
                        content: ""
                    )
                },
                onTextOnPathCircleRequest: { center, radius in
                    canvasState.beginTextOnPathCircle(
                        center: center,
                        radius: radius,
                        content: ""
                    )
                },
                typeOnPathMode: typeOnPathPathMode,
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

            // Pose-reference skeleton(s). Sibling to TransformHandlesOverlay
            // (Decision 4 — no Metal layer, no DrawingLayer subtype).
            PoseOverlayView(poseManager: poseOverlayManager, canvasState: canvasState)
                .ignoresSafeArea()

            // Whole-skeleton transform handles (PR 4). Renders dashed
            // bbox + corner / edge / rotation handles when the
            // skeleton's bbox is armed; auto-deselects after 4s.
            // Above the joint dots in Z so handle hit zones can compete
            // when they overlap with extremity joints.
            PoseTransformHandlesView(poseManager: poseOverlayManager, canvasState: canvasState)
                .ignoresSafeArea()

            // Floating chip per active skeleton — chevron menu with
            // Replace Photo / Commit / Hide-or-Show / Manually Place /
            // Discard. PR 6.
            PoseSkeletonChipsOverlay(
                poseManager: poseOverlayManager,
                canvasState: canvasState,
                onRequestReplace: { kind in poseDetectionRequest = kind },
                onRequestManualPlace: { kind in
                    poseOverlayManager.placeDefault(kind: kind, canvasSize: canvasState.documentSize)
                }
            )
            .ignoresSafeArea()

            // Low-confidence banner (top of canvas, 5s auto-dismiss).
            // Slides down on detection-place when joints fall below
            // PoseConfidence.lowThreshold; user can tap X to dismiss.
            PoseLowConfidenceBanner(poseManager: poseOverlayManager)
                .ignoresSafeArea()

            pathStartHandleOverlay
            textOnPathPreviewOverlay
            textOnPathCirclePreviewOverlay
            typeOnPathModeTogglePill
            cancelPillOverlay
            TextEntryOverlay(canvasState: canvasState)

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

                        // Tool slots — 9 cells, 4 rows of 2 + 1 cell. Six
                        // grouped (Effects, Sample, Shapes, Select, Text,
                        // Pose Reference) reveal a long-press popover for
                        // variant selection; the other three (Brush,
                        // Eraser, Move) are single-tool slots. The 9th
                        // cell (Pose Reference) sits in row-5-left,
                        // pushing the first non-tool middle item (Clear
                        // / trash) to row-5-right and reflowing the rest
                        // by one cell. Below the tool slots sit the 10
                        // non-tool middle items in their pre-refactor
                        // relative order. Import/Export and Undo/Redo
                        // are pinned OUTSIDE this ScrollView, just above
                        // the existing Globe block (see below).
                        //
                        // NOTE: this iPad layout intentionally diverges
                        // from the iPhone phoneToolPanel grid. The
                        // tile-mirroring comment on phoneToolPanel is
                        // therefore stale by design for v1.1+.
                        LazyVGrid(columns: [GridItem(.fixed(44)), GridItem(.fixed(44))], spacing: 8) {
                            // Row 1: Brush, Eraser
                            ToolButton(icon: DrawingTool.brush.icon, isSelected: canvasState.currentTool == .brush) {
                                canvasState.currentTool = .brush
                            }

                            ToolButton(icon: DrawingTool.eraser.icon, isSelected: canvasState.currentTool == .eraser) {
                                canvasState.currentTool = .eraser
                            }

                            // Row 2: Effects (smudge / blur / blur adjustment), Sample (eyedropper / paint bucket)
                            GroupedToolButton(
                                group: .effects,
                                isSelected: { v in
                                    if case .tool(let t) = v {
                                        return canvasState.currentTool == t
                                    }
                                    return false
                                },
                                onActivate: { v in
                                    if case .tool(let t) = v {
                                        canvasState.currentTool = t
                                    }
                                }
                            )

                            GroupedToolButton(
                                group: .sample,
                                isSelected: { v in
                                    if case .tool(let t) = v {
                                        return canvasState.currentTool == t
                                    }
                                    return false
                                },
                                onActivate: { v in
                                    if case .tool(let t) = v {
                                        canvasState.currentTool = t
                                    }
                                }
                            )

                            // Row 3: Shapes (line / rectangle / circle), Select (rectangle / lasso)
                            GroupedToolButton(
                                group: .shapes,
                                isSelected: { v in
                                    if case .tool(let t) = v {
                                        return canvasState.currentTool == t
                                    }
                                    return false
                                },
                                onActivate: { v in
                                    if case .tool(let t) = v {
                                        canvasState.currentTool = t
                                    }
                                }
                            )

                            GroupedToolButton(
                                group: .select,
                                isSelected: { v in
                                    if case .tool(let t) = v {
                                        return canvasState.currentTool == t
                                    }
                                    return false
                                },
                                onActivate: { v in
                                    if case .tool(let t) = v {
                                        canvasState.currentTool = t
                                    }
                                }
                            )

                            // Row 4: Text (text / text-on-path), Move
                            //
                            // The settings opener variant retired in the
                            // Tier-1 type-tools overhaul — settings are now
                            // an inline inspector that auto-presents while
                            // a floating text is active.
                            GroupedToolButton(
                                group: .text,
                                isSelected: { v in
                                    switch v {
                                    case .tool(let t): return canvasState.currentTool == t
                                    }
                                },
                                onActivate: { v in
                                    switch v {
                                    case .tool(let t):
                                        canvasState.currentTool = t
                                    }
                                }
                            )

                            ToolButton(icon: DrawingTool.move.icon, isSelected: canvasState.currentTool == .move) {
                                canvasState.currentTool = .move
                            }

                            // Row 5 left — Pose Reference (9th tool slot).
                            // Wrapper handles the Decision-7 tap cycle so
                            // GroupedToolButton stays pose-agnostic.
                            PoseReferenceSlot(
                                poseManager: poseOverlayManager,
                                onRequestDetection: { kind in
                                    poseDetectionRequest = kind
                                }
                            )

                            // Middle items — non-tool entries in their
                            // pre-refactor relative order. Behavior
                            // unchanged.

                            // Clear button
                            ToolButton(icon: "trash", isSelected: false) {
                                showClearConfirmation = true
                            }

                            // Color picker swatch. Grayed (not hidden) when
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

                    // Pinned bottom — Import/Export above Undo/Redo, both
                    // above the existing Globe block. These sit OUTSIDE
                    // the ScrollView so they remain anchored regardless
                    // of toolbar scroll position. Behavior of each entry
                    // is unchanged from when they lived inside the grid.
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
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
                        }

                        HStack(spacing: 8) {
                            ToolButton(icon: "arrow.uturn.backward", isSelected: false) {
                                canvasState.undo()
                            }
                            .disabled(!canvasState.historyManager.canUndo)

                            ToolButton(icon: "arrow.uturn.forward", isSelected: false) {
                                canvasState.redo()
                            }
                            .disabled(!canvasState.historyManager.canRedo)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)

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

            // Selection actions overlay — iPad positioning. The card
            // content (caption + Cancel + Delete pills) lives in the
            // shared `selectionActiveCard` computed property; only the
            // outer VStack/Spacer/HStack/Spacer + bottom-200 positioning
            // is iPad-specific. Same justified-deviation pattern as
            // Phase 4's critiqueContent extraction.
            if canvasState.activeSelection != nil || canvasState.selectionPath != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        selectionActiveCard
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
                            betaInfoButton
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
        // Note: sheets / alerts / fullScreenCover / onChange / onAppear /
        // preferredColorScheme modifiers used to live here on the ZStack;
        // PR #33 (iPhone Phase 2 / C1) lifted them onto the outer Group
        // wrapper in `body` so phoneBody and padBody share them. Don't
        // re-add them here — they'd double-fire.
    }

    // MARK: - Type Bar overlay (Tier 1.4)
    //
    // The bar is the Type tool's session controller. It appears whenever
    // the user is in a Type session — `.text` selected, OR `.textOnPath`
    // with a path-bearing FloatingText already on canvas — AND
    // `typeBarSuspended` is false (set true by the checkmark to hide the
    // bar without ending the float). The GeometryReader provides
    // screen-space bounds for drag-clamping and the default first-launch
    // position.

    @ViewBuilder
    private var typeBarOverlay: some View {
        GeometryReader { geo in
            if shouldShowTypeBar {
                TypeBarView(
                    settings: $canvasState.textSettings,
                    canvasState: canvasState,
                    canvasSize: geo.size,
                    onCheckmark: { handleTypeCheckmark() }
                )
            }
        }
        .ignoresSafeArea(.keyboard)
    }

    private var shouldShowTypeBar: Bool {
        guard !typeBarSuspended else { return false }
        switch canvasState.currentTool {
        case .text:
            return true
        case .textOnPath:
            return canvasState.floatingText?.path != nil
        default:
            return false
        }
    }

    // MARK: - Path overlay during Type session (Tier 1.4)
    //
    // While the user is in an active typing session on a path-bearing
    // float, render the smoothed path as a faint gray polyline so the
    // user sees the curve their text is following. The overlay vanishes
    // when the user taps the bar's checkmark (which sets
    // `typeBarSuspended` and hides the path) or when the float commits.

    @ViewBuilder
    private var typingPathOverlay: some View {
        if !typeBarSuspended,
           let ft = canvasState.floatingText,
           let cgPath = ft.path {
            Path { p in
                cgPath.applyWithBlock { elPtr in
                    let el = elPtr.pointee
                    switch el.type {
                    case .moveToPoint:
                        p.move(to: canvasState.documentToScreen(el.points[0]))
                    case .addLineToPoint:
                        p.addLine(to: canvasState.documentToScreen(el.points[0]))
                    default:
                        break
                    }
                }
            }
            .stroke(Color.gray.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }

    /// End the typing portion of the Type session. Tier-1.4 keeps the
    /// float alive so the user can drag / scale / rotate via the existing
    /// transform handles; the actual commit-into-layer happens later when
    /// the user taps outside (existing .text-tool behavior). Path
    /// overlay disappears via the same `typeBarSuspended` flag.
    private func handleTypeCheckmark() {
        // Empty float → no point keeping a zero-glyph float around. Treat
        // checkmark on an empty float as a quiet cancel.
        if let ft = canvasState.floatingText, ft.content.isEmpty {
            canvasState.cancelFloatingText()
            canvasState.currentTool = previousNonTypeTool
            return
        }
        // Dismiss the soft keyboard (if any) by resigning the current
        // first responder app-wide. The TextEntryOverlay's UITextView
        // receives the resign and the keyboard slides down. The float
        // itself remains alive — `floatingText` is unchanged.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        typeBarSuspended = true
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

    // MARK: - Type-on-path overlays (Phase 3 extraction)
    //
    // Same rationale as the bottom-right buttons above: these three
    // siblings tipped the body's type-checker over its threshold (10+
    // SwiftUI sub-views with conditionals). Each as its own computed
    // property so the heuristic stays happy.

    private var pathStartHandleOverlay: some View {
        // PathStartHandle internally gates on `floatingText.path != nil`,
        // so it's safe to mount unconditionally here.
        PathStartHandle(canvasState: canvasState)
            .ignoresSafeArea()
    }

    @ViewBuilder
    private var textOnPathPreviewOverlay: some View {
        if let pts = canvasState.previewTextOnPathPoints, pts.count >= 2 {
            Path { p in
                p.move(to: canvasState.documentToScreen(pts[0]))
                for pt in pts.dropFirst() {
                    p.addLine(to: canvasState.documentToScreen(pt))
                }
            }
            .stroke(Color.gray.opacity(0.55), lineWidth: 1.5)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    /// Live circle outline shown while the user is dragging in
    /// type-on-path circle mode. Same gray-stroke styling as the
    /// freehand preview so the user sees a consistent path-in-progress
    /// affordance.
    @ViewBuilder
    private var textOnPathCirclePreviewOverlay: some View {
        if let preview = canvasState.previewTextOnPathCircle, preview.radius >= 1 {
            let centerScreen = canvasState.documentToScreen(preview.center)
            // Convert doc-space radius to screen via the existing
            // doc→screen helper. Compute it as the screen distance
            // between the doc-space center and a doc-space point at
            // (center.x + radius, center.y) — matches whatever pan /
            // zoom transforms the canvas applies.
            let edgeScreen = canvasState.documentToScreen(
                CGPoint(x: preview.center.x + preview.radius, y: preview.center.y)
            )
            let screenRadius = hypot(edgeScreen.x - centerScreen.x, edgeScreen.y - centerScreen.y)
            Path { p in
                p.addEllipse(in: CGRect(
                    x: centerScreen.x - screenRadius,
                    y: centerScreen.y - screenRadius,
                    width: 2 * screenRadius,
                    height: 2 * screenRadius
                ))
            }
            .stroke(Color.gray.opacity(0.55), lineWidth: 1.5)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    /// Top-center capsule pill that toggles the .textOnPath input mode
    /// between Freehand and Circle. Visible only when the user has the
    /// Type-on-Path tool selected, no float is currently active, and no
    /// path-drawing preview is in progress (the pill vanishes the
    /// moment the user begins dragging).
    @ViewBuilder
    private var typeOnPathModeTogglePill: some View {
        if canvasState.currentTool == .textOnPath
            && canvasState.floatingText == nil
            && canvasState.previewTextOnPathPoints == nil
            && canvasState.previewTextOnPathCircle == nil {
            VStack {
                HStack {
                    Spacer()
                    HStack(spacing: 0) {
                        modeSegment(.freehand, label: "Freehand")
                        modeSegment(.circle,   label: "Circle")
                    }
                    .background(Color.black.opacity(0.75))
                    .clipShape(Capsule())
                    .shadow(radius: 3)
                    Spacer()
                }
                .padding(.top, 60)
                Spacer()
            }
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    /// One segment of the toggle pill. Selected segment darkens; tapping
    /// an unselected segment switches the mode (writes through the
    /// `@AppStorage`-backed `typeOnPathPathModeRaw`).
    @ViewBuilder
    private func modeSegment(_ mode: TypeOnPathPathMode, label: String) -> some View {
        let isSelected = typeOnPathPathMode == mode
        Button {
            typeOnPathPathModeRaw = mode.rawValue
        } label: {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.white.opacity(0.22) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cancelPillOverlay: some View {
        // Top-center pill, visible while a floating selection OR a floating
        // text exists. The pill internally routes to the right cancel.
        if canvasState.floatingSelectionTexture != nil || canvasState.floatingText != nil {
            VStack {
                HStack {
                    Spacer()
                    TransformCancelPill(canvasState: canvasState)
                    Spacer()
                }
                .padding(.top, 60)
                Spacer()
            }
            .ignoresSafeArea()
        }
    }

    private var bottomRightActionButtons: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 12) {
                    // Procreate-style brush size rail. Sits above the
                    // action buttons and collapses with the rest of the
                    // tool chrome when the toolbar is hidden — same gate
                    // as `settingsGearButton` / `betaInfoButton`.
                    if !isToolbarCollapsed {
                        BrushSizeRail(size: $canvasState.brushSettings.size)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
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

    /// Opt-in trigger for the beta-transparency notice. Sits under the
    /// settings gear in the floating chrome so the same place that
    /// houses meta-info (settings) also surfaces meta-info (beta state).
    /// The popup itself is presented via the `.sheet(isPresented:
    /// $showBetaInfo)` binding on the body.
    private var betaInfoButton: some View {
        Button(action: { showBetaInfo = true }) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 22))
                .foregroundColor(.primary)
                .frame(width: 44, height: 44)
                .background(Color(uiColor: .systemBackground).opacity(0.95))
                .clipShape(Circle())
                .shadow(radius: 4)
        }
        .accessibilityLabel("Beta information")
    }

    // saveToGalleryButton and getFeedbackButton scale themselves down on
    // iPhone via internal DeviceIdiom branches. Padding, icon size, font,
    // corner radius, and shadow all shrink — but the disabled state
    // bindings, "Saved ✓" confirmation logic, and ProgressView-while-
    // loading branches stay in one place across both idioms. This is
    // a deliberate, contained deviation from "wholesale-quoted padBody"
    // — same justification class as Phase 4's critiqueContent extraction:
    // shared elements that need idiom-specific tuning belong in one
    // computed property to prevent functional drift between idioms.

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
                        .font(.system(size: actionButtonIconSize))
                    Text("Saved")
                        .font(actionButtonFont)
                } else {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: actionButtonIconSize))
                    Text("Save to Gallery")
                        .font(actionButtonFont)
                }
            }
            .padding(.horizontal, actionButtonHPadding)
            .padding(.vertical, actionButtonVPadding)
            .background(Color.green)
            .foregroundColor(.white)
            .cornerRadius(actionButtonCornerRadius)
            .shadow(radius: actionButtonShadow)
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
                        .font(.system(size: actionButtonIconSize))
                    Text("Get Feedback")
                        .font(actionButtonFont)
                }
            }
            .padding(.horizontal, actionButtonHPadding)
            .padding(.vertical, actionButtonVPadding)
            .background(Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(actionButtonCornerRadius)
            .shadow(radius: actionButtonShadow)
        }
        .disabled(isRequestingFeedback || canvasState.isEmpty)
        .opacity(canvasState.isEmpty ? 0.5 : 1.0)
    }

    // MARK: - Action-button sizing tokens (idiom-branched)
    //
    // iPhone values per the toolbar-redesign spec: ~13pt font, ~8pt
    // vertical padding, frame proportionally shrunk. iPad values are
    // the pre-redesign defaults, byte-preserved.

    private var actionButtonHPadding: CGFloat {
        DeviceIdiom.isPhone ? 12 : 20
    }
    private var actionButtonVPadding: CGFloat {
        DeviceIdiom.isPhone ? 8 : 14
    }
    private var actionButtonIconSize: CGFloat {
        DeviceIdiom.isPhone ? 14 : 18
    }
    private var actionButtonFont: Font {
        DeviceIdiom.isPhone
            ? .system(size: 13, weight: .semibold)
            : .headline
    }
    private var actionButtonCornerRadius: CGFloat {
        DeviceIdiom.isPhone ? 10 : 12
    }
    private var actionButtonShadow: CGFloat {
        DeviceIdiom.isPhone ? 2 : 4
    }

    // MARK: - Selection-active card (shared, idiom-positioned)
    //
    // Card content (caption + Cancel + Delete pill row) shared between
    // iPad's floating overlay (positioned via padding(.bottom, 200) over
    // the bottom-right action stack) and iPhone's bottom-inset stack
    // (positioned via VStack placement above phoneActionRow). Functional
    // behavior — clearSelection / deleteSelectedPixels button actions —
    // is identical across idioms; only outer positioning differs. Same
    // justified-deviation reasoning as Phase 4's critiqueContent
    // extraction: shared elements that need idiom-specific positioning
    // belong in one computed property to prevent functional drift.

    private var selectionActiveCard: some View {
        VStack(spacing: 12) {
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
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(radius: 5)
    }

    // MARK: - iPhone tool-panel chrome (collapsed-by-default)
    //
    // The bottom inset of phoneBody now stacks (top→bottom):
    //   1. phoneSelectionContextBar  — conditional, only when selection active
    //   2. phoneActionRow             — [tools trigger, Save flex, Feedback flex]
    //   3. phoneToolPanel             — conditional, only when expanded
    //
    // Trigger sits on the LEFT of the action row, showing the currently-
    // selected tool's icon. Tap toggles isToolPanelExpanded. Selecting
    // a tile in the expanded grid auto-collapses the panel. Spring
    // animation matches iPad's chevron-collapse profile.
    //
    // Tool grid lives in C2 of this PR — `phoneToolPanel` returns
    // EmptyView in C1 so the state machine + collapsed layout can land
    // and verify cleanly before the 28-tile grid stacks on top.

    private var phoneSelectionContextBar: some View {
        Group {
            if canvasState.activeSelection != nil || canvasState.selectionPath != nil {
                selectionActiveCard
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var phoneActionRow: some View {
        HStack(spacing: 8) {
            phoneToolsTrigger
            saveToGalleryButton
                .frame(maxWidth: .infinity)
            getFeedbackButton
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
    }

    private var phoneToolsTrigger: some View {
        // Selected-tool-icon variant (per locked spec): the trigger shows
        // the currently-selected tool's icon, both indicating active
        // tool and inviting expansion. Visually distinct from the action
        // pills (Circle vs. RoundedRect, .regularMaterial vs. solid
        // brand color) so it doesn't read as a third primary action.
        Button(action: {
            withAnimation(.spring(response: 0.3)) {
                isToolPanelExpanded.toggle()
            }
        }) {
            ZStack {
                Circle()
                    .fill(isToolPanelExpanded
                          ? Color.accentColor.opacity(0.18)
                          : Color(uiColor: .secondarySystemBackground))
                    .overlay(
                        Circle().stroke(
                            isToolPanelExpanded
                                ? Color.accentColor
                                : Color.clear,
                            lineWidth: 2
                        )
                    )
                Image(systemName: canvasState.currentTool.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.primary)
            }
            .frame(width: 44, height: 44)
        }
        .accessibilityLabel(isToolPanelExpanded ? "Collapse tool panel" : "Expand tool panel")
    }

    // Helper for tile actions inside phoneToolPanel: every tile auto-
    // collapses the panel after firing, since once the user has picked
    // a tool / triggered a modifier they want to see the canvas. The
    // collapse animation matches the trigger button's spring profile.
    private func collapsePhoneToolPanel() {
        withAnimation(.spring(response: 0.3)) {
            isToolPanelExpanded = false
        }
    }

    private var phoneToolPanel: some View {
        // 30 tiles. 5 columns × 6 rows = 30 cells, all used. The two
        // pose-reference tiles (handPose / bodyPose) absorb the two
        // empty trailing slots that the v1.1 toolbar refactor reserved.
        // Each tile auto-collapses the panel via collapsePhoneToolPanel()
        // after firing.
        //
        // Tile bodies are duplicated rather than extracted-and-shared
        // because extracting would force a structural change to padBody's
        // LazyVGrid; the redesign only authorizes the action-button
        // sizing extraction and selectionActiveCard extraction. If a
        // tile is added / reordered / removed in padBody's LazyVGrid,
        // mirror the change here.
        //
        // ViewBuilder limit of 10 children in HStack/LazyVGrid is sided
        // around with Group{} chunks below — same pattern as other large
        // tile sets in this file.
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5),
            spacing: 12
        ) {
            Group {
                ToolButton(icon: DrawingTool.brush.icon, isSelected: canvasState.currentTool == .brush) {
                    canvasState.currentTool = .brush
                    collapsePhoneToolPanel()
                }
                ToolButton(icon: DrawingTool.eraser.icon, isSelected: canvasState.currentTool == .eraser) {
                    canvasState.currentTool = .eraser
                    collapsePhoneToolPanel()
                }
                ToolButton(icon: DrawingTool.blur.icon, isSelected: canvasState.currentTool == .blur) {
                    canvasState.currentTool = .blur
                    collapsePhoneToolPanel()
                }
                ToolButton(icon: DrawingTool.blurAdjustment.icon, isSelected: canvasState.currentTool == .blurAdjustment) {
                    canvasState.currentTool = .blurAdjustment
                    collapsePhoneToolPanel()
                }
                ToolButton(icon: DrawingTool.smudge.icon, isSelected: canvasState.currentTool == .smudge) {
                    canvasState.currentTool = .smudge
                    collapsePhoneToolPanel()
                }
                ToolButton(icon: DrawingTool.line.icon, isSelected: canvasState.currentTool == .line) {
                    canvasState.currentTool = .line
                    collapsePhoneToolPanel()
                }
                ToolButton(icon: DrawingTool.rectangle.icon, isSelected: canvasState.currentTool == .rectangle) {
                    canvasState.currentTool = .rectangle
                    collapsePhoneToolPanel()
                }
                ToolButton(icon: DrawingTool.circle.icon, isSelected: canvasState.currentTool == .circle) {
                    canvasState.currentTool = .circle
                    collapsePhoneToolPanel()
                }
                ToolButton(icon: DrawingTool.paintBucket.icon, isSelected: canvasState.currentTool == .paintBucket) {
                    canvasState.currentTool = .paintBucket
                    collapsePhoneToolPanel()
                }
                ToolButton(icon: DrawingTool.eyeDropper.icon, isSelected: canvasState.currentTool == .eyeDropper) {
                    canvasState.currentTool = .eyeDropper
                    collapsePhoneToolPanel()
                }
            }
            Group {
                ToolButton(icon: DrawingTool.rectangleSelect.icon, isSelected: canvasState.currentTool == .rectangleSelect) {
                    canvasState.currentTool = .rectangleSelect
                    collapsePhoneToolPanel()
                }
                ToolButton(icon: DrawingTool.lasso.icon, isSelected: canvasState.currentTool == .lasso) {
                    canvasState.currentTool = .lasso
                    collapsePhoneToolPanel()
                }
                ToolButton(icon: DrawingTool.move.icon, isSelected: canvasState.currentTool == .move) {
                    canvasState.currentTool = .move
                    collapsePhoneToolPanel()
                }
                ToolButton(icon: DrawingTool.text.icon, isSelected: canvasState.currentTool == .text) {
                    canvasState.currentTool = .text
                    collapsePhoneToolPanel()
                }
                // Pose-reference tiles. Each is its own ToolButton-styled
                // tile (no popover; iPhone is flat). Tap routes through
                // the same Decision-7 cycle used by the iPad slot.
                PoseReferenceTile(
                    tool: .handPose,
                    poseManager: poseOverlayManager,
                    onRequestDetection: { kind in poseDetectionRequest = kind },
                    onTapCompleted: { collapsePhoneToolPanel() }
                )
                PoseReferenceTile(
                    tool: .bodyPose,
                    poseManager: poseOverlayManager,
                    onRequestDetection: { kind in poseDetectionRequest = kind },
                    onTapCompleted: { collapsePhoneToolPanel() }
                )
            }
            // ViewBuilder caps each Group at 10 children. The second Group
            // hit that ceiling pre-pose; the two pose tiles above forced a
            // third Group split here so PhotosPicker..layerPanel can keep
            // their original tile sequence.
            Group {
                PhotosPicker(selection: $photoPickerItem, matching: .images) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 22))
                        .frame(width: 44, height: 44)
                }
                .onChange(of: photoPickerItem) { _, _ in
                    // Collapse on pick so the canvas is visible while
                    // the import sheet is being interacted with.
                    collapsePhoneToolPanel()
                }
                ToolButton(
                    icon: showPhotoSaveConfirmation ? "checkmark" : "arrow.down.to.line",
                    isSelected: false
                ) {
                    Task { await downloadToPhotos() }
                    collapsePhoneToolPanel()
                }
                .disabled(isSavingToPhotos)
                ToolButton(icon: "trash", isSelected: false) {
                    showClearConfirmation = true
                    collapsePhoneToolPanel()
                }
                Button(action: {
                    guard canvasState.currentTool != .blur,
                          canvasState.currentTool != .blurAdjustment,
                          canvasState.currentTool != .smudge else { return }
                    showColorPicker.toggle()
                    collapsePhoneToolPanel()
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
                ToolButton(icon: "slider.horizontal.3", isSelected: showBrushSettings) {
                    showBrushSettings.toggle()
                    collapsePhoneToolPanel()
                }
                ToolButton(icon: "square.stack.3d.up", isSelected: showLayerPanel) {
                    showLayerPanel.toggle()
                    collapsePhoneToolPanel()
                }
            }
            Group {
                ToolButton(
                    icon: "square.split.2x1",
                    isSelected: showSymmetrySettings || symmetry.mode != .off
                ) {
                    showSymmetrySettings.toggle()
                    collapsePhoneToolPanel()
                }
                ToolButton(
                    icon: userPreferredColorScheme == "dark" ? "sun.max.fill" : "moon.fill",
                    isSelected: false
                ) {
                    toggleColorScheme()
                    collapsePhoneToolPanel()
                }
                ToolButton(icon: "arrow.uturn.backward", isSelected: false) {
                    canvasState.undo()
                    collapsePhoneToolPanel()
                }
                .disabled(!canvasState.historyManager.canUndo)
                ToolButton(icon: "arrow.uturn.forward", isSelected: false) {
                    canvasState.redo()
                    collapsePhoneToolPanel()
                }
                .disabled(!canvasState.historyManager.canRedo)
                ToolButton(
                    icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                    isSelected: canvasState.flipHorizontal
                ) {
                    canvasState.toggleFlipHorizontal()
                    collapsePhoneToolPanel()
                }
                ToolButton(
                    icon: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                    isSelected: canvasState.flipVertical
                ) {
                    canvasState.toggleFlipVertical()
                    collapsePhoneToolPanel()
                }
                ToolButton(icon: "viewfinder", isSelected: false) {
                    canvasState.resetAllTransforms()
                    collapsePhoneToolPanel()
                }
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
                    collapsePhoneToolPanel()
                }
                .disabled(canvasState.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
