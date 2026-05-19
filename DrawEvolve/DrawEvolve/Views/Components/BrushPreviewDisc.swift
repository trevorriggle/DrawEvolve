//
//  BrushPreviewDisc.swift
//  DrawEvolve
//
//  Live preview disc used by the brush-size rail (both iPad vertical
//  and iPhone horizontal variants). Renders the brush stamp at the
//  user's current size + hardness using a SwiftUI stitchable Metal
//  shader (`brushPreviewFalloff` in BrushPreviewShader.metal) so the
//  disc the user sees while scrubbing matches the falloff the brush
//  fragment shader produces on the canvas — not a SwiftUI
//  RadialGradient approximation that would drift from the shader the
//  first time the falloff curve is re-tuned.
//
//  `BrushPreviewModel` is the input contract for the disc. It carries
//  diameter (in screen pt) + hardness today and reserves an opacity
//  channel so the rail can add a third slider later without
//  reshaping callers.
//

import SwiftUI

/// All inputs that drive what the preview disc renders. Anything the
/// brush-rail wants to expose visually goes here — diameter, hardness,
/// and (reserved for future) opacity. The disc reads only this; it
/// does not know about brush colour, blend mode, or which slider is
/// currently being scrubbed.
struct BrushPreviewModel: Equatable {
    /// Diameter in screen points. Callers are expected to apply any
    /// on-screen cap (the rail caps at 80pt so the disc doesn't
    /// balloon out of the rail's chrome at very large brush sizes).
    var diameter: CGFloat
    /// Raw slider value 0...1. The shader applies the same perceptual
    /// remap the brush fragment shader does, so passing raw is correct.
    var hardness: CGFloat
    /// Raw slider value 0...1. Wired from the rail's opacity track.
    /// Applied via `.opacity(...)` on the disc; defaults to fully
    /// opaque so legacy single/dual-track callers that don't pass an
    /// opacity binding render the same as before.
    var opacity: CGFloat = 1.0
}

struct BrushPreviewDisc: View {
    let model: BrushPreviewModel

    var body: some View {
        Rectangle()
            .fill(Color.primary)
            .opacity(Double(model.opacity))
            .frame(width: model.diameter, height: model.diameter)
            .colorEffect(
                ShaderLibrary.default.brushPreviewFalloff(
                    .float(Float(model.diameter)),
                    .float(Float(model.hardness))
                )
            )
            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
    }
}

#Preview {
    VStack(spacing: 24) {
        BrushPreviewDisc(model: .init(diameter: 80, hardness: 1.0))
        BrushPreviewDisc(model: .init(diameter: 80, hardness: 0.5))
        BrushPreviewDisc(model: .init(diameter: 80, hardness: 0.1))
        BrushPreviewDisc(model: .init(diameter: 80, hardness: 0.0))
    }
    .padding()
    .background(Color.gray.opacity(0.15))
}
