//
//  LayerPanelView.swift
//  DrawEvolve
//
//  Layer management panel.
//

import SwiftUI

struct LayerPanelView: View {
    @Binding var layers: [DrawingLayer]
    @Binding var selectedIndex: Int
    let onAddLayer: () -> Void
    let onDeleteLayer: (Int) -> Void
    let onMoveLayer: (Int, Int) -> Void
    /// Eyeball-tap path. Routed through CanvasStateManager so the
    /// canvas actually redraws (see toggleLayerVisibility's doc).
    let onToggleVisibility: (Int) -> Void
    /// Lock-tap path. Routed through CanvasStateManager so the toggle
    /// records one undo entry (same reasoning as onToggleVisibility above).
    let onToggleLock: (Int) -> Void
    let onBeginOpacityDrag: (Int) -> Void
    /// Fires on EVERY slider value change during a drag (not just at
    /// begin/end). Routed to CanvasStateManager.bumpLayerMutation() so
    /// the canvas redraws live as the user drags. Without this, the
    /// slider writes directly to DrawingLayer.opacity (a @Published on
    /// the layer class), which doesn't publish on CanvasStateManager,
    /// so the render-on-demand MTKView never gets setNeedsDisplay()
    /// until drag-end's history-record cascade fires. Same pattern as
    /// onToggleVisibility above — see toggleLayerVisibility's doc.
    let onOpacityChanged: (Int) -> Void
    let onEndOpacityDrag: (Int) -> Void
    let onBeginRename: (Int) -> Void
    let onCommitRename: (Int) -> Void
    @ObservedObject var poseManager: PoseOverlayManager

    // Per-row expand state. Resets on view dismiss (transient).
    @State private var expandedLayerIds: Set<UUID> = []

    // Long-press-drag-to-reorder state. Only attached to real layer rows —
    // pose ghost rows aren't reorderable.
    @State private var draggingLayerId: UUID? = nil
    @State private var dragTranslation: CGFloat = 0

    @State private var pendingPoseDiscard: PoseSkeletonKind?

    // Live row-height measurement (collapsed). Seeded with a sane default so
    // pre-measurement drags still work; PreferenceKey converges on the real
    // height as soon as the first row renders.
    @State private var measuredRowHeight: CGFloat = 60
    private let rowSpacing: CGFloat = 6

    var body: some View {
        ScrollView {
            LazyVStack(spacing: rowSpacing) {
                // Pose ghost rows pinned at the top — read-only references,
                // not part of the reorderable layer stack.
                ForEach(poseManager.activeSkeletons.map(\.kind)) { kind in
                    PoseGhostRow(
                        kind: kind,
                        state: poseManager.state(for: kind),
                        onToggleVisibility: {
                            let visible = poseManager.state(for: kind).isVisible
                            poseManager.setVisible(!visible, for: kind)
                        },
                        onDismiss: {
                            if poseManager.hasManualEdits(for: kind) {
                                pendingPoseDiscard = kind
                            } else {
                                poseManager.discard(kind)
                            }
                        }
                    )
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // Reverse so the visual top of the panel matches the top of
                // the layer stack (Procreate-style). Index is the original
                // bottom-up array index — the same value used everywhere
                // else in CanvasStateManager.
                ForEach(Array(layers.enumerated().reversed()), id: \.element.id) { (index: Int, layer: DrawingLayer) in
                    rowView(index: index, layer: layer)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: draggingLayerId)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: expandedLayerIds)
        }
        // Lock the ScrollView while a row is picked up so its pan recognizer
        // can't steal the drag mid-gesture and so the underlying scroll
        // position doesn't shift under the user's finger (which would skew
        // the drop math). Released as soon as the row drops.
        .scrollDisabled(draggingLayerId != nil)
        .onPreferenceChange(CollapsedRowHeightKey.self) { value in
            // Ignore the seed value (.infinity) and any stray zero readings.
            if value.isFinite && value > 0 {
                measuredRowHeight = value
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: onAddLayer) {
                    Image(systemName: "plus")
                }
            }
        }
        .alert(
            "Discard pose reference?",
            isPresented: Binding(
                get: { pendingPoseDiscard != nil },
                set: { if !$0 { pendingPoseDiscard = nil } }
            ),
            presenting: pendingPoseDiscard
        ) { kind in
            Button("Discard", role: .destructive) {
                poseManager.discard(kind)
                pendingPoseDiscard = nil
            }
            Button("Cancel", role: .cancel) { pendingPoseDiscard = nil }
        } message: { _ in
            Text("You've manually moved joints. Discarding can't be undone.")
        }
    }

    @ViewBuilder
    private func rowView(index: Int, layer: DrawingLayer) -> some View {
        let isDragging = draggingLayerId == layer.id
        let displacement = displacementOffset(for: index, layer: layer)
        let isExpanded = expandedLayerIds.contains(layer.id)
        // Hoisted from inline so the .gesture(...) modifier below can
        // read it for the GestureMask.
        let isSelected = selectedIndex == index

        LayerRow(
            layer: layer,
            isSelected: isSelected,
            isExpanded: isExpanded,
            isDragging: isDragging,
            isOnlyLayer: layers.count <= 1,
            onTapRow: {
                // Suppress selection-tap during an active reorder — the
                // drop handler resets draggingLayerId, so a tap after a
                // clean drop won't be suppressed. Guards against an
                // interleaved tap firing mid-drag and stealing the
                // selection.
                guard draggingLayerId != layer.id else { return }
                selectedIndex = index
            },
            onToggleVisibility: { onToggleVisibility(index) },
            onToggleLock: { onToggleLock(index) },
            onToggleExpand: {
                if expandedLayerIds.contains(layer.id) {
                    expandedLayerIds.remove(layer.id)
                } else {
                    expandedLayerIds.insert(layer.id)
                }
            },
            onBeginOpacityDrag: { onBeginOpacityDrag(index) },
            onOpacityChanged: { onOpacityChanged(index) },
            onEndOpacityDrag: { onEndOpacityDrag(index) },
            onBeginRename: { onBeginRename(index) },
            onCommitRename: { onCommitRename(index) },
            onDelete: { onDeleteLayer(index) }
        )
        // Only collapsed rows contribute to the measured row height — see
        // CollapsedRowHeightKey for why.
        .background(rowHeightProbe(isExpanded: isExpanded))
        .offset(y: isDragging ? dragTranslation : displacement)
        .scaleEffect(isDragging ? 1.02 : 1.0)
        .shadow(color: isDragging ? Color.black.opacity(0.25) : .clear,
                radius: isDragging ? 8 : 0,
                x: 0,
                y: isDragging ? 4 : 0)
        .opacity(isDragging ? 0.95 : 1.0)
        .zIndex(isDragging ? 1 : 0)
        // Row-body reorder. GestureMask gates the entire gesture on
        // selection: `.all` while selected (drag is live), `.subviews`
        // otherwise (drag is fully off — touches fall through to the
        // row's onTapGesture and the child Buttons). The mask flips
        // without rebuilding the view, so view identity stays stable
        // across selection changes. minimumDistance: 10 keeps quick
        // button taps from being read as drags.
        .gesture(
            rowReorderGesture(index: index, layer: layer),
            including: isSelected ? .all : .subviews
        )
    }

    @ViewBuilder
    private func rowHeightProbe(isExpanded: Bool) -> some View {
        if isExpanded {
            Color.clear
        } else {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: CollapsedRowHeightKey.self,
                                value: proxy.size.height)
            }
        }
    }

    /// Compute the y-offset to shift a non-dragging row to make room for the
    /// dragging row. Rows visually between the source and the projected drop
    /// position shift by one row-stride; everything else stays put.
    ///
    /// This math has survived two gesture rewrites — first the LongPress-
    /// sequenced row gesture, then a dedicated grab handle on the selected
    /// row, now a row-body DragGesture gated via GestureMask on isSelected.
    /// The inputs (draggingLayerId, dragTranslation, layer index) are the
    /// same in every case; the reversed-visual-order math is independent
    /// of which gesture sets dragTranslation. The function's uniform-row-
    /// stride assumption still holds because rowReorderGesture collapses
    /// all expanded rows on pickup. Kept (not deleted) because "shift the
    /// visually-between rows" is the same problem regardless of how the
    /// drag was initiated.
    private func displacementOffset(for index: Int, layer: DrawingLayer) -> CGFloat {
        guard let draggingId = draggingLayerId,
              let draggingIndex = layers.firstIndex(where: { $0.id == draggingId }),
              draggingId != layer.id else { return 0 }

        let stride = measuredRowHeight + rowSpacing
        // Visual position in the reversed list (0 = topmost).
        let visualDragOrigin = layers.count - 1 - draggingIndex
        let myVisualPos = layers.count - 1 - index
        let rowsMoved = Int((dragTranslation / stride).rounded())
        let visualDragTarget = max(0, min(layers.count - 1, visualDragOrigin + rowsMoved))

        if rowsMoved > 0 && myVisualPos > visualDragOrigin && myVisualPos <= visualDragTarget {
            return -stride
        }
        if rowsMoved < 0 && myVisualPos < visualDragOrigin && myVisualPos >= visualDragTarget {
            return stride
        }
        return 0
    }

    /// Row-body reorder gesture. Attached at the row level (not on a
    /// child handle) with `.gesture(_:, including:)` masked on
    /// `isSelected` so unselected rows can't initiate a drag — touches
    /// there fall through to the row's onTapGesture (which selects the
    /// row) and the eye / lock / chevron Buttons (which fire normally).
    /// minimumDistance: 10 keeps button-tap finger jitter (typically
    /// <10pt) from being misread as a drag.
    ///
    /// Pickup state (`draggingLayerId`, `dragTranslation`) and the drop
    /// math live here because they're owned by LayerPanelView's @State —
    /// LayerRow is unaware of the drag.
    private func rowReorderGesture(index: Int, layer: DrawingLayer) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                // "First call of an active drag" detected by
                // draggingLayerId == nil. Collapse expanded rows on
                // pickup so displacementOffset's uniform-row-stride
                // assumption holds.
                if draggingLayerId == nil {
                    draggingLayerId = layer.id
                    expandedLayerIds.removeAll()
                }
                if draggingLayerId == layer.id {
                    dragTranslation = value.translation.height
                }
            }
            .onEnded { value in
                guard draggingLayerId == layer.id else { return }
                defer {
                    draggingLayerId = nil
                    dragTranslation = 0
                }
                let stride = measuredRowHeight + rowSpacing
                let rowsMovedVisually = Int((value.translation.height / stride).rounded())
                guard rowsMovedVisually != 0 else { return }
                // Reversed display: dragging visually DOWN (positive y)
                // means moving toward the bottom of the stack = lower
                // array index.
                let targetArrayIndex = max(0, min(layers.count - 1, index - rowsMovedVisually))
                guard targetArrayIndex != index else { return }
                // moveLayer(from:to:) interprets `to` as a pre-removal
                // insertion point: target+1 when moving up the array
                // (so the post-removal insert lands at `target`); plain
                // target when moving down.
                let destIndex = targetArrayIndex > index ? targetArrayIndex + 1 : targetArrayIndex
                onMoveLayer(index, destIndex)
            }
    }

}

/// Captures the actual rendered height of a collapsed layer row. Reduced
/// with `min` so an expanded row's larger height never overwrites the
/// collapsed measurement; the seed of `.infinity` makes the first real
/// reading win immediately.
private struct CollapsedRowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = min(value, next)
        }
    }
}

/// Ghost row pinned at the top of the layer list when a skeleton is
/// active. Visually distinguished from real layer rows: italic name,
/// muted fill, no opacity / blend / alpha-lock controls.
private struct PoseGhostRow: View {
    let kind: PoseSkeletonKind
    let state: PoseOverlayManager.SlotState
    let onToggleVisibility: () -> Void
    let onDismiss: () -> Void

    private var isVisible: Bool { state.isVisible }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleVisibility) {
                Image(systemName: isVisible ? "eye.fill" : "eye.slash.fill")
                    .foregroundColor(isVisible ? .accentColor : .secondary)
            }
            .buttonStyle(.borderless)

            Image(systemName: kind.icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayLabel)
                    .font(.subheadline.weight(.medium))
                    .italic()
                    .foregroundColor(.primary)
                Text("Reference overlay — not saved with the drawing")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss \(kind.displayLabel)")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }
}

private struct LayerRow: View {
    @ObservedObject var layer: DrawingLayer
    let isSelected: Bool
    let isExpanded: Bool
    let isDragging: Bool
    let isOnlyLayer: Bool
    let onTapRow: () -> Void
    /// Eyeball-tap. Routed to CanvasStateManager.toggleLayerVisibility
    /// so the canvas redraws (see the comment on that method).
    let onToggleVisibility: () -> Void
    /// Lock-tap. Routed to CanvasStateManager.toggleLayerLock so the
    /// toggle records one undo entry.
    let onToggleLock: () -> Void
    let onToggleExpand: () -> Void
    let onBeginOpacityDrag: () -> Void
    /// Fires on every slider value change. See the doc on
    /// LayerPanelView.onOpacityChanged for why we need a continuous
    /// callback rather than relying on the begin/end drag hooks alone.
    let onOpacityChanged: () -> Void
    let onEndOpacityDrag: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onDelete: () -> Void

    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedBar
            if isExpanded {
                expandedSection
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { onTapRow() }
        .onChange(of: nameFieldFocused) { focused in
            if focused {
                onBeginRename()
            } else {
                onCommitRename()
            }
        }
    }

    private var rowBackground: some View {
        Group {
            if isSelected {
                Color.accentColor.opacity(0.18)
            } else {
                Color(.secondarySystemGroupedBackground)
            }
        }
    }

    private var collapsedBar: some View {
        HStack(spacing: 10) {
            Button(action: onToggleVisibility) {
                Image(systemName: layer.isVisible ? "eye.fill" : "eye.slash.fill")
                    .foregroundColor(layer.isVisible ? .primary : .secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            thumbnail

            VStack(alignment: .leading, spacing: 2) {
                Text(layer.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(Int(layer.opacity * 100))% · \(layer.blendMode.rawValue)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            Button(action: onToggleLock) {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                    .foregroundColor(layer.isLocked ? .red : .secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Button(action: onToggleExpand) {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(isExpanded ? .degrees(90) : .zero)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let thumbnail = layer.thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "photo")
                        .foregroundColor(.gray)
                )
        }
    }

    /// Inline controls revealed when the chevron is tapped. Opacity is
    /// available on any row (selection-independent) so a user can dim
    /// layer 3 without giving up their active draw target on layer 1.
    /// Name and Delete are gated on `isSelected` because they're
    /// destructive or identity-mutating — actions that should require
    /// the deliberate "I'm working on this layer right now" gesture
    /// that selection represents.
    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
                .padding(.top, 8)

            if isSelected {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Name")
                            .font(.caption2.weight(.medium))
                            .foregroundColor(.secondary)
                        if !nameFieldFocused {
                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.6))
                                .transition(.opacity)
                        }
                    }
                    TextField("Layer name", text: $layer.name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFieldFocused)
                        .submitLabel(.done)
                        .onSubmit { nameFieldFocused = false }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Opacity")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(layer.opacity * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { layer.opacity },
                        set: { newValue in
                            layer.opacity = newValue
                            // Wake the canvas — DrawingLayer.@Published
                            // doesn't propagate to CanvasStateManager on
                            // its own, so without this the MTKView won't
                            // see setNeedsDisplay until drag-end's
                            // history cascade fires.
                            onOpacityChanged()
                        }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if editing {
                            onBeginOpacityDrag()
                        } else {
                            onEndOpacityDrag()
                        }
                    }
                )
            }

            if isSelected && !isOnlyLayer {
                Button(action: onDelete) {
                    Label("Delete layer", systemImage: "trash")
                        .font(.subheadline)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }
        }
        .padding(.bottom, 4)
    }
}

#Preview {
    NavigationView {
        LayerPanelView(
            layers: .constant([
                DrawingLayer(name: "Background"),
                DrawingLayer(name: "Sketch"),
                DrawingLayer(name: "Lines")
            ]),
            selectedIndex: .constant(1),
            onAddLayer: {},
            onDeleteLayer: { _ in },
            onMoveLayer: { _, _ in },
            onToggleVisibility: { _ in },
            onToggleLock: { _ in },
            onBeginOpacityDrag: { _ in },
            onOpacityChanged: { _ in },
            onEndOpacityDrag: { _ in },
            onBeginRename: { _ in },
            onCommitRename: { _ in },
            poseManager: PoseOverlayManager()
        )
        .navigationTitle("Layers")
    }
}

