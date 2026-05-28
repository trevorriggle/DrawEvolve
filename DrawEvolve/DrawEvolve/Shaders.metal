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
    float hardness;         // 0.0 (soft) to 1.0 (hard) — RAW SLIDER VALUE.
                            // Each stamp shader applies a perceptual remap
                            // on this uniform before using it (see
                            // `perceivedHardness` below). The lower half
                            // of the slider needs to feel airbrush-soft,
                            // so the remap compresses low slider values
                            // toward zero rather than spreading them out.
    float pressure;         // 0.0 to 1.0 from Apple Pencil
    float grainDensity;     // experiment/brush-variety-v1: charcoal grain
                            // intensity. Existing shaders ignore it; only
                            // `charcoalFragmentShader` reads it. Adding a
                            // trailing field keeps the C-ABI prefix stable
                            // for the brush/eraser/blur/smudge shaders.
    float2 tileOrigin;      // Layer-pixel coords of the framebuffer's (0,0).
                            // Tiling migration Phase 2: when the framebuffer
                            // is the monolithic layer texture, this is (0,0)
                            // and every shader's `in.position.xy + tileOrigin`
                            // is mathematically identical to `in.position.xy`
                            // alone. Phase 4+: when the framebuffer is a tile,
                            // this becomes (tx * tileSize, ty * tileSize) so
                            // selection mask sampling, procedural grain seeds,
                            // and canvas-sized texture lookups keep producing
                            // the same layer-space values they did pre-tiling.
    float pressureAlpha;    // ALPHA pressure (BLOCKER B). Fragment shaders
                            // multiply `alpha *= opacity * pressureAlpha`
                            // here instead of `* pressure` so the size-fudge
                            // value 0.75 used for non-Pencil input doesn't
                            // silently cap the first stamp's alpha at 75%.
                            // Pencil: equal to `pressure`. Finger/mouse: 1.0.
                            // `pressure` is still the SIZE knob (vertex
                            // shader's `pointSize = size * pressure`).
                            // Trailing position preserves C-ABI prefix for
                            // shaders that don't reference this field.
};

// Perceptual hardness remap. Earlier this used `sqrt(h)` so slider 0.5
// landed at ~50% opaque area, but the side-effect was that the lower
// half of the slider all rendered firmer than artists expected — sqrt
// pushes weak values UP (0.25 → 0.5), starving the slider of true
// airbrush territory at the soft end.
//
// `h²` compresses low slider values toward zero, giving the bottom
// half real feathering (slider 0.25 → 0.0625, slider 0.5 → 0.25) while
// keeping 1.0 → 1.0 for hard-edge work. Each quarter of the slider
// now reads as a meaningfully different brush. Clamp keeps the curve
// well-defined on out-of-range inputs.
static float perceivedHardness(float h) {
    float clamped = clamp(h, 0.0, 1.0);
    return clamped * clamped;
}

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

// MARK: - Tile composite shaders (Phase 3)
//
// Per-tile composite path for compositeLayersToTextureViaTiles. The output is
// a canvas-sized render target; this shader draws one input tile texture at
// the tile's integer pixel rect within the canvas. Several invariants make the
// rasterization bit-exact with the legacy full-canvas-quad composite:
//
//   1. Rect inputs are int4 (origin x/y + size w/h). No float bridging in
//      Swift — values pass through unchanged.
//   2. Output dimensions are powers of 2 today (2048 or 4096), so pixel/dim
//      is exactly representable in float.
//   3. Quad corners land on exact integer pixel boundaries in the output;
//      the rasterizer covers the same pixel centers as a full-canvas-quad
//      composite would for that source region.
//   4. Fragment shader uses NEAREST sampler — UV at texel centers maps each
//      output pixel to exactly one source texel.
//
// Together these guarantee `compositeLayersToTextureViaTiles` produces
// byte-identical output to the legacy `compositeLayersToTexture` given the
// same tile-grid <-> monolithic invariant Phase 2 established.
struct TileCompositeUniforms {
    int4 tileRect;     // (originX, originY, width, height) in output pixels
    int2 outputSize;   // canvas pixel dims
};

vertex VertexOut compositeTileVertexShader(uint vertexID [[vertex_id]],
                                            constant TileCompositeUniforms &uniforms [[buffer(0)]]) {
    VertexOut out;

    // Unit-square corners in CCW. texCoord (0,0) = top-left of source tile so
    // sampling produces "texture row 0 = top of canvas" just like the layer
    // shader does.
    float2 unitPos[6] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
        float2(0.0, 1.0), float2(1.0, 0.0), float2(1.0, 1.0)
    };
    float2 unit = unitPos[vertexID];

    int4 r = uniforms.tileRect;
    int2 o = uniforms.outputSize;

    // Quad corner in output pixel coords. Integer arithmetic in Swift; the
    // float() conversion here on an integer up to 8192 is exact in IEEE 754.
    float pixelX = float(r.x) + unit.x * float(r.z);
    float pixelY = float(r.y) + unit.y * float(r.w);

    // Output pixel → NDC. For power-of-2 output dims and integer pixel coords,
    // pixelX / float(o.x) is exact, so the rasterizer covers pixels
    // [r.x .. r.x + r.z) horizontally — bit-exact with a full-canvas quad
    // that just happened to write only into this rect.
    float ndcX = (pixelX / float(o.x)) * 2.0 - 1.0;
    float ndcY = (pixelY / float(o.y)) * 2.0 - 1.0;
    ndcY = -ndcY;   // Metal NDC y-up vs canvas pixel y-down.

    out.position = float4(ndcX, ndcY, 0.0, 1.0);
    out.texCoord = unit;   // 0..1 across tile — interpolated to texel centers.
    out.pointSize = 1.0;
    return out;
}

fragment float4 compositeTileFragmentShader(VertexOut in [[stage_in]],
                                             texture2d<float> tex [[texture(0)]],
                                             constant float &opacity [[buffer(0)]]) {
    // NEAREST sampler. Phase 3 invariant: each output pixel maps to exactly
    // one source texel — no bilinear blending across texels. Combined with
    // integer-aligned quad corners and power-of-2 output dims, this makes
    // the composite bit-exact with the legacy full-canvas-quad path.
    constexpr sampler tileSampler(mag_filter::nearest, min_filter::nearest);
    float4 color = tex.sample(tileSampler, in.texCoord);
    color.a *= opacity;
    return color;
}

// MARK: - Tile direct-to-drawable shaders (Phase 6 / Tier C 9)
//
// Per-tile vertex shader that maps a tile's canvas-pixel rect through the
// full canvas-to-drawable transform chain (fit-to-longest, zoom, rotation,
// pan, flip). Used by the tile-direct rendering path that replaces the
// per-layer compose-into-intermediate + sample-as-fullscreen-quad pair
// with a single per-layer pass that rasterizes each visible tile directly
// onto the drawable.
//
// The math is composed line-for-line from `quadVertexShaderWithTransform`
// (the legacy fullscreen-quad-with-transform), with one extra step at
// the front: convert the tile's canvas-pixel corner to the equivalent
// canvas-fraction NDC, then run the existing pipeline. The math is
// algebraically identical to the legacy path for a quad covering the
// same canvas region.
//
// **Sampler choice:** the fragment shader uses LINEAR to match the
// legacy display path (`textureDisplayShader` uses LINEAR). NEAREST
// would pixel-snap at oblique angles and visibly differ. LINEAR can
// produce 1-texel seams at tile boundaries when sub-pixel sample
// positions don't reach into the adjacent tile — acceptable visual
// trade-off for v1; future work could add per-tile texel-overlap
// padding to eliminate seams.
//
// **Bit-exact vs legacy at axis-aligned transforms:** zoom=1.0 with no
// rotation/flip/sub-pixel-pan produces drawable pixels that land on
// texel centers; LINEAR = NEAREST in that regime; output is byte-exact
// with the legacy path. At rotated / sub-pixel transforms ULP-level
// differences are expected from floating-point vertex math composing
// differently per-tile vs once-per-fullscreen-quad.
struct TileDirectUniforms {
    int4   tileRect;       // (originX, originY, width, height) in canvas pixels
    float2 canvasSize;     // canvas dimensions in canvas pixels
    float4 transform;      // [zoom, panX, panY, rotationRadians]
    float2 viewportSize;   // viewport in UIKit points
    float2 flipState;      // [flipH, flipV] — each 0 or 1
};

vertex VertexOut tileDirectVertexShader(uint vertexID [[vertex_id]],
                                         constant TileDirectUniforms &u [[buffer(0)]]) {
    VertexOut out;

    // Unit-square corners; texCoord matches so sampling produces "texture
    // row 0 = tile-y 0" — same convention as the per-tile composite shader.
    float2 unitPos[6] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
        float2(0.0, 1.0), float2(1.0, 0.0), float2(1.0, 1.0)
    };
    float2 unit = unitPos[vertexID];

    int4 rect = u.tileRect;

    // Tile vertex position in canvas-pixel space.
    float pixelX = float(rect.x) + unit.x * float(rect.z);
    float pixelY = float(rect.y) + unit.y * float(rect.w);

    // Canvas-pixel → canvas-fraction (0..1).
    float2 frac = float2(pixelX / u.canvasSize.x, pixelY / u.canvasSize.y);

    // Canvas-fraction → equivalent fullscreen-quad NDC position.
    // Legacy quadVertexShaderWithTransform takes NDC then does
    // (ndc * 0.5 + 0.5) * viewport. The texCoord convention is UIKit-Y-down
    // (top of texture = canvas y=0 = NDC y=+1), so frac.y=0 → ndc.y=+1.
    float2 ndcPos = float2(frac.x * 2.0 - 1.0, 1.0 - 2.0 * frac.y);

    // From here, EXACTLY the legacy quadVertexShaderWithTransform pipeline.

    float zoom = u.transform.x;
    float2 pan = float2(u.transform.y, u.transform.z);
    float rotation = u.transform.w;
    float2 viewport = u.viewportSize;

    // Aspect-ratio correction: canvas-square fills the longer viewport axis
    // at zoom=1.
    float viewportAspect = viewport.x / viewport.y;
    float2 scale = float2(1.0, 1.0);
    if (viewportAspect > 1.0) {
        scale.y = viewportAspect;
    } else {
        scale.x = 1.0 / viewportAspect;
    }
    float2 correctedPos = ndcPos * scale;

    // NDC → Y-up pixel space.
    float2 screenPos = (correctedPos * 0.5 + 0.5) * viewport;

    // Zoom around viewport center.
    float2 screenCenter = viewport * 0.5;
    screenPos = (screenPos - screenCenter) * zoom + screenCenter;

    // Rotate around viewport center.
    if (rotation != 0.0) {
        float2 rel = screenPos - screenCenter;
        float c = cos(rotation);
        float s = sin(rotation);
        screenPos = float2(rel.x * c - rel.y * s, rel.x * s + rel.y * c) + screenCenter;
    }

    // Pan. UIKit Y-down points; screenPos is Y-up pixels — flip pan.y.
    screenPos += float2(pan.x, -pan.y);

    // Flip last in screen space.
    if (u.flipState.x > 0.5) screenPos.x = viewport.x - screenPos.x;
    if (u.flipState.y > 0.5) screenPos.y = viewport.y - screenPos.y;

    // Back to NDC.
    float2 finalPos = (screenPos / viewport) * 2.0 - 1.0;

    out.position = float4(finalPos, 0.0, 1.0);
    out.texCoord = unit;
    out.pointSize = 1.0;

    return out;
}

fragment float4 tileDirectFragmentShader(VertexOut in [[stage_in]],
                                          texture2d<float> tex [[texture(0)]],
                                          constant float &opacity [[buffer(0)]]) {
    // LINEAR to match legacy textureDisplayShader. See file header for
    // the seam-vs-aliasing trade-off discussion.
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float4 color = tex.sample(s, in.texCoord);
    color.a *= opacity;
    return color;
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

// Sample the selection mask at the fragment's LAYER pixel position. Returns
// 1.0 inside the selection (or everywhere when no-mask 1×1 is bound) and
// 0.0 outside; soft-edge selections produce in-between values.
//
// `tileOrigin` is MANDATORY — no overload, no default. It's the layer-pixel
// coords of the framebuffer's (0,0). Pre-tiling callers pass (0,0); tiled
// callers pass the tile's pixel offset. A missed offset would silently
// sample the wrong region of the mask; the mandatory positional argument
// forces callers to think about it (Phase 2 / Task 1 refinement #1).
static float sampleSelectionMask(texture2d<float> mask,
                                 float4 fragPosition,
                                 float2 tileOrigin) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 maskSize = float2(mask.get_width(), mask.get_height());
    // For the 1×1 no-mask texture, maskSize is (1,1) and any UV samples
    // the single pixel (= 1.0). For the canvas-sized real mask, maskSize
    // matches the layer texture's dims and `layerPos` is in those same
    // pixel units.
    float2 layerPos = fragPosition.xy + tileOrigin;
    return mask.sample(s, layerPos / maskSize).r;
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
    float hardness = perceivedHardness(uniforms.hardness);
    float alpha;
    if (hardness >= 0.99) {
        // Hard brush: sharp cutoff
        alpha = dist < 1.0 ? 1.0 : 0.0;
    } else {
        // Soft brush: smooth falloff
        float softness = 1.0 - hardness;
        float edge = 1.0 - softness;
        alpha = smoothstep(1.0, edge, dist);
    }

    // Apply opacity, then clip to selection. Pressure drives SIZE only
    // (vertex shader's `pointSize = size * pressure`) — opacity is NOT
    // pressure-modulated. Real paint doesn't get more transparent under
    // light pressure; the user's opacity slider is the authoritative
    // value. This also fixes the "stroke draws at ~60% opacity sometimes"
    // bug where average pressure capped per-stamp alpha and wet-ink
    // saturation prevented overlap recovery.
    alpha *= uniforms.opacity;
    alpha *= sampleSelectionMask(selectionMask, in.position, uniforms.tileOrigin);

    return float4(uniforms.color.rgb, alpha * uniforms.color.a);
}

// Fragment shader for eraser (outputs transparent pixels)
fragment float4 eraserFragmentShader(VertexOut in [[stage_in]],
                                      float2 pointCoord [[point_coord]],
                                      constant BrushUniforms &uniforms [[buffer(0)]],
                                      texture2d<float> selectionMask [[texture(2)]]) {
    float2 center = float2(0.5, 0.5);
    float dist = distance(pointCoord, center) * 2.0;

    float hardness = perceivedHardness(uniforms.hardness);
    float alpha;
    if (hardness >= 0.99) {
        alpha = dist < 1.0 ? 1.0 : 0.0;
    } else {
        float softness = 1.0 - hardness;
        float edge = 1.0 - softness;
        alpha = smoothstep(1.0, edge, dist);
    }

    // Pressure drives SIZE only — opacity slider is authoritative.
    // Matches brushFragmentShader for consistency: the eraser is the
    // inverse stamp of brush and shouldn't accidentally soft-erase at
    // light Pencil pressure.
    alpha *= uniforms.opacity;
    alpha *= sampleSelectionMask(selectionMask, in.position, uniforms.tileOrigin);

    // Return transparent black with alpha for erasing
    return float4(0.0, 0.0, 0.0, alpha);
}

// MARK: - Experimental Brush Variants (experiment/brush-variety-v1)
//
// Each shader below is a stamp-fragment variant — same point-sprite vertex
// shader, same `BrushUniforms`, same standard alpha blend pipeline as
// `brushFragmentShader`. The differences are local: edge profile, opacity
// modulation, procedural grain. None of them sample a texture (texture
// cache is a v1.2 task). Procedural grain uses a cheap 2D hash of the
// fragment's screen-space position; it deliberately decorrelates per
// stamp (because `in.position` differs across stamps even at the same
// `pointCoord`) which is what gives charcoal/pencil their stochastic
// feel without an explicit per-stamp jitter seed.

// Cheap stochastic noise. fract(sin(...)) is the classic GLSL/Metal hash;
// fine for grain modulation, not cryptographic.
static float brushHash(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

// 1. Pencil — sharp narrow edge with directional paper-tooth grain.
// Mimics graphite on textured paper: pressure drives darkness more than
// width, and the strokes show the paper texture as light streaks.
fragment float4 pencilFragmentShader(VertexOut in [[stage_in]],
                                      float2 pointCoord [[point_coord]],
                                      constant BrushUniforms &uniforms [[buffer(0)]],
                                      texture2d<float> selectionMask [[texture(2)]]) {
    // Layer-space fragment position. Pre-tiling: in.position.xy is already
    // the layer-pixel coord and tileOrigin is (0,0). Tiled: in.position.xy
    // is tile-local and tileOrigin re-anchors it. Used for both the
    // procedural grain seed AND the selection mask sample — without this
    // a brush stamp crossing a tile boundary would show a grain seam.
    float2 layerPos = in.position.xy + uniforms.tileOrigin;

    float2 center = float2(0.5, 0.5);
    float dist = distance(pointCoord, center) * 2.0;

    // Pencil edge is ALWAYS fairly sharp — even if the user softens
    // hardness in the panel, force a floor of 0.85 so the look stays
    // identifiably "pencil." Without this floor, pencil at hardness 0.5
    // is indistinguishable from a default brush at hardness 0.5.
    // The perceptual remap runs BEFORE the floor so the slider's UX
    // matches the other tools; the floor still kicks in for any
    // remapped value below 0.85.
    //
    // Disc formula: `1 - smoothstep(hardness, 1, dist)`. Well-defined
    // for all hardness in [0,1] including
    // hardness=1.0 (smoothstep with equal edges → 0 inside, 1 outside,
    // so the disc reads as solid then drops to 0 past dist=1). The
    // previous reversed form `smoothstep(1.0, hardness, dist)` left a
    // hole at the disc center when hardness=1.0 (MSL behavior with
    // edge0 == edge1 is implementation-defined; Apple's GPU returns 0
    // for x ≤ edge0, which created the hole).
    float hardness = max(perceivedHardness(uniforms.hardness), 0.85);
    float alpha = 1.0 - smoothstep(hardness, 1.0, dist);

    // Paper-tooth grain — three-octave decorrelated hash. The earlier
    // 2-octave design (coarse `floor(layerPos * 0.03)` quilt + fine
    // `layerPos * 0.15` smooth sample) sampled brushHash at multipliers
    // below its decorrelation floor: adjacent x-pixels saw sin-argument
    // deltas of only ~2 radians, so the output traced the level curves
    // of the hash constants (12.9898, 78.233) as diagonal stripes, and
    // the `floor` produced an axis-aligned 33×33 quilt on top. Their
    // sum + threshold read as diamonds/chevrons, not paper.
    //
    // The fix puts every octave at a multiplier ≥ 0.6 where adjacent
    // pixels see sin-argument deltas of ≥ ~7.8 radians (over one full
    // period), and gives each octave its own phase offset so they
    // don't constructively align. Multipliers, offsets, and weights
    // are deliberately distinct from charcoal's grain so the two
    // brushes' noise fields are decorrelated, not identical-up-to-
    // threshold.
    //
    // Threshold stays at (0.3, 0.7) — lighter than charcoal's
    // (0.25, 0.75) — so pencil reads as broken streaks on tooth
    // rather than charcoal's heavy on/off speckle. No edge-breakup
    // term: that's charcoal's identity, not pencil's.
    float grain1 = brushHash(layerPos * 0.7);
    float grain2 = brushHash(layerPos * 1.1 + float2(5.0, 11.0));
    float grain3 = brushHash(layerPos * 2.7 + float2(23.0, 3.0));
    float tooth = grain1 * 0.45 + grain2 * 0.35 + grain3 * 0.20;
    float grain = smoothstep(0.3, 0.7, tooth);
    // Grain multiplies alpha directly — paper-tooth pixels (grain ≈ 0)
    // deposit nothing, so dense stamp overlap can't saturate them into a
    // uniform dark stroke. A nonzero floor here washes the paper-show-
    // through out after ~20 overlapping stamps along a stroke.
    alpha *= grain;

    // Pressure curve: pow 1.5 — light strokes still build up across
    // repeated passes, but mid-pressure shows enough alpha for the
    // grain to actually read. Reads `pressureAlpha` (not `pressure`)
    // so non-Pencil input doesn't permanently cap pencil — see
    // BrushUniforms.
    float pressureOpacity = uniforms.pressureAlpha * sqrt(uniforms.pressureAlpha);
    alpha *= uniforms.opacity * pressureOpacity;

    alpha *= sampleSelectionMask(selectionMask, in.position, uniforms.tileOrigin);
    return float4(uniforms.color.rgb, alpha * uniforms.color.a);
}

// 2. Marker — flat-topped, very crisp edge, subtle felt-tip horizontal
// streak. Distinct from brush (which has a soft falloff option). The
// streak comes from ink wicking along felt fibers along the stroke
// direction.
fragment float4 markerFragmentShader(VertexOut in [[stage_in]],
                                      float2 pointCoord [[point_coord]],
                                      constant BrushUniforms &uniforms [[buffer(0)]],
                                      texture2d<float> selectionMask [[texture(2)]]) {
    float2 layerPos = in.position.xy + uniforms.tileOrigin;
    float2 center = float2(0.5, 0.5);
    float dist = distance(pointCoord, center) * 2.0;

    // Softer-than-Sharpie, harder-than-brush feather: chisel-tip marker
    // ink doesn't deposit at a perfectly sharp edge, but it's also not
    // airbrushed. 15% feather sits between ink pen (3%) and brush
    // (~36% at default hardness).
    float alpha = 1.0 - smoothstep(0.85, 1.0, dist);

    // Felt-tip streak: very subtle horizontal banding (~8% modulation)
    // simulating ink wicking through felt fibers along the stroke
    // axis. Y is quantized to coarse bands so adjacent rows share
    // values, creating visible streaks rather than per-pixel noise.
    float streak = mix(0.92, 1.0, brushHash(float2(13.0, floor(layerPos.y * 0.2))));
    alpha *= streak;

    // Pressure → SIZE primarily, plus a mild opacity taper so stroke
    // ends fade as the Pencil lifts. Floor at 0.5 keeps the body at
    // near-full saturation for typical mid-pressure input — much
    // milder than charcoal's 0.1 floor.
    alpha *= uniforms.opacity * mix(0.5, 1.0, uniforms.pressureAlpha);

    alpha *= sampleSelectionMask(selectionMask, in.position, uniforms.tileOrigin);
    return float4(uniforms.color.rgb, alpha * uniforms.color.a);
}

// 4. Airbrush — very soft Gaussian-bell falloff plus visible mist grain.
// Differs from a soft brush in that the density CONCENTRATES in the
// center and fades to nothing at the edge, with stochastic mist
// speckle on top. Density builds via overlap, not single-stamp
// opacity (defaults to 0.08 alpha per stamp).
fragment float4 airbrushFragmentShader(VertexOut in [[stage_in]],
                                        float2 pointCoord [[point_coord]],
                                        constant BrushUniforms &uniforms [[buffer(0)]],
                                        texture2d<float> selectionMask [[texture(2)]]) {
    // Layer-space fragment position; see pencilFragmentShader for rationale.
    float2 layerPos = in.position.xy + uniforms.tileOrigin;

    float2 center = float2(0.5, 0.5);
    float dist = distance(pointCoord, center) * 2.0;

    // Quadratic falloff. Was quartic (`falloff⁴`); under wet-ink the
    // strong concentration left most of the stamp invisible because
    // `falloff⁴ × per-stamp-opacity` dropped to ~0 by half-radius —
    // the visible airbrush ended up at ~50% of the size indicator.
    // Quadratic spreads the visible portion to ~80% of the indicator
    // while still keeping center-weighted mist character.
    float falloff = 1.0 - clamp(dist, 0.0, 1.0);
    float alpha = falloff * falloff;

    // Mist grain — bumped to 35% modulation so the airbrush reads as
    // stippled mist instead of a smooth halo. Combined with the
    // quadratic falloff above, individual stamps look like sprayed
    // particles rather than soft gradient dots.
    float grain = mix(1.0, brushHash(layerPos * 2.0), 0.35);
    alpha *= grain;

    // Pressure modulates opacity, not size. Floor at 0.6 + pow(x, 1.5)
    // curve so a light Apple Pencil touch still deposits ~36% of full
    // mist alpha — previously the squared curve through the
    // [minPressureSize=0.3, maxPressureSize=1.0] remap left light Pencil
    // strokes at ~14% of finger-touch flow, requiring artists to mash
    // hard to register any value. Finger fallback returns pressureAlpha=1.0
    // (see computePressure in MetalCanvasView) so finger input lands at
    // mix(0.6, 1.0, 1.0) = 1.0 — unchanged. Reads `pressureAlpha` so
    // non-Pencil input doesn't cap airbrush — see BrushUniforms.
    //
    // NOTE: this is the non-premul fallback path. Production airbrush
    // strokes route through the wet-ink pipeline (airbrushFragmentShaderPremul
    // below) when session.wetInkActive is true, which is the normal case.
    // This branch only fires on the legacy renderStroke fallback (e.g.
    // scratch allocation failure at touchesBegan). Kept in defensive
    // symmetry with the premul variant so the curves don't drift.
    float pressureOpacity = mix(0.6, 1.0, uniforms.pressureAlpha * sqrt(uniforms.pressureAlpha));
    alpha *= uniforms.opacity * pressureOpacity;

    alpha *= sampleSelectionMask(selectionMask, in.position, uniforms.tileOrigin);
    return float4(uniforms.color.rgb, alpha * uniforms.color.a);
}

// 5. Charcoal — soft irregular edge plus VERY heavy procedural grain.
// The grain term is gated by `uniforms.grainDensity` so the settings
// panel can dial from smooth (effectively a soft brush) to fully
// speckled. At the default density 0.9 set by BrushSettings.defaults,
// it reads unmistakably as charcoal — rough, broken, textured.
fragment float4 charcoalFragmentShader(VertexOut in [[stage_in]],
                                        float2 pointCoord [[point_coord]],
                                        constant BrushUniforms &uniforms [[buffer(0)]],
                                        texture2d<float> selectionMask [[texture(2)]]) {
    // Layer-space fragment position. Charcoal is the heaviest user of
    // procedural grain in this codebase (4 brushHash calls, 3 octaves +
    // edge breakup). All 4 grain seeds AND the selection-mask sample must
    // be in layer-space — anything tile-local would produce a visible
    // seam wherever a single stamp crosses a tile boundary.
    float2 layerPos = in.position.xy + uniforms.tileOrigin;

    float2 center = float2(0.5, 0.5);
    float dist = distance(pointCoord, center) * 2.0;

    // See pencilFragmentShader for the rationale on the disc formula —
    // `1 - smoothstep(hardness, 1, dist)` avoids the hole-in-the-disc
    // bug that the reversed `smoothstep(1, edge, dist)` pattern produced
    // at hardness=1.0 on Apple's GPU.
    float hardness = perceivedHardness(uniforms.hardness);
    float alpha = 1.0 - smoothstep(hardness, 1.0, dist);

    // Heavy three-octave grain — was two-octave. Each octave is the
    // hash() at a different spatial frequency; summing makes the
    // texture rocky and irregular rather than blocky or noisy.
    float grain1 = brushHash(layerPos * 0.6);
    float grain2 = brushHash(layerPos * 1.4 + float2(13.0, 7.0));
    float grain3 = brushHash(layerPos * 3.1 + float2(31.0, 19.0));
    float grain = grain1 * 0.5 + grain2 * 0.3 + grain3 * 0.2;

    // Steepen the grain into a black/white speckle (was linear). This
    // is what gives charcoal its broken edges and patchy fill — the
    // pigment grabs the paper unevenly. smoothstep maps the noise into
    // a high-contrast on/off pattern that reads as char fragments.
    grain = smoothstep(0.25, 0.75, grain);

    // grainDensity 0 → no grain (multiplier = 1), 1 → full grain.
    // At default density 0.9 the strokes are aggressively speckled.
    alpha *= mix(1.0, grain, clamp(uniforms.grainDensity, 0.0, 1.0));

    // EDGE BREAKUP — band starts at dist=0.3 (was 0.4) and the noise
    // modulation is stronger (0.85 vs 0.6) so the charcoal disc reads
    // as a chunky broken silhouette, not a clean circle with grain
    // inside. Under wet-ink each pixel's max alpha is capped, so this
    // edge irregularity is fully visible (overlapping stamps used to
    // fill in the gaps with the OLD blend).
    float edgeBand = smoothstep(0.3, 1.0, dist);
    float edgeBreakup = mix(1.0, brushHash(layerPos * 2.3 + float2(7.0, 5.0)), edgeBand * 0.85);
    alpha *= edgeBreakup;

    // Small floor so charcoal still marks at the lightest touch, but a
    // real Apple-Pencil lift-off taper is visible — the stroke tail
    // dissolves into the same chunky catches a charcoal stick leaves as
    // it leaves the paper.
    float pressureOpacity = mix(0.1, 1.0, uniforms.pressureAlpha);
    alpha *= uniforms.opacity * pressureOpacity;

    alpha *= sampleSelectionMask(selectionMask, in.position, uniforms.tileOrigin);
    return float4(uniforms.color.rgb, alpha * uniforms.color.a);
}

// MARK: - Wet-ink premultiplied stamp variants (Phase A.5 onward)
//
// Each shader below mirrors its OLD counterpart's body up through alpha
// computation, then emits PREMULTIPLIED output: (rgb * finalAlpha, finalAlpha)
// where finalAlpha = alpha * color.a. Paired with a pipeline that uses
// `sourceRGBBlendFactor = .one` instead of `.sourceAlpha`. Mathematically
// identical framebuffer result vs. OLD shader+pipeline when blending into
// the atlas with standard alpha-over:
//
//   OLD: (color.rgb, finalA) with (srcA, 1-srcA)
//        → dst.rgb = color.rgb * finalA + dst.rgb * (1-finalA)
//   NEW: (color.rgb * finalA, finalA) with (one, 1-srcA)
//        → dst.rgb = color.rgb * finalA + dst.rgb * (1-finalA)
//
// Identical. Phase A.5's probe is what proves this empirically — see
// `runShaderEquivalencePhaseA5Probe` in CanvasRenderer.
//
// These shaders are also what gets used by the wet-ink deposit pass (Phase B+),
// since the `.max/.max` deposit blend requires premultiplied source for the
// max-of-RGB-channels to behave correctly across stamps of different alphas.

// 1. Brush — premul.
fragment float4 brushFragmentShaderPremul(VertexOut in [[stage_in]],
                                           float2 pointCoord [[point_coord]],
                                           constant BrushUniforms &uniforms [[buffer(0)]],
                                           texture2d<float> selectionMask [[texture(2)]]) {
    float2 center = float2(0.5, 0.5);
    float dist = distance(pointCoord, center) * 2.0;

    float hardness = perceivedHardness(uniforms.hardness);
    float alpha;
    if (hardness >= 0.99) {
        alpha = dist < 1.0 ? 1.0 : 0.0;
    } else {
        float softness = 1.0 - hardness;
        float edge = 1.0 - softness;
        alpha = smoothstep(1.0, edge, dist);
    }

    // Pressure → SIZE only. See brushFragmentShader for rationale.
    alpha *= uniforms.opacity;
    alpha *= sampleSelectionMask(selectionMask, in.position, uniforms.tileOrigin);

    float finalAlpha = alpha * uniforms.color.a;
    return float4(uniforms.color.rgb * finalAlpha, finalAlpha);
}

// 2. Pencil — premul. Disc formula matches OLD pencil after fix:
// `1 - smoothstep(hardness, 1, dist)` (well-defined at hardness=1.0).
fragment float4 pencilFragmentShaderPremul(VertexOut in [[stage_in]],
                                            float2 pointCoord [[point_coord]],
                                            constant BrushUniforms &uniforms [[buffer(0)]],
                                            texture2d<float> selectionMask [[texture(2)]]) {
    float2 layerPos = in.position.xy + uniforms.tileOrigin;

    float2 center = float2(0.5, 0.5);
    float dist = distance(pointCoord, center) * 2.0;

    float hardness = max(perceivedHardness(uniforms.hardness), 0.85);
    float alpha = 1.0 - smoothstep(hardness, 1.0, dist);

    // See pencilFragmentShader for the rationale on this grain design.
    // Frequencies must stay in lockstep with the standard variant.
    float grain1 = brushHash(layerPos * 0.7);
    float grain2 = brushHash(layerPos * 1.1 + float2(5.0, 11.0));
    float grain3 = brushHash(layerPos * 2.7 + float2(23.0, 3.0));
    float tooth = grain1 * 0.45 + grain2 * 0.35 + grain3 * 0.20;
    float grain = smoothstep(0.3, 0.7, tooth);
    alpha *= grain;

    float pressureOpacity = uniforms.pressureAlpha * sqrt(uniforms.pressureAlpha);
    alpha *= uniforms.opacity * pressureOpacity;

    alpha *= sampleSelectionMask(selectionMask, in.position, uniforms.tileOrigin);

    float finalAlpha = alpha * uniforms.color.a;
    return float4(uniforms.color.rgb * finalAlpha, finalAlpha);
}

// 3. Marker — premul. Same identity as OLD: very crisp edge + felt
// streak. See markerFragmentShader for design rationale.
fragment float4 markerFragmentShaderPremul(VertexOut in [[stage_in]],
                                            float2 pointCoord [[point_coord]],
                                            constant BrushUniforms &uniforms [[buffer(0)]],
                                            texture2d<float> selectionMask [[texture(2)]]) {
    float2 layerPos = in.position.xy + uniforms.tileOrigin;
    float2 center = float2(0.5, 0.5);
    float dist = distance(pointCoord, center) * 2.0;

    float alpha = 1.0 - smoothstep(0.85, 1.0, dist);

    float streak = mix(0.92, 1.0, brushHash(float2(13.0, floor(layerPos.y * 0.2))));
    alpha *= streak;

    // Pressure → SIZE primarily, plus mild opacity taper on lift. See
    // markerFragmentShader for rationale.
    alpha *= uniforms.opacity * mix(0.5, 1.0, uniforms.pressureAlpha);

    alpha *= sampleSelectionMask(selectionMask, in.position, uniforms.tileOrigin);

    float finalAlpha = alpha * uniforms.color.a;
    return float4(uniforms.color.rgb * finalAlpha, finalAlpha);
}

// 5. Airbrush — premul. Quadratic falloff (size indicator accurate),
// mist grain at 35% modulation.
fragment float4 airbrushFragmentShaderPremul(VertexOut in [[stage_in]],
                                              float2 pointCoord [[point_coord]],
                                              constant BrushUniforms &uniforms [[buffer(0)]],
                                              texture2d<float> selectionMask [[texture(2)]]) {
    float2 layerPos = in.position.xy + uniforms.tileOrigin;

    float2 center = float2(0.5, 0.5);
    float dist = distance(pointCoord, center) * 2.0;

    float falloff = 1.0 - clamp(dist, 0.0, 1.0);
    float alpha = falloff * falloff;

    float grain = mix(1.0, brushHash(layerPos * 2.0), 0.35);
    alpha *= grain;

    // Pressure curve: mix(0.6, 1.0, pow(pressureAlpha, 1.5)). The 0.6 floor
    // means a light Apple Pencil touch still deposits ~36% of full mist
    // alpha. The previous squared curve through the
    // [minPressureSize=0.3, maxPressureSize=1.0] remap left light Pencil
    // strokes at ~14% of finger-touch flow (finger returns pressureAlpha=1.0,
    // Pencil at 10% force returns ~0.37). Finger fallback lands at
    // mix(0.6, 1.0, 1.0) = 1.0 — unchanged behavior on touch input.
    float pressureOpacity = mix(0.6, 1.0, uniforms.pressureAlpha * sqrt(uniforms.pressureAlpha));
    alpha *= uniforms.opacity * pressureOpacity;

    alpha *= sampleSelectionMask(selectionMask, in.position, uniforms.tileOrigin);

    float finalAlpha = alpha * uniforms.color.a;
    return float4(uniforms.color.rgb * finalAlpha, finalAlpha);
}

// 6. Charcoal — premul. Disc formula matches OLD charcoal after fix.
fragment float4 charcoalFragmentShaderPremul(VertexOut in [[stage_in]],
                                              float2 pointCoord [[point_coord]],
                                              constant BrushUniforms &uniforms [[buffer(0)]],
                                              texture2d<float> selectionMask [[texture(2)]]) {
    float2 layerPos = in.position.xy + uniforms.tileOrigin;

    float2 center = float2(0.5, 0.5);
    float dist = distance(pointCoord, center) * 2.0;

    float hardness = perceivedHardness(uniforms.hardness);
    float alpha = 1.0 - smoothstep(hardness, 1.0, dist);

    float grain1 = brushHash(layerPos * 0.6);
    float grain2 = brushHash(layerPos * 1.4 + float2(13.0, 7.0));
    float grain3 = brushHash(layerPos * 3.1 + float2(31.0, 19.0));
    float grain = grain1 * 0.5 + grain2 * 0.3 + grain3 * 0.2;

    grain = smoothstep(0.25, 0.75, grain);

    alpha *= mix(1.0, grain, clamp(uniforms.grainDensity, 0.0, 1.0));

    // See charcoalFragmentShader for edge-breakup design rationale.
    float edgeBand = smoothstep(0.3, 1.0, dist);
    float edgeBreakup = mix(1.0, brushHash(layerPos * 2.3 + float2(7.0, 5.0)), edgeBand * 0.85);
    alpha *= edgeBreakup;

    float pressureOpacity = mix(0.1, 1.0, uniforms.pressureAlpha);
    alpha *= uniforms.opacity * pressureOpacity;

    alpha *= sampleSelectionMask(selectionMask, in.position, uniforms.tileOrigin);

    float finalAlpha = alpha * uniforms.color.a;
    return float4(uniforms.color.rgb * finalAlpha, finalAlpha);
}

// MARK: - Wet-ink commit (Phase C onward)
//
// The commit pass runs once at touchesEnded for additive-family tools (and
// at touchesMoved-batch boundaries for tools with live writes — eraser,
// blur, smudge — under their wet-ink integration in Phase F+).
//
// Reads `strokeScratch` (canvas-sized, premultiplied), returns the sample.
// The paired pipeline state (premul-over — `sourceRGBBlendFactor = .one`,
// `destinationRGBBlendFactor = .oneMinusSourceAlpha`) composites scratch
// over the pre-stroke atlas contents.
//
// Opacity is already baked into scratch (per-stamp shaders multiplied alpha
// by opacity * pressureAlpha * mask * color.a before emitting premultiplied
// output). Commit just passes scratch through.
//
// Selection clipping is also already baked in via the deposit-time mask
// sample — commit deliberately does NOT bind the selection mask. One clip,
// at deposit (§2.2 of WET_INK_DESIGN.md).
//
// ─── Two sampling regimes ───────────────────────────────────────────
//
// There are two pipeline state objects that use these commit shaders, and
// they sample under different UV regimes — so each gets its own variant.
//
// 1. `wetInkCommit*Shader`  (NEAREST sampler) — wired to
//    `wetInkCommitPipelineState` / `wetInkEraserCommitPipelineState`.
//    Used by the touchesEnded commit pass that writes scratch into the
//    `canvasStagingAtlas`. Atlas and scratch are the same dimensions and
//    the quad is full-canvas, so UVs land on texel centers; NEAREST gives
//    a bit-exact 1:1 readback with no interpolation question.
//
// 2. `wetInkCommit*ShaderLinear`  (LINEAR sampler) — wired to
//    `wetInkCommitToDrawablePipelineState` /
//    `wetInkEraserCommitToDrawablePipelineState`. Used by the per-frame
//    live preview that composites scratch directly onto the drawable
//    through `tileDirectVertexShader`'s pan/zoom/rotation transform. UVs
//    are NOT 1:1 here. Must use LINEAR so the preview matches the post-
//    commit display path (`tileDirectFragmentShader`, also LINEAR) — if
//    the preview used NEAREST while the post-commit display used LINEAR,
//    high-frequency content (pencil tooth, charcoal grain) would visibly
//    reshape on stroke release at any zoom != 100% or non-integer pan
//    offset. The blend math is identical between the two paths; only the
//    sampler determines whether grain stays sharp (NEAREST) or gets
//    averaged with neighbors (LINEAR).

fragment float4 wetInkCommitShader(VertexOut in [[stage_in]],
                                    texture2d<float> scratch [[texture(0)]]) {
    constexpr sampler s(mag_filter::nearest, min_filter::nearest);
    return scratch.sample(s, in.texCoord);
}

// LINEAR preview variant — see the "Two sampling regimes" block above.
// Bound ONLY to `wetInkCommitToDrawablePipelineState`. Sampler must match
// the LINEAR sampling used by `tileDirectFragmentShader` so committed
// pixels don't visibly reshape on stroke release.
fragment float4 wetInkCommitShaderLinear(VertexOut in [[stage_in]],
                                          texture2d<float> scratch [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    return scratch.sample(s, in.texCoord);
}

// Eraser variant of the wet-ink commit. Reads only the alpha channel of
// `strokeScratch` (eraser RGB is always 0 — see `eraserFragmentShader`)
// and returns (0, 0, 0, scratch.a). Paired with a dest-out pipeline
// (`sourceRGBBlendFactor = .zero`, `destinationRGBBlendFactor =
// `.oneMinusSourceAlpha`) so the layer's RGB and alpha get scaled by
// (1 - scratch.a) — the standard dest-out erase op.
//
// Within-stroke no-accumulation: the deposit pass already capped scratch.a
// via .max/.max, so multiple overlapping eraser stamps at 50% opacity
// leave scratch.a at 0.5 (not 0.75 like the OLD sourceAlpha eraser
// blend would accumulate to). The commit then dest-outs at exactly 0.5
// once, instead of repeatedly partially erasing during the stroke.
fragment float4 wetInkEraserCommitShader(VertexOut in [[stage_in]],
                                          texture2d<float> scratch [[texture(0)]]) {
    constexpr sampler s(mag_filter::nearest, min_filter::nearest);
    float a = scratch.sample(s, in.texCoord).a;
    return float4(0.0, 0.0, 0.0, a);
}

// LINEAR preview variant for eraser — see the "Two sampling regimes" block
// above. Bound ONLY to `wetInkEraserCommitToDrawablePipelineState`. Same
// rationale as `wetInkCommitShaderLinear`: erasing through pencil/charcoal
// grain at non-100% zoom would visibly reshape the alpha hole on release
// without sampler parity between preview and post-commit display.
fragment float4 wetInkEraserCommitShaderLinear(VertexOut in [[stage_in]],
                                                texture2d<float> scratch [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float a = scratch.sample(s, in.texCoord).a;
    return float4(0.0, 0.0, 0.0, a);
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

// Brush-blur deposit pass — point-sprite fragment shader. Each stamp
// linearly interpolates the current layer pixel toward the pre-blurred
// neighborhood sample by `coverage`. Uses Metal framebuffer fetch
// (`[[color(0)]]`) to read the destination; the caller's pipeline
// disables fixed-function blending (replace mode).
//
// Why mix() and not premul-over: the previous design returned a
// premultiplied (blurred.rgb * alpha, blurred.a * alpha) and relied on
// sourceAlpha/oneMinusSourceAlpha blending. That ACCUMULATES alpha
// across overlapping stamps — a 50%-opacity area blurred N times has
// destination alpha asymptote to 1.0, so blur strokes visibly darken
// greys toward pure black. True spatial smoothing is a linear
// interpolation between current pixel and blurred neighborhood:
// uniform areas stay uniform, repeated stamps converge to the blurred
// sample and stop. mix() of two premultiplied colours is itself
// premultiplied, so no unpremul round-trip is needed.
fragment float4 stampBlurDepositShader(VertexOut in [[stage_in]],
                                       float2 pointCoord [[point_coord]],
                                       texture2d<float> blurredTexture [[texture(0)]],
                                       texture2d<float> selectionMask  [[texture(2)]],
                                       constant BrushUniforms &uniforms [[buffer(0)]],
                                       constant float &blurStrength [[buffer(1)]],
                                       float4 currentColor [[color(0)]]) {
    // Same disc + hardness curve as brushFragmentShader.
    float2 center = float2(0.5, 0.5);
    float dist = distance(pointCoord, center) * 2.0;

    float hardness = perceivedHardness(uniforms.hardness);
    float alpha;
    if (hardness >= 0.99) {
        alpha = dist < 1.0 ? 1.0 : 0.0;
    } else {
        float softness = 1.0 - hardness;
        float edge = 1.0 - softness;
        alpha = smoothstep(1.0, edge, dist);
    }
    float coverage = alpha * uniforms.opacity * uniforms.pressureAlpha * blurStrength;
    coverage *= sampleSelectionMask(selectionMask, in.position, uniforms.tileOrigin);

    if (coverage <= 0.0) {
        discard_fragment();
    }

    // Sample blurredTexture at this fragment's LAYER-pixel position.
    // `blurredTexture` is canvas-sized (the pre-blurred snapshot from
    // the H/V Gaussian passes), so the lookup must be in layer-space
    // even when the framebuffer is a tile.
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 layerSize = float2(blurredTexture.get_width(), blurredTexture.get_height());
    float2 layerPos = in.position.xy + uniforms.tileOrigin;
    float2 uv = layerPos / layerSize;
    float4 blurred = blurredTexture.sample(s, uv);

    return mix(currentColor, blurred, coverage);
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

// Smudge deposit — point-sprite fragment shader. Same disc + hardness
// curve as brushFragmentShader / stampBlurDepositShader. Reads the
// (just-updated) patch via the fragment's layer-pixel position mapped
// to patch UV, then linearly interpolates the current layer pixel
// toward the patch sample by `coverage`. Uses Metal framebuffer fetch
// (`[[color(0)]]`) to read the destination; the caller's pipeline
// disables fixed-function blending (replace mode).
//
// Why mix() and not premul-over: see stampBlurDepositShader's header.
// Same accumulation fix — smudging an area at low strength used to
// asymptote alpha toward 1.0 after enough strokes, pushing the area
// toward opaque. mix() of two premultiplied values is premultiplied;
// the destination converges to the carried paint instead of saturating.
//
// NB: smudgeStrength does NOT scale the deposit coverage — strength
// only drives pickup weight in the patch update pass. The deposit
// coverage is the brush mask (hardness disc) modulated by opacity *
// pressure, identical to the brush. Doubling-up strength on the
// deposit would make low-strength smudges nearly invisible (pickup *
// deposit both attenuated).
fragment float4 smudgeDepositShader(VertexOut in [[stage_in]],
                                     float2 pointCoord [[point_coord]],
                                     texture2d<float> patchTexture  [[texture(0)]],
                                     texture2d<float> selectionMask [[texture(2)]],
                                     constant BrushUniforms &uniforms [[buffer(0)]],
                                     constant SmudgeUniforms &smudge [[buffer(1)]],
                                     float4 currentColor [[color(0)]]) {
    // Same disc + hardness curve as the brush.
    float2 center = float2(0.5, 0.5);
    float dist = distance(pointCoord, center) * 2.0;

    float hardness = perceivedHardness(uniforms.hardness);
    float alpha;
    if (hardness >= 0.99) {
        alpha = dist < 1.0 ? 1.0 : 0.0;
    } else {
        float softness = 1.0 - hardness;
        float edge = 1.0 - softness;
        alpha = smoothstep(1.0, edge, dist);
    }
    float coverage = alpha * uniforms.opacity * uniforms.pressureAlpha;
    // Selection clip on deposit: outside the selection, coverage → 0
    // and the discard below short-circuits the patch sample. Pairs
    // with the pickup-side mask in smudgePatchUpdateShader.
    coverage *= sampleSelectionMask(selectionMask, in.position, uniforms.tileOrigin);

    if (coverage <= 0.0) {
        discard_fragment();
    }

    // Layer pixel position → patch UV. `smudge.stampCenter` is in
    // layer-pixel coords from the Swift caller, so `layerPx` must also
    // be in layer-pixel coords — `in.position.xy + uniforms.tileOrigin`
    // is the layer-pixel position regardless of whether the framebuffer
    // is monolithic or a tile. The patch is anchored at the current
    // stamp center with world half-size `patchHalfSize`, so the UV at
    // `layerPx` is (layerPx - center + halfSize) / (2 * halfSize). Sampler
    // clamps so fragments outside the patch's world footprint (shouldn't
    // happen — point sprite is sized to fit) read the edge.
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 layerPx = in.position.xy + uniforms.tileOrigin;
    float2 patchUV = (layerPx - smudge.stampCenter + smudge.patchHalfSize) / (2.0 * smudge.patchHalfSize);
    float4 picked = patchTexture.sample(s, patchUV);

    return mix(currentColor, picked, coverage);
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

// MARK: - Reference Image: behind-canvas pass
//
// Renders a single reference image as a textured quad positioned in
// screen (drawable-pixel) space, with optional horizontal/vertical
// flip and opacity. Used by the to-screen draw path when a reference
// is in "behind canvas" mode — the quad is encoded AFTER the canvas's
// white-paper render and BEFORE the layer composite, so layer strokes
// composite ON TOP of the reference visually.
//
// ARCHITECTURAL INVARIANT: this shader is ONLY invoked from the
// to-screen path. compositeLayersToTexture (the save/AI/export
// composite) never calls it. References in back-canvas mode are just
// as excluded from the AI feedback as references in front mode.

struct ReferenceQuadUniforms {
    float2 center;          // in drawable pixels
    float2 halfSize;        // in drawable pixels (width/2, height/2)
    float2 viewportSize;    // drawable size in pixels
    float opacity;
    float flipX;            // 1.0 = no flip, -1.0 = flipped
    float flipY;            // 1.0 = no flip, -1.0 = flipped
    float rotation;         // radians, CCW around center. 0 when ref is
                            // screen-fixed; canvas rotation when ref
                            // follows the canvas.
};

struct ReferenceQuadOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex ReferenceQuadOut referenceQuadVertexShader(
    uint vertexID [[vertex_id]],
    constant ReferenceQuadUniforms& U [[buffer(0)]]
) {
    // Unit quad — 2 triangles, 6 vertices.
    float2 corners[6] = {
        float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),
        float2(-1.0,  1.0), float2( 1.0, -1.0), float2( 1.0,  1.0),
    };
    float2 texCoords[6] = {
        float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0),
        float2(0.0, 0.0), float2(1.0, 1.0), float2(1.0, 0.0),
    };

    float2 corner = corners[vertexID];

    // Scale corner to halfSize, rotate, translate to center.
    // R(-θ) in Y-down pixel space matches the canvas main shader's
    // R(θ) in Y-up pixel space — both visually rotate the same
    // direction for the same canvasRotation value. The rotation
    // gesture handler at MetalCanvasView:3144 negates the gesture's
    // raw rotation before storing in canvasRotation, so positive
    // user-CW gestures end up as NEGATIVE canvasRotation values; this
    // R(-θ) formula then rotates CW visually in Y-down for negative
    // input, matching the canvas content.
    float2 scaled = corner * U.halfSize;
    float c = cos(U.rotation);
    float s = sin(U.rotation);
    float2 rotated = float2(
        scaled.x * c + scaled.y * s,
        -scaled.x * s + scaled.y * c
    );
    float2 pixelPos = U.center + rotated;

    // Pixel → NDC. Y-flip for Metal's clip-space convention (UIKit Y-down).
    float2 ndc;
    ndc.x = (pixelPos.x / U.viewportSize.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (pixelPos.y / U.viewportSize.y) * 2.0;

    // Apply flip to texture coords (image content mirrors, position unchanged).
    float2 tc = texCoords[vertexID];
    if (U.flipX < 0.0) { tc.x = 1.0 - tc.x; }
    if (U.flipY < 0.0) { tc.y = 1.0 - tc.y; }

    ReferenceQuadOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = tc;
    return out;
}

fragment float4 referenceQuadFragmentShader(
    ReferenceQuadOut in [[stage_in]],
    texture2d<float> referenceTexture [[texture(0)]],
    constant float& opacity [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 color = referenceTexture.sample(textureSampler, in.texCoord);
    color.a *= opacity;
    // Premultiplied alpha so the standard (one, oneMinusSrcAlpha) blend
    // in the pipeline state composites correctly over the white paper.
    color.rgb *= color.a;
    return color;
}
