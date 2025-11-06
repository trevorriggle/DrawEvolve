# Canvas Rotation Stretching Fix - Final Solution

## Root Cause
The canvas was stretching during rotation because **documentSize was changing with device orientation**, but the canvas texture remained fixed at 2048×2048.

### The Real Issue
1. **Document size was tied to screen size** (`CanvasStateManager.swift:55-57`):
   ```swift
   var documentSize: CGSize {
       return screenSize  // BUG: Changes with orientation!
   }
   ```
   - Portrait: screenSize = 768×1024 → documentSize = 768×1024
   - Landscape: screenSize = 1024×768 → documentSize = 1024×768
   - Canvas texture: **Always** 2048×2048

2. **Coordinate transforms used wrong center points**:
   - `screenToDocument()` and `documentToScreen()` used screenSize center
   - Should use **documentSize center** for document space operations

3. **Shader normalized pan by viewport instead of canvas**:
   - Shader did: `normalizedPan = pan / viewport`
   - Should do: `normalizedPan = pan / canvasSize`
   - When viewport changes with orientation, pan mapping was incorrect

### The Solution
Three critical fixes:

1. **Fixed document size** (CanvasStateManager.swift):
   - Make `documentSize` return constant 2048×2048
   - Document space no longer changes with orientation

2. **Separate coordinate spaces** (CanvasStateManager.swift):
   - `screenToDocument()`: Use screen center for screen ops, document center for document ops
   - `documentToScreen()`: Same separation of concerns
   - Properly map between screen space (varies) and document space (fixed)

3. **Pass canvas size to shader** (Shaders.metal + CanvasRenderer.swift):
   - Added `canvasSize` parameter to shader (buffer index 2)
   - Normalize pan by canvas size, not viewport size
   - Shader now knows about both screen space (for positioning) and canvas space (for texture mapping)

## Changes Made

### CanvasStateManager.swift
- Line 55-57: `documentSize` now returns fixed `CGSize(width: 2048, height: 2048)`
- Line 560-592: `screenToDocument()` uses both screen and document centers
- Line 595-626: `documentToScreen()` uses both screen and document centers

### CanvasRenderer.swift
- Line 467-494: `renderStrokePreview()` uses document center (canvasSize) instead of viewport center
- Line 439-441: Pass canvas size to shader as buffer index 2

### Shaders.metal
- Line 84: Added `canvasSize` parameter to `quadVertexShaderWithTransform`
- Line 102-103: Separate `viewport` (screen) and `canvas` (document) sizes
- Line 137: Normalize pan by canvas size: `normalizedPan = pan / canvas`
- Line 108-130: Vertex positioning uses screen space (viewport)
- Line 132-155: Texture coords use canvas space (fixed document)

## Expected Results
✅ Circles remain perfectly circular at all rotation angles
✅ Squares maintain equal sides at all rotation angles
✅ Line lengths preserved during rotation
✅ Works identically in portrait and landscape orientations
✅ Combined zoom+pan+rotate work without artifacts
✅ **Canvas size stays consistent regardless of device rotation**

## Testing
Please test by:
1. Drawing a perfect circle in portrait mode
2. Rotating the iPad to landscape - circle should stay circular
3. Using two-finger rotation gesture - no stretching at any angle
4. Testing with combined zoom + rotation + pan
5. Verifying drawing coordinates stay in 0-2048 range regardless of orientation
