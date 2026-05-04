# Project Memory — DrawEvolve

Lightweight index of non-obvious project state that future-me (or future-collaborator) needs to know. Code-derivable facts live in the code; this file captures decisions, intentions, and history.

---

## Iterative coaching lives in the system prompt, not user-role text

As of 2026-05-01, the iterative-coaching principle ("when shown prior critiques, you are continuing a coaching relationship; preserve Focus Area unless student made progress") is encoded in `SHARED_SYSTEM_RULES` inside the system prompt, **not** in the user-role framing.

Earlier iterations had the iteration instruction in the user-role wrapper (`HISTORY_FRAMING_DEFAULT`) only. That was weak — system role wins more often than not, and the user-role framing was insufficient against the model's default behavior of treating each request as a fresh critique. Now both the iteration rule and the new `SUBJECT VERIFICATION` / `CLOSING ASIDE — STRICT REQUIREMENTS` blocks are in the system prompt; user-role text is just `"Prior critiques on this drawing, oldest first:"` followed by the critiques and the trailer.

If a future change moves iteration logic back to user-role text, the failure modes (silently absorbing subject drift, dropping prior Focus Area on any new image) are likely to return.

See: `cloudflare-worker/index.js` — `SHARED_SYSTEM_RULES`, `HISTORY_FRAMING_DEFAULT`, `buildUserMessage`.

---

## Worker model is gpt-5.1

`OPENAI_MODEL = 'gpt-5.1'` (`cloudflare-worker/index.js:1148`). The earlier swap attempt that returned 400 was diagnosed (flat `reasoning_effort` field, `max_completion_tokens` instead of `max_tokens`, value `'none'` not `'minimal'`) and the swap is now in production — see commits `9b4297e`, `7947a79`, `b982eaf`.

Cost constants in the Worker reflect gpt-5.1 pricing: `COST_PER_INPUT_TOKEN_USD = 0.63 / 1_000_000`, `COST_PER_OUTPUT_TOKEN_USD = 5.00 / 1_000_000` (`index.js:1178–1179`). If the model changes again, update both constants in the same commit as the model swap or the daily spend cap math will silently mis-account.

Permanent error-body logging on non-ok OpenAI responses is in place — any future swap failure surfaces OpenAI's actual error message in `wrangler tail`.

---

## What lives where

- `cloudflare-worker/` — Cloudflare Worker that mediates between the iOS app and OpenAI; owns auth (Supabase JWT), rate limits, ownership checks, prompt assembly, critique persistence.
- `DrawEvolve/` — iOS app (SwiftUI + Metal). PencilKit canvas at 2048×2048, exports JPEG @ 0.8 compression to the Worker.
- `supabase/migrations/` — Postgres schema. RLS enforced on user-facing tables; service_role used only by the Worker.
- `KNOWN_ISSUES.md` — small bugs / divergences / TODOs not blocking v1.
- `CUSTOM_PROMPTS_PLAN.md` — design doc for per-drawing custom prompts (post-TestFlight).
- `authandratelimitingandsecurity.md` — auth + rate-limiting + security implementation notes.
- `PERF_ISSUES.md` — performance issues queue.
- `PIPELINE_FEATURES.md` — feature pipeline.

---

## App Attest is layered on top of JWT, not a replacement

Phase 5f wires Apple App Attest as a second factor alongside Supabase JWT. JWT proves who the user is; App Attest proves the request comes from a real DrawEvolve install on a real Apple device. **Both must pass** for any protected request — the worker rejects with a stable `attest_*` error code when only JWT validates.

`APPLE_ATTEST_ROOT_PUBKEY_HEX` in `cloudflare-worker/middleware/app-attest.js` is intentionally empty. `/attest/register` fail-closes with HTTP 500 `attest_root_not_pinned` until the operator pastes the Apple App Attest Root CA's uncompressed P-384 public key (extraction recipe is in `cloudflare-worker/DEPLOYMENT.md` — Phase 5f section). This is a deliberate gate: a deploy that forgot the root pin would otherwise silently accept forged attestations. The pubkey lives as a source constant — not a wrangler env var — so a deploy can never accidentally pair the wrong root with the wrong worker version.

iOS-side, App Attest only works on real hardware (`DCAppAttestService.shared.isSupported == false` on the simulator). Test on device, not in the simulator.

---

## Social — Phase A (profiles foundation) is landed

As of 2026-05-04, social Phase A per `ONLINEIMPLEMENTATIONPLANS.md` §11 is in: `supabase/migrations/0006_profiles.sql` + `cloudflare-worker/routes/profiles.js`. **Migration is `0006`, not `0008`** — the planning doc's `0008` was defensive renumbering against a collision that didn't materialize. Future social migrations continue sequentially (custom prompts extension would be `0007`, posts `0008`, etc.).

What's now available server-side:

- `public.profiles` table (one row per `auth.users`, auto-created via after-insert trigger).
- Worker is the sole writer. iOS reads through the Worker (Q8 default), not direct PostgREST.
- Endpoints: `GET /v1/me`, `PATCH /v1/profiles/me`, `POST /v1/profiles/me/avatar`, `GET /v1/profiles/:username`, `GET /v1/profiles/search`. All gated by JWT + App Attest.
- `avatars` bucket: public-read, write-RLS keyed off `storage.foldername(name)[1] = auth.uid()::text`.

Resolved planning questions (defaults baked in):
- **Q1 / Q2:** username is auto-generated at signup (`user_<8 hex>`) and renamable exactly once. The lock is `profiles.username_set_at` — non-null = immutable. The Worker stamps it on the first PATCH that includes a username; subsequent username PATCHes return `409 username_immutable`. Adding `username_set_at` is a small extension to the §2.1 schema; without it the gate would have to regex-detect the auto-generated form, which collides with legitimate user_xxxxxxxx handles.
- **Q4:** `GET /v1/profiles/:username` resolves `is_searchable=false` profiles by exact handle (search hides them). 404 only when `is_public=false` and the requester isn't the owner — surfaced as not-found rather than 403 so private accounts don't reveal their existence via differential status codes.
- **Q8:** Worker-brokered reads, not direct Supabase REST from iOS.

iOS work for Phase B (profile editing UI, ProfileView, username one-time-set gate UX) is the next sprint and intentionally not in the Phase A PR. The backend already supports everything Phase B needs.
