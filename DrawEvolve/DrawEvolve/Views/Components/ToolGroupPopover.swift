//
//  ToolGroupPopover.swift
//  DrawEvolve
//
//  Horizontal variant picker shown on long-press of a `GroupedToolButton`.
//  Styling per the locked spec: rounded-rect with .regularMaterial bg,
//  0.5pt separator-color border, 12pt corner radius, soft shadow, 6pt
//  inner padding around a 4pt-spacing HStack of 44x44 tiles. The
//  currently-selected variant gets an accent-color fill; others are
//  transparent. Tap dismisses via the parent's onPick callback.
//

import SwiftUI

struct ToolGroupPopover: View {
    let group: ToolGroup
    let currentVariant: ToolVariant
    let onPick: (ToolVariant) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(group.variants, id: \.self) { variant in
                Button(action: { onPick(variant) }) {
                    Image(systemName: variant.icon)
                        .font(.system(size: 22))
                        .foregroundColor(variant == currentVariant ? .white : .primary)
                        .frame(width: 44, height: 44)
                        .background(variant == currentVariant ? Color.accentColor : Color.clear)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(variant.accessibilityLabel)
            }
        }
        .padding(6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
        .animation(.easeInOut(duration: 0.15), value: currentVariant)
    }
}
