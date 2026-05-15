//
//  BrushPreviewShader.metal
//  DrawEvolve
//
//  SwiftUI `[[ stitchable ]]` shader for the brush-rail preview disc.
//  Kept separate from `Shaders.metal` so the live brush/canvas/Metal
//  pipeline (release-blocker territory) doesn't have to pull in
//  `<SwiftUI/SwiftUI_Metal.h>`. The math here MUST stay in lockstep
//  with `perceivedHardness` and the brush fragment shader in
//  `Shaders.metal`; if you re-tune the falloff there, mirror it here
//  or the preview disc will lie about what the brush actually paints.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// Falloff math mirrors `brushFragmentShader` in Shaders.metal:
//   1. `dist` is 0 at the disc centre, 1 at the rim.
//   2. `perceivedHardness` remap is h² (matches `perceivedHardness` in
//      Shaders.metal — see that file for the rationale).
//   3. Hard branch (h >= 0.99) draws a sharp edge; soft branch uses
//      smoothstep(1.0, h, dist) which interpolates from 1 at the
//      opaque core to 0 at the rim.
//
// Inputs:
//   position  — pixel coord within the view (points × scale).
//   color     — current colour the view rendered at this pixel.
//   diameter  — disc diameter in the same units as `position`.
//   hardness  — raw slider value 0..1; this function applies the
//               perceptual remap.
[[ stitchable ]] half4 brushPreviewFalloff(float2 position,
                                            half4 color,
                                            float diameter,
                                            float hardness) {
    float radius = diameter * 0.5;
    float2 center = float2(radius, radius);
    float dist = length(position - center) / max(radius, 1e-5);

    float clamped = clamp(hardness, 0.0, 1.0);
    float h = clamped * clamped;

    float alpha;
    if (h >= 0.99) {
        alpha = dist < 1.0 ? 1.0 : 0.0;
    } else {
        float edge = h;
        alpha = smoothstep(1.0, edge, dist);
    }

    return half4(color.rgb * alpha, color.a * alpha);
}
