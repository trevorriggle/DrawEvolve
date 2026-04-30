# Drawing Pipeline Performance Issues

Snapshot of the perf audit run on 2026-04-30 against `main`. Pick this up after TestFlight v1 ships.

Canvas texture is **4096² BGRA8** on iPad Pro per `CLAUDE.md`, so any full-texture buffer = **64 MiB**. Several issues compound at that resolution but were invisible at the smaller texture size the code was written against.

---

## High severity

| Tool / location | Description | Suggested fix |
|---|---|---|
| **Paint bucket** — `Services/CanvasRenderer.swift` (`floodFill`), called from `Views/MetalCanvasView.swift` paint-bucket branch | Originally synchronous on main thread from `touchesBegan`. Single tap = full-texture `getBytes` (64 MB read) + Swift stack-based flood fill with `Set<Int>` of visited pixels (up to 16.7M boxed `Int`s, hundreds of MB heap pressure + rehash storms) + full-texture `replace` (64 MB write) + 2 extra full-texture `captureSnapshot` round-trips for undo. UI hangs hundreds of ms to multi-seconds; possible memory-pressure terminations on large fills. | **Partially mitigated** in commit `8acafb0` (2026-04-30): fill loop moved to background queue, `Set<Int>` swapped for flat `[UInt8]` mask, HUD shown via `CanvasStateManager.isFilling`. Needs iPad retest. **Still open:** the two `captureSnapshot` calls (before/after) remain full-texture `getBytes` on main. **Long-term:** revive `Shaders.metal:408` `floodFillKernel` as a true compute-based connected-component fill to skip CPU entirely. The kernel as written is a color-replace, not a flood fill — needs algorithm rework, not a one-line wire-up. |
| **Aggregate `getBytes` pattern** — 7 call sites across `Services/CanvasRenderer.swift` (paint bucket, `clearRect`, `clearPath`, `extractPixels` rect, `extractPixels` path, `renderImage`, `captureSnapshot`) | Every site reads the **full texture** even when the work region is local (a 256² selection still triggers a 64 MB read). No batching, no shared `MTLBuffer` reuse. Hits in aggregate every time a selection commits, a layer is cleared, text is drawn, or undo snapshots. | Pass the work region into each call and use the existing `MTLRegion` parameter on `getBytes` to read only the bounding box. ~16× saving for a 1024² selection on a 4096² canvas. |

## Medium severity

| Tool / location | Description | Suggested fix |
|---|---|---|
| **Rectangle select / lasso commit** — `Services/CanvasRenderer.swift:1403` (`clearRect`), `:1465` (`clearPath`), `:1568` (`extractPixels`) | Drag preview is GPU and clean. **Commit** path does full-texture `getBytes` + CPU loop + full `replace`, plus `clearPath` runs per-pixel point-in-polygon over the full bounding box. Fires on release, not per-frame, so less acute than the bucket — but still a stutter on commit, and scales with canvas size not selection size. | Region-local `getBytes` (see High row above). Bonus: `clearPath`'s point-in-polygon test only needs to run inside the polygon's bounding box, which it already computes elsewhere. |
| **Text insertion** — `Services/CanvasRenderer.swift:1789` (`renderImage`) | Bypasses the GPU compositor. Does full-texture `getBytes` + per-pixel premultiplied Porter-Duff blending in Swift + full `replace`. The GPU equivalent (`compositeFloatingTextureIntoLayer` at `:604`) is already used by selection commit — text is the only caller still on the CPU path. | Route text through `compositeFloatingTextureIntoLayer` like selection commit does. The text rasterization → texture step stays the same; only the final blend moves to GPU. |
| **Per-frame command queue allocation** — `Views/MetalCanvasView.swift:243` (inside `draw(in:)`) | `device.makeCommandQueue()` is called **every frame**. `MTLCommandQueue` is meant to live for the device's lifetime. The renderer already has a long-lived `commandQueue` — the per-frame one is redundant. Hits every tool, every frame. | Reuse `renderer.commandQueue` instead of allocating a new one in `draw(in:)`. |

## Low severity

| Tool / location | Description | Suggested fix |
|---|---|---|
| **Brush / eraser** — `Services/CanvasRenderer.swift:233` (`renderStroke`), `:258` (eraser pipeline) | GPU point-sprite render pass per stamp — clean. Two minor concerns: (a) `commandBuffer.waitUntilCompleted()` at `:327` after every stroke commit serializes the GPU pipeline so the immediate `captureSnapshot` for undo is consistent. (b) 8+ `print` calls per stroke (`:234-240, 266, 279-286, 328`) — `print` is unbuffered and synchronous. | (a) Switch to a completion-handler-based snapshot so drawing keeps flowing. Needs the undo path to tolerate async snapshot capture — non-trivial. (b) Gate hot-path `print` behind `#if DEBUG`. |
| **Eyedropper** — `Views/MetalCanvasView.swift:1390, 1408-1416` | Composites layers (GPU, fine) then `getBytes` for **a full row** (`width × 1`, ~16 KB) when only 4 bytes are needed. | Pass an `MTLRegion` of `width: 1, height: 1` instead of the row. ~4 KB saving per pick — trivial in absolute terms, but a one-line change. |

## None / clean

| Tool | Notes |
|---|---|
| Line / rectangle / circle | CPU point generation then GPU `renderStroke`. Allocations are fine for normal stroke sizes. |
| Move | Drag is uniform-only (no per-frame pixel writes). Commit uses GPU `compositeFloatingTextureIntoLayer` or `translateLayerTextureInPlace`. Clean. |
| Rotate / scale | Deprecated, integrated into selection transform handles. Don't audit. |

---

## Cross-cutting hazards (not tied to a single tool)

1. **Per-frame `MTLCommandQueue` allocation** in `MetalCanvasView.draw(in:)` — see Medium row above.
2. **Aggregate `getBytes` everywhere** — see High row above.
3. **`print` in hot paths** — `renderStroke` emits 8+ lines per stroke; `floodFill` prints inside the work too. Cumulative cost is non-trivial during a sustained scribble. Wrap in `#if DEBUG`.
4. **`waitUntilCompleted` after every stroke commit** at `Services/CanvasRenderer.swift:327` — GPU pipeline stall. Needed for the immediate undo snapshot; a completion-handler-based snapshot would let drawing keep flowing.

---

## Suggested order if picking this up post-TestFlight

1. ~~Land the paint bucket fix~~ — landed in `8acafb0`. Verify on iPad before TestFlight.
2. Region-local `getBytes` for the four selection-commit paths (`clearRect`, `clearPath`, `extractPixels` rect/path) — moderate change, 16×-class wins for typical selection sizes.
3. Route text through `compositeFloatingTextureIntoLayer` — eliminates one of the seven full-texture loops.
4. Cache the command queue in `draw(in:)` — one-line change.
5. Gate `print` behind `#if DEBUG` in `renderStroke` and `floodFill`.
6. (Optional, larger effort) Rewrite `floodFillKernel` in `Shaders.metal` as a real connected-component fill compute shader and wire it up. Removes the CPU fill path entirely. Needs careful correctness retest on iPad.

---

*Source: drawing-tools audit run 2026-04-30 against `main`. See conversation history for the full evidence trail behind each finding.*
