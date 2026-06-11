//
//  TypeBarView.swift
//  DrawEvolve
//
//  Keyboard-docked Type Bar — the controller for the Type tool session.
//
//  5.1 type-tool rework: the floating, draggable bar (with its own
//  keyboard-dodging slide, persisted position, and grab handle) is gone.
//  The bar now docks ABOVE the soft keyboard as the text editor's
//  inputAccessoryView — the standard pattern in Procreate / Notes — so it
//  can never fight the keyboard, the elevated-preview card, or the canvas
//  for the visible strip. It appears exactly when the keyboard does and
//  leaves with it.
//
//  Contents: row 1 = font pill + color swatch + checkmark (done typing);
//  row 2 = size slider + tracking slider. Same control set as the old
//  floating bar minus the grab handle (nothing to drag anymore). The
//  deeper inspector half-sheet (italic, kerning kind, manual kern,
//  on-path toggles) remains a future surface.
//
//  Settings bind straight to `canvasState.textSettings`; the existing
//  publisher sink propagates changes to the active FloatingText and
//  schedules the debounced re-rasterise, so the on-canvas text (visible
//  editor for plain text, rasterised preview for path text) updates live.
//
//  Hosting: `makeTypeBarAccessoryView` wraps the SwiftUI content in a
//  UIHostingController and returns its view, sized for
//  `UITextView.inputAccessoryView`. The hosting controller is retained
//  by an associated holder object on the returned view so it lives as
//  long as the accessory does.
//

import SwiftUI
import UIKit

/// Fixed accessory height. UIKit sizes inputAccessoryViews from their
/// frame height; width stretches to the keyboard via autoresizing.
let typeBarAccessoryHeight: CGFloat = 96

struct TypeBarAccessoryContent: View {
    @ObservedObject var canvasState: CanvasStateManager

    /// Tapped when the user is done with the typing portion of the Type
    /// session. Parent decides what that means — the float stays alive
    /// with transform handles; commit-to-layer happens on tap-outside.
    let onCheckmark: () -> Void

    @State private var showFontPickerPopover = false
    @State private var showColorPickerPopover = false

    private let families: [String] = UIFont.familyNames.sorted()

    var body: some View {
        VStack(spacing: 6) {
            row1
            row2
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .frame(height: typeBarAccessoryHeight)
        .background(
            Color(uiColor: .systemBackground)
                .overlay(Divider(), alignment: .top)
        )
    }

    // MARK: - Rows

    private var row1: some View {
        HStack(spacing: 8) {
            fontPill
            colorSwatch
            checkmarkButton
        }
    }

    private var row2: some View {
        HStack(spacing: 14) {
            sliderSnippet(label: "Size",
                          value: $canvasState.textSettings.size,
                          range: 1...500,
                          fmt: "%.0f",
                          unit: "pt",
                          labelWidth: 28,
                          valueWidth: 38)
            sliderSnippet(label: "Track",
                          value: $canvasState.textSettings.tracking,
                          range: -10...50,
                          fmt: "%.1f",
                          unit: nil,
                          labelWidth: 32,
                          valueWidth: 30)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Components

    private var fontPill: some View {
        Button { showFontPickerPopover = true } label: {
            HStack(spacing: 6) {
                Text(canvasState.textSettings.fontFamily)
                    .font(.custom(canvasState.textSettings.fontFamily, size: 14))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
        .popover(isPresented: $showFontPickerPopover) {
            fontPickerPopover
        }
    }

    private var colorSwatch: some View {
        Button { showColorPickerPopover = true } label: {
            Circle()
                .fill(Color(uiColor: canvasState.textSettings.color))
                .frame(width: 26, height: 26)
                .overlay(Circle().stroke(Color.gray.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showColorPickerPopover) {
            AdvancedColorPicker(selectedColor: $canvasState.textSettings.color)
                .frame(minWidth: 320, minHeight: 360)
                .padding()
                .presentationCompactAdaptation(.none)
        }
    }

    private var checkmarkButton: some View {
        Button(action: onCheckmark) {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 36, height: 28)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func sliderSnippet(label: String,
                               value: Binding<CGFloat>,
                               range: ClosedRange<CGFloat>,
                               fmt: String,
                               unit: String?,
                               labelWidth: CGFloat,
                               valueWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            Slider(value: value, in: range)
                .layoutPriority(1)
            Text(unit.map { String(format: "\(fmt) \($0)", value.wrappedValue) }
                  ?? String(format: fmt, value.wrappedValue))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }

    // MARK: - Font picker popover

    private var fontPickerPopover: some View {
        Form {
            Section("Family") {
                Picker("Family", selection: $canvasState.textSettings.fontFamily) {
                    ForEach(families, id: \.self) { family in
                        Text(family)
                            .font(.custom(family, size: 16))
                            .tag(family)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChange(of: canvasState.textSettings.fontFamily) { newFamily in
                    let faces = UIFont.fontNames(forFamilyName: newFamily)
                    if !faces.contains(canvasState.textSettings.fontFace) {
                        canvasState.textSettings.fontFace = faces.first ?? newFamily
                    }
                }
            }
            let faces = UIFont.fontNames(forFamilyName: canvasState.textSettings.fontFamily)
            if !faces.isEmpty {
                Section("Face") {
                    Picker("Face", selection: $canvasState.textSettings.fontFace) {
                        ForEach(faces, id: \.self) { face in
                            Text(face)
                                .font(.custom(face, size: 14))
                                .tag(face)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 340, minHeight: 420, idealHeight: 480)
        .presentationCompactAdaptation(.none)
    }
}

// MARK: - UIKit hosting

/// Retains the UIHostingController for the accessory's lifetime. The
/// accessory UIView is what UIKit holds; without this, the hosting
/// controller would deallocate and the SwiftUI content would freeze.
private final class TypeBarHostingHolder {
    let controller: UIHostingController<TypeBarAccessoryContent>
    init(controller: UIHostingController<TypeBarAccessoryContent>) {
        self.controller = controller
    }
}

private var typeBarHolderKey: UInt8 = 0

/// Build the keyboard-docked Type Bar for `UITextView.inputAccessoryView`.
/// Must be assigned BEFORE the text view becomes first responder or the
/// accessory won't dock.
@MainActor
func makeTypeBarAccessoryView(
    canvasState: CanvasStateManager,
    onCheckmark: @escaping () -> Void
) -> UIView {
    let host = UIHostingController(
        rootView: TypeBarAccessoryContent(
            canvasState: canvasState,
            onCheckmark: onCheckmark
        )
    )
    let view = host.view!
    view.frame = CGRect(x: 0, y: 0,
                        width: UIScreen.main.bounds.width,
                        height: typeBarAccessoryHeight)
    view.autoresizingMask = [.flexibleWidth]
    view.backgroundColor = .clear
    objc_setAssociatedObject(
        view, &typeBarHolderKey,
        TypeBarHostingHolder(controller: host),
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
    return view
}
