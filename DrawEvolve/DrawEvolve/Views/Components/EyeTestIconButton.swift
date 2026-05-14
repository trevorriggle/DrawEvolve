//
//  EyeTestIconButton.swift
//  DrawEvolve
//
//  Top-right chrome entry point for the Composition / "Eye Test"
//  panel. Mirrors EveIconButton's 44×44 chrome treatment. Mounted by
//  DrawingCanvasView immediately below the Eve button on iPad only;
//  iPhone defers to FloatingFeedbackPanel per the v1 surface decision.
//
//  Gated by the `eye_test_panel` feature flag at the mount site, not
//  inside this view. The button itself is dumb chrome.
//

import SwiftUI

struct EyeTestIconButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "eye.circle")
                .font(.system(size: 24))
                .foregroundColor(.primary)
                .frame(width: 44, height: 44)
                .background(Color(uiColor: .systemBackground).opacity(0.95))
                .clipShape(Circle())
                .shadow(radius: 4)
        }
        .accessibilityLabel("Composition analysis")
    }
}
