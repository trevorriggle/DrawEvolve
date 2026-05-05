# Custom Prompts — Implementation Plan

Audit captured 2026-04-30. **Status as of 2026-05-05: most of this plan has shipped. See "What landed" below.** Original plan retained for historical context.

---

## ✅ What landed (post-audit)

The custom-prompts feature shipped across multiple PRs:

- **PR #9 (`c096546` — "Add bounded-knobs custom prompts")** — full product surface for per-user custom prompts (voice text + bounded parameter knobs). Migration `0009_custom_prompts_parameters.sql` adds `parameters jsonb` and `template_version` to `custom_prompts`, drops NOT NULL on `body` (parameters-only flow). Worker resolution wired through the modular `routes/prompts.js`.
- **PR #11 (`ea9a61a` — "Register custom-prompts iOS files in Xcode project")** — iOS pbxproj fix to register the iOS-side prompt management files (`Services/CustomPromptManager.swift`, `Models/CustomPrompt.swift`, `Views/PromptListView.swift`, `Views/PromptEditView.swift`).
- **Migration `0005_preset_voices_and_custom_prompts.sql`** (pre-audit) had already added `user_preferences`, `custom_prompts`, and `drawings.preset_id`.

### Key path corrections vs original plan

- The Worker is now modular (PR #3, `bb00a36`). All the line refs below pointing into `cloudflare-worker/index.js` are stale. Current locations:
  - Prompt assembly + voice resolution: `cloudflare-worker/lib/prompt.js`
  - Critique persistence + `buildCritiqueEntry`: `cloudflare-worker/routes/feedback.js`
  - Custom prompt CRUD: `cloudflare-worker/routes/prompts.js`
- iOS storage class: cloud logic lives in `Services/DrawingStorageManager.swift` (the *class* is `CloudDrawingStorageManager`; the *file* keeps the original name to avoid pbxproj churn). Some early planning text referenced a separate `CloudDrawingStorageManager.swift` file — that file does not exist.

### What did NOT land from this plan

- "Drawings-row column for `custom_prompt`" — the team chose the bounded-knobs surface (PR #9) instead. Per-drawing freeform prompt override is **not shipped** and is no longer the recommended path; see CUSTOMPROMPTSPLAN.md for the bounded-knob alternative which is the live surface.
- "Stuck Detection" (Future section) — not started. Still parked.

The remainder of this doc is the original audit/plan, kept for the trade-study trail. Treat the file-path references as historical.

---

## Summary (historical — pre-PR #9)

The Worker prompt-config refactor is real and well-shaped, but only **half-done** for the custom-prompts feature. `PromptConfig`, `buildSystemPrompt`, and the per-critique persistence (`buildCritiqueEntry`'s `prompt_config` snapshot) are all clean. The `styleModifier` field is wired up end-to-end and works.

**However:** `styleModifier` flows from JWT `app_metadata.prompt_preferences`, not from the request body or the drawings row, and `selectConfig`'s signature plus its test coverage assume that. To add `custom_prompt` cleanly there's roughly a half-day of plumbing decisions and edits before any UI can slot in.

Nothing in the existing code actively fights this feature. The shape is right. The work is in the joints.

### Where styleModifier lives today

- Defined in `PromptConfig` JSDoc at `cloudflare-worker/index.js:7-14`.
- Populated in `selectConfig` from `app_metadata.prompt_preferences.styleModifier` (`index.js:77`) — **Pro-tier only**; Free-tier preferences are silently ignored.
- Spliced into the system prompt as the **last section**, labeled `ADDITIONAL STYLE GUIDANCE`, at `index.js:130-132`. Position matters: late-in-prompt = strongly weighted, so it can effectively override the response-format template and skill calibration that come before it.
- Recorded per-critique in the `prompt_config` snapshot stored in `critique_history` (`index.js:655-659`) — each row remembers the modifier that produced it.

---

## Five decisions to make before implementation

1. **Source of truth for `custom_prompt`** — request body, drawings row, or both with a precedence rule? The Worker does **not** fetch any drawing metadata from the row today; `fetchCritiqueHistory` only selects `critique_history` (`index.js:373`).

2. **Composition with existing `styleModifier`** — if a Pro user has both a JWT-resident `styleModifier` and a per-drawing `custom_prompt`, do they concatenate? Does one win? Each get their own labeled section? `buildSystemPrompt` currently emits one `ADDITIONAL STYLE GUIDANCE` block; supporting two distinct sources means either a second section or a join rule.

3. **Length cap** — `context.additionalContext` is currently unbounded server-side. Adding `custom_prompt` without a cap is a self-inflicted token-budget DoS (Pro user × 200 critiques/day × 50K-char prompt × OpenAI input pricing). Pick a number. **2000 chars** feels right; revisit if user feedback says it's too tight.

4. **Iterative critique semantics** — is `custom_prompt` a property of the drawing or of the critique? Cleanest answer: **drawing**. Old critiques are immutable prose and inherit nothing from later edits; this matches how `styleModifier` already behaves (the per-row `prompt_config` snapshot in `critique_history` preserves the modifier value at the time of generation). UI should not retroactively "update" old critiques when the drawing's prompt is edited.

5. **Schema location** — new `custom_prompt text` column on `drawings`, or a key inside the existing `context jsonb`? **Column wins** for length-cap enforcement and queryability; jsonb wins for schema flexibility. For a single string field destined for the system prompt, column is cleaner.

---

## Concrete touch points (HISTORICAL — paths now stale)

The path/line refs below reflect the pre-PR #3 monolithic `index.js`. The worker now lives in modular files (`routes/`, `middleware/`, `lib/`). This table is preserved for design-trail context only — do not use the line numbers.

| Layer | File (pre-refactor) | Change |
|---|---|---|
| Migration | `supabase/migrations/0005_*.sql` (new) | `ALTER TABLE drawings ADD COLUMN custom_prompt text` |
| Worker config | `cloudflare-worker/index.js:73` (`selectConfig`) | Grow third param for request-side input, OR merge at call site `:894` |
| Worker fetch | `index.js:373` (`fetchCritiqueHistory`) | Add `custom_prompt` to the PostgREST `select` if Worker should read it from the row |
| Worker assembly | `index.js:130-132` (`buildSystemPrompt`) | Decide: second labeled section, or merge into existing `ADDITIONAL STYLE GUIDANCE` |
| Worker persistence | `index.js:655-659` (`buildCritiqueEntry`) | Add `custom_prompt` to the `prompt_config` snapshot so future-us can audit |
| Worker validation | Body-validation block around `index.js:824` | New length cap; reject >2000 chars (or whatever cap is chosen) |
| iOS request | `Services/OpenAIManager.swift:124-138` | Add `custom_prompt` to request body, OR pass as `requestFeedback` parameter (signature change ripples to canvas feedback button call site) |
| iOS storage | Wherever drawings are saved (`Services/DrawingStorageManager.swift`, class `CloudDrawingStorageManager`) | Persist per-drawing custom prompt to the new column |
| Tests | `cloudflare-worker/test.mjs:51, 73, 106, 125, 141, 155-158` | All four `selectConfig` tests need updates if its signature changes |

---

## Footgun: test suite assertions

The Worker test suite binds tightly to `selectConfig`'s current shape:

- `assert.deepEqual(unknownTier, { ...DEFAULT_FREE_CONFIG })` at `test.mjs:142` — asserts the returned object is structurally identical to a clone of the default.
- `test.mjs:155-158` asserts that successive calls return **distinct** objects (so callers can mutate without affecting the next call).

Any signature change to `selectConfig` (e.g. adding a `requestBodyOverrides` parameter) ripples through the four call sites in test.mjs. Not hard. Just on the punch list — and the deepEqual is brittle: if the new field is undefined-by-default rather than absent, the assertion fails even though behavior is unchanged.

---

## Recommended path

**Drawings-row as source of truth. Request-body as override. Second labeled section for `custom_prompt`, distinct from `styleModifier`.**

Rationale:

- **Row as source of truth** matches the iterative-coaching mental model: the prompt belongs to the drawing, not the moment of critique. UI is "edit this drawing's coach prompt"; doesn't need to be re-supplied per request. Gives natural persistence with one source of truth.
- **Request body as override** keeps a clean escape hatch for ephemeral experimentation ("just this one critique, try X") without persisting it. iOS doesn't have to send it most of the time; Worker uses `requestBody.custom_prompt ?? row.custom_prompt ?? null`.
- **Second labeled section** preserves `styleModifier`'s identity for Pro-tier global preferences. Two sections, distinct labels:
  - `ADDITIONAL STYLE GUIDANCE (per user preference):` — the existing section, sourced from JWT, Pro-only
  - `DRAWING-SPECIFIC INSTRUCTION (per drawing):` — new section, sourced from row/body, available to all tiers
  
  This keeps the precedence question answered by ordering: drawing-specific instruction is appended **after** the global style guidance, so it gets late-in-prompt weighting. Matches the intuition that "this drawing" beats "in general."

This path doesn't preclude later consolidation if the two-section approach feels like overkill in practice. Easier to merge two sections later than to split a merged one.

---

## Out of scope for this doc

- The UI itself (text input where? drawing detail screen? part of the "context" sheet?). Design question; not blocked by Worker work.
- Free-tier eligibility for `custom_prompt`. The recommendation above makes it tier-agnostic, but if it should be Pro-gated, that's a separate gate in `selectConfig` or the call site.
- Token-cost surfacing in the UI ("your prompt uses ~N tokens"). Nice-to-have; not in scope.
- Prompt-injection defenses beyond the length cap. The string goes to a chat completion, not a rendered surface, so XSS-style escaping isn't relevant — but consider whether to strip/escape e.g. literal `</system>` tokens. Probably overkill for v1.

---

*Source: prompt-engineering audit run 2026-04-30 against `main`. See conversation history for the full evidence trail.*

---

## Future: Stuck Detection

When the same Focus Area persists across 3+ critiques on the same drawing, modify the prompt to suggest a different angle, a focused study, or stepping away from the drawing. Requires Focus Area extraction (Prompt #4 in the prompt-tactics track) to ship first. Prevents iterative coaching from feeling like grinding when a student is genuinely stuck.
