-- DrawEvolve schema bootstrap
-- =========================================================================
-- How to apply:
--   1. Open the Supabase dashboard for project `jkjfcjptzvieaonrmkzd`.
--   2. Go to: SQL Editor → + New query.
--   3. Paste the entire contents of this file.
--   4. Click "Run".
--   5. Re-runnable safely (every statement is idempotent or guarded).
--
-- What it does:
--   - Creates `drawings` table (one row per saved drawing, owned by a user).
--   - Creates `feedback_requests` log table (Phase 5 quota / abuse tracking).
--   - Adds RLS policies so users only see their own data.
--   - Provisions the `drawings` Storage bucket + per-user RLS.
--   - Defaults `auth.users.app_metadata.tier = 'free'` on signup so the
--     Worker's tier-aware quotas have a value to read from request 1.
--
-- This file is the durable backend; the iOS auth UI may be reworked when
-- Apple Developer approval lands, but the schema below should not need
-- to change for that.
-- =========================================================================


-- =========================================================================
-- 1. drawings
-- =========================================================================
-- One row per drawing. critique_history is a jsonb array bundled with the
-- drawing (rationale: atomic with the drawing, single query for gallery
-- hydration, cascades cleanly on delete). storage_path points at the JPEG
-- in the `drawings` bucket: '<user_id>/<drawing_id>.jpg'.

create table if not exists public.drawings (
    id               uuid primary key default gen_random_uuid(),
    user_id          uuid not null references auth.users(id) on delete cascade,
    title            text not null,
    storage_path     text not null,
    context          jsonb,
    feedback         text,
    critique_history jsonb not null default '[]'::jsonb,
    created_at       timestamptz not null default now(),
    updated_at       timestamptz not null default now()
);

create index if not exists drawings_user_id_idx
    on public.drawings (user_id, updated_at desc);

-- Touch updated_at on every UPDATE so the gallery sort stays correct.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists drawings_touch_updated_at on public.drawings;
create trigger drawings_touch_updated_at
    before update on public.drawings
    for each row
    execute function public.touch_updated_at();

-- RLS: a user can only see / mutate rows where they're the owner.
alter table public.drawings enable row level security;

drop policy if exists "users read own drawings"   on public.drawings;
drop policy if exists "users insert own drawings" on public.drawings;
drop policy if exists "users update own drawings" on public.drawings;
drop policy if exists "users delete own drawings" on public.drawings;

create policy "users read own drawings"
    on public.drawings for select
    using (auth.uid() = user_id);

create policy "users insert own drawings"
    on public.drawings for insert
    with check (auth.uid() = user_id);

create policy "users update own drawings"
    on public.drawings for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create policy "users delete own drawings"
    on public.drawings for delete
    using (auth.uid() = user_id);


-- =========================================================================
-- 2. feedback_requests (Phase 5 logging)
-- =========================================================================
-- One row per AI feedback request that hits the Cloudflare Worker. The
-- Worker writes via service_role; users can read their own history (for
-- a future "feedback log" surface). Drives Phase 5c-alert abuse detection
-- (any single user > 5x daily quota in a 1h window) via a SQL query.

create table if not exists public.feedback_requests (
    id                     uuid primary key default gen_random_uuid(),
    user_id                uuid not null references auth.users(id) on delete cascade,
    drawing_id             uuid references public.drawings(id) on delete set null,
    requested_at           timestamptz not null default now(),
    status                 text not null,           -- 'success' | 'quota_exceeded' | 'model_error' | 'auth_failed'
    prompt_token_count     int,
    completion_token_count int,
    client_ip_hash         text                     -- sha256 hex of the originating IP, never the raw IP
);

create index if not exists feedback_requests_user_time_idx
    on public.feedback_requests (user_id, requested_at desc);

alter table public.feedback_requests enable row level security;

drop policy if exists "users read own feedback_requests" on public.feedback_requests;
create policy "users read own feedback_requests"
    on public.feedback_requests for select
    using (auth.uid() = user_id);

-- No insert / update / delete policies for authenticated users.
-- Only the Worker (using the service_role key, which bypasses RLS) writes.


-- =========================================================================
-- 3. Storage bucket: drawings
-- =========================================================================
-- Private bucket — no public URLs. Image bytes live at
-- '<user_id>/<drawing_id>.jpg'; client fetches via signed URLs (short TTL).

insert into storage.buckets (id, name, public)
    values ('drawings', 'drawings', false)
    on conflict (id) do nothing;

drop policy if exists "users read own drawing files"   on storage.objects;
drop policy if exists "users insert own drawing files" on storage.objects;
drop policy if exists "users update own drawing files" on storage.objects;
drop policy if exists "users delete own drawing files" on storage.objects;

-- storage.foldername(name) splits the object key on '/' and returns an
-- array; element 1 is the first segment, which by convention is the user_id.
create policy "users read own drawing files"
    on storage.objects for select
    using (bucket_id = 'drawings' and auth.uid()::text = (storage.foldername(name))[1]);

create policy "users insert own drawing files"
    on storage.objects for insert
    with check (bucket_id = 'drawings' and auth.uid()::text = (storage.foldername(name))[1]);

create policy "users update own drawing files"
    on storage.objects for update
    using (bucket_id = 'drawings' and auth.uid()::text = (storage.foldername(name))[1]);

create policy "users delete own drawing files"
    on storage.objects for delete
    using (bucket_id = 'drawings' and auth.uid()::text = (storage.foldername(name))[1]);


-- =========================================================================
-- 4. Default tier='free' on signup
-- =========================================================================
-- The Worker reads `app_metadata.tier` to pick TIER_LIMITS / PromptConfig.
-- Stamping new rows here means quota + tier-aware prompts apply from the
-- very first request — no race window where tier is null.

create or replace function public.set_default_tier_on_signup()
returns trigger
language plpgsql
security definer
as $$
begin
    if new.raw_app_meta_data is null then
        new.raw_app_meta_data := '{}'::jsonb;
    end if;
    if new.raw_app_meta_data ? 'tier' then
        return new;
    end if;
    new.raw_app_meta_data := new.raw_app_meta_data || jsonb_build_object('tier', 'free');
    return new;
end;
$$;

drop trigger if exists set_default_tier on auth.users;
create trigger set_default_tier
    before insert on auth.users
    for each row
    execute function public.set_default_tier_on_signup();

-- Backfill: any user (including yourself, once you sign in for the first
-- time) without a tier gets stamped as 'free'.
update auth.users
   set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb)
                         || jsonb_build_object('tier', 'free')
 where (raw_app_meta_data ->> 'tier') is null;
