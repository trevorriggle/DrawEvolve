//
//  TypeInspectorView.swift
//  DrawEvolve
//
//  Inline inspector that auto-presents whenever a FloatingText is active.
//  Replaces the modal TextSettingsView sheet retired in the Tier-1 type-
//  tools UX overhaul. The canvas itself is the live preview now, so this
//  view deliberately does NOT include a separate preview row — every
//  control updates the active float's settings via the existing Combine
//  sink in CanvasStateManager.
//
//  Hosting: DrawingCanvasView mounts this in a 280pt right-edge column
//  on iPad landscape and in a `.sheet` with `.presentationDetents` on
//  iPad portrait / iPhone. The view itself is layout-agnostic.
//

import SwiftUI
import UIKit

struct TypeInspectorView: View {
    @Binding var settings: TextSettings

    @ObservedObject var canvasState: CanvasStateManager

    /// Cached at init — `UIFont.familyNames` allocates on every call.
    private let families: [String] = UIFont.familyNames.sorted()

    @State private var manualKerningValue: CGFloat = 0
    @State private var showFontPickerPopover = false
    @State private var showColorPickerPopover = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    topRow
                    Divider()
                    middleRow
                    if let ft = canvasState.floatingText, ft.path != nil {
                        Divider()
                        pathRow(ft: ft)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            footer
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear {
            if case .manual(let v) = settings.kerning {
                manualKerningValue = v
            }
        }
    }

    // MARK: - Top row

    private var topRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            fontFamilyPill
            HStack(spacing: 16) {
                sizeStepper
                Spacer(minLength: 8)
                colorSwatch
            }
            alignmentPicker
        }
    }

    private var fontFamilyPill: some View {
        Button {
            showFontPickerPopover = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "textformat")
                Text(displayFamilyName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showFontPickerPopover) {
            fontFamilyPickerPopover
        }
    }

    private var sizeStepper: some View {
        // Step 2 keeps tap-count reasonable across the 1-500 range; users
        // doing big changes drag the float's corner handle (which bakes
        // into settings.size on lift) rather than mashing the stepper.
        Stepper(value: $settings.size, in: 1...500, step: 2) {
            HStack(spacing: 6) {
                Text("Size")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(String(format: "%.0f pt", settings.size))
                    .monospacedDigit()
            }
        }
        .labelsHidden()
        .overlay(
            HStack(spacing: 6) {
                Text("Size")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(String(format: "%.0f pt", settings.size))
                    .monospacedDigit()
                Spacer()
            }
            .allowsHitTesting(false)
            .padding(.trailing, 100)
        )
    }

    private var colorSwatch: some View {
        Button {
            showColorPickerPopover = true
        } label: {
            Circle()
                .fill(Color(uiColor: settings.color))
                .frame(width: 32, height: 32)
                .overlay(Circle().stroke(Color.gray.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showColorPickerPopover) {
            AdvancedColorPicker(selectedColor: $settings.color)
                .frame(minWidth: 320, minHeight: 360)
                .padding()
        }
    }

    private var alignmentPicker: some View {
        Picker("Alignment", selection: $settings.alignment) {
            Text("Left").tag(TextSettings.Alignment.leading)
            Text("Center").tag(TextSettings.Alignment.center)
            Text("Right").tag(TextSettings.Alignment.trailing)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Middle row

    private var middleRow: some View {
        VStack(alignment: .leading, spacing: 16) {
            sliderRow(label: "Tracking",
                      value: $settings.tracking,
                      range: -10...50,
                      fmt: "%.1f")

            sliderRow(label: "Line Spacing",
                      value: $settings.leading,
                      range: -20...80,
                      fmt: "%.0f")

            VStack(alignment: .leading, spacing: 8) {
                Text("Kerning")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("Kerning", selection: kerningKindBinding) {
                    Text("Auto").tag("auto")
                    Text("None").tag("none")
                    Text("Manual").tag("manual")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if case .manual = settings.kerning {
                    sliderRow(label: "Manual Kern",
                              value: $manualKerningValue,
                              range: -10...50,
                              fmt: "%.1f")
                        .onChange(of: manualKerningValue) { v in
                            settings.kerning = .manual(v)
                        }
                }
            }

            Toggle("Italic", isOn: $settings.italic)
        }
    }

    // MARK: - Path row

    private func pathRow(ft: FloatingText) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("On Path")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            sliderRow(
                label: "Baseline Offset",
                value: Binding(
                    get: { ft.baselineOffset },
                    set: { canvasState.setBaselineOffset($0) }
                ),
                range: -100...100,
                fmt: "%.0f"
            )

            Toggle("Closed Loop",
                isOn: Binding(
                    get: { ft.isClosed },
                    set: { canvasState.setPathClosed($0) }
                )
            )

            Toggle("Auto-flip Glyphs",
                isOn: Binding(
                    get: { ft.autoFlipEnabled },
                    set: { canvasState.setAutoFlipEnabled($0) }
                )
            )
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button(role: .cancel) {
                canvasState.cancelFloatingText()
            } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)

            Button {
                canvasState.commitFloatingText()
            } label: {
                Text("Commit")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(uiColor: .systemBackground))
        .overlay(Divider(), alignment: .top)
    }

    // MARK: - Helpers

    private func sliderRow(label: String,
                           value: Binding<CGFloat>,
                           range: ClosedRange<CGFloat>,
                           fmt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: fmt, value.wrappedValue))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private var displayFamilyName: String {
        // The face is the PostScript name — close enough as a label until
        // the Tier-3 picker overhaul gives us proper family + weight axis.
        let face = settings.fontFace
        return face.isEmpty ? settings.fontFamily : face
    }

    private var fontFamilyPickerPopover: some View {
        // Tier-3 will replace this with a search/sample/recents picker.
        // For now we reuse the dual-Picker UI from the retired sheet so
        // there's zero new font-handling code in this PR.
        Form {
            Section("Family") {
                Picker("Family", selection: $settings.fontFamily) {
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChange(of: settings.fontFamily) { newFamily in
                    let faces = UIFont.fontNames(forFamilyName: newFamily)
                    if !faces.contains(settings.fontFace) {
                        settings.fontFace = faces.first ?? newFamily
                    }
                }
            }
            let faces = UIFont.fontNames(forFamilyName: settings.fontFamily)
            if !faces.isEmpty {
                Section("Face") {
                    Picker("Face", selection: $settings.fontFace) {
                        ForEach(faces, id: \.self) { face in
                            Text(face).tag(face)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
        }
        .frame(minWidth: 320, minHeight: 480)
    }

    private var kerningKindBinding: Binding<String> {
        Binding(
            get: {
                switch settings.kerning {
                case .auto:    return "auto"
                case .none:    return "none"
                case .manual:  return "manual"
                }
            },
            set: { kind in
                switch kind {
                case "auto":   settings.kerning = .auto
                case "none":   settings.kerning = .none
                case "manual": settings.kerning = .manual(manualKerningValue)
                default:       settings.kerning = .auto
                }
            }
        )
    }
}

#Preview {
    TypeInspectorView(
        settings: .constant(.default),
        canvasState: CanvasStateManager()
    )
    .frame(width: 280, height: 700)
}
