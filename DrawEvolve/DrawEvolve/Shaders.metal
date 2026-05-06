//
//  Shaders.metal
//  DrawEvolve
//
//  Metal shaders for high-performance drawing with layers, blend modes, and effects.
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Structures

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float pointSize [[point_size]];
};

struct BrushUniforms {
    float4 color;           // RGBA color
    float size;             // Brush size in pixels
    float opacity;          // 0.0 to 1.0
    float hardness;         // 0.0 (soft) to 1.0 (hard)
    float pressure;         // 0.0 to 1.0 from Apple Pencil
};

struct LayerUniforms {
    float opacity;          // Layer opacity
    int blendMode;          // 0=Normal, 1=Multiply, 2=Screen, 3=Overlay, 4=Add
};

// MARK: - Vertex Shaders

// Vertex shader for brush strokes (point sprites)
vertex VertexOut brushVertexShader(uint vertexID [[vertex_id]],
                                    constant float2 *positions [[buffer(0)]],
                                    constant BrushUniforms &uniforms [[buffer(1)]],
                                    constant float2 &viewportSize [[buffer(2)]]) {
    VertexOut out;

    // Convert from pixel coordinates to normalized device coordinates
    float2 pixelPos = positions[vertexID];
    float2 ndc = (pixelPos / viewportSize) * 2.0 - 1.0;
    ndc.y = -ndc.y; // Flip Y for screen coordinates

    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = float2(0.0, 0.0); // Point sprite will generate tex coords
    // Apple GPU point sprite size cap is ~511 px on A-series (possibly
    // higher on M-series). Past the cap, Metal silently fails to render the
    // point — manifests as "stroke vanishes mid-stroke" / "large brush
    // doesn't draw" from the Apr 15 hardware audit. Clamp here as the
    // last line of defense; Swift-side code also pre-clamps but this
    // guarantees we never lose a stamp regardless of upstream code paths
    // (history restore, future tools, etc). The visible failure mode at
    // extreme inputs is a stamp capped at 511 px instead of invisible.
    out.pointSize = clamp(uniforms.size * uniforms.pressure, 0.0, 511.0);

    return out;
}

// Vertex shader for full-screen quad (compositing) - basic version
vertex VertexOut quadVertexShader(uint vertexID [[vertex_id]]) {
    VertexOut out;

    // Generate full-screen quad
    float2 positions[6] = {
        float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
        float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0)
    };

    float2 texCoords[6] = {
        float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0),
        float2(0.0, 0.0), float2(1.0, 1.0), float2(1.0, 0.0)
    };

    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    out.pointSize = 1.0;

    return out;
}

// Vertex shader for full-screen quad with zoom, pan, and rotation support.
//
// ARCHITECTURE: position transforms ONLY. Texture coordinates are the identity
// [0,1] per-corner mapping; the GPU's linear interpolation across the (possibly
// transformed) quad is what produces the correct sample lookup.
//
// The previous implementation also applied the *inverse* of zoom/pan/rotation to
// the texture coordinates, which was both redundant (double-transform) and
// numerically incorrect (pan was normalised by canvas size in the texCoord path
// but by viewport size in the position path — the two were never inverses of
// each other). That was the source of the persistent stroke offset users saw
// after the Phase-1 coordinate fixes: screen pixels mapped back to doc coords
// via `screenToDocument` didn't agree with how the shader actually painted those
// coords to the screen. With identity texCoords, the inverse is unambiguous:
// whatever the shader does to positions, `CanvasStateManager.screenToDocument`
// inverts, and they match exactly.
vertex VertexOut quadVertexShaderWithTransform(uint vertexID [[vertex_id]],
                                                constant float4 *transform [[buffer(0)]],    // [zoom, panX, panY, rotation]
                                                constant float2 *viewportSize [[buffer(1)]],
                                                constant float2 *canvasSize [[buffer(2)]],   // Unused now; kept for ABI stability
                                                constant float2 *flipState [[buffer(3)]]) {   // [flipH, flipV] each 0 or 1
    VertexOut out;

    // Generate full-screen quad
    float2 positions[6] = {
        float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
        float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0)
    };

    // Texture coords: identity mapping per corner. UIKit-Y-down convention —
    // NDC top (+1) maps to texCoord.v=0 (top row of texture).
    float2 texCoords[6] = {
        float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0),
        float2(0.0, 0.0), float2(1.0, 1.0), float2(1.0, 0.0)
    };

    // Unpack transform parameters
    float zoom = transform[0][0];
    float2 pan = float2(transform[0][1], transform[0][2]);
    float rotation = transform[0][3];  // Rotation angle in radians
    float2 viewport = viewportSize[0]; // Screen size (changes with orientation)

    float2 finalPos = positions[vertexID];
    float2 finalTexCoord = texCoords[vertexID];  // IDENTITY — no transforms.

    // Aspect-ratio correction: canvas is square, viewport usually isn't. Scale
    // the quad so the square canvas *fills* (covers) the longer viewport
    // dimension — at zoom=1 the entire screen is inside the canvas. The shorter
    // axis gets scaled up past ±1 NDC, clipping outside the viewport.
    float viewportAspect = viewport.x / viewport.y;
    float2 scale = float2(1.0, 1.0);
    if (viewportAspect > 1.0) {
        scale.y = viewportAspect;        // landscape: extend quad top/bottom
    } else {
        scale.x = 1.0 / viewportAspect;  // portrait: extend quad left/right
    }
    float2 correctedPos = finalPos * scale;

    // NDC → Y-up pixel space
    float2 screenPos = (correctedPos * 0.5 + 0.5) * viewport;

    // Zoom around viewport center
    float2 screenCenter = viewport * 0.5;
    screenPos = (screenPos - screenCenter) * zoom + screenCenter;

    // Rotate around viewport center
    if (rotation != 0.0) {
        float2 rel = screenPos - screenCenter;
        float c = cos(rotation);
        float s = sin(rotation);
        screenPos = float2(rel.x * c - rel.y * s, rel.x * s + rel.y * c) + screenCenter;
    }

    // Pan. `pan` is in UIKit Y-down points; `screenPos` here is Y-up pixels
    // (Y = viewport.y maps to NDC +1 = screen top). Flip pan.y so the canvas
    // follows the finger vertically. (Bug 2c.)
    screenPos += float2(pan.x, -pan.y);

    // Canvas flip — applied LAST in screen space (mirror around viewport
    // center). Pairs with CanvasStateManager.documentToScreen which
    // applies the same flip last in the CPU-side forward chain, so
    // SwiftUI overlays (symmetry guides, marching ants, transform
    // handles) and Metal-rendered layers agree on flipped positions.
    // Pan/rotate gesture handlers in CanvasStateManager compensate for
    // flip so input still feels natural; zoom commutes with the
    // mirror and needs no compensation.
    float2 flipFlags = flipState[0];
    if (flipFlags.x > 0.5) screenPos.x = viewport.x - screenPos.x;
    if (flipFlags.y > 0.5) screenPos.y = viewport.y - screenPos.y;

    // Back to NDC
    finalPos = (screenPos / viewport) * 2.0 - 1.0;

    out.position = float4(finalPos, 0.0, 1.0);
    out.texCoord = finalTexCoord;
    out.pointSize = 1.0;

    return out;
}

// Vertex shader that renders a texture covering an arbitrary doc-space rect,
// with the same zoom/pan/rotation transforms as the layer compositor. Used
// for the live drag preview of a floating selection (move/rectangle/lasso):
// each drag frame we just update the doc-space rect uniform and redraw — no
// pixels are read or written until the user releases the gesture.
//
// Inputs:
//   transform:   [zoom, panX, panY, rotation]   (same convention as the layer shader)
//   viewportSize: viewport in points
//   canvasSize:   doc-space extents in points (matches CanvasStateManager.documentSize)
//   docRect:     [originX, originY, width, height] in doc space (UIKit Y-down)
vertex VertexOut quadVertexShaderForRect(uint vertexID [[vertex_id]],
                                          constant float4 *transform [[buffer(0)]],
                                          constant float2 *viewportSize [[buffer(1)]],
                                          constant float2 *canvasSize [[buffer(2)]],
                                          constant float4 *docRect [[buffer(3)]],
                                          constant float  *selectionRotation [[buffer(4)]],
                                          constant float2 *flipState [[buffer(5)]]) {
    VertexOut out;

    // Unit quad in [0,1]² — texCoord follows the same parameterization so
    // texCoord.v=0 lands on the rect's TOP edge in doc space. Matches the
    // texture row-0 = top-of-canvas convention used by the layer shader.
    float2 unitPos[6] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
        float2(0.0, 1.0), float2(1.0, 0.0), float2(1.0, 1.0)
    };
    float2 unit = unitPos[vertexID];

    float2 rectOrigin = float2(docRect[0].x, docRect[0].y);
    float2 rectSize   = float2(docRect[0].z, docRect[0].w);
    float2 docPos = rectOrigin + unit * rectSize;

    // Per-selection rotation applied IN DOC SPACE around the rect's center.
    // The user-facing convention (positive = visual CCW) matches canvasRotation,
    // and to produce visual CCW in Y-down doc coords we apply R(-θ):
    //   x' =  x cosθ + y sinθ
    //   y' = -x sinθ + y cosθ
    // This composes correctly with the canvas-level rotation applied later
    // in screen space; the visible angle is θ_selection + canvasRotation.
    float selTheta = selectionRotation[0];
    if (selTheta != 0.0) {
        float2 rectCenter = rectOrigin + rectSize * 0.5;
        float2 rel = docPos - rectCenter;
        float cs = cos(selTheta);
        float ss = sin(selTheta);
        docPos = rectCenter + float2(rel.x * cs + rel.y * ss,
                                     -rel.x * ss + rel.y * cs);
    }

    float2 viewport = viewportSize[0];
    float fitSize = max(viewport.x, viewport.y);
    float2 docDim = canvasSize[0];

    // Doc → quad-local pixels (centered at origin, Y-down to start). Match
    // documentToScreen: pt = (frac * fitSize) - fitSize/2.
    float2 quadLocalYDown = (docPos / docDim) * fitSize - fitSize * 0.5;
    // Flip Y to match the layer shader's Y-up screen-pixel space.
    float2 quadLocal = float2(quadLocalYDown.x, -quadLocalYDown.y);

    float2 screenCenter = viewport * 0.5;
    float2 screenPos = quadLocal + screenCenter;

    // Zoom, rotate, pan — order matches the layer shader exactly so a rect
    // that spans the whole canvas would render identically to a layer.
    float zoom = transform[0][0];
    screenPos = (screenPos - screenCenter) * zoom + screenCenter;

    float rotation = transform[0][3];
    if (rotation != 0.0) {
        float2 rel = screenPos - screenCenter;
        float c = cos(rotation);
        float s = sin(rotation);
        screenPos = float2(rel.x * c - rel.y * s, rel.x * s + rel.y * c) + screenCenter;
    }

    float2 pan = float2(transform[0][1], transform[0][2]);
    screenPos += float2(pan.x, -pan.y);

    // Canvas flip — applied LAST in screen space, matching the layer
    // shader and CanvasStateManager.documentToScreen. Floating selections
    // and imported-image drag previews flip alongside the rest of the
    // canvas so the user's drag continues to track the finger.
    float2 flipFlags = flipState[0];
    if (flipFlags.x > 0.5) screenPos.x = viewport.x - screenPos.x;
    if (flipFlags.y > 0.5) screenPos.y = viewport.y - screenPos.y;

    float2 finalPos = (screenPos / viewport) * 2.0 - 1.0;

    out.position = float4(finalPos, 0.0, 1.0);
    out.texCoord = unit;
    out.pointSize = 1.0;
    return out;
}

// MARK: - Fragment Shaders

// MARK: - Selection mask convention (PR 3)
//
// Brush, eraser, blur-brush deposit, and smudge (both pickup + deposit)
// sample a selection mask at `[[texture(2)]]`. The mask is r8Unorm,
// canvas-sized: 1.0 inside the active selection, 0.0 outside. When no
// selection is active, the renderer binds a 1×1 all-ones texture so the
// shader's mask multiply is a no-op without per-shader branching.
// Sampling is by normalised layer coords — `in.position.xy` is the
// fragment's layer-pixel coord (Metal framebuffer convention, y=0 at
// top), so `uv = in.position.xy / mask.size` gives the [0,1] lookup.
// `clamp_to_edge + linear` so soft (anti-aliased) selection edges
// produce smooth clipping without per-shader edge handling.

// Sample the selection mask at the fragment's layer pixel position. Returns
// 1.0 inside the selection (or everywhere when no-mask 1×1 is bound) and
// 0.0 outside; soft-edge selections produce in-between values.
static float sampleSelectionMask(texture2d<float> mask,
                                 float4 fragPosition) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 maskSize = float2(mask.get_width(), mask.get_height());
    // For the 1×1 no-mask texture, maskSize is (1,1) and any UV samples
    // the single pixel (= 1.0). For the canvas-sized real mask, maskSize
    // matches the layer texture's dims and `fragPosition.xy` is in those
    // same pixel units.
    return mask.sample(s, fragPosition.xy / maskSize).r;
}

// Fragment shader for brush strokes with soft edges
fragment float4 brushFragmentShader(VertexOut in [[stage_in]],
                                     float2 pointCoord [[point_coord]],
                                     constant BrushUniforms &uniforms [[buffer(0)]],
                                     texture2d<float> selectionMask [[texture(2)]]) {
    // Calculate distance from center (0.5, 0.5)
    float2 center = float2(0.5, 0.5);
    float dist = distance(pointCoord, center) * 2.0; // 0.0 at center, 1.0 at edge

    // Apply hardness: soft edge vs hard edge
    float alpha;
    if (uniforms.hardness >= 0.99) {
        // Hard brush: sharp cutoff
        alpha = dist < 1.0 ? 1.0 : 0.0;
    } else {
        // Soft brush: smooth falloff
        float softness = 1.0 - uniforms.hardness;
        float edge = 1.0 - softness;
        alpha = smoothstep(1.0, edge, dist);
    }

    // Apply opacity and pressure, then clip to selection.
    alpha *= uniforms.opacity * uniforms.pressure;
    alpha *= sampleSelectionMask(selectionMask, in.position);

    return float4(uniforms.color.rgb, alpha * uniforms.color.a);
}

// Fragment shader for eraser (outputs transparent pixels)
fragment float4 eraserFragmentShader(VertexOut in [[stage_in]],
                                      float2 pointCoord [[point_coord]],
                                      constant BrushUniforms &uniforms [[buffer(0)]],
                                      texture2d<float> selectionMask [[texture(2)]]) {
    float2 center = float2(0.5, 0.5);
    float dist = distance(pointCoord, center) * 2.0;

    float alpha;
    if (uniforms.hardness >= 0.99) {
        alpha = dist < 1.0 ? 1.0 : 0.0;
    } else {
        float softness = 1.0 - uniforms.hardness;
        float edge = 1.0 - softness;
        alpha = smoothstep(1.0, edge, dist);
    }

    alpha *= uniforms.opacity * uniforms.pressure;
    alpha *= sampleSelectionMask(selectionMask, in.position);

    // Return transparent black with alpha for erasing
    return float4(0.0, 0.0, 0.0, alpha);
}

// MARK: - Blend Mode Functions

float4 blendNormal(float4 base, float4 blend, float opacity) {
    return mix(base, blend, blend.a * opacity);
}

float4 blendMultiply(float4 base, float4 blend, float opacity) {
    float4 result = base * blend;
    result.a = blend.a;
    return mix(base, result, opacity);
}

float4 blendScreen(float4 base, float4 blend, float opacity) {
    float4 result = 1.0 - (1.0 - base) * (1.0 - blend);
    result.a = blend.a;
    return mix(base, result, opacity);
}

float4 blendOverlay(float4 base, float4 blend, float opacity) {
    float4 result;
    result.r = base.r < 0.5 ? 2.0 * base.r * blend.r : 1.0 - 2.0 * (1.0 - base.r) * (1.0 - blend.r);
    result.g = base.g < 0.5 ? 2.0 * base.g * blend.g : 1.0 - 2.0 * (1.0 - base.g) * (1.0 - blend.g);
    result.b = base.b < 0.5 ? 2.0 * base.b * blend.b : 1.0 - 2.0 * (1.0 - base.b) * (1.0 - blend.b);
    result.a = blend.a;
    return mix(base, result, opacity);
}

float4 blendAdd(float4 base, float4 blend, float opacity) {
    float4 result = base + blend;
    result.a = blend.a;
    return mix(base, result, opacity);
}

// Fragment shader for layer compositing with blend modes
fragment float4 compositeFragmentShader(VertexOut in [[stage_in]],
                                         texture2d<float> baseTexture [[texture(0)]],
                                         texture2d<float> blendTexture [[texture(1)]],
                                         constant LayerUniforms &uniforms [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);

    float4 base = baseTexture.sample(textureSampler, in.texCoord);
    float4 blend = blendTexture.sample(textureSampler, in.texCoord);

    // Apply blend mode
    float4 result;
    switch (uniforms.blendMode) {
        case 0: // Normal
            result = blendNormal(base, blend, uniforms.opacity);
            break;
        case 1: // Multiply
            result = blendMultiply(base, blend, uniforms.opacity);
            break;
        case 2: // Screen
            result = blendScreen(base, blend, uniforms.opacity);
            break;
        case 3: // Overlay
            result = blendOverlay(base, blend, uniforms.opacity);
            break;
        case 4: // Add
            result = blendAdd(base, blend, uniforms.opacity);
            break;
        default:
            result = blendNormal(base, blend, uniforms.opacity);
            break;
    }

    return result;
}

// MARK: - Shape Shaders

// Fragment shader for line tool
fragment float4 lineFragmentShader(VertexOut in [[stage_in]],
                                    constant BrushUniforms &uniforms [[buffer(0)]]) {
    return float4(uniforms.color.rgb, uniforms.opacity * uniforms.color.a);
}

// Fragment shader for filled shapes (rectangle, circle)
fragment float4 shapeFragmentShader(VertexOut in [[stage_in]],
                                     constant BrushUniforms &uniforms [[buffer(0)]]) {
    return float4(uniforms.color.rgb, uniforms.opacity * uniforms.color.a);
}

// Fragment shader for displaying a texture with opacity and blend mode support
fragment float4 textureDisplayShader(VertexOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]],
                                      constant float &opacity [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 color = tex.sample(textureSampler, in.texCoord);
    // Apply layer opacity to alpha channel
    color.a *= opacity;
    return color;
}

// MARK: - Gaussian Blur (Effects)
//
// The blur tool family (Blur Brush + Blur Adjustment) shares two render
// pipelines built on these shaders:
//
//   1. Two-pass separable Gaussian. `gaussianBlurShader` runs once for the
//      horizontal pass (direction = (1/width, 0)) and once for the vertical
//      pass (direction = (0, 1/height)). Sigma drives both kernel weights and
//      kernelHalfWidth (caller computes ceil(3 * sigma)). Output is a fully
//      blurred copy of the source — used by the brush-blur path as an
//      intermediate, and by the adjustment path's first pass.
//
//   2. `gaussianBlurMaskedShader` is the same vertical-pass Gaussian, but
//      blends its result with a separately-bound source texture using an
//      r8Unorm mask. Used by the adjustment path's final pass to clip blur
//      to the active selection (mask = 1 inside selection, 0 outside).
//
//   3. `stampBlurDepositShader` is a point-sprite fragment shader that
//      samples the pre-computed blurred texture at the fragment's layer-pixel
//      position, gated by the standard brush hardness curve. Used by the
//      brush-blur path as the final deposit per stamp.

struct GaussianUniforms {
    float2 direction;       // (1/width, 0) horizontal; (0, 1/height) vertical
    float sigma;            // Gaussian standard deviation in pixels
    int   kernelHalfWidth;  // ceil(3 * sigma); 0 disables (returns source)
};

// Compute a 1-D Gaussian sample at the fragment's UV. Caller passes
// `direction` to choose horizontal vs vertical.
static float4 gaussian1D(texture2d<float> tex,
                         float2 uv,
                         float2 direction,
                         float sigma,
                         int halfWidth) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    if (halfWidth <= 0 || sigma <= 0.0) {
        return tex.sample(s, uv);
    }
    float weightSum = 0.0;
    float4 colorSum = float4(0.0);
    float twoSigmaSquared = 2.0 * sigma * sigma;
    for (int i = -halfWidth; i <= halfWidth; i++) {
        float w = exp(-float(i * i) / twoSigmaSquared);
        colorSum += tex.sample(s, uv + direction * float(i)) * w;
        weightSum += w;
    }
    return colorSum / weightSum;
}

// Generic 1-D Gaussian blur fragment shader. Output is a pure Gaussian sample
// of the input texture along `direction`. No masking, no compositing.
fragment float4 gaussianBlurShader(VertexOut in [[stage_in]],
                                   texture2d<float> inputTexture [[texture(0)]],
                                   constant GaussianUniforms &uniforms [[buffer(0)]]) {
    return gaussian1D(inputTexture,
                      in.texCoord,
                      uniforms.direction,
                      uniforms.sigma,
                      uniforms.kernelHalfWidth);
}

// Vertical-pass Gaussian + masked composite. The "blur adjustment" tool's
// final pass: reads the horizontally-blurred intermediate, reads the original
// snapshot, reads the selection mask (r8Unorm), and outputs:
//
//     mix(original, blurred, mask.r)
//
// Where mask = 1 the user sees full blur; where mask = 0 they see the
// original. The full-layer adjustment path (no selection) supplies an all-1.0
// mask so output == blurred everywhere.
fragment float4 gaussianBlurMaskedShader(VertexOut in [[stage_in]],
                                          texture2d<float> inputTexture [[texture(0)]],
                                          texture2d<float> sourceTexture [[texture(1)]],
                                          texture2d<float> maskTexture   [[texture(2)]],
                                          constant GaussianUniforms &uniforms [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float4 blurred = gaussian1D(inputTexture,
                                in.texCoord,
                                uniforms.direction,
                                uniforms.sigma,
                                uniforms.kernelHalfWidth);
    float maskAlpha = maskTexture.sample(s, in.texCoord).r;
    float4 original = sourceTexture.sample(s, in.texCoord);
    return mix(original, blurred, maskAlpha);
}

// Brush-blur deposit pass — point-sprite fragment shader. Samples the
// pre-blurred texture at the fragment's layer-pixel position (via the
// VertexOut `position` attribute, which is the framebuffer coordinate at
// rasterisation time), gated by the standard brush hardness curve and
// modulated by opacity * pressure * blurStrength. Returns a premultiplied
// colour so the caller's standard sourceAlpha/oneMinusSourceAlpha blend
// deposits it cleanly into the layer.
fragment float4 stampBlurDepositShader(VertexOut in [[stage_in]],
                                       float2 pointCoord [[point_coord]],
                                       texture2d<float> blurredTexture [[texture(0)]],
                                       texture2d<float> selectionMask  [[texture(2)]],
                                       constant BrushUniforms &uniforms [[buffer(0)]],
                                       constant float &blurStrength [[buffer(1)]]) {
    // Same disc + hardness curve as brushFragmentShader.
    float2 center = float2(0.5, 0.5);
    float dist = distance(pointCoord, center) * 2.0;

    float alpha;
    if (uniforms.hardness >= 0.99) {
        alpha = dist < 1.0 ? 1.0 : 0.0;
    } else {
        float softness = 1.0 - uniforms.hardness;
        float edge = 1.0 - softness;
        alpha = smoothstep(1.0, edge, dist);
    }
    alpha *= uniforms.opacity * uniforms.pressure * blurStrength;
    alpha *= sampleSelectionMask(selectionMask, in.position);

    if (alpha <= 0.0) {
        discard_fragment();
    }

    // Sample blurredTexture at this fragment's layer-pixel position. The
    // VertexOut `position` attribute is in framebuffer (= layer-pixel) coords
    // at rasterisation; normalise by layer size to get the [0,1] UV.
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 layerSize = float2(blurredTexture.get_width(), blurredTexture.get_height());
    float2 uv = in.position.xy / layerSize;
    float4 blurred = blurredTexture.sample(s, uv);

    // Premultiplied output for the standard sourceAlpha blend.
    return float4(blurred.rgb * alpha, alpha);
}

// MARK: - Smudge (PR 2)
//
// Smudge is "stamp-as-you-go": each stamp depends on the layer state the
// previous stamp deposited, so we cannot batch the whole stroke at touchesEnded
// the way the brush/blur paths do. Instead the renderer holds a small
// `smudgePatch` texture (~ stampSize square) and dispatches a (patch update,
// deposit) pair per stamp, in order, on a single command buffer per
// touchesMoved batch.
//
// The patch holds the "carried paint" — at each stamp the layer is sampled
// under the stamp center and mixed into the patch with weight = strength *
// pressure (the pickup). The patch is then sampled by a point-sprite deposit
// pass that paints picked color back into the layer with the standard hardness
// disc + opacity falloff.
//
// Two patches are kept (front/back ping-pong): the pickup pass reads the
// "front" patch + the layer and writes the result to the "back" patch; the
// caller then swaps them so the next pickup reads the just-written carry.
// First-stamp pickup uses weight = 1.0 (initialise the patch to the layer
// sample directly) and the deposit pass is skipped — the patch is "empty"
// before stamp 0 so depositing it would just paint zero.
//
// Patch ↔ layer mapping is anchored at the current stamp center: the patch's
// world half-size in layer pixels is `patchHalfSize`, so patch UV (u,v) maps
// to layer pixel `stampCenter + (uv - 0.5) * 2 * patchHalfSize`. Sampling
// uses clamp_to_edge so stamps near the layer border read the edge pixel
// instead of garbage.

struct SmudgeUniforms {
    float2 stampCenter;        // layer pixel coords of this stamp's center
    float2 patchHalfSize;      // half-extent of the patch in layer pixel units
    float2 layerSize;          // layer texture pixel size
    float  weight;             // pickup mix weight = strength * pressure (0..1).
                               // First stamp of a stroke is dispatched with 1.0
                               // so mix(empty_patch, layer, 1.0) = layer.
};

// Smudge patch update — full-quad pass on the BACK patch. For each patch
// pixel: read the FRONT patch at the same UV (the previously-carried paint),
// read the layer at the world coord that this patch UV maps to, mix.
//
// `frontPatch` is the patch that holds the current carry (read-only here);
// its content was written by the previous stamp. `layerTexture` is the active
// layer's MTLTexture (read-only). The fragment writes to the BACK patch (the
// render target).
fragment float4 smudgePatchUpdateShader(VertexOut in [[stage_in]],
                                         texture2d<float> frontPatch    [[texture(0)]],
                                         texture2d<float> layerTexture  [[texture(1)]],
                                         texture2d<float> selectionMask [[texture(2)]],
                                         constant SmudgeUniforms &uniforms [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    // Patch UV → layer pixel coord, then normalise to layer UV.
    float2 layerPx = uniforms.stampCenter + (in.texCoord - 0.5) * 2.0 * uniforms.patchHalfSize;
    float2 layerUV = layerPx / uniforms.layerSize;
    float4 layerSample = layerTexture.sample(s, layerUV);

    // Selection-aware pickup: scale the pickup weight by the mask sampled
    // at the SOURCE layer pixel (not the patch UV). When the world coord
    // for this patch pixel is OUTSIDE the selection, the layer sample
    // contributes nothing — the patch retains its previous carry instead
    // of dragging "outside" colour into the inside of the selection on
    // the next deposit. Photoshop-correct: pickup AND deposit clip.
    constexpr sampler maskSampler(address::clamp_to_edge, filter::linear);
    float2 maskSize = float2(selectionMask.get_width(), selectionMask.get_height());
    float maskSrc = selectionMask.sample(maskSampler, layerPx / maskSize).r;
    float weight = uniforms.weight * maskSrc;

    // Front patch sample at the same UV — the previously-carried paint at
    // this offset from the (now-current) stamp center. Since the patch is
    // anchored at the new stamp center, this is a tiny approximation: the
    // previous stamp's patch was anchored at the previous stamp's center.
    // For tightly-spaced stamps along a drag (stampSpacing << patchSize) the
    // two anchors are close enough that the carry stays coherent. This is
    // the standard cheap-smudge approximation; it matches Procreate-style
    // behaviour without per-stamp per-pixel resampling of the patch.
    float4 frontSample = frontPatch.sample(s, in.texCoord);

    return mix(frontSample, layerSample, weight);
}

// Smudge deposit — point-sprite fragment shader. Same disc + hardness curve
// as brushFragmentShader / stampBlurDepositShader. Samples the (just-updated)
// patch via the fragment's layer-pixel position mapped to patch UV, returns
// premultiplied colour for the standard sourceAlpha source-over blend.
//
// NB: smudgeStrength does NOT scale the deposit alpha — strength only drives
// pickup weight in the patch update pass. The deposit alpha is just the
// brush mask (hardness disc) modulated by opacity * pressure, identical to
// the brush. Doubling-up strength on the deposit would make low-strength
// smudges nearly invisible (pickup * deposit both attenuated).
fragment float4 smudgeDepositShader(VertexOut in [[stage_in]],
                                     float2 pointCoord [[point_coord]],
                                     texture2d<float> patchTexture  [[texture(0)]],
                                     texture2d<float> selectionMask [[texture(2)]],
                                     constant BrushUniforms &uniforms [[buffer(0)]],
                                     constant SmudgeUniforms &smudge [[buffer(1)]]) {
    // Same disc + hardness curve as the brush.
    float2 center = float2(0.5, 0.5);
    float dist = distance(pointCoord, center) * 2.0;

    float alpha;
    if (uniforms.hardness >= 0.99) {
        alpha = dist < 1.0 ? 1.0 : 0.0;
    } else {
        float softness = 1.0 - uniforms.hardness;
        float edge = 1.0 - softness;
        alpha = smoothstep(1.0, edge, dist);
    }
    alpha *= uniforms.opacity * uniforms.pressure;
    // Selection clip on deposit: outside the selection, alpha → 0 and the
    // discard below short-circuits the patch sample. Pairs with the
    // pickup-side mask in smudgePatchUpdateShader.
    alpha *= sampleSelectionMask(selectionMask, in.position);

    if (alpha <= 0.0) {
        discard_fragment();
    }

    // Layer pixel position → patch UV. The patch is anchored at the current
    // stamp center with world half-size `patchHalfSize`, so the UV at
    // `layerPx` is (layerPx - center + halfSize) / (2 * halfSize). Sampler
    // clamps so fragments outside the patch's world footprint (shouldn't
    // happen — point sprite is sized to fit) read the edge.
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 layerPx = in.position.xy;
    float2 patchUV = (layerPx - smudge.stampCenter + smudge.patchHalfSize) / (2.0 * smudge.patchHalfSize);
    float4 picked = patchTexture.sample(s, patchUV);

    // The patch holds premultiplied content (it was sampled from the
    // layer, which stores premultiplied bgra8Unorm). Scaling the entire
    // tuple by `alpha` produces a premultiplied output that the standard
    // sourceAlpha/oneMinusSourceAlpha blend deposits cleanly.
    return picked * alpha;
}

// MARK: - Effect Shaders

// One iteration pass of a connected-component (flood) fill.
//
// The caller seeds `frontMask` with 1.0 at the start pixel and 0.0 everywhere
// else, dispatches this kernel over the canvas, swaps `frontMask`/`backMask`,
// and repeats until convergence (no new pixels added on a pass). On each
// pass, for every grid pixel:
//
//   1. If the pixel is already marked in `frontMask`, carry the bit forward
//      to `backMask`.
//   2. Otherwise, if the source-texture pixel matches `targetColor` within
//      `tolerance` AND any 4-connected neighbor is already marked in
//      `frontMask`, mark this pixel in `backMask`.
//   3. Otherwise, write 0 — the pixel is unreachable from the seed under
//      the current mask front.
//
// After convergence the caller stamps `fillColor` into the canvas wherever
// the final mask is set, in a separate compositing pass.
//
// This replaces the prior color-replace kernel, which marked every pixel
// matching `targetColor` regardless of whether it was connected to the seed.
// That behavior is a global threshold replace, not a flood fill — visually
// it'd bleed the bucket across disconnected regions of the same color.
//
// NOTE: not yet wired up. The CPU `floodFill` in CanvasRenderer is still
// the active code path. See the TODO at its top for follow-up work to
// drive this kernel from Swift (mask textures, iteration loop, final blit).
kernel void floodFillKernel(texture2d<float, access::read>  inputTexture [[texture(0)]],
                            texture2d<float, access::read>  frontMask    [[texture(1)]],
                            texture2d<float, access::write> backMask     [[texture(2)]],
                            constant float4 &targetColor [[buffer(0)]],
                            constant float  &tolerance   [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    const uint w = inputTexture.get_width();
    const uint h = inputTexture.get_height();
    if (gid.x >= w || gid.y >= h) {
        return;
    }

    // Already part of the fill — carry forward.
    float front = frontMask.read(gid).r;
    if (front > 0.5) {
        backMask.write(float4(1.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    // Color must match the target within tolerance to be reachable.
    float4 px = inputTexture.read(gid);
    if (distance(px.rgb, targetColor.rgb) > tolerance) {
        backMask.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    // 4-connected neighbor check — propagation, not a global match. This is
    // what makes the kernel a real flood fill instead of a threshold replace.
    bool neighborMarked = false;
    if (gid.x > 0     && frontMask.read(uint2(gid.x - 1, gid.y)).r > 0.5) neighborMarked = true;
    if (gid.x + 1 < w && frontMask.read(uint2(gid.x + 1, gid.y)).r > 0.5) neighborMarked = true;
    if (gid.y > 0     && frontMask.read(uint2(gid.x, gid.y - 1)).r > 0.5) neighborMarked = true;
    if (gid.y + 1 < h && frontMask.read(uint2(gid.x, gid.y + 1)).r > 0.5) neighborMarked = true;

    backMask.write(float4(neighborMarked ? 1.0 : 0.0, 0.0, 0.0, 1.0), gid);
}
