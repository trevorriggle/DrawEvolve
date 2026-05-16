//
//  CanvasStateManager.swift
//  DrawEvolve
//
//  Manages canvas state including layers, tools, selection, zoom/pan, and history
//

import Foundation
import SwiftUI
import UIKit
import Combine

@MainActor
class CanvasStateManager: ObservableObject {
    @Published var layers: [DrawingLayer] = []
    @Published var selectedLayerIndex = 0
    @Published var currentTool: DrawingTool = .brush
    @Published var brushSettings = BrushSettings() {
        // Phase 3 (Color System Overhaul, 2026-05-13): persist across
        // app launches. BrushSettings is Codable; CodableColor wraps the
        // UIColor field. The matching restore happens in init() below.
        // Matches the TextSettings persistence shape — same key
        // versioning pattern, same UserDefaults / JSONCoder usage.
        didSet { CanvasStateManager.saveBrushSettings(brushSettings) }
    }
    /// True while the paint-bucket flood fill is running on a background queue.
    /// The canvas re-entrancy-guards on this so a second tap can't kick off a
    /// concurrent fill, and DrawingCanvasView shows a HUD over the canvas.
    @Published var isFilling: Bool = false
    @Published var feedback: String?
    /// Incremented once per real pixel-level edit. Drives auto-save —
    /// `DrawingCanvasView` observes this and flips an unsaved-edits flag
    /// that a 30s timer flushes to the cloud. Viewport changes
    /// (pan / zoom / tool switch / transient drag previews) DON'T bump
    /// this; only commits that change what the saved manifest would
    /// contain do. Wrapping arithmetic — we don't care about the value,
    /// only that it changes.
    @Published var layerMutationCounter: Int = 0
    /// Phase 5d: the Worker-persisted critique entry returned alongside the
    /// feedback text. Consumers append this directly to local
    /// `critiqueHistory` for immediate display; the cloud row is canonical
    /// on the next gallery hydrate.
    @Published var lastCritiqueEntry: CritiqueEntry?
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var activeSelection: CGRect? = nil // Active selection rectangle
    @Published var selectionPath: [CGPoint]? = nil // For lasso selection
    @Published var selectionOffset: CGPoint = .zero // Offset for moving selection
    @Published var previewSelection: CGRect? = nil // Preview rectangle while dragging
    @Published var previewLassoPath: [CGPoint]? = nil // Preview lasso path while dragging

    // Selection pixel data (extracted when selection is made)
    var selectionPixels: UIImage? = nil
    var selectionOriginalRect: CGRect? = nil // Original position before moving
    var selectionLayerSnapshot: Data? = nil // Snapshot after clearing selection (for real-time rendering)
    var selectionBeforeSnapshot: Data? = nil // Snapshot before extraction (for history/undo)

    // GPU-side mirror of selectionPixels. Built once when extraction completes
    // (or when the move tool grabs the whole layer); the renderer composites
    // it at offset every frame instead of CPU-blending UIImage data per drag
    // sample. nil when no drag preview is active.
    var floatingSelectionTexture: MTLTexture? = nil
    // True when the move tool is dragging the whole active layer with no
    // prior rect/lasso selection. In that mode we skip extraction entirely:
    // the layer texture itself is what gets translated in the shader during
    // drag, and an in-place blit moves the bits on commit.
    var isTranslatingActiveLayer: Bool = false
    // Full-resolution source for the floating selection (only set on import,
    // for now). Future scale-gesture work resamples from this every time the
    // user changes the size, instead of resizing an already-resized texture
    // — otherwise repeated handle drags degrade quality fast.
    var selectionOriginalSource: UIImage? = nil

    // Transform state for selection
    // Scale factor for the floating selection. CGSize so corner handles
    // (uniform — width == height) and edge handles (one-axis — width XOR
    // height changes) share the same representation. Identity = (1, 1).
    @Published var selectionScale: CGSize = CGSize(width: 1.0, height: 1.0)
    @Published var selectionRotation: Angle = .zero // Rotation angle for selection
    @Published var isTransformingSelection = false // True when dragging transform handles

    // Zoom and Pan state (for canvas navigation)
    @Published var zoomScale: CGFloat = 1.0 // Current zoom level (1.0 = 100%)
    @Published var panOffset: CGPoint = .zero // Current pan offset in screen space
    @Published var canvasRotation: Angle = .zero // Current rotation angle

    // Canvas flip state — display-only mirror around viewport center.
    // Layer textures are unchanged; only the screen composition flips.
    // See documentToScreen / screenToDocument for the transform-chain
    // order rationale. resetAllTransforms clears these along with
    // zoom/pan/rotation so the Recenter button is always a one-tap
    // return to normal orientation.
    @Published var flipHorizontal: Bool = false
    @Published var flipVertical: Bool = false

    // Zoom constraints
    let minZoom: CGFloat = 0.1 // 10% minimum zoom
    let maxZoom: CGFloat = 10.0 // 1000% maximum zoom

    // Rotation settings
    let rotationSnappingInterval: Angle = .degrees(15) // Snap to 15° increments
    var enableRotationSnapping: Bool = true

    // MARK: - Blur Adjustment Tool (Procreate-style HUD scrubber)
    //
    // While the blurAdjustment tool is selected, the renderer holds a snapshot
    // of the active layer plus a preview texture; the MetalCanvasView swaps in
    // the preview texture for display. ✓ commits via commitBlurAdjustment(),
    // ✕ resets sigma via cancelBlurAdjustment(). Switching tools auto-ends.

    /// True while the blur adjustment HUD is visible. Drives both the HUD
    /// overlay and the preview-texture display swap in MetalCanvasView.
    @Published var blurAdjustmentActive: Bool = false

    /// Current blur sigma in document pixels. Drives the HUD percentage
    /// readout and the preview render. SwiftUI binds to this for live HUD
    /// updates as the user drags.
    @Published var blurAdjustmentSigma: Float = 0.0

    /// Maximum sigma the scrubber maps to. Defined here so the HUD percentage
    /// math and the renderer's kernel-radius math agree. Starting target per
    /// directive; reduce if perf measurements demand a lower cap.
    let blurAdjustmentMaxSigma: Float = 50.0

    /// Live percentage display for the HUD ("Blur · 35%"). Computed from
    /// blurAdjustmentSigma so it tracks edits in real time without manual
    /// mirroring.
    var blurAdjustmentPercent: Int {
        guard blurAdjustmentMaxSigma > 0 else { return 0 }
        return Int(round((blurAdjustmentSigma / blurAdjustmentMaxSigma) * 100.0))
    }

    // MARK: - Stamp cursor (blur brush; smudge in PR 2)
    //
    // Transient circle outline at the touch point during a blur-brush drag.
    // Set on touchesBegan/Moved, cleared on touchesEnded. SwiftUI overlay in
    // DrawingCanvasView binds to these.

    /// Center of the stamp cursor in screen-space points. nil = hidden.
    @Published var stampCursorCenter: CGPoint? = nil

    /// Diameter of the stamp cursor in screen-space points.
    @Published var stampCursorDiameter: CGFloat = 0

    // MARK: - Text tool (FloatingText)
    //
    // textSettings is the global default; loaded from UserDefaults on init,
    // saved via a Combine sink on every change. Editing the sheet while a
    // FloatingText is active also propagates to `floatingText.settings` —
    // single source of truth, see `applyTextSettingsToFloating`. Drag,
    // resize, and rotate mutate `floatingText` directly. Commit blits the
    // rasterised image into the active layer and clears the float.

    /// Persisted typographic defaults. Sliders/pickers in TypeInspectorView
    /// bind to this; the didSet sink saves to UserDefaults and pushes a
    /// debounced re-rasterise of the active FloatingText (if any).
    @Published var textSettings: TextSettings = TextSettings.loadPersisted()

    /// In-flight text object. nil = no floating text. Drag updates `anchor`,
    /// corner handle updates `scale` (uniform), rotation handle updates
    /// `rotation`. Commit/cancel from this side; auto-commit on tool change.
    @Published var floatingText: FloatingText? = nil

    /// Live preview of the user's in-progress path drawing during the
    /// .textOnPath touch session in **freehand** mode. Doc-space points;
    /// nil when no draw is active. DrawingCanvasView renders this as a
    /// thin guide line.
    @Published var previewTextOnPathPoints: [CGPoint]? = nil

    /// Live preview of the user's in-progress path drawing during the
    /// .textOnPath touch session in **circle** mode. `(center, radius)`
    /// in doc-space; nil when no draw is active or the user is in
    /// freehand mode. DrawingCanvasView renders this as a thin gray
    /// circle outline.
    @Published var previewTextOnPathCircle: TypeOnPathCirclePreview? = nil

    /// Cancellable rasterise debounce (~16ms). Re-armed on every settings or
    /// content change so rapid slider drags coalesce into one rasterise.
    private var textRasterizeTask: Task<Void, Never>?
    private var textSettingsCancellable: AnyCancellable?

    let historyManager = HistoryManager()
    // Bridge the nested HistoryManager's ObservableObject changes up to this object so
    // SwiftUI views that read `canvasState.historyManager.canUndo / canRedo` actually
    // re-render when those flags flip. Without this bridge the redo button stayed
    // .disabled(true) even after an undo pushed an action onto the redo stack — the
    // visible symptom of bug 2.1. Retain as a property so the subscription lives as
    // long as the state manager.
    private var historyCancellable: AnyCancellable?
    private var toolChangeCancellable: AnyCancellable?
    var renderer: CanvasRenderer?
    private var _screenSize: CGSize = .zero
    var screenSize: CGSize {
        get { return _screenSize }
        set {
            _screenSize = newValue
            // Update canvas size based on new screen size
            if let renderer = renderer {
                renderer.updateCanvasSize(for: newValue)
            }
        }
    }

    // Document size is the coordinate space for stored drawing data
    // DYNAMIC SIZE - the canvas is always a square sized to be bigger than the screen diagonal
    // This ensures no clipping/distortion when the canvas is rotated
    var documentSize: CGSize {
        return renderer?.canvasSize ?? CGSize(width: 2048, height: 2048)
    }

    /// Approximate doc-pixel → screen-point diameter for a brush stamp
    /// at the current zoom and canvas-fit ratio. Mirrors the math in
    /// `MetalCanvasView.Coordinator.stampScreenDiameter` so the brush
    /// rail's live size preview matches what a single stamp will look
    /// like on the canvas. Returns the raw `docSize` if the document
    /// width hasn't been set up yet (briefly true on first launch).
    func stampScreenDiameter(forBrushSize docSize: CGFloat) -> CGFloat {
        let docWidth = documentSize.width
        guard docWidth > 0 else { return docSize }
        return docSize * (screenSize.width / docWidth) * zoomScale
    }
    @Published var hasLoadedExistingImage = false // Track if we've loaded an existing drawing

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
        // Phase 3 (Color System Overhaul) — restore the user's last
        // brush settings from UserDefaults before any UI binding wires
        // up. Done first so the published default never momentarily
        // flashes to .black before the saved color lands. If load
        // returns nil (first launch, ever) we keep the BrushSettings()
        // default; the next mutation persists it for next launch.
        if let saved = CanvasStateManager.loadBrushSettings() {
            self.brushSettings = saved
        }

        // Forward nested HistoryManager change notifications. `objectWillChange.send()`
        // must fire on the main actor; we're already @MainActor-isolated, so that's
        // guaranteed for callers that mutate historyManager from the main actor (which
        // all our mutation sites do).
        historyCancellable = historyManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        // Auto-commit any active floating selection (or whole-layer move drag)
        // when the user picks a different tool. Without this, switching tools
        // while a selection is mid-transform would either leave the selection
        // floating indefinitely or strand the user — neither is sane UX.
        //
        // Exception: switching TO the move tool. Move's whole job is to drag
        // the floating selection (or, if none, the whole active layer); auto-
        // committing first would erase the user's selection right before they
        // tried to move it. dropFirst() skips the initial value emission so
        // we don't fire on init.
        toolChangeCancellable = $currentTool
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] newTool in
                guard let self = self else { return }

                // Auto-end blur adjustment if leaving the tool. Per directive:
                // "Switching to another tool → discards preview, no commit.
                // Explicit commit only via ✓."
                if newTool != .blurAdjustment && self.blurAdjustmentActive {
                    self.endBlurAdjustment()
                }

                if newTool != .move {
                    if self.floatingSelectionTexture != nil {
                        self.commitSelection()
                    } else if self.isTranslatingActiveLayer {
                        self.commitActiveLayerTranslation()
                    }
                }

                // Auto-commit any active floating text whenever we leave a
                // text-hosting tool. Both .text (plain) and .textOnPath
                // host floating text; switching to anything else commits.
                // Switching between .text and .textOnPath ALSO commits —
                // each owns its own creation flow and "carrying" a float
                // across modes would be confusing.
                if self.floatingText != nil {
                    let isPathText = self.floatingText?.path != nil
                    let stayingInOwningTool =
                        (newTool == .text && !isPathText) ||
                        (newTool == .textOnPath && isPathText)
                    if !stayingInOwningTool {
                        self.commitFloatingText()
                    }
                }

                // Auto-begin blur adjustment when entering the tool. Begin
                // after any pending floating-selection commit so the snapshot
                // captures the now-flattened layer state.
                if newTool == .blurAdjustment && !self.blurAdjustmentActive {
                    self.beginBlurAdjustment()
                }

                // Brush-variant calibration. Each variant (pencil / inkPen /
                // marker / airbrush / charcoal / brush) has its own size /
                // opacity / hardness / spacing / grainDensity defaults so a
                // freshly-selected Charcoal actually LOOKS like charcoal —
                // not like a default brush. Without this snap-back, all five
                // shaders rendered against the same generic settings produce
                // near-identical strokes (the user-visible "they all look
                // the same" complaint).
                //
                // Preserves the color across the switch — only the brush-
                // shape knobs reset. Pressure / minPressureSize / maxPressureSize
                // also carry through since they're user-prefs, not per-brush.
                if let defaults = BrushSettings.defaults(for: newTool) {
                    var next = defaults
                    next.color = self.brushSettings.color
                    next.pressureSensitivity = self.brushSettings.pressureSensitivity
                    next.minPressureSize = self.brushSettings.minPressureSize
                    next.maxPressureSize = self.brushSettings.maxPressureSize
                    // Don't disturb effect-tool params (blur / smudge) — they're
                    // owned by their own tool sessions and shouldn't be wiped
                    // when bouncing between brush variants.
                    next.blurStrength = self.brushSettings.blurStrength
                    next.smudgeStrength = self.brushSettings.smudgeStrength
                    self.brushSettings = next
                }
            }

        // Start with one layer. Inlined (rather than via `addLayer()`)
        // because the implicit first layer is canvas state, not a user
        // action — recording it in undo history would let the user undo
        // past it and end up with an empty `layers` array, which crashes
        // every subsequent touch on `layers[selectedLayerIndex]`. Matches
        // Procreate / Photoshop / Krita: the canvas always has at least
        // one layer; you can't undo it away.
        let initialLayer = DrawingLayer(name: "Layer 1")
        layers.append(initialLayer)
        selectedLayerIndex = 0

        // Persist textSettings to UserDefaults on every change, and propagate
        // edits to the active FloatingText so the sheet's sliders update the
        // live preview. dropFirst() skips the initial value emitted at init.
        textSettingsCancellable = $textSettings
            .dropFirst()
            .sink { [weak self] newSettings in
                guard let self = self else { return }
                newSettings.savePersisted()
                self.applyTextSettingsToFloating(newSettings)
            }
    }

    /// Marks the drawing as having an unsaved pixel-level change. Call
    /// from every commit point that mutates the texture/manifest the
    /// auto-save would upload — strokes, fills, text commits, selection
    /// deletes, undo/redo, layer add/remove/reorder. Do NOT call from
    /// viewport changes (pan/zoom), tool switches, or transient drag
    /// state.
    func bumpLayerMutation() {
        layerMutationCounter &+= 1
    }

    func addLayer() {
        let layer = DrawingLayer(name: "Layer \(layers.count + 1)")
        layers.append(layer)
        selectedLayerIndex = layers.count - 1
        print("➕ Added '\(layer.name)' - selectedLayerIndex now = \(selectedLayerIndex), total layers = \(layers.count)")
        historyManager.record(.layerAdded(layer))
        bumpLayerMutation()
    }

    /// Toggle a layer's isVisible flag AND trigger a canvas redraw.
    ///
    /// The eyeball button in the layer panel calls this rather than
    /// mutating `layer.isVisible` directly. The reason: DrawingLayer is
    /// a class with @Published properties, so mutating `layer.isVisible`
    /// directly fires the layer's own objectWillChange (which updates
    /// LayerRow's icon), but NOT the @Published var layers array on
    /// this manager — class-instance property mutations don't change
    /// the array reference. Under render-on-demand (Fix 1.1 of the
    /// perf-quick-wins PR), the MTKView only redraws when something
    /// calls setNeedsDisplay, which is wired to `updateUIView` on
    /// SwiftUI state changes. Bumping the layer-mutation counter here
    /// propagates through DrawingCanvasView's body → updateUIView →
    /// setNeedsDisplay, so the canvas reflects the visibility change.
    func toggleLayerVisibility(at index: Int) {
        guard layers.indices.contains(index) else { return }
        layers[index].isVisible.toggle()
        bumpLayerMutation()
    }

    func deleteLayer(at index: Int) {
        guard layers.count > 1, layers.indices.contains(index) else { return }
        let layer = layers[index]
        layers.remove(at: index)
        if selectedLayerIndex >= layers.count {
            selectedLayerIndex = layers.count - 1
        }
        historyManager.record(.layerRemoved(layer, index: index))
        bumpLayerMutation()
    }

    /// Reorder a layer within the stack. `destIndex` is interpreted as an
    /// insertion point in the *original* array (i.e. the index where the
    /// caller wants the layer to land before removal); we adjust for the
    /// remove-then-insert ordering internally so callers don't have to.
    /// The active selection follows the moved layer by id, so dragging the
    /// currently-selected layer keeps it selected after drop.
    func moveLayer(from sourceIndex: Int, to destIndex: Int) {
        guard layers.indices.contains(sourceIndex),
              (0...layers.count).contains(destIndex),
              sourceIndex != destIndex,
              destIndex != sourceIndex + 1 else { return }

        let layer = layers.remove(at: sourceIndex)
        let insertAt = destIndex > sourceIndex ? destIndex - 1 : destIndex
        layers.insert(layer, at: insertAt)

        selectedLayerIndex = layers.firstIndex(where: { $0.id == layer.id }) ?? selectedLayerIndex

        historyManager.record(.layerMoved(from: sourceIndex, to: insertAt))
        bumpLayerMutation()
    }

    // MARK: - Opacity slider history bracketing
    //
    // The slider mutates `layer.opacity` directly (via SwiftUI binding) so
    // the canvas updates live. We bracket the drag with begin/end so undo
    // gets one entry per gesture instead of one per intermediate value.
    private var opacityDragStartValue: [UUID: Float] = [:]

    func beginOpacityDrag(forLayerAt index: Int) {
        guard layers.indices.contains(index) else { return }
        opacityDragStartValue[layers[index].id] = layers[index].opacity
    }

    func endOpacityDrag(forLayerAt index: Int) {
        guard layers.indices.contains(index) else { return }
        let layer = layers[index]
        guard let oldValue = opacityDragStartValue.removeValue(forKey: layer.id),
              oldValue != layer.opacity else { return }
        historyManager.record(.layerPropertyChanged(
            layerId: layer.id,
            property: .opacity(old: oldValue, new: layer.opacity)
        ))
    }

    // MARK: - Layer rename history bracketing
    //
    // Same pattern as opacity. TextField binds directly to `layer.name`;
    // begin captures the pre-edit name, commit trims/caps and records one
    // history entry. Empty/whitespace-only commits revert to the old name.
    private var renameStartValue: [UUID: String] = [:]
    private static let layerNameMaxLength = 64

    func beginLayerRename(forLayerAt index: Int) {
        guard layers.indices.contains(index) else { return }
        renameStartValue[layers[index].id] = layers[index].name
    }

    func commitLayerRename(forLayerAt index: Int) {
        guard layers.indices.contains(index) else { return }
        let layer = layers[index]
        guard let oldName = renameStartValue.removeValue(forKey: layer.id) else { return }

        let trimmed = String(layer.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.layerNameMaxLength))
        if trimmed.isEmpty {
            layer.name = oldName
            return
        }
        layer.name = trimmed

        if oldName != layer.name {
            historyManager.record(.layerPropertyChanged(
                layerId: layer.id,
                property: .name(old: oldName, new: layer.name)
            ))
        }
    }

    func clearCanvas() {
        layers.removeAll()
        addLayer()
        historyManager.clear()
    }

    /// Clamp `selectedLayerIndex` into the valid range after a layer
    /// removal. The previous formula `max(0, layers.count - 1)` returns 0
    /// when `layers.isEmpty` — a valid Int but an INVALID array index — so
    /// callers that read `layers[selectedLayerIndex]` without a separate
    /// bounds check would crash. This helper keeps the index 0 only when
    /// the array is non-empty; when empty it parks at 0 and relies on the
    /// touch-handler guards in MetalCanvasView to skip the access. The
    /// empty case should be unreachable in practice once `init()` stops
    /// recording the implicit first layer in undo history (see commit
    /// "fix: don't record initial layer creation in undo history").
    ///
    /// TODO: consider Int? for selectedLayerIndex to make "no selection"
    /// representable at the type level. Touches every read site
    /// (LayerPanelView, MetalCanvasView in many places) so it's a
    /// follow-up; revisit post-TestFlight.
    private func clampSelectedLayerIndex() {
        selectedLayerIndex = layers.isEmpty
            ? 0
            : min(selectedLayerIndex, layers.count - 1)
    }

    func undo() {
        guard let action = historyManager.undo() else { return }
        defer { bumpLayerMutation() }

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
                clampSelectedLayerIndex()
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

        case .flipContent(let layerIds, let flipH, let flipV):
            // Flip is involutive — re-applying the same axes to the same
            // layers reverses the effect. Iterate by stored IDs (not
            // current visibility) so a layer hidden after the op is
            // still un-flipped.
            applyFlipToLayers(layerIds: layerIds, flipH: flipH, flipV: flipV)
        }
    }

    func redo() {
        guard let action = historyManager.redo() else { return }
        defer { bumpLayerMutation() }

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
                clampSelectedLayerIndex()
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

        case .flipContent(let layerIds, let flipH, let flipV):
            applyFlipToLayers(layerIds: layerIds, flipH: flipH, flipV: flipV)
        }
    }

    /// Re-apply a flip op to the specified layer IDs without recording
    /// a new history entry. Used by undo and redo (flip is involutive,
    /// so both directions just replay the same operation). Refreshes
    /// thumbnails and bumps the mutation counter.
    private func applyFlipToLayers(layerIds: [UUID], flipH: Bool, flipV: Bool) {
        guard let renderer = renderer else { return }
        guard flipH || flipV else { return }

        let affected = layerIds.compactMap { id in
            layers.first(where: { $0.id == id })
        }
        guard !affected.isEmpty else { return }

        for layer in affected {
            guard let texture = layer.texture else { continue }
            renderer.flipLayerTextureInPlace(
                texture,
                tileGrid: layer.tileGrid,
                flipHorizontal: flipH,
                flipVertical: flipV
            )

            let layerId = layer.id
            nonisolated(unsafe) let unsafeRenderer = renderer
            nonisolated(unsafe) let unsafeTexture = texture
            Task.detached {
                if let thumbnail = unsafeRenderer.generateThumbnail(
                    from: unsafeTexture,
                    size: CGSize(width: 44, height: 44)
                ) {
                    await MainActor.run {
                        if let l = self.layers.first(where: { $0.id == layerId }) {
                            l.updateThumbnail(thumbnail)
                        }
                    }
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

    // MARK: - FloatingText lifecycle
    //
    // beginText creates the float at the tap location with the global
    // textSettings as a snapshot. Drag updates `anchor`; the corner handle
    // updates `scale` (uniform); rotation handle updates `rotation`. Commit
    // = rasterise → renderImage → record stroke; cancel = drop without
    // touching the layer. Auto-commit on tool change, see init().

    /// Create a FloatingText at the tap location with the current global
    /// textSettings. The initial rasterise runs synchronously so the live
    /// preview / transform handles have valid bounds and a cached texture
    /// before the next touch event can race against the 16ms debounce.
    func beginText(at location: CGPoint, content: String) {
        // If a previous floating text is somehow still alive (shouldn't be —
        // the tap-outside-commit path should have caught it), bake it down
        // before starting the new one.
        if floatingText != nil {
            commitFloatingText()
        }
        let ft = FloatingText(content: content, settings: textSettings, anchor: location)
        floatingText = ft
        rasterizeFloatingTextNow()
    }

    /// Replace the active FloatingText's content. Re-rasterises (debounced).
    func setFloatingTextContent(_ content: String) {
        guard var ft = floatingText else { return }
        ft.content = content
        floatingText = ft
        scheduleRasterizeFloatingText()
    }

    /// Discard the floating text without touching the layer. Used by the
    /// cancel pill and touch handlers' touchesCancelled paths.
    func cancelFloatingText() {
        textRasterizeTask?.cancel()
        textRasterizeTask = nil
        floatingText = nil
    }

    /// Bake the active FloatingText into the active layer. Single GPU pass
    /// via `compositeFloatingTextureIntoLayer` (rotation included);
    /// before/after snapshots wrap the operation as a `.stroke` history
    /// entry so undo works the same as any other paint operation.
    func commitFloatingText() {
        guard floatingText != nil else { return }

        // Cancel any pending debounced rasterise and run one synchronously
        // so the commit always uses the latest content/settings — a setting
        // tweak immediately followed by a tool change can otherwise commit
        // a frame-stale image.
        textRasterizeTask?.cancel()
        textRasterizeTask = nil
        rasterizeFloatingTextNow()

        guard let ft = floatingText else { return }

        defer {
            // Always clear the float — even if commit failed, leaving the
            // float alive after an intended commit would strand the user.
            floatingText = nil
        }

        guard selectedLayerIndex < layers.count,
              let texture = layers[selectedLayerIndex].texture,
              let renderer = renderer,
              let cachedTexture = ft.cachedTexture else {
            print("⚠️ commitFloatingText: missing layer/texture/cached image — discarding")
            return
        }

        let beforeSnapshot = renderer.captureSnapshot(of: texture)

        let displayed = ft.displayedRect
        let docRect = displayed
        renderer.compositeFloatingTextureIntoLayer(
            cachedTexture,
            into: texture,
            tileGrid: layers[selectedLayerIndex].tileGrid,
            atDocRect: docRect,
            rotation: Float(ft.rotation.radians)
        )

        let afterSnapshot = renderer.captureSnapshot(of: texture)
        if let before = beforeSnapshot, let after = afterSnapshot {
            let layerId = layers[selectedLayerIndex].id
            historyManager.record(.stroke(
                layerId: layerId,
                beforeSnapshot: before,
                afterSnapshot: after
            ))
        }

        bumpLayerMutation()

        // Refresh the layer thumbnail off-main, same pattern as renderStroke.
        let currentLayerIndex = selectedLayerIndex
        nonisolated(unsafe) let unsafeRenderer = renderer
        nonisolated(unsafe) let unsafeTexture = texture
        let layerId = layers[selectedLayerIndex].id
        Task.detached {
            if let thumbnail = unsafeRenderer.generateThumbnail(from: unsafeTexture, size: CGSize(width: 44, height: 44)) {
                await MainActor.run { [weak self] in
                    guard let self = self,
                          currentLayerIndex < self.layers.count,
                          self.layers[currentLayerIndex].id == layerId else { return }
                    self.layers[currentLayerIndex].updateThumbnail(thumbnail)
                }
            }
        }
    }

    // MARK: - Type-on-path lifecycle

    /// Create a path-bearing FloatingText. Called from DrawingCanvasView's
    /// "Add" button after the user has drawn a path with .textOnPath and
    /// typed the text. Smooths the raw points (Catmull-Rom), builds the
    /// arc-length LUT, auto-detects closed-loop endpoint snap, and
    /// triggers an initial synchronous rasterise.
    func beginTextOnPath(
        rawPoints: [CGPoint],
        firstScreen: CGPoint,
        lastScreen: CGPoint,
        content: String
    ) {
        if floatingText != nil {
            commitFloatingText()
        }
        previewTextOnPathPoints = nil

        // Below ~3 raw samples there's nothing to smooth — bail silently.
        guard rawPoints.count >= 3 else { return }

        // Smooth the raw freehand polyline. Each output sample carries
        // both position and the analytic Catmull-Rom tangent — no
        // finite-difference reconstruction in the LUT (Tier-1.5 third
        // audit).
        let smoothed = PathSmoothing.catmullRom(rawPoints)
        let path = PathSmoothing.cgPath(from: smoothed)
        // Closure is detected from raw screen-space endpoints (locked
        // 30pt threshold). The lookup wraps modulo for closed paths so
        // text crosses the seam continuously.
        let isClosed = PathSmoothing.isClosedByEndpoint(
            firstScreen: firstScreen,
            lastScreen: lastScreen
        )
        let lut = PathSmoothing.buildArcLengthLUT(smoothed, isClosed: isClosed)

        var ft = FloatingText(
            content: content,
            settings: textSettings,
            anchor: smoothed.first?.point ?? .zero
        )
        ft.path = path
        ft.pathLUT = lut
        ft.isClosed = isClosed
        ft.pathStartOffset = 0
        ft.baselineOffset = 0
        // autoFlipEnabled left at the model default (false post-PR1).
        // Users with heart-shape / closed-loop paths who want flip
        // behaviour can toggle the field — UI surface for the toggle
        // is deferred until the inspector half-sheet returns.
        floatingText = ft
        rasterizeFloatingTextNow()
    }

    /// Type-on-path entry point for circle mode. Center is where the
    /// user touched down; radius is the drag distance at lift. The LUT
    /// is generated parametrically (no Catmull-Rom — a circle is
    /// already smooth). `isClosed = true` so the LUT lookup wraps
    /// continuously around the circle.
    func beginTextOnPathCircle(
        center: CGPoint,
        radius: CGFloat,
        content: String
    ) {
        if floatingText != nil {
            commitFloatingText()
        }
        previewTextOnPathPoints = nil

        // Sanity floor — sub-pixel circles produce degenerate LUTs.
        guard radius >= 4 else { return }

        let lut = PathSmoothing.circleArcLengthLUT(center: center, radius: radius)
        let path = PathSmoothing.cgPath(forCircleAt: center, radius: radius)

        var ft = FloatingText(
            content: content,
            settings: textSettings,
            // Anchor at the LUT's first sample (top of the circle in
            // the parameterisation; matches where pathStartOffset = 0
            // lands).
            anchor: lut.first?.point ?? center
        )
        ft.path = path
        ft.pathLUT = lut
        ft.isClosed = true
        ft.pathStartOffset = 0
        ft.baselineOffset = 0
        floatingText = ft
        rasterizeFloatingTextNow()
    }

    /// Update where text begins along the path (PathStartHandle drag).
    /// Clamps to [0, arcLength] for open paths; wraps mod arcLength for
    /// closed paths so dragging past the seam keeps text continuous.
    func setPathStartOffset(_ offset: CGFloat) {
        guard var ft = floatingText, let lut = ft.pathLUT, !lut.isEmpty else { return }
        let total = lut.last?.distance ?? 0
        var d = offset
        if ft.isClosed, total > 0 {
            d = d.truncatingRemainder(dividingBy: total)
            if d < 0 { d += total }
        } else {
            d = max(0, min(total, d))
        }
        guard ft.pathStartOffset != d else { return }
        ft.pathStartOffset = d
        floatingText = ft
        scheduleRasterizeFloatingText()
    }

    /// Set the perpendicular baseline shift (TypeInspectorView slider).
    /// Positive = above the path, negative = below.
    func setBaselineOffset(_ offset: CGFloat) {
        guard var ft = floatingText, ft.path != nil else { return }
        guard ft.baselineOffset != offset else { return }
        ft.baselineOffset = offset
        floatingText = ft
        scheduleRasterizeFloatingText()
    }

    /// Override the auto-detected closed flag (TypeInspectorView toggle).
    /// Re-rasterises so the lookup wraps (or clamps) accordingly.
    func setPathClosed(_ closed: Bool) {
        guard var ft = floatingText, ft.path != nil else { return }
        guard ft.isClosed != closed else { return }
        ft.isClosed = closed
        floatingText = ft
        scheduleRasterizeFloatingText()
    }

    /// Toggle auto-flip on upside-down sections.
    func setAutoFlipEnabled(_ enabled: Bool) {
        guard var ft = floatingText, ft.path != nil else { return }
        guard ft.autoFlipEnabled != enabled else { return }
        ft.autoFlipEnabled = enabled
        floatingText = ft
        scheduleRasterizeFloatingText()
    }

    // MARK: - Plain text helpers

    /// Bake `floatingText.scale` into `textSettings.size` and reset scale to
    /// identity, then re-rasterise. Called by the corner-handle drag's
    /// onEnded so font crispness is preserved across handle drags. Updating
    /// `textSettings` propagates through the global Combine sink to the
    /// active float (single source of truth).
    func bakeFloatingTextScale() {
        guard let ft = floatingText else { return }
        let factor = ft.scale.width
        guard abs(factor - 1.0) > 0.001 else { return }
        floatingText?.scale = CGSize(width: 1, height: 1)
        // didSet on textSettings propagates the new size to floatingText.settings
        // and schedules a re-rasterise.
        textSettings.size = max(1, textSettings.size * factor)
    }

    /// Push a settings update onto the active FloatingText (if any) and
    /// schedule a re-rasterise. Called from the textSettings publisher.
    private func applyTextSettingsToFloating(_ newSettings: TextSettings) {
        guard floatingText != nil else { return }
        floatingText?.settings = newSettings
        scheduleRasterizeFloatingText()
    }

    /// Debounce a rasterise of the active FloatingText. Short text uses a
    /// ~16ms debounce so each slider tick produces a smooth live preview;
    /// long text (>200 graphemes, where a single rasterise can cost >16ms)
    /// uses a longer debounce so rapid slider drags coalesce into a single
    /// rasterise on slider release. Approximates the spec's "defer rasterise
    /// to slider release" rule without UIKit slider state.
    private func scheduleRasterizeFloatingText() {
        textRasterizeTask?.cancel()
        let glyphCount = floatingText?.content.count ?? 0
        let delayNs: UInt64 = glyphCount > 200 ? 250_000_000 : 16_000_000
        textRasterizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }
            self?.rasterizeFloatingTextNow()
        }
    }

    private func rasterizeFloatingTextNow() {
        guard var ft = floatingText,
              let renderer = renderer,
              selectedLayerIndex < layers.count,
              let layerTexture = layers[selectedLayerIndex].texture else { return }

        guard let result = renderer.rasterizeFloatingTextWithDocOrigin(
            ft,
            for: layerTexture,
            screenSize: documentSize
        ) else {
            ft.cachedImage = nil
            ft.cachedTexture = nil
            ft.bounds = CGRect(origin: ft.anchor, size: .zero)
            floatingText = ft
            return
        }

        ft.cachedImage = result.image
        ft.cachedTexture = renderer.makeTexture(from: result.image)
        ft.bounds = result.docBounds
        if ft.path != nil {
            // Path text: `result.docBounds.origin` is the *natural* origin
            // produced by the current path-layout pass. To match
            // plain-text body-drag behavior (which survives re-rasterise
            // because plain text's docBounds.origin == ft.anchor), we
            // preserve the user's drag offset across re-rasterises.
            //
            //   newAnchor = newNatural + (oldAnchor - oldNatural)
            //
            // First rasterise after `beginTextOnPath` has no
            // pathNaturalAnchor yet, so the offset is zero and we land
            // at the natural origin (existing v1 behavior).
            let newNatural = result.docBounds.origin
            let offset: CGPoint = ft.pathNaturalAnchor.map { old in
                CGPoint(x: ft.anchor.x - old.x, y: ft.anchor.y - old.y)
            } ?? .zero
            ft.pathNaturalAnchor = newNatural
            ft.anchor = CGPoint(x: newNatural.x + offset.x,
                                y: newNatural.y + offset.y)
        } else {
            // Plain text: docBounds.origin already equals ft.anchor; this
            // is a no-op assignment that keeps the contract explicit.
            ft.anchor = result.docBounds.origin
        }
        floatingText = ft
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

    // MARK: - Pose reference (commit-to-trace)

    /// Bake `skeleton` into the active layer at the user-chosen
    /// `opacity` (0…1). Records a reversible `HistoryAction.stroke` so
    /// undo restores the pre-trace pixels.
    ///
    /// Returns `false` (without writing or recording history) when:
    ///   • there is no selected layer, or
    ///   • the active layer is locked (`isLocked` — layer-level lock,
    ///     not alpha-lock).
    ///
    /// Alpha-lock interaction (Stream 1D): not yet shipped. When 1D
    /// adds an `alphaLocked` flag on `DrawingLayer` and a corresponding
    /// branch in `CanvasRenderer.renderImage`, this commit will respect
    /// it automatically (renderImage is the single blit path here). If
    /// 1D wires alpha-lock as a per-stamp branch instead, mirror it
    /// here against the rasterized image's alpha buffer before the
    /// renderImage call.
    @discardableResult
    func commitPoseToTrace(skeleton: PoseSkeleton, opacity: CGFloat) -> Bool {
        guard selectedLayerIndex >= 0, selectedLayerIndex < layers.count else { return false }
        let layer = layers[selectedLayerIndex]
        guard !layer.isLocked else { return false }
        guard let texture = layer.texture else { return false }
        guard let renderer = renderer else { return false }
        guard let image = PoseRasterizer.rasterize(
            skeleton: skeleton,
            canvasSize: documentSize,
            opacity: max(0, min(1, opacity))
        ) else { return false }

        let beforeSnapshot = renderer.captureSnapshot(of: texture)

        // The rasterized image is at canvas-doc native pixel resolution
        // and the texture is the same; passing rect = full doc and
        // screenSize = documentSize means renderImage's scaleX/scaleY
        // become texture.width / documentSize.width — exactly the doc-
        // pixel-to-texture-pixel ratio (1.0 in practice). The blit ends
        // up pixel-aligned.
        let fullRect = CGRect(origin: .zero, size: documentSize)
        renderer.renderImage(image, at: fullRect, to: texture, tileGrid: layers[selectedLayerIndex].tileGrid, screenSize: documentSize)

        let afterSnapshot = renderer.captureSnapshot(of: texture)
        if let before = beforeSnapshot, let after = afterSnapshot {
            historyManager.record(.stroke(
                layerId: layer.id,
                beforeSnapshot: before,
                afterSnapshot: after
            ))
        }

        // Refresh the layer thumbnail off-main, same pattern as
        // commitFloatingText / renderStroke.
        let currentLayerIndex = selectedLayerIndex
        nonisolated(unsafe) let unsafeRenderer = renderer
        nonisolated(unsafe) let unsafeTexture = texture
        let layerId = layer.id
        Task.detached {
            if let thumbnail = unsafeRenderer.generateThumbnail(from: unsafeTexture, size: CGSize(width: 44, height: 44)) {
                await MainActor.run { [weak self] in
                    guard let self = self,
                          currentLayerIndex < self.layers.count,
                          self.layers[currentLayerIndex].id == layerId else { return }
                    self.layers[currentLayerIndex].updateThumbnail(thumbnail)
                }
            }
        }
        return true
    }

    // MARK: - Layered load (ONLINELAYERSTORE.md §6)

    /// Outcome of `loadLayered` — most are non-fatal "we still loaded the
    /// drawing, but…" surfaces that the canvas chrome can show as toasts.
    /// `formatTooNew` is the only hard failure: we refuse to truncate a
    /// future-format manifest to a single layer.
    enum LayeredLoadResult: Equatable {
        case loaded
        case loadedWithIntegrityWarning(missingOrdinals: [Int])
        case loadedWithSizeMismatch(savedWidth: Int, savedHeight: Int)
        case formatTooNew(savedVersion: Int, supportedVersion: Int)
    }

    /// Highest manifest format version this build can consume. Bump in lockstep
    /// with any breaking change to the manifest schema (ONLINELAYERSTORE.md §6.3).
    static let supportedManifestVersion = 1

    /// Reconstruct the canvas from a layered payload.
    ///
    /// Mirrors `loadImage(_:)` but reads the manifest + per-layer PNG bytes
    /// instead of a single flat image. Per ONLINELAYERSTORE.md §6.2:
    ///   1. Wipe the layer stack without re-adding the default layer.
    ///   2. Walk manifest entries in ordinal order, instantiating each
    ///      `DrawingLayer` with the manifest's stable id + flags.
    ///   3. Materialize each layer's texture from `renderer.makeTexture(from:)`.
    ///   4. Select the top layer, mark hasLoadedExistingImage, clear history.
    ///
    /// Sanity checks (§6.3):
    ///   - format_version > supported → returns `.formatTooNew`, layers untouched.
    ///   - per-layer bytes nil OR sha mismatch → insert an empty layer at that
    ///     ordinal so subsequent layers don't collapse upward; returns
    ///     `.loadedWithIntegrityWarning(missingOrdinals: …)`.
    ///   - document size != current `documentSize` → load anyway at saved
    ///     size; returns `.loadedWithSizeMismatch`. (We don't resample.)
    ///
    /// Tier enforcement (§6.4): we don't silently drop layers when the user
    /// is over their cap. Use `isOverLayerCap(_:)` to gate the save UI.
    @discardableResult
    func loadLayered(_ payload: LayeredDrawingPayload) -> LayeredLoadResult {
        guard let renderer = renderer else {
            print("ERROR: Cannot load layered drawing - renderer not available")
            return .loaded
        }

        let manifest = payload.manifest

        if manifest.formatVersion > Self.supportedManifestVersion {
            print("⚠️ Layered manifest format_version \(manifest.formatVersion) > supported \(Self.supportedManifestVersion); refusing to load")
            return .formatTooNew(
                savedVersion: manifest.formatVersion,
                supportedVersion: Self.supportedManifestVersion
            )
        }

        // Clear without auto-adding the default layer (stock clearCanvas does).
        layers.removeAll()
        clearSelection()

        // Walk in ordinal order — manifest may not already be sorted.
        let ordered = manifest.layers.sorted { $0.ordinal < $1.ordinal }
        var missingOrdinals: [Int] = []

        for entry in ordered {
            let blend = BlendMode(rawValue: entry.blendMode) ?? .normal
            let layerID = UUID(uuidString: entry.id) ?? UUID()
            let layer = DrawingLayer(
                id: layerID,
                name: entry.name,
                opacity: entry.opacity,
                isVisible: entry.visible,
                isLocked: entry.locked,
                blendMode: blend
            )

            // The payload's layerPNGs is a parallel array indexed by the
            // manifest's order; storage manager guarantees that contract.
            let pngIndex = manifest.layers.firstIndex(where: { $0.ordinal == entry.ordinal }) ?? entry.ordinal
            let pngData: Data? = (pngIndex >= 0 && pngIndex < payload.layerPNGs.count)
                ? payload.layerPNGs[pngIndex]
                : nil

            var texture: MTLTexture? = nil
            if let bytes = pngData, let image = UIImage(data: bytes) {
                texture = renderer.makeTexture(from: image)
            }

            if texture == nil {
                // Sha-mismatched / missing / undecodable bytes: insert an empty
                // layer at this ordinal so the rest of the stack keeps its
                // shape. Caller's toast tells the user something's off.
                missingOrdinals.append(entry.ordinal)
                texture = renderer.createLayerTexture()
            }

            layer.texture = texture
            // Pair the texture with an empty tile grid (Phase 2 Task 5).
            // Same lifetime as `layer.texture`; nil if texture allocation
            // ultimately failed.
            if texture != nil {
                layer.tileGrid = renderer.makeEmptyTileGrid()
            }
            layers.append(layer)
        }

        // Empty manifest is a corrupt save — restore default to avoid a
        // canvas with zero layers (which the renderer can't handle).
        if layers.isEmpty {
            addLayer()
        } else {
            selectedLayerIndex = layers.count - 1
        }

        hasLoadedExistingImage = true
        historyManager.clear()

        // Document-size sanity check is informational — we don't resample.
        let saved = CGSize(width: manifest.document.width, height: manifest.document.height)
        let current = documentSize
        let sizeChanged = abs(saved.width - current.width) > 0.5
            || abs(saved.height - current.height) > 0.5

        if !missingOrdinals.isEmpty {
            return .loadedWithIntegrityWarning(missingOrdinals: missingOrdinals)
        }
        if sizeChanged {
            return .loadedWithSizeMismatch(savedWidth: Int(saved.width), savedHeight: Int(saved.height))
        }
        return .loaded
    }

    /// True when the current layer count exceeds the supplied per-tier cap.
    /// Caller (e.g. the save button) gates writes while this is true so a
    /// downgraded user can't push an over-cap manifest. Loading itself never
    /// drops layers (ONLINELAYERSTORE.md §6.4).
    func isOverLayerCap(_ cap: Int) -> Bool {
        layers.count > cap
    }

    /// Build a `LayeredDrawingPayload` from the live layer stack so the save
    /// flow can call `saveLayeredDrawing` / `updateLayeredDrawing` instead of
    /// the legacy flat-image path. Per ONLINELAYERSTORE.md §3:
    ///   - each layer is read back as a lossless RGBA PNG via the renderer;
    ///   - opacity, visibility, locked, blendMode, stable id, and stack order
    ///     round-trip through the manifest;
    ///   - the composite JPEG (white-backed) keeps the AI-feedback / Worker
    ///     contract unchanged and seeds the gallery thumbnail.
    ///
    /// Returns nil only when no layer texture could be read back at all.
    /// Per-layer readback failures are logged and that ordinal is dropped —
    /// `normalizeManifestForUpload` will renumber the survivors so the
    /// uploaded manifest stays consistent.
    ///
    /// `drawingID` is advisory: storage manager rewrites
    /// `manifest.drawing_id` and per-layer asset paths in
    /// `normalizeManifestForUpload`. Pass the row id for updates and any
    /// fresh UUID for new saves.
    func exportLayeredPayload(drawingID: UUID) -> LayeredDrawingPayload? {
        guard let renderer = renderer, !layers.isEmpty else { return nil }

        var layerPNGs: [Data] = []
        var manifestLayers: [LayeredDrawingManifest.Layer] = []

        for (idx, layer) in layers.enumerated() {
            // Lazy-init: a layer the user added but never drew on arrives
            // with .texture == nil (texture creation runs on the next Metal
            // draw cycle). Materialize an empty layer texture so we still
            // preserve the slot in the manifest.
            let tex = layer.texture ?? renderer.createLayerTexture()
            guard let texture = tex,
                  let png = renderer.layerPNGData(of: texture) else {
                print("⚠️ exportLayeredPayload: failed to read layer \(idx) '\(layer.name)' — dropping from save")
                continue
            }
            layerPNGs.append(png)

            manifestLayers.append(LayeredDrawingManifest.Layer(
                ordinal: idx,
                id: layer.id.uuidString.lowercased(),
                name: layer.name,
                opacity: layer.opacity,
                visible: layer.isVisible,
                locked: layer.isLocked,
                blendMode: layer.blendMode.rawValue,
                asset: LayeredDrawingFilenames.layer(ordinal: idx),
                assetSha256: "",
                bbox: nil
            ))
        }

        guard !layerPNGs.isEmpty else {
            print("❌ exportLayeredPayload: every layer readback failed")
            return nil
        }

        let composite = exportImage()
        let compositeJPEG = composite?.jpegData(compressionQuality: 0.9)
        let thumbnailJPEG = composite.flatMap { layeredThumbnailJPEG(from: $0) }

        let manifest = LayeredDrawingManifest(
            formatVersion: Self.supportedManifestVersion,
            drawingId: drawingID.uuidString.lowercased(),
            document: .init(
                width: Int(documentSize.width.rounded()),
                height: Int(documentSize.height.rounded()),
                colorSpace: "srgb",
                pixelFormat: "rgba8_premultiplied"
            ),
            layers: manifestLayers,
            thumbnail: LayeredDrawingFilenames.thumbnail,
            composite: compositeJPEG != nil ? LayeredDrawingFilenames.composite : nil
        )

        return LayeredDrawingPayload(
            manifest: manifest,
            layerPNGs: layerPNGs,
            compositeJPEG: compositeJPEG,
            thumbnailJPEG: thumbnailJPEG
        )
    }

    /// Aspect-fit JPEG thumbnail at scale 1.0 so 1 UIImage point = 1 backing
    /// pixel (matches the gallery's existing 256-pt thumbnail size and
    /// ONLINELAYERSTORE.md §7.4).
    private func layeredThumbnailJPEG(from image: UIImage, maxDim: CGFloat = 256, quality: CGFloat = 0.8) -> Data? {
        let largest = max(image.size.width, image.size.height)
        guard largest > maxDim else {
            return image.jpegData(compressionQuality: quality)
        }
        let scale = maxDim / largest
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let r = UIGraphicsImageRenderer(size: newSize, format: format)
        let resized = r.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: quality)
    }

    /// Import a photo onto a brand-new layer, sized aspect-fit and centered
    /// on the document. The user can reposition with the Move tool.
    /// (Corner scale/rotate handles are deferred — see audit doc.)
    func importImage(_ image: UIImage) {
        guard let renderer = renderer else {
            print("ERROR: Cannot import image - renderer not ready")
            return
        }

        // If an earlier floating selection (prior import, or a rect/lasso
        // extraction) is still uncommitted, bake it into its layer first —
        // otherwise our clearSelection() below would silently throw away
        // the user's pixels.
        if floatingSelectionTexture != nil {
            commitSelection()
        } else if isTranslatingActiveLayer {
            commitActiveLayerTranslation()
        }

        addLayer()
        guard selectedLayerIndex < layers.count else {
            print("ERROR: Cannot import image - selectedLayerIndex out of range")
            return
        }

        // `addLayer` only appends the DrawingLayer; texture creation is lazy
        // inside MetalCanvasView.Coordinator.ensureLayerTextures(), which
        // only runs during a Metal draw cycle. We need the texture NOW —
        // commitSelection (called after the user drag-releases the imported
        // image) blits the floating texture into it, and the captureSnapshot
        // calls below need a real MTLTexture.
        if layers[selectedLayerIndex].texture == nil {
            layers[selectedLayerIndex].texture = renderer.createLayerTexture()
            // Pair with an empty tile grid (Phase 2 Task 5).
            if layers[selectedLayerIndex].texture != nil &&
               layers[selectedLayerIndex].tileGrid == nil {
                layers[selectedLayerIndex].tileGrid = renderer.makeEmptyTileGrid()
            }
        }
        guard let texture = layers[selectedLayerIndex].texture else {
            print("ERROR: Cannot import image - failed to create texture")
            return
        }

        // Aspect-fit at 80% of the canvas (matches the user's "leave room
        // for the handles" intent for the upcoming transform feature).
        let docW = documentSize.width
        let docH = documentSize.height
        let imgW = image.size.width
        let imgH = image.size.height
        guard imgW > 0, imgH > 0 else { return }

        let scale = min(docW * 0.8 / imgW, docH * 0.8 / imgH)
        let drawW = imgW * scale
        let drawH = imgH * scale
        let rect = CGRect(
            x: (docW - drawW) / 2,
            y: (docH - drawH) / 2,
            width: drawW,
            height: drawH
        )

        // Resample the source down to its displayed pixel size BEFORE the
        // GPU upload — uploading a 6000×4000 photo just to have the shader
        // downsample it for display burns memory and looks worse than a
        // proper Core Graphics resample. The full-res source is stashed on
        // the state manager so the upcoming scale-gesture work can resample
        // from the original each time the user changes size, instead of
        // degrading from successive resizes of an already-resized image.
        let displayPixelSize = CGSize(
            width: max(1, drawW.rounded()),
            height: max(1, drawH.rounded())
        )
        let resized = resizedImage(image, to: displayPixelSize)

        // Wire as a floating selection on the new (empty) layer. The user
        // can drag with the move tool (or any tap inside the image bounds);
        // drag-release routes through commitSelection, which blits the
        // floating texture into the layer in a single GPU pass.
        clearSelection()
        let beforeSnapshot = renderer.captureSnapshot(of: texture)
        selectionBeforeSnapshot = beforeSnapshot
        selectionLayerSnapshot = beforeSnapshot   // empty layer — nothing to "restore" beyond it
        selectionPixels = resized
        selectionOriginalRect = rect
        selectionOffset = .zero
        selectionOriginalSource = image
        floatingSelectionTexture = renderer.makeTexture(from: resized)

        if floatingSelectionTexture == nil {
            print("⚠️ Failed to upload imported image to a Metal texture; falling back to direct composite")
            renderer.renderImage(resized, at: rect, to: texture, tileGrid: layers[selectedLayerIndex].tileGrid, screenSize: documentSize)
            clearSelection()
        }

        hasLoadedExistingImage = true
        print("📷 Imported image as floating selection at \(rect) (texture \(displayPixelSize))")
    }

    /// Aspect-fill resample at scale 1.0 so 1 UIImage point = 1 backing pixel
    /// (otherwise UIGraphicsImageRenderer picks the screen scale and the
    /// resulting CGImage has 2× / 3× the pixels we asked for, which then
    /// uploads a needlessly large GPU texture).
    private func resizedImage(_ image: UIImage, to size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// `drawingId` must reference a row that already exists in the cloud
    /// `drawings` table for the current user — Phase 5b's Worker enforces
    /// ownership via service_role lookup. Caller is responsible for ensuring
    /// the drawing has been persisted to cloud before invoking this.
    ///
    /// Phase 5d: the Worker now also persists the critique to
    /// `drawings.critique_history` and returns the canonical entry. The
    /// caller reads `lastCritiqueEntry` after this call returns to update
    /// local UI state — no local synthesis or appending.
    func requestFeedback(
        for context: DrawingContext,
        drawingId: UUID,
        compositionFindings: CompositionFindingsPayload? = nil
    ) async {
        guard let image = exportImage() else {
            showError(message: "Failed to export drawing")
            return
        }

        do {
            let response = try await OpenAIManager.shared.requestFeedback(
                image: image,
                context: context,
                drawingId: drawingId,
                compositionFindings: compositionFindings
            )
            feedback = response.feedback
            lastCritiqueEntry = response.critiqueEntry
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
        selectionPixels = nil
        selectionOriginalRect = nil
        selectionLayerSnapshot = nil
        selectionBeforeSnapshot = nil
        floatingSelectionTexture = nil
        isTranslatingActiveLayer = false
        selectionOriginalSource = nil
        selectionOffset = .zero
        previewSelection = nil
        previewLassoPath = nil
        selectionScale = CGSize(width: 1.0, height: 1.0)
        selectionRotation = .zero
        isTransformingSelection = false
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

        // Delete pixels in selection (use documentSize for 1:1 coordinate mapping)
        if let rect = activeSelection {
            renderer.clearRect(rect, in: texture, tileGrid: layers[selectedLayerIndex].tileGrid, screenSize: documentSize)
        } else if let path = selectionPath {
            renderer.clearPath(path, in: texture, tileGrid: layers[selectedLayerIndex].tileGrid, screenSize: documentSize)
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

        bumpLayerMutation()

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

    /// Extract pixels from the selection and store them for moving
    /// IMPORTANT: This captures snapshots and immediately clears the original pixels for fluent real-time movement
    func extractSelectionPixels() {
        guard selectedLayerIndex < layers.count,
              let texture = layers[selectedLayerIndex].texture,
              let renderer = renderer else {
            print("ERROR: Cannot extract selection - invalid layer or texture")
            return
        }

        // Capture "before" snapshot for history (BEFORE any modifications)
        selectionBeforeSnapshot = renderer.captureSnapshot(of: texture)

        if let rect = activeSelection {
            // Extract pixels from rectangular selection
            // IMPORTANT: rect is in document space, so pass documentSize for 1:1 coordinate mapping
            selectionPixels = renderer.extractPixels(from: rect, in: texture, screenSize: documentSize)
            selectionOriginalRect = rect
            selectionOffset = .zero

            // Verify extraction succeeded
            if let pixels = selectionPixels {
                // IMMEDIATELY clear the original pixels - they'll be rendered at the new position in real-time
                renderer.clearRect(rect, in: texture, tileGrid: layers[selectedLayerIndex].tileGrid, screenSize: documentSize)
                // Capture snapshot AFTER clearing - this is the "base layer with hole" for real-time rendering
                selectionLayerSnapshot = renderer.captureSnapshot(of: texture)
                // Upload the extracted pixels to a Metal texture once. The
                // draw loop composites this on top of the layer (which now
                // has a hole) at originalRect + offset every frame — no CPU
                // work during drag.
                floatingSelectionTexture = renderer.makeTexture(from: pixels)
                print("✂️ Extracted rectangular selection: \(rect) and cleared original")
            } else {
                print("❌ ERROR: Failed to extract rectangular selection")
                print("  Rect: \(rect), Texture: \(texture.width)x\(texture.height), Document: \(documentSize)")
                clearSelection() // Clear invalid selection
            }
        } else if let path = selectionPath {
            // Validate path has enough points
            guard path.count >= 3 else {
                print("❌ ERROR: Lasso path too short (\(path.count) points), cannot extract")
                clearSelection() // Clear invalid selection
                return
            }

            // For lasso, find bounding box and extract with mask
            let boundingRect = calculateBoundingRect(for: path)

            // Validate bounding rect is not empty/invalid
            guard boundingRect.width > 0 && boundingRect.height > 0 else {
                print("❌ ERROR: Invalid lasso selection bounding rect: \(boundingRect)")
                clearSelection() // Clear invalid selection
                return
            }

            // IMPORTANT: path is in document space, so pass documentSize for 1:1 coordinate mapping
            selectionPixels = renderer.extractPixels(fromPath: path, in: texture, screenSize: documentSize)
            selectionOriginalRect = boundingRect
            selectionOffset = .zero

            // Verify extraction succeeded
            if let pixels = selectionPixels {
                // IMMEDIATELY clear the original pixels - they'll be rendered at the new position in real-time
                renderer.clearPath(path, in: texture, tileGrid: layers[selectedLayerIndex].tileGrid, screenSize: documentSize)
                // Capture snapshot AFTER clearing - this is the "base layer with hole" for real-time rendering
                selectionLayerSnapshot = renderer.captureSnapshot(of: texture)
                // GPU-side mirror for the live drag preview. See note in the
                // rect-selection branch above.
                floatingSelectionTexture = renderer.makeTexture(from: pixels)
                print("✂️ Extracted lasso selection, bounding rect: \(boundingRect) and cleared original")
            } else {
                print("❌ ERROR: Failed to extract lasso selection")
                print("  Bounding rect: \(boundingRect), Texture: \(texture.width)x\(texture.height), Document: \(documentSize)")
                clearSelection() // Clear invalid selection
            }
        }
    }

    /// Render selection pixels in real-time during drag
    /// This provides fluent animation by rendering directly to the texture as the user drags
    func renderSelectionInRealTime() {
        guard selectedLayerIndex < layers.count,
              let texture = layers[selectedLayerIndex].texture,
              let renderer = renderer,
              let pixels = selectionPixels,
              let originalRect = selectionOriginalRect,
              let snapshot = selectionLayerSnapshot else {
            return
        }

        // Step 1: Restore the base layer (with hole where selection was) from snapshot
        renderer.restoreSnapshot(snapshot, to: texture)

        // Step 2: Calculate the current position with offset and scale applied
        let currentRect = CGRect(
            x: originalRect.origin.x + selectionOffset.x,
            y: originalRect.origin.y + selectionOffset.y,
            width: originalRect.width * selectionScale.width,
            height: originalRect.height * selectionScale.height
        )

        // Step 3: Render the pixels at the new position (use documentSize for 1:1 coordinate mapping)
        renderer.renderImage(pixels, at: currentRect, to: texture, tileGrid: layers[selectedLayerIndex].tileGrid, screenSize: documentSize)
    }

    /// Commit the moved selection to finalize the change.
    ///
    /// During drag we never write to the layer texture — `floatingSelectionTexture`
    /// is composited on top each frame at `originalRect + offset`. Here we
    /// bake it back into the layer in a single GPU pass and then drop the
    /// floating texture.
    func commitSelection() {
        guard selectedLayerIndex < layers.count,
              let texture = layers[selectedLayerIndex].texture,
              let renderer = renderer,
              let beforeSnapshot = selectionBeforeSnapshot else {
            print("ERROR: Cannot commit selection - missing data")
            return
        }

        if let floating = floatingSelectionTexture, let originalRect = selectionOriginalRect {
            // Compute the final destination rect in doc space (offset + scale).
            // Layer currently has the source region cleared (extractSelectionPixels
            // did this), so source-over compositing into it produces exactly
            // "the moved selection placed where the user released."
            let finalRect = CGRect(
                x: originalRect.origin.x + selectionOffset.x,
                y: originalRect.origin.y + selectionOffset.y,
                width: originalRect.width * selectionScale.width,
                height: originalRect.height * selectionScale.height
            )
            renderer.compositeFloatingTextureIntoLayer(
                floating,
                into: texture,
                tileGrid: layers[selectedLayerIndex].tileGrid,
                atDocRect: finalRect,
                rotation: Float(selectionRotation.radians)
            )
        } else {
            // Fallback: floating texture wasn't built (e.g. extraction failed
            // to upload). Use the legacy CPU path so we still commit *something*
            // rather than losing the user's drag entirely.
            print("⚠️ Selection commit falling back to CPU composite (no floating texture)")
            renderSelectionInRealTime()
        }

        // Capture the current state as "after" for history
        let afterSnapshot = renderer.captureSnapshot(of: texture)

        // Record in history (before = original with pixels, after = current with pixels moved)
        if let after = afterSnapshot {
            let layerId = layers[selectedLayerIndex].id
            historyManager.record(.stroke(
                layerId: layerId,
                beforeSnapshot: beforeSnapshot,
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

        // Clear all selection data (pixels, rects, floating texture, etc.)
        clearSelection()
        print("✅ Selection committed to texture")
    }

    /// Throw away the active floating selection without baking it. Restores
    /// whatever the layer looked like before the selection was extracted /
    /// imported, then clears all selection state.
    /// (Wired to the Cancel pill in the toolbar overlay.)
    func cancelSelection() {
        if let renderer = renderer,
           selectedLayerIndex < layers.count,
           let texture = layers[selectedLayerIndex].texture,
           let beforeSnapshot = selectionBeforeSnapshot {
            renderer.restoreSnapshot(beforeSnapshot, to: texture)
        }
        clearSelection()
    }

    /// After a scale gesture ends, the floating texture has been bilinear-
    /// upscaled (or downsampled) by the shader, which looks soft for any
    /// large change. Resample from the original full-res source UIImage at
    /// the new displayed pixel size on a background thread; on completion,
    /// swap in the new texture if the user hasn't moved the goalposts.
    /// Must be called on the main actor; spawns Task.detached internally.
    func scheduleFloatingTextureResampleFromSource() {
        guard let source = selectionOriginalSource,
              let originalRect = selectionOriginalRect,
              let renderer = renderer else { return }

        let displayedW = max(1, originalRect.width  * selectionScale.width)
        let displayedH = max(1, originalRect.height * selectionScale.height)
        let target = CGSize(width: displayedW.rounded(), height: displayedH.rounded())

        nonisolated(unsafe) let unsafeRenderer = renderer
        nonisolated(unsafe) let unsafeSource = source
        Task.detached(priority: .userInitiated) {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.0
            format.opaque = false
            let cgRenderer = UIGraphicsImageRenderer(size: target, format: format)
            let resized = cgRenderer.image { _ in
                unsafeSource.draw(in: CGRect(origin: .zero, size: target))
            }
            guard let newTexture = unsafeRenderer.makeTexture(from: resized) else { return }
            await MainActor.run {
                // Bail if the user kept dragging in the meantime — applying a
                // resample at a stale size would make the texture briefly look
                // wrong before the next gesture-end resample replaces it.
                guard self.floatingSelectionTexture != nil,
                      let currentRect = self.selectionOriginalRect,
                      abs(currentRect.width  * self.selectionScale.width  - displayedW) < 1.0,
                      abs(currentRect.height * self.selectionScale.height - displayedH) < 1.0 else {
                    return
                }
                self.floatingSelectionTexture = newTexture
                self.selectionPixels = resized
            }
        }
    }

    /// Begin a move-tool whole-layer drag. Used when the user taps with the
    /// move tool and there's no prior rect/lasso selection: we want to drag
    /// the entire active layer. Unlike rect/lasso this skips extraction —
    /// the layer texture itself is what the shader translates during drag,
    /// and a single Metal blit moves the pixels on commit.
    func beginActiveLayerTranslation() {
        guard selectedLayerIndex < layers.count,
              let texture = layers[selectedLayerIndex].texture,
              let renderer = renderer else {
            print("ERROR: Cannot begin layer translation - invalid layer or texture")
            return
        }

        // Snapshot for undo/redo. No texture writes — the layer renders at
        // offset via the shader during drag.
        selectionBeforeSnapshot = renderer.captureSnapshot(of: texture)
        selectionOffset = .zero
        isTranslatingActiveLayer = true
    }

    /// Finalize a move-tool whole-layer drag. One GPU blit moves the bits;
    /// no per-pixel CPU work.
    func commitActiveLayerTranslation() {
        guard selectedLayerIndex < layers.count,
              let texture = layers[selectedLayerIndex].texture,
              let renderer = renderer,
              let beforeSnapshot = selectionBeforeSnapshot else {
            print("ERROR: Cannot commit layer translation - missing data")
            return
        }

        renderer.translateLayerTextureInPlace(texture, tileGrid: layers[selectedLayerIndex].tileGrid, byDocOffset: selectionOffset, screenSize: documentSize)

        let afterSnapshot = renderer.captureSnapshot(of: texture)
        if let after = afterSnapshot {
            let layerId = layers[selectedLayerIndex].id
            historyManager.record(.stroke(
                layerId: layerId,
                beforeSnapshot: beforeSnapshot,
                afterSnapshot: after
            ))
        }

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

        clearSelection()  // resets selectionOffset, isTranslatingActiveLayer, snapshots
        print("✅ Layer translation committed")
    }

    /// Apply scale and rotation transforms to a UIImage
    private func applyTransforms(to image: UIImage, scale: CGFloat, rotation: Angle) -> UIImage {
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        UIGraphicsBeginImageContextWithOptions(size, false, image.scale)
        defer { UIGraphicsEndImageContext() }

        guard let context = UIGraphicsGetCurrentContext() else { return image }

        // Move to center
        context.translateBy(x: size.width / 2, y: size.height / 2)

        // Apply rotation
        context.rotate(by: CGFloat(rotation.radians))

        // Draw image centered
        let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        image.draw(in: rect)

        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }

    /// Calculate bounding rectangle for a path
    func calculateBoundingRect(for path: [CGPoint]) -> CGRect {
        guard !path.isEmpty else { return .zero }

        var minX = path[0].x
        var minY = path[0].y
        var maxX = path[0].x
        var maxY = path[0].y

        for point in path {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Zoom and Pan Management

    // MARK: - Coordinate transforms
    //
    // These must be the exact inverse of the shader's vertex transform in
    // `quadVertexShaderWithTransform`. The shader does (pseudocode):
    //
    //   quadCornerNDC → aspectScaled → screenPos (Y-up pixels)
    //                 → zoomAroundCenter → rotateAroundCenter → screenPos += (pan.x, -pan.y)
    //                 → NDC
    //
    // With identity texCoords, every screen pixel inside the quad samples the
    // texture at the fraction of the quad it falls in. The math below is the
    // UIKit-space (Y-down) inverse of that pipeline. A single-number scale
    // `fitSize = min(viewport.w, viewport.h)` replaces the previous separate
    // aspectScale + canvasScale steps that were overshooting by 1/aspect.
    //
    // The previous implementation overshot doc coords by a factor of the
    // viewport aspect ratio on the longer axis — e.g. touching the right edge
    // of a pillarbox in landscape returned doc.x ≈ 2390 instead of 2048. That
    // was the "strokes offset consistently" symptom after Phase-1 fixes.

    /// Transform a point from view/screen space (UIKit points) to document space.
    func screenToDocument(_ point: CGPoint) -> CGPoint {
        guard point.x.isFinite, point.y.isFinite,
              screenSize.width > 0, screenSize.height > 0,
              documentSize.width > 0, documentSize.height > 0,
              zoomScale.isFinite, zoomScale > 0,
              panOffset.x.isFinite, panOffset.y.isFinite,
              canvasRotation.radians.isFinite else {
            return .zero
        }

        let fitSize = max(screenSize.width, screenSize.height)
        let centerX = screenSize.width / 2
        let centerY = screenSize.height / 2

        // Step 1 (Phase 0): inverse FLIP, applied FIRST in the inverse chain.
        // The forward render applies flip LAST in screen space (mirror around
        // viewport center); inverting that means we mirror the touch point
        // around viewport center BEFORE undoing pan/rotate/zoom. Flip is its
        // own inverse, so the same negation works in both directions.
        // Without this, a touch on the right side of a flipped canvas would
        // map to the right side of the document — but the user's finger is
        // visually over the LEFT side of the document because that's what
        // the flip-LAST render is showing under their finger.
        var sx = point.x
        var sy = point.y
        if flipHorizontal { sx = 2 * centerX - sx }
        if flipVertical   { sy = 2 * centerY - sy }

        // Inverse pan, then translate so (0,0) is the viewport center.
        var pt = CGPoint(x: sx - panOffset.x - centerX,
                         y: sy - panOffset.y - centerY)

        // Inverse rotation. The shader applies R(θ) in Y-up pixel space, which
        // reads as a visual CCW rotation by θ on screen. In UIKit Y-down math,
        // the forward matrix that produces visual CCW is R(-θ); the inverse is
        // therefore R(+θ) applied directly to Y-down coords:
        //   x' = x·cos(θ) - y·sin(θ)
        //   y' = x·sin(θ) + y·cos(θ)
        // The previous version had the signs of sinT swapped, which was the
        // cause of strokes "jumping" once any rotation was applied — my
        // screenToDocument was winding the point the wrong way.
        let theta = canvasRotation.radians
        let cosT = cos(theta)
        let sinT = sin(theta)
        let rx = pt.x * cosT - pt.y * sinT
        let ry = pt.x * sinT + pt.y * cosT

        // Inverse zoom (around viewport center, which is (0,0) here).
        let zx = rx / zoomScale
        let zy = ry / zoomScale

        // At this point (zx, zy) is the quad-local coordinate centered at origin,
        // ranging over [-fitSize/2, +fitSize/2] when the touch is inside the
        // aspect-corrected canvas region. Convert to normalized [0,1] fraction
        // and scale by document size.
        let fracX = (zx + fitSize / 2) / fitSize
        let fracY = (zy + fitSize / 2) / fitSize

        return CGPoint(x: fracX * documentSize.width,
                       y: fracY * documentSize.height)
    }

    /// Transform a point from document space to view/screen space (UIKit points).
    func documentToScreen(_ point: CGPoint) -> CGPoint {
        guard point.x.isFinite, point.y.isFinite,
              screenSize.width > 0, screenSize.height > 0,
              documentSize.width > 0, documentSize.height > 0,
              zoomScale.isFinite, zoomScale > 0,
              panOffset.x.isFinite, panOffset.y.isFinite,
              canvasRotation.radians.isFinite else {
            return .zero
        }

        let fitSize = max(screenSize.width, screenSize.height)
        let centerX = screenSize.width / 2
        let centerY = screenSize.height / 2

        // doc → normalized fraction → quad-local (centered) pixels.
        let fracX = point.x / documentSize.width
        let fracY = point.y / documentSize.height
        var pt = CGPoint(x: fracX * fitSize - fitSize / 2,
                         y: fracY * fitSize - fitSize / 2)

        // Zoom around origin (viewport center).
        pt.x *= zoomScale
        pt.y *= zoomScale

        // Rotate around origin. The shader rotates the quad visually CCW by θ
        // (it applies R(θ) in Y-up pixel space). To reproduce visual CCW in
        // UIKit Y-down, apply R(-θ):
        //   x' =  x·cos(θ) + y·sin(θ)
        //   y' = -x·sin(θ) + y·cos(θ)
        let theta = canvasRotation.radians
        let cosT = cos(theta)
        let sinT = sin(theta)
        let rx = pt.x * cosT + pt.y * sinT
        let ry = -pt.x * sinT + pt.y * cosT

        // Translate to viewport center, then apply pan.
        var sx = rx + centerX + panOffset.x
        var sy = ry + centerY + panOffset.y

        // Apply FLIP last in the forward chain (mirror around viewport
        // center). Pairs with the same flip applied as the LAST step in
        // the Metal shader (Shaders.metal: quadVertexShaderWithTransform
        // and quadVertexShaderForRect) so on-screen positions and
        // SwiftUI overlays (symmetry guides, marching ants, transform
        // handles) all agree on where flipped doc points render.
        if flipHorizontal { sx = 2 * centerX - sx }
        if flipVertical   { sy = 2 * centerY - sy }
        return CGPoint(x: sx, y: sy)
    }

    /// Apply zoom. `centerPoint` is the pinch location in screen space; currently only
    /// used for future zoom-around-point restoration.
    ///
    /// The previous implementation tried to adjust `panOffset` so the document point
    /// under `centerPoint` stayed fixed, but its math mixed document coordinates with
    /// screen coordinates:
    ///
    ///     panOffset += centerPoint − docPoint * zoomScale
    ///
    /// `docPoint` lives in a 0…2048 document-space range while `centerPoint` lives in a
    /// ~0…1366 screen-space range, so `centerPoint − docPoint*zoomScale` produced
    /// arbitrary values that, reapplied every frame at 60 Hz, grew `panOffset`
    /// roughly geometrically. This was the cause of the 10^48 → 10^121 coordinate
    /// explosion after any pinch on device.
    ///
    /// For now zoom happens around the screen center (no pan compensation). Zoom-to-
    /// pinch-point can be restored later with correct aspect/rotation-aware math.
    func zoom(scale: CGFloat, centerPoint: CGPoint) {
        guard scale.isFinite, scale > 0 else { return }
        guard centerPoint.x.isFinite, centerPoint.y.isFinite else { return }

        let newScale = min(max(scale, minZoom), maxZoom)
        guard newScale.isFinite, newScale > 0 else { return }

        zoomScale = newScale
    }

    /// Pan the canvas by a delta in screen space.
    ///
    /// Flip compensation: the rendering pipeline applies flip LAST in
    /// screen space (mirror around viewport center). Without input
    /// compensation, a positive panOffset.x on a horizontally-flipped
    /// canvas would translate the un-flipped content right, which the
    /// flip mirrors to a leftward visual move — drag-right would feel
    /// like drag-left. Inverting delta on each flipped axis makes the
    /// gesture feel natural while flipped: drag right → canvas-display
    /// moves right, regardless of flip state.
    func pan(delta: CGPoint) {
        guard delta.x.isFinite, delta.y.isFinite else { return }

        let dx = flipHorizontal ? -delta.x : delta.x
        let dy = flipVertical   ? -delta.y : delta.y

        panOffset.x += dx
        panOffset.y += dy

        // Hard clamp so a corrupted frame can't push panOffset to infinity. With a
        // 2048-pt canvas and max 10× zoom, legitimate pan stays well inside ±2×
        // document size; anything past that is runaway state.
        let maxPan = 2 * max(documentSize.width, documentSize.height)
        panOffset.x = min(max(panOffset.x, -maxPan), maxPan)
        panOffset.y = min(max(panOffset.y, -maxPan), maxPan)
    }

    /// Rotate the canvas by an angle increment.
    ///
    /// Flip compensation: a single mirror reverses orientation, so a CCW
    /// gesture under one active flip would visually appear as CW rotation
    /// without compensation. A double mirror (both flipH and flipV) is
    /// equivalent to a 180° rotation, which preserves orientation — no
    /// inversion needed in that case. Rule: invert when EXACTLY ONE flip
    /// is active (XOR of the two flags).
    func rotate(by angle: Angle, snapToGrid: Bool = true) {
        guard angle.radians.isFinite else { return }
        // Prevent rotation if change is negligible
        guard abs(angle.degrees) > 0.1 else { return }

        let invertForFlip = flipHorizontal != flipVertical
        let effectiveAngle = invertForFlip ? Angle(radians: -angle.radians) : angle

        var newRotation = canvasRotation + effectiveAngle

        // Normalize to 0-360° to prevent overflow
        newRotation = .degrees(newRotation.degrees.truncatingRemainder(dividingBy: 360))
        if newRotation.degrees < 0 {
            newRotation = .degrees(newRotation.degrees + 360)
        }

        // Snap to grid if enabled (typically only on gesture .ended; passing true here
        // during continuous rotation causes per-frame 15° ratcheting — see the gesture
        // handler comment for the bug this avoids).
        if snapToGrid && enableRotationSnapping {
            let snappedDegrees = round(newRotation.degrees / rotationSnappingInterval.degrees) * rotationSnappingInterval.degrees
            newRotation = .degrees(snappedDegrees)
        }

        canvasRotation = newRotation
    }

    /// Reset rotation to 0°
    func resetRotation() {
        canvasRotation = .zero
    }

    /// Reset zoom, pan, and rotation to defaults
    func resetZoomAndPan() {
        zoomScale = 1.0
        panOffset = .zero
        canvasRotation = .zero
    }

    /// Reset all transforms — zoom, pan, rotation, AND flips. The
    /// Recenter button calls this; the contract is "one tap returns
    /// the canvas to normal orientation, no matter what state it's in."
    func resetAllTransforms() {
        resetZoomAndPan()
        flipHorizontal = false
        flipVertical = false
    }

    /// Bake a horizontal flip into each visible layer's pixel data.
    /// Layer textures are mirrored about their horizontal center on the
    /// GPU; afterwards no display-time flip transform is needed. The op
    /// is recorded with the affected layer IDs so undo flips the same
    /// set even if visibility changes later. The `flipHorizontal` bool
    /// is left at its existing value (always `false` post-bake) — it's
    /// preserved for legacy callers that still gate on it, but it no
    /// longer drives any visible flip.
    func toggleFlipHorizontal() {
        applyFlipContent(flipH: true, flipV: false)
    }

    /// Bake a vertical flip into each visible layer's pixel data. See
    /// `toggleFlipHorizontal` for the rationale.
    func toggleFlipVertical() {
        applyFlipContent(flipH: false, flipV: true)
    }

    /// Apply a flip-content op to every currently-visible layer, record
    /// it on the history stack, and refresh thumbnails. Used by both
    /// the toggle entry points and the undo/redo handlers (flip is its
    /// own inverse — applying the same axis twice cancels).
    private func applyFlipContent(flipH: Bool, flipV: Bool, recordHistory: Bool = true) {
        guard let renderer = renderer else { return }
        guard flipH || flipV else { return }

        let affected = layers.filter { $0.isVisible && $0.texture != nil }
        guard !affected.isEmpty else { return }

        for layer in affected {
            guard let texture = layer.texture else { continue }
            renderer.flipLayerTextureInPlace(
                texture,
                tileGrid: layer.tileGrid,
                flipHorizontal: flipH,
                flipVertical: flipV
            )
        }

        if recordHistory {
            let layerIds = affected.map { $0.id }
            historyManager.record(.flipContent(
                layerIds: layerIds,
                flipH: flipH,
                flipV: flipV
            ))
        }

        // Refresh thumbnails for every flipped layer off the main thread,
        // mirroring the stroke-commit path. The mutation counter bump
        // below covers Metal redraws; thumbnails live on @Published
        // `DrawingLayer.thumbnail` and need their own regen.
        for layer in affected {
            guard let texture = layer.texture else { continue }
            let layerId = layer.id
            nonisolated(unsafe) let unsafeRenderer = renderer
            nonisolated(unsafe) let unsafeTexture = texture
            Task.detached {
                if let thumbnail = unsafeRenderer.generateThumbnail(
                    from: unsafeTexture,
                    size: CGSize(width: 44, height: 44)
                ) {
                    await MainActor.run {
                        if let l = self.layers.first(where: { $0.id == layerId }) {
                            l.updateThumbnail(thumbnail)
                        }
                    }
                }
            }
        }

        bumpLayerMutation()
    }

    /// Transform a rectangle from document space to screen space
    /// For rotated canvases, returns the bounding box of the transformed corners
    func documentRectToScreen(_ rect: CGRect) -> CGRect {
        // Transform all four corners
        let topLeft = documentToScreen(CGPoint(x: rect.minX, y: rect.minY))
        let topRight = documentToScreen(CGPoint(x: rect.maxX, y: rect.minY))
        let bottomLeft = documentToScreen(CGPoint(x: rect.minX, y: rect.maxY))
        let bottomRight = documentToScreen(CGPoint(x: rect.maxX, y: rect.maxY))

        // Find bounding box of transformed corners
        let minX = min(topLeft.x, topRight.x, bottomLeft.x, bottomRight.x)
        let minY = min(topLeft.y, topRight.y, bottomLeft.y, bottomRight.y)
        let maxX = max(topLeft.x, topRight.x, bottomLeft.x, bottomRight.x)
        let maxY = max(topLeft.y, topRight.y, bottomLeft.y, bottomRight.y)

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Transform a path from document space to screen space
    func documentPathToScreen(_ path: [CGPoint]) -> [CGPoint] {
        return path.map { documentToScreen($0) }
    }

    // MARK: - Blur Adjustment lifecycle
    //
    // Snapshot + preview-texture lifecycle is managed by the renderer; the
    // state manager owns the user-facing flags and the undo bridge.

    /// Activate the blur adjustment preview. Called when the tool is selected
    /// (via the toolChangeCancellable subscription).
    func beginBlurAdjustment() {
        guard !blurAdjustmentActive else { return }
        guard let renderer = renderer,
              let layer = layers[safe: selectedLayerIndex],
              let texture = layer.texture else {
            print("⚠️ beginBlurAdjustment: missing renderer or layer texture; skipping")
            return
        }
        blurAdjustmentSigma = 0.0
        renderer.beginBlurAdjustment(
            sourceTexture: texture,
            layerId: layer.id,
            selectionPath: selectionPath,
            documentSize: documentSize
        )
        blurAdjustmentActive = true
    }

    /// Update the preview sigma (called from the HUD scrubber touch handler).
    /// Clamps and dispatches a re-render of the preview texture.
    func setBlurAdjustmentSigma(_ sigma: Float) {
        let clamped = max(0, min(blurAdjustmentMaxSigma, sigma))
        blurAdjustmentSigma = clamped
        renderer?.updateBlurAdjustmentPreview(sigma: clamped)
    }

    /// ✓ button: blit the preview into the layer texture, record undo, then
    /// re-snapshot so the user can immediately stack another blur on top.
    /// Tool stays active per directive.
    func commitBlurAdjustment() {
        guard blurAdjustmentActive,
              let renderer = renderer,
              let layer = layers[safe: selectedLayerIndex],
              let texture = layer.texture else { return }
        let layerId = layer.id

        let beforeSnapshot = renderer.captureSnapshot(of: texture)
        renderer.commitBlurAdjustment(into: texture)
        let afterSnapshot = renderer.captureSnapshot(of: texture)

        if let before = beforeSnapshot, let after = afterSnapshot {
            historyManager.record(.stroke(
                layerId: layerId,
                beforeSnapshot: before,
                afterSnapshot: after
            ))
        }

        // Re-snapshot the now-committed layer state so subsequent drags blur
        // from the new baseline (allows stacking blurs).
        blurAdjustmentSigma = 0.0
        renderer.beginBlurAdjustment(
            sourceTexture: texture,
            layerId: layerId,
            selectionPath: selectionPath,
            documentSize: documentSize
        )

        // Update thumbnail off the main thread.
        let currentLayerIndex = selectedLayerIndex
        nonisolated(unsafe) let unsafeRenderer = renderer
        nonisolated(unsafe) let unsafeTexture = texture
        Task.detached {
            if let thumbnail = unsafeRenderer.generateThumbnail(from: unsafeTexture, size: CGSize(width: 44, height: 44)) {
                await MainActor.run {
                    if let l = self.layers[safe: currentLayerIndex] {
                        l.updateThumbnail(thumbnail)
                    }
                }
            }
        }
    }

    /// ✕ button: discard the current preview output, reset sigma to 0%.
    /// Layer texture is unchanged. Tool stays active.
    func cancelBlurAdjustment() {
        guard blurAdjustmentActive else { return }
        blurAdjustmentSigma = 0.0
        renderer?.updateBlurAdjustmentPreview(sigma: 0.0)
    }

    /// Tool deactivated: free GPU resources, hide HUD, drop preview.
    /// Called automatically when user switches away from .blurAdjustment.
    func endBlurAdjustment() {
        guard blurAdjustmentActive else { return }
        renderer?.endBlurAdjustment()
        blurAdjustmentSigma = 0.0
        blurAdjustmentActive = false
    }

    // MARK: - BrushSettings persistence (Phase 3, Color System Overhaul)
    //
    // Saves brushSettings to UserDefaults on every mutation; restores
    // on init. Pattern lifted from TextSettings (see TextSettings.swift
    // lines 156-173). Versioned key so a future schema break can ship
    // a v2 alongside v1 without overwriting.

    private static let brushSettingsKey = "DrawEvolve.BrushSettings.v1"

    static func loadBrushSettings() -> BrushSettings? {
        guard let data = UserDefaults.standard.data(forKey: brushSettingsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(BrushSettings.self, from: data)
    }

    fileprivate static func saveBrushSettings(_ settings: BrushSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: brushSettingsKey)
    }
}
