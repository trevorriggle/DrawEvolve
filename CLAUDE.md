# CLAUDE.md — DrawEvolve

Onboarding doc for Claude (or any new contributor). Code-derivable facts are deliberately kept brief here — read the source. This file captures **what isn't obvious from reading the code**. Last full refresh: 2026-06-11.

---

## What DrawEvolve is

iOS drawing app — Universal target (iPad and iPhone), iPad-primary by design — with AI coaching. The user draws on a Metal-backed canvas, fills out a short questionnaire, and receives an iterative critique that **remembers prior critiques on the same drawing**. Around that core: per-critique canvas snapshots (version history + "Watch It Evolve" timelapse), critique pointers grounded on the drawing (ghost layer), Eve (a separate conversational coach), and a cross-drawing Evolution dashboard.

The "iterative coaching" behavior is the core product differentiator. Don't break it without reading `MEMORY.md` first.

---

## Repo layout (monorepo, three deployables)

```
DrawEvolve/                     ← iOS app (SwiftUI + Metal). Open DrawEvolve.xcodeproj here.
cloudflare-worker/              ← Cloudflare Worker. Sits between iOS and OpenAI.
                                  Owns: JWT validation, rate limiting/quotas, prompt assembly,
                                  OpenAI calls (critique + classifier + annotator + Eve),
                                  critique persistence, snapshot promotion.
supabase/                       ← Postgres migrations + Deno edge functions (account deletion).
                                  Migrations run via Supabase SQL Editor. 0001–0020 applied
                                  as of 2026-06-11 (0017 is an optional one-time purge).
docs/archive/                   ← Superseded plans/audits, kept for history. Don't trust
                                  their line numbers or status claims.
images/                         ← static assets / screenshots
```

The three pieces ship independently. iOS talks to Worker (HTTPS) and Supabase (auth + storage + Postgres). Worker talks to Supabase (service-role) and OpenAI. iOS never calls OpenAI directly.

### iOS app structure (`DrawEvolve/DrawEvolve/`)

```
DrawEvolveApp.swift          @main entry point + dbgLog() (debug-only logging shim)
Views/                       SwiftUI views; no business logic, calls into Services
Services/                    singletons: AuthManager, SupabaseManager, OpenAIManager,
                             DrawingStorageManager (class CloudDrawingStorageManager),
                             CanvasRenderer, HistoryManager, CrashReporter,
                             EventLogService, FeedbackService, ShapeClassifier
Models/                      Codable structs: Drawing, DrawingContext, DrawingLayer,
                             DrawingTool, CritiqueHistory (+ CritiqueAnnotation,
                             SnapshotPointer), FloatingText, TextSettings, TileGrid
ViewModels/                  CanvasStateManager (canvas state, undo/redo, transforms),
                             EveConversationManager, EvolutionViewModel
Config/                      Config.plist (public values only — committed)
Shaders.metal                Metal stamp/composite/wet-ink shaders
DrawEvolve.entitlements      Sign in with Apple + App Attest (environment: development —
                             flip to production with the App Attest re-enable)
```

---

## Tech stack

| Layer | Tech |
|---|---|
| iOS UI | SwiftUI, iOS 17+ deployment target, Universal device family (1,2) |
| Canvas | Metal + MetalKit (MTKView), tile-based (256² tiles), 2048² doc (4096² on iPad Pro), wet-ink stroke pipeline, **event-driven rendering** (see Gotchas #1) |
| Auth | Supabase Auth — Sign in with Apple + email magic-link OTP |
| Storage | Supabase Storage (private `drawings` bucket, public `avatars`) + local `Documents/DrawEvolveCache/` |
| DB | Supabase Postgres — drawings, feedback_requests, profiles, user_preferences, custom_prompts, user_palettes, conversations(+messages), feature_flags, user_event_log, feedback_submissions, account_deletions |
| Backend proxy | Cloudflare Worker (`drawevolve-backend.trevorriggle.workers.dev`) |
| AI | OpenAI `gpt-5.1` for critiques (+ Eve chat); `gpt-5-mini` for the tag classifier, the ghost-layer annotator, and Eve rolling summaries. **`gpt-5.1-mini` does not exist** — see Gotchas #6 for the reasoning_effort split. |
| iOS deps (SPM) | supabase-swift 2.34.0, swift-asn1, swift-crypto |
| Worker tests | Node `--test` (`cloudflare-worker/test.mjs`, 488 tests) |

No XCTest suite for the iOS app. Manual testing on device/simulator. Build verification: `xcodebuild` needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` on this machine.

---

## Build & run

### iOS app
```bash
cd DrawEvolve/
./setup.sh                       # copies Config.example.plist → Config.plist
open DrawEvolve.xcodeproj
# Edit Config/Config.plist with Supabase URL + anon key, then ⌘R
```
Single scheme: `DrawEvolve`. New Swift files need four pbxproj entries (PBXBuildFile, PBXFileReference, PBXGroup children, PBXSourcesBuildPhase — DE000NNN/DE100NNN id pattern; last used: 912).

### Cloudflare Worker
```bash
cd cloudflare-worker/
npm test                         # 488 tests, ~30s — run before every deploy
npx wrangler deploy              # auth via CLOUDFLARE_API_TOKEN env or wrangler login
# Required secrets (set once via `wrangler secret put`):
#   OPENAI_API_KEY, SUPABASE_URL, SUPABASE_JWT_ISSUER, SUPABASE_SERVICE_ROLE_KEY
```
KV namespace `QUOTA_KV` must exist; binding id is in `wrangler.toml`. See `cloudflare-worker/DEPLOYMENT.md`.

### Supabase migrations
Paste `supabase/migrations/000X_*.sql` into the Supabase SQL Editor and Run. Written to be idempotent. Numbering gap: 0007/0008 were reserved and never claimed — not missing.

---

## How a feedback request flows end-to-end

1. iOS user signs in (`AuthManager.swift`); Supabase issues an ES256 JWT.
2. User draws, taps "Get feedback". iOS uploads a pending snapshot bundle to storage in parallel and `POST`s to the Worker with `Authorization: Bearer <jwt>`, `drawingId`, JPEG-base64 image, and `client_request_id` (idempotency).
3. Worker: JWT → ownership check → rate/quota gates (KV) → gpt-5.1 critique call.
4. Worker then runs **in parallel**: the tag classifier and the ghost-layer annotator (both gpt-5-mini, both null-on-any-failure), promotes the pending snapshot bundle to `snapshots/<sequence>/`, and appends the entry (content + tags + annotations + snapshot pointer) to `drawings.critique_history` via the `append_critique` RPC. Logs a `feedback_requests` row.
5. iOS displays the critique; ghost markers render over the canvas (toggle chip); the snapshot powers version history and the timelapse.

**Worker is the sole writer of `critique_history`.** iOS reads it but never sends it in PATCH bodies — `DrawingUpsertPayload` deliberately omits the field. This is the lock against append races. (A DB-level trigger enforcing this is designed but not applied — see the 2026-06-11 ship audit.)

---

## Configuration & secrets

- `DrawEvolve/DrawEvolve/Config/Config.plist` — Supabase URL + anon key. Public values, **committed by design** (RLS-protected).
- Cloudflare Worker secrets — `wrangler secret put`, never committed.
- Supabase service role key — Worker only. Bypasses RLS. God-mode credential.

### App Attest is currently DISABLED end-to-end

Two coordinated kill-switches: iOS `AppAttestManager.isEnforcementEnabled = false` and Worker `APP_ATTEST_REQUIRED = "false"` (wrangler.toml). Per-user + global OpenAI spend caps plus JWT auth cover the threat model meanwhile.

Re-enable checklist: pin the real Apple App Attest root CA pubkey in `middleware/app-attest.js` (currently a placeholder), flip the entitlement environment to `production`, flip BOTH kill-switches (iOS first or both at once — Worker-required + iOS-off blocks all requests), `wrangler deploy`, ship a new iOS build, verify a clean register round-trip via `wrangler tail`.

---

## Conventions worth knowing

- **Postgres is snake_case; Swift models use CodingKeys.** New column = both sides change.
- **Storage paths:** legacy flat `<user_id>/<drawing_id>.jpg`; layered `<user>/<drawing>/{manifest.json,layer-N.png,composite.jpg,thumb.jpg}`; snapshots `<user>/<drawing>/snapshots/<sequence>/`. UUIDs lowercase everywhere.
- **State management:** `@MainActor ObservableObject` singletons (`AuthManager`, `CloudDrawingStorageManager`, `CanvasStateManager`) observed via `@EnvironmentObject` / `@ObservedObject`.
- **Local-first storage:** save to local cache + memory first, then queue cloud upload (NWPathMonitor retries). Save UI shows ✓ before cloud completes — by design.
- **Canvas transforms:** ALL presentation consumers (documentToScreen, screenToDocument wrappers, both Metal draw snapshots) read `CanvasStateManager.effectivePanOffset` — gesture pan plus the transient keyboard-avoidance pan. Gesture math reads/writes raw `panOffset`. Never mix them.
- **Metal stroke paths:** any code that async-commits a command buffer MUST hold a `strokeCommandSlots` semaphore slot (wait before makeCommandBuffer, signal on early exits + in the completed handler). The blur crash was a path that skipped this.
- **BrushUniforms:** trailing-append only (C-ABI prefix stability for shaders that don't read new fields). `strokeDir` landed in tail padding — stride is still 64 on both MSL and Swift sides; verify layout math before the next append.
- **Wet-ink deposit blends:** brush/marker/airbrush/watercolor use `.max/.max` (a stroke's cross-section = the stamp profile; pressure terms are per-stroke value CEILINGS that overlap can't rebuild — keep pressure tapers shallow). Pencil/charcoal use premul-over accumulation (shade by scribbling).
- **Logging:** diagnostic logging goes through `dbgLog()` (compiled out of Release). Don't add raw `print` to hot paths.
- **Worker prompt config:** voice presets + `selectConfig(tier, prefs)` live in `cloudflare-worker/lib/prompt.js` (modular worker — `index.js` is mostly routing + re-exports for tests). The iterative-coaching rule lives in `SHARED_SYSTEM_RULES` (system prompt), **not** user-role framing — see MEMORY.md for why.
- **Debug bypass:** AuthManager `isDebugBypassed` (synthetic user `DEADBEEF-…`), compiled out of Release.

---

## Other docs in this repo

| File | What's in it |
|---|---|
| `MEMORY.md` | Non-obvious decisions log, append-style. Read before touching coaching, prompts, storage formats. |
| `authandratelimitingandsecurity.md` | Auth + rate-limiting master plan (all phases shipped except the skipped legacy migration). App Attest re-enable runbook lives here. |
| `KNOWN_ISSUES.md` | Punch list. Empty as of 2026-06-11 — add new ones here, not in code comments. |
| `PERF_ISSUES.md` | Perf audit history. Authoritative status table at top (re-audited 2026-06-10/11). Remaining: paint-bucket before-snapshot, floodFillKernel rewrite. |
| `PIPELINE_FEATURES.md` | Long-term roadmap with status snapshot. Next major phase: monetization/tiers. |
| `cloudflare-worker/DEPLOYMENT.md` | Worker deploy runbook (secrets, KV, manual steps). |
| `RATELIMITSPLAN.md` | Credit-system / monetization design — NOT built yet; input for the tier sprint. |
| `ONLINEIMPLEMENTATIONPLANS.md` | Social Phases B–G design — deferred, not started. |
| `docs/archive/*` | SHIPPED or superseded plans/audits (April–May 2026): critique audit, both custom-prompts plans, layered-storage plan, the April 27th dev plan. Historical context only — stale line numbers, stale status claims. |

When the user asks about anything in those buckets, **read the doc** rather than guessing.

---

## Gotchas that have bitten before

1. **The canvas MTKView is event-driven — never set `isPaused = false`.** Both `enableSetNeedsDisplay = true` AND `isPaused = true` are required; with `isPaused = false` the display link free-runs draw() at 120 Hz on an idle canvas (the 2026-06 battery/thermal bug, shipped for weeks). If the canvas shows a stale frame after a state change, a field is missing from `CanvasRenderSnapshot` — add the field; don't un-pause. The foreground observer deliberately does NOT un-pause.
2. **`critique_history` is read-only from iOS.** Worker is sole writer. Sending it in PATCH bodies clobbers concurrent appends.
3. **Simulator HTTP/3 hang on Supabase.** `SupabaseManager` biases to HTTP/2 via an ephemeral URLSession (`httpMaximumConnectionsPerHost = 2`). Real devices don't hit this. Don't "clean up" that session config.
4. **Sign in with Apple entitlements** must stay in sync between `DrawEvolve.entitlements` and Xcode's Signing & Capabilities UI — removing one side = runtime crash on auth.
5. **Don't migrate or delete legacy `Documents/Drawings/*.json`.** Phase 4 work, deliberately deferred; deleting loses pre-auth drawings.
6. **reasoning_effort is FLAT on chat/completions and model-specific:** `gpt-5.1` takes `'none'|'low'|'medium'|'high'`; `gpt-5-mini` takes `'minimal'|'low'|'medium'|'high'` (`'none'` 400s on mini, `'minimal'` 400s on 5.1). The nested `reasoning: { effort }` shape belongs to /v1/responses and 400s on chat/completions. Also: gpt-5-series needs `max_completion_tokens` big enough for reasoning + output (300 starves it; use ~2000) and rejects `temperature`/`seed`.
7. **MTLCommandQueue caps in-flight buffers (~64).** That's what `strokeCommandSlots` (60) is for — see Conventions. Exceeding it traps the queue's dispatch thread (`com.Metal.CommandQueueDispatch` EXC_BREAKPOINT + libxpc "Malformed Mach message").
8. **Position-keyed vs profile-keyed shader effects under `.max` deposit:** layer-space modulation (streaks, grain) survives; per-stamp radial features (edge rims) wash out to the stroke cross-section. Design stamp profiles AS the desired stroke cross-section.

---

## Things to ask before doing

- Touching `AuthManager`, `SupabaseManager`, or `AppConfig` — auth is stable and verified.
- Touching the Metal pipeline / `CanvasRenderer` / `Shaders.metal` / brush code — release-blocker risk; changes here have shipped recently with verification debt, don't add more silently.
- Touching `Services/AnonymousUserManager.swift` — legacy but still imported by `CrashReporter`.
- Pushing to remote, force-pushing, or opening PRs — confirm first (standing exception: Trevor has been in explicit ship-everything mode; re-confirm if context is older than a few days).
- Committing anything that looks like a secret.

---

## Quick orientation for new tasks

- Auth flow bug → `Services/AuthManager.swift` + `authandratelimitingandsecurity.md`.
- Save/load bug → `Services/DrawingStorageManager.swift` (local-first + retry queue + layered manifest paths).
- Critique/AI bug → `cloudflare-worker/routes/feedback.js` + `lib/prompt.js`; iOS side `Services/OpenAIManager.swift`. `wrangler tail` for OpenAI errors (`[classifier]`, `[annotator]`, `[persistence]` prefixes).
- Eve bug → `routes/eve.js` + `lib/eve-prompt.js` / `eve-summary.js`; iOS `EveConversationManager` + `Views/Eve/`.
- Rendering/brush/canvas bug → `Views/MetalCanvasView.swift` + `Services/CanvasRenderer.swift` + `Shaders.metal`. Tread carefully.
- Text tool → `Views/Components/InlineTextEditorView.swift` (visible editor), `TextEntryOverlay.swift` (path text), `TypeBarView.swift` (keyboard accessory), `CanvasStateManager` FloatingText lifecycle.
- Ghost layer → worker `lib/annotations.js`; iOS `Views/GhostAnnotationOverlay.swift` + `CritiqueAnnotation` in `Models/CritiqueHistory.swift`.
- Version history / timelapse → `lib/snapshots.js` (worker), `SnapshotPointer`, `Views/EvolutionTimelapseView.swift`, `SnapshotCanvasOverlay.swift`.
- Quotas/tiers → `middleware/rate-limit.js` (TIER_LIMITS, KV key shapes) — daily windows only today; monthly windows are the first monetization build item.
- New Postgres column → migration in `supabase/migrations/` (next free: 0021), then `Models/Drawing.swift` + `DrawingUpsertPayload`.
- New voice preset / prompt change → `cloudflare-worker/lib/prompt.js`, then update `test.mjs`.
