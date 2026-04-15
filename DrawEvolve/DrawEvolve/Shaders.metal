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
    out.pointSize = uniforms.size * uniforms.pressure;

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
                                                constant float2 *canvasSize [[buffer(2)]]) {  // Unused now; kept for ABI stability
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

    // Back to NDC
    finalPos = (screenPos / viewport) * 2.0 - 1.0;

    out.position = float4(finalPos, 0.0, 1.0);
    out.texCoord = finalTexCoord;
    out.pointSize = 1.0;

    return out;
}

// MARK: - Fragment Shaders

// Fragment shader for brush strokes with soft edges
fragment float4 brushFragmentShader(VertexOut in [[stage_in]],
                                     float2 pointCoord [[point_coord]],
                                     constant BrushUniforms &uniforms [[buffer(0)]]) {
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

    // Apply opacity and pressure
    alpha *= uniforms.opacity * uniforms.pressure;

    return float4(uniforms.color.rgb, alpha * uniforms.color.a);
}

// Fragment shader for eraser (outputs transparent pixels)
fragment float4 eraserFragmentShader(VertexOut in [[stage_in]],
                                      float2 pointCoord [[point_coord]],
                                      constant BrushUniforms &uniforms [[buffer(0)]]) {
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

// MARK: - Effect Shaders

// Compute shader for paint bucket flood fill
kernel void floodFillKernel(texture2d<float, access::read> inputTexture [[texture(0)]],
                            texture2d<float, access::write> outputTexture [[texture(1)]],
                            constant float4 &fillColor [[buffer(0)]],
                            constant float4 &targetColor [[buffer(1)]],
                            constant float &tolerance [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    float4 pixelColor = inputTexture.read(gid);

    // Check if pixel color matches target color within tolerance
    float diff = distance(pixelColor.rgb, targetColor.rgb);

    if (diff <= tolerance) {
        outputTexture.write(fillColor, gid);
    } else {
        outputTexture.write(pixelColor, gid);
    }
}
