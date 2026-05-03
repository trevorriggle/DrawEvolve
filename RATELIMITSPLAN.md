# Rate Limits & Credit System — Audit + Plan

**Status:** Plan only. No implementation in this document.
**Date:** 2026-05-02
**Scope:** Replace the current tier-bucket rate limiter with a credit-based system that supports Apple StoreKit 2 in-app purchases.

---

# Part 1 — Audit of the Current System

## 1.1 Cloudflare Worker rate limits

All limits live in `cloudflare-worker/index.js` and are backed by Cloudflare KV (`QUOTA_KV`). KV is **eventually consistent**; the code accepts small overshoot under concurrency.

### Per-user tier quotas (`TIER_LIMITS`, lines 565–568)

| Tier | per-minute | per-day |
|------|-----------|---------|
| free | 5 | 20 |
| pro  | 15 | 200 |

Tier is read from `auth.users.app_metadata.tier` (Supabase JWT). Default `'free'` is stamped on signup by trigger `set_default_tier_on_signup` (`supabase/migrations/0001_init.sql:164`). Resolution: `getUserTier(payload)` at `index.js:514`.

### Per-IP backstop (lines 569, 691–710)

`IP_HOURLY_CAP = 100` requests/hour per `sha256(ip)`, key `ip:<sha256(ip)>:<utc-hour>`, 1h TTL. Hard cap; intentionally coarse to catch shared accounts and basic spam.

### Idempotency cache (`recordIdempotent` / `checkIdempotency`)

Key: `idempotency:<user_id>:<client_request_id>`. 1h TTL. Caches the response body so a retry of the same `client_request_id` returns the cached body without re-charging OpenAI. Prevents *replay* abuse only — concurrent requests with different IDs both pass.

### Daily spend cap (lines 1169–1204, 1411–1423)

Global hard ceiling: `DAILY_SPEND_CAP_USD = 5.00`. Aggregates across **all users**. Enforced before the OpenAI call; on breach, returns 503. Cost computed from `data.usage` after the call:

- `COST_PER_INPUT_TOKEN_USD  = 0.63 / 1_000_000` (gpt-5.1)
- `COST_PER_OUTPUT_TOKEN_USD = 5.00 / 1_000_000` (gpt-5.1)

### Anomaly alert (lines 728–765)

Hourly counter `hourly:<user_id>:<utc-hour>`. If success count exceeds `ANOMALY_MULTIPLIER (5) × tier.perDay` in a single hour, POSTs to `ANOMALY_ALERT_WEBHOOK` (or `console.error`). Fires on threshold transition only. For a free user this is 100 critiques/hour — effectively unreachable under the per-minute gate, so this is more about catching pro-tier exfil patterns.

### Order of enforcement

1. JWT validation → `auth_failed`
2. Schema/payload validation → `validation_failed`
3. Drawing ownership check → `ownership_denied`
4. `enforceRateLimits` (per-day, per-minute, per-IP) → `quota_exceeded`
5. Daily spend cap → 503
6. OpenAI call → `model_error` if upstream fails
7. On success: persist critique, increment quota counter, increment daily spend, write idempotency cache, log row

**Key property:** the daily quota counter increments **after** OpenAI delivers (`recordSuccessfulCritique`, lines 737–740). Per-minute and per-IP record **before** the OpenAI call. This means failed-upstream calls do NOT burn the daily quota but DO count against per-minute/per-IP — important for the credit refund design below.

## 1.2 Supabase rate limits

**There are no schema-level rate limits.** All quota logic lives in the Worker. Relevant tables:

- `drawings` (`0001_init.sql:32`) — RLS `auth.uid() = user_id` on read/insert/update/delete. No per-user-per-day insert cap.
- `feedback_requests` (`0001_init.sql:98`) — service-role-only writes from the Worker. Logs every attempt with `status`, `prompt_token_count`, `completion_token_count`, `client_ip_hash`. RLS lets users read their own log.
- `auth.users.app_metadata.tier` — single source of truth for tier. Mutated only by the trigger or by a Supabase admin (no client API path mutates it).

The `feedback_requests` log is the only persistent ground truth for usage; everything else (KV counters) is ephemeral.

## 1.3 Client-side throttles (iOS)

**None.** Search of `DrawEvolve/` for debounce/throttle/rate-limit logic returns no hits in the critique path. The relevant call chain:

- `DrawingCanvasView.requestFeedback()` → `Task { await canvasState.requestFeedback(...) }`
- `CanvasStateManager.requestFeedback()` → awaits `OpenAIManager.requestFeedback()`
- `OpenAIManager.requestFeedback()` (line 89) — async POST to the Worker, no debounce, no concurrent-request guard

A user holding the "Get Feedback" button can spawn arbitrarily many concurrent requests. The Worker's per-minute and per-IP gates absorb this, but each request still costs a JWT validation, a Supabase ownership check, and a KV read. The auto-save step (`ensureDrawingPersistedToCloud`) is a prerequisite, not a throttle.

## 1.4 Existing documentation

- `authandratelimitingandsecurity.md` (614 lines) — fully documents Phase 5c quotas, per-IP backstop, anomaly webhook, daily spend cap, idempotency, and `feedback_requests` logging. This document supersedes that for the credit design but does not invalidate the existing rate-limit mechanics (which will become *belt-and-suspenders* under the new system, see §2.4).
- `MEMORY.md` — notes that `OPENAI_MODEL` was attempted to swap to gpt-5.1, rolled back, then restored. **Code reality (verified):** `OPENAI_MODEL = 'gpt-5.1'` at `index.js:1148`. MEMORY.md is stale on this point and should be updated.

---

## 1.5 Token cost per critique

### System prompt assembly (`buildSystemPrompt`, `assembleSystemPrompt` in `index.js`)

Composed of:

1. **Voice block** (one of 4 presets, `index.js:28–34`) — ~450–520 chars
2. **`SHARED_SYSTEM_RULES`** (lines 36–98) — ~2,800 chars (subject verification, iterative coaching rules, closing-aside requirements)
3. **Skill calibration** (lines 177–190) — ~200–250 chars
4. **Context block** (lines 192–201) — variable; capped at: subject 200, style 200, artists 500, techniques 200, focus 200, additionalContext 2000 (validated at lines 441–450)
5. **Response format template** (lines 122–147) — ~500–600 chars
6. **Optional Pro `styleModifier`** (line 211) — appended for Pro tier overrides

**Estimate (4 chars ≈ 1 token):** baseline ~875 input tokens; Pro with style modifier ~900–975.

### User-message assembly (`buildUserMessage`, lines 244–264)

1. History framing line (`HISTORY_FRAMING_DEFAULT`) — ~10 tokens
2. Truncation marker if history was clipped — ~10–20 tokens
3. **Formatted prior critiques** (`formatHistoryEntries`, lines 217–234) — each prior critique ≈ 350–400 tokens
   - Free tier: up to 2 priors → ~700–800 tokens
   - Pro tier: up to 5 priors → ~1,750–2,000 tokens
4. Base message ("Please critique this drawing.") — ~8 tokens
5. **Image** (`index.js:261`) — JPEG @ 0.8 from a 2048×2048 PencilKit canvas (`OpenAIManager.swift:91`). Sent as `data:image/jpeg;base64,...` with **no `detail` parameter** — OpenAI defaults to `detail=auto`, which selects `low` (~85 tokens) for typical content. **High-detail would be ~1,700 tokens — a 20× difference.**

### Output cap (`maxOutputTokens`)

- Free: 1,000 (line 156)
- Pro: 1,500 (line 164)

Sent to OpenAI as `max_completion_tokens` (gpt-5.1 rejects `max_tokens`). Typical observed completions are ~700–800 words → ~300–500 output tokens.

### Per-call cost estimates (gpt-5.1: $0.63 / $5.00 per 1M tokens)

| Scenario | Input tok | Output tok | Cost USD |
|----------|-----------|-----------|----------|
| Free, first critique (no history) | ~970 | ~300 | **$0.0021** |
| Free, follow-up (2 priors) | ~1,720 | ~400 | **$0.0031** |
| Pro, first critique | ~990 | ~400 | **$0.0026** |
| Pro, 5th critique (max history) | ~2,920 | ~500 | **$0.0043** |
| Worst case (Pro + high-detail vision swap, 5 priors) | ~4,540 | ~1,500 | **$0.0104** |
| Catastrophic (high-detail + max additionalContext + 5 priors + max output) | ~5,200 | ~1,500 | **$0.0108** |

**Variance drivers, ranked:**

1. **Image `detail` mode** — single biggest lever. A flip from `auto`/`low` (~85 tok) to `high` (~1,700 tok) inflates input cost ~$0.001 per critique on its own. Currently we don't set this, so we benefit from the default. **A future change to `detail: high` without re-pricing credits is a footgun.**
2. **History length** — Pro 5-prior is +1,300 tokens vs first critique (~$0.0008).
3. **Output length** — capped per tier; rarely the dominant factor unless cap is raised.
4. **`additionalContext`** — capped at 2,000 chars (~500 tokens) but rarely filled.

---

## 1.6 Gaps where unbounded usage is possible

1. **No per-drawing critique cap.** A user can request 20 critiques on the same drawing in a day (within their daily quota). No schema or Worker constraint prevents this.
2. **No client-side debounce.** The "Get Feedback" button has no UI guard. A buggy or hostile client can spawn concurrent requests until the per-minute gate trips.
3. **KV eventual consistency.** `index.js:628` and `:1197` both acknowledge this — under high concurrency multiple isolates can read `count = N` and all write `N+1`, undercounting. At TestFlight scale this is fine; at scale it silently breaches quotas.
4. **Concurrent requests bypass idempotency.** Idempotency is keyed by `client_request_id`. Two simultaneous requests with different IDs both hit OpenAI.
5. **Per-IP gate punishes shared networks.** A school/office/coffee-shop IP burns through 100 req/hr quickly when 5 users share it; all users on that IP get locked out.
6. **No per-user spend cap, only per-user request cap.** A Pro user at max-history-every-time uses ~$0.86/day at quota. A model swap or vision-detail flip changes the per-request cost without changing the request quota.
7. **Daily spend cap is global, not per-user.** A single abusive user (or a runaway client bug) can starve every other user once the $5/day ceiling hits.
8. **No outlier guard on `prompt_token_count`.** If something pushes a single request to 50k input tokens (e.g., a future history bug), it costs $0.03 and there's no pre-flight reject.

---

# Part 2 — Plan: Credit-Based Rate Limiting

## 2.1 Product principle

**1 credit = 1 AI critique.** All other limits become abuse backstops, not the user-facing model.

This replaces "free = 20/day, Pro = 200/day" with "you have N credits; each critique costs 1; buy more in-app."

### Why this beats the current tiered-quota model

- **Mental model is one number.** Users don't have to learn min/day/month resets.
- **Rolls cleanly into IAP.** Apple StoreKit consumables map 1:1 to credit packs.
- **Decouples pricing from rate-limit complexity.** Credit math is the price; rate limits stay as abuse backstops invisible to honest users.
- **Existing `tier` field stays useful.** Pro tier still gates *quality* features (longer output cap, custom prompts, more history) without dictating *quantity*.

---

## 2.2 Credit balance schema (Supabase Postgres)

New migration `0006_credit_balances.sql`. Postgres is the right home for credits (not KV) because we need atomicity; KV stays the home for short-window rate limits.

### Tables

```sql
-- Per-user credit balance. One row per user, lazily created on first credit op.
create table public.user_credits (
    user_id              uuid primary key references auth.users(id) on delete cascade,
    balance              int  not null default 0 check (balance >= 0),
    lifetime_purchased   int  not null default 0,  -- sum of all paid grants ever
    lifetime_consumed    int  not null default 0,  -- sum of all critique decrements
    lifetime_refunded    int  not null default 0,  -- sum of refunds back into balance
    free_grant_period    text,                     -- e.g. '2026-05' — month last granted
    free_grant_amount    int  not null default 0,
    apple_account_token  uuid,                     -- StoreKit2 appAccountToken, set on first purchase
    locked_at            timestamptz,              -- non-null = blocked from spending (chargeback hold)
    locked_reason        text,
    created_at           timestamptz not null default now(),
    updated_at           timestamptz not null default now()
);

-- Append-only ledger. Every change to balance has a row here. Source of truth.
create table public.credit_ledger (
    id                 bigserial primary key,
    user_id            uuid not null references auth.users(id) on delete cascade,
    delta              int  not null,             -- +grant / -spend / +refund / -clawback
    reason             text not null,             -- 'free_grant' | 'iap_consumable' | 'critique_spend'
                                                  -- | 'critique_refund' | 'apple_revoke_clawback'
                                                  -- | 'admin_adjustment'
    balance_after      int  not null,
    request_id         uuid,                      -- feedback_requests.id when reason='critique_spend'
    apple_transaction_id text unique,             -- non-null for IAP/refund/revoke; UNIQUE = idempotency
    metadata           jsonb,
    created_at         timestamptz not null default now()
);

create index credit_ledger_user_time_idx
    on public.credit_ledger (user_id, created_at desc);

-- Track Apple transactions we've seen (signed JWS payloads) for replay protection.
-- Distinct from credit_ledger because some notifications (e.g. DID_RENEW for a
-- subscription we don't sell yet) we want to record but not turn into credits.
create table public.apple_transactions (
    transaction_id     text primary key,          -- Apple's transactionId
    original_transaction_id text not null,
    user_id            uuid not null references auth.users(id) on delete cascade,
    product_id         text not null,
    quantity           int  not null default 1,
    purchase_date      timestamptz not null,
    revocation_date    timestamptz,
    revocation_reason  int,
    raw_payload        jsonb not null,            -- the verified JWS payload for audit
    notification_uuid  uuid,                      -- when received via S2S notification
    created_at         timestamptz not null default now()
);

create index apple_transactions_user_idx
    on public.apple_transactions (user_id, purchase_date desc);
```

### RLS

- `user_credits` — `select` allowed for `auth.uid() = user_id` (so the iOS app can show "you have N credits"); no client-side `insert/update/delete`. All mutations go through service-role RPCs called by the Worker.
- `credit_ledger` — same: `select` own rows only, no client mutations.
- `apple_transactions` — service-role only; no RLS exposure (sensitive raw payloads).

### Atomic spend RPC (the one that matters)

```sql
create or replace function public.spend_credit(
    p_user_id    uuid,
    p_request_id uuid
) returns int          -- new balance, or NULL on insufficient credit / locked
language plpgsql
security definer
as $$
declare
    v_balance int;
    v_locked  timestamptz;
begin
    select balance, locked_at into v_balance, v_locked
      from public.user_credits
     where user_id = p_user_id
       for update;                              -- row lock prevents concurrent overspend

    if not found or v_balance < 1 or v_locked is not null then
        return null;
    end if;

    update public.user_credits
       set balance         = balance - 1,
           lifetime_consumed = lifetime_consumed + 1,
           updated_at      = now()
     where user_id = p_user_id;

    insert into public.credit_ledger (user_id, delta, reason, balance_after, request_id)
    values (p_user_id, -1, 'critique_spend', v_balance - 1, p_request_id);

    return v_balance - 1;
end;
$$;
```

`SELECT ... FOR UPDATE` gives us atomic check-and-decrement under concurrency — the bug class that KV exposes. Two concurrent critique requests serialize through the row lock; the second one with `balance = 0` returns NULL.

Companion RPCs (sketched, not full SQL): `refund_credit(user_id, request_id, reason)`, `grant_credits(user_id, amount, reason, apple_transaction_id)`, `clawback_credits(user_id, amount, apple_transaction_id)`, `ensure_free_grant(user_id, period, amount)`.

---

## 2.3 Worker enforcement (check + decrement + refund)

New flow inside the existing handler in `cloudflare-worker/index.js`. Order of enforcement changes:

1. JWT validation
2. Schema/payload validation
3. Drawing ownership check
4. **Free-grant top-up** — call `ensure_free_grant` (idempotent on `(user_id, current_month)`); first call this month grants the monthly free credits
5. **Soft rate-limit gate** (existing per-minute + per-IP, kept as abuse backstop — see §2.4)
6. **Spend credit** — `select spend_credit(user_id, generated_request_id)` returns the new balance or NULL
   - NULL → 402 Payment Required (or 429 with `code: 'no_credits'`) with message: *"You're out of credits. Buy more in the app to keep going."*
7. Daily global spend cap (kept; defense in depth)
8. Insert `feedback_requests` row with status `'pending'` — the `request_id` from step 6 *is* this row's id (generate UUID up front)
9. OpenAI call
10. On success: update `feedback_requests` to `'success'`, persist critique, log
11. On failure: **refund the credit** (call `refund_credit`), update `feedback_requests` to the failure status
12. Idempotency cache write

### Refund taxonomy

Refund the credit when the failure was **not the user's fault** and **no critique was delivered**:

| Status | Refund? | Rationale |
|--------|---------|-----------|
| `success` | No | User got the critique. |
| `persistence_orphan` | No | User got the critique; row write failed but model did the work. |
| `model_error` (OpenAI 5xx, malformed response, empty content) | **Yes** | User got nothing. |
| `internal_error` (Worker bug, KV/Supabase outage *after* spend) | **Yes** | User got nothing. |
| `auth_failed`, `validation_failed`, `ownership_denied` | N/A | Rejected before spend, no credit was taken. |
| `quota_exceeded` (legacy backstop) | N/A | Rejected before spend. |
| Daily spend cap (503) | **Yes** | Rejected before OpenAI but **after** spend. Refund and lift the spend toward the cap accordingly. |
| `idempotent_replay` | No spend on the replay | Cached response served; no second spend ever happens. |

**Pre-flight position of the spend matters.** Putting `spend_credit` *after* the daily-spend-cap check (so a 503 doesn't need a refund) is cleaner — recommend that order. The table above assumes the recommended order; the only refund cases are `model_error` and `internal_error`.

### Idempotency interaction

`client_request_id` cache must be checked **before** spending. If a cache hit, return cached body; do not spend. This prevents double-charge on retry — same property the legacy system has, just more important under credits.

### Failure modes inside the refund itself

If `refund_credit` throws (Postgres outage), the user has lost a credit and got nothing. Mitigations:

- Log loudly to `[credit-refund] failed` with the request_id and amount
- Write a row to a `pending_refunds` table (service-role only) so a retry sweep (cron or manual) can complete it
- On startup or via scheduled worker, drain `pending_refunds`

This is the same shape as `recordSuccessfulCritique`'s fire-and-forget pattern, but the user's money makes it less acceptable to lose silently.

---

## 2.4 Soft rate limits (kept as abuse backstops)

Keep `TIER_LIMITS.perMinute` and `IP_HOURLY_CAP` from `index.js:565–569`. Drop or relax `perDay` (the credit balance now does that job).

Suggested values under the credit model:

| Limit | Value | Purpose |
|-------|-------|---------|
| Per-user per-minute | 10 | Stops UI spam / button-mashing without throttling normal use |
| Per-IP per-hour | 100 | Unchanged; catches multi-account farming on one network |
| Per-user concurrent | 1 | New: reject if a request from this user is already in-flight (Workers KV `inflight:<user_id>` with short TTL set on entry, deleted on exit) |
| Daily global spend cap | $25 | Raise from $5 — credits subsidize this — but keep as a runaway-cost circuit breaker |

**Per-user concurrency cap is new.** The current system has none, and it's the cheapest fix for the "user mashes Get Feedback" attack: one concurrent request per user; the second arrives, sees the inflight key, gets 429 with *"Already working on your last critique."*

---

## 2.5 Free-tier allowance

**Recommendation:** 5 free credits/month, granted on first critique attempt of a calendar month (lazy top-up). Not per-day — a user can blow their entire monthly free allowance in one sitting if they want.

Why monthly, not daily:

- Lets users do a real session (not "1 critique today, come back tomorrow")
- Higher conversion to paid: the painful out-of-credit moment lands while they're engaged, not when they're already gone
- Cheaper to reason about: one grant per user per month, ~5 cost = ~$0.015/user/month at typical critique cost

Why 5, not 10 or 3:

- 5 is enough to evaluate the product (one drawing + a few iterations)
- Cost ceiling: 5 credits × $0.0043 worst-typical = $0.022/user/month; even with 10k MAU free users, $220/month upper bound on free-tier OpenAI cost
- 10 free/month makes the smallest paid pack feel less compelling
- 3 is too few to experience iterative coaching

Implementation: `ensure_free_grant(user_id, period, amount)` is called by the Worker on every critique attempt. It's idempotent — if `user_credits.free_grant_period = current_month`, it's a no-op. First call of a new month grants `amount` credits, sets `free_grant_period`, writes a ledger row with reason `'free_grant'`.

**Anti-farming:** Free grants are tied to `auth.users.id`. Account creation is gated by Sign in with Apple (already integrated per recent commit `54d830b`). Per-Apple-ID account is the natural abuse boundary. Optional hardening: if a Sign-in-with-Apple user's `is_private_email` claim is true *and* they've never made an IAP, cap free grants to one period total (plays defense against private-relay-cycling).

---

## 2.6 Tiered paid plans (StoreKit 2 IAP)

### Recommendation: consumable credit packs only for v1. No subscriptions.

Subscriptions add: subscription-status polling, grace period handling, billing retry, lapsed-subscription credit decay rules, and the "what happens to unused subscription credits at month end" question. None of that is necessary to ship credits.

### Initial product catalog

Three consumable IAPs in App Store Connect:

| productId | Credits | Price (USD) | $/credit | Notes |
|-----------|---------|-------------|----------|-------|
| `credits_pack_25`  | 25  | $1.99 | $0.0796 | Entry pack |
| `credits_pack_100` | 100 | $5.99 | $0.0599 | Best-value badge |
| `credits_pack_500` | 500 | $24.99 | $0.0500 | Power-user pack |

Margin sanity: at $0.0043/critique worst-typical cost and ~$0.05/credit revenue → **~12× gross margin** on the $5.99 pack. Holds up even if average critique cost doubles (e.g., a future model swap). See §2.10 for what to do if a single critique threatens to exceed the per-credit cost basis.

### Pro tier becomes a future SKU, not a subscription required to use credits

The existing `tier` field stays — Pro still gates *quality* (longer output, custom prompts, more history). For v1, Pro is granted manually or bundled with a "Pro Pack" (e.g., a `credits_pack_pro_500` consumable that also flips `app_metadata.tier = 'pro'` for 30 days via a separate non-credit grant). This is an enhancement; ship credit packs first.

### Why consumable, not non-consumable?

Consumables are designed exactly for this: the user buys 100 of something, uses them, buys more. They don't restore across devices (a user reinstalling doesn't get their used credits back), but the **balance lives on the server**, so device reinstall is fine — the balance follows the Supabase user.

---

## 2.7 Server-side StoreKit 2 receipt validation

Two integration paths from Apple. Use both:

### Path A: client-initiated verification on every transaction

When `Transaction.updates` fires in Swift:

1. iOS app sends `{ jwsRepresentation, appAccountToken }` to a new Worker endpoint `POST /apple/verify-transaction`
2. Worker verifies the JWS:
   - Parse the JWS header to extract the `x5c` cert chain
   - Verify the cert chain roots to Apple's root CA (`AppleRootCA-G3.cer`) — bundle the root in the Worker
   - Verify the JWS signature against the leaf cert's public key
   - Decode payload; reject if `bundleId` ≠ ours, if `environment` ≠ expected (`Production` or `Sandbox` per worker env), if `expiresDate` < now (consumables don't have one; subscriptions do)
3. Resolve `(transactionId, originalTransactionId)` and look up `apple_transactions.transaction_id`:
   - Already present → respond 200 with `{ status: 'already_processed', balance }` (idempotent — replay-safe)
   - Not present → insert the row, then call `grant_credits(user_id, productCreditMap[productId], 'iap_consumable', transaction_id)` which uses the `apple_transaction_id` UNIQUE constraint as the second idempotency layer
4. Bind `apple_account_token` to `user_credits.apple_account_token` on first purchase. Reject future transactions whose `appAccountToken` doesn't match (account-linking integrity).
5. Respond with the new balance so the iOS app can update its UI immediately

### Path B: App Store Server Notifications V2 (S2S webhook)

Configure the production endpoint in App Store Connect → App Information → App Store Server Notifications → V2: `https://worker.drawevolve.app/apple/notifications`.

Handle these notification types at minimum:

- `CONSUMPTION_REQUEST` — Apple is reviewing a refund request. Respond with consumption data (whether the credits were used). Required by Apple to influence refund decisions.
- `REFUND` — Apple granted a refund. Find the transaction, call `clawback_credits` (see §2.8).
- `REVOKE` (family sharing revocation) — same handling as REFUND.
- `REFUND_REVERSED` — credits we clawed back should be re-granted.
- `TEST` — App Store Connect test pings; respond 200.

Receive, verify the JWS exactly as in Path A, look up by `notification_uuid` for idempotency, then dispatch.

**Both paths converge on `apple_transactions` and the `credit_ledger`** — `apple_transactions.transaction_id` is the dedup key for the purchase event itself; `credit_ledger.apple_transaction_id` is UNIQUE for the credit grant. Either path can run first; the other becomes a no-op.

### What lives in the Worker vs. a new Supabase Edge Function?

Recommend the Worker. Rationale:
- Already owns auth, KV, Supabase service-role, OpenAI — the StoreKit verifier belongs with the rest of the trust boundary
- One deploy story (`wrangler deploy`)
- Cloudflare Workers can do WebCrypto signature verification natively
- The existing `delete-account` Supabase function is a different shape (one-shot RPC with admin key); StoreKit verification is request-response with side effects

---

## 2.8 Abuse prevention

### Refund-and-rebuy loops (the canonical IAP attack)

User buys 100 credits, spends them, requests Apple refund, Apple grants refund, user has free credits.

**Defense:**

1. On `REFUND` notification, call `clawback_credits(user_id, original_grant_amount, transaction_id)`
2. `clawback_credits` decrements `balance`. **Allow balance to go negative.** Don't clamp at zero — going negative is the signal that the user already spent refunded credits.
3. While `balance < 0`, `spend_credit` returns NULL → user can't make critiques. The next purchase brings them back to positive and unblocks them.
4. Track `lifetime_refunded` separately from `lifetime_consumed`. If `lifetime_refunded / lifetime_purchased > threshold` (say 30%) over a rolling window, set `user_credits.locked_at = now()` and `locked_reason = 'refund_abuse_pattern'`. Locked accounts can't spend even with positive balance — manual review required to unlock.

### Account/device farming for free credits

- Free grants tied to `auth.users.id`, which is tied to Sign in with Apple (per `54d830b`). Apple ID is the abuse perimeter.
- If `is_private_email = true` and `lifetime_purchased = 0`, cap to one free grant period total.
- Per-IP signup throttle (already informally provided by `IP_HOURLY_CAP`; can add explicit one).

### Multi-account credit transfer

Could a user buy credits on one Apple ID, then somehow apply them to a different Supabase account? Defense: `apple_account_token` (a UUID the iOS client sets in `Product.PurchaseOption.appAccountToken`) is bound to the Supabase `user_id` on first purchase. Subsequent purchases under a different `appAccountToken` are rejected. Apple validates the token round-trips — a different Supabase user can't claim someone else's transaction.

### Concurrent-spend race

The `spend_credit` RPC uses `SELECT ... FOR UPDATE`. Concurrent critique requests serialize at the row level; you can't double-spend a single credit even with 100 concurrent requests. This is the property KV cannot give us.

### Refund grief in the Worker

If a `model_error` happens *after* the spend but *before* the refund completes (Worker dies mid-flight), the credit is lost. Mitigation: `pending_refunds` table + retry sweep (§2.3). Loud error log so operationally we notice.

### Replay of old client_request_ids

Already handled by `idempotency:` KV (1h TTL) — same as today. Move the cache check to **before** the spend (it already is in the current code path, keep it that way).

---

## 2.9 Migration plan (existing users)

Current `tier=free` users have an "implicit balance" of 20/day. Existing `tier=pro` users (none in production yet, but soon) have 200/day.

One-time migration on rollout:

- Every existing user gets a one-time grant of 20 credits (matches a free user's daily cap; over-grants compared to fair) with `reason='migration_grant'`
- Set `free_grant_period = current_month` so they don't get a second free grant in the same month
- Comms (in-app notice): "We've simplified how usage works. You now have N credits — each critique uses 1. Buy more anytime."

For the small Pro cohort (handful of beta testers): grant 200 credits, same migration row.

---

## 2.10 Cross-reference to Part 1's token audit

Per §1.5, typical critique cost = **$0.0021–$0.0043**. At $0.05/credit revenue, gross margin is ~12–24×. Comfortable.

### Where a single critique could exceed reasonable cost (and how to handle)

The catastrophic-case row (~$0.0108) assumed `detail: high` vision + max history + max additionalContext. None of these are in production today, but each is one PR away.

**Recommended hard caps in the Worker, post-spend, pre-OpenAI:**

1. **`prompt_tokens` outlier guard.** Pre-flight estimate (or post-call assertion via `tiktoken`-style counting in the Worker) — if estimate > **8,000 input tokens**, reject as `validation_failed` with code `prompt_too_large`, refund the credit. This is ~$0.005/call at gpt-5.1 input rates and wildly larger than anything legitimate today.

2. **`detail: high` decoupled from credit cost.** If we ever set `detail: high` (e.g. a "deep critique" mode), make it cost more credits up front (e.g., 3 credits) — encoded in the request payload and validated server-side. Don't let any code path enable high-detail at 1 credit.

3. **Output cap stays per-tier.** Free 1,000, Pro 1,500. Don't raise without re-pricing.

4. **Per-month per-user cost ceiling (defense in depth).** Sum `feedback_requests.prompt_token_count + completion_token_count` for the user this month; if cost > $5 and `lifetime_purchased = 0`, lock spending. This catches anyone who somehow triggers the outlier path 1,000 times in a row on free credits.

5. **Daily global spend cap stays.** Raise to $25 with credits absorbing most cost; it's the blast-radius limiter.

### When to re-price credits

Trigger a credit-pricing review if any of these ship:

- Model swap (gpt-5.1 → o1-preview, gpt-5.5, etc.). Costs can swing 5×.
- Image `detail: high` becomes default.
- Output cap raised.
- History window expanded (e.g., Pro to 10 priors).

The pricing constants in `cloudflare-worker/index.js:1178–1179` are the single point to update for cost computation; the credit-pack prices in App Store Connect are the single point to update for revenue. Keep both in sync via a comment cross-reference.

---

# Open questions for the implementation phase

1. Sandbox vs production StoreKit environments — the JWS payload's `environment` field tells you which; the Worker needs a config flag to pick the right Apple root cert and reject mismatches. Confirm we're OK rejecting sandbox transactions in the production Worker.
2. Credit balance display in the iOS app — needs a new lightweight `GET /credits/balance` endpoint or a Postgres query (RLS allows it directly, no Worker hop required). Direct Postgres read is simpler.
3. "Out of credits" UX — needs a paywall sheet that lists the three packs and triggers `Product.purchase()`. Out of scope here, but the Worker contract for "no credits" should be a stable error code (`code: 'no_credits'`) so the client can route to the paywall reliably.
4. Test environment for IAP — sandbox testers in App Store Connect plus a dev-only Worker endpoint that grants credits without a receipt for QA. Gate it behind an env-var check.
5. Stale `MEMORY.md` note about `OPENAI_MODEL = 'gpt-4o'` — code reality is `'gpt-5.1'`. Update or delete that memory entry; it'll mislead future cost reasoning.
