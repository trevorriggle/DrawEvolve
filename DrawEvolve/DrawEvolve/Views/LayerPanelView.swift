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
    /// Optional pose-overlay manager — when present, the panel shows a
    /// pinned ghost row at the top for each active skeleton (Decision 6).
    /// Optional so callers that don't need pose UI (previews, future
    /// surfaces) can omit it without changing the call signature.
    @ObservedObject var poseManager: PoseOverlayManager
    @State private var pendingPoseDiscard: PoseSkeletonKind?

    var body: some View {
        List {
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
                .listRowBackground(Color(uiColor: .secondarySystemBackground))
                .listRowSeparator(.visible)
            }

            ForEach(Array(layers.enumerated().reversed()), id: \.element.id) { index, layer in
                Button(action: {
                    // index already has the correct layer index from enumerated()
                    print("🎯 Layer tapped: '\(layer.name)' at index \(index) - Setting selectedIndex to \(index)")
                    selectedIndex = index
                }) {
                    LayerRow(
                        layer: layer,
                        isSelected: selectedIndex == index
                    )
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if layers.count > 1 {
                        Button(role: .destructive) {
                            print("🗑️ Deleting layer at index \(index)")
                            onDeleteLayer(index)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
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
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }
}

struct LayerRow: View {
    @ObservedObject var layer: DrawingLayer
    let isSelected: Bool

    var body: some View {
        HStack {
            // Visibility toggle
            Button(action: { layer.isVisible.toggle() }) {
                Image(systemName: layer.isVisible ? "eye.fill" : "eye.slash.fill")
                    .foregroundColor(layer.isVisible ? .primary : .secondary)
            }
            .buttonStyle(.plain)

            // Layer preview thumbnail
            Group {
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

            // Layer info
            VStack(alignment: .leading, spacing: 4) {
                Text(layer.name)
                    .font(.subheadline.weight(.medium))

                HStack(spacing: 8) {
                    Text("Opacity: \(Int(layer.opacity * 100))%")
                        .font(.caption)
                        .foregroundColor(.primary)

                    Text(layer.blendMode.rawValue)
                        .font(.caption)
                        .foregroundColor(.primary)
                }
            }

            Spacer()

            // Lock toggle
            Button(action: { layer.isLocked.toggle() }) {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                    .foregroundColor(layer.isLocked ? .red : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
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
            poseManager: PoseOverlayManager()
        )
        .navigationTitle("Layers")
    }
}
