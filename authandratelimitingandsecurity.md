# Auth, Rate Limiting & Security Plan

Working checklist for the foundational plumbing pass. Tick items as they land.

Last updated: 2026-04-29

---

## CURRENT STATE — RESUME HERE

A future helper or future-me should read this section first; everything below is the longer paper trail.

### One-paragraph summary

Phases 1 (auth gate), 2 (schema + RLS), and **3 (cloud sync, local-first)** are code-complete. Phase 3 landed 2026-04-29: `DrawingStorageManager` was rewritten in place as `CloudDrawingStorageManager`, the `Drawing` model dropped its inline `imageData` in favor of `storage_path`, and the gallery / detail / canvas views now read images via the manager's thumbnail + signed-URL accessors. Save flow is local-first with a disk-backed pending-upload queue retried on `NWPathMonitor` reachability events. Phase 3 is **not yet iPad-verified**; Trevor needs to do an end-to-end test (sign in → save a drawing → verify it appears in the Supabase Storage bucket + `drawings` table → cold-launch → verify gallery hydrates from cloud). Existing local-only drawings under `Documents/Drawings/*.json` are untouched and still invisible to the new code; Phase 4 picks them up.

### Status by phase

| Phase | Status | Notes |
|---|---|---|
| **Phase 0** — portal/dashboard work | ⏳ partial | Supabase project created (`jkjfcjptzvieaonrmkzd`), URL + anon key in `Config.plist` (committed). Apple Developer + OpenAI cap + Slack webhook + KV namespace pending. |
| **Phase 1** — iOS auth foundation | ✅ code complete & pushed | Awaits iPad render verification + Supabase dashboard config (Email provider, redirect URL) for magic link to work. Apple Sign In awaits Apple Developer approval. |
| **Phase 2** — Postgres schema + RLS + Storage | ✅ applied 2026-04-28 | `supabase/migrations/0001_init.sql` ran clean in the SQL Editor. `drawings` + `feedback_requests` tables, all RLS policies, the `drawings` storage bucket, the `set_default_tier_on_signup` trigger, and the backfill are live in project `jkjfcjptzvieaonrmkzd`. |
| **Phase 3** — cloud sync (local-first) | 🟡 code complete 2026-04-29 | `CloudDrawingStorageManager` + new `Drawing` model + view updates landed. Saves write to local cache + queue cloud upload; gallery hydrates from `drawings` table; full images load via signed URL (1h TTL). Pending uploads retry via `NWPathMonitor`. **Awaits iPad end-to-end verify.** |
| **Phase 4** — existing-drawing migration on first signin | ☐ not started | Re-stamps anonymous-tagged local drawings with the auth user ID, batch-uploads to cloud. **Carryover from Phase 3:** also responsible for cleaning up `Documents/Drawings/*.json` after migration, and for evicting any `Documents/DrawEvolveCache/{metadata,thumbnails,images}/` files belonging to a `user_id` that no longer matches the signed-in user (the Phase 3 manager filters them out at hydrate time but doesn't delete). |
| **Phase 5a + 5b** — Worker JWT gate + request validation | ✅ code complete & verified end-to-end 2026-04-29 | ES256/JWKS verification (Supabase asymmetric signing — confirmed live at `.well-known/jwks.json`); 10-min JWKS cache with kid-rotation refetch; per-request validation (drawing_id ownership, 8MB image cap, JPEG/PNG magic-byte check, context shape). Real `getUserTier` + `fetchCritiqueHistory` replace the Phase 1 stubs. iOS `OpenAIManager` now attaches `Authorization: Bearer` and sends `drawingId`. |
| **Phase 5c** — rate limits + cost ceilings | 🟡 code complete 2026-04-29 | `TIER_LIMITS` (free: 5/min · 20/day; pro: 15/min · 200/day) + per-IP backstop (100/hr) + per-user 5×-quota anomaly counter. KV-backed: `quota:<uid>:<utc-day>`, `rate:<uid>` (rolling 60s window), `ip:<sha256(ip)>:<utc-hour>`, `hourly:<uid>:<utc-hour>`. Daily counter increments AFTER successful OpenAI delivery so failed requests don't burn quota; per-minute + per-IP record the *attempt* so concurrent bursts can't slip past the gate. 429 body `{ error, scope, tier, limit, used, retryAfter, message }` with tier-aware human-readable `message`. Anomaly secret named `ANOMALY_ALERT_WEBHOOK` (renamed from `ABUSE_ALERT_WEBHOOK` in earlier draft); falls back to `console.error` when unset. iOS `OpenAIError.rateLimited` surfaces server `message` verbatim. **Awaits**: KV namespace creation, `wrangler deploy`, iPad verification, OpenAI $75 monthly cap. **Phase 5d, 5e** still ☐. |
| **Phase 6** — account deletion edge function | ☐ not started | App Store guideline 5.1.1(v) requires it; ship before TestFlight. |
| **Phase 7** — observability + admin polish | ☐ not started | Post-TestFlight bucket. |

### What Trevor needs to do next (in order)

1. ~~**Run the SQL migration**~~ — done 2026-04-28; migration applied clean.
2. ~~**Enable Email provider** + **redirect URL**~~ — done 2026-04-28.
3. **Verify Phase 1 magic-link end-to-end on iPad** — still the first true end-to-end auth success milestone (HTTP/3 bias-off was the last code touch on it). Once magic link works, Phase 3 verification can begin.
4. **Verify Phase 3 end-to-end on iPad**: with a real signed-in session, save a drawing → check Supabase dashboard → Storage → `drawings` bucket has `<user_id>/<id>.jpg` + `<id>_thumb.jpg` → check `drawings` table has the row. Then cold-launch and confirm the gallery hydrates from cloud (kill local cache via the DEBUG "Clear All" button to force a clean cloud read).
5. **Phase 5c manual steps** (do these before / alongside iPad verification):
   - `wrangler kv:namespace create drawevolve-quota` → paste the returned id into `cloudflare-worker/wrangler.toml` (replacing `REPLACE_WITH_NAMESPACE_ID`) → `wrangler deploy`.
   - Set OpenAI monthly cap to **$75** with email alerts at 50%/80% (REQUIRED before public TestFlight).
   - *(Optional, deferrable)* Once a Slack incoming webhook URL exists, run `wrangler secret put ANOMALY_ALERT_WEBHOOK`. Until then, anomaly alerts surface as `console.error` in `wrangler tail`.
6. **Apple Sign In**: blocked on Apple Developer approval. When that lands, see the "Apple Developer side" runbook below in this file.

### What a fresh helper should NOT do

- Do not modify `AuthManager`, `SupabaseManager`, or `AppConfig` without asking — they're stable and tested in shape (compile-tested, not yet runtime-tested).
- Do not migrate the legacy `Documents/Drawings/*.json` files in any future code change — that is Phase 4's job. The Phase 3 storage manager intentionally ignores them.
- Do not touch `Services/AnonymousUserManager.swift`. It's still imported by `Services/CrashReporter.swift` at 5 sites; severing that requires a small follow-up pass, but it's out of scope for the current phase.
- Do not touch the brush/canvas/Metal pipeline (`MetalCanvasView`, `CanvasRenderer`, `CanvasStateManager`, `Shaders.metal`, `HistoryManager`). Those are TestFlight-blocker territory tracked in the dev plan, separately from auth.
- Do not push without explicit user say-so. Pattern in this session: `Bash` commits land locally; pushes happen only when Trevor says "push".
- Do not commit secret-shaped values. The current `Config.plist` is committed because it holds **only** public values (Supabase anon key + project URL — both ship in the app binary anyway). The header comment in `Config.plist` itself documents the rule. Real secrets go in the Cloudflare Worker via `wrangler secret put`.

### Recent commits (newest first; all on origin/main)

```
6b573a3  Add Phase 2 Supabase migration + document AuthGateView reskin
fc9cdca  Reskin AuthGateView to brand visual identity
9712f64  Commit Config.plist; remove Config.plist gitignore rule
36eb63b  z                                  (Trevor: markdown plan log)
e108c0a  Bundle Config.plist as a target resource
fb26849  Add AppConfig, SupabaseManager, AuthManager, AuthGateView to DrawEvolve target
68e458e  zzz                                (Trevor: end-of-day catch-up of Worker refactor + iOS scaffolding code)
```

### Key files (the artifacts that matter today)

| File | Purpose |
|---|---|
| `cloudflare-worker/index.js` | PromptConfig presets, tier/history stubs, OpenAI call. **Iterate prompts here**; do not inline strings into the request handler. |
| `cloudflare-worker/test.mjs` + `package.json` | `node --test test.mjs` from `cloudflare-worker/`. 6 tests, currently green. |
| `DrawEvolve/Services/AppConfig.swift` | Reads `SUPABASE_URL` / `SUPABASE_ANON_KEY` from `Config.plist`; nil-safe when not configured. |
| `DrawEvolve/Services/SupabaseManager.swift` | Singleton wrapping `SupabaseClient`. `client` is nil if Config.plist isn't filled in (DEBUG warns). |
| `DrawEvolve/Services/AuthManager.swift` | `@MainActor ObservableObject`. State machine: `.loading / .signedOut / .signedIn(User)`. Sign in with Apple + email magic link + deep-link handler + signOut + deleteAccount stub. |
| `DrawEvolve/Views/AuthGateView.swift` | Branded sign-in screen. Uses `Image("DrawEvolveLogo")` + AccentColor. Pure view layer; never touches AuthManager state directly except via its public methods. |
| `DrawEvolve/Views/ContentView.swift` | Routes on `authManager.state`. SignedInRoot is the existing onboarding/canvas flow. |
| `DrawEvolve/Services/DrawingStorageManager.swift` | Holds `CloudDrawingStorageManager` (Phase 3). Filename intentionally unchanged so the pbxproj didn't need editing. Local-first save with disk-backed pending-upload queue retried on `NWPathMonitor` reachability. DEBUG bypass user (`DEADBEEF-...`) skips cloud entirely at the top of the upload path. |
| `DrawEvolve/Models/Drawing.swift` | Phase 3 model — no inline `imageData`, has `storage_path`. CodingKeys map snake_case ↔ Postgres columns. |
| `DrawEvolve/Config/Config.plist` | Live Supabase URL + anon key. Committed; only-public-values. |
| `DrawEvolve/Config/Config.example.plist` | Template (vestigial since the real one is committed; safe to delete in a future cleanup). |
| `supabase/migrations/0001_init.sql` | Phase 2 schema bootstrap. Idempotent. Run in Supabase SQL Editor. |
| `authandratelimitingandsecurity.md` | This file — auth/security plan. |
| `DrawEvolve, April 27th` | Main dev plan (broader feature work, not auth-specific). |

### Verification runbook for the iPad render test

If Trevor hasn't reported back from the iPad, here's what success looks like and what each failure mode means:

1. **Cold launch** — splash → auth gate. **If you see a black screen or crash**, check the Xcode console for "SupabaseManager: SUPABASE_URL / SUPABASE_ANON_KEY not set" → Config.plist missing or path wrong.
2. **Auth gate renders** — DrawEvolveLogo at top, tagline below, Sign in with Apple button (50pt, rounded), divider with "or", email field, Send Magic Link button, footer at bottom. **If layout is broken on iPad** (edge-to-edge, weirdly stretched), check the `frame(maxWidth: 440)` constraint in AuthGateView.swift line ~52.
3. **Tap Send Magic Link** with a real email — should show a red error inline ("Couldn't send magic link…") UNTIL Trevor enables the Email provider in Supabase. After enable: the call succeeds and UI transitions to "Check your inbox" card. **If it crashes**, log the error from `AuthManager.sendMagicLink`'s catch.
4. **Tap Sign in with Apple** — system sheet appears. After Apple ID auth, will show a red error ("Apple sign-in failed…") until Apple Developer approval + Supabase Apple provider is configured. **If the system sheet doesn't appear at all**, check that the Sign in with Apple capability is added in Xcode → Signing & Capabilities.

### Glossary (so a helper doesn't have to decode our shorthand)

- **anon key** — Supabase public JWT (`role: anon`). Ships in every iOS app binary. Safe to commit. Security comes from RLS policies, not from secrecy.
- **service_role key** — Supabase secret JWT (`role: service_role`). Bypasses RLS. **Never** in repo, chat, or app. Lives in Cloudflare Worker secrets only (`wrangler secret put`).
- **PromptConfig** — typed shape at the top of `cloudflare-worker/index.js`. Controls systemPrompt / history count / style modifier / max tokens. Two presets: `DEFAULT_FREE_CONFIG`, `DEFAULT_PRO_CONFIG`.
- **TIER_LIMITS** — planned single source of truth (one object) in the Worker for per-tier rate limits. Defined in Phase 5c of this file; not yet implemented.
- **Paige iPad** — Trevor's physical test iPad. Simulator is not trusted for touch/Pencil bugs.
- **iPad-via-AnyDesk workflow** — Trevor edits in this codespace → pushes to GitHub → Mac Mini pulls (via AnyDesk from his work PC) → Xcode builds → deploys to Paige iPad. Round trip is slow; minimize "go test this" cycles.

---

## Session log

Legend: ✅ done & verified · 🟡 code-complete, awaits iPad / Xcode build verify · 🟠 partial · ⏳ blocked on Trevor's portal/dashboard work · ☐ not started

### 2026-04-28 — auth foundation pass

**Cloudflare Worker (cloudflare-worker/):**
- ✅ `index.js` rewritten: prompt construction externalized into `PromptConfig` shape with `DEFAULT_FREE_CONFIG` + `DEFAULT_PRO_CONFIG` presets, `selectConfig`, `buildSystemPrompt`, `buildUserMessage`, `getUserTier` stub, `fetchCritiqueHistory` stub, `formatHistoryEntries`. Existing prompt content preserved verbatim; client contract unchanged.
- ✅ `test.mjs` + `package.json` added. 6 tests in `node:test` covering preset selection, tier override, history capping, styleModifier injection, free-tier history-empty path, and selectConfig mutation isolation. Run via `npm test` from `cloudflare-worker/`. Currently green.

**iOS app (DrawEvolve/):**
- ✅ `Services/AppConfig.swift` — reads `SUPABASE_URL` + `SUPABASE_ANON_KEY` from `Config.plist`, returns nil for placeholder values.
- ✅ `Services/SupabaseManager.swift` — singleton, fails loudly in DEBUG if not configured; nil-safe at all sites.
- 🟡 `Services/AuthManager.swift` — `@MainActor ObservableObject`. State machine (`loading | signedOut | signedIn(User)`), Sign in with Apple flow (nonce + SHA-256 + `signInWithIdToken`), email magic link (`signInWithOTP` with `drawevolve://auth/callback`), `handleDeepLink`, `signOut`, `deleteAccount` stub, `authStateChanges` listener. Code-complete; needs first-build verify against the Supabase Swift SDK API surface.
- 🟡 `Views/AuthGateView.swift` — system Sign in with Apple button + email magic-link path with "Check your inbox" state, error surface. Renders without keys; sign-in attempts surface `notConfigured` error inline.
- 🟡 `DrawEvolveApp.swift` updated — `@StateObject` AuthManager, `.environmentObject`, `.onOpenURL → handleDeepLink`.
- 🟡 `Views/ContentView.swift` rewritten — routes on `authManager.state`: loading → `SplashView`, signedOut → `AuthGateView`, signedIn → existing flow (extracted to private `SignedInRoot`).
- ✅ `Services/DrawingStorageManager.swift` — dropped cached anonymous user ID; `saveDrawing` now reads `AuthManager.shared.currentUserID` and throws `.notAuthenticated` if missing.
- ✅ `Config/Config.example.plist` — `SUPABASE_URL` + `SUPABASE_ANON_KEY` placeholders added.
- ✅ `Info.plist` — `CFBundleURLTypes` added for the `drawevolve` scheme.

**Plan documents:**
- ✅ `authandratelimitingandsecurity.md` — Phase 0 expanded (tier model decision, OpenAI cost ceiling, 50%/80% alerts), Phase 5c rewritten as tier-aware from day one (`TIER_LIMITS`, 429 body shape), Phase 5c-alert added (5× daily quota in 1h webhook), Phase 7 trimmed to remove items now baked in.
- ✅ `DrawEvolve, April 27th` — header bumped to Apr 28, AI Feedback System section rewritten, Worker Auth section cross-references this file, Files That Matter expanded, new Investigations Reference entry for the prompt refactor.

### 2026-04-28 (cont.) — Xcode project wiring + Supabase keys

- ✅ `DrawEvolve.xcodeproj/project.pbxproj` — Phase 1 sources added to the DrawEvolve target (PBXBuildFile + PBXFileReference + Views/Services group children + PBXSourcesBuildPhase entries for AppConfig, SupabaseManager, AuthManager, AuthGateView). Commit `fb26849`.
- ✅ Supabase project created; URL + anon key captured (project ref `jkjfcjptzvieaonrmkzd`).
- ✅ `Config.plist` written locally at `DrawEvolve/Config/Config.plist` with the real values. File is gitignored (verified via `git check-ignore`); only the pbxproj reference is tracked.
- ✅ `Config.plist` added to PBXResourcesBuildPhase so `Bundle.main.path(forResource: "Config", ofType: "plist")` resolves at runtime. Without this the lookup returns nil even with the file on disk. Commit `e108c0a`.
- 📌 **Heads-up for future builds**: a fresh clone of this repo will not include `Config.plist`, so Xcode will show a yellow missing-file warning for the entry until each developer creates their own from `Config.example.plist`. Build will still succeed (the warning is non-fatal); the missing plist will surface at runtime as `AppConfig.isSupabaseConfigured == false`.

### 2026-04-28 (cont.) — AuthGateView reskin + Phase 2 migration drafted

- ✅ `Views/AuthGateView.swift` reskinned to brand identity. Pure view-layer change — `AuthManager`, `SupabaseManager`, `AppConfig` untouched. Uses the existing `DrawEvolveLogo` asset (cursive "Draw → EVOLVE"), constrains Sign in with Apple to standard 50pt height, custom rounded email field with focus accent border, primary-filled magic-link button with accent shadow, soft inbox-notice card, muted error styling with reserved 44pt height (no layout jump), 440pt max-width container for iPad readability. Commit `fc9cdca`, pushed.
- 🟡 `supabase/migrations/0001_init.sql` written. Single runnable file — paste into Supabase SQL editor → Run. Idempotent (safe to re-run). Contents:
  - `public.drawings` table (one row per drawing, `critique_history` as jsonb, indexed on `(user_id, updated_at desc)`, `updated_at` touch trigger).
  - RLS on `drawings` — four policies, all keyed on `auth.uid() = user_id`.
  - `public.feedback_requests` log table for Phase 5 quota / abuse tracking. Read-only RLS for users (Worker writes via service_role bypass).
  - Storage bucket `drawings` (private), with per-user read/insert/update/delete policies via `storage.foldername(name)[1] = auth.uid()::text`.
  - `set_default_tier_on_signup()` trigger that stamps `app_metadata.tier = 'free'` on every new `auth.users` row, plus a backfill update for any pre-existing row without a tier. Worker's `getUserTier()` therefore never sees a null tier in practice.

### 2026-04-28 (cont.) — Phase 2 migration applied + magic-link instrumentation

- ✅ `supabase/migrations/0001_init.sql` ran clean in the Supabase SQL Editor against project `jkjfcjptzvieaonrmkzd`. All Phase 2 schema is live: `drawings` + `feedback_requests` tables, RLS policies, `drawings` storage bucket + per-user policies, `set_default_tier_on_signup` trigger + backfill. Migration is idempotent so re-runs are safe.
- ✅ Email provider enabled in Supabase dashboard. `drawevolve://auth/callback` added to Authentication → URL Configuration → Redirect URLs allow-list. Custom SMTP configured against the drawevolve domain.
- 🟠 **Magic-link delivery investigation in flight.** Symptoms on Paige: after tapping "Send Magic Link", spinner spins indefinitely; no email arrives in any inbox; Sent Items folder on the drawevolve.com SMTP server is empty. Supabase auth log shows `/otp | request completed` and `mail.send` but no follow-up indicator. Audit confirmed the iOS code path is correct (View `isSendingMagicLink` flips off as soon as `await` returns; redirect-URL constant matches the dashboard allow-list exactly; Info.plist scheme registered) — so the fact that the spinner never clears means the await is genuinely not returning.
- 🟡 Diagnostic instrumentation added (DEBUG-only) so the next iPad attempt produces actionable Xcode console output:
  - `AuthManager.sendMagicLink`: `signInWithOTP` is now wrapped in a 30s watchdog (`withThrowingTaskGroup`) that throws on timeout. Both branches print elapsed time and the full `error` value (not `localizedDescription`, which is famously vague on URL/Foundation errors).
  - `SupabaseManager`: a private `DrawEvolveSupabaseLogger` conforming to `SupabaseLogger` is now passed via `SupabaseClientOptions.global.logger`, so every SDK request/response logs to the Xcode console as `[Supabase <level>] <message>`. Both diagnostics are `#if DEBUG` so Release/TestFlight builds stay quiet.
- ✅ Tangentially: fixed `AuthManager.randomNonce` charset typo (line 219) — uppercase sequence was missing `W` between `V` and `X`. Apple's nonce charset has 64 characters; ours had 63. Doesn't affect security (still uniform sampling), only used by Apple Sign In, but worth fixing in the same audit.
- 📌 No `Package.resolved` is checked into the repo — Xcode's SPM workspace dirs are excluded. Pinned requirement is `supabase-swift ≥ 2.0.0 / < 3.0.0`. Once we land on a version that works for Trevor's environment we should commit `Package.resolved` so a fresh clone gets the same SDK build.

### 2026-04-28 (cont.) — HTTP/3 / QUIC bias-off in DEBUG

- 🟡 Simulator console showed `nw_connection_copy_connected_local_endpoint_block_invoke - Connection has no local endpoint` and `quic_conn_process_inbound - unable to parse packet` while `signInWithOTP` hung. Root cause hypothesis: URLSession opportunistically upgrades to HTTP/3 against the Supabase edge, and the simulator's QUIC stack fails without falling back cleanly to HTTP/2 — explains why the request never returns and why the auth log only shows the original `/otp` entry.
- 🟡 `SupabaseManager` now constructs a `URLSessionConfiguration.ephemeral` with `urlCache = nil`, `requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData`, `httpMaximumConnectionsPerHost = 2`, and 30s/60s timeouts in DEBUG. The session is passed via `SupabaseClientOptions.global.session`. Rationale: there is no public API to disable HTTP/3 outright (Apple only exposes `URLRequest.assumesHTTP3Capable` for opt-in); ephemeral + no cache prevents the system's `Alt-Svc` route cache from biasing the next request toward HTTP/3. This is a *bias*, not a guarantee. Release/TestFlight still uses the default `URLSession.shared` since this issue has only been observed in the simulator.
- 📌 Escalation if the bias-off doesn't unstick the simulator: KVC `setValue(false, forKey: "_supportsHTTP3")` on the configuration. That's a private-flag workaround — DEBUG-only, never ship to TestFlight or App Store.

### What's left in Phase 1 (the closest unfinished work)

- ⏳ Fill real values into `Config.plist` (SUPABASE_URL, SUPABASE_ANON_KEY) — blocks first sign-in attempt.
- ⏳ Xcode → target → Signing & Capabilities → **+ Capability → Sign in with Apple**. Without this the Apple button can launch the system sheet but the credential exchange fails.
- ⏳ Xcode → File → Add Package Dependencies → confirm Supabase Swift package products (`Supabase`, `Auth`, `PostgREST`, `Storage`) are checked for the DrawEvolve target. SDK is declared in `project.pbxproj` per the Apr 28 codebase audit but had zero imports before today, which sometimes means "declared, not linked."
- 🟠 `AnonymousUserManager` still imported by `Services/CrashReporter.swift` at 5 sites (lines 53, 78, 95, 172, 181). Pre-auth crashes still tag with the device anonymous UUID. Out of scope today; future small pass: have `CrashReporter` prefer `AuthManager.shared.currentUserID?.uuidString` and fall back to anonymous. After that, `AnonymousUserManager` can be deleted.
- 🟡 Cold-launch session restore: code path is wired (`AuthManager.bootstrap()` → `client.auth.session`), needs iPad cold-launch test once keys are in.

### Phase 0 status (Trevor's portal/dashboard work)

- ⏳ Supabase: create project, capture URL + anon key + service_role key, enable Apple + Email magic-link providers, add `drawevolve://auth/callback` to redirect URLs.
- ⏳ Apple Developer: enable Sign in with Apple capability on the App ID, create Services ID, create + download `.p8` key, paste credentials into Supabase's Apple provider config.
- ⏳ OpenAI dashboard: set monthly Usage limit hard cap (suggested $100–$150 for TestFlight phase) and Soft limit alerts at 50% / 80%. Document the chosen cap in this file once set.
- ☐ Slack/Discord webhook for abuse alerts (Phase 5).
- ☐ Cloudflare Workers KV namespace `drawevolve-quota` (Phase 5).

### Phase 2–7 status

- **Phase 2** ✅ applied 2026-04-28 to live Supabase project (`jkjfcjptzvieaonrmkzd`) via the dashboard SQL Editor. Migration is idempotent; safe to re-run.
- **Phase 3** 🟡 code complete 2026-04-29 — see the 2026-04-29 session-log entry below for design notes. Awaits iPad end-to-end verification.
- **Phase 4** ⏭️ skipped — confirmed no pre-auth users / no legacy data exists; Trevor wipes dev iPad local data manually if needed.
- **Phase 5a + 5b** 🟡 code complete 2026-04-30 — see the 2026-04-30 session-log entry below. Awaits coordinated iOS + Worker deploy.
- **Phase 5c–7** ☐ not started.

---

## 2026-04-30 — Phase 5a + 5b coordinated iOS + Worker pass

**Cloudflare Worker (cloudflare-worker/):**
- ✅ `index.js` — Phase 5a auth gate: `validateJWT(token, env)` does ES256 (ECDSA P-256) signature verification via `crypto.subtle.verify` against the project's JWKS. JWKS fetched from `<SUPABASE_URL>/auth/v1/.well-known/jwks.json` and cached at module scope for 10 min; on `kid` not found we invalidate and refetch once before giving up. Validates `exp`, `iss` (against `SUPABASE_JWT_ISSUER` env), `aud` ("authenticated"), `sub`. Any failure → 401 with no body, no leakage.
- ✅ `index.js` — Phase 5b validators: `validateImagePayload` (≤8MB base64 + JPEG/PNG magic bytes), `validateContext` (object shape, optional string fields), `verifyDrawingOwnership` (PostgREST query against `drawings` with service_role key — bypasses RLS, scopes by `id` AND `user_id`). Order in handler: auth → body parse → drawing_id presence → image → context → ownership → tier+history → OpenAI. Cheap checks first; ownership Postgres roundtrip last.
- ✅ `index.js` — `getUserTier(payload)` and `fetchCritiqueHistory(drawingId, env)` replace the Phase 1 stubs. Tier reads from validated `payload.app_metadata.tier` (sync — no extra Supabase call). History pulls `drawings.critique_history` jsonb for the drawing. Both fall back to safe defaults (free, []) on any failure.
- ✅ `test.mjs` — 17 new tests for `validateImagePayload` (JPEG/PNG/garbage/oversized/empty/malformed base64), `validateContext` (full/empty/partial/wrong types/array rejection/forward-compat), `getUserTier(payload)` (default free, missing payload, pro+preferences, unknown tier, end-to-end → selectConfig). All 23 tests green via `node --test test.mjs`. JWT/Postgres integration paths are covered by end-to-end iPad testing — not unit-testable in node:test alone.
- ✅ `wrangler.toml` + `DEPLOYMENT.md` — required secrets documented: `OPENAI_API_KEY`, `SUPABASE_URL`, `SUPABASE_JWT_ISSUER`, `SUPABASE_SERVICE_ROLE_KEY`. **Note**: HS256 / `SUPABASE_JWT_SECRET` is NOT used — Trevor's project supports ES256/JWKS, which is the spec.

**iOS app (DrawEvolve/):**
- ✅ `Services/OpenAIManager.swift` — new signature `requestFeedback(image:, context:, drawingId: UUID)`. Fetches `client.auth.session.accessToken` via `SupabaseManager.shared.client`, attaches `Authorization: Bearer <jwt>`. Sends `drawingId.uuidString.lowercased()` (Phase 3 lowercase convention). Distinguishes 401 (`.unauthorized` — session expired) and 403 (`.forbidden` — ownership mismatch) from generic server errors. New error cases: `.notAuthenticated`, `.unauthorized`, `.forbidden`.
- ✅ `ViewModels/CanvasStateManager.swift` — `requestFeedback(for: DrawingContext, drawingId: UUID)` threads the id through.
- ✅ `Views/DrawingCanvasView.swift` — auto-save-before-feedback. `requestFeedback()` now calls `ensureDrawingPersistedToCloud()` first: if `currentDrawingID` is nil, generates a default title via `defaultSketchTitle(for:)` formatter (`"Sketch · MMM d, h:mm a"`, e.g. `"Sketch · Apr 30, 10:14 AM"`) and saves silently — no dialog, no notification per spec. Then awaits `storageManager.awaitCloudSync(for:)` so the row exists in Postgres before the Worker sees the ownership-check request. Auto-save / sync failures surface inline via `canvasState.errorMessage`.
- ✅ `Services/DrawingStorageManager.swift` — `awaitCloudSync(for: UUID) async throws` blocks on the active upload task; throws `.cloudSyncFailed` if the pending entry remains afterward (upload errored / in backoff). Normal saves remain local-first / fire-and-forget — only the auto-save-before-feedback path pays the latency.

**DEBUG bypass implication:** the bypass user has no Supabase session, so any feedback request from a bypassed canvas will fail with `.notAuthenticated` *before* hitting the Worker. This is correct — feedback genuinely requires a real auth session under Phase 5a. Trevor's bypass is for exercising local-only flows (canvas, save, gallery) without Supabase, not feedback.

**Lowercase-pattern audit during this pass:** no drift found. All new UUID-as-string conversions use `.uuidString.lowercased()` (iOS) or `.toLowerCase()` (Worker). Worker also defensively lowercases the `drawing_id` from the request body before any PostgREST query.

**Required Worker deploy steps (for Trevor):**
```bash
wrangler secret put SUPABASE_URL                # https://jkjfcjptzvieaonrmkzd.supabase.co
wrangler secret put SUPABASE_JWT_ISSUER         # https://jkjfcjptzvieaonrmkzd.supabase.co/auth/v1
wrangler secret put SUPABASE_SERVICE_ROLE_KEY   # service_role JWT from Supabase dashboard
# OPENAI_API_KEY already set
wrangler deploy
```

**iPad verification (after Worker is deployed):**
1. Sign in via magic link.
2. Draw something. Tap "Get Feedback" *without* hitting Save first.
3. Expect: brief delay (auto-save + cloud sync), then feedback streams. Gallery now contains a "Sketch · <date>" entry — rename via gallery if desired.
4. Save a real drawing with a chosen title. Request feedback. Verify `drawings.critique_history` in Supabase dashboard accumulates entries (drives Phase 5d's iterative-coaching prompt).
5. Sign out → back in. Old session JWT invalidated. Try feedback → expect 401 surfaced as "Your session has expired."

**Out of scope for this pass (still ☐):**
- 5c — tier-aware rate limits + KV quotas + per-IP backstop
- 5c-alert — 5×-quota webhook
- 5d — server-side feedback persistence (Worker writes to `critique_history` instead of trusting client)
- 5e — `feedback_requests` log rows
- Phase 6 — account deletion edge function

---

## 2026-04-29 — Phase 3 cloud sync

**iOS app (DrawEvolve/):**
- ✅ `Models/Drawing.swift` — dropped inline `imageData: Data`; replaced with required `storagePath: String` (`<user_id>/<id>.jpg`). CodingKeys map snake_case ↔ Postgres columns. Initializer signature updated; the `#Preview` in `DrawingDetailView` updated to match.
- 🟡 `Services/DrawingStorageManager.swift` — rewritten in place. Type renamed to `CloudDrawingStorageManager`; filename intentionally unchanged so the pbxproj didn't need editing. Public method signatures (`fetchDrawings`, `saveDrawing`, `updateDrawing`, `deleteDrawing`, `clearAllDrawings`) preserved so call sites compile after only a type-name swap. New surface: `pendingUploadCount: @Published`, `thumbnailData(for:)` (sync), `loadFullImage(for:) async throws -> Data?`.
- 🟡 `Views/GalleryView.swift` — `CloudDrawingStorageManager.shared`; `DrawingCard` now takes `thumbnail: Data?` from `storageManager.thumbnailData(for: drawing.id)`. Re-renders pick up async-loaded thumbnails because `thumbnailCache` is `@Published` on the manager.
- 🟡 `Views/DrawingDetailView.swift` — `CloudDrawingStorageManager.shared`; full image is `@State` loaded via `.task { fullImageData = try? await storageManager.loadFullImage(for: drawing.id) }`. Adds offline-fallback empty state.
- 🟡 `Views/DrawingCanvasView.swift` — `CloudDrawingStorageManager.shared`; `loadExistingDrawing()` now async-loads bytes via `storageManager.loadFullImage(for:)` before pushing onto the canvas, replacing the old direct `UIImage(data: drawing.imageData)`. Renderer-ready retry loop preserved.

**Local cache layout** (under `Documents/DrawEvolveCache/`):
- `metadata/<id>.json` — Drawing metadata (no image bytes)
- `thumbnails/<id>.jpg` — 256px JPEG (q=0.8), generated at save time, also pulled from `<user_id>/<id>_thumb.jpg` in cloud on hydrate-with-missing-cache
- `images/<id>.jpg` — full-size JPEG (q=0.9), lazy-loaded from `<user_id>/<id>.jpg` via signed URL (1h TTL)
- `pending/<id>.json` — retry queue entries (PendingUpload struct: drawing_id, user_id, storage_path, attempt_count, last_attempt_at)

**Save flow:** local persist → in-memory `drawings` array updated → save returns success → background `Task` uploads JPEG + thumb + upserts row. NWPathMonitor retries pending entries on reachability events. Exponential backoff capped at 60s, in-memory only.

**JPEG-only commitment:** the cloud schema stores `.jpg`, and the Phase 3 manager converts the canvas's PNG export to JPEG (q=0.9 full, q=0.8 thumb) before persist. This is a one-way lossy conversion. **Future feature on file (post-TestFlight):** an opt-in PNG-storage tier for users who care about lossless round-trips. Header comment in `DrawingStorageManager.swift` documents this.

**DEBUG bypass behavior:** the bypass user (sentinel UUID `DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF`) skips cloud entirely at the top of the upload path — no pending-upload entries are ever written, no spurious RLS-denied errors accumulate. Local save/load works so the canvas can be exercised offline. `fetchDrawings` short-circuits to local-cache hydration when bypass is on. `clearAllDrawings` and `deleteDrawing` skip cloud teardown.

**Sign-in / sign-out reactivity:** the manager observes `AuthManager.shared.$state` (and `$isDebugBypassed` in DEBUG). On any user change: in-memory `drawings`, thumbnails, retry-backoff state, and active upload tasks are cleared. Pending-upload entries on disk are filtered to the active user's `user_id` at retry time — entries from other accounts wait silently for that user to sign back in (no errors surfaced).

**What I deliberately did not do:**
- Did **not** migrate `Documents/Drawings/*.json` → that's Phase 4. Those files are now invisible to the app until Phase 4 picks them up.
- Did **not** delete cached metadata/thumbnails/images that belong to a stale `user_id` after sign-out; only filter on read. Cleanup is also Phase 4's job.
- Did **not** wire any "Some drawings still syncing" UI banner. `pendingUploadCount` is `@Published` and ready to bind; UI hookup is a follow-up.
- Did **not** touch the Worker (Phase 5a JWT validation is separate).
- Did **not** touch `AnonymousUserManager` / `CrashReporter`.

**Verification still required (iPad):**
1. Sign in via magic link.
2. Save a drawing → check Supabase dashboard → `drawings` bucket contains `<user_id>/<id>.jpg` + `<id>_thumb.jpg` → `drawings` table contains the row.
3. Force-quit app → cold launch → open gallery → confirm row hydrates from cloud (use DEBUG "Clear All" first to wipe local cache and verify it's a real cloud read, not just the cache).
4. Toggle airplane mode → save a drawing → confirm it appears in gallery immediately (local-first) → re-enable network → confirm `pendingUploadCount` decrements as the queue drains.
5. DEBUG SKIP AUTH path: enter bypass → save a drawing → confirm it appears locally and that no pending entry shows up in `Documents/DrawEvolveCache/pending/`.

---

## Goals

1. Replace device-anonymous identity with real per-user accounts (Supabase Auth).
2. Move drawings + AI feedback off-device into user-scoped cloud storage, with feedback **permanently linked** to the drawing it was generated for.
3. Lock down the Cloudflare Worker (`drawevolve-backend.trevorriggle.workers.dev`) so it can't be used as a free OpenAI proxy or used to bankrupt the OpenAI bill.
4. Ship App Store–compliant account creation **and** deletion.
5. Defense in depth: assume the client is hostile, the anon key is public, and at least one user will try to abuse the system.

## Threat model (what we're defending against)

- **Wallet-drain attacks**: anyone hitting the Worker to burn OpenAI credits.
- **Free-proxy abuse**: third parties using the Worker as a free GPT-4o Vision endpoint for unrelated apps.
- **Cross-user data access**: user A reading or modifying user B's drawings/feedback.
- **Spoofed identity**: user impersonating another via UUID forgery (current `AnonymousUserManager` is trivially spoofable).
- **Oversized payloads**: massive images sent to inflate token costs.
- **Account-creation abuse**: signing up many accounts to multiply free quota.
- **Lost data on migration**: existing TestFlight users' local drawings vanishing when auth lands.

---

## Phase 0 — Prereqs (account/portal work, not code)

### Supabase + Apple

- [~] Create Supabase project; capture project URL + anon key + service role key. **🟡 Partial**: URL + anon key captured & live in `Config.plist` (project ref `jkjfcjptzvieaonrmkzd`). `service_role` key still pending — only needed when the Worker starts validating JWTs in Phase 5a.
- [ ] Apple Developer: confirm Sign in with Apple capability is enabled for the app's bundle ID.
- [ ] Apple Developer: create Services ID + private key for Supabase ↔ Apple JWT exchange.
- [ ] In Supabase dashboard → Auth → Providers: enable **Apple** (paste Services ID + key) and **Email** (magic link only — disable signup-with-password).
- [ ] In Supabase dashboard → Auth → URL Configuration: add `drawevolve://auth/callback` to allowed redirect URLs.
- [ ] Decide email sender: Supabase default vs. custom SMTP / Resend. (Default fine for TestFlight.)
- [x] Add Supabase URL + anon key to `Config.plist` (and `Config.example.plist`).

### Tier model (used by quota + prompt config from day one)

- [ ] Decision locked: tier is stored in `auth.users.app_metadata.tier`, values `'free' | 'pro'`. Default `'free'` if absent or null. Pro-only prompt overrides live in `auth.users.app_metadata.prompt_preferences` (object with optional `styleModifier: string`).
- [ ] Set default `app_metadata.tier = 'free'` on new signups via a Supabase auth hook or trigger (so the field is never missing for legitimate users).

### OpenAI cost ceiling (provider-level backstop)

This is the last line of defense if every quota check fails simultaneously (Worker bug, KV outage, JWT validation broken). The OpenAI dashboard cap is enforced by OpenAI itself and cannot be bypassed by anything in our stack.

- [ ] OpenAI dashboard → Billing → Usage limits: set monthly hard cap on the `OPENAI_API_KEY` used by the Worker.
  - **Chosen cap: $___ /month** ← Trevor fills this in after setting it. Suggested starting range for TestFlight phase: **$100–$150/month** (covers ~50 active free-tier users at full daily quota with headroom; revisit before public launch).
- [ ] OpenAI dashboard → Usage alerts: configure email alerts at **50%** and **80%** of the monthly cap.
- [ ] Document the cap value and alert thresholds in this file once set, so future-me knows what the assumed budget is when revisiting limits.

## Phase 1 — Auth foundation (client)

- [ ] Add Sign in with Apple capability + entitlement in Xcode project. ⏳ Trevor (Xcode UI)
- [x] Add `drawevolve` URL scheme to `Info.plist` for magic-link redirect.
- [x] Create `Services/SupabaseManager.swift` — singleton wrapping `SupabaseClient`, configured from `Config.plist`.
- [x] Create `Services/AuthManager.swift` — `@MainActor` `ObservableObject` exposing:
  - `currentUser: User?` (nil = signed out) ✅
  - `signInWithApple()` (split into `prepareAppleSignInRequest` / `completeAppleSignIn` for SwiftUI button integration) ✅
  - `sendMagicLink(email:)` ✅
  - `handleDeepLink(_ url: URL)` ✅
  - `signOut()` ✅
  - `deleteAccount() async throws` (stub — wired in Phase 6) ✅
- [x] Auth UI: `AuthGateView` showing app branding + two CTAs (Sign in with Apple, Continue with Email). Email path shows "Check your inbox" state after submit.
- [x] Wire `ContentView` to gate on `authManager.currentUser` — auth gate before onboarding/canvas.
- [x] Handle deep link in `DrawEvolveApp` via `.onOpenURL { … }` → `authManager.handleDeepLink(url)`.
- [~] Replace `AnonymousUserManager.shared.userID` references with `authManager.currentUser?.id`. Delete `AnonymousUserManager` once nothing imports it. **🟠 Partial**: `DrawingStorageManager` updated; `CrashReporter` still imports `AnonymousUserManager` at 5 sites (out of scope today).
- [x] Persist session across launches (Supabase SDK does this by default — verify with cold launch test). 🟡 Code wired via `AuthManager.bootstrap()`; needs iPad cold-launch verify once Config.plist has real keys.
- [x] Loading states: cold-launch shows splash until session restore completes (no auth-gate flash).

## Phase 2 — Cloud schema + RLS

### `drawings` table

```sql
create table drawings (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  storage_path text not null,        -- 'drawings/<user_id>/<drawing_id>.jpg'
  context jsonb,                      -- DrawingContext
  feedback text,                      -- latest feedback summary (denormalized for gallery)
  critique_history jsonb not null default '[]',  -- [CritiqueEntry] — bundled with drawing
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index drawings_user_id_idx on drawings(user_id, updated_at desc);
```

**Why `critique_history` as jsonb (not a separate table):** mirrors local model 1:1, atomic with the drawing, cascades on delete for free, one query hydrates the gallery + all feedback. Future split-out is straightforward if a "feedback timeline across drawings" feature ever lands.

### RLS policies

```sql
alter table drawings enable row level security;

create policy "users read own drawings" on drawings
  for select using (auth.uid() = user_id);

create policy "users insert own drawings" on drawings
  for insert with check (auth.uid() = user_id);

create policy "users update own drawings" on drawings
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "users delete own drawings" on drawings
  for delete using (auth.uid() = user_id);
```

### Storage bucket

- [ ] Create private bucket `drawings`.
- [ ] Storage RLS: path must start with `auth.uid()` for select/insert/update/delete.
- [ ] No public URLs — always serve via signed URLs (short TTL, e.g. 1 hour).

### Migration scripts

- [ ] Capture all schema in `/supabase/migrations/0001_init.sql` checked into the repo.
- [ ] Document the apply command in the dev plan.

## Phase 3 — Cloud sync (local-first)

- [x] Replace `DrawingStorageManager` with `CloudDrawingStorageManager` — same public surface, hybrid implementation.
- [x] **Save flow**: write JSON locally → upload JPEG to Storage → upsert metadata row to Postgres → mark sync state. Local write is the source of truth on save; cloud is best-effort and retried.
- [x] **Load flow** on launch: query Postgres for user's drawings, hydrate gallery from metadata, lazy-load images via signed URLs (cache to disk).
- [x] **Offline mode**: if network fails, fall back to local cache; queue pending uploads; retry on next launch / network restore.
- [x] **Conflict policy**: last-write-wins by `updated_at`. Acceptable for solo-device usage; revisit if multi-device sync surfaces conflicts.
- [x] Drop in-JSON `imageData` for cloud-stored drawings — bytes live in Storage, JSON keeps only `storage_path`. Local cache can keep a thumbnail.
- [x] Thumbnails: generate 256px thumbnail at save time, store at `drawings/<user_id>/<drawing_id>_thumb.jpg`, use for gallery grid.

## Phase 4 — Migration of existing local drawings

- [ ] On first sign-in (detected by `UserDefaults.bool(forKey: "didMigrateLocalDrawings")` == false):
  - [ ] Enumerate existing `Documents/Drawings/*.json`.
  - [ ] For each: re-stamp `userId` with the new auth user ID, upload image bytes to Storage, insert metadata row.
  - [ ] On full success, set `didMigrateLocalDrawings = true`.
  - [ ] On partial failure, keep the flag false; surface a "Some drawings still syncing" indicator and retry on next launch.
- [ ] **After successful migration, delete the legacy `Documents/Drawings/*.json` files** — Phase 3 stopped reading them but left them in place; this is where they get cleaned up. (Phase 3 carryover.)
- [ ] **Sweep stale local cache by user_id** — enumerate `Documents/DrawEvolveCache/{metadata,thumbnails,images,pending}/` and delete any entry whose metadata/`user_id` doesn't match the now-signed-in user. The Phase 3 manager filters them out at hydrate time but never deletes; over time this grows on shared/test devices. (Phase 3 carryover.)

## Phase 5 — Cloudflare Worker hardening (rate limit + auth)

This is the biggest current attack surface. Layered defense:

### 5a. Auth gate

- [x] Worker requires `Authorization: Bearer <supabase_jwt>` on all feedback endpoints.
- [x] Validate JWT against Supabase JWKS (ES256 / P-256 via `crypto.subtle.verify`, with 10-min JWKS cache + kid-rotation refetch).
- [x] Extract `sub` (user ID) for use in rate limiting + logging.
- [x] Reject unauthenticated requests with 401 (no body — don't leak which routes exist).

### 5b. Request validation

- [x] Require `drawing_id` parameter in feedback request body.
- [x] Server-side check: `drawing_id` must belong to the JWT's user (query Postgres with service role, scoped by `user_id`).
- [x] Cap image payload size (8 MB base64 max).
- [x] Validate base64 decodes to a real JPEG/PNG (magic byte check).
- [x] Reject if `context` field is missing or malformed.

### 5c. Rate limiting (tier-aware from day one, per-user not per-IP — mobile IPs are unreliable)

**Tier source.** Tier is read at request time from `auth.users.app_metadata.tier` (via service role lookup keyed on the validated JWT's `sub`). Default `'free'` if absent or null. KV keys stay tier-agnostic (`quota:<user_id>:<yyyy-mm-dd>` → count) — tier is looked up live, so quota values can be retuned without key migration and a user upgrading from free to pro mid-day picks up the new limit on the next request.

**Limits live in one place in the Worker.** No magic numbers scattered through the handler — one config object, one-line edits to retune:

```js
const TIER_LIMITS = {
  free: { perMinute: 5, perDay: 20 },
  pro:  { perMinute: 15, perDay: 200 }
};
```

These are conservative starting values; revise once we have a week of real usage data.

- [x] Per-minute hard cap by tier: enforced in-Worker against a KV-backed rolling window of timestamps at `rate:<user_id>` (120s TTL, filter to `now - t < 60_000` on read). Recorded *before* the OpenAI call so concurrent bursts can't slip past the gate.
- [x] Daily soft quota by tier: tracked in Workers KV at `quota:<user_id>:<yyyy-mm-dd>` → count. Increment **after** a successful OpenAI response (don't burn quota on Worker errors). 48h TTL (so requests within a few hours after midnight don't read a stale-but-not-yet-expired value); UTC day boundary.
- [x] On quota exhausted: return **429** with body `{ error, scope, tier, limit, used, retryAfter, message }` and `Retry-After` header. The `message` field is the canonical user-facing copy (tier-aware: free mentions Pro upgrade, pro just states the reset time, IP scope omits tier mention entirely). iOS surfaces it verbatim through `OpenAIError.rateLimited`.
- [x] Per-IP backstop: 100 req/hr per hashed IP (`ip:<sha256(ip)>:<yyyy-mm-ddThh>`, 1h TTL). Implemented in-Worker rather than via the Cloudflare Rate Limiting product so KV semantics match the per-user counters.

### 5c-alert. Per-user abuse alert (Worker-level webhook)

- [x] If any single `user_id` exceeds **5× their daily quota** within a 1-hour window, POST to a logging webhook (Slack incoming webhook or similar). 5× a free-tier daily quota inside an hour means either JWT theft, a quota-bypass bug, or a runaway client — all of which warrant a human look. Tracked in KV at `hourly:<user_id>:<yyyy-mm-ddThh>` with 2h TTL. Fires only on the *transition* past threshold (not every subsequent request). Webhook URL stored as Worker secret **`ANOMALY_ALERT_WEBHOOK`** (renamed from earlier draft `ABUSE_ALERT_WEBHOOK`); when unset, threshold crossings fall back to `console.error` visible in `wrangler tail`.

### 5d. Server-side feedback persistence

- [ ] Worker writes the feedback response **directly to Postgres** (`drawings.critique_history` append) using service role key, not relying on the client to persist.
- [ ] Why: closes the gap where a client could request feedback, get the response, and never persist it (free queries). Also makes feedback tamper-evident — client can't doctor what GPT-4o said.
- [ ] Client gets feedback in the response and updates UI optimistically; on next gallery refresh, the cloud row is canonical.

### 5e. Logging

- [ ] `feedback_requests` table: id, user_id, drawing_id, requested_at, prompt_token_count, completion_token_count, status (`success` | `quota_exceeded` | `model_error`), client_ip_hash.
- [ ] Worker writes one row per request (success or fail) via service role.
- [ ] Index `(user_id, requested_at desc)` for abuse queries.

## Phase 6 — Account lifecycle (App Store compliance)

- [ ] Account deletion is required by App Store guideline 5.1.1(v). Build it now, not later.
- [ ] Supabase Edge Function `delete-account`:
  - Verifies caller's JWT.
  - Deletes Storage objects under `drawings/<user_id>/`.
  - Deletes drawings rows (cascade handles `feedback_requests`).
  - Calls `auth.admin.deleteUser(user_id)`.
- [ ] Client: settings screen → "Delete Account" → confirmation modal → call edge function → sign out → return to auth gate.
- [ ] Sign out: `supabase.auth.signOut()` + clear local cache + return to auth gate.
- [ ] Session refresh: rely on Supabase SDK's auto-refresh; verify token rotation works on long-running sessions.

## Phase 7 — Hardening + observability (post-TestFlight nice-to-haves)

(Per-user 5× alert and per-tier quotas were promoted into Phase 5c / Phase 0 — they're built in from day one, not bolted on later.)

- [ ] Aggregate anomaly dashboard: scheduled query over `feedback_requests` for global trends (total spend by day, p99 latency, OpenAI moderation rejection rate). Distinct from the per-user 5× webhook alert in 5c — this is the broader weather report.
- [ ] Admin view (web, not in-app): list users by feedback volume, ability to flip a user's `app_metadata.tier` or set a `disabled: true` flag the Worker honors.
- [ ] Content moderation: flag repeat OpenAI moderation rejections per user; auto-disable after N strikes.
- [ ] Rotate Supabase anon key procedure documented (in case of leak).
- [ ] Backup/export: user-initiated "download all my drawings" zip (GDPR-friendly).

---

## Open questions / decisions to revisit

- **Google Sign In**: deferred. Apple + magic link covers iOS users; revisit if user feedback demands it. Adds OAuth complexity + redirect URL scheme.
- **Anonymous trial mode** (use the app without signing in, sync later): not planned. Adds a claim-flow that's not worth the complexity. Auth required from launch.
- **Critiques as a separate table**: deferred. jsonb column suffices until a cross-drawing feedback feature is on the roadmap.
- **Offline-first vs cloud-first sync semantics**: starting local-first. Re-evaluate if multi-device usage becomes a thing.
- **Subscription/paid tier**: out of scope for this pass. Quota system in 5c is designed to support per-tier limits later.

---

## TestFlight blocker bar (must-haves before 2026-06-01)

- Phase 0 ✅
- Phase 1 ✅
- Phase 2 ✅
- Phase 3 ✅
- Phase 4 ✅
- Phase 5a, 5b, 5c (basic), 5d ✅
- Phase 6 ✅

Phase 5e logging and Phase 7 can ship after TestFlight cut, but 5a–5d cannot — without them the Worker is exploitable the moment TestFlight goes wide.
