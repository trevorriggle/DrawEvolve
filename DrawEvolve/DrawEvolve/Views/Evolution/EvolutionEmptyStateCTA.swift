//
//  EvolutionEmptyStateCTA.swift
//  DrawEvolve
//
//  CTA shown only in `.example` state, beneath the chart and warming-up
//  rows. The example data is the visible promise — this button is just an
//  exit ramp that dismisses the sheet so the user lands back on the
//  canvas. Secondary visual treatment by design; the chart is the hero.
//

import SwiftUI

struct EvolutionEmptyStateCTA: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text("Make your first drawing to start your own.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
    }
}

#Preview {
    EvolutionEmptyStateCTA(onTap: {})
        .padding()
}
