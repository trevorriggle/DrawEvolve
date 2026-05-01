-- Preset voices + custom prompts plumbing (Commit A of 3).
-- =========================================================================
-- How to apply:
--   1. Open the Supabase dashboard for project `jkjfcjptzvieaonrmkzd`.
--   2. SQL Editor → + New query → paste this file → Run.
--   3. Re-runnable safely (every statement is idempotent or guarded).
--
-- What it does:
--   - Adds public.user_preferences table holding per-user preferred_preset_id.
--   - Adds drawings.preset_id column (text, default 'studio_mentor').
--   - Adds public.custom_prompts table for user-authored prompt strings.
--   - RLS policies on both new tables matching the existing drawings pattern.
--   - INSERT-on-signup trigger so every new auth.users row has a preferences
--     row before its first request, plus a backfill for existing users.
--
-- What it does NOT do:
--   - Change any user-visible behavior. The Worker plumbing in index.js
--     wires preset_id through validation and persistence but continues to
--     use the existing VOICE_ART_PROFESSOR voice for every request. Voice
--     selection logic ships in Commit B; iOS UI ships in Commit C.
--
-- Design rationale and the long-form trade study live in
-- CUSTOM_PROMPTS_PLAN.md at the repo root. Key choices encoded here:
--   - user_preferences as a new public table (NOT auth.users.raw_app_meta_data,
--     which would have JWT-staleness issues on "set as default")
--   - per-drawing preset_id column on drawings (write-through from request)
--   - preset_id at top-level of critique_history JSONB entries (voice
--     identity is not a config knob, so it doesn't go inside prompt_config)
--   - custom_prompts as a separate table with the standard 4-policy RLS
--     pattern matching drawings
--
-- Pattern conventions match 0001_init.sql:
--   - one policy per CRUD verb, named "users <verb> own <table>"
--   - DROP POLICY IF EXISTS before each CREATE for re-runnability
--   - service-role bypasses RLS for the Worker's writes
-- =========================================================================


-- =========================================================================
-- 1. user_preferences
-- =========================================================================
-- One row per user. PK is user_id (the FK is the natural key — there's
-- exactly one preferences row per user, no need for a synthetic id).

create table if not exists public.user_preferences (
    user_id              uuid primary key references auth.users(id) on delete cascade,
    preferred_preset_id  text not null default 'studio_mentor',
    created_at           timestamptz not null default now(),
    updated_at           timestamptz not null default now()
);

-- Reuses public.touch_updated_at() defined in 0001_init.sql.
drop trigger if exists user_preferences_touch_updated_at on public.user_preferences;
create trigger user_preferences_touch_updated_at
    before update on public.user_preferences
    for each row
    execute function public.touch_updated_at();

alter table public.user_preferences enable row level security;

drop policy if exists "users read own user_preferences"   on public.user_preferences;
drop policy if exists "users insert own user_preferences" on public.user_preferences;
drop policy if exists "users update own user_preferences" on public.user_preferences;
drop policy if exists "users delete own user_preferences" on public.user_preferences;

create policy "users read own user_preferences"
    on public.user_preferences for select
    using (auth.uid() = user_id);

create policy "users insert own user_preferences"
    on public.user_preferences for insert
    with check (auth.uid() = user_id);

create policy "users update own user_preferences"
    on public.user_preferences for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create policy "users delete own user_preferences"
    on public.user_preferences for delete
    using (auth.uid() = user_id);


-- =========================================================================
-- 2. Signup trigger: ensure every user has a user_preferences row
-- =========================================================================
-- after insert (not before) — the auth.users row needs to exist before the
-- FK on user_preferences.user_id can resolve. Pattern matches
-- set_default_tier_on_signup in 0001_init.sql, but with INSERT semantics
-- instead of column-stamping.

create or replace function public.create_user_preferences_on_signup()
returns trigger
language plpgsql
security definer
as $$
begin
    insert into public.user_preferences (user_id)
    values (new.id)
    on conflict (user_id) do nothing;
    return new;
end;
$$;

drop trigger if exists create_user_preferences on auth.users;
create trigger create_user_preferences
    after insert on auth.users
    for each row
    execute function public.create_user_preferences_on_signup();

-- Backfill: any pre-existing user (including the developer) gets a
-- preferences row stamped with the default preset.
insert into public.user_preferences (user_id)
select id from auth.users
on conflict (user_id) do nothing;


-- =========================================================================
-- 3. drawings.preset_id
-- =========================================================================
-- Per-drawing preset, written through from the request body by the Worker.
-- NOT NULL is safe because of the default; existing rows backfill to
-- 'studio_mentor' implicitly.

alter table public.drawings
    add column if not exists preset_id text not null default 'studio_mentor';


-- =========================================================================
-- 4. custom_prompts
-- =========================================================================
-- User-authored prompt strings. References auth.users(id) with cascade so
-- account deletion cleans up. Char-length checks at the column level
-- enforce the same caps the Worker enforces in validateContextLengths
-- (defense in depth).

create table if not exists public.custom_prompts (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references auth.users(id) on delete cascade,
    name        text not null check (char_length(name) <= 50),
    body        text not null check (char_length(body) <= 2000),
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create index if not exists custom_prompts_user_id_idx
    on public.custom_prompts (user_id);

drop trigger if exists custom_prompts_touch_updated_at on public.custom_prompts;
create trigger custom_prompts_touch_updated_at
    before update on public.custom_prompts
    for each row
    execute function public.touch_updated_at();

alter table public.custom_prompts enable row level security;

drop policy if exists "users read own custom_prompts"   on public.custom_prompts;
drop policy if exists "users insert own custom_prompts" on public.custom_prompts;
drop policy if exists "users update own custom_prompts" on public.custom_prompts;
drop policy if exists "users delete own custom_prompts" on public.custom_prompts;

create policy "users read own custom_prompts"
    on public.custom_prompts for select
    using (auth.uid() = user_id);

create policy "users insert own custom_prompts"
    on public.custom_prompts for insert
    with check (auth.uid() = user_id);

create policy "users update own custom_prompts"
    on public.custom_prompts for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create policy "users delete own custom_prompts"
    on public.custom_prompts for delete
    using (auth.uid() = user_id);
