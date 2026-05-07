//
//  TypeInspectorView.swift
//  DrawEvolve
//
//  Half-sheet content surfaced via the Type Bar's "More" button. Hosts the
//  deeper / less-frequently-tapped controls — italic, kerning kind +
//  manual kern slider, and the path-only section (baseline offset, closed
//  loop, auto-flip).
//
//  Tier 1.2 split: the everyday controls (font family, size, color,
//  alignment, leading, tracking) all live on the floating Type Bar now,
//  so this view holds only what the bar doesn't expose. Auto-show binding
//  was retired with PR #52's inspector mounting — this sheet only opens
//  when the user explicitly taps More.
//

import SwiftUI
import UIKit

struct TypeInspectorView: View {
    @Binding var settings: TextSettings

    @ObservedObject var canvasState: CanvasStateManager

    @State private var manualKerningValue: CGFloat = 0

    var body: some View {
        Form {
            styleSection
            kerningSection
            if let ft = canvasState.floatingText, ft.path != nil {
                pathSection(ft: ft)
            }
        }
        .onAppear {
            if case .manual(let v) = settings.kerning {
                manualKerningValue = v
            }
        }
    }

    // MARK: - Style

    private var styleSection: some View {
        Section("Style") {
            Toggle("Italic", isOn: $settings.italic)
        }
    }

    // MARK: - Kerning

    private var kerningSection: some View {
        Section("Kerning") {
            Picker("Kerning", selection: kerningKindBinding) {
                Text("Auto").tag("auto")
                Text("None").tag("none")
                Text("Manual").tag("manual")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

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

    // MARK: - Path

    private func pathSection(ft: FloatingText) -> some View {
        Section("On Path") {
            HStack {
                Text("Baseline Offset")
                Spacer()
                Text(String(format: "%.0f", ft.baselineOffset))
                    .foregroundColor(.secondary)
            }
            Slider(
                value: Binding(
                    get: { ft.baselineOffset },
                    set: { canvasState.setBaselineOffset($0) }
                ),
                in: -100...100
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
}

#Preview {
    TypeInspectorView(
        settings: .constant(.default),
        canvasState: CanvasStateManager()
    )
    .frame(width: 380, height: 480)
}
