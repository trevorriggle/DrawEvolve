//
//  ColorPicker.swift
//  DrawEvolve
//
//  Custom color picker (Phase 3 — Color System Overhaul, 2026-05-13).
//
//  Phase 3.1 picker UI redesign (2026-05-13):
//    - Horizontal pill row replaces Menu switcher; active palette is
//      always one tap away.
//    - Trailing dashed "+" pill creates a new palette and immediately
//      enters inline rename mode.
//    - Explicit Edit toggle governs BOTH the pill row (× = delete,
//      long-press = rename) AND the swatch grid (× = remove swatch).
//    - "+ add current" trailing slot in the swatch grid previews the
//      active color and saves it to the active palette on tap; a brief
//      checkmark fade confirms.
//    - Long-press on pills (in either mode) opens inline rename.
//    - Manage-palettes sheet and per-swatch context menus removed —
//      edit mode is the only mutation surface.
//
//  External surface preserved: AdvancedColorPicker is still presented
//  from DrawingCanvasView with the same @Binding<UIColor> signature.
//  Backing data layer (PaletteManager, BrushSettings persistence,
//  recent-color dedupe) is untouched — this is a view rewrite only.
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
    @State private var hexFieldInvalid: Bool = false

    @State private var sliderMode: SliderMode = .hsb

    /// Captured at .onAppear so we can decide whether to write a
    /// recent-color entry on .onDisappear.
    @State private var openingColor: UIColor = .black

    @State private var showGeneratedPreview: Bool = false
    @State private var generatedColors: [UIColor] = []
    @State private var isGenerating: Bool = false
    @State private var generationError: String? = nil

    // MARK: - Edit mode + rename state (Phase 3.1)

    /// Single mode flag that gates BOTH pill deletes and swatch deletes.
    /// While true: × buttons appear on pills and swatches, tap-to-activate
    /// is suppressed on pills, tap-to-pick is suppressed on swatches, and
    /// the "+ add current" trailing slot hides.
    @State private var isEditMode: Bool = false

    /// When non-nil, the matching pill swaps its text for an inline
    /// TextField focused for renaming. Submit / focus-loss commits;
    /// empty after trim cancels.
    @State private var pendingRenameID: UUID? = nil
    @State private var pendingRenameText: String = ""
    @FocusState private var renameFocused: Bool

    /// Briefly true after "+ add current" succeeds — drives the
    /// checkmark fade on the trailing slot's badge.
    @State private var addCurrentJustSaved: Bool = false

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
            syncStateFromSelectedColor(skipFor: newValue)
        }
        .onDisappear {
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

    // MARK: - Section: Palette pill row + swatches (Phase 3.1)

    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            paletteHeader
            palettePillRow

            if let message = generationError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            paletteSwatches
        }
    }

    private var paletteHeader: some View {
        HStack(spacing: 12) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isEditMode.toggle() } }) {
                Text(isEditMode ? "Done" : "Edit")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderless)
            .disabled(paletteManager.palettes.isEmpty)

            Spacer()

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
                .disabled(isGenerating || isEditMode)
            }
        }
    }

    private var palettePillRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(paletteManager.palettes) { p in
                        palettePill(p)
                            .id(p.id)
                    }
                    createPalettePill
                        .id("create-palette-pill")
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 1)
            }
            .onChange(of: paletteManager.activePaletteID) { _, newID in
                guard let id = newID else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func palettePill(_ p: Palette) -> some View {
        let isActive = p.id == paletteManager.activePaletteID
        let isRenaming = pendingRenameID == p.id

        return HStack(spacing: 6) {
            if isRenaming {
                TextField("Name", text: $pendingRenameText)
                    .focused($renameFocused)
                    .submitLabel(.done)
                    .onSubmit { commitRename() }
                    .onChange(of: renameFocused) { _, focused in
                        // Tapping anywhere outside the field commits.
                        if !focused && pendingRenameID == p.id {
                            commitRename()
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(isActive ? .white : .primary)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .frame(minWidth: 80, maxWidth: 160)
            } else {
                Text(p.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(isActive ? .white : .primary)
                    .lineLimit(1)
            }

            if isEditMode && !isRenaming {
                Button {
                    Task { try? await paletteManager.deletePalette(id: p.id) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(isActive ? Color.white.opacity(0.85) : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(isActive ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
        )
        .contentShape(Capsule())
        .onTapGesture {
            guard !isRenaming else { return }
            // Edit-mode tap is a no-op on pills — × is the only mutator.
            guard !isEditMode else { return }
            paletteManager.activePaletteID = p.id
        }
        .onLongPressGesture(minimumDuration: 0.4) {
            beginRename(p)
        }
    }

    private var createPalettePill: some View {
        Button(action: handleCreatePalette) {
            Image(systemName: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .strokeBorder(
                            Color(uiColor: .separator),
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]),
                        )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isEditMode)
        .opacity(isEditMode ? 0.4 : 1.0)
    }

    private var paletteSwatches: some View {
        let activePalette = paletteManager.palettes.first { $0.id == paletteManager.activePaletteID }
            ?? paletteManager.palettes.first
        let colors = activePalette?.colors.map { $0.uiColor } ?? []
        let activeID = activePalette?.id

        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 8),
            spacing: 10,
        ) {
            ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                swatchCell(color: color, index: index, paletteID: activeID)
            }
            if !isEditMode, let pid = activeID {
                addCurrentSlot(paletteID: pid)
            }
        }
    }

    private func swatchCell(color: UIColor, index: Int, paletteID: UUID?) -> some View {
        let isActive = PaletteManager.colorsAreEqualForRecent(color, selectedColor)
        return ZStack(alignment: .topTrailing) {
            ColorSwatch(color: color, isActive: isActive)
                .onTapGesture {
                    guard !isEditMode else { return }
                    applyColor(color)
                    paletteManager.addRecentColor(color)
                }

            if isEditMode, let pid = paletteID {
                Button {
                    Task { try? await paletteManager.removeColor(at: index, fromPaletteID: pid) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .background(Circle().fill(Color(uiColor: .systemBackground)))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
    }

    /// Trailing "+" cell in the swatch grid. Previews the active color so
    /// the user sees what they're about to save; tapping appends it to
    /// the active palette and flashes a checkmark for ~0.5s.
    private func addCurrentSlot(paletteID: UUID) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                CheckerboardBackground()
                    .clipShape(Circle())
                Circle().fill(Color(selectedColor))
            }
            .frame(width: 32, height: 32)
            .overlay(
                Circle().stroke(Color(uiColor: .separator), lineWidth: 1)
            )

            ZStack {
                Circle()
                    .fill(addCurrentJustSaved ? Color.green : Color.accentColor)
                    .frame(width: 16, height: 16)
                Image(systemName: addCurrentJustSaved ? "checkmark" : "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            }
            .offset(x: 4, y: -4)
            .animation(.easeInOut(duration: 0.2), value: addCurrentJustSaved)
        }
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await handleAddCurrent(paletteID: paletteID) }
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
                                paletteManager.addRecentColor(color)
                            }
                    }
                }
            }
        }
    }

    // MARK: - Palette mutation helpers (Phase 3.1)

    private func beginRename(_ p: Palette) {
        pendingRenameID = p.id
        pendingRenameText = p.name
        renameFocused = true
    }

    private func commitRename() {
        guard let id = pendingRenameID else { return }
        let trimmed = pendingRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalName = paletteManager.palettes.first(where: { $0.id == id })?.name
        pendingRenameID = nil
        pendingRenameText = ""
        renameFocused = false
        // Empty-after-trim or unchanged → no-op.
        guard !trimmed.isEmpty, trimmed != originalName else { return }
        Task { try? await paletteManager.renamePalette(id: id, to: trimmed) }
    }

    private func handleCreatePalette() {
        Task {
            do {
                try await paletteManager.createPalette(name: "New palette", colors: [])
                if let newID = paletteManager.activePaletteID {
                    // Small yield so the pill renders before we focus the
                    // TextField — SwiftUI .focused needs the field in the
                    // hierarchy first.
                    try? await Task.sleep(for: .milliseconds(80))
                    pendingRenameID = newID
                    pendingRenameText = "New palette"
                    renameFocused = true
                }
            } catch {
                // Optimistic insert rolled back inside PaletteManager.
            }
        }
    }

    private func handleAddCurrent(paletteID: UUID) async {
        do {
            try await paletteManager.addColor(selectedColor, toPaletteID: paletteID)
            paletteManager.addRecentColor(selectedColor)
            addCurrentJustSaved = true
            try? await Task.sleep(for: .milliseconds(500))
            addCurrentJustSaved = false
        } catch {
            // Optimistic insert rolled back; surface nothing for now.
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

    private func applyColor(_ color: UIColor) {
        selectedColor = color
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
        if !PaletteManager.colorsAreEqualForRecent(newColor, selectedColor) {
            applyColor(newColor)
        } else if newColor != selectedColor {
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
