# DrawEvolve Revival — April 15, 2026

**Where we're at:** core canvas stable from yesterday's sprint. Today was AI prompt overhaul, selection tool rewrite, brush/render-pipeline fixes, and code cleanup — all in service of the June 1 TestFlight deadline.

---

## What shipped today

### AI feedback pipeline
- Replaced the thin "encouraging art teacher" prompt on the Cloudflare Worker with a structured, skill-calibrated prompt (Quick Take / What's Working / Focus Area / Try This / 💬) that references specific visual evidence and scales tone Beginner/Intermediate/Advanced.
- Added `skillLevel` end-to-end: `DrawingContext` model → segmented picker at the top of `PromptInputView` → JSON payload in `OpenAIManager` → worker destructures it → template branches on it.
- Worker now sends the prompt as a proper `role: system` message; user message is a short "Please critique this drawing." + image. `max_tokens` 800 → 1000.
- Worker deployed live via `wrangler deploy` (after API-token auth in codespace — browser OAuth doesn't work here).
- Feedback panel bumped ~25% bigger (`FloatingFeedbackPanel.expandedSize` 525×500 → 656×625).
- gpt-4o staying put for now. Estimated cost per critique ≈ $0.015 (1,200-token cap output dominates).

### Selection tools — major rewrite
Audit surfaced that past-Trevor had 90% of selection logic in place but three things were broken:

1. **Transform handles were cosmetic** — scale/rotation state updated on drag but the renderer never consumed it. Hid/removed them entirely (MVP ships without scale/rotate/magic-wand).
2. **Delete had no UI binding** — wired a floating red Delete button that appears whenever `activeSelection || selectionPath` is non-nil.
3. **Rectangle marquee completely broke under canvas rotation.** Stored selections as `min/max` of two doc-space touch points, which gave a doc-axis-aligned rect. Under rotation, the user's on-screen drag is a *rotated quad* in doc space, not axis-aligned — so marching ants, extracted pixels, and cleared pixels were three different regions.

**Fix:** marquee now stores the 4 screen-axis-aligned corners of the drag, each mapped through `screenToDocument`, as a 4-point polygon in `selectionPath` (not `activeSelection`). Routes through the existing lasso extract/clear/render code path. Marching ants via `documentPathToScreen` correctly draw a rotated quad under any rotation.

**Pixel-level bugs on extract/clear/render also fixed:**
- `Int(...)` truncation of sub-pixel coords in `clearRect` / `extractPixels` / `renderImage` → introduced `texturePixelRect` helper with `floor`/`ceil`/clamp. Guarantees identical integer rects across the three.
- Point-in-polygon in `clearPath` / `extractPixels(fromPath:)` tested pixel corners — changed to pixel **centers** `(px+0.5, py+0.5)` so edge pixels aren't shaved.
- `renderImage` did `context.draw(cgImage, in: CGRect(0,0,w,h))` which **resampled** when integer dims didn't match cgImage's intrinsic pixel dims → half-alpha edges that composited as white halos. Rewrote to blit the cgImage at its intrinsic pixel size with integer-floor offset, no resampling.
- Porter-Duff math in `renderImage` was straight-alpha but inputs are premultiplied BGRA → double-premul on edges shifted colors. Rewrote blend to premul-correct integer math, short-circuiting fully-transparent source pixels.

Residual: ~10px "jump up" on Delete that I couldn't pin down analytically. Deprioritized pending the next audit.

### Brush rendering

- **Preview vs committed size mismatch.** Preview rendered `settings.size * zoomScale` in drawable pixels; committed rendered `settings.size` texture pixels and was scaled to screen by the compositor. Ratio off by `drawable_fit_pixels / canvasSize.width`. Added a `drawableSize: CGSize` param to `renderStrokePreview` and scaled preview by the correct texture-to-screen ratio. First attempt used `view.bounds.size` (points) instead of `view.drawableSize` (pixels), which **inverted** the fix on iPad (ratio was 0.67× instead of 1.33×). Fixed on second pass.

- **Gray halos around strokes.** Double-premultiplied alpha. Brush pipeline (`.sourceAlpha / .oneMinusSourceAlpha`) stores premultiplied pixels in the canvas texture. The compositor pipelines (`textureDisplay` + `textureDisplayWithTransform`) were then using `.sourceAlpha` *again*, multiplying by alpha a second time and producing dark, desaturated edges that bled into the gray workbench. Changed both to `.one / .oneMinusSourceAlpha` on the source RGB+alpha.

- **Eraser preview.** Previously suppressed ("looks weird"). Now renders as a semi-transparent gray ghost trail via the brush pipeline (eraser pipeline would zero drawable alpha and destroy the composite). Actual erase-on-commit unchanged.

### Color picker
`AdvancedColorPicker.updateFromColor()` now inherits only hue from the current selection and forces saturation/brightness/opacity to 1.0 on open. Picker opens to a vivid color every time instead of carrying over muted state.

### Dead code cleanup (stage 1)
- Deleted `OpenAIManager.buildPrompt` (real prompt is on the worker).
- Deleted `FeedbackOverlay.swift` and `CritiqueHistoryView.swift` — files + 4 pbxproj refs each + dead `showHistory` state/sheet in `FloatingFeedbackPanel`. Edited the Xcode project file directly to avoid needing Xcode on the Mac.
- Deleted unused `SelectionTransformHandles` + `HandleView` structs.
- Updated `verify-project.sh` to stop checking the deleted file.

Stage 2 (shader/Metal dead code: `quadVertexShader`, `floodFillKernel`, unused pressure fields) held for after TestFlight.

---

## Status tracker

- [x] 1.1 Brush stroke offset/distortion
- [x] 1.2 Canvas zoom and pan
- [x] 1.3 Apple Pencil input for all tools
- [x] 1.4 Circle tool crash
- [x] 2.1 Redo
- [ ] 2.2 Gallery preview
- [ ] 2.3 Navigation state
- [~] 2.4 Selection tools — marquee + lasso + delete work; ~10px Y jump on delete unresolved; scale/rotate/magic-wand deferred to v1.1
- [x] 2.5 AI feedback display
- [x] 3.1 Pencil vs finger width
- [ ] 3.2 Launch time
- [ ] 3.3 Landing screen
- [x] 3.4 Brush thickens on release
- [ ] Canvas fill/clipping fix
- [ ] Reset transform button
- [ ] **TESTFLIGHT SUBMISSION (target: before June 1)**

---

## Open issues

**Low-res strokes / blocky edges.** Canvas texture is 2048×2048 but iPad Pro drawable is ~2732×2048 pixels → 1.33× upscale on display. `CanvasRenderer.updateCanvasSize(for:)` receives `view.bounds.size` (points), not drawable pixels. Fix is one line — pass drawable pixels → texture becomes 4096×4096 (next po2 above ~3416 diagonal). Costs: +48 MB per layer (320 MB at 5 layers), and `BrushSettings.size` is in doc pixels so defaults will render half as thick and need bumping. Held pending Trevor's audit.

**Selection delete jumps ~10px up.** Math traced through extract/clear/render three times, found no offset source. Could be antialiasing on `MarchingAntsPath`'s 2px stroke extending outside the polygon, creating a visual mismatch with the cleared pixels. Low priority.

**Selection under rotation for the marching ants preview.** `documentRectToScreen` returns the AABB of 4 rotated corners — larger than the actual quad. Now unused for selection (we use `documentPathToScreen` on the 4-point polygon), but left in place; callers outside selection haven't been audited.

---

## Next session candidates

- Trevor's upcoming tool audit (don't preempt it).
- Low-res texture bump (waiting on signoff).
- 2.2 Gallery preview verification on device (likely already done per CODEBASE_AUDIT).
- 2.3 Navigation state + 3.3 Landing screen.
- 3.2 Launch time — Instruments pass.
- TestFlight prep: icon assets, screenshots, App Store Connect record, signing certs.

---

## Ground rules holding

1. No scope creep past v1.0 minimum.
2. Every coordinate-pipeline change retested on physical iPad — `screenToDocument` / `documentToScreen` / shader `quadVertexShaderWithTransform` must stay in sync.
3. Dead code cleanup is polish, not critical path.

## Files touched today
- `cloudflare-worker/index.js` — new prompt, skillLevel destructure, system message, max_tokens 1000, deployed.
- `DrawEvolve/DrawEvolve/Models/DrawingContext.swift` — +skillLevel.
- `DrawEvolve/DrawEvolve/Views/PromptInputView.swift` — skill-level segmented picker.
- `DrawEvolve/DrawEvolve/Services/OpenAIManager.swift` — payload includes skillLevel; deleted `buildPrompt`.
- `DrawEvolve/DrawEvolve/Views/FloatingFeedbackPanel.swift` — +25% size; removed dead `showHistory` state/sheet.
- `DrawEvolve/DrawEvolve/Views/ColorPicker.swift` — max-defaults on open.
- `DrawEvolve/DrawEvolve/Views/DrawingCanvasView.swift` — Delete button; removed `SelectionTransformHandles` usage; closed preview subpath.
- `DrawEvolve/DrawEvolve/Views/MetalCanvasView.swift` — marquee polygon rewrite, eraser preview unexcluded, drawableSize passed through.
- `DrawEvolve/DrawEvolve/Views/SelectionOverlays.swift` — deleted dead transform-handle view structs.
- `DrawEvolve/DrawEvolve/Services/CanvasRenderer.swift` — `texturePixelRect` helper, `clearRect`/`clearPath`/`extractPixels` pixel-inclusive, `renderImage` no-resample + premul blend, compositor blend factors fixed, eraser preview color path, `renderStrokePreview` drawable-size param.
- `DrawEvolve/DrawEvolve/Views/FeedbackOverlay.swift` — deleted.
- `DrawEvolve/DrawEvolve/Views/CritiqueHistoryView.swift` — deleted.
- `DrawEvolve/DrawEvolve.xcodeproj/project.pbxproj` — removed refs to deleted files.
- `DrawEvolve/verify-project.sh` — updated.
