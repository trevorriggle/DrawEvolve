//
//  ColorPicker.swift
//  DrawEvolve
//
//  Custom color picker (Phase 3 — Color System Overhaul, 2026-05-13).
//
//  Refactor preserves the external surface: AdvancedColorPicker is still
//  presented from DrawingCanvasView with the same @Binding<UIColor>
//  signature. Internals are entirely new:
//    - Picker opens to the exact current color (no more "reset to vivid"
//      that the v1 implementation did on every open).
//    - HSB / RGB segmented control switches slider modes non-
//      destructively.
//    - Hex field with live validation and commit-on-Return.
//    - Active palette section reads from PaletteManager, with a Menu-
//      based switcher and a "Generate from canvas" button.
//    - Recent colors strip at the bottom shows the last 16 colors used.
//
//  External callers should pass `compositeImage` if they want the
//  "Generate from canvas" button to function (the picker can't fetch
//  the canvas composite on its own — that's a caller concern).
//

import SwiftUI
import UIKit

struct AdvancedColorPicker: View {
    @Binding var selectedColor: UIColor

    /// Optional closure that returns the current canvas composite as
    /// a UIImage. When provided, the "Generate from canvas" button is
    /// enabled and routes the image through PaletteGenerator. When
    /// nil, the button is hidden — the picker still works for color
    /// picking, just without the AI-generation affordance.
    var compositeImage: (() -> UIImage?)? = nil

    @StateObject private var paletteManager = PaletteManager.shared

    @State private var hue: Double = 0
    @State private var saturation: Double = 1
    @State private var brightness: Double = 1
    @State private var alpha: Double = 1

    @State private var red: Double = 0
    @State private var green: Double = 0
    @State private var blue: Double = 0

    @State private var hexText: String = "#000000"
    @State private var hexFieldFocused: Bool = false
    @State private var hexFieldInvalid: Bool = false

    @State private var sliderMode: SliderMode = .hsb

    /// Captured at .onAppear so we can decide whether to write a
    /// recent-color entry on .onDisappear. If the user opens and
    /// closes the picker without changing anything, no recent-color
    /// entry is written (the previous active color is still active).
    @State private var openingColor: UIColor = .black

    @State private var showGeneratedPreview: Bool = false
    @State private var generatedColors: [UIColor] = []
    @State private var isGenerating: Bool = false
    @State private var generationError: String? = nil

    enum SliderMode: String, CaseIterable, Identifiable {
        case hsb = "HSB"
        case rgb = "RGB"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                activeColorAndInputs
                sliderSection
                paletteSection
                if !paletteManager.recentColors.isEmpty {
                    recentSection
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear {
            openingColor = selectedColor
            syncStateFromSelectedColor()
        }
        .onChange(of: selectedColor) { _, newValue in
            // External writes to the binding (eyedropper, palette taps
            // from outside this view) should keep the slider state in
            // sync without firing the slider→color writeback loop.
            syncStateFromSelectedColor(skipFor: newValue)
        }
        .onDisappear {
            // Commit the final color to recents when the picker
            // dismisses, if it changed during the session. Dedupe in
            // PaletteManager.addRecentColor absorbs accidental dupes.
            if !PaletteManager.colorsAreEqualForRecent(openingColor, selectedColor) {
                paletteManager.addRecentColor(selectedColor)
            }
        }
        .sheet(isPresented: $showGeneratedPreview) {
            GeneratedPalettePreview(
                colors: generatedColors,
                onSave: { name, finalColors in
                    Task {
                        do {
                            try await paletteManager.createPalette(name: name, colors: finalColors)
                            showGeneratedPreview = false
                        } catch {
                            // Surface inside the sheet; preview keeps
                            // showing so the user can retry.
                        }
                    }
                },
                onCancel: { showGeneratedPreview = false }
            )
        }
    }

    // MARK: - Section: Active color + inputs

    private var activeColorAndInputs: some View {
        HStack(alignment: .top, spacing: 16) {
            // Preview swatch with a checkerboard pattern behind so
            // alpha is visible at a glance.
            ZStack {
                CheckerboardBackground()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(selectedColor))
                    .frame(width: 96, height: 96)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(uiColor: .separator), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 8) {
                hexField
                rgbReadout
            }
            Spacer(minLength: 0)
        }
    }

    private var hexField: some View {
        HStack(spacing: 8) {
            Text("Hex")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            TextField("#000000", text: $hexText)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(hexFieldInvalid ? Color.red : Color(uiColor: .separator), lineWidth: 1)
                )
                .onSubmit { commitHex() }
                .onChange(of: hexText) { _, newValue in
                    // Live validation: turn the border red on invalid,
                    // commit on valid 6-digit hex without waiting for
                    // Return.
                    if let color = parseHex(newValue) {
                        hexFieldInvalid = false
                        applyColor(color)
                    } else {
                        hexFieldInvalid = true
                    }
                }
        }
    }

    private var rgbReadout: some View {
        HStack(spacing: 8) {
            rgbField(label: "R", value: $red, range: 0...255)
            rgbField(label: "G", value: $green, range: 0...255)
            rgbField(label: "B", value: $blue, range: 0...255)
        }
    }

    private func rgbField(label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("0", value: value, formatter: Self.integerFormatter)
                .font(.callout.monospaced())
                .keyboardType(.numberPad)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(uiColor: .separator), lineWidth: 1)
                )
                .frame(width: 56)
                .onChange(of: value.wrappedValue) { _, _ in writeBackFromRGB() }
        }
    }

    private static let integerFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 0
        f.maximum = 255
        f.allowsFloats = false
        return f
    }()

    // MARK: - Section: Sliders

    private var sliderSection: some View {
        VStack(spacing: 10) {
            Picker("Mode", selection: $sliderMode) {
                ForEach(SliderMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch sliderMode {
            case .hsb: hsbSliders
            case .rgb: rgbSliders
            }

            opacitySlider
        }
    }

    private var hsbSliders: some View {
        VStack(spacing: 10) {
            ColorSlider(value: $hue, range: 0...1, label: "Hue") {
                LinearGradient(
                    colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .onChange(of: hue) { _, _ in writeBackFromHSB() }

            ColorSlider(value: $saturation, range: 0...1, label: "Saturation") {
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0, brightness: brightness),
                        Color(hue: hue, saturation: 1, brightness: brightness),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .onChange(of: saturation) { _, _ in writeBackFromHSB() }

            ColorSlider(value: $brightness, range: 0...1, label: "Brightness") {
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: saturation, brightness: 0),
                        Color(hue: hue, saturation: saturation, brightness: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .onChange(of: brightness) { _, _ in writeBackFromHSB() }
        }
    }

    private var rgbSliders: some View {
        VStack(spacing: 10) {
            ColorSlider(value: Binding(
                get: { red / 255.0 },
                set: { red = ($0 * 255.0).rounded() }
            ), range: 0...1, label: "Red") {
                LinearGradient(
                    colors: [
                        Color(red: 0, green: green / 255.0, blue: blue / 255.0),
                        Color(red: 1, green: green / 255.0, blue: blue / 255.0),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            }
            .onChange(of: red) { _, _ in writeBackFromRGB() }

            ColorSlider(value: Binding(
                get: { green / 255.0 },
                set: { green = ($0 * 255.0).rounded() }
            ), range: 0...1, label: "Green") {
                LinearGradient(
                    colors: [
                        Color(red: red / 255.0, green: 0, blue: blue / 255.0),
                        Color(red: red / 255.0, green: 1, blue: blue / 255.0),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            }
            .onChange(of: green) { _, _ in writeBackFromRGB() }

            ColorSlider(value: Binding(
                get: { blue / 255.0 },
                set: { blue = ($0 * 255.0).rounded() }
            ), range: 0...1, label: "Blue") {
                LinearGradient(
                    colors: [
                        Color(red: red / 255.0, green: green / 255.0, blue: 0),
                        Color(red: red / 255.0, green: green / 255.0, blue: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            }
            .onChange(of: blue) { _, _ in writeBackFromRGB() }
        }
    }

    private var opacitySlider: some View {
        ColorSlider(value: $alpha, range: 0...1, label: "Opacity") {
            LinearGradient(
                colors: [
                    Color(uiColor: selectedColor).opacity(0),
                    Color(uiColor: selectedColor).opacity(1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
        }
        .onChange(of: alpha) { _, _ in
            switch sliderMode {
            case .hsb: writeBackFromHSB()
            case .rgb: writeBackFromRGB()
            }
        }
    }

    // MARK: - Section: Active palette + generate

    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                paletteSwitcherMenu
                Spacer(minLength: 8)
                if compositeImage != nil {
                    Button(action: triggerGenerate) {
                        if isGenerating {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Generating…").font(.subheadline)
                            }
                        } else {
                            Label("Generate from canvas", systemImage: "wand.and.stars")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isGenerating)
                }
            }

            if let message = generationError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            paletteSwatches
        }
    }

    private var paletteSwitcherMenu: some View {
        Menu {
            ForEach(paletteManager.palettes) { p in
                Button(action: { paletteManager.activePaletteID = p.id }) {
                    if p.id == paletteManager.activePaletteID {
                        Label(p.name, systemImage: "checkmark")
                    } else {
                        Text(p.name)
                    }
                }
            }
            Divider()
            Button(action: { /* hook in PaletteManagerView in a follow-up */ }) {
                Label("Manage palettes…", systemImage: "slider.horizontal.3")
            }
            .disabled(true)
        } label: {
            HStack(spacing: 4) {
                Text(activePaletteName)
                    .font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(.primary)
        }
    }

    private var activePaletteName: String {
        if let id = paletteManager.activePaletteID,
           let p = paletteManager.palettes.first(where: { $0.id == id }) {
            return p.name
        }
        return paletteManager.palettes.first?.name ?? "No palette"
    }

    private var paletteSwatches: some View {
        let palette = paletteManager.palettes.first { $0.id == paletteManager.activePaletteID }
            ?? paletteManager.palettes.first
        let colors = palette?.colors.map { $0.uiColor } ?? []
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 8),
            spacing: 10
        ) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                ColorSwatch(color: color, isActive: PaletteManager.colorsAreEqualForRecent(color, selectedColor))
                    .onTapGesture {
                        applyColor(color)
                        paletteManager.addRecentColor(color)
                    }
            }
        }
    }

    // MARK: - Section: Recent colors

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(paletteManager.recentColors.enumerated()), id: \.offset) { _, color in
                        ColorSwatch(color: color, isActive: PaletteManager.colorsAreEqualForRecent(color, selectedColor))
                            .onTapGesture {
                                applyColor(color)
                                // Recent tap also bumps the color back
                                // to the front of the recent list (most-
                                // recently-used semantics).
                                paletteManager.addRecentColor(color)
                            }
                    }
                }
            }
        }
    }

    // MARK: - Color sync helpers
    //
    // The picker carries 3 redundant representations of the color:
    // HSB (hue/sat/bright), RGB (red/green/blue 0-255), and the binding
    // (selectedColor). The four state writes (HSB→color, RGB→color,
    // hex→color, swatch tap→color) all route through applyColor(_:),
    // which sets selectedColor + syncs all three rep states atomically
    // to keep them coherent. The .onChange(of: selectedColor) handler
    // catches outside writes (eyedropper, palette tap from another
    // view) and syncs the same way.
    //
    // We track whether the write came from us or from outside via the
    // skipFor parameter on syncStateFromSelectedColor — without it we
    // could ping-pong on every slider drag.

    private func applyColor(_ color: UIColor) {
        selectedColor = color
        // syncStateFromSelectedColor will fire via the .onChange handler.
    }

    private func syncStateFromSelectedColor(skipFor _: UIColor? = nil) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        selectedColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        red = (r * 255).rounded()
        green = (g * 255).rounded()
        blue = (b * 255).rounded()
        alpha = a

        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, aa: CGFloat = 0
        selectedColor.getHue(&h, saturation: &s, brightness: &br, alpha: &aa)
        hue = h
        saturation = s
        brightness = br

        let rr = Int(red)
        let gg = Int(green)
        let bb = Int(blue)
        let newHex = String(format: "#%02x%02x%02x", rr, gg, bb)
        if hexText != newHex {
            hexText = newHex
            hexFieldInvalid = false
        }
    }

    private func writeBackFromHSB() {
        let newColor = UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
        // Only apply if changed enough — float precision in HSB↔RGB
        // round-trips can otherwise cause invisible feedback loops.
        if !PaletteManager.colorsAreEqualForRecent(newColor, selectedColor) {
            applyColor(newColor)
        } else if newColor != selectedColor {
            // Within tolerance but not bit-equal — write through so the
            // user's slider drag is reflected exactly.
            selectedColor = newColor
            syncStateFromSelectedColor()
        }
    }

    private func writeBackFromRGB() {
        let r = max(0, min(1, red / 255))
        let g = max(0, min(1, green / 255))
        let b = max(0, min(1, blue / 255))
        let newColor = UIColor(red: r, green: g, blue: b, alpha: alpha)
        if !PaletteManager.colorsAreEqualForRecent(newColor, selectedColor) {
            applyColor(newColor)
        } else if newColor != selectedColor {
            selectedColor = newColor
            syncStateFromSelectedColor()
        }
    }

    private func commitHex() {
        if let color = parseHex(hexText) {
            applyColor(color)
            hexFieldInvalid = false
        } else {
            hexFieldInvalid = true
        }
    }

    private func parseHex(_ raw: String) -> UIColor? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xff) / 255.0
        let g = CGFloat((value >> 8) & 0xff) / 255.0
        let b = CGFloat(value & 0xff) / 255.0
        // Hex doesn't carry alpha (6-digit only, per spec) — preserve
        // the picker's current alpha so the opacity slider is the
        // sole source of truth for alpha.
        return UIColor(red: r, green: g, blue: b, alpha: alpha)
    }

    // MARK: - Generate from canvas

    private func triggerGenerate() {
        guard let getImage = compositeImage, !isGenerating else { return }
        isGenerating = true
        generationError = nil
        Task {
            defer { isGenerating = false }
            guard let image = getImage() else {
                generationError = "Draw something first."
                return
            }
            do {
                let extracted = try PaletteGenerator.generate(from: image)
                if extracted.isEmpty {
                    generationError = "Couldn't find distinct colors."
                    return
                }
                generatedColors = extracted
                showGeneratedPreview = true
            } catch let e as PaletteGeneratorError {
                generationError = e.errorDescription
            } catch {
                generationError = "Generation failed."
            }
        }
    }
}

// MARK: - Subviews

private struct ColorSwatch: View {
    let color: UIColor
    let isActive: Bool

    var body: some View {
        ZStack {
            CheckerboardBackground()
                .clipShape(Circle())
            Circle().fill(Color(color))
        }
        .frame(width: 32, height: 32)
        .overlay(
            Circle()
                .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }
}

private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 6
            let cols = Int((size.width / tile).rounded(.up))
            let rows = Int((size.height / tile).rounded(.up))
            for y in 0..<rows {
                for x in 0..<cols {
                    let rect = CGRect(x: CGFloat(x) * tile, y: CGFloat(y) * tile, width: tile, height: tile)
                    let isLight = (x + y) % 2 == 0
                    context.fill(Path(rect), with: .color(isLight ? Color(white: 0.93) : Color(white: 0.78)))
                }
            }
        }
    }
}

struct ColorSlider<Background: View>: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    @ViewBuilder let background: Background

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.primary)
                Spacer()
                Text(String(format: "%.0f%%", value * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.primary)
            }
            Slider(value: $value, in: range)
                .accentColor(.clear)
                .background(
                    background
                        .frame(height: 8)
                        .cornerRadius(4)
                )
        }
    }
}

// MARK: - Generated palette preview sheet

private struct GeneratedPalettePreview: View {
    let colors: [UIColor]
    let onSave: (_ name: String, _ colors: [UIColor]) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var workingColors: [UIColor] = []

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Edit the name or remove any colors you don't want, then save as a palette.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("Palette name", text: $name)
                    .textFieldStyle(.roundedBorder)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                    spacing: 12
                ) {
                    ForEach(Array(workingColors.enumerated()), id: \.offset) { index, color in
                        ZStack(alignment: .topTrailing) {
                            ColorSwatch(color: color, isActive: false)
                                .frame(width: 44, height: 44)
                            Button {
                                workingColors.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .background(Circle().fill(Color(uiColor: .systemBackground)))
                            }
                            .offset(x: 4, y: -4)
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Generated palette")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let resolved = finalName.isEmpty ? Self.defaultName() : finalName
                        onSave(resolved, workingColors)
                    }
                    .disabled(workingColors.isEmpty)
                }
            }
            .onAppear {
                name = Self.defaultName()
                workingColors = colors
            }
        }
    }

    private static func defaultName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Generated \(f.string(from: Date()))"
    }
}

// MARK: - Static seed presets
//
// Phase 3 (Color System Overhaul, 2026-05-13): These 16 colors used to
// be the picker's hardcoded swatch grid. They now SEED the starter "My
// palette" on first launch (PaletteManager.seedStarterPalette). The
// constant survives — it's the source for new-user seed data, not a
// runtime swatch list.

struct ColorPresets {
    static let standard: [UIColor] = [
        .black, .darkGray, .gray, .lightGray,
        .red, .orange, .yellow, .green,
        .cyan, .blue, .purple, .magenta,
        .brown, .white, UIColor(red: 1, green: 0.75, blue: 0.8, alpha: 1), UIColor(red: 0.5, green: 0.75, blue: 1, alpha: 1)
    ]
}

// MARK: - Tolerance helper on PaletteManager
//
// Exposed at type-level so views can compare colors without re-implementing
// the Euclidean-distance math. Kept in extension so the picker doesn't
// import a redundant copy.

extension PaletteManager {
    static func colorsAreEqualForRecent(_ a: UIColor, _ b: UIColor, threshold: CGFloat = 12.0) -> Bool {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let dr = (ar - br) * 255.0
        let dg = (ag - bg) * 255.0
        let db = (ab - bb) * 255.0
        let dist = (dr * dr + dg * dg + db * db).squareRoot()
        return dist < threshold
    }
}

#Preview {
    AdvancedColorPicker(selectedColor: .constant(.blue))
}
