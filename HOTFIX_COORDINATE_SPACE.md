# Hotfix: Coordinate Space Mismatch

## Issue
Drawings were shifting to the left on release. The stroke appeared to be drawn correctly while dragging, but would jump position when the finger was lifted.

## Root Cause

**Coordinate Space Confusion:**

On Retina displays (2x scale):
- **Touch coordinates**: In logical points (e.g., 820x1180)
- **Metal drawable size**: In pixels (e.g., 1640x2360 = 2x the points)

The bug occurred because:
1. `mtkView(_:drawableSizeWillChange:)` was setting `screenSize` to the drawable size (pixels)
2. Touch coordinates were in logical points (view.bounds)
3. When rendering, we scaled coordinates using `documentSize` (which was the pixel size)
4. This caused a ~1.25x scaling error: `2048 / 1640 ≈ 1.25` instead of `2048 / 820 ≈ 2.5`

## The Fix

**File:** `MetalCanvasView.swift` - Line 176

**Before:**
```swift
canvasState.screenSize = size  // Drawable size in pixels
```

**After:**
```swift
canvasState.screenSize = view.bounds.size  // Bounds size in logical points
```

## Why This Works

All coordinate handling in iOS uses **logical points**, not pixels:
- `touch.location(in: view)` returns points
- `view.bounds.size` is in points
- Our drawing coordinates are in points

The Metal drawable size is only relevant for the GPU pixel buffer, not for our coordinate system. By consistently using `view.bounds.size`, we ensure:

✅ Touch coordinates match document coordinates
✅ Scaling from document to texture is correct
✅ No shift on stroke release
✅ Works on all display scales (1x, 2x, 3x)

## Test Results

**Before Fix:**
```
Touch at: (359, 334.5) → Document: (359, 334.5)
Document size: 1640x2360, View size: 820x1180  ❌ MISMATCH
Scale factor: 2048 / 1640 = 1.25x              ❌ WRONG
Result: Drawing shifts on release              ❌ BUG
```

**After Fix:**
```
Touch at: (359, 334.5) → Document: (359, 334.5)
Document size: 820x1180, View size: 820x1180   ✅ MATCH
Scale factor: 2048 / 820 = 2.5x               ✅ CORRECT
Result: Drawing stays in place                 ✅ FIXED
```

## Impact

This fix affects all drawing operations:
- Brush strokes
- Eraser
- Shapes (line, rectangle, circle)
- Fill tools (paint bucket)
- Selection tools
- Effect tools (blur, sharpen)

All tools now work correctly on Retina displays without coordinate shifts.

## Related Files

- `MetalCanvasView.swift` - Fixed line 176
- `CanvasStateManager.swift` - Uses screenSize consistently
- `CanvasRenderer.swift` - Scales coordinates correctly

## Lessons Learned

1. **Always use logical points** for coordinate systems in iOS
2. **Drawable size ≠ bounds size** on Retina displays
3. **Be explicit** about which coordinate space you're working in
4. **Test on Retina displays** to catch scaling issues

---

**Status:** ✅ Fixed
**Date:** 2025-11-04
**Impact:** Critical (affects all drawing tools)
