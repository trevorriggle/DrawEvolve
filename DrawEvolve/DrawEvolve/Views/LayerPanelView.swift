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
    let onBeginOpacityDrag: (Int) -> Void
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

    // Used both for the drag-displacement math and as a visual rhythm.
    // Chosen by eyeballing the collapsed row + spacing; if you change row
    // padding, adjust here so drop-target math still lines up.
    private let collapsedRowHeight: CGFloat = 60
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

        LayerRow(
            layer: layer,
            isSelected: selectedIndex == index,
            isExpanded: expandedLayerIds.contains(layer.id),
            isDragging: isDragging,
            isOnlyLayer: layers.count <= 1,
            onTapRow: { selectedIndex = index },
            onToggleExpand: {
                if expandedLayerIds.contains(layer.id) {
                    expandedLayerIds.remove(layer.id)
                } else {
                    expandedLayerIds.insert(layer.id)
                }
            },
            onBeginOpacityDrag: { onBeginOpacityDrag(index) },
            onEndOpacityDrag: { onEndOpacityDrag(index) },
            onBeginRename: { onBeginRename(index) },
            onCommitRename: { onCommitRename(index) },
            onDelete: { onDeleteLayer(index) }
        )
        .offset(y: isDragging ? dragTranslation : displacement)
        .scaleEffect(isDragging ? 1.02 : 1.0)
        .shadow(color: isDragging ? Color.black.opacity(0.25) : .clear,
                radius: isDragging ? 8 : 0,
                x: 0,
                y: isDragging ? 4 : 0)
        .opacity(isDragging ? 0.95 : 1.0)
        .zIndex(isDragging ? 1 : 0)
        .gesture(longPressDragGesture(index: index, layer: layer))
    }

    /// Compute the y-offset to shift a non-dragging row to make room for the
    /// dragging row. Rows visually between the source and the projected drop
    /// position shift by one row-stride; everything else stays put.
    private func displacementOffset(for index: Int, layer: DrawingLayer) -> CGFloat {
        guard let draggingId = draggingLayerId,
              let draggingIndex = layers.firstIndex(where: { $0.id == draggingId }),
              draggingId != layer.id else { return 0 }

        let stride = collapsedRowHeight + rowSpacing
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

    private func longPressDragGesture(index: Int, layer: DrawingLayer) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                switch value {
                case .first(true):
                    if draggingLayerId == nil {
                        draggingLayerId = layer.id
                        // Collapse expanded rows so heights stay uniform —
                        // otherwise the displacement math (which assumes a
                        // single row stride) lies and rows snap to wrong slots.
                        expandedLayerIds.removeAll()
                    }
                case .second(true, let drag):
                    if let drag = drag {
                        dragTranslation = drag.translation.height
                    }
                default:
                    break
                }
            }
            .onEnded { value in
                defer {
                    draggingLayerId = nil
                    dragTranslation = 0
                }
                guard draggingLayerId == layer.id else { return }
                guard case .second(true, let drag?) = value else { return }

                let stride = collapsedRowHeight + rowSpacing
                let rowsMovedVisually = Int((drag.translation.height / stride).rounded())
                guard rowsMovedVisually != 0 else { return }

                // Reversed display: dragging visually DOWN (positive y) means
                // moving toward the bottom of the stack = lower array index.
                let targetArrayIndex = max(0, min(layers.count - 1, index - rowsMovedVisually))
                guard targetArrayIndex != index else { return }

                // moveLayer(from:to:) interprets `to` as a pre-removal
                // insertion point. To land at `targetArrayIndex` in the
                // final array: when moving up the array (target > source),
                // dest is target+1 so insertAt = target after the remove
                // shifts everything down. When moving down, dest = target.
                let destIndex = targetArrayIndex > index ? targetArrayIndex + 1 : targetArrayIndex
                onMoveLayer(index, destIndex)
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
            .buttonStyle(.plain)

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
            .buttonStyle(.plain)
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
    let onToggleExpand: () -> Void
    let onBeginOpacityDrag: () -> Void
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
            Button(action: { layer.isVisible.toggle() }) {
                Image(systemName: layer.isVisible ? "eye.fill" : "eye.slash.fill")
                    .foregroundColor(layer.isVisible ? .primary : .secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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

            Button(action: { layer.isLocked.toggle() }) {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                    .foregroundColor(layer.isLocked ? .red : .secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onToggleExpand) {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(isExpanded ? .degrees(90) : .zero)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
                .padding(.top, 8)

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
                    value: $layer.opacity,
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

            if !isOnlyLayer {
                Button(action: onDelete) {
                    Label("Delete layer", systemImage: "trash")
                        .font(.subheadline)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
            onBeginOpacityDrag: { _ in },
            onEndOpacityDrag: { _ in },
            onBeginRename: { _ in },
            onCommitRename: { _ in },
            poseManager: PoseOverlayManager()
        )
        .navigationTitle("Layers")
    }
}
