# DrawEvolve Tool Audit — April 15, 2026

Trevor's on-device audit of every tool and related UI behavior that's still in the app. Captures what's broken, what's missing, and what's questionable before TestFlight.

> **Cut tools** (Magic Wand, Smudge, Blur, Sharpen / "black triangle", Clone Stamp, Polygon, plus the never-implemented Clipboard button and the on-canvas brush stamp dots) are no longer in the app. See `CUT_TOOLS_TO_REINSTATE.md` at project root for what was removed, why, and notes on how to bring each one back.

---

## Tool-by-tool findings

### Shape tools
- ✅ **Circle and Rectangle rotation** — FIXED (April 15). Shape generation now happens in screen space with each stamp mapped back through `screenToDocument`; rectangle + circle are screen-axis-aligned regardless of canvas rotation/zoom/pan. Line is rotation-invariant. Confirmed on device.

### Paint bucket
- Fill takes a long time to complete.
- Leaves a thin white outline around filled regions — not a true paint-bucket fill (likely antialiased boundary pixels getting skipped by the flood fill's color-match tolerance).
- VERDICT → **KEEP AND FIX**

### Text
- Adding text causes a breakpoint/crash.
- Font handling isn't figured out — no sensible font picker, sizing, or styling story yet.
- VERDICT → **KEEP AND FIX**

### Color picker / eyedropper
- Doesn't work. Tapping the canvas with the eyedropper doesn't update the brush color.
- VERDICT → **KEEP AND FIX**

### Rectangular select / Lasso
- Selection and move work after the April 15 polygon rewrite.
- Still exhibits the ~10px Y-jump when Delete is tapped (see April 15 revival journal).
- VERDICT → **KEEP AND FIX (SO CLOSE)**

### Move tool (pointer)
- ✅ **NEW (April 15)** — implemented per the prior audit's "URGENT NEED POINTER TOOL" note. Tapping the move tool grabs every pixel in the selected layer as a single floating selection; drag relocates the whole layer, release commits with full undo support. Reuses the rect-selection extract/drag/commit pipeline. Needs on-device confirmation.

### Stroke resolution (canvas-wide)
- ✅ **FIXED** (April 14). Canvas texture now sizes from `view.drawableSize` (pixels) instead of `view.bounds.size` (points), pushing it from 2048² to 4096² on iPad Pro so strokes render at the display's native resolution. Default `BrushSettings.size` doubled (5 → 10) and slider max doubled (100 → 200) to compensate for the doubled doc-pixel coord system. Memory cost: ~48 MB per layer (320 MB at 5 layers) — fine on iPad Pro, monitor on base iPad.

---

## Missing features

- ✅ **Image import — basic** (April 15). New `photo.badge.plus` button in the toolbar opens the system PhotosPicker. On selection, the image is dropped onto a brand-new layer, aspect-fit and centered at ~80% of the document. After import the user can use the Move tool to reposition. Implemented via `CanvasStateManager.importImage(_:)`. Needs on-device confirmation.

## High-priority deferred work

> These are NOT done yet. They are the obvious next steps and should be picked up before TestFlight.

- **Corner scale/rotate handles for selections (HIGH PRIORITY)** — in-flight transform via draggable anchors at the four corners of any active selection. This was the original UX intent for the imported image (and was specced in the prior audit as "with scale anchors in corners"), but the handles don't exist anywhere in `Views/SelectionOverlays.swift` yet — only marching-ants borders are drawn. Once built, the handles must work for **all selection sources**:
  - Rectangular Select
  - Lasso (quick selection)
  - Imported images (currently rely on Move tool only)

  State plumbing already exists on `CanvasStateManager` (`selectionScale`, `selectionRotation`, `selectionOffset`) and `renderSelectionInRealTime()` already applies scale/offset, so the missing piece is the SwiftUI overlay + drag gesture math. A rotate handle (above the bounding box, like Photoshop) would be a natural addition while in there.

- **Rectangular Select Y-jump on Delete (~10px)** — known existing bug in the rect-select path. Lives in the same code area as the work above; fix while implementing the corner handles since both touch the rect-selection rendering math.

- **Procreate-style multitouch shape constraint (HIGH PRIORITY)** — when the user is mid-drag on the Rectangle or Circle tool, a second finger touching the screen should snap the in-progress shape to a perfect square / perfect circle (i.e. force width = height around the drag origin). Release of the second finger un-snaps. This is the Procreate "QuickShape"-style affordance Trevor wants. Implementation lives in `Views/MetalCanvasView.swift` `touchesMoved`/`touchesEnded` for `.rectangle` and `.circle`; the `UIEvent` already exposes the touch count via `touches(for: view)?.count`. Watch out for the screen-space → doc-space mapping introduced by the April 15 rotation fix — the constraint needs to apply in screen space and then map through, the same way the shape itself does.

---

## Cross-cutting UX

- **Tool selected indicator** — when a tool is selected, briefly show the tool's name mid-screen (fade in, hold briefly, fade out). Quick affordance so the user knows what they just tapped.
- **Brush settings** — full pass needed on true hardware (sizes, hardness curves, pressure curves, spacing defaults). Today's prompt-side fixes don't cover on-iPad feel.
- **Hand-drawn tool icons** — Trevor considering replacing SF Symbols with custom icons for personality. Target size: 44×44 pt button with ~22pt glyph; design as vector (PDF/SVG) or raster at 132×132px (@3×).

---

## AI feedback panel

- History panel goes off screen — needs a layout that fits the expanded panel and scrolls correctly on iPad.
- Should default to loading the **most recent** feedback when opened, not an empty state.

---

## Triage for TestFlight (deadline 2026-06-01)

**Must fix before ship:**
- Paint bucket outline + performance.
- Text breakpoint.
- Color picker / eyedropper.
- AI feedback history panel layout + default-most-recent.
- Selection delete ~10px jump.
- Corner scale/rotate handles for selections (Rect Select, Lasso, imported images) — see High-priority deferred work above.
- Procreate-style multitouch constraint for perfect circles/squares — see High-priority deferred work above.
- Verify Move tool + image import on device.

**Should fix before ship (polish):**
- Tool-selected mid-screen indicator.
- Brush settings on-hardware tuning pass.
- Hand-drawn tool icons (if Trevor has the time).

**Already done:**
- ✅ Circle/Rectangle rotation behavior.
- ✅ Low-res stroke rendering.
- ✅ Move tool / pointer (full-layer drag).
- ✅ Image import — basic (drops into a new layer; reposition via Move tool until corner handles land).
- ✅ Six broken/half-built tools cut from the toolbar (see `CUT_TOOLS_TO_REINSTATE.md`).
