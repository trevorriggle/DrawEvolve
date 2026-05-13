//
//  EveIconButton.swift
//  DrawEvolve
//
//  The "EVE" text icon, used in two places:
//    - The iPad canvas right-side action column (between gallery and
//      settings, always-visible tier).
//    - The bottom of FloatingFeedbackPanel as the "Ask Eve" affordance.
//
//  Per spec the glyph is plain text — no sparkle, no chat bubble, no
//  SF Symbol. Rendered in the app's rounded design at semibold weight.
//  Two callers, one component: action-column uses `.standard` (44×44
//  to match neighbors); the critique-panel bottom row can opt into
//  `.compact` (36×36) if it needs a tighter fit. Default is `.standard`.
//

import SwiftUI

struct EveIconButton: View {
    enum Size {
        case standard
        case compact
    }

    let action: () -> Void
    var size: Size = .standard

    var body: some View {
        Button(action: action) {
            Text("EVE")
                .font(.system(
                    size: textSize,
                    weight: .semibold,
                    design: .rounded
                ))
                .kerning(0.5)
                .foregroundColor(.primary)
                .frame(width: frameSize, height: frameSize)
                .background(Color(uiColor: .systemBackground).opacity(0.95))
                .clipShape(Circle())
                .shadow(radius: 4)
        }
        .accessibilityLabel("Eve")
    }

    private var frameSize: CGFloat {
        switch size {
        case .standard: return 44
        case .compact:  return 36
        }
    }

    private var textSize: CGFloat {
        switch size {
        case .standard: return 13
        case .compact:  return 11
        }
    }
}
