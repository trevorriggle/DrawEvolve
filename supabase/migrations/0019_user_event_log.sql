-- 0019_user_event_log.sql
-- =========================================================================
-- How to apply:
--   1. Open the Supabase dashboard for project `jkjfcjptzvieaonrmkzd`.
--   2. SQL Editor → + New query → paste this file → Run.
--   3. Re-runnable safely (every statement is idempotent or guarded).
--
-- What it does:
--   - Creates public.user_event_log (general-purpose client-side event sink).
--   - Composite index on (user_id, event_name, created_at desc) — supports
--     the most common analytical query shape ("recent events of type X for
--     user Y" / "all of type X across all users in last N days").
--   - RLS: users INSERT their own rows. No SELECT/UPDATE/DELETE for
--     anon/authenticated. Service role reads for analysis.
--
-- First consumer: the fresh-install tutorial work (proposal v2). Event
-- types fired by the tutorial:
--   - tutorial_card_seen        — payload: {card: 1|2|3}
--   - tutorial_completed
--   - tutorial_skipped          — payload: {last_card_seen: 1|2|3}
--   - prompt_input_banner_dismissed
--   - coach_mark_seen   — payload: {mark: "..."} where mark is one of
--                         "get_feedback" | "ask_eve" | "gallery_tour"
--
-- Future consumers (separate PRs):
--   - Critique funnel events, Eve engagement, gallery navigation,
--     settings actions. This table is the primitive; instrument other
--     surfaces incrementally.
--
-- What it does NOT do:
--   - Add server-side dedup, sampling, or per-event-type rate limits.
--     Events should always succeed. If this becomes a problem we add a
--     trigger then; v1 stays permissive.
--   - Add a payload schema. payload is jsonb with no validation — caller
--     is responsible for shape. We document event shapes in the iOS
--     EventLogService.swift call sites; if shapes calcify we can add a
--     check constraint per-event-name later.
--   - Add a TTL / retention policy. Events are kept indefinitely until
--     the table grows big enough to justify cleanup. Storage is cheap;
--     historical funnels are valuable.
--
-- Failure-mode design:
--   - The iOS EventLogService swallows errors silently (Task.detached,
--     background priority). Analytics failure must NEVER block UX. If
--     the table is missing / RLS is misconfigured / network drops, the
--     user still sees the tutorial; we just lose the event. Acceptable.
--
-- Pattern conventions match 0001 / 0012 / 0014 / 0018:
--   - `create table if not exists` for idempotent re-runs
--   - DROP POLICY IF EXISTS before each CREATE POLICY for re-runnability
--   - service-role bypasses RLS (no policy granted to service_role)
--   - snake_case columns; <table>_<thing>_idx index naming
-- =========================================================================


-- =========================================================================
-- 1. user_event_log
-- =========================================================================

create table if not exists public.user_event_log (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references auth.users(id) on delete cascade,
    event_name  text not null,
    payload     jsonb not null default '{}'::jsonb,
    created_at  timestamptz not null default now()
);

create index if not exists user_event_log_user_event_idx
    on public.user_event_log (user_id, event_name, created_at desc);

alter table public.user_event_log enable row level security;

drop policy if exists "users insert own events" on public.user_event_log;

create policy "users insert own events"
    on public.user_event_log for insert
    with check (auth.uid() = user_id);

-- Note: no SELECT/UPDATE/DELETE policies for authenticated. Service role
-- bypasses RLS for analytical queries via Supabase Studio.
