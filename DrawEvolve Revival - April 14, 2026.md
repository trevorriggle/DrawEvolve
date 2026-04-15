# DrawEvolve Revival — April 14–15, 2026

**Started from:** Unplugged Mac Mini, cancelled accounts, couldn't remember the workflow, hadn't touched the project in 5 months.
**Ended with:** A running app on a physical iPad with core drawing, zoom, pan, and rotation all working.

---

## What happened

- Plugged in the Mac Mini, reconnected AnyDesk
- Discovered GitHub repos were still intact (never actually cancelled)
- Found past-Trevor left detailed documentation including a "where we left off" file dated the exact day development stopped
- Spun up a fresh codespace, installed Claude Code
- Paid for Claude Max to handle the 100k+ line codebase
- Claude Code performed a full audit of every file in the repo, produced a surgical diagnosis with specific line numbers and root causes for every bug
- Identified that 80% of the bug list traced back to three root causes: async state timing, gesture recognizer race conditions, and nested ObservableObject not propagating changes
- Fixed `screenSize` initialization timing (stale `.zero` on first touch)
- Fixed gesture recognizers so pinch/pan/rotation actually fire on device
- Fixed Y-inversion in shader pan math
- Fixed Apple Pencil input with coalesced touches at 240Hz
- Wired up dead pressure sensitivity sliders that existed in UI but did nothing
- Fixed circle tool NaN crash (zero-radius guard)
- Fixed redo button (nested ObservableObject bridging)
- Found and fixed the real coordinate pipeline bug: aspect ratio correction was overshooting by 17%, proven with mathematical trace
- Rewrote the shader to remove redundant dual-transform that was compounding the error
- Unified all coordinate math around a single `fitSize` model
- Found and fixed rotation sign convention mismatch between Metal Y-up and UIKit Y-down
- Fixed prenview stroke scaling to match zoom level
- Fixed critique history duplication bug in `DrawingStorageManager`
- Fixed gallery card layout (proper square cells)
- Deleted all outdated helper markdown files, replaced with one clean dev plan

**Bugs squashed: 7 of 13 on the checklist**

---

## Status Tracker

- [x] 1.1 Brush stroke offset/distortion
- [x] 1.2 Canvas zoom and pan
- [x] 1.3 Apple Pencil input for all tools
- [x] 1.4 Circle tool crash
- [x] 2.1 Redo
- [ ] 2.2 Gallery preview
- [ ] 2.3 Navigation state
- [ ] 2.4 Selection tools
- [x] 2.5 AI feedback display
- [x] 3.1 Pencil vs finger width
- [x] 3.2 Launch time
- [x] 3.3 Landing screen
- [x] 3.4 Brush thickens on release
- [ ] Canvas fill/clipping fix
- [ ] Reset transform button
- [ ] **TESTFLIGHT SUBMISSION**

**TestFlight target:** Before June 1. Possibly end of April at this pace.

---

## Tonight's session (canvas fill + off-canvas background)

Problem: drawing quad was a square fitted to the *shorter* viewport dimension (letter/pillarbox), so strokes were hard-clipped at a visible canvas edge inside the screen.

Changes shipped:
- **`DrawEvolve/Shaders.metal`** (`quadVertexShaderWithTransform`): flipped aspect-ratio correction from **fit (min)** to **fill (max)**. Square canvas quad now covers the longer viewport dimension at zoom=1. Landscape: `scale.y = aspect` extends the quad past top/bottom. Portrait: `scale.x = 1/aspect` extends past left/right.
- **`ViewModels/CanvasStateManager.swift`**: `fitSize = min(...)` → `max(...)` in `screenToDocument` and `documentToScreen` (3 sites). Keeps inverse transforms in sync with shader.
- **`Services/CanvasRenderer.swift`** (`renderStrokePreview`, ~line 602): same `min` → `max` for the live preview path.
- **`Views/MetalCanvasView.swift`**: `metalView.clearColor` + `backgroundColor` changed from white to light gray (0.9, 0.9, 0.9) so the off-canvas "workbench" is visible.

### Known limitation
The quad is still a **square sized to the viewport's longer edge**. At 1× zoom:
- Long axis — quad exactly matches the viewport; panning along that axis reveals gray almost immediately.
- Short axis — quad overshoots by `(aspect − 1) × short_dim / 2` pixels (~150–180px on iPad landscape); you have to pan that far before gray appears.
- Zooming out reveals gray on all sides.

Trevor on device: "panning indefinitely and nothing." Partially expected (long-axis reveals it; short-axis needs bigger pan). Not ideal UX — see decision point below.

---

## What to do next

### 1. Finish the canvas fill refinement — decision point

- **Option A (shipped tonight):** square quad, covers longer viewport dim. Simple, but short-axis requires a meaningful pan before gray shows up.
- **Option B:** rectangular quad matching the viewport exactly. Any pan in any direction reveals gray immediately. Texture stays square (document is square), but quad is sized viewport.w × viewport.h and samples the texture with UV scaling. Touches shader + both coordinate transforms — moderate risk, needs retest of stroke placement on iPad (same code path as the Phase-1 offset bug).
- **Option C:** make the document itself rectangular / viewport-matched. Bigger architectural change; probably overkill.

Recommend Option B for the "no visible edges at default zoom, gray only on pan/zoom away" UX goal. Before shipping, verify on physical iPad:
- Strokes land exactly under Pencil tip at 1× zoom, all four corners.
- Strokes land correctly after pinch-zoom and pan.
- Strokes land correctly after canvas rotation.

### 2. Feedback + feedback history + gallery display (Trevor's next area)

Not yet audited. Likely files to survey next session:
- `Views/FeedbackOverlay.swift`
- `Views/FloatingFeedbackPanel.swift`
- `Views/FormattedMarkdownView.swift` (feedback rendered as markdown)
- `Views/GalleryView.swift` + `Views/DrawingDetailView.swift`
- Any `Services/` file handling feedback persistence (check for `FeedbackService`, `HistoryService`, or similar)

Questions to answer:
- Where is feedback stored (local only? Supabase? CloudKit?)
- Per-drawing history, or just latest?
- How is feedback surfaced in the gallery (badge? thumbnail overlay? tap-through?)
- Does feedback survive app relaunch / device restart?
- What happens to feedback if the drawing is edited after feedback was generated?

### 3. Remaining checklist items before TestFlight

- Canvas fill/clipping fix (Option B above)
- Gallery preview (2.2)
- Navigation state (2.3)
- Selection tools (2.4)
- AI feedback display (2.5) — overlaps with feedback audit
- Launch time (3.2)
- Landing screen (3.3)
- Reset transform button
- TestFlight submission

---

## Notes for future sessions

- I (Claude) can't see iPad runtime logs. If a rendering bug needs debugging, ask Trevor for Xcode console output or add targeted `print`s.
- Coordinate transform code (`screenToDocument` / `documentToScreen` / shader `quadVertexShaderWithTransform`) is load-bearing and historically painful. Any change to one must be mirrored in the others. Always retest stroke placement on physical iPad after touching these.
- Dev plan lives at `Draw_Evolve_dev_plan.md`. This file is the running revival journal.

## Quick reference — files touched tonight
- `DrawEvolve/DrawEvolve/Shaders.metal`
- `DrawEvolve/DrawEvolve/ViewModels/CanvasStateManager.swift`
- `DrawEvolve/DrawEvolve/Services/CanvasRenderer.swift`
- `DrawEvolve/DrawEvolve/Views/MetalCanvasView.swift`
