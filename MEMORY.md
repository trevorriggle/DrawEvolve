# Project Memory — DrawEvolve

Lightweight index of non-obvious project state that future-me (or future-collaborator) needs to know. Code-derivable facts live in the code; this file captures decisions, intentions, and history.

---

## Iterative coaching lives in the system prompt, not user-role text

As of 2026-05-01, the iterative-coaching principle ("when shown prior critiques, you are continuing a coaching relationship; preserve Focus Area unless student made progress") is encoded in `SHARED_SYSTEM_RULES` inside the system prompt, **not** in the user-role framing.

Earlier iterations had the iteration instruction in the user-role wrapper (`HISTORY_FRAMING_DEFAULT`) only. That was weak — system role wins more often than not, and the user-role framing was insufficient against the model's default behavior of treating each request as a fresh critique. Now both the iteration rule and the new `SUBJECT VERIFICATION` / `CLOSING ASIDE — STRICT REQUIREMENTS` blocks are in the system prompt; user-role text is just `"Prior critiques on this drawing, oldest first:"` followed by the critiques and the trailer.

If a future change moves iteration logic back to user-role text, the failure modes (silently absorbing subject drift, dropping prior Focus Area on any new image) are likely to return.

See: `cloudflare-worker/index.js` — `SHARED_SYSTEM_RULES`, `HISTORY_FRAMING_DEFAULT`, `buildUserMessage`.

---

## Worker model is gpt-4o, with gpt-5.1 plumbing parked

`OPENAI_MODEL` is currently `'gpt-4o'`. A gpt-5.1 swap was attempted, returned 400, and was rolled back. `OPENAI_REASONING_EFFORT = 'none'` constant is parked in code but **not wired into the request body** (gpt-4o rejects the `reasoning` field). When the next reasoning-capable model attempt happens, restore `reasoning: { effort: OPENAI_REASONING_EFFORT }` to the request body alongside the model swap.

Permanent error-body logging on non-ok responses is in place — any future swap failure will surface OpenAI's actual error message in `wrangler tail`.

---

## What lives where

- `cloudflare-worker/` — Cloudflare Worker that mediates between the iOS app and OpenAI; owns auth (Supabase JWT), rate limits, ownership checks, prompt assembly, critique persistence.
- `DrawEvolve/` — iOS app (SwiftUI + Metal). PencilKit canvas at 2048×2048, exports JPEG @ 0.8 compression to the Worker.
- `supabase/migrations/` — Postgres schema. RLS enforced on user-facing tables; service_role used only by the Worker.
- `KNOWN_ISSUES.md` — small bugs / divergences / TODOs not blocking v1.
- `CUSTOM_PROMPTS_PLAN.md` — design doc for per-drawing custom prompts (post-TestFlight).
- `authandratelimitingandsecurity.md` — auth + rate-limiting + security implementation notes.

---

## App Attest is layered on top of JWT, not a replacement

Phase 5f wires Apple App Attest as a second factor alongside Supabase JWT. JWT proves who the user is; App Attest proves the request comes from a real DrawEvolve install on a real Apple device. **Both must pass** for any protected request — the worker rejects with a stable `attest_*` error code when only JWT validates.

`APPLE_ATTEST_ROOT_PUBKEY_HEX` in `cloudflare-worker/index.js` is intentionally empty. `/attest/register` fail-closes with HTTP 500 `attest_root_not_pinned` until the operator pastes the Apple App Attest Root CA's uncompressed P-384 public key (extraction recipe is in `cloudflare-worker/DEPLOYMENT.md` — Phase 5f section). This is a deliberate gate: a deploy that forgot the root pin would otherwise silently accept forged attestations.

iOS-side, App Attest only works on real hardware (`DCAppAttestService.shared.isSupported == false` on the simulator). Test on device, not in the simulator.
- `PERF_ISSUES.md` — performance issues queue.
- `PIPELINE_FEATURES.md` — feature pipeline.
