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

- **Image import** — no way to bring an existing image into the canvas. Needed button/tool.
  - VERDICT → **ADD** (with scale anchors in corners — drop into its own layer)

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
- Image import tool.
- Selection delete ~10px jump.
- Verify Move tool on device.

**Should fix before ship (polish):**
- Tool-selected mid-screen indicator.
- Brush settings on-hardware tuning pass.
- Hand-drawn tool icons (if Trevor has the time).

**Already done:**
- ✅ Circle/Rectangle rotation behavior.
- ✅ Low-res stroke rendering.
- ✅ Move tool / pointer (full-layer drag).
- ✅ Six broken/half-built tools cut from the toolbar (see `CUT_TOOLS_TO_REINSTATE.md`).
