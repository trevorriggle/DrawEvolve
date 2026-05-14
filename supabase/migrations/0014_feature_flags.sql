-- 0014_feature_flags.sql
--
-- Remote-configurable feature flags. Drives the Eye Test panel's
-- kill switch (and any future feature that needs the same).
--
-- Reads: authenticated users may SELECT all flags. Writes: service
-- role only — flip flags via the Supabase SQL editor or the worker
-- when an admin tool exists.
--
-- The iOS AppFeatureFlags service polls this table at app launch and
-- on a slow timer, falls back to a UserDefaults snapshot if offline,
-- and treats "no row" as enabled=false (fail closed).
--
-- Idempotent.

create table if not exists public.feature_flags (
    flag_name text primary key,
    enabled boolean not null default false,
    updated_at timestamptz not null default now()
);

alter table public.feature_flags enable row level security;

drop policy if exists "feature_flags_read_authenticated" on public.feature_flags;
create policy "feature_flags_read_authenticated"
    on public.feature_flags
    for select
    using (auth.role() = 'authenticated');

-- Only service_role can mutate (no policy granted to authenticated).

-- Seed the two Eye Test flags. Both default to disabled. Beta-only
-- first per the Eye Test build plan (condition 9): the panel flag
-- gets flipped on for the TestFlight cohort via SQL update; the
-- Eve-integration flag stays off until panel data justifies enabling it.
insert into public.feature_flags (flag_name, enabled) values
    ('eye_test_panel', false),
    ('eye_test_eve_integration', false)
on conflict (flag_name) do nothing;

create or replace function public.touch_feature_flags_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists feature_flags_set_updated_at on public.feature_flags;
create trigger feature_flags_set_updated_at
    before update on public.feature_flags
    for each row execute function public.touch_feature_flags_updated_at();
