# Canvas Rotation & Coordinate Space Fix

## Issues Fixed

### 1. Canvas Rotation Distortion ✅
**Problem:** When rotating the canvas, the square canvas was being distorted by the rectangular viewport.

**Solution:**
- Made canvas size **dynamically calculated** based on screen diagonal: `size = ceil(√(width² + height²))`
- Added **aspect ratio correction** in the Metal shader to properly fit the square canvas within a rectangular viewport
- Canvas now maintains 1:1 aspect ratio with pillarboxing (landscape) or letterboxing (portrait)

**Files Changed:**
- `CanvasRenderer.swift:24-45` - Dynamic canvas size calculation
- `Shaders.metal:111-126` - Aspect ratio correction in vertex shader
- `CanvasStateManager.swift:53-70` - Dynamic document size property
- `MetalCanvasView.swift:168-183, 190-206` - Canvas size update on screen changes

---

### 2. Brushstroke Offset on Release ✅
**Problem:** When drawing, the stroke preview appeared correctly, but upon release, the committed stroke was offset from where you drew.

**Root Cause:**
The coordinate transformation functions (`screenToDocument` and `documentToScreen`) didn't account for the aspect ratio correction being applied by the shader. When the canvas is pillarboxed or letterboxed to maintain its square aspect ratio, touch coordinates need to be adjusted for the scaled canvas area.

**Solution:**
Updated both transformation functions to include aspect ratio correction:

1. **screenToDocument** (CanvasStateManager.swift:582-649)
   - Added Step 0: Calculate aspect ratio scale
   - Added Step 5: Apply inverse aspect ratio correction
   - Added Step 6: Scale from screen space to document space
   - Now properly maps touch coordinates to document space accounting for black bars

2. **documentToScreen** (CanvasStateManager.swift:651-713)
   - Added aspect ratio calculation
   - Added Step 2: Scale from document to screen space
   - Added Step 3: Apply aspect ratio correction
   - Ensures selection overlays and previews render at correct positions

**The Transform Pipeline:**

**Screen → Document:**
```
Touch Point (screen px)
  ↓ Remove pan offset
  ↓ Translate to screen center
  ↓ Apply inverse rotation
  ↓ Apply inverse zoom
  ↓ Apply inverse aspect ratio correction  ← NEW
  ↓ Scale to document space                ← NEW
  ↓ Translate to document center
  = Document coordinates
```

**Document → Screen:**
```
Document Point
  ↓ Translate to document origin
  ↓ Scale to screen space                  ← NEW
  ↓ Apply aspect ratio correction          ← NEW
  ↓ Apply zoom
  ↓ Apply rotation
  ↓ Translate to screen center + pan
  = Screen coordinates
```

---

## How It Works

### Canvas Sizing
```swift
// Example: iPad 1024×768 screen
diagonal = √(1024² + 768²) = 1280
canvas_size = next_power_of_2(1280) = 2048
```

The canvas is always a **square** that's big enough to contain the screen diagonal. This ensures no clipping when rotated.

### Aspect Ratio Correction

**Landscape (wider than tall):**
```
Viewport: ┌─────────────┐
          │  │       │  │  ← pillarbox (black bars)
          │  │ CANVAS│  │
          │  │       │  │
          └─────────────┘
Scale: (1/aspect, 1)
```

**Portrait (taller than wide):**
```
Viewport: ┌───────────┐
          │───────────│  ← letterbox (black bars)
          │           │
          │  CANVAS   │
          │           │
          │───────────│
          └───────────┘
Scale: (1, aspect)
```

---

## Testing Checklist

- [x] Canvas rotates without distortion
- [x] Brushstrokes appear at correct position when released
- [x] Selection tools work correctly
- [ ] Zoom + rotation works correctly
- [ ] Pan + rotation works correctly
- [ ] Existing drawings load and render correctly
- [ ] Test on different device orientations (portrait/landscape)
- [ ] Test on different screen sizes (iPad Pro, iPad Mini, etc.)

---

## Technical Notes

1. **Canvas size is now dynamic** - It changes when screen size changes (e.g., device rotation)
2. **Document size = Canvas size** - They're always the same (1:1 mapping)
3. **Texture size = Canvas size** - Layer textures match the canvas dimensions
4. **Coordinate spaces:**
   - **Screen space**: Touch coordinates from UIKit (varies with device orientation)
   - **Document space**: Fixed canvas coordinates (square, size = screen diagonal)
   - **Texture space**: GPU texture coordinates (matches document space 1:1)

5. **Aspect ratio correction happens in two places:**
   - Metal shader (for rendering the canvas to screen)
   - Coordinate transformations (for mapping touches to canvas)

---

## Known Limitations

- Canvas size is recalculated on screen size change, but existing textures are not resized
- This could cause issues if device is rotated from portrait to landscape with very different aspect ratios
- Consider: Implementing texture resizing or using maximum possible canvas size upfront
