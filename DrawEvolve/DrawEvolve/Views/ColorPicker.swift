//
//  ColorPicker.swift
//  DrawEvolve
//
//  Advanced color picker for drawing app.
//

import SwiftUI

struct AdvancedColorPicker: View {
    @Binding var selectedColor: UIColor
    @State private var hue: Double = 0
    @State private var saturation: Double = 1
    @State private var brightness: Double = 1
    @State private var alpha: Double = 1

    var body: some View {
        VStack(spacing: 20) {
            // Color preview
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(selectedColor))
                .frame(height: 60)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(uiColor: .separator), lineWidth: 1)
                )

            // HSB Sliders
            VStack(spacing: 12) {
                ColorSlider(value: $hue, range: 0...1, label: "Hue") {
                    LinearGradient(
                        colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }

                ColorSlider(value: $saturation, range: 0...1, label: "Saturation") {
                    LinearGradient(
                        colors: [
                            Color(hue: hue, saturation: 0, brightness: brightness),
                            Color(hue: hue, saturation: 1, brightness: brightness)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }

                ColorSlider(value: $brightness, range: 0...1, label: "Brightness") {
                    LinearGradient(
                        colors: [
                            Color(hue: hue, saturation: saturation, brightness: 0),
                            Color(hue: hue, saturation: saturation, brightness: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }

                ColorSlider(value: $alpha, range: 0...1, label: "Opacity") {
                    LinearGradient(
                        colors: [
                            Color(hue: hue, saturation: saturation, brightness: brightness, opacity: 0),
                            Color(hue: hue, saturation: saturation, brightness: brightness, opacity: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
            }

            // Quick color presets
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 8), spacing: 12) {
                ForEach(ColorPresets.standard, id: \.self) { color in
                    Circle()
                        .fill(Color(color))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle()
                                .stroke(selectedColor == color ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                        .onTapGesture {
                            selectedColor = color
                            updateFromColor()
                        }
                }
            }
        }
        .padding()
        .onChange(of: hue) { _, _ in updateColor() }
        .onChange(of: saturation) { _, _ in updateColor() }
        .onChange(of: brightness) { _, _ in updateColor() }
        .onChange(of: alpha) { _, _ in updateColor() }
        .onAppear {
            updateFromColor()
        }
    }

    private func updateColor() {
        selectedColor = UIColor(
            hue: hue,
            saturation: saturation,
            brightness: brightness,
            alpha: alpha
        )
    }

    private func updateFromColor() {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0

        selectedColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        hue = h
        saturation = s
        brightness = b
        alpha = a
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
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", value * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
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

struct ColorPresets {
    static let standard: [UIColor] = [
        .black, .darkGray, .gray, .lightGray,
        .red, .orange, .yellow, .green,
        .cyan, .blue, .purple, .magenta,
        .brown, .white, UIColor(red: 1, green: 0.75, blue: 0.8, alpha: 1), UIColor(red: 0.5, green: 0.75, blue: 1, alpha: 1)
    ]
}

#Preview {
    AdvancedColorPicker(selectedColor: .constant(.blue))
}
