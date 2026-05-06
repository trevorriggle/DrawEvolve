//
//  GroupedToolButton.swift
//  DrawEvolve
//
//  Slot view for the iPad toolbar's grouped tool slots. Visually mirrors
//  the existing `ToolButton` styling (44x44, 8pt corner radius, accent-
//  color fill when active) and adds a disclosure triangle in the
//  bottom-right plus a long-press popover for variant selection.
//
//  This view does NOT wrap `Button` directly. SwiftUI's `Button` runs
//  its own internal tap recognizer that wins over a sibling
//  `.onLongPressGesture` — long-press never fires. To get reliable
//  tap + long-press composition we render the styled tile as a plain
//  View and attach `.onTapGesture` + `.onLongPressGesture` ourselves.
//  Accessibility traits are restored manually so the slot still
//  announces as a button.
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
        slotTile
            .contentShape(Rectangle())
            .onTapGesture {
                onActivate(currentVariant)
            }
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(group.name)
            .accessibilityValue(currentVariant.accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Double tap to activate. Long press to choose a variant.")
    }

    private var slotTile: some View {
        Image(systemName: currentVariant.icon)
            .font(.system(size: 22))
            .foregroundColor(slotIsSelected ? .white : .primary)
            .frame(width: 44, height: 44)
            .background(slotIsSelected ? Color.accentColor : Color.clear)
            .cornerRadius(8)
            .overlay(alignment: .bottomTrailing) {
                DisclosureCornerTriangle()
                    .fill(slotIsSelected ? Color.white : Color.primary)
                    .frame(width: 6, height: 6)
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
                    .allowsHitTesting(false)
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
