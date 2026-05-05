//
//  AdjustmentHUD.swift
//  DrawEvolve
//
//  Reusable top-of-canvas HUD bar for Procreate-style adjustment tools.
//  Built generic so future adjustment tools (sharpen, hue/saturation, etc.)
//  reuse this component instead of each rolling its own bar.
//

import SwiftUI

struct AdjustmentHUD: View {
    /// Tool name shown on the left ("Blur", "Sharpen", …).
    let label: String

    /// Right-of-label value display ("35%", "+12 px", …). Caller formats it
    /// however the tool wants — the HUD doesn't interpret.
    let valueText: String

    /// ✓ button — caller commits the preview into the active layer.
    let onCommit: () -> Void

    /// ✕ button — caller discards the preview / resets value to 0.
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                Text("·")
                    .foregroundColor(.secondary)
                Text(valueText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .frame(minWidth: 56, alignment: .leading)
                    .monospacedDigit()
            }
            .padding(.leading, 16)

            Spacer()

            HStack(spacing: 8) {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.red.opacity(0.85))
                        .clipShape(Circle())
                }
                .accessibilityLabel("Cancel adjustment")

                Button(action: onCommit) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.green.opacity(0.85))
                        .clipShape(Circle())
                }
                .accessibilityLabel("Commit adjustment")
            }
            .padding(.trailing, 8)
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .cornerRadius(14)
        .shadow(radius: 4)
    }
}

#Preview {
    VStack {
        AdjustmentHUD(
            label: "Blur",
            valueText: "35%",
            onCommit: {},
            onCancel: {}
        )
        .padding()
        Spacer()
    }
    .background(Color.gray)
}
