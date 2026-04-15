# DrawEvolve Tool Audit — April 15, 2026

Trevor's on-device audit of every tool and related UI behavior. Captures what's broken, what's missing, and what's questionable before TestFlight.

---

## Tool-by-tool findings

### Shape tools
- ✅ **Circle and Square/Rectangle rotation** — FIXED. Shape generation now happens in screen space with each stamp mapped back through `screenToDocument`; rectangle + circle are screen-axis-aligned regardless of canvas rotation/zoom/pan. Line unchanged (rotation-invariant). Confirmed on device.

### Paint bucket
- Fill takes a long time to complete.
- Leaves a thin white outline around filled regions — not a true paint-bucket fill (likely antialiased boundary pixels getting skipped by the flood fill's color-match tolerance).

### Text
- Adding text causes a breakpoint/crash.
- Font handling isn't figured out — no sensible font picker, sizing, or styling story yet.

### Color picker / eyedropper
- Doesn't work. Tapping the canvas with the eyedropper doesn't update the brush color.

### Magic selection (magic wand)
- Doesn't work.
- **Decision: cut from UI** for v1 (Trevor confirmed).

### Smudge (finger smudge tool)
- Doesn't work.
- **Decision: cut from UI** for v1 (Trevor confirmed).

### "Black triangle" tool
- Does *something* but unclear what.
- **Decision: cut from UI** for v1 (Trevor confirmed).

### Brush dots / stamp preview
- "Brush dot things" don't seem to work.
- **Decision: cut from UI** for v1 if still broken after brush tuning pass.

### Rectangular select
- Selection and move work after today's polygon rewrite.
- Still exhibits the ~10px Y-jump when Delete is tapped (see April 15 revival journal).

### Clipboard button
- Redundant / unclear purpose.
- **Decision: cut from UI** for v1 (Trevor confirmed).

### Stroke resolution (canvas-wide)
- ✅ **Low-res / blocky stroke edges** — FIXED. Canvas texture now sizes from `view.drawableSize` (pixels) instead of `view.bounds.size` (points), pushing it from 2048² to 4096² on iPad Pro so strokes render at the display's native resolution. Default `BrushSettings.size` doubled (5 → 10) and slider max doubled (100 → 200) to compensate for the doubled doc-pixel coord system. Memory cost: ~48 MB per layer (320 MB at 5 layers) — fine on iPad Pro, monitor on base iPad.

---

## Missing features

- **Image import** — no way to bring an existing image into the canvas. Needed button/tool.

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

## Triage for TestFlight

**Must fix before ship:**
- ~~Circle/Rectangle rotation behavior.~~ ✅
- ~~Low-res stroke rendering.~~ ✅
- Paint bucket outline + performance.
- Text breakpoint.
- Color picker / eyedropper.
- AI feedback history panel layout + default-most-recent.
- Image import tool.
- Selection delete ~10px jump.

**Should fix before ship (polish):**
- Tool-selected mid-screen indicator.
- Brush settings on-hardware tuning pass.
- Hand-drawn tool icons (if Trevor has the time).

**Cut from UI for v1 (decided):**
- Magic selection.
- Smudge tool.
- Clipboard button.
- "Black triangle" tool.
- Brush stamp preview dots (if still broken after brush tuning pass).
