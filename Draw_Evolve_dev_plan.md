DrawEvolve Dev Plan - April 2026
The Only Helper File That Matters
Audited: April 10, 2026 (physical iPad, Apple Pencil)
Author: Trevor Riggle (RIG Tech)
Goal: TestFlight-ready build before June 1, 2026
Method: Claude Code handles the code. Trevor handles the iPad testing.

Phase 1: Core Drawing Must Work (P0)
Nothing else matters until you can draw correctly on the iPad.
1.1 Fix brush stroke offset and distortion

Symptom: Strokes render offset and distorted upward from where the Pencil/finger touches
Likely cause: screenToDocument() transform pipeline broken on physical device (may work differently than simulator due to screen scale, safe area insets, or coordinate space differences)
Files to investigate: CanvasStateManager.swift (screenToDocument/documentToScreen), MetalCanvasView.swift (touch handlers), Shaders.metal (vertex shader transforms)
Test: Draw a dot, it appears exactly where you touched. At all canvas positions.

1.2 Fix canvas zoom and pan

Symptom: No zooming or panning works at all on physical device
Likely cause: Gesture recognizers may not be firing, or transforms are applied but not reflected in rendering. Could be related to 1.1 - if the base transform is broken, zoom/pan built on top of it will also break.
Files to investigate: MetalCanvasView.swift (handlePinch, handlePan, handleRotation gesture handlers), CanvasStateManager.swift (zoom/pan state)
Test: Pinch to zoom in/out. Two-finger pan. Draw after zooming - strokes land correctly.
NOTE: If gesture approach is fundamentally broken on device, may need to reconsider gesture handling strategy.

1.3 Fix Apple Pencil input for all tools

Symptom: Most tools don't work with Pencil, only finger. Finger vs Pencil yields different stroke widths.
Likely cause: Touch type detection may be filtering incorrectly, or Pencil-specific code paths are broken.
Files to investigate: MetalCanvasView.swift (touchesBegan/Moved/Ended - touch.type checks)
Test: Every tool responds to Apple Pencil. Pressure sensitivity works smoothly.

1.4 Fix circle tool crash

Symptom: Circle tool crashes the app entirely
Likely cause: Edge case in generateCirclePoints() - possibly division by zero if start and end points are the same, or NaN from the Ramanujan perimeter calculation with zero radius
Files to investigate: MetalCanvasView.swift (generateCirclePoints function)
Test: Draw circles of various sizes including very small ones. No crash.

Phase 1 check: Can you draw accurately with the Pencil, zoom in, pan around, and draw more without offset? If yes, move to Phase 2.

Phase 2: Core Features Must Work (P0-P1)
Drawing works. Now make sure the app works.
2.1 Fix redo

Symptom: Undo works, redo does not
Likely cause: HistoryManager redo stack not being populated correctly, or redo action not restoring texture state
Files to investigate: CanvasStateManager.swift (redo function), HistoryManager (redo stack logic)
Test: Draw stroke, undo (disappears), redo (reappears). Multiple times in sequence.

2.2 Fix gallery preview

Symptom: Gallery preview is badly broken
Likely cause: Thumbnail generation, image sizing, or layout issue in gallery view
Files to investigate: GalleryView.swift, DrawingStorageManager (thumbnail generation/storage)
Test: Save 3 drawings. Gallery shows correct, properly sized thumbnails for each.

2.3 Fix navigation state (panels opening incorrectly)

Symptom: Stroke properties panel and layers panel open when clicking gallery items. Layers panel inaccessible from canvas. Breaks dark mode testing too.
Likely cause: Navigation state machine has overlapping triggers or shared state between gallery and canvas views
Files to investigate: DrawingCanvasView.swift (panel state management), AppState/navigation logic
Test: Gallery items open drawing detail only. Layers panel opens from canvas only. Dark mode toggle accessible.

2.4 Fix selection tools

Symptom: Rectangle select partially works but broken. Magic wand totally broken.
Likely cause: Selection coordinate transforms (same root as 1.1), or selection pixel extraction failing on device
Files to investigate: CanvasStateManager.swift (selection management), MetalCanvasView.swift (selection touch handlers, magicWandSelection)
Test: Rectangle select a region, move it. Magic wand selects contiguous color region.

2.5 Fix AI feedback display

Symptom: Feedback exists in data but can't be previewed. Feedback history has unknown issue.
Likely cause: FeedbackOverlay or FloatingFeedbackPanel not triggering, or feedback data not being passed to display components correctly
Files to investigate: FeedbackOverlay.swift, FloatingFeedbackPanel.swift, DrawingCanvasView.swift (feedback display triggers)
Test: Draw something, get feedback, see it rendered with markdown formatting. View history of past feedback.

Phase 2 check: Full user flow works - draw, save, view gallery, get feedback, undo/redo, use selection tools. If yes, move to Phase 3.

Phase 3: Polish for TestFlight (P1-P2)
3.1 Fix Pencil vs finger stroke width consistency

Symptom: Drawing with finger yields different width than Pencil
Details: Pressure sensitivity partially works, but base width behavior differs
Test: Finger and Pencil produce predictable, consistent strokes at same brush size setting.

3.2 Improve app launch time

Symptom: App takes forever to launch
Likely cause: Heavy initialization on main thread, possibly texture creation or renderer setup blocking
Test: App launches in under 3 seconds.

3.3 Landing screen / loading state

From original P1 list: App loads too fast into canvas (or too slow now). Need a proper launch experience.
Test: Professional-looking launch that transitions smoothly to canvas or gallery.

3.4 Brush thickens on release

From original P1 list: Stroke width changes on touchesEnded
Test: Stroke width remains consistent from first touch to release.

Phase 3 check: App feels polished enough for strangers to use without confusion. Ship to TestFlight.

Dev Workflow

Open Claude Code in DrawEvolve codespace
Point it at a specific bug from this list
Let it read the relevant files, write the fix
Push to GitHub
Pull to Mac Mini in Xcode
Build to iPad
Test with Pencil in hand
If fixed, check it off. If not, report back to Claude with what happened.
Next bug.


Rules

This is the ONLY planning document. All other helper .md files are deprecated.
Don't start Phase 2 until Phase 1 is solid.
Don't start Phase 3 until Phase 2 is solid.
If a fix breaks something else, stop and reassess before continuing.
Test on the physical iPad with the actual Pencil. Simulator means nothing.


Status Tracker

 1.1 Brush stroke offset/distortion
 1.2 Canvas zoom and pan
 1.3 Apple Pencil input for all tools
 1.4 Circle tool crash
 2.1 Redo
 2.2 Gallery preview
 2.3 Navigation state
 2.4 Selection tools
 2.5 AI feedback display
 3.1 Pencil vs finger width
 3.2 Launch time
 3.3 Landing screen
 3.4 Brush thickens on release
 TESTFLIGHT SUBMISSION