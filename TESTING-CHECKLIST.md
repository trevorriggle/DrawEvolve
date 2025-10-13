# DrawEvolve Testing Checklist

**Last Updated:** January 13, 2025
**Build Status:** Ready for iPad testing

---

## CRITICAL: Stroke Offset Bug Fix

**Priority 1 Test:**
- [ ] Draw a brush stroke and release - verify it stays EXACTLY where you drew it
- [ ] Draw strokes in all corners of the screen - no offset anywhere
- [ ] Draw with different brush sizes - all should land correctly
- [ ] This was a critical bug that's now fixed - must verify!

---

## Core Drawing Tests

### Brush Tool
- [ ] Pressure sensitivity works with Apple Pencil
- [ ] Smooth interpolation between points
- [ ] Color, size, opacity, hardness all functional
- [ ] No offset when releasing stroke (CRITICAL - just fixed!)

### Other Tools
- [ ] Eraser removes pixels cleanly
- [ ] Shapes (line, rectangle, circle, polygon) draw correctly
- [ ] Paint bucket flood fills
- [ ] Eyedropper picks colors
- [ ] Text tool adds text at correct location
- [ ] Blur/sharpen apply effects

### Selection Tools
- [ ] Rectangle select with marching ants
- [ ] Lasso select with marching ants
- [ ] Can drag selection to move it
- [ ] Delete selection works
- [ ] Cancel selection works

---

## Layers & History

### Layers
- [ ] Add/delete layers
- [ ] Toggle visibility
- [ ] Adjust opacity
- [ ] Thumbnails update correctly
- [ ] Drawing on correct layer

### Undo/Redo
- [ ] Undo stroke operations
- [ ] Redo stroke operations
- [ ] Buttons enable/disable correctly
- [ ] Works across layer operations

---

## AI Feedback

### Basic Feedback
- [ ] "Get Feedback" button works
- [ ] Loading state displays
- [ ] Feedback appears in floating panel
- [ ] Panel is draggable
- [ ] **NEW:** Markdown formatting renders (bold, bullets, headers, etc.)
- [ ] Panel can be dismissed

### Critique History (UNTESTED)
- [ ] Get feedback on a drawing
- [ ] Get feedback again (second critique)
- [ ] Tap "View History" button
- [ ] History view shows both critiques with timestamps
- [ ] Can navigate back to drawing

**Note:** Critique history is fully implemented but hasn't been tested end-to-end yet!

---

## Save/Load System

### Gallery
- [ ] Save drawing with title
- [ ] Drawing appears in gallery
- [ ] Thumbnail displays correctly
- [ ] Can open existing drawing
- [ ] Editing updates drawing (doesn't create duplicate)
- [ ] Gallery accessible even with toolbar collapsed

---

## UI/UX

### Interface
- [ ] Onboarding shows on first launch
- [ ] Toolbar collapses/expands smoothly
- [ ] Dark mode toggle works (light/dark only)
- [ ] Loading screen displays correctly
- [ ] App icon visible
- [ ] Buttons disable when canvas empty

---

## Known Issues (Don't Test - Intentionally Disabled)

### Zoom/Pan/Rotate
- **DO NOT TEST** - Intentionally disabled
- Gesture recognizers exist but coordinate transforms are disabled
- Will be re-implemented in future session with physical iPad

### Untested Features
- Critique history (implemented but needs verification)

---

## Performance

- [ ] Drawing feels smooth (60fps)
- [ ] No lag when drawing fast strokes
- [ ] Selection drag is responsive
- [ ] Gallery loads quickly
- [ ] Undo/redo is instant
- [ ] No crashes

---

## Test on Physical iPad

**Essential Tests:**
1. Verify stroke offset fix (draw in all areas of screen)
2. Test Apple Pencil pressure sensitivity
3. Test critique history feature
4. Overall UI responsiveness
5. Performance with multiple layers

**Device Info to Note:**
- iPad model
- iOS version
- Apple Pencil generation
- Any unusual behavior

---

## If You Find Bugs

**Report Format:**
```
Bug: [Short description]

Steps:
1. [Step 1]
2. [Step 2]
3. [Result]

Expected: [What should happen]
Actual: [What happened]

Console logs: [If available]
```

---

## Success Criteria

**Must Work:**
- ✅ Drawing with no stroke offset
- ✅ All basic tools functional
- ✅ Save/load system works
- ✅ AI feedback displays correctly

**Known Limitations:**
- No zoom/pan (deferred)
- Critique history untested

---

## Quick Reference

- **Latest fix:** Coordinate scaling in `CanvasRenderer.swift` line 218-220
- **Branch:** main
- **Ready for:** Physical iPad testing
