# DrawEvolve Tool Audit — April 15, 2026

Trevor's on-device audit of every tool and related UI behavior. Captures what's broken, what's missing, and what's questionable before TestFlight.

---

## Tool-by-tool findings

### Shape tools
- **Circle and Square/Rectangle** — these *shouldn't* account for canvas rotation. Currently they do, which means a rectangle drawn on a rotated canvas ends up rotated relative to the drag. They should draw axis-aligned to the user's on-screen drag regardless of canvas rotation.

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
- Questionable whether it needs to be in v1 at all.

### Smudge (finger smudge tool)
- Doesn't work.
- Questionable whether it needs to be in v1.

### "Black triangle" tool
- Does *something* but unclear what. Needs identification — likely a stale/unused tool that should either be documented or removed.

### Brush dots / stamp preview
- "Brush dot things" don't seem to work (likely the brush size/hardness/opacity preview dots next to the size slider).

### Rectangular select
- Selection and move work after today's polygon rewrite.
- Still exhibits the ~10px Y-jump when Delete is tapped (see April 15 revival journal).

### Clipboard button
- Redundant / unclear purpose. Probably cut candidate.

---

## Missing features

- **Image import** — no way to bring an existing image into the canvas. Needed button/tool.

---

## Cross-cutting UX

- **Tool selected indicator** — when a tool is selected, briefly show the tool's name mid-screen (fade in, hold briefly, fade out). Quick affordance so the user knows what they just tapped.
- **Brush settings** — full pass needed on true hardware (sizes, hardness curves, pressure curves, spacing defaults). Today's prompt-side fixes don't cover on-iPad feel.

---

## AI feedback panel

- History panel goes off screen — needs a layout that fits the expanded panel and scrolls correctly on iPad.
- Should default to loading the **most recent** feedback when opened, not an empty state.

---

## Triage for TestFlight

**Must fix before ship:**
- Paint bucket outline + performance.
- Text breakpoint.
- Color picker / eyedropper.
- Circle/Rectangle rotation behavior.
- AI feedback history panel layout + default-most-recent.
- Image import tool.
- Selection delete ~10px jump.

**Should fix before ship (polish):**
- Tool-selected mid-screen indicator.
- Brush settings on-hardware tuning pass.
- Identify and fix/remove the "black triangle" tool.
- Brush stamp preview dots.

**Cut candidates (defer to v1.1 or remove):**
- Magic selection.
- Smudge tool.
- Clipboard button (verify purpose first).
