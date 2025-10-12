# DrawEvolve iPad Testing Checklist

**Generated:** October 12, 2025
**Session:** Selection Tools Implementation
**Build:** Latest main branch (commit dddd5a4)

---

## 🎯 Priority 1: Selection Tools (NEW - Just Implemented)

### Rectangle Selection Tool
- [ ] Tap rectangle select tool, drag to create selection
- [ ] Verify marching ants animation appears (black/white dashed border)
- [ ] Tap inside selection and drag - should move selection with semi-transparent preview
- [ ] Release - selection should commit to new position
- [ ] Switch to different tool - selection should auto-commit
- [ ] Undo - selection movement should revert
- [ ] Redo - selection movement should reapply

### Lasso Selection Tool
- [ ] Tap lasso tool, draw freeform shape around area
- [ ] Verify marching ants follow the drawn path
- [ ] Tap inside lasso selection and drag to move
- [ ] Verify point-in-polygon hit detection works (only triggers inside shape)
- [ ] Release and verify pixels committed correctly

### Selection Actions
- [ ] Create selection, tap "Delete" button - pixels should clear
- [ ] Undo delete - pixels should restore
- [ ] Create selection, tap "Cancel" - selection should clear without affecting canvas
- [ ] Create selection with rectangle, then create new selection with lasso - first should cancel

### Edge Cases
- [ ] Try to drag outside a selection - should NOT move it (only triggers inside)
- [ ] Create very small selection (10x10 pixels) - should still work
- [ ] Create very large selection (full canvas) - should still work
- [ ] Move selection off-canvas partially - should handle gracefully
- [ ] Create selection, draw with brush, switch back to selection - should be gone
- [ ] Multiple undo/redo cycles with selections

---

## 🎯 Priority 2: Gallery & Save/Overwrite (Previously Fixed)

### Gallery Navigation
- [ ] Open app, draw something, tap Gallery button (top-right)
- [ ] Gallery should open with "Close" button visible
- [ ] Tap "Close" - should return to canvas with drawing intact
- [ ] Gallery button should be visible even with toolbar collapsed

### Save New Drawing
- [ ] Draw something new
- [ ] Tap "Save to Gallery" button
- [ ] Enter title "Test Drawing 1"
- [ ] Verify drawing appears in gallery with correct title
- [ ] Verify thumbnail shows drawing preview (not blank)

### Edit Existing Drawing
- [ ] From gallery, tap existing drawing to open
- [ ] Canvas should load with drawing visible
- [ ] Draw additional strokes - **CRITICAL: Verify brush strokes appear on screen**
- [ ] Tap "Save to Gallery"
- [ ] Should UPDATE existing drawing (not create new one)
- [ ] Return to gallery - verify only one copy exists, updated

### Gallery Display
- [ ] Dark mode: Thumbnails should have white background (not transparent)
- [ ] Thumbnails should be centered with proper aspect ratio
- [ ] Tap any thumbnail - should open that specific drawing

---

## 🎯 Priority 3: Core Drawing Functionality

### Brush Tool
- [ ] Select brush, draw smooth curves
- [ ] Vary pressure (if using Apple Pencil) - stroke width should change
- [ ] Draw fast strokes - should have consistent spacing (no gaps)
- [ ] **Known Issue**: Brush may thicken on touchesEnded (P1 bug)

### Eraser Tool
- [ ] Draw something, switch to eraser
- [ ] Erase part of drawing - should clear pixels cleanly
- [ ] Eraser should respect brush size setting

### Color Picker
- [ ] Tap color circle in toolbar
- [ ] Pick different color
- [ ] Draw with new color - should work

### Undo/Redo
- [ ] Draw 3 strokes
- [ ] Undo 3 times - all strokes should disappear
- [ ] Redo 3 times - all strokes should reappear
- [ ] Verify layer thumbnails update correctly

---

## 🎯 Priority 4: Layers

### Layer Management
- [ ] Tap layers button (stack icon)
- [ ] Add new layer - should create "Layer 2"
- [ ] Draw on Layer 2 - stroke should appear
- [ ] Hide Layer 2 (eye icon) - drawing should disappear
- [ ] Show Layer 2 - drawing should reappear
- [ ] Delete Layer 2 (must have at least 1 layer)

### Layer Thumbnails
- [ ] Draw on layer - thumbnail should update to show preview
- [ ] Switch layers - correct layer should be selected

---

## 🎯 Priority 5: Shape Tools

### Line Tool
- [ ] Select line tool
- [ ] Tap and drag - should show line preview
- [ ] Release - line should commit to canvas

### Rectangle Tool
- [ ] Tap and drag to draw rectangle outline
- [ ] Should be hollow (outline only)

### Circle Tool
- [ ] Tap and drag to draw ellipse
- [ ] Should maintain aspect ratio based on drag

### Polygon Tool
- [ ] Tap multiple points to build polygon
- [ ] Tap near first point to close - polygon should draw

---

## 🎯 Priority 6: Other Tools

### Paint Bucket
- [ ] Draw closed shape (rectangle)
- [ ] Switch to paint bucket, pick color
- [ ] Tap inside shape - should flood fill

### Eyedropper
- [ ] Draw something with red
- [ ] Switch to eyedropper, tap red area
- [ ] Brush color should change to red

### Text Tool
- [ ] Select text tool, tap canvas
- [ ] Enter text "Hello"
- [ ] Text should appear on canvas

### Blur Tool
- [ ] Draw something
- [ ] Switch to blur tool, drag over area
- [ ] Area should blur slightly

### Sharpen Tool
- [ ] Draw something blurry
- [ ] Switch to sharpen, drag over area
- [ ] Should sharpen slightly

---

## 🎯 Priority 7: UI & Navigation

### Onboarding
- [ ] Fresh install - should see onboarding popup
- [ ] Text should say "personalized drawing coach" (not "AI")
- [ ] Button should say "Get personalized feedback" (not "AI feedback")

### Feedback Panel
- [ ] Draw something, tap "Get Feedback" button
- [ ] Wait for response (may take 5-10 seconds)
- [ ] Floating panel should appear with feedback
- [ ] Drag panel around - should move smoothly
- [ ] Collapse panel (chevron down) - should minimize to icon
- [ ] Tap icon - should expand again
- [ ] **Verify markdown formatting** (bold, bullets, etc.) renders correctly

### Dark Mode
- [ ] Switch device to dark mode
- [ ] Gallery thumbnails should have white background (not dark)
- [ ] UI should adapt to dark mode properly
- [ ] **Known Issue**: No dark mode toggle in app yet (P1)

### Toolbar
- [ ] Collapse toolbar (chevron left) - should slide off screen
- [ ] Expand toolbar (chevron right) - should slide back
- [ ] Gallery button should stay visible when collapsed

---

## 🚨 Known Issues to Document

### P0 Issues (Critical):
1. **Canvas Rotation** - NOT TESTED YET
   - [ ] Rotate iPad from portrait to landscape while drawing
   - [ ] Check if existing strokes distort (EXPECTED BUG)

2. **Zoom** - NOT IMPLEMENTED YET
   - [ ] Try pinch-to-zoom gesture (will not work - not implemented)

### P1 Issues (Important):
1. **Brush Width on Release**
   - [ ] Draw stroke, note width at end
   - [ ] If last point is thicker than rest - CONFIRM BUG

2. **Landing Screen**
   - [ ] App launches directly to canvas (might feel too fast)

3. **Dark Mode Toggle**
   - [ ] No in-app toggle for dark/light mode (uses system setting)

---

## 🔍 Debug Logging to Check

If you encounter issues, check Xcode console for:

```
✅ Marks successful operations
❌ Marks errors
👆 Touch input events
🎨 Rendering operations
✂️ Selection operations
```

### Key Debug Output:
- Texture IDs should match across operations
- Touch coordinates should be logged
- Selection rect/path creation logged
- Pixel extraction logged with dimensions

---

## 📊 Performance Checks

- [ ] Drawing feels smooth (60fps) with no lag
- [ ] Selection drag is responsive (no stuttering)
- [ ] Gallery thumbnails load quickly
- [ ] Undo/redo is instant
- [ ] App doesn't crash during any operation
- [ ] Memory usage stays reasonable (check Xcode instruments if concerned)

---

## ✅ Success Criteria

**Must Work:**
- ✅ Create, save, and edit drawings
- ✅ Gallery navigation works perfectly
- ✅ Selection tools (rectangle, lasso, move, delete)
- ✅ Basic drawing tools (brush, eraser, shapes)
- ✅ Undo/redo functionality
- ✅ Layers work correctly

**Known Limitations:**
- ⚠️ No zoom (P0 - not implemented)
- ⚠️ Rotation may distort (P0 - known bug)
- ⚠️ Brush may thicken on release (P1 - minor)

---

## 📸 Screenshots to Capture

If reporting bugs, please capture:
1. Gallery view showing thumbnails
2. Canvas with active selection (marching ants visible)
3. Selection being moved (semi-transparent preview visible)
4. Feedback panel (expanded and collapsed states)
5. Layer panel with multiple layers
6. Any error states or unexpected behavior

---

## 🐛 Bug Report Template

If you find a bug:

```
**Bug Title:** [Short description]

**Steps to Reproduce:**
1.
2.
3.

**Expected:** [What should happen]
**Actual:** [What actually happened]

**Console Output:** [Paste relevant logs if available]
**Screenshot:** [Attach if helpful]

**Device:** iPad [model]
**iOS Version:** [version]
**Build:** [commit hash or date]
```

---

## 📞 Quick Reference

**Latest Commit:** dddd5a4
**Session Date:** October 12, 2025
**Major Features Added:** Selection tools with marching ants, pixel extraction, touch-drag movement
**Files to Watch:** MetalCanvasView.swift, CanvasRenderer.swift, DrawingCanvasView.swift

**If Something Breaks:** Check `whereweleftoff.md` for architecture notes and known issues.
