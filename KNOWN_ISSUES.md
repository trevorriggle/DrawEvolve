# Known Issues

Pre-TestFlight punch list of small issues discovered during development that aren't blockers. Triage before v1 ships; defer the rest.

---

## Drawing save-as vs save-overwrite (RESOLVED in this commit)

The Save-to-Gallery button used to unconditionally show the title-input alert on every tap, even for already-saved drawings. After saving once, subsequent taps re-prompted for a name — a re-prompt for a drawing that already had one, with the previously-entered title pre-filled. Users read this as "save as new" and either typed a different name (causing in-place rename via the existing update branch) or dismissed and retried, generally feeling like the save behavior was wrong.

**Fix:** the button now branches on `currentDrawingID`. Unsaved drawings (id is nil) still get the alert; saved drawings overwrite silently and show a transient "✓ Saved" confirmation on the button itself. No re-prompt, no chance for the title to drift, no rename surface attached to Save.

Files: `DrawEvolve/DrawEvolve/Views/DrawingCanvasView.swift`.

---

## Silent no-op in DrawingStorageManager.updateDrawing

At `DrawEvolve/DrawEvolve/Services/DrawingStorageManager.swift:342-345`, `updateDrawing` silently returns if the drawing isn't found in the in-memory `drawings` array. The array can be replaced wholesale by `fetchDrawings()` (`:215`: `drawings = decoded`) in narrow timing windows — for example: user saves → opens gallery → `fetchDrawings` runs before the in-flight cloud upload completes → the freshly-decoded array doesn't contain the new drawing → user returns to canvas → tries to save again → `updateDrawing` no-ops silently with no error surfaced.

Result from the user's POV: tap Save, nothing happens, no toast, no error. Pre-TestFlight polish, low frequency in normal usage.

Possible fixes (not done here):
- `updateDrawing` could fall back to re-inserting the drawing into the array from local cache (`writeMetadataToCache` / cache-on-disk) when not found in memory.
- Or surface an explicit error so the caller can decide.
- Or have `fetchDrawings` merge with pending-upload entries instead of replacing wholesale.

---

## Drawing rename via Save button

Currently no way to rename a saved drawing. Save = overwrite (correct), but no "Rename" affordance is surfaced anywhere. Considered: long-press or context menu on the drawing thumbnail in the Gallery, with a "Rename" action that updates `drawings.title`. Could also live in `DrawingDetailView` as a menu item.

Not blocking v1; users who care can delete + re-save with a new name today.

---

## iOS DrawingContext.swift skill-level default diverges from worker

`DrawEvolve/DrawEvolve/Models/DrawingContext.swift` defaults `skillLevel` to `"Beginner"` in three locations — line 12 (property declaration), line 25 (init parameter), line 51 (`decodeIfPresent` fallback). The Cloudflare Worker default is now `'Intermediate'` (`cloudflare-worker/index.js:131`).

Harmless in production: `PromptInputView.swift` is a segmented picker that always writes a value before submission, so the Worker's missing-value fallback is effectively never hit. But the defaults are divergent and a future caller that bypasses the picker (programmatic save, new screen, automation) would see different defaults on the two sides.

Fix when next in Xcode: align the iOS default to `"Intermediate"` in all three locations.

