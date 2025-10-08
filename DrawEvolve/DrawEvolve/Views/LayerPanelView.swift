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

    var body: some View {
        List {
            ForEach(Array(layers.enumerated().reversed()), id: \.element.id) { index, layer in
                Button(action: {
                    selectedIndex = layers.count - 1 - index
                }) {
                    LayerRow(
                        layer: layer,
                        isSelected: selectedIndex == (layers.count - 1 - index)
                    )
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if layers.count > 1 {
                        Button(role: .destructive) {
                            onDeleteLayer(layers.count - 1 - index)
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
                        .foregroundColor(.secondary)

                    Text(layer.blendMode.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
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
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
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
            onDeleteLayer: { _ in }
        )
        .navigationTitle("Layers")
    }
}
