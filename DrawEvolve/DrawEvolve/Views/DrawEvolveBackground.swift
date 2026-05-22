//
//  DrawEvolveBackground.swift
//  DrawEvolve
//
//  Shared "atelier sky" gradient applied as the brand background across
//  brand-moment surfaces (launch, auth, gallery). Light/dark adaptive
//  via UITraitCollection so the colors resolve dynamically without each
//  caller needing to observe @Environment(\.colorScheme).
//
//  Pair the background with `Color.drawEvolveBrandTop` as a flat tint
//  on chrome (e.g. nav bars) so the toolbar reads as a continuation of
//  the surface rather than floating over it.
//

import SwiftUI
import UIKit

struct DrawEvolveBackground: View {
    var body: some View {
        LinearGradient(
            colors: [.drawEvolveBrandTop, .drawEvolveBrandBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

extension Color {
    static let drawEvolveBrandTop = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.09, green: 0.11, blue: 0.16, alpha: 1)
            : UIColor(red: 0.92, green: 0.95, blue: 0.99, alpha: 1)
    })

    static let drawEvolveBrandBottom = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1)
            : UIColor(red: 0.83, green: 0.89, blue: 0.96, alpha: 1)
    })
}
