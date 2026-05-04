# Known Issues

Pre-TestFlight punch list of small issues discovered during development that aren't blockers. Triage before v1 ships; defer the rest.

---

## Drawing save-as vs save-overwrite (RESOLVED in this commit)

The Save-to-Gallery button used to unconditionally show the title-input alert on every tap, even for already-saved drawings. After saving once, subsequent taps re-prompted for a name — a re-prompt for a drawing that already had one, with the previously-entered title pre-filled. Users read this as "save as new" and either typed a different name (causing in-place rename via the existing update branch) or dismissed and retried, generally feeling like the save behavior was wrong.

**Fix:** the button now branches on `currentDrawingID`. Unsaved drawings (id is nil) still get the alert; saved drawings overwrite silently and show a transient "✓ Saved" confirmation on the button itself. No re-prompt, no chance for the title to drift, no rename surface attached to Save.

Files: `DrawEvolve/DrawEvolve/Views/DrawingCanvasView.swift`.

---

## Drawing rename via Save button

Currently no way to rename a saved drawing. Save = overwrite (correct), but no "Rename" affordance is surfaced anywhere. Considered: long-press or context menu on the drawing thumbnail in the Gallery, with a "Rename" action that updates `drawings.title`. Could also live in `DrawingDetailView` as a menu item.

Not blocking v1; users who care can delete + re-save with a new name today.

---

## Resolved

- ✅ **Silent no-op in `DrawingStorageManager.updateDrawing`** — `updateDrawing` now throws `DrawingStorageError.drawingNotFound` instead of silently returning when the id is missing from the in-memory `drawings` array. The existing caller in `DrawingCanvasView` already wraps the call in `do/catch`, so the error propagates and the false ✓ confirmation no longer fires on a dropped save.
- ✅ **iOS `DrawingContext.swift` skill-level default diverges from worker** — aligned all three iOS defaults (property declaration, init parameter, `decodeIfPresent` fallback) to `"Intermediate"` to match the Cloudflare Worker (`cloudflare-worker/index.js`).
