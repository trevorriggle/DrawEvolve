# Canvas Rotation Stretching Fix Plan

## Problem Statement

Rotating the canvas causes drawings to stretch and distort. Proportions are not maintained during rotation, causing circles to become ellipses and squares to become rectangles.

---

## Root Causes Identified

### 1. Shader Texture Coordinate Transform Bug (CRITICAL)

**Location**: `Shaders.metal` lines 129-149

**Problem**: The shader transforms texture coordinates in screen space (pixels) instead of normalized space.

```metal
// CURRENT (WRONG):
float2 texScreenPos = finalTexCoord * viewport;  // ← Converts normalized coords to pixels
// ... rotation happens in pixel space ...
finalTexCoord = texScreenPos / viewport;  // ← Converts back
```

**Why This Breaks**:
- Rotating in pixel space with different width/height causes aspect ratio distortion
- Example: iPad landscape (1024x768) - rotation stretches because X and Y dimensions differ
- Rotation matrix assumes uniform scaling, but pixel space has non-uniform scaling

**Impact**: HIGH - This is the primary cause of stretching

---

### 2. Coordinate Transform Order Issue

**Location**: `CanvasStateManager.swift` lines 593-619 (`documentToScreen()`)

**Problem**: Zoom is applied BEFORE translating to center for rotation.

```swift
// CURRENT (WRONG ORDER):
// Step 1: Apply zoom
var pt = CGPoint(x: point.x * zoomScale, y: point.y * zoomScale)
// Step 2: Translate to rotation origin
pt.x -= centerX
pt.y -= centerY
// Step 3: Apply rotation
```

**Why This Breaks**:
- Rotation happens around the wrong pivot point
- Zoom affects the rotation center calculation
- Combined transforms don't compose correctly

**Correct Order Should Be**:
```
Translate to Center → Zoom → Rotate → Translate Back → Pan
```

**Impact**: MEDIUM - Causes incorrect rotation pivot and secondary distortion

---

### 3. Missing Aspect Ratio Preservation

**Location**: Both shader and Swift coordinate transforms

**Problem**: When viewport is not square (most iPads), rotation stretches because:
- X and Y are scaled differently by viewport dimensions
- Rotation assumes equal scaling in both axes
- No aspect ratio correction applied

**Example**:
- iPad landscape: 1024x768 (aspect ratio 1.33)
- Drawing a circle at (512, 384)
- Rotating 90° moves it incorrectly because X and Y scales differ

**Impact**: HIGH - Fundamental cause of proportion distortion

---

## Fix Plan

### Phase 1: Fix Shader Texture Coordinates (CRITICAL)

**File**: `Shaders.metal` lines 129-149

**Changes**:

1. **Remove viewport pixel space conversion**
   - Keep texture coordinates in normalized 0-1 space
   - Apply all transforms in normalized space

2. **Add aspect ratio correction**
   ```metal
   // Calculate aspect ratio
   float aspectRatio = viewport.x / viewport.y;

   // Before rotation: scale Y by aspect ratio
   texCoord.y *= aspectRatio;

   // Rotate in uniform space
   // Apply rotation matrix...

   // After rotation: scale Y back
   texCoord.y /= aspectRatio;
   ```

3. **Apply inverse transforms correctly**
   - Inverse pan: subtract pan offset (in normalized space)
   - Inverse rotation: negate angle
   - Inverse zoom: divide by zoom
   - All in normalized texture space (0-1)

**New Implementation**:
```metal
// Transform texture coordinates inversely (stay in normalized 0-1 space)
float2 finalTexCoord = texCoords[vertexID];

// Get aspect ratio for correction
float aspectRatio = viewport.x / viewport.y;

// Convert pan from pixel space to normalized space
float2 normalizedPan = pan / viewport;

// Inverse pan
finalTexCoord -= normalizedPan;

// Inverse rotation (with aspect ratio correction)
if (rotation != 0.0) {
    // Translate to center in normalized space
    finalTexCoord -= float2(0.5, 0.5);

    // Scale Y by aspect ratio before rotation
    finalTexCoord.y *= aspectRatio;

    // Apply inverse rotation (negate angle)
    float cosAngle = cos(-rotation);
    float sinAngle = sin(-rotation);
    float2 rotated;
    rotated.x = finalTexCoord.x * cosAngle - finalTexCoord.y * sinAngle;
    rotated.y = finalTexCoord.x * sinAngle + finalTexCoord.y * cosAngle;
    finalTexCoord = rotated;

    // Scale Y back after rotation
    finalTexCoord.y /= aspectRatio;

    // Translate back from center
    finalTexCoord += float2(0.5, 0.5);
}

// Inverse zoom
finalTexCoord = (finalTexCoord - float2(0.5, 0.5)) / zoom + float2(0.5, 0.5);
```

---

### Phase 2: Fix Swift Coordinate Transforms

**File**: `CanvasStateManager.swift`

#### Fix `documentToScreen()` (lines 593-619)

**Current (Wrong)**:
```swift
// Step 1: Apply zoom
var pt = CGPoint(x: point.x * zoomScale, y: point.y * zoomScale)
// Step 2: Translate to rotation origin
pt.x -= centerX
pt.y -= centerY
// Step 3: Apply rotation
let angle = canvasRotation.radians
let cosAngle = cos(angle)
let sinAngle = sin(angle)
let rotatedX = pt.x * cosAngle - pt.y * sinAngle
let rotatedY = pt.x * sinAngle + pt.y * cosAngle
// Step 4: Translate back and apply pan
pt.x = rotatedX + centerX + panOffset.x
pt.y = rotatedY + centerY + panOffset.y
```

**Should Be**:
```swift
// Step 1: Translate to center (before any scaling/rotation)
var pt = CGPoint(
    x: point.x - centerX,
    y: point.y - centerY
)

// Step 2: Apply zoom
pt.x *= zoomScale
pt.y *= zoomScale

// Step 3: Apply rotation (already relative to center)
let angle = canvasRotation.radians
let cosAngle = cos(angle)
let sinAngle = sin(angle)
let rotatedX = pt.x * cosAngle - pt.y * sinAngle
let rotatedY = pt.x * sinAngle + pt.y * cosAngle

// Step 4: Translate back from center and apply pan
pt = CGPoint(
    x: rotatedX + centerX + panOffset.x,
    y: rotatedY + centerY + panOffset.y
)

return pt
```

#### Fix `screenToDocument()` (lines 559-590)

**Must be exact inverse of `documentToScreen()`**:

```swift
// Step 1: Remove pan
var pt = CGPoint(
    x: point.x - panOffset.x,
    y: point.y - panOffset.y
)

// Step 2: Translate to origin
pt.x -= centerX
pt.y -= centerY

// Step 3: Apply inverse rotation
let angle = -canvasRotation.radians // Negative for inverse
let cosAngle = cos(angle)
let sinAngle = sin(angle)
let rotatedX = pt.x * cosAngle - pt.y * sinAngle
let rotatedY = pt.x * sinAngle + pt.y * cosAngle

// Step 4: Apply inverse zoom
pt.x = rotatedX / zoomScale
pt.y = rotatedY / zoomScale

// Step 5: Translate back from origin
pt.x += centerX
pt.y += centerY

return pt
```

---

### Phase 3: Fix Preview Stroke Rendering

**File**: `CanvasRenderer.swift` lines 472-491

**Current Issue**: Similar transform order problem as above

**Fix**: Update to match corrected `documentToScreen()` logic:

```swift
let positions = stroke.points.map { point -> SIMD2<Float> in
    // Document → Screen transformation (match corrected documentToScreen)

    // Step 1: Translate to center
    var x = point.location.x - centerX
    var y = point.location.y - centerY

    // Step 2: Apply zoom
    x *= zoomScale
    y *= zoomScale

    // Step 3: Apply rotation
    let rotatedX = x * cosAngle - y * sinAngle
    let rotatedY = x * sinAngle + y * cosAngle

    // Step 4: Translate back and apply pan
    x = rotatedX + centerX + panOffset.x
    y = rotatedY + centerY + panOffset.y

    return SIMD2<Float>(Float(x), Float(y))
}
```

---

## Testing Plan

After implementing fixes, test the following scenarios:

### Test Case 1: Circle Preservation
1. Draw a perfect circle in the center of canvas
2. Rotate canvas 45°
3. **Expected**: Circle remains circular (not elliptical)
4. Rotate to 90°, 180°, 270°
5. **Expected**: Circle stays circular at all angles

### Test Case 2: Square Preservation
1. Draw a square with equal sides
2. Rotate canvas 45°
3. **Expected**: All sides remain equal length
4. **Expected**: Square becomes diamond but maintains proportions

### Test Case 3: Line Length Preservation
1. Draw a horizontal line
2. Measure visual length
3. Rotate canvas 90°
4. **Expected**: Line is now vertical with same visual length
5. Rotate to other angles
6. **Expected**: Length never changes

### Test Case 4: Aspect Ratios
1. Test on iPad portrait (768x1024)
2. Test on iPad landscape (1024x768)
3. Test on iPhone portrait
4. **Expected**: Rotation behavior identical on all orientations

### Test Case 5: Combined Transforms
1. Zoom to 2x
2. Pan to corner
3. Rotate 45°
4. Draw shapes
5. **Expected**: No distortion at any zoom/pan/rotation combination

### Test Case 6: Selection Tools
1. Select a region while rotated
2. **Expected**: Selection marquee matches selected pixels exactly
3. Move selected pixels
4. **Expected**: No stretching or distortion

---

## Implementation Order

### Priority 1: Shader Fix (Highest Impact)
- [ ] Fix shader texture coordinate transforms
- [ ] Add aspect ratio preservation to shader
- [ ] Remove pixel space conversions
- [ ] Test: Basic rotation without stretching

### Priority 2: Swift Transform Fixes
- [ ] Fix `documentToScreen()` transform order
- [ ] Fix `screenToDocument()` transform order
- [ ] Ensure both are exact inverses
- [ ] Test: Touch input while rotated

### Priority 3: Preview Stroke Fix
- [ ] Update `renderStrokePreview()` transforms
- [ ] Match corrected `documentToScreen()` logic
- [ ] Test: Drawing while rotated shows correct preview

### Priority 4: Comprehensive Testing
- [ ] Run all test cases listed above
- [ ] Test on physical iPad (both orientations)
- [ ] Test with Apple Pencil input
- [ ] Test all drawing tools while rotated

---

## Expected Results After Fix

1. **No stretching**: Circles stay circular, squares stay square
2. **Preserved proportions**: All distances and angles maintained
3. **Correct aspect ratio**: Works identically on all device orientations
4. **Accurate transforms**: Touch input lands exactly where expected
5. **Preview accuracy**: Live stroke preview shows at correct position without distortion

---

## Technical Notes

### Why Aspect Ratio Matters

When viewport is rectangular (width ≠ height):
- Normalized coordinates (0-1) map to different pixel counts in X and Y
- Example: 1024x768 → 0.1 normalized = 102.4 pixels in X, 76.8 pixels in Y
- Rotation matrix assumes uniform scaling (1 unit X = 1 unit Y)
- Without correction, rotation causes stretching proportional to aspect ratio

### Why Transform Order Matters

Matrix multiplication is not commutative:
- `Zoom × Rotate ≠ Rotate × Zoom`
- Rotating around center requires: `Translate(-center) × Rotate × Translate(center)`
- If zoom is applied before translating to center, the center point moves
- Result: Rotation happens around wrong point, causing visible shift and distortion

### Inverse Transform Requirements

For touch input to work correctly:
- `screenToDocument(documentToScreen(point))` must equal `point`
- Each transform must be inverted in reverse order
- Forward: `Pan(Rotate(Zoom(Translate(point))))`
- Inverse: `Translate⁻¹(Zoom⁻¹(Rotate⁻¹(Pan⁻¹(point))))`

---

## Files to Modify

1. **Shaders.metal** (lines 80-156)
   - `quadVertexShaderWithTransform` function
   - Texture coordinate transform section

2. **CanvasStateManager.swift** (lines 559-619)
   - `screenToDocument()` function
   - `documentToScreen()` function

3. **CanvasRenderer.swift** (lines 444-514)
   - `renderStrokePreview()` function
   - Point transformation logic

4. **MetalCanvasView.swift** (lines 238-254)
   - Already correct, passes rotation to renderer
   - No changes needed

---

## Success Criteria

✅ Drawings maintain exact proportions at any rotation angle
✅ Circles remain circular, squares remain square
✅ Works correctly on all device orientations and aspect ratios
✅ Touch input lands at expected location while rotated
✅ Preview strokes appear at correct position
✅ Selection tools work accurately while rotated
✅ Combined zoom + rotate + pan works without artifacts
✅ Performance remains at 60 FPS during rotation

---

## Estimated Implementation Time

- Shader fixes: 30 minutes
- Swift transform fixes: 20 minutes
- Preview stroke fixes: 15 minutes
- Testing and validation: 45 minutes
- **Total: ~2 hours**

---

**Status**: Ready to implement
**Priority**: CRITICAL - Breaks core functionality
**Difficulty**: Medium - Well-understood problem with clear solution
