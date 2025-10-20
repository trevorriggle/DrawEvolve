# Tool Implementation Roadmap

**Created:** January 20, 2025
**Purpose:** Detailed requirements and implementation plan for unimplemented drawing tools

---

## Completed Tools (12/22)

### Recently Implemented
1. **Magic Wand** ✅ (Jan 20, 2025)
   - Flood fill selection algorithm
   - Color tolerance matching
   - Boundary tracing
   - Integration with selection system
   - **Files:** MetalCanvasView.swift:530-560, 1178-1336

---

## Tools Requiring Implementation (9/22)

### Priority 1: Selection & Effect Tools

#### 1. Smudge Tool
**Status:** Not implemented
**Complexity:** High (requires Metal shader)
**User Value:** High - common artist tool

**Requirements:**
- Sample pixels at brush location
- Blend sampled pixels with existing pixels as brush moves
- Use brush size/opacity/pressure settings
- Maintain "color memory" across stroke

**Implementation Approach:**
1. Create Metal compute shader for pixel sampling and blending
2. Sample circular region at brush location on touchesBegan
3. On touchesMoved, blend sampled pixels with destination
4. Apply pressure sensitivity to blend amount
5. Update sampled region gradually during stroke (for realistic smudging)

**Files to Modify:**
- `Shaders.metal` - Add smudge shader
- `CanvasRenderer.swift` - Add renderSmudgeStroke() method
- `MetalCanvasView.swift` - Add smudge tool handling

**Estimated Effort:** 4-6 hours

---

#### 2. Clone Stamp Tool
**Status:** Not implemented
**Complexity:** High (requires Metal shader + UI)
**User Value:** Medium - professional feature

**Requirements:**
- Alt/Option-click to set source point
- Click to stamp source pixels at new location
- Maintain offset between source and destination
- Support brush size/opacity
- Show preview of source region

**Implementation Approach:**
1. Add source point selection (needs UI feedback)
2. Create Metal shader for sampling and stamping
3. Track offset between source and stamp location
4. Show visual indicator for source point
5. Apply brush settings to stamped pixels

**Files to Modify:**
- `Shaders.metal` - Add clone stamp shader
- `CanvasRenderer.swift` - Add renderCloneStamp() method
- `MetalCanvasView.swift` - Add clone stamp handling + source point tracking
- `DrawingCanvasView.swift` - Add UI for "set source point" mode

**Estimated Effort:** 6-8 hours

---

### Priority 2: Transform Tools

#### 3. Move Tool
**Status:** Partially implemented
**Complexity:** Low (infrastructure exists)
**User Value:** Medium

**Current State:**
- Selection moving already works (drag selected pixels)
- Just needs dedicated tool for moving layers/selections

**Requirements:**
- Move entire layer when no selection active
- Move selection when selection exists
- Show visual feedback during drag
- Snap to edges/center (optional)

**Implementation Approach:**
1. Check if selection exists → use existing selection move logic
2. If no selection, implement layer moving:
   - Pan layer texture offset
   - Update layer position property
   - Commit changes on touchesEnded
3. Add visual feedback (outline, ghost image)

**Files to Modify:**
- `MetalCanvasView.swift` - Add move tool handling
- `DrawingLayer.swift` - Add offset property (if not exists)
- `CanvasRenderer.swift` - Apply layer offset in rendering

**Estimated Effort:** 2-3 hours

---

#### 4. Rotate Tool
**Status:** Infrastructure exists but disabled
**Complexity:** Medium
**User Value:** Low-Medium

**Current State:**
- Gesture recognizers exist but not used for rotation
- CanvasStateManager has transformation infrastructure

**Requirements:**
- Rotate entire layer or selection
- Tap-drag rotation gesture
- Show rotation angle indicator
- Apply to texture (permanent) or transform (non-destructive)

**Implementation Approach:**
1. Add rotation gesture (two-finger rotate or drag-around-center)
2. Visual feedback: rotation indicator, ghosted preview
3. Non-destructive option: render with rotation transform
4. Destructive option: rotate texture pixels (expensive)
5. Support rotation of selections

**Files to Modify:**
- `MetalCanvasView.swift` - Add rotation gesture handling
- `CanvasRenderer.swift` - Add rotation transform to rendering pipeline
- `DrawingLayer.swift` - Add rotation property
- Option: Add Metal shader for texture rotation

**Estimated Effort:** 4-5 hours

---

#### 5. Scale Tool
**Status:** Infrastructure exists but disabled
**Complexity:** Medium
**User Value:** Low-Medium

**Current State:**
- Pinch gesture exists for canvas zoom
- Need separate tool for layer/selection scaling

**Requirements:**
- Scale entire layer or selection
- Pinch gesture or corner drag
- Maintain aspect ratio (with option to disable)
- Show scale factor indicator
- Apply to texture or transform

**Implementation Approach:**
1. Add scaling gesture (pinch or corner handles)
2. Visual feedback: scale indicator, bounding box
3. Non-destructive: render with scale transform
4. Destructive: resample texture (use Metal for quality)
5. Support selection scaling

**Files to Modify:**
- `MetalCanvasView.swift` - Add scale gesture handling
- `CanvasRenderer.swift` - Add scale transform to rendering pipeline
- `DrawingLayer.swift` - Add scale property
- Option: Add Metal shader for texture resampling

**Estimated Effort:** 4-5 hours

---

### Priority 3: Effect Tools (Brush Mode)

#### 6. Blur (Brush Mode)
**Status:** Partially working (global only)
**Complexity:** Medium (requires localized shader)
**User Value:** High

**Current Implementation:**
- Applies blur to entire texture
- Located in MetalCanvasView.swift:358-401
- Uses CanvasRenderer.swift:896-904, 916-954

**Requirements:**
- Apply blur only where brush touches
- Use brush size to control blur radius
- Support pressure sensitivity for blur amount
- Real-time preview during stroke

**Implementation Approach:**
1. Modify blur shader to work on specific region
2. Create mask texture from brush stroke
3. Apply blur only to masked region
4. Blend blurred result with original using mask alpha
5. Use brush settings for radius and opacity

**Files to Modify:**
- `Shaders.metal` - Modify blur shader for region masking
- `CanvasRenderer.swift` - Add renderBlurStroke() method
- `MetalCanvasView.swift` - Change blur from tap to stroke

**Estimated Effort:** 3-4 hours

---

#### 7. Sharpen (Brush Mode)
**Status:** Partially working (global only)
**Complexity:** Medium (requires localized shader)
**User Value:** Medium

**Current Implementation:**
- Applies sharpen to entire texture
- Located in MetalCanvasView.swift:403-446
- Uses CanvasRenderer.swift:906-914, 916-954

**Requirements:**
- Same as blur but with sharpen kernel
- Apply only where brush touches
- Support pressure sensitivity

**Implementation Approach:**
- Same approach as Blur (brush mode)
- Use sharpen convolution kernel instead of blur
- Rest of implementation identical

**Files to Modify:**
- `Shaders.metal` - Modify sharpen shader for region masking
- `CanvasRenderer.swift` - Add renderSharpenStroke() method
- `MetalCanvasView.swift` - Change sharpen from tap to stroke

**Estimated Effort:** 3-4 hours

---

## Implementation Priority Ranking

### Quick Wins (< 4 hours)
1. **Move Tool** - 2-3 hours, uses existing infrastructure
2. **Magic Wand** - ✅ COMPLETED

### High Value (4-6 hours)
3. **Blur Brush Mode** - 3-4 hours, fixes user expectation mismatch
4. **Sharpen Brush Mode** - 3-4 hours, same as blur
5. **Smudge** - 4-6 hours, high user demand
6. **Rotate Tool** - 4-5 hours, moderate value

### Lower Priority (6+ hours)
7. **Clone Stamp** - 6-8 hours, professional feature
8. **Scale Tool** - 4-5 hours, overlaps with zoom functionality

---

## Technical Notes

### Metal Shader Requirements
Most unimplemented tools require Metal compute shaders:
- **Smudge:** Pixel sampling + blending shader
- **Clone Stamp:** Pixel copying + offset shader
- **Blur/Sharpen (brush):** Masked convolution shader

### Performance Considerations
- Large texture operations (2048x2048) are expensive on CPU
- Use Metal for all pixel operations
- Implement safety limits (max pixels, timeout)
- Test on physical iPad for performance

### UI/UX Needs
- Source point indicator for clone stamp
- Rotation angle indicator
- Scale factor indicator
- Transform handles/bounding boxes
- Mode toggles (e.g., "Set Source Point" for clone stamp)

---

## Testing Checklist

When implementing each tool:
- [ ] Pressure sensitivity works
- [ ] Undo/redo support
- [ ] Thumbnail updates
- [ ] Works on all layer blend modes
- [ ] Performance acceptable on device
- [ ] UI feedback clear
- [ ] Edge cases handled (empty layer, bounds, etc.)

---

## Next Steps

### Immediate (This Session)
1. ✅ Complete Magic Wand implementation
2. ✅ Test Magic Wand on simulator
3. Document requirements for remaining tools

### Short Term (Next Session)
1. Implement Move tool (quick win)
2. Convert Blur to brush mode (high value)
3. Convert Sharpen to brush mode (while we're at it)

### Medium Term
1. Implement Smudge tool
2. Implement Rotate tool
3. Implement Scale tool

### Long Term
1. Implement Clone Stamp
2. Performance optimization
3. Advanced features (blend modes, masks, etc.)

---

## Resources Needed

### For All Tools
- Physical iPad for testing (gestures, performance)
- Metal shader expertise (or documentation study)
- Time for proper testing and polish

### For Specific Tools
- **Clone Stamp:** UI design for source point indicator
- **Transform Tools:** Gesture conflict resolution (pinch, pan, rotate)
- **Blur/Sharpen:** Convolution kernel optimization

---

**Last Updated:** January 20, 2025
**Status:** Magic Wand completed, 8 tools remaining
**Estimated Total Effort:** 30-40 hours for all tools
