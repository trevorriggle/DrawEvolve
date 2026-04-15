# Cut Tools To Reinstate Later

Tools removed from DrawEvolve on **2026-04-15** as part of the pre-TestFlight cleanup driven by `DrawEvolve Tool Audit - April 15, 2026.md`. They were broken, half-implemented, or unclear in purpose, and shipping them in v1 would have done more harm than good.

This file is the inventory of what was removed, why, and where to look in `git` history if/when reinstating. The deletion commit on `main` is the canonical reference — `git log --diff-filter=D --follow` and `git show <sha>` will surface the original implementations.

---

## Tools removed

### 1. Magic Wand (`DrawingTool.magicWand`)
- **Icon:** `wand.and.stars`
- **Why cut:** Doesn't work. Selection produced from flood-fill but boundary trace fell back to a bounding box rather than a real polygon outline, so the resulting selection didn't match what the user clicked.
- **What was removed:**
  - Enum case + icon/name in `Models/DrawingTool.swift`
  - Toolbar `ToolButton` in `Views/DrawingCanvasView.swift`
  - Touch handler in `Views/MetalCanvasView.swift` (was `touchesBegan` `if currentTool == .magicWand`)
  - Helpers `magicWandSelection(at:targetColor:tolerance:in:screenSize:)` and `traceBoundary(selectedPixels:width:height:)` in `Views/MetalCanvasView.swift`
- **To reinstate:** Replace the bounding-box fallback in `traceBoundary` with a real boundary tracer (e.g. Moore-neighbor or marching squares). Tolerance is hard-coded to `0.1` — expose as a setting.

### 2. Smudge (`DrawingTool.smudge`)
- **Icon:** `hand.draw.fill`
- **Why cut:** Never implemented. The handler was a stub comment saying "treat like a regular brush stroke but use special rendering" with no actual sampling/blending logic.
- **What was removed:**
  - Enum case + icon/name in `Models/DrawingTool.swift`
  - Toolbar `ToolButton` in `Views/DrawingCanvasView.swift`
  - Stub `if currentTool == .smudge` block in `Views/MetalCanvasView.swift`
- **To reinstate:** Needs a real implementation — sample pixels under the brush each frame, blend forward along the stroke direction, write back. New Metal compute kernel likely required. No prior code to recover.

### 3. Blur (`DrawingTool.blur`)
- **Icon:** `aqi.medium`
- **Why cut:** Marked X on the on-device tool audit screenshot. The compute shader works, but applying blur to the **entire layer** on a single tap (rather than locally under the brush) is not the intended UX, and there's no brush-style local application implemented.
- **What was removed:**
  - Enum case + icon/name in `Models/DrawingTool.swift`
  - Toolbar `ToolButton` in `Views/DrawingCanvasView.swift`
  - Touch handler in `Views/MetalCanvasView.swift`
  - `applyBlur(at:radius:to:screenSize:)` and the shared `applyEffect(...)` dispatcher in `Services/CanvasRenderer.swift`
  - `blurComputeState` pipeline + `blurKernel` shader load
  - `blurKernel` in `Shaders.metal` (box blur, 3x3-ish per radius)
- **To reinstate:** The box-blur kernel is fine for a starting point but should be local — restrict the dispatch to a brush-radius region around the tap, not the full texture. The `applyEffect` helper had the right shape but dispatched over the entire image. Consider a Gaussian or stacked box for better quality.

### 4. Sharpen / "Black triangle" (`DrawingTool.sharpen`)
- **Icon:** `triangle.fill` (this is the "black triangle" tool from the audit doc)
- **Why cut:** Same reason as Blur — applies to the entire layer rather than locally, and Trevor wasn't sure what the tool was supposed to do on-device.
- **What was removed:**
  - Enum case + icon/name in `Models/DrawingTool.swift`
  - Toolbar `ToolButton` in `Views/DrawingCanvasView.swift`
  - Touch handler in `Views/MetalCanvasView.swift`
  - `applySharpen(at:radius:to:screenSize:)` in `Services/CanvasRenderer.swift` (shared `applyEffect` was removed with Blur)
  - `sharpenComputeState` pipeline + `sharpenKernel` shader load
  - `sharpenKernel` in `Shaders.metal` (3x3 unsharp mask, `result = center * (1+8a) - sum * a`)
- **To reinstate:** Same notes as Blur — make it local to the brush, tune the amount via a setting, decide whether you want unsharp-mask vs. true high-pass sharpen.

### 5. Clone Stamp (`DrawingTool.cloneStamp`)
- **Icon:** `doc.on.doc.fill`
- **Why cut:** Toolbar button + enum case existed but no touch-handler dispatch was ever written. Pure dead UI.
- **What was removed:**
  - Enum case + icon/name in `Models/DrawingTool.swift`
  - Toolbar `ToolButton` in `Views/DrawingCanvasView.swift`
- **To reinstate:** Greenfield work. Needs source-point selection (alt-tap or similar), per-stroke sampling that tracks an offset from the source, and a brush-style stamping mode using sampled pixels as the brush color.

### 6. Polygon (`DrawingTool.polygon`)
- **Icon:** `pentagon`
- **Why cut:** Marked X on the on-device audit screenshot. The multi-tap-to-build-then-tap-near-first-point-to-close UX is not what users expect from a "polygon" tool, and the resulting strokes were rendered with the brush pipeline (so a polygon outline, not a polygon shape).
- **What was removed:**
  - Enum case + icon/name in `Models/DrawingTool.swift`
  - Toolbar `ToolButton` in `Views/DrawingCanvasView.swift`
  - Touch handler in `Views/MetalCanvasView.swift`
  - `polygonPoints: [CGPoint]` state and its reset in `touchesCancelled`
  - Helper `generatePolygonPoints(polygonPoints:pressure:timestamp:)`
- **To reinstate:** Decide first whether you want polygon-as-stroke (current) or polygon-as-shape (filled, like Rectangle/Circle). If shape, route through the same screen-space-to-doc-space mapping the rectangle/circle tools now use after the April 15 rotation fix.

---

## Audit items that turned out NOT to need code changes

### Clipboard button
- The audit doc lists "Clipboard button" as cut, but `grep -ri clipboard` across the codebase returned **no matches**. Either it was already removed in a prior commit, or it was labeled differently on-device than in code. No deletion was needed.

### Brush stamp preview / "brush dots"
- The only thing matching is the static `BrushPreview` in `Views/BrushSettingsView.swift` which renders a wavy line in the Settings panel using the current brush settings. There is no on-canvas brush-stamp overlay anywhere in the rendering code. The audit's verdict was "CUT (FOR NOW) if still broken after brush tuning pass" — conditional, and there's nothing to delete until the brush-settings hardware tuning pass happens. Left as-is.

---

## Files touched by this cleanup

- `DrawEvolve/DrawEvolve/Models/DrawingTool.swift`
- `DrawEvolve/DrawEvolve/Views/DrawingCanvasView.swift`
- `DrawEvolve/DrawEvolve/Views/MetalCanvasView.swift`
- `DrawEvolve/DrawEvolve/Services/CanvasRenderer.swift`
- `DrawEvolve/DrawEvolve/Shaders.metal`

If you want any of the original implementations back verbatim, they live in `git log` before the cleanup commit on `main` dated 2026-04-15.
