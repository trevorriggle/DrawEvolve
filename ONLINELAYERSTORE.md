# Online Layer Store — preserving full layer data on save

Plan only. No implementation in this doc. Goal: make a saved DrawEvolve
drawing fully re-editable as a layered document, instead of collapsing
to a single flattened raster on every save.

---

## 1. Current state — exactly what happens today

### 1.1 The save call chain

1. `DrawingCanvasView.saveDrawing()` (`Views/DrawingCanvasView.swift:849`)
   - Calls `canvasState.exportImage()` which calls
     `CanvasRenderer.exportImage(layers:)` →
     `compositeLayersToImage(layers:)` →
     `compositeLayersToTexture(layers:)`
     (`Services/CanvasRenderer.swift:1582, 351, 362`).
   - That path renders **all visible layers** in order onto one fresh
     BGRA8 texture, then `textureToUIImage` reads it back to a `UIImage`.
   - Result is `image.pngData()` — a single flattened PNG.
2. The PNG `Data` is passed to
   `CloudDrawingStorageManager.saveDrawing(title:imageData:…)` /
   `updateDrawing(id:…, imageData:)`
   (`Services/DrawingStorageManager.swift:286, 330`).
3. `persistLocally(drawing:imageData:)` (line 543) re-encodes the PNG to
   JPEG **q=0.9** for the full image and a 256-pt JPEG **q=0.8**
   thumbnail. Writes:
   - `Documents/DrawEvolveCache/images/<id>.jpg`
   - `Documents/DrawEvolveCache/thumbnails/<id>.jpg`
   - `Documents/DrawEvolveCache/metadata/<id>.json`  (the `Drawing` struct)
   - `Documents/DrawEvolveCache/pending/<id>.json`   (upload queue entry)
4. `attemptUpload` (line 631) PUTs both JPEGs to the `drawings`
   Supabase Storage bucket at:
   - `<user_id>/<drawing_id>.jpg`
   - `<user_id>/<drawing_id>_thumb.jpg`
   Then upserts the row to `public.drawings` via `DrawingUpsertPayload`.

### 1.2 The schema & wire shape

`public.drawings` (migration `supabase/migrations/0001_init.sql`):

```
id uuid pk, user_id uuid, title text,
storage_path text,                       -- single path, single jpg
context jsonb, feedback text,
critique_history jsonb default '[]',
created_at timestamptz, updated_at timestamptz
```

`storage_path` is one string. There is no column, no second path, no
manifest pointer that would let us reference per-layer files.

### 1.3 The load chain

1. `DrawingCanvasView` (line 817) calls
   `storageManager.loadFullImage(for: drawing.id)`. That returns the
   single JPEG `Data`.
2. `UIImage(data:)` decodes it.
3. `canvasState.loadImage(uiImage)`
   (`ViewModels/CanvasStateManager.swift:380`) drops the pixels into
   **the currently selected layer's texture** via
   `renderer.loadImage(image, into: texture)`. There is no other layer.
   `addLayer()` is never called.

### 1.4 What is lost on every save

Per `Models/DrawingLayer.swift`, a `DrawingLayer` carries:

| Field         | Type              | Persisted today? |
|---------------|-------------------|------------------|
| `id`          | `UUID`            | No (regenerated each launch) |
| `name`        | `String`          | No |
| `opacity`     | `Float`           | No (already baked into composite) |
| `isVisible`   | `Bool`            | No (invisible layers dropped from composite) |
| `isLocked`    | `Bool`            | No |
| `blendMode`   | `BlendMode` (5 cases) | No (already baked) |
| `texture`     | `MTLTexture` (2048² BGRA8 premul) | Only as part of the composite |
| layer **order** | `[DrawingLayer]` index | No |
| layer **count** | — | No |
| alpha channel | per layer + composite | Lost twice — at composite, then at JPEG |

Also lost (related, deliberately scoped out below): `HistoryManager`
undo stack, current selection, zoom/pan/rotation, brush settings.

### 1.5 Why JPEG is in the chain at all

The file header on `DrawingStorageManager.swift` calls this out
explicitly: JPEG keeps Storage cost and signed-URL bandwidth bounded
for the AI-feedback flow, and a "PNG storage" follow-up was already on
file. JPEG also drops alpha entirely — even if we later wanted to
"recover layers from the flat" by some heuristic, the lost alpha would
already make every formerly-transparent pixel opaque white-ish.

---

## 2. Format options for serializing layered drawings

Three families. The recommendation is **(B) JSON manifest + per-layer PNG
blobs**, and the rest of this doc assumes that choice — but the
tradeoffs are spelled out so a future change is honest.

### A. Custom binary container

**Shape.** One file. Header (magic + version + counts), an offset table,
then concatenated payloads (layer pixel bytes, manifest JSON,
thumbnail). Like `.psd`, `.procreate`, `.kra`.

- ✓ Single object to upload/download — atomic, no partial-download
  inconsistency.
- ✓ Tightest on-disk size (one zip stream over everything).
- ✗ Forever-on-the-hook for our own format spec. Bumping to "v2" while
  v1 files exist on devices is the long-tail pain.
- ✗ Inspecting/debugging requires our own tooling. Today we can `curl`
  the JPEG and look at it.
- ✗ Doesn't compose with Supabase Storage's strengths (signed URLs,
  per-object cache headers, range requests for thumbnails).

### B. JSON manifest + per-layer blob (recommended)

**Shape.** Per drawing, an addressable group of objects:

```
manifest.json     ← layer order, names, opacity, blend modes, doc size
layer-<n>.png     ← lossless RGBA per layer (n = 0..N-1)
thumb.jpg         ← 256 px gallery thumbnail (unchanged)
composite.jpg     ← optional: flattened JPEG (for AI feedback / legacy)
```

- ✓ Human-inspectable. A failed decode is `cat manifest.json` away from
  diagnosis.
- ✓ Per-layer downloads — gallery only needs `thumb.jpg`, the editor
  only fetches layers when opened.
- ✓ Composes with what already exists: `thumb.jpg` keeps its current
  path so existing local thumbnail caches stay valid; `composite.jpg`
  keeps the AI-feedback / Worker contract unchanged.
- ✓ Re-uses `CanvasRenderer.makeTexture(from:)`
  (`Services/CanvasRenderer.swift:752`) — already converts UIImage →
  MTLTexture in the right format for layer textures.
- ✗ More objects per save — N+2 PUTs instead of 2. Mitigated by upload
  in parallel and by the fire-and-forget pending queue that already
  exists.
- ✗ Partial-failure window: 4 of 5 layers uploaded means a half-
  reconstructable drawing. Handled by the manifest being uploaded
  **last** (see §5.4).

### C. Native multi-image formats

| Format | Verdict |
|--------|---------|
| **OpenRaster (`.ora`)** | Closest to what we want — zip of `mimetype` + `stack.xml` + `data/layer*.png`. Open spec, GIMP/Krita interop. The downside vs. (B) is we'd be choosing it for "a standard" rather than for any DrawEvolve-specific reason; we don't currently export to GIMP. Worth keeping in our back pocket as the wire format inside (A) if we ever switch — its `stack.xml` blend modes ≈ ours. |
| **`.psd`** | Layer-aware, universal, but writing it correctly from Swift means pulling in a third-party library (no first-party Apple writer). Read parity with Photoshop blend modes is a research project. Not worth it for our use case. |
| **Multi-image TIFF** | Apple-native (ImageIO), but TIFF "pages" don't model blend modes / opacity / visibility — we'd still need a sidecar manifest, which is back to (B). |
| **APNG / animated PNG** | Frames, not layers. Wrong abstraction. |

### Why (B) wins for us

- Lowest "what could go wrong" surface area: the only new code is a
  manifest schema and a parallel upload, both small.
- Keeps the existing flat `composite.jpg` so we don't have to touch the
  Worker / OpenAI image-feedback flow at the same time.
- Lets us ship the layer-store feature without breaking the gallery,
  which only needs `thumb.jpg`.

---

## 3. Manifest schema (proposed)

`manifest.json` (one per drawing). Versioned from day one.

```jsonc
{
  "format_version": 1,                  // bump on incompatible changes
  "drawing_id": "uuid-lowercase",
  "document": {
    "width":  2048,                     // pixels; matches MTLTexture.width
    "height": 2048,
    "color_space": "srgb",
    "pixel_format": "rgba8_premultiplied"
  },
  "layers": [
    {
      "ordinal": 0,                     // bottom-up; renderer iterates in order
      "id": "uuid-stable-across-saves", // see §3.1
      "name": "Layer 1",
      "opacity": 1.0,
      "visible": true,
      "locked": false,
      "blend_mode": "normal",           // one of BlendMode.rawValue
      "asset": "layer-0.png",           // sibling object key
      "asset_sha256": "hex…",           // integrity check on download
      "bbox": { "x": 124, "y": 88, "w": 1620, "h": 1432 }  // optional, see §6
    }
    // … up to free=2 / premium=∞ layers per the tier model in PIPELINE_FEATURES.md
  ],
  "thumbnail": "thumb.jpg",
  "composite": "composite.jpg"          // present iff saved (see §5.5)
}
```

### 3.1 Stable layer IDs

`DrawingLayer.id` is `let id = UUID()` regenerated at init time. For the
manifest to round-trip cleanly (so the next save reuses the same
`layer-<n>.png` paths and so undo/redo across sessions is even thinkable
later), each layer needs a **persistent** id. The minimal change:

- Stop generating `id` at init; require it as a constructor argument
  with a `UUID()` default for in-session new layers.
- On load, instantiate each layer with the manifest id.
- The manifest writes that id; the storage path uses the **ordinal**,
  not the id, so reordering doesn't move bytes around in Storage.

This is the only model change required for v1.

---

## 4. Local storage structure on device

Today: flat per-drawing files under `Documents/DrawEvolveCache/`.

Proposed: keep existing top-level layout, add a per-drawing
**directory** for layered drawings.

```
Documents/DrawEvolveCache/
├── metadata/
│   └── <drawing_id>.json              # unchanged: serialized Drawing struct
├── thumbnails/
│   └── <drawing_id>.jpg               # unchanged: gallery cells
├── images/
│   └── <drawing_id>.jpg               # legacy flat — read-only after migration
├── layers/                            # NEW
│   └── <drawing_id>/
│       ├── manifest.json
│       ├── layer-0.png
│       ├── layer-1.png
│       └── composite.jpg              # optional cache of the flat
└── pending/
    └── <drawing_id>.json              # unchanged structurally, see §5.4
```

Notes:

- `thumbnails/<id>.jpg` stays at the same path. Gallery code does not
  change.
- `images/<id>.jpg` is read iff `layers/<id>/manifest.json` is absent
  (i.e. legacy drawing). Once a legacy drawing is opened-and-resaved
  in layered form, the legacy `images/<id>.jpg` is **deleted on
  successful upload** of the layered set.
- Per-drawing layer directory means a single `removeItem` call cleans
  everything up on delete. `removeLocalArtifacts(forDrawingID:)`
  (line 571) just needs an additional `try?
  fileManager.removeItem(at: layersDir.appendingPathComponent(idStr))`.

### 4.1 Disk size envelope (rough)

A 2048×2048 BGRA8 layer in memory is **16 MiB**. Lossless PNG of typical
sketch content (lots of transparent space, ink lines) tends to land at
**0.2–3 MiB** per layer; a fully-painted layer can hit **5–8 MiB**.

For a 5-layer drawing that's roughly **1–25 MiB on disk** vs. today's
~300 KiB JPEG. Free-tier cap of 2 layers (per PIPELINE_FEATURES.md) ≈
**0.5–6 MiB**.

Acceptable on-device. Cloud-side cost is the bigger conversation — see §6.

---

## 5. Cloud storage structure on Supabase

### 5.1 Storage layout

Bucket stays `drawings`. Per-drawing key prefix:

```
<user_id>/<drawing_id>/
├── manifest.json
├── layer-0.png
├── layer-1.png
├── …
├── thumb.jpg                          # was <user_id>/<drawing_id>_thumb.jpg
└── composite.jpg                      # was <user_id>/<drawing_id>.jpg
```

This is a **path change**. The first-segment (`<user_id>/`) RLS check
in `0001_init.sql` still passes — `storage.foldername(name)[1]` returns
the user id either way. Existing legacy objects at the old paths
continue to work; new saves write to the new layout.

### 5.2 Schema change

`public.drawings` needs a column to point at the manifest. Two options
considered, recommendation in bold:

- ~~Repurpose `storage_path`~~ — would break legacy reads mid-flight.
- **Add `manifest_path text` (nullable). `storage_path` stays nullable
  for legacy + composite back-compat. A drawing is "layered" iff
  `manifest_path is not null`.**

Optionally also add (small, cheap, useful):

- `format_version int` — quick filter without touching Storage.
- `layer_count int` — gallery can show "5 layers" without fetching the
  manifest.
- `total_bytes bigint` — for tier-quota enforcement later.

Migration sketch (not run):

```sql
-- supabase/migrations/0007_layered_drawings.sql
alter table public.drawings
    add column if not exists manifest_path text,
    add column if not exists format_version int,
    add column if not exists layer_count int,
    add column if not exists total_bytes bigint;

-- storage_path becomes nullable (was not null in 0001_init.sql).
-- Legacy rows keep storage_path; new layered rows leave it null and set manifest_path.
alter table public.drawings
    alter column storage_path drop not null;

-- A row must point at *something* viewable.
alter table public.drawings
    add constraint drawings_path_present
    check (storage_path is not null or manifest_path is not null);
```

RLS policies need no changes — they're per-row on `user_id`.

### 5.3 Object metadata

Tag each uploaded object with `Cache-Control: private, max-age=31536000`
and the right `Content-Type` (`image/png`, `application/json`,
`image/jpeg`). Not strictly required for correctness but worth setting
in the same code change since the upload path is being touched anyway.

### 5.4 Upload ordering & atomicity

The pending queue today is "one entry per drawing, retry whole upload."
Layered upload needs to be more careful or we'll publish manifests
that point at layers the cloud doesn't have yet.

Order:
1. Upload all `layer-*.png` in parallel.
2. Upload `composite.jpg` and `thumb.jpg` in parallel.
3. **Last**: upload `manifest.json`.
4. Last: upsert the row to `public.drawings` with `manifest_path` set.

Loaders (§6) treat the absence of `manifest.json` as "not a layered
drawing" and fall through to legacy read. So a drawing whose layers
finished uploading but whose manifest didn't is invisible as layered;
it's visible as legacy iff `composite.jpg` made it. The pending entry
needs to hold enough state to resume from the right step:

```jsonc
{
  "drawing_id": "…",
  "user_id":   "…",
  "uploaded_layers": [0, 1],          // ordinals already uploaded
  "uploaded_composite": false,
  "uploaded_thumb": true,
  "uploaded_manifest": false,
  "row_upserted": false,
  "attempt_count": 2,
  "last_attempt_at": "…"
}
```

Each retry resumes from the first false step — no re-uploading bytes
that already made it.

### 5.5 Composite — keep or drop?

Keep, with caveats. Reasons:

- **AI feedback** (`OpenAIManager.requestFeedback`) currently sends a
  flat image. The Worker's prompt contract assumes one image per
  request. Punting "send layers to the model" is the right scope for
  this change.
- **Sharing/export** flows that aren't yet built but are coming
  (`PIPELINE_FEATURES.md`) need the flat anyway.

Caveat: regenerating the composite on every save costs one extra GPU
pass + one extra JPEG encode + one extra upload. The composite should
be derivable from the layers, so it's a cache, not a source of truth.
Treat divergence as "layers win, composite stale" if it ever happens.

---

## 6. Loading — reconstructing layered state

### 6.1 New entry point on the storage manager

```swift
func loadLayeredDrawing(for id: UUID) async throws -> LayeredDrawingPayload?
```

Returns nil for a legacy drawing (caller falls back to
`loadFullImage`). On success, the payload carries the parsed manifest
plus per-layer `Data` (PNG bytes), all from disk cache → signed-URL
download, mirroring `loadFullImage`'s two-tier strategy.

### 6.2 Reconstruction in `CanvasStateManager`

New method, parallel to `loadImage(_ image: UIImage)` (line 380):

```swift
func loadLayered(_ payload: LayeredDrawingPayload)
```

Steps:

1. `clearCanvas()`-equivalent that doesn't auto-add the default layer.
2. For each manifest entry in `ordinal` order:
   - Construct `DrawingLayer(id: manifest.id, name: …, opacity: …,
     isVisible: …, isLocked: …, blendMode: …)`.
   - `renderer.makeTexture(from: UIImage(data: layerPNG))` — already
     exists at `CanvasRenderer.swift:752` and produces the right
     premultiplied BGRA8 format.
   - Append to `layers`.
3. Set `selectedLayerIndex = layers.count - 1` (top layer).
4. `hasLoadedExistingImage = true`.
5. `historyManager.clear()` — saved files don't carry undo stacks (out
   of scope for v1).

### 6.3 Sanity checks at load

- Manifest version > supported → present a "this drawing was saved by
  a newer build, please update" surface; do **not** silently truncate
  to a single layer.
- Per-layer `asset_sha256` mismatch → discard that layer's bytes,
  insert an empty layer at the right ordinal so the rest of the stack
  doesn't collapse, and surface a non-fatal warning.
- Document `width/height` mismatch with current `documentSize` →
  legitimate situation if `documentSize` changed across builds. Either
  resample (lossy) or pad/crop. Lean toward "open at the saved size,
  show a one-time toast" so the user's pixels aren't silently
  disturbed.

### 6.4 Tier enforcement on load

A premium user with 8 layers downgrades to free (2-layer cap). On
load, do **not** drop layers — read-only is fine, and the user can
delete layers themselves to bring it under cap before further edits.
Block the save button while over cap.

---

## 7. File size & compression

### 7.1 Per-layer compression

PNG is already deflate-compressed. No extra work needed for
correctness. Two optimizations worth keeping in mind but not blocking:

- **Tight bbox.** Compute the bounding box of non-transparent pixels
  per layer; save only that crop, plus the `bbox` field in the
  manifest so we know where to paste it back. A mostly-empty layer
  (common with sketch sandwiches) goes from ~16 MiB raw to ~10 KiB
  PNG. Worth it for free-tier disk/bandwidth math.
- **Quantization.** 8-bit indexed PNG for layers with ≤ 256 colors
  (lineart). Big win for ink layers, no value for blended paint.
  Defer.

### 7.2 Manifest compression

Manifest is small (< 4 KiB even with 50 layers). Don't bother.

### 7.3 Composite compression

Unchanged: JPEG q=0.9. Keep.

### 7.4 Thumbnail compression

Unchanged: JPEG q=0.8 at 256 px. Keep.

### 7.5 Bandwidth envelope

A 5-layer save:

| Object        | Today      | Layered    |
|---------------|------------|------------|
| Composite     | ~250 KiB   | ~250 KiB   |
| Thumbnail     | ~25 KiB    | ~25 KiB    |
| Layers (PNG)  | —          | ~1–8 MiB   |
| Manifest      | —          | < 4 KiB    |
| **Total**     | ~275 KiB   | ~1.3–8.3 MiB |

Order-of-magnitude bigger. Consequences:

- Free-tier Supabase bandwidth budget needs a re-look against expected
  save frequency. (Not a blocker, but a number to put in front of
  ourselves before turning this on for everyone.)
- The fire-and-forget upload model is still right — what changes is
  that "fire" is now N PUTs instead of 2.

### 7.6 Layer cap

PIPELINE_FEATURES.md sets free=2, premium=unlimited. Enforce that on
the **save** path (manifest validation), not the upload path — the
client should never produce a manifest that violates its own cap.

---

## 8. Migration path from existing flattened saves

Three classes of existing drawing:

1. **In Supabase + locally cached.** Most users.
2. **In Supabase only.** Cleared local cache.
3. **Locally only.** Bypass-mode drawings, or pending entries that
   never made it to the cloud.

### 8.1 Read

All three: keep working unchanged. Loader checks for
`manifest_path is not null` (or `manifest.json` in the per-drawing
directory locally); if absent, falls through to today's
`loadFullImage` path → `canvasState.loadImage(uiImage)` → single
layer. Identical to current behavior.

### 8.2 Re-saving a legacy drawing

When the user **edits and saves** a legacy drawing:

- The save code unconditionally writes the new layered format.
- `manifest_path` is set on the existing row; `storage_path` (legacy
  composite) is **rewritten** to point at the new
  `<user_id>/<drawing_id>/composite.jpg`.
- After the cloud write succeeds, delete the old legacy objects at
  `<user_id>/<drawing_id>.jpg` and `<user_id>/<drawing_id>_thumb.jpg`
  (best-effort, same pattern as `deleteDrawing`).
- Locally, delete `images/<id>.jpg` (legacy flat). Keep
  `thumbnails/<id>.jpg` if its path is unchanged; otherwise rewrite.

### 8.3 Bulk migration?

Not needed. Drawings auto-upgrade on next save. Anything never edited
again stays legacy forever, which is fine — read works.

If we later want to backfill (e.g., for a "convert all my old sketches
into layered docs" UX): a one-shot job per user that reads each legacy
JPEG, instantiates a single-layer drawing with `name: "Background",
locked: true`, and re-saves. No magic. No automatic call — explicit
user action only.

### 8.4 Format-version forward compat

`format_version: 1` for everything written by this change. Bumping it
means we wrote something a previous build can't safely consume. Older
clients read the version, see it's higher than they support, and show
the "please update" surface from §6.3 instead of trying.

---

## 9. Cross-device sync implications

### 9.1 Last-write-wins is unchanged, but the blast radius is bigger

Today: two devices saving the same drawing race on one JPEG. Worst
case: device A's pixels get clobbered by device B's. One file lost.

Layered: two devices saving race on N+2 files. Worst case: half of
A's layers, half of B's layers, A's manifest pointing at B's layer
files. Inconsistent state.

Mitigation for v1: **don't try to merge.** Same last-write-wins, but:

- Manifest uploaded **last** (per §5.4) → as long as both devices
  finish their layer uploads before either uploads its manifest, the
  loser's layer files are orphans (storage waste, not corruption) and
  the winner's drawing loads correctly.
- Add an `etag` or `version` integer to the row. Client reads it on
  load; on save, conditional upsert (`update … where version = N`).
  Conflict → surface "this drawing was edited on another device,
  reload?" UX. **This is the v1 conflict story.** No silent
  overwrites.

### 9.2 Cache invalidation

A device that hydrated layered drawing X with manifest version 7,
then sees `updated_at` change in a fetched row, **must invalidate the
local layer cache for X**. Today's loader doesn't have that concern
— overwriting one JPEG is naturally idempotent. Layered case needs
the manifest's `asset_sha256` to be the cache key for layer files,
not the bare `layer-N.png` filename.

Concretely: store layer PNGs locally as
`layers/<drawing_id>/<sha256>.png` and have the manifest reference
them by hash. A cache miss is "we don't have this hash yet"; a stale
cache simply isn't referenced anymore (sweep on next launch).

### 9.3 Partial download for the gallery

Gallery is unchanged: it only ever reads `thumb.jpg`. Even on a 50-
drawing gallery the layer files are not touched. This is the main
reason layered storage is OK at all — we're not regressing the
common-case bandwidth.

### 9.4 Worker / AI-feedback sync

Out of scope for this change. The Worker keeps reading the flat
composite via `composite.jpg` (or the legacy `<id>.jpg` for
unmigrated drawings). When/if we want the model to see layers
separately, that's a separate prompt-design conversation, not a
storage change.

---

## 10. What this plan deliberately does NOT cover

- **Layer-aware AI feedback.** Worker prompt + image-payload changes.
- **Stroke / vector storage.** Saving the user's actual brush events
  so undo crosses sessions. Different problem class, different doc.
- **Real-time multi-device collaboration.** v1 conflict story is
  detect + ask, not merge.
- **Layer groups / folders.** PIPELINE_FEATURES.md doesn't list them
  yet; manifest schema is forward-compatible (add a `parent_ordinal`
  field at version 2).
- **Adjustment layers / masks.** Same story.
- **PSD import/export.** Belongs in a separate "interop" effort if it
  ever ships.

---

## 11. Open questions to resolve before implementing

1. **Layer-cap enforcement UX.** When a free-tier user opens a
   premium-tier drawing with 8 layers, what does the save button
   show? "Upgrade" vs. "delete layers"? (Product call.)
2. **Document size resampling.** If a user opens an old drawing
   saved at 2048² on a build with `documentSize` = 4096²: pad,
   resample, or refuse? (Lean: open at saved size, no auto-rescale.)
3. **Bbox crop now or later?** §7.1 — the size win is real, but it
   adds a "compute bounding box of transparent pixels" pass per
   layer per save. Probably defer to v1.1.
4. **Composite still required at all?** Worth a fresh look at how
   often the AI-feedback flow actually fires vs. how often a save
   happens. If feedback is < 5% of saves, generate the composite
   on-demand (lazy upload) instead of every time.
5. **Migration column names.** Bikeshed `manifest_path` vs.
   `layered_root` vs. just adding a `format` enum column.
