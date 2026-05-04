-- Custom prompts — bounded-knob parameters (product-level customization).
-- =========================================================================
-- How to apply:
--   1. Open the Supabase dashboard for project `jkjfcjptzvieaonrmkzd`.
--   2. SQL Editor → + New query → paste this file → Run.
--   3. Re-runnable safely (every statement is idempotent or guarded).
--
-- Why this migration is 0009 and not 0006:
--   0006/0007 are taken by other in-flight work; 0008 is reserved for the
--   profiles sprint running in parallel. Land this as 0009 so the file
--   numbers stay monotonic and the parallel branches don't collide.
--
-- What it does:
--   - Adds custom_prompts.parameters jsonb (the bounded-knob payload:
--     focus / tone / depth / techniques). Default '{}' so existing rows
--     (which were authored under the freeform-body model in 0005) backfill
--     to "no parameters set".
--   - Adds custom_prompts.template_version int (which prompt-template
--     version the row was authored against — enables drift detection in
--     the editor UI later, harmless to the request path today).
--   - Drops the NOT NULL constraint on custom_prompts.body. New rows
--     authored via the bounded-knobs UI carry `parameters` only and have
--     no body. Old rows from 0005 keep their body and continue to work via
--     selectVoice's freeform-body path.
--
-- What it does NOT do:
--   - Add a CHECK constraint on parameters' shape. The Worker's
--     validatePromptParameters() is the source of truth — DB-level CHECK
--     would fight forward-compat (new knobs would require a migration to
--     extend the CHECK every time).
--   - Backfill parameters from existing body text. The two storage models
--     are independent: legacy bodies stay as voices, new rows carry knobs.
--
-- Design rationale and the long-form trade study live in CUSTOMPROMPTSPLAN.md
-- at the repo root. Key choices encoded here:
--   - Parameters as a jsonb column (validated server-side, not by CHECK)
--     for forward-compat with future knobs.
--   - body becomes nullable so the parameters-only flow is first-class
--     rather than carrying a dummy server-rendered string.
--   - template_version on the row (not just on critique entries) so the
--     editor can detect "authored against template v1, current is v2"
--     drift without scanning critique_history.

-- =========================================================================
-- 1. parameters jsonb
-- =========================================================================
-- Stores the bounded-knob payload. NOT NULL with default '{}' so every
-- row has a definite shape — code paths can safely Object.entries() the
-- value without null-checking. Worker's validatePromptParameters() is the
-- single source of truth on shape.

alter table public.custom_prompts
    add column if not exists parameters jsonb not null default '{}'::jsonb;


-- =========================================================================
-- 2. template_version int
-- =========================================================================
-- Records which prompt-template version (PROMPT_TEMPLATE_VERSION in
-- cloudflare-worker/lib/prompt.js) the row was authored against. The
-- request path always renders fragments from the *current* template, so
-- this column is metadata only — used by the editor to surface drift to
-- the user, never by the prompt-assembly pipeline.

alter table public.custom_prompts
    add column if not exists template_version int not null default 1;


-- =========================================================================
-- 3. body becomes nullable
-- =========================================================================
-- Bounded-knobs custom prompts have no body. Legacy rows from 0005 keep
-- theirs (and continue to work via selectVoice's freeform-body path).
-- The 2000-char CHECK stays — it's still active when body is non-null.

alter table public.custom_prompts
    alter column body drop not null;


-- =========================================================================
-- 4. deleted_at for soft-delete
-- =========================================================================
-- DELETE /v1/prompts/:id stamps deleted_at instead of removing the row.
-- Two reasons: (a) recovery from user mistakes, (b) preserving the row so
-- past critiques that recorded preset_id = custom:<uuid> still reference
-- a real row when audited. List endpoints filter `deleted_at is null`;
-- the request path's selectVoice / selectCustomPromptParameters intentionally
-- DO NOT filter on deleted_at — a critique whose source prompt is soft-
-- deleted should still resolve, since the user could be partway through a
-- request when they delete elsewhere.

alter table public.custom_prompts
    add column if not exists deleted_at timestamptz default null;

create index if not exists custom_prompts_user_id_active_idx
    on public.custom_prompts (user_id)
    where deleted_at is null;
