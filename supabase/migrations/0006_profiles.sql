-- Phase A — social foundations: profiles + avatars bucket
-- =========================================================================
-- How to apply:
--   1. Open the Supabase dashboard for project `jkjfcjptzvieaonrmkzd`.
--   2. Go to: SQL Editor → + New query.
--   3. Paste the entire contents of this file.
--   4. Click "Run".
--   5. Re-runnable safely (every statement is idempotent or guarded).
--
-- What it does:
--   - Enables citext + pg_trgm extensions (both ship with Supabase).
--   - Creates `profiles` table (one row per auth.users row, owner-writable,
--     public-readable when is_public=true).
--   - Trigram GIN indexes on username + display_name to power profile search.
--   - RLS policies (select: public-or-owner; insert/update/delete: owner only).
--   - Auto-creates a profile row on every auth.users insert with an auto-
--     generated handle (`user_xxxxxxxx`) and a display name derived from the
--     email local-part. Backfills any existing users that don't have a row.
--   - Provisions the `avatars` Storage bucket (public-read; per-user write).
--
-- The Cloudflare Worker (with the service-role key) is the canonical writer
-- for everything sensitive. iOS clients hit Supabase REST directly only for
-- read paths; mutating writes (display_name, bio, is_public, is_searchable,
-- one-time username set) all flow through the Worker.
-- =========================================================================


-- =========================================================================
-- 0. Required extensions
-- =========================================================================

create extension if not exists citext;
create extension if not exists pg_trgm;


-- =========================================================================
-- 1. profiles
-- =========================================================================
-- One row per user. Counts (follower / following / post) are denormalized
-- caches — never trust them during deletion or moderation. They will be
-- maintained by triggers added in subsequent phases (follows, posts).
--
-- username is citext so case-insensitive uniqueness comes for free; the
-- format check pins it to a-z, 0-9, underscore, 3–24 chars. The auto-create
-- trigger below seeds it with `user_<8 hex>`, which is always 13 chars and
-- always passes the format constraint.

create table if not exists public.profiles (
    user_id          uuid primary key references auth.users(id) on delete cascade,
    username         citext not null unique,
    display_name     text not null,
    bio              text,
    avatar_path      text,
    is_public        boolean not null default true,
    is_searchable    boolean not null default true,
    created_at       timestamptz not null default now(),
    updated_at       timestamptz not null default now(),
    -- Tracks the one-time-set gate. NULL while the user still has the auto-
    -- generated `user_xxxxxxxx` handle; stamped to now() the first time the
    -- Worker accepts a PATCH that changes username. After that, further
    -- username changes are rejected with `username_immutable`.
    username_set_at  timestamptz,
    follower_count   int not null default 0,
    following_count  int not null default 0,
    post_count       int not null default 0,
    constraint username_format     check (username ~ '^[a-z0-9_]{3,24}$'),
    constraint display_name_length check (char_length(display_name) between 1 and 50),
    constraint bio_length          check (bio is null or char_length(bio) <= 280)
);

create index if not exists profiles_username_trgm
    on public.profiles using gin (username gin_trgm_ops);
create index if not exists profiles_display_name_trgm
    on public.profiles using gin (display_name gin_trgm_ops);

-- Touch updated_at on every UPDATE. Reuses public.touch_updated_at() from
-- migration 0001 so the same trigger function is shared across tables.
drop trigger if exists profiles_touch_updated_at on public.profiles;
create trigger profiles_touch_updated_at
    before update on public.profiles
    for each row
    execute function public.touch_updated_at();


-- =========================================================================
-- 2. RLS
-- =========================================================================
-- Anyone authenticated can read public profiles or their own (private profile
-- = not visible to non-owners). Owner-only writes. Service-role (the Worker)
-- bypasses these policies entirely.

alter table public.profiles enable row level security;

drop policy if exists profiles_select on public.profiles;
drop policy if exists profiles_insert on public.profiles;
drop policy if exists profiles_update on public.profiles;
drop policy if exists profiles_delete on public.profiles;

create policy profiles_select
    on public.profiles for select to authenticated
    using (is_public or user_id = auth.uid());

create policy profiles_insert
    on public.profiles for insert to authenticated
    with check (user_id = auth.uid());

create policy profiles_update
    on public.profiles for update to authenticated
    using (user_id = auth.uid())
    with check (user_id = auth.uid());

create policy profiles_delete
    on public.profiles for delete to authenticated
    using (user_id = auth.uid());


-- =========================================================================
-- 3. Auto-create profile on signup
-- =========================================================================
-- Every auth.users insert gets a profiles row stamped with:
--   - username:     'user_' || first 8 lowercase hex chars of id
--   - display_name: split_part(email, '@', 1), defaulting to 'User' when the
--                   account is email-less or the local-part is empty
--
-- Pattern matches set_default_tier_on_signup from migration 0001 (BEFORE
-- INSERT trigger on auth.users). We use AFTER INSERT here because we need
-- the assigned id + email to seed the profile, and an AFTER trigger sees
-- the final row. Failures fall through silently — a missing profile is
-- backfilled on first GET /v1/me by the Worker.

create or replace function public.create_profile_on_signup()
returns trigger
language plpgsql
security definer
as $$
declare
    derived_username text;
    derived_display  text;
    email_local      text;
begin
    derived_username := 'user_' || substr(replace(new.id::text, '-', ''), 1, 8);
    email_local      := nullif(split_part(coalesce(new.email, ''), '@', 1), '');
    derived_display  := coalesce(email_local, 'User');

    insert into public.profiles (user_id, username, display_name)
        values (new.id, derived_username, derived_display)
        on conflict (user_id) do nothing;
    return new;
exception
    when others then
        -- Never block signup on profile creation; Worker backfills lazily.
        raise warning 'create_profile_on_signup failed for %: %', new.id, sqlerrm;
        return new;
end;
$$;

drop trigger if exists create_profile_on_signup on auth.users;
create trigger create_profile_on_signup
    after insert on auth.users
    for each row
    execute function public.create_profile_on_signup();

-- Backfill: any pre-existing user without a profiles row gets one. Same
-- generation rules as the trigger above.
insert into public.profiles (user_id, username, display_name)
select
    u.id,
    'user_' || substr(replace(u.id::text, '-', ''), 1, 8),
    coalesce(nullif(split_part(coalesce(u.email, ''), '@', 1), ''), 'User')
from auth.users u
left join public.profiles p on p.user_id = u.id
where p.user_id is null
on conflict (user_id) do nothing;


-- =========================================================================
-- 4. Storage bucket: avatars
-- =========================================================================
-- Public-read so feed rendering can batch-load avatars without signed URLs.
-- Path convention: '<user_id>/avatar.jpg' (overwriteable by the owner).
-- Writes are RLS-gated on the first path segment matching auth.uid().

insert into storage.buckets (id, name, public)
    values ('avatars', 'avatars', true)
    on conflict (id) do nothing;

drop policy if exists "avatars are publicly readable"   on storage.objects;
drop policy if exists "users insert own avatar files"   on storage.objects;
drop policy if exists "users update own avatar files"   on storage.objects;
drop policy if exists "users delete own avatar files"   on storage.objects;

-- Public read: any role (anon + authenticated) can fetch from the avatars bucket.
create policy "avatars are publicly readable"
    on storage.objects for select
    using (bucket_id = 'avatars');

create policy "users insert own avatar files"
    on storage.objects for insert
    with check (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);

create policy "users update own avatar files"
    on storage.objects for update
    using (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);

create policy "users delete own avatar files"
    on storage.objects for delete
    using (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);
