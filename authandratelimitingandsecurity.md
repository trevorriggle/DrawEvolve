# Auth, Rate Limiting & Security Plan

Working checklist for the foundational plumbing pass. Tick items as they land.

Last updated: 2026-04-28

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

- [ ] Create Supabase project; capture project URL + anon key + service role key.
- [ ] Apple Developer: confirm Sign in with Apple capability is enabled for the app's bundle ID.
- [ ] Apple Developer: create Services ID + private key for Supabase ↔ Apple JWT exchange.
- [ ] In Supabase dashboard → Auth → Providers: enable **Apple** (paste Services ID + key) and **Email** (magic link only — disable signup-with-password).
- [ ] In Supabase dashboard → Auth → URL Configuration: add `drawevolve://auth/callback` to allowed redirect URLs.
- [ ] Decide email sender: Supabase default vs. custom SMTP / Resend. (Default fine for TestFlight.)
- [ ] Add Supabase URL + anon key to `Config.plist` (and `Config.example.plist`).

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

- [ ] Add Sign in with Apple capability + entitlement in Xcode project.
- [ ] Add `drawevolve` URL scheme to `Info.plist` for magic-link redirect.
- [ ] Create `Services/SupabaseManager.swift` — singleton wrapping `SupabaseClient`, configured from `Config.plist`.
- [ ] Create `Services/AuthManager.swift` — `@MainActor` `ObservableObject` exposing:
  - `currentUser: User?` (nil = signed out)
  - `signInWithApple() async throws`
  - `sendMagicLink(email:) async throws`
  - `handleDeepLink(_ url: URL) async throws` (consumes magic-link callback)
  - `signOut() async throws`
  - `deleteAccount() async throws` (calls Edge Function — see Phase 6)
- [ ] Auth UI: `AuthGateView` showing app branding + two CTAs (Sign in with Apple, Continue with Email). Email path shows "Check your inbox" state after submit.
- [ ] Wire `ContentView` to gate on `authManager.currentUser` — auth gate before onboarding/canvas.
- [ ] Handle deep link in `DrawEvolveApp` via `.onOpenURL { … }` → `authManager.handleDeepLink(url)`.
- [ ] Replace `AnonymousUserManager.shared.userID` references with `authManager.currentUser?.id`. Delete `AnonymousUserManager` once nothing imports it.
- [ ] Persist session across launches (Supabase SDK does this by default — verify with cold launch test).
- [ ] Loading states: cold-launch shows splash until session restore completes (no auth-gate flash).

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

- [ ] Replace `DrawingStorageManager` with `CloudDrawingStorageManager` — same public surface, hybrid implementation.
- [ ] **Save flow**: write JSON locally → upload JPEG to Storage → upsert metadata row to Postgres → mark sync state. Local write is the source of truth on save; cloud is best-effort and retried.
- [ ] **Load flow** on launch: query Postgres for user's drawings, hydrate gallery from metadata, lazy-load images via signed URLs (cache to disk).
- [ ] **Offline mode**: if network fails, fall back to local cache; queue pending uploads; retry on next launch / network restore.
- [ ] **Conflict policy**: last-write-wins by `updated_at`. Acceptable for solo-device usage; revisit if multi-device sync surfaces conflicts.
- [ ] Drop in-JSON `imageData` for cloud-stored drawings — bytes live in Storage, JSON keeps only `storage_path`. Local cache can keep a thumbnail.
- [ ] Thumbnails: generate 256px thumbnail at save time, store at `drawings/<user_id>/<drawing_id>_thumb.jpg`, use for gallery grid.

## Phase 4 — Migration of existing local drawings

- [ ] On first sign-in (detected by `UserDefaults.bool(forKey: "didMigrateLocalDrawings")` == false):
  - [ ] Enumerate existing `Documents/Drawings/*.json`.
  - [ ] For each: re-stamp `userId` with the new auth user ID, upload image bytes to Storage, insert metadata row.
  - [ ] On full success, set `didMigrateLocalDrawings = true`.
  - [ ] On partial failure, keep the flag false; surface a "Some drawings still syncing" indicator and retry on next launch.
- [ ] Don't delete local files post-migration — they're the offline cache.

## Phase 5 — Cloudflare Worker hardening (rate limit + auth)

This is the biggest current attack surface. Layered defense:

### 5a. Auth gate

- [ ] Worker requires `Authorization: Bearer <supabase_jwt>` on all feedback endpoints.
- [ ] Validate JWT against Supabase JWKS (verify signature, `aud`, `exp`, `iss`).
- [ ] Extract `sub` (user ID) for use in rate limiting + logging.
- [ ] Reject unauthenticated requests with 401 (no body — don't leak which routes exist).

### 5b. Request validation

- [ ] Require `drawing_id` parameter in feedback request body.
- [ ] Server-side check: `drawing_id` must belong to the JWT's user (query Postgres with service role, scoped by `user_id`).
- [ ] Cap image payload size (e.g. 8 MB base64 max).
- [ ] Validate base64 decodes to a real JPEG/PNG (magic byte check).
- [ ] Reject if `context` field is missing or malformed.

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

- [ ] Per-minute hard cap by tier: enforced in-Worker against KV-backed counters keyed `rate:<user_id>:<yyyy-mm-ddThh:mm>` with 60s TTL (Cloudflare Rate Limiting product is an option for the per-IP backstop below, but per-user limits need the tier lookup so they live in code).
- [ ] Daily soft quota by tier: tracked in Workers KV at `quota:<user_id>:<yyyy-mm-dd>` → count. Increment **after** a successful OpenAI response (don't burn quota on Worker errors). 24h TTL; UTC day boundary.
- [ ] On quota exhausted: return **429** with body `{ error: 'quota_exceeded', tier, limit, retryAfter }` and `Retry-After` header. The `tier` and `limit` fields let the client render context-appropriate copy: free users see "Free tier: 20/day. Upgrade to Pro for 200/day."; pro users see "Pro daily limit reached — resets at 00:00 UTC."
- [ ] Per-IP backstop: 100 req/min across all users from one IP (Cloudflare Rate Limiting rule). Catches one attacker creating many free accounts from a single IP.

### 5c-alert. Per-user abuse alert (Worker-level webhook)

- [ ] If any single `user_id` exceeds **5× their daily quota** within a 1-hour window, POST to a logging webhook (Slack incoming webhook or similar). 5× a free-tier daily quota inside an hour means either JWT theft, a quota-bypass bug, or a runaway client — all of which warrant a human look. Track recent hourly counts in KV at `hourly:<user_id>:<yyyy-mm-ddThh>` with 2h TTL. Webhook URL stored as Worker secret `ABUSE_ALERT_WEBHOOK`.

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
