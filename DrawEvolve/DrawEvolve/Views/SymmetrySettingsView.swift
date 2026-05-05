//
//  SymmetrySettingsView.swift
//  DrawEvolve
//
//  Sub-nav for the symmetry / mirror tool. Form-styled, matching the
//  established BrushSettingsView / LayerPanelView / AdvancedColorPicker
//  pattern (sheet from DrawingCanvasView, NavigationView wrapper, Done
//  button in the trailing toolbar).
//
//  Symmetry stays active until the user explicitly sets Mode → Off.
//  Closing the sheet does NOT deactivate symmetry — that's by spec.
//

import SwiftUI

struct SymmetrySettingsView: View {
    @ObservedObject var symmetry: SymmetryConfig

    var body: some View {
        Form {
            Section("Mode") {
                Picker("Symmetry mode", selection: pickerSelection) {
                    ForEach(SymmetryPickerOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            // Sections stepper is only meaningful in radial mode. Hidden
            // otherwise rather than disabled — matches the BrushSettings
            // pattern of hiding pressure-curve sliders when pressure is off.
            if case .radial(let sections) = symmetry.mode {
                Section("Sections") {
                    HStack {
                        Text("Sections")
                        Spacer()
                        Text("\(sections)")
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                    }
                    Stepper(
                        "Sections",
                        value: radialSectionsBinding,
                        in: SymmetryConfig.radialSectionRange
                    )
                    .labelsHidden()
                }
            }

            Section {
                Toggle("Hide guide", isOn: $symmetry.guideHidden)
            } footer: {
                Text("Symmetry stays active when the guide is hidden — the dashed lines just don't render.")
            }
        }
    }

    // MARK: - Bindings

    /// Picker binding: read projects Mode → SymmetryPickerOption; write
    /// rebuilds Mode from the picker option, preserving the existing
    /// radial section count (or substituting the default on first switch).
    private var pickerSelection: Binding<SymmetryPickerOption> {
        Binding(
            get: { SymmetryPickerOption.from(symmetry.mode) },
            set: { newOption in
                symmetry.mode = Self.mode(forPicker: newOption, currentMode: symmetry.mode)
            }
        )
    }

    private var radialSectionsBinding: Binding<Int> {
        Binding(
            get: {
                if case .radial(let n) = symmetry.mode { return n }
                return SymmetryConfig.defaultRadialSections
            },
            set: { newValue in
                let clamped = max(
                    SymmetryConfig.radialSectionRange.lowerBound,
                    min(SymmetryConfig.radialSectionRange.upperBound, newValue)
                )
                symmetry.mode = .radial(sections: clamped)
            }
        )
    }

    /// Build a Mode from a picker option. Radial preserves the existing
    /// section count when the user toggles Off → Radial → Off → Radial so
    /// they don't lose their setting; if there's no prior radial state,
    /// we use the default.
    private static func mode(forPicker option: SymmetryPickerOption,
                             currentMode: SymmetryConfig.Mode) -> SymmetryConfig.Mode {
        switch option {
        case .off:
            return .off
        case .yAxis:
            return .axis(SymmetryConfig.AxisConfig(yAxis: true, xAxis: false))
        case .xAxis:
            return .axis(SymmetryConfig.AxisConfig(yAxis: false, xAxis: true))
        case .bothAxes:
            return .axis(SymmetryConfig.AxisConfig(yAxis: true, xAxis: true))
        case .radial:
            if case .radial(let n) = currentMode { return .radial(sections: n) }
            return .radial(sections: SymmetryConfig.defaultRadialSections)
        }
    }
}

#Preview {
    NavigationStack {
        SymmetrySettingsView(symmetry: SymmetryConfig())
            .navigationTitle("Symmetry")
    }
}
