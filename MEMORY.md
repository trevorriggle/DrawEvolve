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
