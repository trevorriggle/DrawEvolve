# DrawEvolve Testing Checklist

**Last Updated:** January 20, 2025
**Build Status:** Ready for iPad testing (Apple Pencil + selection bugs fixed)

---

## CRITICAL: Recent Bug Fixes (Jan 20, 2025)

**Priority 1 Tests:**
- [ ] **Apple Pencil Input** - Verify touch/pencil input works throughout the app
  - [ ] Can draw on canvas with Apple Pencil
  - [ ] Can use toolbar buttons
  - [ ] Can interact with all UI elements
  - [ ] Fixed: SwiftUI overlays were blocking hit testing
- [ ] **Delete Selection** - Verify selection deletion works properly
  - [ ] Make rectangle selection, tap delete, verify pixels are cleared
  - [ ] Make lasso selection, tap delete, verify pixels are cleared
  - [ ] After delete, verify no ghost selection data remains
  - [ ] Fixed: clearSelection() now clears all selection state
- [ ] **Feedback Panel Positioning** - Verify panel stays on screen
  - [ ] Open feedback panel, verify it appears on screen
  - [ ] Drag panel around, verify it stays within bounds
  - [ ] Tap reset button (counterclockwise arrow), verify it returns to top-right
  - [ ] Collapse panel to icon, drag it around, verify smooth animation
  - [ ] Fixed: Improved positioning logic and added reset button
- [ ] **Stroke Position (Jan 13 fix)** - Verify strokes land where drawn
  - [ ] Draw strokes in all corners - no offset anywhere
  - [ ] Draw with different brush sizes - all should land correctly

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
- [ ] Blue preview strokes show while dragging selection
- [ ] Can drag selection to move it
- [x] Delete selection works (FIXED Jan 20)
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
- [ ] AI feedback toolbar button (sparkles icon) works
- [ ] Loading state displays
- [ ] Feedback appears in floating panel
- [x] Panel is draggable (FIXED Jan 20)
- [x] Panel has reset position button (FIXED Jan 20)
- [x] Collapsed icon is draggable (FIXED Jan 20)
- [x] Markdown formatting renders (bold, bullets, headers, etc.)
- [ ] Panel can be dismissed
- [ ] Can reopen panel with AI toolbar button

### Critique History
- [ ] Get feedback on a drawing
- [ ] Get feedback again (second critique)
- [ ] Tap hamburger menu icon
- [x] History shows newest critique first (FIXED Jan 20)
- [ ] History menu shows all critiques with timestamps
- [ ] Can select any critique to view it
- [ ] Shows "1 of N" counter in main panel
- [ ] Can navigate back to drawing

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
- Selection pixel moving (extract and drag - implemented but needs verification)

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
1. Verify Apple Pencil input works (overlay hit testing fix - Jan 20)
2. Verify stroke position is accurate (coordinate scaling fix - Jan 13)
3. Test delete selection (clearSelection fix - Jan 20)
4. Test feedback panel positioning and reset button (Jan 20)
5. Test Apple Pencil pressure sensitivity
6. Test critique history feature (newest first ordering)
7. Overall UI responsiveness
8. Performance with multiple layers

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
- ✅ Apple Pencil input responds (Jan 20 fix)
- ✅ Drawing with no stroke offset (Jan 13 fix)
- ✅ Delete selection clears all data (Jan 20 fix)
- ✅ All basic tools functional
- ✅ Save/load system works
- ✅ AI feedback displays correctly
- ✅ Feedback panel stays on screen (Jan 20 fix)

**Known Limitations:**
- No zoom/pan (deferred)
- Selection pixel moving untested

---

## Quick Reference

- **Session:** Jan 20, 2025
- **Latest fixes:**
  - Apple Pencil input: `ContentView.swift` lines 26-54
  - Delete selection: `DrawingCanvasView.swift` lines 1002-1010
  - Feedback panel: `FloatingFeedbackPanel.swift` (positioning + reset button)
  - Stroke coordinates: `CanvasRenderer.swift` lines 218-220 (Jan 13)
- **Branch:** main
- **Ready for:** Physical iPad testing
