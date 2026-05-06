//
//  TextSettingsView.swift
//  DrawEvolve
//
//  Sheet UI for editing TextSettings (font family, face, size, color,
//  alignment, leading, tracking, kerning, italic). Bound to
//  CanvasStateManager.textSettings — the manager's didSet sink persists to
//  UserDefaults and pushes changes onto any active FloatingText.
//

import SwiftUI
import UIKit

struct TextSettingsView: View {
    @Binding var settings: TextSettings

    /// Family list cached at init — UIFont.familyNames returns a fresh array
    /// every call and a SwiftUI Picker re-evaluating it on every render is
    /// noticeable on lower-end iPads.
    private let families: [String] = UIFont.familyNames.sorted()

    @State private var manualKerningValue: CGFloat = 0

    var body: some View {
        Form {
            familySection
            sizeSection
            colorSection
            paragraphSection
            spacingSection
            styleSection
            previewSection
        }
        .onAppear {
            if case .manual(let v) = settings.kerning {
                manualKerningValue = v
            }
        }
    }

    // MARK: - Sections

    private var familySection: some View {
        Section("Font") {
            Picker("Family", selection: $settings.fontFamily) {
                ForEach(families, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            .onChange(of: settings.fontFamily) { newFamily in
                // When the family changes, snap fontFace to the family's
                // first available face. Otherwise the previously selected
                // PostScript name no longer resolves and the rasteriser
                // falls back to the system font.
                let faces = UIFont.fontNames(forFamilyName: newFamily)
                if !faces.contains(settings.fontFace) {
                    settings.fontFace = faces.first ?? newFamily
                }
            }

            let faces = UIFont.fontNames(forFamilyName: settings.fontFamily)
            if !faces.isEmpty {
                Picker("Face", selection: $settings.fontFace) {
                    ForEach(faces, id: \.self) { face in
                        Text(face).tag(face)
                    }
                }
            }
        }
    }

    private var sizeSection: some View {
        Section("Size") {
            HStack {
                Text("Size")
                Spacer()
                Text(String(format: "%.0f pt", settings.size))
                    .foregroundColor(.secondary)
            }
            Slider(value: $settings.size, in: 1...500)
        }
    }

    private var colorSection: some View {
        Section("Color") {
            NavigationLink {
                AdvancedColorPicker(selectedColor: $settings.color)
                    .navigationTitle("Text Color")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                HStack {
                    Text("Text Color")
                    Spacer()
                    Circle()
                        .fill(Color(uiColor: settings.color))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color.gray.opacity(0.4), lineWidth: 1))
                }
            }
        }
    }

    private var paragraphSection: some View {
        Section("Paragraph") {
            Picker("Alignment", selection: $settings.alignment) {
                Text("Leading").tag(TextSettings.Alignment.leading)
                Text("Center").tag(TextSettings.Alignment.center)
                Text("Trailing").tag(TextSettings.Alignment.trailing)
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Leading")
                Spacer()
                Text(String(format: "%.0f", settings.leading))
                    .foregroundColor(.secondary)
            }
            Slider(value: $settings.leading, in: -20...80)
        }
    }

    private var spacingSection: some View {
        Section("Spacing") {
            HStack {
                Text("Tracking")
                Spacer()
                Text(String(format: "%.1f", settings.tracking))
                    .foregroundColor(.secondary)
            }
            Slider(value: $settings.tracking, in: -10...50)

            Picker("Kerning", selection: kerningKindBinding) {
                Text("Auto").tag("auto")
                Text("None").tag("none")
                Text("Manual").tag("manual")
            }
            .pickerStyle(.segmented)

            if case .manual = settings.kerning {
                HStack {
                    Text("Manual")
                    Spacer()
                    Text(String(format: "%.1f", manualKerningValue))
                        .foregroundColor(.secondary)
                }
                Slider(value: $manualKerningValue, in: -10...50)
                    .onChange(of: manualKerningValue) { v in
                        settings.kerning = .manual(v)
                    }
            }
        }
    }

    private var styleSection: some View {
        Section("Style") {
            Toggle("Italic", isOn: $settings.italic)
        }
    }

    private var previewSection: some View {
        Section("Preview") {
            HStack {
                Spacer()
                Text("AaBbCc 123")
                    .font(previewFont)
                    .foregroundColor(Color(uiColor: settings.color))
                Spacer()
            }
            .frame(height: max(48, min(120, settings.size * 1.4)))
        }
    }

    // MARK: - Helpers

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

    /// Preview row: clamp to a readable range so 500pt doesn't blow up the
    /// row height. Italic toggle uses descriptor route first; if the family
    /// has no italic variant the preview won't slant — same fallback story
    /// the rasteriser surfaces. (Shear-fallback isn't visible in the
    /// preview row, intentionally — the rasteriser shows the truth.)
    private var previewFont: Font {
        let basePt = min(60, max(12, settings.size))
        let face = settings.fontFace
        let family = settings.fontFamily
        let uiFont: UIFont = UIFont(name: face, size: basePt)
            ?? UIFont(name: family, size: basePt)
            ?? UIFont.systemFont(ofSize: basePt)
        if settings.italic, let italicDescriptor = uiFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
            return Font(UIFont(descriptor: italicDescriptor, size: basePt))
        }
        return Font(uiFont)
    }
}

#Preview {
    NavigationView {
        TextSettingsView(settings: .constant(.default))
            .navigationTitle("Text Settings")
    }
}
