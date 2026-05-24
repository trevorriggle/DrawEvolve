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
    /// When true, the gallery fullScreenCover opens on first appear.
    /// Routed in by `LaunchHomeView`'s "Go to gallery" button so the
    /// user can browse straight through this view's existing sheet
    /// stack without making the canvas a transient destination.
    var openGalleryOnAppear: Bool = false
    /// When non-nil, the floating feedback panel opens on first appear
    /// with this critique entry pre-selected. Used by the studio-wall
    /// → canvas navigation path (commit 13) so tapping a critique row
    /// lands the user inside the drawing's canvas already looking at
    /// the right entry. Default nil (no preselection) covers all
    /// existing call sites unchanged.
    var preselectedCritique: CritiqueEntry? = nil

    // Canvas state
    @StateObject private var canvasState = CanvasStateManager()
    @State private var showFeedback = false

    // MARK: - Drawing version history phase 2 (canvas-overlay UX)

    /// True when the canvas is rendering a historical snapshot composite
    /// instead of the live drawing. Set by the FloatingFeedbackPanel
    /// onActiveEntryChange callback when the user selects an older
    /// critique. Drives both the SnapshotCanvasOverlay placement and the
    /// per-subview hiding of the editing UI.
    private var isViewingSnapshot: Bool { canvasState.viewingSnapshot != nil }

    /// Top-leading chrome rendered when the canvas is showing a historical
    /// snapshot. Two-zone toolbar:
    ///   - LEFT: explicit "Return to canvas" button (chevron + label) that
    ///           clears `viewingSnapshot`. Tester feedback (C3) — the
    ///           original chip was a single pill where tapping anywhere
    ///           exited snapshot mode; users didn't realize the whole pill
    ///           was tappable, so the exit affordance read as missing.
    ///   - CENTER: the snapshot timestamp as a static label pill. Not
    ///             interactive — its job is to confirm what the user is
    ///             looking at, not to be a tap target.
    /// No right-side element by design — an empty placeholder for symmetry
    /// would be a button-that-does-nothing, which is its own UX confusion.
    /// Asymmetric layout is honest about what each element does.
    @ViewBuilder
    private func snapshotChip(timestamp: Date) -> some View {
        HStack(spacing: 8) {
            Button {
                canvasState.viewingSnapshot = nil
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                    Text("Return to canvas")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Return to canvas")
            .accessibilityHint("Exits snapshot mode and returns to the live drawing")

            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                Text("Viewing snapshot from \(timestamp, format: .dateTime.month().day().hour().minute())")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .foregroundStyle(.primary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Viewing snapshot from \(timestamp.formatted(date: .abbreviated, time: .shortened))")
        }
        .padding(.top, 12)
        .padding(.leading, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    /// iPhone-only — surfaces the 6 brush variants (pencil/brush/inkPen/
    /// marker/airbrush/charcoal) in a sheet, since the flat iPhone tool
    /// grid has no room for the iPad's long-press popover. Triggered by
    /// the single brush tile in phoneToolPanel. iPad uses
    /// `ToolGroup.brushes` via `GroupedToolButton` instead — separate
    /// surface, separate code path.
    @State private var showPhoneBrushPicker = false
    /// iPhone-only — surfaces the two pose-reference variants
    /// (handPose / bodyPose) in a sheet, mirroring the brush picker
    /// pattern. iPad uses the long-press popover via
    /// `ToolGroup.poseReference`; iPhone consolidates the two pose
    /// tiles into one grid slot so the panel stays at one row per
    /// category instead of leaking pose into the "select / move /
    /// text" row.
    @State private var showPhonePosePicker = false
    /// iPhone-only — combines the two text tools (.text + .textOnPath
    /// in both freehand and circle sub-modes) under one grid slot.
    /// iPad surfaces .textOnPath via a separate tile and exposes its
    /// freehand/circle mode through the top-center toggle pill; on
    /// iPhone the pill's `.padding(.top, 60)` collides with the inline
    /// navigation bar, so the sub-mode lives in the picker sheet
    /// instead and the pill is intentionally not mounted in phoneBody.
    @State private var showPhoneTypePicker = false
    /// iPhone-only — combines the three effect tools (smudge / blur
    /// brush / blur adjustment) under one grid slot. Mirrors iPad's
    /// `ToolGroup.effects` long-press popover.
    @State private var showPhoneEffectsPicker = false
    @State private var isRequestingFeedback = false
    @State private var isEditingExisting = false
    @State private var currentDrawingID: UUID?

    // A1-build: critique request confirm sheet. Tapping the Get Feedback
    // button presents this sheet so the user can declare stage-of-work
    // before Eve runs. Reset to .inProgress on every open (per the
    // locked spec — never persisted across sessions or drawings).
    @State private var showCritiqueRequestSheet = false
    @State private var selectedStageOfWork: StageOfWork = .inProgress

    // MARK: - Auto-save state
    //
    // The first save still routes through saveToGalleryButton's title
    // alert (the user names the drawing). Once `currentDrawingID` is
    // set, a 30s timer flushes pending edits to the cloud — but ONLY
    // if a real mutation happened since the last save. The dirty flag
    // is driven by `canvasState.layerMutationCounter`, which gets
    // bumped from explicit commit points (stroke commit, flood fill,
    // text commit, selection delete, undo/redo, layer add/remove/
    // reorder). Viewport changes and transient drag state DON'T bump
    // it — saving every 30s regardless of edits would multiply our
    // Supabase egress by ~4x at no benefit.
    //
    // Reuses the existing `saveDrawing()` path so texture export,
    // NWPathMonitor retry queue, and Supabase upload semantics are
    // shared with the manual Save button. Auto-save is silent on
    // failure (queue retries); manual Save still surfaces errors.

    @State private var hasUnsavedEdits: Bool = false
    @State private var isAutoSaving: Bool = false
    @State private var showAutoSavedToast: Bool = false

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

    /// Captured at the moment the color picker sheet opens; restored to
    /// `canvasState.currentTool` on dismiss (Done, swipe-down, or any
    /// other path that flips `showColorPicker` back to false). Mirrors
    /// the `previousNonTypeTool` idiom — the picker is a non-tool sheet
    /// that shouldn't strand the user on a different tool after dismissal.
    @State private var previousNonColorPickerTool: DrawingTool = .brush

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

    // Eve coach sheet state. `showEve` toggles the iPad floating overlay /
    // iPhone sheet; `eveScope` + `eveCritiqueSequence` + `eveDrawingTitle`
    // configure the conversation being opened. Cleared between sessions so
    // closing the sheet and re-opening from a different entry point gets
    // a fresh scope. See Feature 2, Phase 2A in DrawEvolve-Three-Big-Features.md.
    @State private var showEve = false
    @State private var eveScope: EveScope = .general
    @State private var eveCritiqueSequence: Int? = nil
    @State private var eveDrawingTitle: String? = nil

    // Composition / "Eye Test" panel. Gated by the
    // `eye_test_panel` feature flag — both Eye Test flags default
    // off in the feature_flags table; the beta cohort gets the
    // panel flipped on first. The Eve integration flag stays off
    // until panel data justifies enabling it.
    //
    // Heatmap visibility resets to false on each panel open to keep
    // the lighter-weight markers-only mode as the default surface.
    @StateObject private var compositionAnalysisService = CompositionAnalysisService()
    @ObservedObject private var appFeatureFlags = AppFeatureFlags.shared
    @State private var showEyeTestPanel: Bool = false
    @State private var showEyeTestHeatmap: Bool = false
    /// Tap-to-mark-intent mode (M3). Engaged when the user taps
    /// "Mark intent" / "Re-mark intent" in EyeTestPanel — the panel
    /// dismisses, the active-mode banner appears at the top of the
    /// canvas ("Tap to mark your intended focal point. Tap Done to
    /// exit."), and a single tap on the canvas captures the
    /// normalized document coord as the new intent marker. The
    /// banner is non-optional per condition 3.
    @State private var isTapToMarkActive: Bool = false

    /// Apple Pencil hover point (iPadOS 16.1+, iPad Pro M2+ / Pencil
    /// 2/Pro). Set from MetalCanvasView's onHoverChange callback. Local
    /// @State (not @Published on canvasState) so 60-120Hz hover events
    /// only re-render the cursor overlay view, not the full DrawingCanvasView
    /// body. nil when no hover is active.
    @State private var hoverCursorPoint: CGPoint? = nil

    @ObservedObject private var storageManager = CloudDrawingStorageManager.shared

    // Clear confirmation
    @State private var showClearConfirmation = false

    // Image import — bifurcated into two flows behind one button.
    // "Import as Layer" preserves today's flow (image enters the layer
    // stack; AI-critique + export include it). "Add as Reference"
    // creates a session-only floating overlay (NEVER enters the layer
    // stack, automatically excluded from AI/export by construction).
    // The two paths share nothing above UIImage(data:) decoding.
    @StateObject private var referenceManager = ReferenceImageManager()
    @State private var showPhotoChoice = false
    @State private var showLayerPicker = false
    @State private var showReferencePicker = false
    @State private var layerPickerItem: PhotosPickerItem?
    @State private var referencePickerItem: PhotosPickerItem?

    // Image export (Photos save)
    @State private var isSavingToPhotos = false
    @State private var showPhotoSaveConfirmation = false
    @State private var photoSaveError: String?
    /// Routed separately from `photoSaveError` so the permission-denied
    /// case can present a Cancel / Open Settings two-button alert instead
    /// of the generic OK-only "couldn't save" alert. An OK-only dead-end
    /// when the system has nothing actionable to offer was the bug.
    @State private var showPhotoPermissionDeniedAlert = false

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
        .overlay(hoverCursorOverlay)
        .overlay(alignment: .top) {
            autoSaveStatusIndicator
                .allowsHitTesting(false)
        }
        // Dirty signal — `bumpLayerMutation()` increments
        // `layerMutationCounter` at every real pixel commit. Viewport
        // changes (pan / zoom / tool switch) DON'T bump it, so we
        // don't spuriously auto-save on navigation.
        .onChange(of: canvasState.layerMutationCounter) { _ in
            hasUnsavedEdits = true
        }
        // 30s polling tick. Cancelled when the view goes away. Sleep-
        // loop rather than Timer so we don't have to bridge a Combine
        // schedule onto the main actor for the autoSaveTick check.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await autoSaveTick()
            }
        }
        // Opening a different drawing — clear the dirty flag so stale
        // edits from the prior canvas don't trigger a save against
        // the new one.
        .onChange(of: currentDrawingID) { _ in
            hasUnsavedEdits = false
            showAutoSavedToast = false
        }
        .onChange(of: canvasState.currentTool) { newTool in
            // Capture the last non-Type tool so future restoration knows
            // where to return. Re-entering a Type tool resets the bar's
            // suspended flag so a fresh tap on the canvas brings it back.
            if newTool != .text && newTool != .textOnPath {
                previousNonTypeTool = newTool
            } else {
                typeBarSuspended = false
            }
            // Selecting the Text tool with no float in flight auto-creates
            // an empty placeholder at canvas center. The TextEntryOverlay
            // mounts immediately, raises the system keyboard, and the
            // FloatingTextCaretIndicator renders a blinking blue caret at
            // the anchor — so the user knows exactly where text will land
            // without having to tap first. textOnPath is excluded because
            // it requires the user to draw a path before any text exists.
            if newTool == .text && canvasState.floatingText == nil {
                let docSize = canvasState.documentSize
                canvasState.beginText(
                    at: CGPoint(x: docSize.width / 2, y: docSize.height / 2),
                    content: ""
                )
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
                AdvancedColorPicker(
                    selectedColor: $canvasState.brushSettings.color,
                    compositeImage: composeCanvasForPaletteGeneration
                )
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
        // Restore the pre-picker tool from a single observer regardless of
        // dismissal path — Done button, swipe-down, or any future tap-outside
        // wiring all funnel through `showColorPicker` flipping to false.
        .onChange(of: showColorPicker) { isShown in
            if !isShown {
                canvasState.currentTool = previousNonColorPickerTool
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
                    onToggleVisibility: { index in canvasState.toggleLayerVisibility(at: index) },
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
        // iPhone-only brush variant picker. iPad uses ToolGroup.brushes
        // (long-press popover); iPhone uses this sheet because the flat
        // tile grid has no room for a six-variant popover. The sheet
        // body itself doesn't care about idiom — it's just never
        // triggered on iPad (showPhoneBrushPicker is only flipped from
        // phoneToolPanel's brush tile).
        .sheet(isPresented: $showPhoneBrushPicker) {
            phoneBrushPickerSheet
        }
        // iPhone-only pose-reference picker. Same justification as the
        // brush picker — the flat tile grid has no surface for the
        // iPad long-press popover, so one consolidated slot opens a
        // sheet listing the two pose variants.
        .sheet(isPresented: $showPhonePosePicker) {
            phonePosePickerSheet
        }
        // iPhone-only type picker (plain text / type-on-path freehand /
        // type-on-path circle). iPad uses two separate tiles + the
        // floating mode-toggle pill; on iPhone the pill collides with
        // the nav bar, so sub-mode selection lives in the sheet.
        .sheet(isPresented: $showPhoneTypePicker) {
            phoneTypePickerSheet
        }
        // iPhone-only effects picker — mirrors iPad's ToolGroup.effects
        // long-press popover under a single grid slot.
        .sheet(isPresented: $showPhoneEffectsPicker) {
            phoneEffectsPickerSheet
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
        .sheet(isPresented: $showCritiqueRequestSheet) {
            critiqueRequestSheet
        }
        .sheet(isPresented: $showEyeTestPanel, onDismiss: { showEyeTestHeatmap = false }) {
            EyeTestPanel(
                service: compositionAnalysisService,
                canvasState: canvasState,
                showHeatmap: $showEyeTestHeatmap,
                intentMarker: currentDrawingIntentMarker,
                onMarkIntent: {
                    showEyeTestPanel = false
                    isTapToMarkActive = true
                },
                onClearIntent: {
                    Task { await clearIntentMarker() }
                },
                onAskEve: {
                    // M6 handoff: dismiss the panel and open Eve in
                    // `.drawing` scope so the conversation context is
                    // anchored to the current drawing. openEve always
                    // starts a fresh sheet — EveConversationManager
                    // creates a new conversation when none exists for
                    // (drawing, critique) — so this does not continue
                    // an existing thread, per condition 6 of the M6
                    // build plan.
                    showEyeTestPanel = false
                    openEve(scope: .drawing)
                },
                onClose: { showEyeTestPanel = false }
            )
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
        .alert(
            "Photos Access Needed",
            isPresented: $showPhotoPermissionDeniedAlert
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text("DrawEvolve needs permission to save to Photos. Enable it in Settings > Privacy & Security > Photos > DrawEvolve.")
        }
        .onChange(of: canvasState.currentTool) { _, _ in
            // When tool changes, commit any active selection
            if canvasState.selectionPixels != nil {
                canvasState.commitSelection()
            }
        }
        .confirmationDialog(
            "Add a photo",
            isPresented: $showPhotoChoice,
            titleVisibility: .visible,
        ) {
            Button("Import as Layer") { showLayerPicker = true }
            Button("Add as Reference") { showReferencePicker = true }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(
            isPresented: $showLayerPicker,
            selection: $layerPickerItem,
            matching: .images,
        )
        .photosPicker(
            isPresented: $showReferencePicker,
            selection: $referencePickerItem,
            matching: .images,
        )
        .onChange(of: layerPickerItem) { _, newItem in
            // "Import as Layer" path — unchanged behavior. Image enters
            // the layer stack and is included in AI critique and export.
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    await MainActor.run { canvasState.importImage(uiImage) }
                }
                await MainActor.run { layerPickerItem = nil }
            }
        }
        .onChange(of: referencePickerItem) { _, newItem in
            // "Add as Reference" path — image becomes a session-only
            // floating overlay. ReferenceImageManager lives outside the
            // layer stack, so this image NEVER enters AI critique or
            // export (see CanvasRenderer.compositeLayersToTexture).
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    await MainActor.run {
                        let viewport = canvasState.screenSize.width > 0
                            ? canvasState.screenSize
                            : UIScreen.main.bounds.size
                        referenceManager.add(uiImage, viewportSize: viewport)
                    }
                }
                await MainActor.run { referencePickerItem = nil }
            }
        }
        .onAppear {
            loadExistingDrawing()
            // LaunchHomeView "Go to gallery" routes through this view
            // so the gallery cover opens via the existing showGallery
            // state. One-shot — we don't re-open if the user dismisses,
            // so the canvas behaves normally on every subsequent appear.
            if openGalleryOnAppear && !showGallery {
                showGallery = true
            }
            // Studio-wall navigation (commit 13) sets preselectedCritique
            // to a specific entry; auto-open the floating feedback panel
            // so the user lands inside the canvas already looking at the
            // right critique. The panel's own initialSelectedEntryId
            // param drives the entry selection.
            if preselectedCritique != nil {
                showFeedback = true
            }
        }
        // Phase 2 snapshot mode — dismiss any open modal sheets when
        // entering snapshot mode so they don't float over the historical
        // composite. Sheets aren't hidden by ZStack conditionals; we have
        // to flip the underlying state bindings explicitly.
        .onChange(of: canvasState.viewingSnapshot) { _, newValue in
            guard newValue != nil else { return }
            showColorPicker = false
            showLayerPanel = false
            showBrushSettings = false
            showSymmetrySettings = false
            showEyeTestPanel = false
            showPhoneBrushPicker = false
            showPhonePosePicker = false
            showPhoneTypePicker = false
            showPhoneEffectsPicker = false
        }
        // Phase 2 snapshot mode — dismissing the feedback panel exits
        // snapshot mode immediately (per approved auto-clear rules).
        // Covers both the explicit X dismiss and the iPhone drag-down
        // half-sheet dismiss paths.
        .onChange(of: showFeedback) { _, newValue in
            if !newValue {
                canvasState.viewingSnapshot = nil
            }
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
                    symmetry: symmetry,
                    backCanvasReferences: referenceManager.references.filter { $0.isBehindCanvas },
                    onHoverChange: { hoverCursorPoint = $0 }
                )
                .ignoresSafeArea()
                .background(Color(uiColor: .systemGray6))
                // Reference images render above the canvas, below tool
                // chrome. NEVER enters the layer stack — see
                // CanvasRenderer.compositeLayersToTexture for the
                // architectural commitment.
                .overlay { referenceOverlay }
                // Composition / Eye Test markers + heatmap. Same
                // SwiftUI-overlay-never-in-composite pattern as
                // reference images. iPhone has no entry point in v1
                // (skip per condition 9 of the M2 build plan), but
                // attaching the overlay here is harmless when
                // showEyeTestPanel == false.
                .overlay { eyeTestOverlay }
                .overlay { tapToMarkCaptureOverlay }
                .overlay(alignment: .top) { tapToMarkBanner }

                // Phase 2 snapshot overlay — iPhone parity with padBody.
                // Same placement (above MetalCanvasView + its .overlay {}
                // chain), same hit-testing rule. Editing chrome below
                // hides via per-subview gates on !isViewingSnapshot.
                if let viewing = canvasState.viewingSnapshot {
                    SnapshotCanvasOverlay(viewing: viewing)
                        .allowsHitTesting(true)
                        .ignoresSafeArea()
                    snapshotChip(timestamp: viewing.timestamp)
                }

                // Selection overlays — parity with padBody. Without these
                // iPhone users got no rubber-band preview while dragging
                // a rectangle/lasso selection and no marching ants on the
                // finalized selection, which read as "the tool is broken
                // / takes forever." Geometry math is universal (reads from
                // shared canvasState), the overlays just needed to be
                // mounted in the iPhone ZStack. Same z-ordering as padBody:
                // selection overlays under symmetry/pose.

                if !isViewingSnapshot, let previewRect = canvasState.previewSelection {
                    let screenPreviewRect = canvasState.documentRectToScreen(previewRect)
                    Rectangle()
                        .path(in: screenPreviewRect)
                        .stroke(Color.blue, lineWidth: 2)
                        .allowsHitTesting(false)
                        .ignoresSafeArea()
                }

                if !isViewingSnapshot, let previewPath = canvasState.previewLassoPath, !previewPath.isEmpty {
                    let screenPreviewPath = canvasState.documentPathToScreen(previewPath)
                    Path { p in
                        p.move(to: screenPreviewPath[0])
                        for point in screenPreviewPath.dropFirst() {
                            p.addLine(to: point)
                        }
                        p.closeSubpath()
                    }
                    .stroke(Color.blue, lineWidth: 2)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
                }

                // Marching ants vanish while the user is moving or
                // scaling/rotating the selection — see
                // canvasState.isTransformingSelection. The selection is
                // still alive; only the animated outline is suppressed
                // for the duration of the transform so the chasing ants
                // don't read as visual noise (and so we don't restroke
                // a large polygon every frame).
                if !isViewingSnapshot,
                   let selection = canvasState.activeSelection,
                   !canvasState.isTransformingSelection {
                    let screenSelection = canvasState.documentRectToScreen(selection)
                    MarchingAntsRectangle(rect: screenSelection)
                        .allowsHitTesting(false)
                        .ignoresSafeArea()
                }

                if !isViewingSnapshot,
                   let path = canvasState.selectionPath,
                   !canvasState.isTransformingSelection {
                    let screenPath = canvasState.documentPathToScreen(path)
                    MarchingAntsPath(path: screenPath)
                        .allowsHitTesting(false)
                        .ignoresSafeArea()
                }

                // Free-transform handles for the active floating selection.
                // Hit-tests scoped to the handles themselves; the rest of
                // the overlay frame falls through to MTKView.
                if !isViewingSnapshot {
                    TransformHandlesOverlay(canvasState: canvasState)
                        .ignoresSafeArea()
                }

                // Symmetry mirror guides. Used to live in padBody only;
                // the iPhone Phase 2 split deliberately omitted it but
                // testers reported "the lines don't show on my phone."
                // Drop it in here with the same wiring — geometry math
                // is universal (reads from shared canvasState), the
                // overlay just needed to be in the iPhone ZStack.
                if !isViewingSnapshot {
                    SymmetryGuideOverlay(canvasState: canvasState, symmetry: symmetry)
                        .ignoresSafeArea()
                }

                // Pose skeleton(s). PoseOverlayView gates per-joint
                // dragging to `DeviceIdiom.isPad` internally (21 joints
                // at thumb scale isn't manageable), but whole-skeleton
                // transforms via PoseTransformHandlesView work on both.
                if !isViewingSnapshot {
                    PoseOverlayView(poseManager: poseOverlayManager, canvasState: canvasState)
                        .ignoresSafeArea()
                    PoseTransformHandlesView(poseManager: poseOverlayManager, canvasState: canvasState)
                        .ignoresSafeArea()
                }

                // Floating chip per active skeleton (Replace / Commit /
                // Hide / Lock / Discard). Was iPad-only; without it
                // iPhone users had no way to hide a placed skeleton.
                if !isViewingSnapshot {
                    PoseSkeletonChipsOverlay(
                        poseManager: poseOverlayManager,
                        canvasState: canvasState,
                        onRequestReplace: { kind in poseDetectionRequest = kind },
                        onRequestManualPlace: { kind in
                            poseOverlayManager.placeDefault(kind: kind, canvasSize: canvasState.documentSize)
                        }
                    )
                    .ignoresSafeArea()
                }

                // Low-confidence detection banner. Top of canvas,
                // 5s auto-dismiss.
                if !isViewingSnapshot {
                    PoseLowConfidenceBanner(poseManager: poseOverlayManager)
                        .ignoresSafeArea()
                }

                // Type-on-path live overlays — parity with padBody.
                // PathStartHandle gates internally on floatingText.path,
                // so all three are safe to mount unconditionally.
                if !isViewingSnapshot {
                    pathStartHandleOverlay
                    textOnPathPreviewOverlay
                    textOnPathCirclePreviewOverlay
                }

                // Caret + invisible UITextView host. `.ignoresSafeArea()`
                // is REQUIRED on iPhone — both views position via
                // `documentToScreen(...)` which returns coordinates in
                // the MTKView's full-window space (MTKView itself ignores
                // safe area). Without `.ignoresSafeArea()` the parent
                // ZStack's local origin sits below the NavigationStack's
                // toolbar + status bar, so `.position()` interprets the
                // window-space point as local — shifting both the
                // blinking caret and the invisible text host DOWN by the
                // top safe-area inset. The visible rasterised glyphs are
                // drawn directly into the layer texture so they still
                // land at the correct doc location regardless, but the
                // caret/host drift made the iPhone text tool feel "off."
                // padBody doesn't need this because padBody is a bare
                // ZStack at the top level (no NavigationStack chrome).
                if !isViewingSnapshot {
                    TextEntryOverlay(canvasState: canvasState)
                        .ignoresSafeArea()
                    FloatingTextCaretIndicator(canvasState: canvasState)
                        .ignoresSafeArea()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Phase 2 — hide nav bar items in snapshot mode alongside
                // the rest of the iPhone chrome. ToolbarItem accepts a
                // builder; an empty conditional renders nothing.
                ToolbarItem(placement: .navigationBarLeading) {
                    if !isViewingSnapshot {
                        Button(action: { showGallery = true }) {
                            Image(systemName: "photo.on.rectangle")
                        }
                        .accessibilityLabel("Gallery")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !isViewingSnapshot {
                        Button(action: { showSettings = true }) {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                // Beta Notice + How It Works moved into SettingsView
                // (see infoSection there). Their iPhone toolbar icons
                // were removed to declutter the nav bar.
            }
            .safeAreaInset(edge: .bottom) {
                // Phase 2 — entire iPhone bottom toolbar (selection bar,
                // brush rail, action row, tool panel) hides in snapshot
                // mode. EmptyView leaves the bottom safe area visually
                // empty while the canvas overlay is up.
                if isViewingSnapshot {
                    EmptyView()
                } else {
                    VStack(spacing: 8) {
                        phoneSelectionContextBar
                        if phoneBrushSizeRailVisible {
                            BrushSizeRailHorizontal(
                                size: $canvasState.brushSettings.size,
                                // Hide hardness track for tools whose shader
                                // ignores the uniform (inkPen, marker,
                                // airbrush) or floors it (pencil). The rail
                                // already treats a nil binding as "no
                                // hardness track."
                                hardness: canvasState.currentTool.usesHardness ? $canvasState.brushSettings.hardness : nil,
                                opacity: $canvasState.brushSettings.opacity,
                                screenDiameter: { canvasState.stampScreenDiameter(forBrushSize: $0) }
                            )
                                .padding(.horizontal, 16)
                                .transition(.opacity)
                        }
                        phoneActionRow
                        if isToolPanelExpanded {
                            phoneToolPanel
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .background(.regularMaterial)
                    .animation(.easeInOut(duration: 0.18), value: phoneBrushSizeRailVisible)
                }
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
                // Present whenever there's anything to show — current
                // feedback OR prior history. Was gated on
                // `feedback != nil`, which masked the panel when the
                // user opened it purely to scroll their history (e.g.
                // after relaunch when `feedback` is nil but the
                // critique log still hydrates from cloud).
                if canvasState.feedback != nil || !critiqueHistory.isEmpty {
                    FloatingFeedbackPanel(
                        feedback: canvasState.feedback,
                        critiqueHistory: critiqueHistory,
                        isPresented: $showFeedback,
                        onAskEve: { sequence in
                            // Dismiss critique sheet first; the Eve sheet
                            // opens via the .sheet modifier on the parent
                            // body so we can't stack two presentations.
                            showFeedback = false
                            openEve(scope: .drawing, critiqueSequence: sequence)
                        },
                        onActiveEntryChange: { entry, isLatest in
                            // Same phase 2 snapshot rule as iPad. On
                            // iPhone the panel is a half-sheet over the
                            // canvas; collapsing or dismissing it returns
                            // to the live canvas via .onChange(of:
                            // showFeedback) on the Group.
                            guard let entry = entry,
                                  !isLatest,
                                  let snapshot = entry.snapshot else {
                                canvasState.viewingSnapshot = nil
                                return
                            }
                            canvasState.viewingSnapshot = CanvasStateManager.SnapshotViewingState(
                                snapshot: snapshot,
                                timestamp: entry.timestamp
                            )
                        },
                        initialSelectedEntryId: preselectedCritique?.id
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            }
            // Eve sheet — iPhone. Half-sheet that matches the critique
            // panel's presentation. iPad uses the in-place overlay in
            // padBody; same EveSheetHost component, two presentation
            // shapes (DeviceIdiom branches at the call site, not inside
            // the component, mirroring how FloatingFeedbackPanel works).
            .sheet(isPresented: $showEve) {
                EveSheetHost(
                    scope: eveScope,
                    drawingId: eveScope == .drawing ? currentDrawingID : nil,
                    critiqueSequence: eveCritiqueSequence,
                    drawingTitle: eveDrawingTitle,
                    captureCanvas: { [canvasState] in
                        // Mirrors the critique flow's encoding path
                        // (CanvasStateManager.requestFeedback). The
                        // manager invokes this lazily on pill-tap; if
                        // export fails it just returns nil and the UI
                        // shows a transient retry hint.
                        canvasState.exportImage()?.jpegData(compressionQuality: 0.8)
                    },
                    onClose: { showEve = false }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
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

    // Returns AnyView (not `some View`) to type-erase the very deep
    // generic ZStack body. The Swift runtime type demangler runs out of
    // stack walking padBody's full TupleView<...> chain on 10-year-old
    // iPads (1 MB main-thread stack vs 8 MB on the simulator). The
    // crash signature was 50+ frames of swift::Demangle::__runtime in
    // the thread-1 backtrace. AnyView is a closed type — the demangler
    // stops at the boundary instead of recursing into the inner type.
    // Trade-off: we lose some of SwiftUI's structural diffing across
    // re-renders inside padBody; perf-wise that's measurable but
    // strictly better than a guaranteed crash on older hardware.
    private var padBody: AnyView {
        AnyView(
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
                symmetry: symmetry,
                backCanvasReferences: referenceManager.references.filter { $0.isBehindCanvas },
                onHoverChange: { hoverCursorPoint = $0 }
            )
            .ignoresSafeArea() // Full screen, edge to edge
            .background(Color(uiColor: .systemGray6))
            // Reference images render above the canvas, below tool
            // chrome. NEVER enters the layer stack — see
            // CanvasRenderer.compositeLayersToTexture for the
            // architectural commitment.
            .overlay { referenceOverlay }
            // Composition / Eye Test markers + heatmap. Same
            // SwiftUI-overlay-never-in-composite pattern as
            // reference images. Only renders when the panel is open
            // AND the service has a .ready result; harmless no-op
            // otherwise.
            .overlay { eyeTestOverlay }
            .overlay { tapToMarkCaptureOverlay }
            .overlay(alignment: .top) { tapToMarkBanner }

            // Phase 2 snapshot overlay — sits above MetalCanvasView and
            // its attached .overlay { } chain so the historical composite
            // visually covers the canvas AND the reference / eye-test
            // overlays. .allowsHitTesting(true) on the overlay catches
            // every touch so brush/eraser/selection gestures can't reach
            // the live Metal canvas underneath. The chrome below this
            // block is per-subview-gated on !isViewingSnapshot.
            if let viewing = canvasState.viewingSnapshot {
                SnapshotCanvasOverlay(viewing: viewing)
                    .allowsHitTesting(true)
                    .ignoresSafeArea()

                // Top-leading chip — sits over the overlay, tappable
                // anywhere to clear (no separate X per approved decision).
                snapshotChip(timestamp: viewing.timestamp)
            }

            // Selection overlays use the MTKView's full-screen coordinate
            // space (the MTKView ignores safe area at line 70). Without
            // .ignoresSafeArea() on each overlay, SwiftUI lays them out
            // inside the safe-area-reduced ZStack frame, shifting them down
            // by safeAreaInsets.top (~20pt iPad portrait). The marching
            // ants then visually misalign with the actual selected pixels
            // by that offset. Any new overlay aligned to canvas pixels
            // needs the same modifier.

            // Blue preview stroke while dragging selection
            if !isViewingSnapshot, let previewRect = canvasState.previewSelection {
                // Transform preview from document space to screen space
                let screenPreviewRect = canvasState.documentRectToScreen(previewRect)
                Rectangle()
                    .path(in: screenPreviewRect)
                    .stroke(Color.blue, lineWidth: 2)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }

            if !isViewingSnapshot, let previewPath = canvasState.previewLassoPath, !previewPath.isEmpty {
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

            // Marching ants selection overlay (after selection is made).
            // Hidden during transform — see canvasState.isTransformingSelection;
            // selection is still active, just the animated outline is
            // suppressed while the user moves or scales it.
            if !isViewingSnapshot,
               let selection = canvasState.activeSelection,
               !canvasState.isTransformingSelection {
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
            if !isViewingSnapshot, canvasState.isFilling {
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
            // gallery button. Rotation indicator pushed leftward by the same
            // gallery-icon clearance (50pt button + 12pt trailing inset + 10pt
            // gap = 72pt trailing) so it doesn't sit visually-under that
            // always-visible icon column when canvas is rotated.
            if !isViewingSnapshot {
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
                .padding(.top, 12)
                .padding(.trailing, 72)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
            }

            // Layer indicator — pinned to the bottom center of the screen so
            // it's always visible regardless of which gallery/panels are open.
            // SwiftUI alignment + safe-area padding handles iPad orientation
            // changes automatically (portrait ↔ landscape reflow).
            if !isViewingSnapshot {
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
            }

            if !isViewingSnapshot,
               let path = canvasState.selectionPath,
               !canvasState.isTransformingSelection {
                // Transform path from document space to screen space.
                // Hidden during transform — see iPad activeSelection
                // branch above for the rationale.
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
            if !isViewingSnapshot {
                SymmetryGuideOverlay(canvasState: canvasState, symmetry: symmetry)
                    .ignoresSafeArea()
            }

            // Free-transform handles for the active floating selection
            // (rect/lasso/import). Sits above the marching ants overlays so
            // the handles aren't obscured by the marquee. Hit tests are
            // scoped to the handles themselves; the rest of the overlay's
            // frame is transparent and lets touches fall through to MTKView.
            if !isViewingSnapshot {
                TransformHandlesOverlay(canvasState: canvasState)
                    .ignoresSafeArea()
            }

            // Pose-reference skeleton(s). Sibling to TransformHandlesOverlay
            // (Decision 4 — no Metal layer, no DrawingLayer subtype).
            if !isViewingSnapshot {
                PoseOverlayView(poseManager: poseOverlayManager, canvasState: canvasState)
                    .ignoresSafeArea()
            }

            // Whole-skeleton transform handles (PR 4). Renders dashed
            // bbox + corner / edge / rotation handles when the
            // skeleton's bbox is armed; auto-deselects after 4s.
            // Above the joint dots in Z so handle hit zones can compete
            // when they overlap with extremity joints.
            if !isViewingSnapshot {
                PoseTransformHandlesView(poseManager: poseOverlayManager, canvasState: canvasState)
                    .ignoresSafeArea()
            }

            // Floating chip per active skeleton — chevron menu with
            // Replace Photo / Commit / Hide-or-Show / Manually Place /
            // Discard. PR 6.
            if !isViewingSnapshot {
                PoseSkeletonChipsOverlay(
                    poseManager: poseOverlayManager,
                    canvasState: canvasState,
                    onRequestReplace: { kind in poseDetectionRequest = kind },
                    onRequestManualPlace: { kind in
                        poseOverlayManager.placeDefault(kind: kind, canvasSize: canvasState.documentSize)
                    }
                )
                .ignoresSafeArea()
            }

            // Low-confidence banner (top of canvas, 5s auto-dismiss).
            // Slides down on detection-place when joints fall below
            // PoseConfidence.lowThreshold; user can tap X to dismiss.
            if !isViewingSnapshot {
                PoseLowConfidenceBanner(poseManager: poseOverlayManager)
                    .ignoresSafeArea()
            }

            if !isViewingSnapshot {
                pathStartHandleOverlay
                textOnPathPreviewOverlay
                textOnPathCirclePreviewOverlay
                typeOnPathModeTogglePill
                cancelPillOverlay
                TextEntryOverlay(canvasState: canvasState)
                FloatingTextCaretIndicator(canvasState: canvasState)

                blurAdjustmentHUDOverlay

                stampCursorOverlay
            }

            // Delete button for active selection (rect or lasso)
            if !isViewingSnapshot,
               canvasState.activeSelection != nil || canvasState.selectionPath != nil {
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

            // Floating toolbar overlay (top layer, left side). Hidden
            // entirely when the canvas is showing a snapshot (per
            // approved phase 2 rule — editing UI disappears, not just
            // disables).
            floatingToolbar

            // Floating feedback panel. Stays visible in snapshot mode —
            // it's the navigator the user uses to flip between critiques
            // (and thus snapshots). The two new params wire phase 2:
            // onActiveEntryChange drives canvasState.viewingSnapshot;
            // initialSelectedEntryId lets the studio-wall navigation
            // open this view with a pre-selected entry.
            if showFeedback, canvasState.feedback != nil {
                FloatingFeedbackPanel(
                    feedback: canvasState.feedback,
                    critiqueHistory: critiqueHistory,
                    isPresented: $showFeedback,
                    onAskEve: { sequence in
                        openEve(scope: .drawing, critiqueSequence: sequence)
                    },
                    onActiveEntryChange: { entry, isLatest in
                        // Snapshot mode rule: enter iff the user picked
                        // a HISTORICAL entry that has a snapshot. Most-
                        // recent entries and pre-VH legacy entries
                        // (snapshot == nil) leave the live canvas alone.
                        guard let entry = entry,
                              !isLatest,
                              let snapshot = entry.snapshot else {
                            canvasState.viewingSnapshot = nil
                            return
                        }
                        canvasState.viewingSnapshot = CanvasStateManager.SnapshotViewingState(
                            snapshot: snapshot,
                            timestamp: entry.timestamp
                        )
                    },
                    initialSelectedEntryId: preselectedCritique?.id,
                    isInSnapshotMode: canvasState.viewingSnapshot != nil
                )
            }

            // Eve floating panel renders at the END of padBody (below) so
            // it's the topmost layer in the ZStack — above the action
            // column, the bottom-right CTAs, and the canvas itself. The
            // earlier in-stack position let the action column win the
            // z-fight and let canvas touches pass through to the brush
            // pipeline. See the `// Eve modal — iPad` block below.

            // Selection actions overlay — iPad positioning. The card
            // content (caption + Cancel + Delete pills) lives in the
            // shared `selectionActiveCard` computed property; only the
            // outer VStack/Spacer/HStack/Spacer + bottom-200 positioning
            // is iPad-specific. Same justified-deviation pattern as
            // Phase 4's critiqueContent extraction.
            if !isViewingSnapshot,
               canvasState.activeSelection != nil || canvasState.selectionPath != nil {
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
            //
            // Phase 2 — even the "always visible" gallery/Eve/Eye Test
            // cluster hides in snapshot mode (per "hide the entire
            // toolbar" rule). Restored when the snapshot clears.
            if !isViewingSnapshot {
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

                        // Eve coach — Feature 2, Phase 2A. Sits in the
                        // always-visible tier alongside Gallery (above
                        // the collapsible group) so the user can reach
                        // Eve even when the toolbar's hidden for focus.
                        // Lower visual weight than Gallery (44×44 with
                        // .primary monochrome treatment) so it doesn't
                        // visually compete with the "Get Feedback" CTA.
                        // iPhone path defers this affordance — iPhone
                        // users reach Eve via Ask Eve on FloatingFeedback-
                        // Panel only (per Phase 2A spec).
                        EveIconButton(action: { openEve(scope: .general) })

                        // Composition / "Eye Test" entry. Sits immediately
                        // below Eve in the always-visible chrome tier so
                        // the user can reach it without expanding the
                        // toolbar. Gated by the `eye_test_panel` remote
                        // feature flag — when the flag is off, the
                        // button doesn't mount at all (no flicker, no
                        // empty-state).
                        if appFeatureFlags.isEnabled(FeatureFlagName.eyeTestPanel) {
                            EyeTestIconButton(action: { showEyeTestPanel = true })
                        }

                        if !isToolbarCollapsed {
                            settingsGearButton
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                            // Beta Notice + How It Works moved into
                            // SettingsView (see settingsView.infoSection).
                            // Their per-canvas icons were removed here
                            // to declutter the floating chrome.
                        }
                    }
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                }
                Spacer()
                }
            }  // end if !isViewingSnapshot wrapper for top-right cluster

            // Bottom right - Action buttons (collapses with toolbar). Extracted
            // into a computed property because the inline expression pushed
            // the body past the Swift type-checker's tolerance once the gear
            // button landed in Phase 6. Hidden entirely in snapshot mode
            // alongside the rest of the editing chrome.
            if !isViewingSnapshot, !isToolbarCollapsed {
                bottomRightActionButtons
            }

            // Eve modal — iPad. Renders LAST in the padBody ZStack so the
            // dim backdrop and the panel sit above everything else (canvas,
            // tool rail, action column, bottom CTAs). The dim layer absorbs
            // touches via the default hit-testing — without it the user
            // could keep drawing / switching tools / tapping Get Feedback
            // while Eve was open, which broke the "focused conversation"
            // promise. Dismissal is X-button-only by design; tap-outside
            // was too easy to trigger accidentally and lost in-progress
            // conversations.
            //
            // Width 560 reads well on landscape (~half-screen) and
            // portrait (~70% of the narrower axis). Height caps at 820
            // with 80pt of breathing room. Both axes clamp against the
            // geometry so an unusually small split-screen pane still
            // fits the panel.
            if showEve {
                Color.black
                    .opacity(0.35)
                    .ignoresSafeArea()
                    .transition(.opacity)

                GeometryReader { geo in
                    EveSheetHost(
                        scope: eveScope,
                        drawingId: eveScope == .drawing ? currentDrawingID : nil,
                        critiqueSequence: eveCritiqueSequence,
                        drawingTitle: eveDrawingTitle,
                        captureCanvas: { [canvasState] in
                            canvasState.exportImage()?.jpegData(compressionQuality: 0.8)
                        },
                        onClose: {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                showEve = false
                            }
                        }
                    )
                    .frame(
                        width: min(560, geo.size.width - 40),
                        height: min(820, geo.size.height - 80)
                    )
                    .background(Color(uiColor: .systemBackground))
                    .cornerRadius(16)
                    .shadow(radius: 12)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        )  // close AnyView wrap
        // Note: sheets / alerts / fullScreenCover / onChange / onAppear /
        // preferredColorScheme modifiers used to live here on the ZStack;
        // PR #33 (iPhone Phase 2 / C1) lifted them onto the outer Group
        // wrapper in `body` so phoneBody and padBody share them. Don't
        // re-add them here — they'd double-fire.
    }

    // MARK: - Extracted: floating toolbar
    //
    // The entire iPad-side floating toolbar (the if !isViewingSnapshot
    // { VStack { ... } } block at the top of padBody). Same rationale
    // as toolPaletteGrid below: putting the block behind an opaque
    // `some View` boundary keeps padBody's tree shallow enough to
    // resolve inside iOS's 1 MB main-thread stack. The LazyVGrid
    // extraction in e5c9a4f wasn't enough on the oldest iPads —
    // the wrapping VStacks + ScrollView + sibling blocks still
    // pushed past the limit.

    @ViewBuilder
    private var floatingToolbar: some View {
            if !isViewingSnapshot {
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
                        toolPaletteGrid
                    }

                    // Pinned bottom — Import/Export above Undo/Redo, both
                    // above the existing Globe block. These sit OUTSIDE
                    // the ScrollView so they remain anchored regardless
                    // of toolbar scroll position. Behavior of each entry
                    // is unchanged from when they lived inside the grid.
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            // Image import — bifurcated picker. Button
                            // opens a confirmationDialog with "Import as
                            // Layer" / "Add as Reference"; each option
                            // triggers its own PhotosPicker. See the
                            // modifier chain on body for the dialog +
                            // pickers + handlers.
                            Button(action: { showPhotoChoice = true }) {
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
            }  // end if !isViewingSnapshot wrapper for floating toolbar
    }

    // MARK: - Extracted: tool palette grid
    //
    // Extracted from padBody to keep DrawingCanvasView's SwiftUI
    // body tree shallow enough to fit in the iOS 1 MB main-thread
    // stack. The inline LazyVGrid held 20 sibling tool slots which
    // the compiler wraps in nested TupleView generics deep enough
    // to overflow stack on older iPads (any device older than ~2018
    // hit this on first open of the canvas). Routing the grid
    // through an opaque `some View` boundary gives SwiftUI's view
    // resolver a place to break the body-evaluation recursion.

    @ViewBuilder
    private var toolPaletteGrid: some View {
                        LazyVGrid(columns: [GridItem(.fixed(44)), GridItem(.fixed(44))], spacing: 8) {
                            // Row 1: Brushes (grouped — pencil / brush /
                            // ink pen / marker / airbrush / charcoal),
                            // Eraser (standalone). Eraser stays its own
                            // top-level slot per audit §6 — it's the
                            // most-reached-for tool after brush, so
                            // muscle memory wins over slot economy.
                            GroupedToolButton(
                                group: .brushes,
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

                            // AI Feedback panel toggle. Was at the bottom of
                            // the iPad slot grid; swapped with the trash
                            // slot to put the destructive action at the
                            // bottom corner (less likely to be tapped by
                            // accident) and the everyday Feedback toggle
                            // up here next to the brush controls.
                            ToolButton(icon: "sparkles", isSelected: showFeedback) {
                                if canvasState.feedback != nil {
                                    showFeedback.toggle()
                                } else {
                                    presentCritiqueRequestSheet()
                                }
                            }
                            .disabled(canvasState.isEmpty)

                            // Color picker swatch. Grayed (not hidden) when
                            // blur, blurAdjustment, or smudge is the active
                            // tool — those tools don't read brush color.
                            Button(action: {
                                guard canvasState.currentTool != .blur,
                                      canvasState.currentTool != .blurAdjustment,
                                      canvasState.currentTool != .smudge else { return }
                                // Stash the active tool BEFORE flipping the
                                // sheet on so the .onChange(of: showColorPicker)
                                // dismissal handler can restore it.
                                if !showColorPicker {
                                    previousNonColorPickerTool = canvasState.currentTool
                                }
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
                            //
                            // Tap behavior is mode-dependent:
                            //   • Symmetry currently ON → tap turns it off.
                            //   • Symmetry off → tap opens the settings sheet
                            //     so the user can pick a mode to enable.
                            // Matches every other modal toggle in the toolbar
                            // (Selection, Move, etc.) — second tap exits.
                            ToolButton(
                                icon: "square.split.2x1",
                                isSelected: showSymmetrySettings || symmetry.mode != .off
                            ) {
                                if symmetry.mode != .off {
                                    symmetry.mode = .off
                                } else {
                                    showSymmetrySettings.toggle()
                                }
                            }

                            // Canvas flip — display-only mirrors around the
                            // viewport center. Layer textures unchanged. Used
                            // by artists to spot proportion errors the eye
                            // gets used to. The flip buttons are one-shot
                            // actions, not toggles — tapping fires the flip
                            // and the button visually "deselects" instantly.
                            // (Was previously a sticky toggle showing
                            // selected state while a flip was active; now
                            // the button never reads as on. The flip state
                            // itself is still toggled internally; the user
                            // gets back to neutral via Recenter.)
                            //
                            // Y-flip then X-flip placed at an EVEN-count
                            // position in the 2-column LazyVGrid so the
                            // pair sits side-by-side on the same row.
                            // Items above this group must remain at an
                            // even count or these two will split across
                            // rows again (the prior layout drifted into
                            // a column-adjacent / diagonal arrangement
                            // when Dark Mode was inserted before them).
                            ToolButton(
                                icon: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                                isSelected: false
                            ) {
                                canvasState.toggleFlipVertical()
                            }
                            .help("Flip canvas vertically")

                            ToolButton(
                                icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                                isSelected: false
                            ) {
                                canvasState.toggleFlipHorizontal()
                            }
                            .help("Flip canvas horizontally")

                            // Dark mode toggle — moved AFTER the flips
                            // so the flips end up side-by-side. (Was
                            // immediately before the flips, which
                            // shifted Y-flip into column 2 and X-flip
                            // onto the next row's column 1.)
                            ToolButton(
                                icon: userPreferredColorScheme == "dark" ? "sun.max.fill" : "moon.fill",
                                isSelected: false
                            ) {
                                toggleColorScheme()
                            }

                            // Canvas Transform Controls
                            // Rotate L/R buttons removed Apr 16 — pinch-rotate
                            // covers the same case on device and these were
                            // toolbar clutter. Recenter button stays — also
                            // the canonical way to undo a flip now that the
                            // flip buttons don't show their toggle state.
                            ToolButton(icon: "viewfinder", isSelected: false) {
                                canvasState.resetAllTransforms()
                            }
                            .help("Reset zoom, pan, rotation, and flips")
                            .disabled(canvasState.zoomScale == 1.0
                                      && canvasState.panOffset == .zero
                                      && canvasState.canvasRotation == .zero
                                      && !canvasState.flipHorizontal
                                      && !canvasState.flipVertical)

                            // Clear (trash) button. Lives in the bottom
                            // corner of the iPad slot grid — destructive
                            // action sits as far as possible from the
                            // everyday tools above. Confirmation alert
                            // (`showClearConfirmation`) gates the wipe.
                            ToolButton(icon: "trash", isSelected: false) {
                                showClearConfirmation = true
                            }
                        }
                        .padding(.top, 12)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
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

    /// Apple Pencil hover cursor — a thin circle outline at the
    /// pencil's hover position, sized to the current brush's
    /// screen-projected diameter. Renders only when:
    ///   • a hover point is active (pencil within ~1cm of the screen
    ///     on supported hardware, OR trackpad pointer on an iPad with
    ///     a Magic Keyboard)
    ///   • the current tool actually uses a brush (no cursor for
    ///     selection / move / text / etc.)
    /// On hardware without hover support, hoverCursorPoint stays nil
    /// and this overlay never renders.
    private var hoverCursorOverlay: some View {
        Group {
            if let point = hoverCursorPoint, toolUsesBrushCursor {
                let raw = canvasState.stampScreenDiameter(forBrushSize: canvasState.brushSettings.size)
                let diameter = max(raw, 6)
                ZStack {
                    Circle()
                        .strokeBorder(Color.black.opacity(0.45), lineWidth: 2.5)
                    Circle()
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
                }
                .frame(width: diameter, height: diameter)
                .position(point)
                .allowsHitTesting(false)
            }
        }
    }

    /// Tools that paint with a brush size — the only ones where a
    /// brush-shaped hover cursor makes visual sense.
    private var toolUsesBrushCursor: Bool {
        switch canvasState.currentTool {
        case .brush, .eraser, .pencil, .inkPen, .marker, .airbrush,
             .charcoal, .blur, .smudge, .line, .rectangle, .circle:
            return true
        default:
            return false
        }
    }

    /// Floating reference images layered above the Metal canvas. Each
    /// reference has its own chrome bar (lock/opacity/isolation/flip/
    /// delete) and corner-handle resize affordances. When unlocked the
    /// body is interactive (drag from anywhere, corner resize); when
    /// locked the body is non-hit-testable so brush strokes pass
    /// through. Sorted by zOrder so the most-recently-touched is on top.
    private var referenceOverlay: some View {
        ZStack {
            ForEach(referenceManager.references.sorted { $0.zOrder < $1.zOrder }) { ref in
                ReferenceImageView(
                    reference: ref,
                    canvasState: canvasState,
                    onUpdate: { referenceManager.update($0) },
                    onDelete: { referenceManager.remove(id: ref.id) },
                    onBringToFront: { referenceManager.bringToFront(id: ref.id) },
                    onRequestIsolation: {
                        Task { await referenceManager.requestIsolation(id: ref.id) }
                    },
                )
            }
        }
    }

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
                // Rail hugs the trailing edge (no horizontal padding) while
                // Save / Get Feedback keep their 12pt inset for tap-target
                // safety. Procreate keeps the size slider flush against
                // the canvas edge — matching that.
                VStack(alignment: .trailing, spacing: 12) {
                    if !isToolbarCollapsed {
                        BrushSizeRail(
                            size: $canvasState.brushSettings.size,
                            // See horizontal-rail comment above — hide
                            // the hardness track for tools that don't use it.
                            hardness: canvasState.currentTool.usesHardness ? $canvasState.brushSettings.hardness : nil,
                            opacity: $canvasState.brushSettings.opacity,
                            screenDiameter: { canvasState.stampScreenDiameter(forBrushSize: $0) }
                        )
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    VStack(spacing: 12) {
                        saveToGalleryButton
                        getFeedbackButton
                    }
                    .padding(.trailing, 12)
                }
                .padding(.bottom, 12)
            }
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    /// Opens the Eve coach sheet/panel with the given scope. Reads the
    /// current drawing's title from in-memory storage so the EveContextChip
    /// can render "About your drawing 'Forest at Dusk'" without an extra
    /// round-trip. iPad presents an in-place overlay (see padBody); iPhone
    /// uses a .sheet attached to the body wrapper. Both paths key off
    /// `showEve` so the dismiss button works the same in both idioms.
    private func openEve(scope: EveScope, critiqueSequence: Int? = nil) {
        eveScope = scope
        eveCritiqueSequence = critiqueSequence
        eveDrawingTitle = currentDrawingTitle
        // Use a soft animation on iPad so the panel slides in; iPhone's
        // sheet has its own animation.
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            showEve = true
        }
    }

    /// Best-effort lookup of the current drawing's title for the Eve
    /// context chip. Returns nil when no drawing is saved yet (fresh
    /// canvas — Eve will fall back to a generic chip label).
    private var currentDrawingTitle: String? {
        guard let id = currentDrawingID else { return nil }
        return storageManager.drawings.first(where: { $0.id == id })?.title
    }

    /// Render the canvas composite as a UIImage for AdvancedColorPicker's
    /// "Generate from canvas" button. Same path the eyedropper uses to
    /// sample a pixel — composite all visible layers, then export. Cost
    /// is bounded by the 128×128 downsample inside PaletteGenerator;
    /// the full-resolution UIImage we hand off only lives for the
    /// duration of one generation request. Returns nil if the renderer
    /// or composite isn't available (cold canvas, transient state).
    private func composeCanvasForPaletteGeneration() -> UIImage? {
        guard let renderer = canvasState.renderer else { return nil }
        guard let composite = renderer.compositeLayersToTexture(layers: canvasState.layers) else {
            return nil
        }
        return renderer.textureToUIImage(composite)
    }

    /// On-canvas overlay for the Composition / "Eye Test" panel.
    /// Findings render only when the panel is open AND the service has
    /// produced a `.ready` result. The intent marker renders whenever
    /// it's persisted on the drawing — independent of panel state —
    /// so the user can see their intent without the panel open.
    @ViewBuilder
    private var eyeTestOverlay: some View {
        let findings: CompositionFindings? = {
            guard showEyeTestPanel else { return nil }
            if case .ready(let f) = compositionAnalysisService.lastResult {
                return f
            }
            return nil
        }()
        EyeTestOverlay(
            findings: findings,
            showHeatmap: showEyeTestHeatmap,
            intentMarker: currentDrawingIntentMarker,
            canvasState: canvasState
        )
    }

    /// Current intent marker for the drawing being edited, if any.
    /// Reads from CloudDrawingStorageManager's @Published `drawings`
    /// array — changes via `setIntentMarker(id:marker:)` re-trigger
    /// view updates automatically.
    private var currentDrawingIntentMarker: IntentMarker? {
        guard let id = currentDrawingID else { return nil }
        return storageManager.drawings.first(where: { $0.id == id })?.intentMarker
    }

    /// Persist a new intent marker for the current drawing. Requires
    /// a saved drawing — pre-save drawings can't be marked yet (no
    /// row to PATCH). Errors are logged; user retry path is to tap
    /// again.
    private func setIntentMarker(_ marker: IntentMarker) async {
        guard let id = currentDrawingID else { return }
        do {
            try await storageManager.setIntentMarker(id: id, marker: marker)
        } catch {
            print("⚠️ setIntentMarker failed: \(error.localizedDescription)")
        }
    }

    /// Clear the intent marker for the current drawing.
    private func clearIntentMarker() async {
        guard let id = currentDrawingID else { return }
        do {
            try await storageManager.setIntentMarker(id: id, marker: nil)
        } catch {
            print("⚠️ clearIntentMarker failed: \(error.localizedDescription)")
        }
    }

    /// Tap-to-mark gesture handler. Converts the screen-coord tap into
    /// normalized document coords, persists, and exits the mode.
    private func handleTapToMark(at screenPoint: CGPoint) {
        let docPoint = canvasState.screenToDocument(screenPoint)
        let docSize = canvasState.documentSize
        guard docSize.width > 0, docSize.height > 0 else { return }
        let marker = IntentMarker(
            x: max(0, min(1, Double(docPoint.x / docSize.width))),
            y: max(0, min(1, Double(docPoint.y / docSize.height)))
        )
        isTapToMarkActive = false
        Task { await setIntentMarker(marker) }
    }

    /// Banner overlay shown at the top of the canvas while
    /// tap-to-mark mode is active. Copy is locked per condition 3 of
    /// the M3 build plan ("Tap to mark your intended focal point. Tap
    /// Done to exit."). Without this banner, users would mark intent
    /// accidentally or not know they were in the mode — non-optional.
    @ViewBuilder
    private var tapToMarkBanner: some View {
        if isTapToMarkActive {
            HStack(spacing: 12) {
                Image(systemName: "scope")
                    .font(.system(size: 16, weight: .semibold))
                Text("Tap to mark your intended focal point. Tap Done to exit.")
                    .font(.callout)
                Spacer(minLength: 8)
                Button("Done") {
                    isTapToMarkActive = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(uiColor: .systemBackground).opacity(0.97))
            .cornerRadius(10)
            .shadow(radius: 4)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Tap-capture overlay. Mounted above all other canvas overlays
    /// when isTapToMarkActive is true; transparent otherwise. The
    /// SpatialTapGesture supplies the tap location in screen coords.
    @ViewBuilder
    private var tapToMarkCaptureOverlay: some View {
        if isTapToMarkActive {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            handleTapToMark(at: value.location)
                        }
                )
        }
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

    // Beta-info and onboarding-info buttons were here. They moved to
    // SettingsView's infoSection. Their @State triggers, .sheet bindings,
    // toolbar items, and computed views are all removed.

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
        Button(action: presentCritiqueRequestSheet) {
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

    // Resets the toggle to .inProgress at the call site (not via
    // onDismiss) so the next sheet open always starts fresh, per the
    // locked spec — even after a cancel or a successful send. The
    // .inProgress default mirrors the "more forgiving failure mode"
    // reasoning: process advice on a finished drawing is mildly off;
    // finishing advice on a sketch is what broke for Sophia.
    private func presentCritiqueRequestSheet() {
        selectedStageOfWork = .inProgress
        showCritiqueRequestSheet = true
    }

    // A1-build: critique request confirm sheet. Hosts the stage-of-work
    // segmented picker and the Send-to-Eve / Cancel actions. Send closes
    // the sheet first, then kicks off the existing requestFeedback flow
    // so the existing in-flight UI (button spinner, FloatingFeedbackPanel
    // on completion) keeps working unchanged.
    private var critiqueRequestSheet: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Request a Critique")
                    .font(.headline)
                Text("How would you describe this drawing right now?")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 16)

            Picker("Stage of work", selection: $selectedStageOfWork) {
                Text("In progress").tag(StageOfWork.inProgress)
                Text("Finished").tag(StageOfWork.finished)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)

            VStack(spacing: 8) {
                Button(action: {
                    showCritiqueRequestSheet = false
                    requestFeedback()
                }) {
                    Text("Send to Eve")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .cornerRadius(10)
                }

                Button("Cancel") {
                    showCritiqueRequestSheet = false
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.vertical, 2)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
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

    /// True when the active tool actually consumes `brushSettings.size`.
    /// The horizontal brush-size rail hugs the action row when this is
    /// true and collapses out when the user picks a tool that ignores
    /// size (fill, eyedropper, select / move, text, pose, blur
    /// adjustment) — those tools don't benefit from a size affordance,
    /// and giving the canvas the row back reads better on a narrow
    /// phone. The list matches the doc-comment on
    /// `BrushSizeRail.swift`; keep them in sync when adding tools.
    private var phoneBrushSizeRailVisible: Bool {
        switch canvasState.currentTool {
        case .brush, .pencil, .inkPen, .marker, .airbrush, .charcoal,
             .eraser, .blur, .smudge,
             .line, .rectangle, .circle:
            return true
        default:
            return false
        }
    }

    // MARK: - iPhone brush variant picker (sheet)
    //
    // The 6 brush variants live behind a single tile on iPhone (the
    // flat tile grid has no room for an iPad-style long-press popover).
    // Tap → picker sheet → tap a variant → currentTool updates and
    // sheet dismisses. The tile's icon reflects the active variant so
    // the user sees which brush they're holding.

    /// iPad-only brush variants. Keep the order matching ToolGroup.brushes
    /// so the picker visually mirrors the iPad popover even though the
    /// rendering surface is different. Source of truth on which tools
    /// count as "brush variants" lives here.
    private static let phoneBrushVariants: [DrawingTool] = [
        .pencil, .brush, .inkPen, .marker, .airbrush, .charcoal,
    ]

    private var isCurrentToolBrushVariant: Bool {
        Self.phoneBrushVariants.contains(canvasState.currentTool)
    }

    /// Icon for the iPhone brush tile. Shows the active variant's icon
    /// when a brush variant is current; defaults to the base brush
    /// icon when a non-brush tool is selected (so the tile still
    /// reads as "brushes" semantically).
    private var phoneBrushTileIcon: String {
        if isCurrentToolBrushVariant {
            return canvasState.currentTool.icon
        }
        return DrawingTool.brush.icon
    }

    private var phoneBrushPickerSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Self.phoneBrushVariants, id: \.self) { variant in
                        Button {
                            canvasState.currentTool = variant
                            showPhoneBrushPicker = false
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: variant.icon)
                                    .font(.title3)
                                    .frame(width: 32, height: 32)
                                    .foregroundStyle(canvasState.currentTool == variant
                                                     ? Color.accentColor
                                                     : .primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(variant.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(Self.phoneBrushTagline(for: variant))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if canvasState.currentTool == variant {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Each brush calibrates size / hardness / opacity to fit its style. You can fine-tune in Brush Settings after picking.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Brushes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showPhoneBrushPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// One-line vibe per variant — shown under the variant name in the
    /// iPhone picker sheet. Kept terse so the row stays single-line
    /// readable on narrow phones.
    private static func phoneBrushTagline(for tool: DrawingTool) -> String {
        switch tool {
        case .pencil:   return "Sharp, narrow, paper-tooth grain"
        case .brush:    return "Round disc, soft edge — the default"
        case .inkPen:   return "Confident hard edge, pressure scales width"
        case .marker:   return "Flat-topped, semi-transparent, overlaps deepen"
        case .airbrush: return "Big soft mist, builds via overlap"
        case .charcoal: return "Wide, grainy, broken edges"
        default:        return ""
        }
    }

    // MARK: - iPhone pose picker
    //
    // Mirrors the brush picker pattern. The grid tile is a single
    // "Pose" entry; tapping it opens a sheet listing hand pose and
    // body pose, each row preserving the same tap-cycle as the
    // standalone PoseReferenceTile (request detection if no skeleton
    // exists, toggle visibility otherwise).

    private static let phonePoseVariants: [DrawingTool] = [.handPose, .bodyPose]

    /// True when any pose skeleton is currently visible. Used to
    /// drive the combined tile's selected-state styling — matches the
    /// brush tile's "is the active tool a brush variant" semantic.
    private var isAnyPoseVisible: Bool {
        poseOverlayManager.state(for: .hand).isVisible
            || poseOverlayManager.state(for: .body).isVisible
    }

    /// Icon for the combined iPhone pose tile. Reflects which kind is
    /// currently visible so the tile communicates state at a glance.
    /// Falls back to the body-pose icon (more recognisable as "pose")
    /// when nothing is visible or both are.
    private var phonePoseTileIcon: String {
        let handVisible = poseOverlayManager.state(for: .hand).isVisible
        let bodyVisible = poseOverlayManager.state(for: .body).isVisible
        if handVisible && !bodyVisible { return DrawingTool.handPose.icon }
        if bodyVisible && !handVisible { return DrawingTool.bodyPose.icon }
        return DrawingTool.bodyPose.icon
    }

    private var phonePosePickerSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Self.phonePoseVariants, id: \.self) { variant in
                        Button {
                            handlePhonePosePick(variant)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: variant.icon)
                                    .font(.title3)
                                    .frame(width: 32, height: 32)
                                    .foregroundStyle(phonePoseRowAccent(for: variant))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(variant.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(phonePoseRowStatus(for: variant))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                phonePoseRowTrailing(for: variant)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Tap a pose to detect from a photo. Tap again to hide a placed skeleton; once more to show it again.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Pose Reference")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showPhonePosePicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Tap dispatcher for a row in the iPhone pose picker. Runs the
    /// same tap cycle as the standalone PoseReferenceTile so behavior
    /// stays consistent: handleSlotTap may return a detection request,
    /// which we route to `poseDetectionRequest` (drives the detection
    /// sheet) — visibility toggles are absorbed by the manager. The
    /// picker dismisses on tap regardless of outcome.
    private func handlePhonePosePick(_ variant: DrawingTool) {
        if let outcome = poseOverlayManager.handleSlotTap(forTool: variant) {
            if case .requestDetection(let kind) = outcome {
                poseDetectionRequest = kind
            }
        }
        showPhonePosePicker = false
    }

    private func phonePoseRowAccent(for variant: DrawingTool) -> Color {
        guard let kind = PoseSkeletonKind(tool: variant) else { return .primary }
        return poseOverlayManager.state(for: kind).isVisible ? Color.accentColor : .primary
    }

    private func phonePoseRowStatus(for variant: DrawingTool) -> String {
        guard let kind = PoseSkeletonKind(tool: variant) else { return "" }
        switch poseOverlayManager.state(for: kind) {
        case .none:
            return variant == .handPose
                ? "Detect a hand from a photo to place a skeleton"
                : "Detect a body from a photo to place a skeleton"
        case .activeVisible:
            return "Visible — tap to hide"
        case .activeHidden:
            return "Hidden — tap to show again"
        }
    }

    @ViewBuilder
    private func phonePoseRowTrailing(for variant: DrawingTool) -> some View {
        if let kind = PoseSkeletonKind(tool: variant) {
            switch poseOverlayManager.state(for: kind) {
            case .activeVisible:
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            case .activeHidden:
                Image(systemName: "eye.slash")
                    .font(.body)
                    .foregroundStyle(.secondary)
            case .none:
                EmptyView()
            }
        }
    }

    // MARK: - iPhone type picker
    //
    // One grid tile, three rows in a sheet: plain text, type-on-path
    // freehand, type-on-path circle. Selecting a row sets the tool
    // and (for path modes) the sub-mode via `typeOnPathPathModeRaw`,
    // then dismisses. iPad uses a separate `.textOnPath` tile + the
    // floating mode-toggle pill; the pill collides with the iPhone
    // nav bar so we route the sub-mode through the sheet instead.

    /// Identifier for each row in the iPhone type picker. Used in
    /// place of a flat `[DrawingTool]` array because two rows share
    /// the same `DrawingTool` (`.textOnPath`) and differ only by
    /// sub-mode.
    private enum PhoneTypeVariant: Hashable, CaseIterable {
        case plainText
        case pathFreehand
        case pathCircle

        var tool: DrawingTool {
            switch self {
            case .plainText: return .text
            case .pathFreehand, .pathCircle: return .textOnPath
            }
        }

        var pathMode: TypeOnPathPathMode? {
            switch self {
            case .plainText: return nil
            case .pathFreehand: return .freehand
            case .pathCircle: return .circle
            }
        }

        var title: String {
            switch self {
            case .plainText:    return "Type Text"
            case .pathFreehand: return "Type on Path — Freehand"
            case .pathCircle:   return "Type on Path — Circle"
            }
        }

        var tagline: String {
            switch self {
            case .plainText:
                return "Tap to drop a caret; the keyboard rises immediately."
            case .pathFreehand:
                return "Drag a curve; the text flows along it."
            case .pathCircle:
                return "Tap a center, drag for the radius; the text wraps the ring."
            }
        }

        var icon: String {
            switch self {
            case .plainText:    return DrawingTool.text.icon
            case .pathFreehand: return DrawingTool.textOnPath.icon
            case .pathCircle:   return "circle.dashed"
            }
        }
    }

    private var isCurrentToolTypeVariant: Bool {
        canvasState.currentTool == .text || canvasState.currentTool == .textOnPath
    }

    private var phoneTypeTileIcon: String {
        switch canvasState.currentTool {
        case .textOnPath:
            return typeOnPathPathMode == .circle ? "circle.dashed" : DrawingTool.textOnPath.icon
        default:
            return DrawingTool.text.icon
        }
    }

    private func isPhoneTypeVariantActive(_ v: PhoneTypeVariant) -> Bool {
        switch v {
        case .plainText:
            return canvasState.currentTool == .text
        case .pathFreehand:
            return canvasState.currentTool == .textOnPath && typeOnPathPathMode == .freehand
        case .pathCircle:
            return canvasState.currentTool == .textOnPath && typeOnPathPathMode == .circle
        }
    }

    private var phoneTypePickerSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(PhoneTypeVariant.allCases, id: \.self) { variant in
                        Button {
                            canvasState.currentTool = variant.tool
                            if let mode = variant.pathMode {
                                typeOnPathPathModeRaw = mode.rawValue
                            }
                            showPhoneTypePicker = false
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: variant.icon)
                                    .font(.title3)
                                    .frame(width: 32, height: 32)
                                    .foregroundStyle(isPhoneTypeVariantActive(variant)
                                                     ? Color.accentColor
                                                     : .primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(variant.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(variant.tagline)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isPhoneTypeVariantActive(variant) {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Type Text drops a caret where you tap. Type on Path lets you trace a curve (or a circle) and the letters follow it.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showPhoneTypePicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - iPhone effects picker
    //
    // Mirrors iPad's ToolGroup.effects: smudge, blur (brush), blur
    // adjustment under one grid tile. Same picker pattern as brush /
    // pose / type — tap the tile to open a sheet, tap a row to
    // select and dismiss. Order matches the iPad popover so the
    // mental model is consistent across idioms.

    private static let phoneEffectsVariants: [DrawingTool] = [
        .smudge, .blur, .blurAdjustment,
    ]

    private var isCurrentToolEffectVariant: Bool {
        Self.phoneEffectsVariants.contains(canvasState.currentTool)
    }

    /// Tile icon reflects the active effect when one is selected;
    /// defaults to the smudge icon (iPad's default variant) otherwise.
    private var phoneEffectsTileIcon: String {
        if isCurrentToolEffectVariant {
            return canvasState.currentTool.icon
        }
        return DrawingTool.smudge.icon
    }

    private static func phoneEffectsTagline(for tool: DrawingTool) -> String {
        switch tool {
        case .smudge:
            return "Drag pixels along the stroke — smear the color you start on."
        case .blur:
            return "Paint Gaussian blur freeform along the stroke."
        case .blurAdjustment:
            return "Drag horizontally to set blur strength, ✓ to commit."
        default:
            return ""
        }
    }

    private var phoneEffectsPickerSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Self.phoneEffectsVariants, id: \.self) { variant in
                        Button {
                            canvasState.currentTool = variant
                            showPhoneEffectsPicker = false
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: variant.icon)
                                    .font(.title3)
                                    .frame(width: 32, height: 32)
                                    .foregroundStyle(canvasState.currentTool == variant
                                                     ? Color.accentColor
                                                     : .primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(variant.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(Self.phoneEffectsTagline(for: variant))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if canvasState.currentTool == variant {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Smudge and Blur paint freeform along your stroke. Blur Adjustment locks the canvas and lets you dial blur strength with a horizontal drag.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Effects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showPhoneEffectsPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var phoneToolPanel: some View {
        // 27 tiles, 5 columns × 6 rows. Three trailing cells are empty.
        // iPhone consolidates iPad's grouped categories under single
        // tiles that open a picker sheet — same pattern as iPad's
        // long-press popovers, just sheet-based since the flat phone
        // grid has no popover surface:
        //   • Brushes (6 variants) → one tile, phoneBrushPickerSheet
        //   • Effects (smudge / blur / blurAdjustment) → one tile,
        //     phoneEffectsPickerSheet
        //   • Type (text / textOnPath freehand / textOnPath circle)
        //     → one tile, phoneTypePickerSheet
        //   • Pose Reference (handPose / bodyPose) → one tile,
        //     phonePosePickerSheet
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
                // Single brush tile on iPhone — tapping opens the brush
                // variant picker sheet (pencil / brush / inkPen / marker
                // / airbrush / charcoal). The tile's ICON reflects
                // whichever variant is currently active so the user can
                // tell at a glance which brush they're holding.
                // isSelected is true whenever ANY brush variant is the
                // current tool, since the tile semantically represents
                // "brushes" as a category.
                ToolButton(
                    icon: phoneBrushTileIcon,
                    isSelected: isCurrentToolBrushVariant
                ) {
                    showPhoneBrushPicker = true
                    collapsePhoneToolPanel()
                }
                ToolButton(icon: DrawingTool.eraser.icon, isSelected: canvasState.currentTool == .eraser) {
                    canvasState.currentTool = .eraser
                    collapsePhoneToolPanel()
                }
                // Combined Effects tile — opens phoneEffectsPickerSheet
                // (smudge / blur / blurAdjustment). Mirrors iPad's
                // ToolGroup.effects category. Tile icon reflects the
                // active effect when one is selected.
                ToolButton(
                    icon: phoneEffectsTileIcon,
                    isSelected: isCurrentToolEffectVariant
                ) {
                    showPhoneEffectsPicker = true
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
                // Combined Type tile — opens phoneTypePickerSheet,
                // which routes to plain text or type-on-path
                // (freehand/circle). Same pattern as the brush and
                // pose pickers. isSelected is true while any text
                // tool is active; the icon reflects which sub-mode
                // (text vs freehand-path vs circle-path) so the tile
                // communicates state at a glance.
                ToolButton(
                    icon: phoneTypeTileIcon,
                    isSelected: isCurrentToolTypeVariant
                ) {
                    showPhoneTypePicker = true
                    collapsePhoneToolPanel()
                }
                // Single combined pose tile — taps open the pose
                // picker sheet (hand / body), mirroring the brush
                // tile pattern. isSelected reflects whether any
                // pose skeleton is currently visible; the tile icon
                // reflects which kind (or defaults to body when
                // neither or both are visible).
                ToolButton(
                    icon: phonePoseTileIcon,
                    isSelected: isAnyPoseVisible
                ) {
                    showPhonePosePicker = true
                    collapsePhoneToolPanel()
                }
            }
            // ViewBuilder caps each Group at 10 children. The second Group
            // hit that ceiling pre-pose; the two pose tiles above forced a
            // third Group split here so PhotosPicker..layerPanel can keep
            // their original tile sequence.
            Group {
                Button(action: {
                    // Same bifurcation as the iPad site — opens the
                    // confirmationDialog mounted on body. Collapse the
                    // tool panel before the dialog appears so the canvas
                    // is visible while the user chooses.
                    collapsePhoneToolPanel()
                    showPhotoChoice = true
                }) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 22))
                        .frame(width: 44, height: 44)
                }
                ToolButton(
                    icon: showPhotoSaveConfirmation ? "checkmark" : "arrow.down.to.line",
                    isSelected: false
                ) {
                    Task { await downloadToPhotos() }
                    collapsePhoneToolPanel()
                }
                .disabled(isSavingToPhotos)
                // iPhone-only behavior: the sparkle tile opens the
                // critique-history half-sheet, it does NOT fire a new
                // AI request. The "Get Feedback" action pill on
                // phoneActionRow is the dedicated trigger for new
                // critiques — having two entry points (a button and a
                // toolbar tile) that both ran the request was a
                // double-spend hazard. Sparkle now means "look at what
                // I've already been told." Disabled only when there's
                // truly nothing to show (no current feedback AND no
                // prior history).
                ToolButton(icon: "sparkles", isSelected: showFeedback) {
                    showFeedback = true
                    collapsePhoneToolPanel()
                }
                .disabled(canvasState.feedback == nil && critiqueHistory.isEmpty)
                Button(action: {
                    guard canvasState.currentTool != .blur,
                          canvasState.currentTool != .blurAdjustment,
                          canvasState.currentTool != .smudge else { return }
                    // Stash the active tool BEFORE flipping the sheet on
                    // so the .onChange(of: showColorPicker) dismissal
                    // handler can restore it. Mirrors iPad toggle site.
                    if !showColorPicker {
                        previousNonColorPickerTool = canvasState.currentTool
                    }
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
                    if symmetry.mode != .off {
                        symmetry.mode = .off
                    } else {
                        showSymmetrySettings.toggle()
                    }
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
                // Flip buttons are one-shot actions, not sticky toggles —
                // tap, canvas flips, button visually deselects.
                ToolButton(
                    icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                    isSelected: false
                ) {
                    canvasState.toggleFlipHorizontal()
                    collapsePhoneToolPanel()
                }
                ToolButton(
                    icon: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                    isSelected: false
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
                ToolButton(icon: "trash", isSelected: false) {
                    showClearConfirmation = true
                    collapsePhoneToolPanel()
                }
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
            // Pre-populate the save-dialog title from the questionnaire's
            // name field so the user doesn't enter it twice. Only seed
            // when still empty so a mid-session retitle isn't clobbered.
            if drawingTitle.isEmpty {
                let trimmed = context.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    drawingTitle = trimmed
                }
            }
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
            // A manual save zeros the auto-save dirty flag — the cloud
            // is now up to date, no need for the next 30s tick to
            // chase the same change.
            hasUnsavedEdits = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                showSavedConfirmation = false
            }
        }
    }

    // MARK: - Auto-save tick

    /// Called by the 30s polling task. Bails unless every condition
    /// holds: a drawing ID exists (first manual save happened), a
    /// title is loaded, there's been a real edit since the last
    /// save, no manual save is in flight, and no auto-save is
    /// already in flight.
    @MainActor
    private func autoSaveTick() async {
        guard let drawingID = currentDrawingID,
              !drawingTitle.isEmpty,
              hasUnsavedEdits,
              !isSaving,
              !isAutoSaving else { return }

        isAutoSaving = true
        defer { isAutoSaving = false }

        guard let payload = canvasState.exportLayeredPayload(drawingID: drawingID) else {
            print("⚠️ Auto-save: failed to build layered payload")
            return
        }
        do {
            try await storageManager.updateLayeredDrawing(
                id: drawingID,
                title: drawingTitle,
                payload: payload,
                feedback: canvasState.feedback,
                context: context,
                critiqueHistory: critiqueHistory
            )
            // Clear the dirty flag ONLY if no new mutation arrived
            // while the upload was in flight — otherwise the next
            // tick should still fire to flush the in-flight edits.
            // Bumped during the await? Leave the flag set.
            hasUnsavedEdits = false
            withAnimation(.easeInOut(duration: 0.2)) {
                showAutoSavedToast = true
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                withAnimation(.easeInOut(duration: 0.2)) {
                    showAutoSavedToast = false
                }
            }
        } catch {
            print("⚠️ Auto-save failed (storage queue will retry next tick): \(error)")
        }
    }

    /// Subtle floating indicator anchored to the top of the canvas.
    /// "Saving…" mid-flight, "Saved" briefly on success, nothing
    /// otherwise. Top padding clears the iPhone nav bar / iPad chrome.
    @ViewBuilder
    private var autoSaveStatusIndicator: some View {
        Group {
            if showAutoSavedToast {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                    Text("Saved")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                .padding(.top, 60)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if isAutoSaving {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Saving…")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                .padding(.top, 60)
                .transition(.opacity.combined(with: .move(edge: .top)))
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
        } catch PhotoLibrarySaverError.permissionDenied {
            // The system permission prompt has already been answered "no"
            // (or "limited" without add-only access). An OK-only alert
            // here would be a dead-end since iOS won't re-prompt — route
            // the user to Settings instead.
            showPhotoPermissionDeniedAlert = true
        } catch {
            photoSaveError = error.localizedDescription
        }
    }

    private func requestFeedback() {
        isRequestingFeedback = true

        Task {
            do {
                let drawingId = try await ensureDrawingPersistedToCloud()
                // Eye Test M4 — when both Eye Test feature flags are on
                // (panel + Eve integration) AND the local service has a
                // payload to share, pass it along. The panel flag gates
                // the surface; the Eve flag gates the wire-up to the
                // critique pipeline. Either off → critique runs without
                // composition findings. Both on, but no result yet → also
                // nil (the user can still get a critique without having
                // opened the panel).
                let compositionFindings: CompositionFindingsPayload? = {
                    guard appFeatureFlags.isEnabled(FeatureFlagName.eyeTestPanel),
                          appFeatureFlags.isEnabled(FeatureFlagName.eyeTestEveIntegration) else {
                        return nil
                    }
                    return compositionAnalysisService.currentFindingsPayload(
                        intentMarker: currentDrawingIntentMarker
                    )
                }()
                await canvasState.requestFeedback(
                    for: context,
                    drawingId: drawingId,
                    stageOfWork: selectedStageOfWork,
                    compositionFindings: compositionFindings
                )
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
