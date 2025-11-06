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

// Vertex shader for full-screen quad with zoom, pan, and rotation support
vertex VertexOut quadVertexShaderWithTransform(uint vertexID [[vertex_id]],
                                                constant float4 *transform [[buffer(0)]],    // [zoom, panX, panY, rotation]
                                                constant float2 *viewportSize [[buffer(1)]],
                                                constant float2 *canvasSize [[buffer(2)]]) {  // Fixed canvas/document size
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

    // Unpack transform parameters
    float zoom = transform[0][0];
    float2 pan = float2(transform[0][1], transform[0][2]);
    float rotation = transform[0][3];  // Rotation angle in radians
    float2 viewport = viewportSize[0];     // Screen size (changes with orientation)
    float2 canvas = canvasSize[0];         // Document size (fixed 2048x2048)

    float2 finalPos = positions[vertexID];
    float2 finalTexCoord = texCoords[vertexID];

    // VERTEX POSITIONING (screen/viewport space)
    // Apply transform: Zoom → Rotate → Pan
    // Convert NDC position to screen space
    float2 screenPos = (finalPos * 0.5 + 0.5) * viewport;  // NDC to screen

    // Step 1: Apply zoom (scale around viewport center)
    float2 screenCenter = viewport * 0.5;
    screenPos = (screenPos - screenCenter) * zoom + screenCenter;

    // Step 2: Apply rotation (rotate around viewport center)
    if (rotation != 0.0) {
        float2 rotated = screenPos - screenCenter;
        float cosAngle = cos(rotation);
        float sinAngle = sin(rotation);
        screenPos.x = rotated.x * cosAngle - rotated.y * sinAngle + screenCenter.x;
        screenPos.y = rotated.x * sinAngle + rotated.y * cosAngle + screenCenter.y;
    }

    // Step 3: Apply pan
    screenPos += pan;

    // Convert back to NDC
    finalPos = (screenPos / viewport) * 2.0 - 1.0;

    // TEXTURE COORDINATE TRANSFORMATION (normalized 0-1 space)
    // The texture is fixed size (canvas), but screen size varies with orientation
    // We need to map from screen transforms to the fixed canvas texture correctly

    // Convert pan from screen pixels to normalized canvas space
    float2 normalizedPan = pan / canvas;  // Normalize by CANVAS size, not viewport!

    // Inverse pan
    finalTexCoord -= normalizedPan;

    // Inverse rotation (around center 0.5, 0.5 in normalized space)
    if (rotation != 0.0) {
        // Translate to center in normalized space
        finalTexCoord -= float2(0.5, 0.5);

        // Apply inverse rotation (negate angle)
        float cosAngle = cos(-rotation);
        float sinAngle = sin(-rotation);
        float2 rotated;
        rotated.x = finalTexCoord.x * cosAngle - finalTexCoord.y * sinAngle;
        rotated.y = finalTexCoord.x * sinAngle + finalTexCoord.y * cosAngle;
        finalTexCoord = rotated;

        // Translate back from center
        finalTexCoord += float2(0.5, 0.5);
    }

    // Inverse zoom (in normalized space)
    finalTexCoord = (finalTexCoord - float2(0.5, 0.5)) / zoom + float2(0.5, 0.5);

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

// Compute shader for blur effect
kernel void blurKernel(texture2d<float, access::read> inputTexture [[texture(0)]],
                       texture2d<float, access::write> outputTexture [[texture(1)]],
                       constant float &blurRadius [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    // Simple box blur
    float4 sum = float4(0.0);
    int radius = int(blurRadius);
    int count = 0;

    for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
            int2 coord = int2(gid) + int2(dx, dy);
            if (coord.x >= 0 && coord.x < int(inputTexture.get_width()) &&
                coord.y >= 0 && coord.y < int(inputTexture.get_height())) {
                sum += inputTexture.read(uint2(coord));
                count++;
            }
        }
    }

    outputTexture.write(sum / float(count), gid);
}

// Compute shader for sharpen effect
kernel void sharpenKernel(texture2d<float, access::read> inputTexture [[texture(0)]],
                          texture2d<float, access::write> outputTexture [[texture(1)]],
                          constant float &amount [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    // Sharpen kernel
    float4 center = inputTexture.read(gid);
    float4 sum = float4(0.0);

    // 3x3 sharpen kernel
    int2 offsets[8] = {
        int2(-1, -1), int2(0, -1), int2(1, -1),
        int2(-1,  0),              int2(1,  0),
        int2(-1,  1), int2(0,  1), int2(1,  1)
    };

    for (int i = 0; i < 8; i++) {
        int2 coord = int2(gid) + offsets[i];
        if (coord.x >= 0 && coord.x < int(inputTexture.get_width()) &&
            coord.y >= 0 && coord.y < int(inputTexture.get_height())) {
            sum += inputTexture.read(uint2(coord));
        }
    }

    float4 result = center * (1.0 + 8.0 * amount) - sum * amount;
    outputTexture.write(clamp(result, 0.0, 1.0), gid);
}

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
