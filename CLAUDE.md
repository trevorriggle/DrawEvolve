# CLAUDE.md — DrawEvolve

Onboarding doc for Claude (or any new contributor). Code-derivable facts are deliberately kept brief here — read the source. This file captures **what isn't obvious from reading the code**.

---

## What DrawEvolve is

iOS drawing app (iPad-primary, iPhone-secondary) with AI feedback. The user draws on a Metal-backed canvas, fills out a short questionnaire (subject, style, skill level, focus areas), and receives an iterative GPT-4o Vision critique that **remembers prior critiques on the same drawing** and continues a coaching relationship rather than re-critiquing from scratch.

The "iterative coaching" behavior is the core product differentiator. Don't break it without reading `MEMORY.md` first.

---

## Repo layout (monorepo, three deployables)

```
DrawEvolve/                     ← iOS app (SwiftUI + Metal). Open DrawEvolve.xcodeproj here.
cloudflare-worker/              ← Cloudflare Worker. Sits between iOS and OpenAI.
                                  Owns: JWT validation, rate limiting, prompt assembly,
                                  OpenAI call, critique persistence.
supabase/                       ← Postgres migrations + Deno edge functions.
                                  Migrations run via Supabase SQL Editor.
images/                         ← static assets / screenshots
```

The three pieces ship independently. iOS app talks to Worker (HTTPS) and Supabase (auth + storage + Postgres). Worker talks to Supabase (service-role) and OpenAI. iOS never calls OpenAI directly.

### iOS app structure (`DrawEvolve/DrawEvolve/`)

```
DrawEvolveApp.swift          @main entry point
Views/                       SwiftUI views; no business logic, calls into Services
Services/                    singletons: AuthManager, SupabaseManager, OpenAIManager,
                             DrawingStorageManager (CloudDrawingStorageManager),
                             CanvasRenderer, HistoryManager, CrashReporter
Models/                      Codable structs: Drawing, DrawingContext, DrawingLayer,
                             DrawingTool, CritiqueHistory
ViewModels/                  CanvasStateManager (canvas tool state, undo/redo)
Config/                      Config.plist (public values only — committed)
Shaders.metal                Metal shaders for brush/eraser/fill
DrawEvolve.entitlements      Sign in with Apple capability
```

---

## Tech stack

| Layer | Tech |
|---|---|
| iOS UI | SwiftUI, iOS 15+ deployment target |
| Canvas | Metal + MetalKit (MTKView), 2048² texture (4096² on iPad Pro) |
| Auth | Supabase Auth — Sign in with Apple + email magic-link OTP |
| Storage | Supabase Storage (private `drawings` bucket) + local `Documents/DrawEvolveCache/` |
| DB | Supabase Postgres — tables: `drawings`, `feedback_requests`, `account_deletions` |
| Backend proxy | Cloudflare Worker (`drawevolve-backend.trevorriggle.workers.dev`) |
| AI | OpenAI GPT-4o Vision (gpt-5.1 was attempted, returned 400 — see MEMORY.md) |
| iOS deps (SPM) | supabase-swift 2.34.0, swift-asn1, swift-crypto |
| Worker tests | Node `--test` (`cloudflare-worker/test.mjs`) |

No XCTest suite for the iOS app. Manual testing on device/simulator.

---

## Build & run

### iOS app
```bash
cd DrawEvolve/
./setup.sh                       # copies Config.example.plist → Config.plist
open DrawEvolve.xcodeproj
# Edit Config/Config.plist with Supabase URL + anon key, then ⌘R
```
Single scheme: `DrawEvolve`.

### Cloudflare Worker
```bash
cd cloudflare-worker/
wrangler login
# Required secrets (set once via `wrangler secret put`):
#   OPENAI_API_KEY, SUPABASE_URL, SUPABASE_JWT_ISSUER, SUPABASE_SERVICE_ROLE_KEY
# Optional: ANOMALY_ALERT_WEBHOOK
wrangler deploy
npm test                         # run PromptConfig unit tests
```
KV namespace `QUOTA_KV` must exist; binding id is in `wrangler.toml`. See `cloudflare-worker/DEPLOYMENT.md`.

### Supabase migrations
Paste `supabase/migrations/000X_*.sql` into the Supabase SQL Editor and Run. Migrations are written to be idempotent.

---

## How auth + a feedback request flows end-to-end

1. iOS user signs in via Sign in with Apple or email OTP (`AuthManager.swift`).
2. Supabase issues an ES256-signed JWT; `AuthManager` publishes `signedIn(User)`.
3. User draws and taps "Get feedback". `OpenAIManager` sends `POST` to the Worker with `Authorization: Bearer <jwt>`, `drawingId`, JPEG-base64 image, and `client_request_id` (for idempotency).
4. Worker validates JWT against Supabase JWKS, checks drawing ownership, checks rate-limit/quota in KV, then calls OpenAI.
5. Worker writes the critique to `drawings.critique_history` via `append_critique(uuid, jsonb)` RPC and logs a `feedback_requests` row.
6. iOS displays the critique and refreshes the drawing on next hydrate.

**Worker is the sole writer of `critique_history`.** iOS reads it but never sends it in PATCH bodies — `DrawingUpsertPayload` deliberately omits the field. Don't change this; it's the lock against append races.

---

## Configuration & secrets

- `DrawEvolve/DrawEvolve/Config/Config.plist` — Supabase URL + anon key. Public values, **committed by design**. Anon key is RLS-protected.
- Cloudflare Worker secrets — set via `wrangler secret put`, never committed.
- Supabase service role key — Worker only. Bypasses RLS. Treat as god-mode credential.
- `Config.plist` is gitignored at the iOS subdirectory level but committed at root — this is intentional. Read `.gitignore` comments.

`AppConfig.swift` returns nil when keys still contain placeholder values, which surfaces as a "Couldn't configure Supabase" error rather than a crash.

---

## Conventions worth knowing

- **Postgres is snake_case; Swift models use CodingKeys to map to camelCase.** When adding a column, both sides must change.
- **Storage paths:** `<user_id>/<drawing_id>.jpg`, thumbnails get `_thumb.jpg`. UUIDs are normalized to lowercase on decode (`Drawing.swift` line ~54) — older local-cache files used uppercase.
- **State management:** Three `@MainActor ObservableObject` singletons drive most UI: `AuthManager`, `CloudDrawingStorageManager`, `CanvasStateManager`. Views observe them via `@EnvironmentObject` / `@ObservedObject`.
- **Local-first storage:** `DrawingStorageManager` saves to local cache + in-memory array first, then queues cloud upload. NWPathMonitor triggers retries. Save UI shows ✓ before cloud upload completes — this is by design but can mask delayed failures.
- **Worker prompt config:** `cloudflare-worker/index.js` has four hard-coded voice presets (`VOICE_STUDIO_MENTOR`, `VOICE_THE_CRIT`, `VOICE_FUNDAMENTALS_COACH`, `VOICE_RENAISSANCE_MASTER`) and a `selectConfig(tier, prefs)` function. The iterative-coaching rule lives in `SHARED_SYSTEM_RULES` (system prompt), **not** in the user-role framing — see MEMORY.md for why.
- **Debug bypass:** AuthManager has an `isDebugBypassed` path that skips Supabase entirely (synthetic user `DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF`). Cloud operations no-op for that user. Compiled-out of release.

---

## Other docs in this repo (read these instead of duplicating)

| File | What's in it |
|---|---|
| `MEMORY.md` | Non-obvious decisions log: iterative-coaching prompt placement, gpt-5.1 attempt rollback, where things live |
| `authandratelimitingandsecurity.md` | The auth + rate-limiting master plan, in 6 phases. Source of truth for what's landed vs. pending. iPad verification runbook. |
| `KNOWN_ISSUES.md` | Punch list of small bugs not blocking v1 (save-as UX, no-op updateDrawing, skillLevel default divergence, missing rename) |
| `PERF_ISSUES.md` | Perf audit dated 2026-04-30. Highest priorities: full-texture `getBytes` reads in `CanvasRenderer`, paint bucket / aggregate texture I/O |
| `CUSTOM_PROMPTS_PLAN.md` | Post-TestFlight design for per-drawing custom prompts. Not started. |
| `PIPELINE_FEATURES.md` | Feature roadmap. MVP+ done; Phase-1 analytics next; social phase not started. |
| `cloudflare-worker/DEPLOYMENT.md` | Worker deploy runbook (secrets, KV, manual steps) |
| `DrawEvolve, April 27th` | Older broad dev plan; mostly superseded but has device-targeting notes |

When the user asks about anything in those buckets, **read the doc** rather than guessing.

---

## Gotchas that have bitten before

1. **Simulator HTTP/3 hang on Supabase.** The iOS Simulator's QUIC upgrade causes `signInWithOTP` to hang. `SupabaseManager` builds an ephemeral URLSession with `httpMaximumConnectionsPerHost = 2` to bias toward HTTP/2. Real devices don't hit this. Don't "clean up" that session config.
2. **`critique_history` is read-only from iOS.** Worker is sole writer. If you start sending it in PATCH bodies you'll clobber concurrent appends.
3. **Sign in with Apple entitlements.** `DrawEvolve.entitlements` and the Xcode "Signing & Capabilities" UI must stay in sync. Removing in one place but not the other = runtime crash on auth attempt.
4. **`skillLevel` default divergence.** iOS defaults to `"Beginner"`, Worker fallback uses `"Intermediate"`. Harmless today (UI always sets a value) but a trap for future API consumers. See `KNOWN_ISSUES.md`.
5. **Don't migrate legacy `Documents/Drawings/*.json` yet.** That's Phase 4 work. Phase 3 ignores those files on purpose; deleting them now would lose pre-auth drawings.
6. **`CanvasRenderer.getBytes` reads the full 4096² texture in 7 places** even when the work region is small (~64MB per call). Logged in `PERF_ISSUES.md`. If you touch the renderer, fix this in passing only with sign-off — brush/canvas/Metal pipeline is TestFlight-blocker territory.
7. **gpt-5.1 doesn't accept the `reasoning` field** the way gpt-4o doesn't. The `OPENAI_REASONING_EFFORT = 'none'` constant is parked but **not wired into the request body**. If you swap to a reasoning-capable model, restore `reasoning: { effort: ... }` alongside the model swap. See MEMORY.md.

---

## Things to ask before doing

- Touching `AuthManager`, `SupabaseManager`, or `AppConfig` — Phase 1 is stable and verified.
- Touching the Metal pipeline / `CanvasRenderer` / `Shaders.metal` / brush code — TestFlight blocker risk.
- Touching `Services/AnonymousUserManager.swift` — legacy but still imported by `CrashReporter`. Don't delete without checking.
- Pushing to remote, force-pushing, or opening PRs — always confirm first.
- Committing anything that looks like a secret. The repo's `.gitignore` is comprehensive but not infallible.

---

## Quick orientation for new tasks

- Bug in auth flow → start in `Services/AuthManager.swift` + `authandratelimitingandsecurity.md`.
- Bug in saving/loading drawings → `Services/DrawingStorageManager.swift`. Local-first + retry queue.
- Bug in feedback / AI critique → `Services/OpenAIManager.swift` (iOS side) + `cloudflare-worker/index.js` (server side). Check `wrangler tail` for OpenAI errors.
- Bug in rendering / brush / canvas → `Views/MetalCanvasView.swift` + `Services/CanvasRenderer.swift` + `Shaders.metal`. Tread carefully.
- New Postgres column → migration in `supabase/migrations/`, then update `Models/Drawing.swift` + `DrawingUpsertPayload`.
- New voice preset / prompt change → `cloudflare-worker/index.js`, then update `cloudflare-worker/test.mjs`.
