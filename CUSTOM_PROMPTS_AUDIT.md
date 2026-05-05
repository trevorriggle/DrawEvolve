# Custom Prompts — Smoke Audit

Read-only audit of the bounded-knob custom prompts feature shipped untested.
Scope: `cloudflare-worker/routes/prompts.js`, `cloudflare-worker/lib/prompt.js`,
`DrawEvolve/DrawEvolve/Models/CustomPrompt.swift`,
`DrawEvolve/DrawEvolve/Services/CustomPromptManager.swift`,
`DrawEvolve/DrawEvolve/Views/PromptEditView.swift`,
`DrawEvolve/DrawEvolve/Views/PromptListView.swift`. Cross-references:
`CUSTOMPROMPTSPLAN.md`, `cloudflare-worker/routes/feedback.js`,
`cloudflare-worker/test.mjs`, `supabase/migrations/0005_*.sql`,
`supabase/migrations/0009_custom_prompts_parameters.sql`.

Audit date: 2026-05-05. Branch: `trevorriggle/custom-prompts-smoke-audit`.
No code touched.

---

## TL;DR

No critical (🚨) findings. The bounded-knob pipeline is well-built: enum
validation is defense-in-depth (validate-on-write **and** validate-on-read),
the assembly path is unit-tested through `lib/prompt.js`, and the
iOS↔Worker contract is consistent.

Two ⚠️ items deserve attention before broad rollout:

1. **No rate limit on the `/v1/prompts/*` CRUD endpoints.** Every other
   user-state-mutating route lives behind `enforceRateLimits`; this one
   does not. A determined user can spam-create rows up to whatever
   App Attest's counter throughput allows.
2. **No iOS handler-level test coverage** for any of the five new
   endpoints — the pure assembly functions in `lib/prompt.js` are well
   covered, but `routes/prompts.js` (auth gate, dispatch, CRUD against
   PostgREST, soft-delete idempotency) has zero test coverage in
   `cloudflare-worker/test.mjs`.

Plus a handful of UX paper cuts and a versioning gap (the
`prompt_template_versions` and `custom_prompt_versions` tables from
`CUSTOMPROMPTSPLAN.md` §4 were never created — the column exists but
has no consumer).

---

## 1. Security boundary integrity

**Verdict: ✅ for the documented surface, with a ⚠️ defense-in-depth note.**

### What works

- The CRUD surface in `routes/prompts.js` accepts only `name` +
  `parameters`. The legacy `body` column is intentionally not exposed
  (`routes/prompts.js:14-17, 173, 197-198`).
- Every `parameters` write goes through `validatePromptParameters`
  (`routes/prompts.js:246, 283`). The validator silently drops unknown
  keys and unknown enum values
  (`cloudflare-worker/lib/prompt.js:534-565`); only documented enum
  values from `FOCUS_OPTIONS` / `TONE_OPTIONS` / `DEPTH_OPTIONS` /
  `TECHNIQUE_OPTIONS` survive.
- Validate-on-read: `selectCustomPromptParameters` re-runs
  `validatePromptParameters` on the row at request time
  (`cloudflare-worker/lib/prompt.js:642-644`), so even if a future
  Worker writes a knob this Worker doesn't recognize, it gets narrowed
  before rendering.
- `renderCustomPromptModifier` only emits fragments from frozen,
  server-defined string maps — `FOCUS_FRAGMENTS`, `TONE_FRAGMENTS`,
  `DEPTH_FRAGMENTS`, `TECHNIQUE_FRAGMENTS`
  (`cloudflare-worker/lib/prompt.js:492-523`). No user input ever ends
  up as the rendered text, only as a key into these maps. Unknown keys
  yield no fragment (`cloudflare-worker/lib/prompt.js:577-595`).
- `routes/prompts.js` filters every PostgREST call by `user_id` even
  though it uses the service-role key (`routes/prompts.js:142, 154,
  190, 211`). RLS is bypassed but the WHERE-clause scoping is
  defense-in-depth.

### ⚠️ The bounded-knobs guarantee leaks one layer down

The CRUD endpoint never lets a user write `body`. But the underlying
`custom_prompts` row-level security policy from
`supabase/migrations/0005_preset_voices_and_custom_prompts.sql:166-168`
is column-agnostic:

```
create policy "users insert own custom_prompts"
    on public.custom_prompts for insert
    with check (auth.uid() = user_id);
```

Nothing in the policy restricts which columns a user can write. A user
holding a valid Supabase JWT can still curl PostgREST directly with the
anon key and insert a row with `body` populated. Worker code-paths
specifically prefer `body` over the bounded-knobs path:

- `cloudflare-worker/lib/prompt.js:411-420` — if `body` is a non-empty
  string, `selectVoice` returns it as the voice **instead of**
  `VOICE_STUDIO_MENTOR`. The bounded-knob `parameters` then ride on top
  via `selectCustomPromptParameters`. Net effect: a user-supplied body
  runs as the voice for that user's own critique.

This is single-user / self-inflicted (RLS prevents writing to another
user's row), and the long-form spec explicitly accepts the freeform-
body path with mitigations (2000-char cap, `SHARED_SYSTEM_RULES`
positioned after the voice; see `CUSTOMPROMPTSPLAN.md` §2.1). It is
**not** a privilege-escalation or cross-tenant vulnerability. But the
prose comments in `routes/prompts.js:10-17` ("Every input that ends up
in the OpenAI prompt is server-controlled") read as a stronger
guarantee than the system actually enforces — the guarantee holds for
inputs that pass through the Worker, not for inputs that reach
`custom_prompts` via direct PostgREST.

If shipping a strong-guarantee bounded-knobs surface is the goal,
options are (a) a column-level RLS that prevents user writes to
`body`, (b) a Postgres trigger that nulls `body` on user-scoped
inserts, or (c) flipping `selectVoice` to ignore `body` entirely on
post-0009 rows. None are required for v1; flagging because the comment
overstates the invariant.

### Other

- UUID format on `:id` is validated with a strict regex
  (`routes/prompts.js:46-50, 359`); malformed IDs 400 before any
  PostgREST hit.
- `name` is `trim()` + non-empty + ≤50 char checked
  (`routes/prompts.js:52-58`); the DB's `char_length(name) <= 50`
  CHECK constraint
  (`supabase/migrations/0005_preset_voices_and_custom_prompts.sql:140`)
  is defense-in-depth.
- No request-body size cap on the Worker side. Cloudflare's default
  100 MB cap applies, so this is bounded by the platform, but a
  1 MB malformed-JSON POST still triggers an App Attest verification
  before the parse fails. Not a security issue, just a minor wasted-
  cycles concern.

---

## 2. Assembly logic correctness

**Verdict: ✅ correct end-to-end, with one ⚠️ contradiction worth knowing.**

### Composition order

`buildSystemPrompt` (`cloudflare-worker/lib/prompt.js:193-215`) joins
sections in this order:

1. `config.systemPrompt` — voice + `SHARED_SYSTEM_RULES`
   (set by `assembleSystemPrompt(voice)` in
   `routes/feedback.js:667`).
2. `SKILL LEVEL CALIBRATION:` block
   (`cloudflare-worker/lib/prompt.js:197`).
3. `CONTEXT (use what's provided, ignore empty fields):` block.
4. `RESPONSE FORMAT — follow this structure exactly:` template,
   skill-level branched
   (`cloudflare-worker/lib/prompt.js:112-137, 199`).
5. `ADDITIONAL STYLE GUIDANCE (per user preference):` (Pro tier
   only; sourced from JWT `app_metadata.prompt_preferences`)
   (`cloudflare-worker/lib/prompt.js:201-203`).
6. `PROMPT CUSTOMIZATION (per saved prompt):` if the bounded-knob
   modifier renders non-null
   (`cloudflare-worker/lib/prompt.js:208-213`).

The custom-prompt section is correctly placed last, picking up the
late-in-prompt weighting noted in `CUSTOMPROMPTSPLAN.md` §2.1. The
ordering is unit-tested at
`cloudflare-worker/test.mjs:3439-3453` ("PROMPT CUSTOMIZATION should
follow ADDITIONAL STYLE GUIDANCE").

### Voice selection × knobs interaction

`routes/feedback.js:642-669` resolves three things in sequence:

1. `resolvePresetId` (`lib/prompt.js:317-359`) — verifies the
   `custom:<uuid>` exists and belongs to the user. Hardcoded
   preset IDs short-circuit with no DB hit.
2. `selectVoice` (`lib/prompt.js:377-425`) — fetches `body` for
   `custom:<uuid>`; falls back to `VOICE_STUDIO_MENTOR` if `body` is
   empty (which is the bounded-knob case per migration 0009 — `body`
   is null after that migration).
3. `selectCustomPromptParameters` (`lib/prompt.js:612-649`) —
   fetches `parameters`; returns `{}` for hardcoded preset IDs.

For the bounded-knobs flow (the new product surface), `selectVoice`
*always* returns `VOICE_STUDIO_MENTOR` because the row's `body` is
null (`supabase/migrations/0009_custom_prompts_parameters.sql:76-77`).
The `parameters` jsonb is then layered on top. This is by design and
documented at `cloudflare-worker/lib/prompt.js:412-419`.

**⚠️ Implication: bounded-knob custom prompts always run on the
`VOICE_STUDIO_MENTOR` base.** The user has no way to pick "the_crit"
or "fundamentals_coach" as the base voice for their custom prompt,
even though `CUSTOMPROMPTSPLAN.md` §3.2 ("Quick — pick a base voice
(the four built-ins or any custom), then a small set of bounded
knobs…") specifies that base-voice picking should be part of the
authoring UI. The iOS `PromptEditView` has no base-voice picker
(`DrawEvolve/DrawEvolve/Views/PromptEditView.swift:39-122` — the form
only has Name, Critique focus, Tone, Depth, Technique emphasis).
Today this means every custom prompt runs studio-mentor + knobs;
users who want "rigorous + the_crit's persona" can only pick
`the_crit` from the four-preset list, and that path doesn't carry
their saved knobs.

Not a correctness bug — what ships is consistent — but the spec→ship
delta is worth tracking.

### Contradictory length instructions

`RESPONSE_FORMAT_TEMPLATE` ends with the line
`Stay within ~700 words. Be dense and specific.`
(`cloudflare-worker/lib/prompt.js:136`). The `depth` knob fragments
say `aim for ~250 words total` (brief) or `aim for ~1100 words`
(deep_dive) (`cloudflare-worker/lib/prompt.js:511-513`). Both end up
in the assembled prompt — depth lands in the `PROMPT CUSTOMIZATION`
block at the very end, and the response format template earlier.

**⚠️ Contradiction.** Late-in-prompt weighting *should* mean the
depth fragment wins, but the model is reading two contradictory
instructions about word count. Two fixes worth considering:

- Have the response-format template branch on depth the same way it
  branches on `skillLevel` (`lib/prompt.js:112-117`), so the format
  string itself reads "Stay within ~250 words" / "~700 words" /
  "~1100 words" depending on the knob. The depth fragment then
  wouldn't have to override anything.
- Or make the depth fragment's prose explicitly authoritative
  ("Override the ~700 word target above and aim for ~1100 words").

Not a bug — the AI generally respects the later instruction in
practice — but the prompt is worse than it needs to be.

### Other

- `customPromptModifier` is captured into the persisted critique
  snapshot (`routes/feedback.js:281-286`,
  `test.mjs:3538-3568`). Reproducibility of past critiques is
  preserved.
- `selectCustomPromptParameters` skips the DB hit for hardcoded
  preset IDs (`lib/prompt.js:613-615`,
  test at `test.mjs:3455-3463`).
- Both `selectVoice` and `selectCustomPromptParameters` re-filter on
  `user_id` even though `resolvePresetId` already verified ownership
  (`lib/prompt.js:398, 624`). Belt-and-suspenders is correct here.

---

## 3. Versioning correctness

**Verdict: ⚠️ partial implementation. Not broken, but the spec's drift-detection UX has no consumer.**

### What's implemented

- `PROMPT_TEMPLATE_VERSION = 1` constant
  (`cloudflare-worker/lib/prompt.js:457`).
- `custom_prompts.template_version` column, defaults to 1
  (`supabase/migrations/0009_custom_prompts_parameters.sql:65-66`).
- Inserts and updates stamp the row's `template_version` with the
  Worker's current `PROMPT_TEMPLATE_VERSION`
  (`routes/prompts.js:176, 286-289`). The PATCH path correctly
  refreshes `template_version` only when `parameters` change, not on
  name-only edits.
- iOS decodes `template_version` from the wire row
  (`DrawEvolve/DrawEvolve/Models/CustomPrompt.swift:127, 135`).

### What's not implemented

- **`prompt_template_versions` table from `CUSTOMPROMPTSPLAN.md` §4.3
  doesn't exist.** No migration creates it. The Worker has no
  consumer that reads from it, so its absence is fine for now — the
  Worker always renders the *current* fragments anyway
  (`lib/prompt.js:208-213`, no version branching). But the spec's
  forward-looking design ("Worker reads the active template at request
  time") cannot land without this table.
- **`custom_prompt_versions` table from §4.2 doesn't exist.** Edits
  are destructive; no row-history log. The "see what this voice was on
  critique #4" UX (§6.1) is not reachable from the data model. This is
  fine for the bounded-knobs case where edits are low-stakes (knob
  flips, not prose rewrites), but it does mean a user who edits a
  prompt cannot recover the prior version.
- **No drift detection in `PromptEditView`.** The spec calls for the
  editor to surface "authored against template v1, current is v2"
  when the row's `template_version` lags
  (`CUSTOMPROMPTSPLAN.md` §6.2). `PromptEditView.swift` reads
  `templateVersion` via the row but never compares it against a
  client-side constant. There is no client-side mirror of
  `PROMPT_TEMPLATE_VERSION`.

### What happens at template bump

Today (template v1, no v2 in flight): nothing happens, because there's
no v2. If/when `PROMPT_TEMPLATE_VERSION` bumps:

- Existing rows keep their old `template_version`.
- New writes from the bumped Worker stamp the new version.
- The Worker renders current-version fragments regardless of the
  row's stored value — `selectCustomPromptParameters` /
  `renderCustomPromptModifier` never branch on `template_version`
  (`lib/prompt.js:612-649, 575-598`).
- iOS doesn't know to surface drift, because it has no v2 constant
  to compare against.

So the system gracefully degrades to "version is metadata only," which
is exactly what the migration comment states
(`supabase/migrations/0009_custom_prompts_parameters.sql:60-63`). No
user-visible breakage; just no drift UX. This matches today's product
need (one template version, no drift) but doesn't match the spec's
v1+drift roadmap.

---

## 4. iOS UX issues

**Verdict: ⚠️ multiple paper cuts, none blocking. No "preview before save," which the spec calls "make-or-break."**

### Walkthrough as a new user

1. **Discovery.** From the gallery's "My Prompts" tab, a user sees
   the four hardcoded preset rows
   (`DrawEvolve/DrawEvolve/Views/GalleryView.swift:228-260`) and a
   "Saved prompts" navigation row below them
   (`GalleryView.swift:264-279`). The "Saved prompts" row's
   subtitle is "Tune focus, tone, depth, and techniques" — which
   doesn't tell the user that tapping a saved prompt *replaces* the
   preset selection. The selection coupling between the two
   screens is not obvious.
2. **Empty state.** First-time visitor sees the wand-and-stars
   empty state and a "+ New Prompt" button
   (`PromptListView.swift:135-160`). Clear.
3. **Authoring.** `PromptEditView` shows a Name field, then Critique
   focus / Tone / Depth single-select pickers, then Technique
   emphasis multi-select (`PromptEditView.swift:39-122`). Each
   section has a footer explaining what it does. Reasonable.
4. **Save.** Save is enabled iff name is non-empty
   (`PromptEditView.swift:117, 124-126`). On success, dismiss; on
   failure, show error inline
   (`PromptEditView.swift:170-172`). Reasonable.
5. **Selecting.** Back in the list, tapping a row writes
   `selectedPresetID = "custom:<uuid>"` into `@AppStorage`
   (`PromptListView.swift:62`). A checkmark moves to the selected
   row (`PromptListView.swift:112-114`).
6. **Using.** Next critique request reads
   `selectedPresetID` from `UserDefaults`
   (`DrawEvolve/DrawEvolve/Services/OpenAIManager.swift:130, 148`)
   and sends it as `preset_id`. ✓
7. **Editing / deleting.** Swipe-trailing reveals Delete (red,
   destructive) and Edit (blue) buttons
   (`PromptListView.swift:67-88`). Standard iOS pattern. Deleting
   the currently-selected row falls back to `studio_mentor`
   (`PromptListView.swift:74-77`). Good.

### ⚠️ Specific concerns

- **No preview of assembled prompt.** The user cannot see what their
  knobs actually do until they save → select → leave the screen → go
  to canvas → request feedback. `CUSTOMPROMPTSPLAN.md` §3.2 calls
  preview "the make-or-break for all three modes." Not implemented.
  A read-only "Preview" expandable section showing the bullet-list
  of fragments would be a small addition that closes the loop.
- **"Default" vs "Balanced" / "Standard" overlap.** The Tone picker
  shows `Default` *and* `Balanced` as separate options
  (`PromptEditView.swift:128-140` + the "Default" `nil` tag at
  line 134). They're functionally similar — `tone=balanced`
  renders the "Stay balanced. Honest assessment delivered with
  measured warmth. Default critique posture." fragment
  (`lib/prompt.js:505`); `tone=nil` renders nothing. The difference
  matters at the prompt level (one explicit instruction vs none),
  but the labels don't communicate it. Same pattern for Depth
  (`Default` vs `Standard (~700 words)`). The list summary makes
  this visible by hiding `balanced` and `standard` from the row
  preview (`PromptListView.swift:127-128`), so a row with only
  `tone=balanced` set displays "Default settings" — confusing.
- **Empty saves are accepted.** Server-side, `parameters: {}` is
  valid (`validatePromptParameters` returns `{ value: {} }` for
  empty input — `lib/prompt.js:535`). Client-side,
  `PromptEditView.canSave` only requires a non-empty name. A user
  can create "My Custom Prompt" with zero knobs set; selecting it
  produces studio-mentor output indistinguishable from the default
  preset. The user's intent (custom = different) doesn't match the
  result. A warning ("Pick at least one knob, or this prompt will
  match the default voice") would prevent the surprise.
- **No base-voice picker.** Per §2 above. All bounded-knob prompts
  run on `VOICE_STUDIO_MENTOR`. The spec called for a fork-from-
  voice picker. Worth a banner in `PromptEditView` clarifying
  "This prompt customizes the Studio Mentor voice — to use a
  different base voice, pick it from the four presets."
- **Selection is invisible from `GalleryView`.** When
  `selectedPresetID = "custom:<uuid>"`, the "My Prompts" four-preset
  list shows no checkmark on any row, and the "Saved prompts" row
  doesn't show "currently selected: <name>". A user opening
  `GalleryView` after selecting a custom prompt has no immediate
  signal which voice is active. Showing a small "Active: <name>"
  label on the Saved prompts row would resolve it.
- **Form-field labels say "title", picker says "title"** — checked
  this isn't a bug; `enumPicker` uses the title both as the row
  label and the menu trigger (`PromptEditView.swift:128-140`). Fine.
- **No timestamps on rows.** With many prompts, "last edited"
  would help. Low priority.
- **No `confirmationDialog` on delete.** Swipe-to-delete in
  `PromptListView.swift:67-88` deletes immediately on tap (server
  soft-deletes, but the row vanishes from the list). Soft-delete is
  recoverable on the server, but there's no recovery UI. Minor.

### What works well

- Loading state, empty state, error footer, refreshable list — all
  standard SwiftUI affordances done correctly
  (`PromptListView.swift:26-55, 89-94, 135-160`).
- Lenient decoding so an unknown enum value from a future Worker
  doesn't crash the list (`CustomPrompt.swift:104-114`). Mirrors the
  Worker's validate-and-narrow posture cleanly.
- Techniques are persisted in canonical `TECHNIQUE_OPTIONS` order so
  two devices editing the same prompt produce equal payloads
  (`PromptEditView.swift:155-159`). Good.
- Falling back to `studio_mentor` on delete-of-selected
  (`PromptListView.swift:74-77`).

---

## 5. Auth and rate-limit gating

**Verdict: ⚠️ — JWT + App Attest are wired correctly; no rate limit on the CRUD surface. Spam-creation is unbounded.**

### Auth: ✅

- `routes/prompts.js:71-119` (`authenticate`) is a clean port of the
  feedback.js gate sequence: validate Worker config →
  `validateJWT` → check App Attest headers present → look up the
  attested key → re-derive `clientDataHash` from method + path +
  raw body → `verifyAppAttestAssertion` → update counter via
  `ctx.waitUntil`.
- The body bytes are read once (`routes/prompts.js:332`) so the
  hash matches what the iOS client signed. `request.json()` is
  deliberately not used.
- Method dispatch is owned by the route, not by the top-level
  router (`index.js:74-80`). Each method-path combo gates with a
  405 (`routes/prompts.js:344-364`). ✓
- Cross-user reads/writes/deletes are all WHERE-scoped on `user_id`
  even with the service-role key (`routes/prompts.js:142, 154,
  190, 211`). Defense-in-depth. ✓

### ⚠️ Rate limiting: not applied

`routes/feedback.js:618` runs `enforceRateLimits` before any
PostgREST call; `routes/prompts.js` does not import or call it.
Failure modes a malicious authenticated user could exercise:

- **Unbounded row creation.** No DB-side row cap on `custom_prompts`
  per user (only the `name` and `body` length CHECKs). A scripted
  client could create thousands of rows. PostgREST + Worker time-
  costs scale linearly. The user's own `GET /v1/prompts/me` becomes
  slow after enough rows (no pagination — single PostgREST call
  returns all rows: `routes/prompts.js:141-149`).
- **Storage bloat.** Each row is small but unbounded growth wastes
  space. RLS prevents cross-user impact; the bloat is single-tenant.
- **Worker CPU on every request.** App Attest verification is the
  most expensive operation on the path (~15ms ECDSA verify). At
  1000 requests/sec from a single attested key, the Worker pays for
  every one. App Attest's counter monotonicity prevents replay but
  not high-volume legitimate use.

The rate-limit module already supports per-user counting
(`cloudflare-worker/middleware/rate-limit.js:80-100, TIER_LIMITS`).
Adding `await enforceRateLimits({ env, userId, ip, tier, now })` to
each handler in `routes/prompts.js` after `authenticate` returns
would close this gap. Alternatively, a separate cheaper limit
(e.g. "100 prompt CRUD ops / hour / user") would be appropriate
since these aren't OpenAI-cost calls.

A row-cap per user (e.g. 50 saved prompts) at the DB layer would be
defense-in-depth — UPSERT with a count check, or a trigger.

### Other auth notes

- App Attest counter advance happens inside `ctx.waitUntil`
  (`routes/prompts.js:113`), same as feedback.js. If the client
  sends parallel requests, the in-flight counter could lose updates
  to the same problem the feedback path has — not a regression.
- Diagnostic logging on failure (`console.log('[prompts] JWT
  validation failed', err?.message)` etc.) is consistent with
  feedback.js.

---

## 6. Test coverage

**Verdict: ✅ on `lib/prompt.js`, ⚠️ zero coverage on `routes/prompts.js`.**

### `lib/prompt.js` — well covered

`cloudflare-worker/test.mjs` lines 3270–3569 (a dedicated section
"Custom prompts (product-level) — bounded-knob parameters") cover:

- `PROMPT_TEMPLATE_VERSION` integer invariant
  (`test.mjs:3280-3284`).
- Enum option lock-in — exact contents of `FOCUS_OPTIONS` /
  `TONE_OPTIONS` / `DEPTH_OPTIONS` / `TECHNIQUE_OPTIONS`
  (`test.mjs:3286-3299`).
- `validatePromptParameters` happy paths, null/undefined,
  unknown-enum drops, unknown-key drops, type rejections,
  technique deduping, oversized-array rejection
  (`test.mjs:3301-3370`).
- `renderCustomPromptModifier` empty cases, fragment emission per
  enum, fixed section order, technique-input-order independence
  (`test.mjs:3372-3416`).
- `buildSystemPrompt` integration: section header presence,
  omission when empty/null, ordering vs `styleModifier`
  (`test.mjs:3418-3453`).
- `selectCustomPromptParameters` no-DB-hit for hardcoded preset IDs,
  successful fetch, validate-on-read narrowing, PostgREST non-OK,
  missing env (`test.mjs:3455-3536`).
- `buildCritiqueEntry` snapshots `customPromptModifier` in
  `prompt_config` (`test.mjs:3538-3569`).

This is excellent coverage of the assembly pipeline. The
prompt-injection-via-parameters surface is thoroughly red-teamed
(unknown values, unknown keys, oversized arrays).

### ⚠️ `routes/prompts.js` — uncovered

Searching `cloudflare-worker/test.mjs` for `handlePrompts`,
`handleList`, `handleCreate`, `handleFetch`, `handleUpdate`,
`handleDelete`, `validateName`, `isValidUuid`: **zero matches.**
What's missing:

- **Auth gate.** No test that a missing JWT 401s, that an invalid
  JWT 401s, that missing App Attest headers 401, that
  `attest_env_mismatch` / `attest_assertion_invalid` /
  `attest_key_unknown` paths each yield the documented stable
  error code.
- **Method dispatch.** No test that
  `POST /v1/prompts/me` 405s, that
  `GET /v1/prompts` 405s, that
  `PUT /v1/prompts/:id` 405s, etc. These are part of the
  contract surface.
- **CRUD against PostgREST.** No test that `handleCreate` writes
  the right body shape to PostgREST, that `handleUpdate` produces
  the correct PATCH URL with `user_id=eq.<id>` filter, that
  `handleDelete` writes `deleted_at` and not a hard delete.
- **Cross-user authorization.** No test that user A cannot fetch
  / patch / delete user B's row even with a leaked id.
- **Soft-delete idempotency.** Per the migration comment
  (`migration 0009:84-86`), DELETE on an already-deleted row
  should 404 (the `Prefer=representation` returns zero rows). No
  test asserts this.
- **Invalid UUID 400.** `routes/prompts.js:359` rejects malformed
  IDs. Not tested.
- **`name` validation.** Empty / oversized / non-string name is
  rejected. Not tested.
- **`parameters` malformed.** A POST with parameters that fails
  `validatePromptParameters` returns 400. The validator is
  tested directly, but the integration through `handleCreate` is
  not.
- **Empty patch.** PATCH with `{}` returns 400 with
  `no_fields_to_update` (`routes/prompts.js:290-292`). Not tested.

The plumbing is shallow — most of the work happens in the auth
middleware and PostgREST — but a smoke test that stubs both and
exercises each happy path + the documented failure paths would
catch a class of regressions that the unit tests miss (e.g. someone
flipping the user-id filter direction in a refactor).

### Recommendation for tests to add

In rough priority order:

1. Per-method dispatcher round-trip with a stub `fetcher`: GET
   `/v1/prompts/me` returns the rows; POST `/v1/prompts` writes
   with the right body shape; PATCH/DELETE on a non-owned id
   returns 404.
2. Auth-failure tests: missing/invalid JWT, missing/invalid App
   Attest, each yielding the documented stable error code.
3. Validation: invalid UUID, empty name, oversized name, malformed
   parameters, empty patch.
4. Soft-delete idempotency: DELETE on an already-deleted row
   returns 404; subsequent listings don't include the row.
5. Cross-user isolation: user B's id, user A's row → 404 (because
   the WHERE clause filters by `user_id`).

---

## Recommended follow-ups

Ranked by severity:

### ⚠️ Should fix before broad rollout

1. **Add rate limiting to `/v1/prompts/*`.** Either reuse
   `enforceRateLimits` (likely too aggressive for non-OpenAI
   calls) or add a separate counter (e.g. 100 ops/hour/user). Plus
   a row cap (50 prompts/user) at the DB or app layer. (§5)
2. **Add handler-level test coverage for `routes/prompts.js`.** At
   minimum the auth-failure paths, dispatch 405s, soft-delete
   idempotency, and cross-user 404s. The pure assembly layer is
   well covered; the route layer is not. (§6)
3. **Make the bounded-knobs guarantee match the comment**, or
   amend the comment to admit the freeform `body` path.
   The strongest fix is to prevent user writes to `custom_prompts.body`
   via direct PostgREST — column-level RLS, a trigger that nulls
   `body` on user-context inserts, or flipping `selectVoice` to
   ignore `body` on rows with `template_version >= 1`. (§1)

### ⚠️ UX paper cuts (ship-blocking only if user testing flags them)

4. **Add a "Preview" section to `PromptEditView`** that renders the
   bullet-list of fragments client-side from the same enum-to-
   string mapping the Worker uses. Lets users see what their knobs
   do before saving. The spec calls this make-or-break. (§4)
5. **Resolve the "Default" vs "Balanced/Standard" picker overlap.**
   Either drop the `Default` row from Tone/Depth pickers (forcing
   users to pick a value), or rename `Balanced/Standard` to make
   the difference explicit. Today the list summary hides the
   distinction, which makes the picker look broken. (§4)
6. **Warn on empty saves.** A custom prompt with zero knobs set
   silently behaves like the default. Either disable Save until a
   knob is set, or show a confirmation. (§4)
7. **Surface custom-prompt selection in `GalleryView`.** When a
   `custom:<uuid>` is selected, show "Active: <name>" on the
   Saved prompts row so users don't think nothing is selected. (§4)
8. **Resolve the response-format-vs-depth contradiction.** Branch
   `RESPONSE_FORMAT_TEMPLATE` on depth the same way it branches on
   skill level, so the format string itself reflects the chosen
   word target. (§2)

### ⚠️ Cleanup / spec drift

9. **Add a base-voice picker to `PromptEditView`** (or document
   that bounded-knob prompts always run on studio_mentor and
   amend the spec). The current state silently diverges from
   `CUSTOMPROMPTSPLAN.md` §3.2. (§2, §4)
10. **Decide on the versioning roadmap.** Either land
    `prompt_template_versions` + `custom_prompt_versions` tables
    and the editor's drift UI per the spec, or document that
    `template_version` is permanently metadata-only. The current
    half-state will rot — someone will eventually wonder why the
    column exists. (§3)

### ✅ Nothing in this audit blocks the feature shipping in its current state to a controlled user pool.

The bounded-knob contract is tight, the assembly is correct, the
auth gate matches the rest of the Worker, and the only known
prompt-injection escape is single-user / self-inflicted /
explicitly-acknowledged in the design spec. The combination of (a)
enum-only writes, (b) curated server-side fragments, (c) validate-
on-write and validate-on-read, and (d) the SHARED_SYSTEM_RULES
positioned to win late-in-prompt is a defensible posture.

---

*Audit performed read-only on branch `trevorriggle/custom-prompts-smoke-audit` at 2026-05-05. No source files modified.*
