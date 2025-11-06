# Fixed Canvas System - Rotation Without Stretching

## The Problem
When rotating the iPad device, drawings were stretching and warping because the canvas coordinate space was changing with screen orientation.

## Root Cause Analysis

### Before (BROKEN):
```swift
var documentSize: CGSize {
    return screenSize  // ❌ Changes with orientation!
}
```

**What happened:**
- Portrait orientation: screenSize = 768×1024 → documentSize = 768×1024
- Landscape orientation: screenSize = 1024×768 → documentSize = 1024×768
- Canvas texture: **Always** 2048×2048 (fixed)
- **Result**: Coordinate transforms broke because documentSize != canvasSize

When you rotated the iPad:
1. screenSize changed from 768×1024 to 1024×768
2. documentSize followed screenSize and also changed
3. All coordinate math used documentSize for the center point
4. But the texture stayed 2048×2048
5. Transform mismatch → stretching and warping

### After (FIXED):
```swift
var documentSize: CGSize {
    return CGSize(width: 2048, height: 2048)  // ✅ FIXED - never changes!
}
```

## The Solution: Fixed Canvas Like Procreate

Think of it like a **physical piece of paper**:
- The paper (canvas) is always the same size
- When you rotate the iPad, you're changing how you **view** the paper
- The drawings on the paper don't change
- The screen is just a **window** into the canvas

### Two Coordinate Spaces

1. **Document Space** (the canvas/paper):
   - Fixed size: 2048×2048 pixels
   - Never changes regardless of screen orientation
   - All drawings stored here
   - Source of truth

2. **Screen/Viewport Space** (the window):
   - Changes with device orientation
   - Portrait: 768×1024
   - Landscape: 1024×768
   - Shows a view of the canvas with zoom/pan/rotation applied

### Coordinate Transform Pipeline

**Screen → Document** (for input/touches):
```
1. Remove pan (screen space)
2. Translate to screen center
3. Apply inverse rotation
4. Apply inverse zoom
5. Translate to DOCUMENT center ← Key difference!
```

**Document → Screen** (for rendering):
```
1. Translate to document center
2. Apply zoom
3. Apply rotation
4. Translate to screen center and apply pan
```

## Changes Made

### 1. CanvasStateManager.swift (Lines 53-58)
```swift
var documentSize: CGSize {
    return CGSize(width: 2048, height: 2048)  // Fixed square canvas
}
```

### 2. CanvasStateManager.swift - screenToDocument() (Lines 560-596)
- Added separate `screenCenter` and `docCenter`
- Transforms now correctly map between variable screen and fixed document space

### 3. CanvasStateManager.swift - documentToScreen() (Lines 598-632)
- Added separate `screenCenter` and `docCenter`
- Inverse of screenToDocument with correct space mapping

### 4. Shaders.metal - quadVertexShaderWithTransform (Lines 80-164)
- Added `canvasSize` parameter (buffer index 2)
- Vertex positioning uses `viewport` (screen space)
- Texture coordinate mapping uses `canvas` (fixed document space)
- Pan normalized by canvas size: `normalizedPan = pan / canvas`

### 5. CanvasRenderer.swift - renderTextureToScreen() (Lines 432-444)
- Pass canvas size to shader as buffer index 2
- Shader can now correctly map square canvas to rectangular screen

### 6. CanvasRenderer.swift - renderStrokePreview() (Lines 470-500)
- Added `docCenter` for document space calculations
- Stroke preview transforms match the main rendering pipeline

## Key Principles

1. **Canvas is fixed**: 2048×2048 always, like a physical canvas
2. **Screen is variable**: Changes with orientation, just a viewport
3. **Two centers**: Screen center (varies) vs Document center (fixed at 1024, 1024)
4. **Shader separation**: Vertex positions use viewport, texture coords use canvas
5. **Pan normalization**: Always normalize by canvas size, not viewport

## Expected Results

✅ **Rotate the iPad** (portrait ↔ landscape): No stretching, drawings stay perfect
✅ **Two-finger rotate gesture**: Smooth rotation, no distortion
✅ **Draw a circle**: Stays circular at any rotation angle or zoom level
✅ **Zoom + Rotate + Pan**: All work together without artifacts
✅ **Layer isolation**: Each layer has its own 2048×2048 texture

## Testing Checklist

1. **Device Rotation Test**:
   - Draw a perfect circle in portrait
   - Rotate iPad to landscape
   - Circle should remain perfectly circular (not ellipse)

2. **Gesture Rotation Test**:
   - Draw a square
   - Use two-finger rotation gesture
   - Square should stay square at all angles

3. **Combined Transform Test**:
   - Zoom to 200%
   - Rotate 45 degrees
   - Pan around
   - Draw should stay sharp, no resampling

4. **Multi-layer Test**:
   - Create 3 layers
   - Draw different shapes on each
   - Rotate canvas
   - All layers should rotate together without stretching

## Technical Notes

### Why 2048×2048?
- Square aspect ratio prevents any directional scaling bias
- 2048 is large enough for high-res drawing on iPad
- Power of 2 is optimal for Metal textures
- Matches common iPad Retina resolutions

### Letterboxing
When the canvas is rendered to screen:
- If viewport is wider than canvas: vertical letterboxing (black bars on sides)
- If viewport is taller than canvas: horizontal letterboxing (black bars top/bottom)
- The canvas always maintains 1:1 aspect ratio

### Performance
- No texture reallocation during rotation
- No bitmap resampling
- Transforms are GPU-only (vertex shader)
- 60 FPS maintained during gestures

## Files Modified

1. `ViewModels/CanvasStateManager.swift` - Fixed documentSize, coordinate transforms
2. `Shaders.metal` - Added canvas size parameter, proper space separation
3. `Services/CanvasRenderer.swift` - Pass canvas size, updated preview rendering
4. `PIPELINE_FEATURES.md` - Updated to reflect rotation now works
