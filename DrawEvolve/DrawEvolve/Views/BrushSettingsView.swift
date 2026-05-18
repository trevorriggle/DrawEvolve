//
//  BrushSettingsView.swift
//  DrawEvolve
//
//  Brush customization settings.
//

import SwiftUI

struct BrushSettingsView: View {
    @Binding var settings: BrushSettings
    /// Optional active tool. When set to `.blur`, the panel surfaces the
    /// blur strength slider. nil = caller doesn't supply a tool, panel
    /// behaves as the legacy brush settings panel.
    var activeTool: DrawingTool? = nil

    var body: some View {
        Form {
            Section("Size") {
                HStack {
                    Text("Size")
                    Spacer()
                    Text(String(format: "%.0f px", settings.size))
                        .foregroundColor(.primary)
                }
                Slider(value: $settings.size, in: 1...200)
            }

            // Blur Brush — strength slider only surfaces when the blur tool
            // is active.
            if activeTool == .blur {
                Section("Blur") {
                    HStack {
                        Text("Strength")
                        Spacer()
                        Text(String(format: "%.0f%%", settings.blurStrength * 100))
                            .foregroundColor(.primary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(settings.blurStrength) },
                            set: { settings.blurStrength = Float($0) }
                        ),
                        in: 0...1
                    )
                }
            }

            // Charcoal — procedural grain density. Multiplied into the
            // hash term inside `charcoalFragmentShader`. 0 = no grain
            // (effectively a soft brush), 1 = fully speckled. Only
            // surfaced when the charcoal variant is active; mirrors the
            // blur/smudge strength pattern.
            if activeTool == .charcoal {
                Section("Grain") {
                    HStack {
                        Text("Density")
                        Spacer()
                        Text(String(format: "%.0f%%", settings.grainDensity * 100))
                            .foregroundColor(.primary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(settings.grainDensity) },
                            set: { settings.grainDensity = Float($0) }
                        ),
                        in: 0...1
                    )
                }
            }

            // Smudge — pickup/deposit weight. Drives the patch-update mix
            // (strength * pressure) at every stamp; lower = the same
            // pigment carries longer along the drag, higher = each stamp
            // freshly samples the layer underneath. First-stamp pickup
            // always uses weight 1.0 internally so the patch initialises
            // to a full-saturation sample regardless of slider value.
            if activeTool == .smudge {
                Section("Smudge") {
                    HStack {
                        Text("Strength")
                        Spacer()
                        Text(String(format: "%.0f%%", settings.smudgeStrength * 100))
                            .foregroundColor(.primary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(settings.smudgeStrength) },
                            set: { settings.smudgeStrength = Float($0) }
                        ),
                        in: 0...1
                    )
                }
            }

            // Opacity slider (Phase 4.6 — wet-ink architecture). Bound to
            // `BrushSettings.opacity`; routed through commitWetInkToLayer at
            // stroke commit for brush-family tools. Read at touchesEnded so
            // mid-stroke slider changes take effect at commit. Eraser/blur/
            // smudge/shapes ignore opacity at the renderer level — the slider
            // stays visible for consistency with Size / Hardness / Spacing
            // (also "universal" properties that don't apply to every tool).
            Section("Opacity") {
                HStack {
                    Text("Opacity")
                    Spacer()
                    Text(String(format: "%.0f%%", settings.opacity * 100))
                        .foregroundColor(.primary)
                }
                Slider(value: $settings.opacity, in: 0...1)
            }

            Section("Shape") {
                HStack {
                    Text("Hardness")
                    Spacer()
                    Text(String(format: "%.0f%%", settings.hardness * 100))
                        .foregroundColor(.primary)
                }
                Slider(value: $settings.hardness, in: 0...1)

                HStack {
                    Text("Spacing")
                    Spacer()
                    Text(String(format: "%.0f%%", settings.spacing * 100))
                        .foregroundColor(.primary)
                }
                Slider(value: $settings.spacing, in: 0.01...1)
            }

            // Pressure section is iPad-only. iPhone has no Apple Pencil
            // input path and finger-force readings vary wildly across
            // models (3D Touch was deprecated on most current iPhones),
            // so the controls do nothing useful for phone users and the
            // section just adds clutter. The underlying
            // BrushSettings.pressureSensitivity / min / max fields
            // keep their defaults on iPhone — MetalCanvasView's
            // computePressure() returns 1.0 when no real pressure is
            // reported, so the iPhone stroke ends up size-flat regardless
            // of the toggle state.
            if !DeviceIdiom.isPhone {
                Section("Pressure") {
                    Toggle("Pressure Sensitivity", isOn: $settings.pressureSensitivity)

                    if settings.pressureSensitivity {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Minimum Size")
                                Spacer()
                                Text(String(format: "%.0f%%", settings.minPressureSize * 100))
                                    .foregroundColor(.primary)
                            }
                            Slider(value: $settings.minPressureSize, in: 0...1)

                            HStack {
                                Text("Maximum Size")
                                Spacer()
                                Text(String(format: "%.0f%%", settings.maxPressureSize * 100))
                                    .foregroundColor(.primary)
                            }
                            Slider(value: $settings.maxPressureSize, in: 0...1)
                        }
                    }
                }
            }

            Section("Preview") {
                BrushPreview(settings: settings)
                    .frame(height: 100)
            }
        }
    }
}

struct BrushPreview: View {
    let settings: BrushSettings

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, size in
            // Draw sample stroke with current settings
            let path = Path { path in
                let points: [CGPoint] = stride(from: 0, to: size.width, by: 5).map { x in
                    let t = x / size.width
                    let y = size.height / 2 + sin(t * .pi * 4) * 20
                    return CGPoint(x: x, y: y)
                }

                path.addLines(points)
            }

                context.stroke(
                    path,
                    with: .color(Color(settings.color)),
                    lineWidth: settings.size
                )
            }
            .background(Color(uiColor: .systemGray6))
            .cornerRadius(8)
        }
    }
}

#Preview {
    NavigationView {
        BrushSettingsView(settings: .constant(BrushSettings()))
            .navigationTitle("Brush Settings")
    }
}
