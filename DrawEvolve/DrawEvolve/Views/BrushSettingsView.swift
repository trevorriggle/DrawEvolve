//
//  BrushSettingsView.swift
//  DrawEvolve
//
//  Brush customization settings.
//

import SwiftUI

struct BrushSettingsView: View {
    @Binding var settings: BrushSettings

    var body: some View {
        Form {
            Section("Size") {
                HStack {
                    Text("Size")
                    Spacer()
                    Text(String(format: "%.0f px", settings.size))
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.size, in: 1...100)
            }

            Section("Opacity") {
                HStack {
                    Text("Opacity")
                    Spacer()
                    Text(String(format: "%.0f%%", settings.opacity * 100))
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.opacity, in: 0...1)
            }

            Section("Shape") {
                HStack {
                    Text("Hardness")
                    Spacer()
                    Text(String(format: "%.0f%%", settings.hardness * 100))
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.hardness, in: 0...1)

                HStack {
                    Text("Spacing")
                    Spacer()
                    Text(String(format: "%.0f%%", settings.spacing * 100))
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.spacing, in: 0.01...1)
            }

            Section("Pressure") {
                Toggle("Pressure Sensitivity", isOn: $settings.pressureSensitivity)

                if settings.pressureSensitivity {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Minimum Size")
                            Spacer()
                            Text(String(format: "%.0f%%", settings.minPressureSize * 100))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.minPressureSize, in: 0...1)

                        HStack {
                            Text("Maximum Size")
                            Spacer()
                            Text(String(format: "%.0f%%", settings.maxPressureSize * 100))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.maxPressureSize, in: 0...1)
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

#Preview {
    NavigationView {
        BrushSettingsView(settings: .constant(BrushSettings()))
            .navigationTitle("Brush Settings")
    }
}
