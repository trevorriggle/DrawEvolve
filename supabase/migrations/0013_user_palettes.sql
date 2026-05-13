-- Feature 5, Phase 3 — Color System Overhaul: user palettes table.
-- =========================================================================
-- How to apply:
--   1. Open the Supabase dashboard for project `jkjfcjptzvieaonrmkzd`.
--   2. SQL Editor → + New query → paste this file → Run.
--   3. Re-runnable safely (every statement is idempotent or guarded).
--
-- What it does:
--   - Creates public.user_palettes (one row per palette, user-scoped).
--   - Index on (user_id, updated_at desc) partial on deleted_at IS NULL
--     for the list-user-palettes read path.
--   - RLS policies matching the per-user table pattern (drawings /
--     user_preferences / custom_prompts / conversations).
--   - touch_updated_at trigger reusing public.touch_updated_at() from
--     0001_init.sql.
--
-- What it does NOT do:
--   - Seed a "My palette" starter for existing users — that runs
--     client-side on first PaletteManager.bootstrap() when the worker
--     returns an empty list. Survives signup → delete → re-signup
--     cleanly without database trigger state.
--   - Add per-swatch names. v1 stores colors as a JSONB array of
--     6-digit hex strings ["#ff8844", "#33aa66"]. Migration 0014 can
--     expand to {hex, name} objects if/when named swatches ship.
--
-- Pattern conventions match 0001 / 0005 / 0011 / 0012:
--   - `create table if not exists` for idempotent re-runs
--   - DROP POLICY IF EXISTS before each CREATE POLICY for re-runnability
--   - service-role bypasses RLS for the Worker's writes
--   - soft-delete via `deleted_at timestamptz` column; the list-by-user
--     index has a `where deleted_at is null` predicate so soft-deleted
--     rows fall out of the user's "my palettes" view immediately
-- =========================================================================

create table if not exists public.user_palettes (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references auth.users(id) on delete cascade,
    name        text not null check (char_length(name) <= 50),
    colors      jsonb not null default '[]'::jsonb,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    deleted_at  timestamptz
);

create index if not exists user_palettes_user_idx
    on public.user_palettes (user_id, updated_at desc)
    where deleted_at is null;

-- Reuses public.touch_updated_at() defined in 0001_init.sql.
drop trigger if exists user_palettes_touch_updated_at on public.user_palettes;
create trigger user_palettes_touch_updated_at
    before update on public.user_palettes
    for each row
    execute function public.touch_updated_at();

alter table public.user_palettes enable row level security;

drop policy if exists "users read own palettes"   on public.user_palettes;
drop policy if exists "users insert own palettes" on public.user_palettes;
drop policy if exists "users update own palettes" on public.user_palettes;

create policy "users read own palettes"
    on public.user_palettes for select
    using (auth.uid() = user_id);

create policy "users insert own palettes"
    on public.user_palettes for insert
    with check (auth.uid() = user_id);

create policy "users update own palettes"
    on public.user_palettes for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

-- Note: no DELETE policy — deletion is soft (set deleted_at). The worker
-- (service_role) is the only writer in practice; user-side soft-delete
-- goes through DELETE /v1/palettes/:id, not direct PostgREST.
