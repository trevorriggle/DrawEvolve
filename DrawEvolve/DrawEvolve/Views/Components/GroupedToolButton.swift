//
//  GroupedToolButton.swift
//  DrawEvolve
//
//  Slot view for the iPad toolbar's grouped tool slots. Wraps the
//  existing `ToolButton` so visual styling stays in one place, then
//  layers on a disclosure triangle in the bottom-right corner and a
//  long-press popover that lets the user pick a different variant.
//

import SwiftUI

struct GroupedToolButton: View {
    let group: ToolGroup
    let isSelected: (ToolVariant) -> Bool
    let onActivate: (ToolVariant) -> Void

    @AppStorage private var currentVariantString: String
    @State private var showPopover = false

    init(
        group: ToolGroup,
        isSelected: @escaping (ToolVariant) -> Bool,
        onActivate: @escaping (ToolVariant) -> Void
    ) {
        self.group = group
        self.isSelected = isSelected
        self.onActivate = onActivate
        self._currentVariantString = AppStorage(
            wrappedValue: group.defaultVariant.storageString,
            group.storageKey
        )
    }

    private var currentVariant: ToolVariant {
        ToolVariant(storageString: currentVariantString) ?? group.defaultVariant
    }

    private var slotIsSelected: Bool {
        isSelected(currentVariant)
    }

    var body: some View {
        ToolButton(icon: currentVariant.icon, isSelected: slotIsSelected) {
            onActivate(currentVariant)
        }
        .overlay(alignment: .bottomTrailing) {
            DisclosureCornerTriangle()
                .fill(slotIsSelected ? Color.white : Color.primary)
                .frame(width: 6, height: 6)
                .padding(.trailing, 4)
                .padding(.bottom, 4)
                .allowsHitTesting(false)
        }
        .accessibilityLabel(group.name)
        .accessibilityValue(currentVariant.accessibilityLabel)
        .onLongPressGesture(minimumDuration: 0.5) {
            showPopover = true
        }
        .popover(
            isPresented: $showPopover,
            attachmentAnchor: .point(.trailing),
            arrowEdge: .leading
        ) {
            ToolGroupPopover(
                group: group,
                currentVariant: currentVariant,
                onPick: { picked in
                    currentVariantString = picked.storageString
                    showPopover = false
                    onActivate(picked)
                }
            )
        }
    }
}

/// Right-angle disclosure indicator. Right-angle vertex sits at the
/// bottom-right of the shape's frame; hypotenuse runs from top-right to
/// bottom-left. Sized 6×6 in use, then inset 4pt off the trailing /
/// bottom edges so the triangle sits just inside the button's 8pt
/// corner curve regardless of selection state.
private struct DisclosureCornerTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
