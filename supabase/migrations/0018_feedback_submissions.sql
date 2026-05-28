-- 0018_feedback_submissions.sql
-- =========================================================================
-- How to apply:
--   1. Open the Supabase dashboard for project `jkjfcjptzvieaonrmkzd`.
--   2. SQL Editor → + New query → paste this file → Run.
--   3. Re-runnable safely (every statement is idempotent or guarded).
--
-- What it does:
--   - Creates public.feedback_submissions (one row per user-submitted
--     feedback entry from Settings → Send Feedback).
--   - Index on (user_id, submitted_at desc) for the rate-limit check
--     and any future "feedback by user" review tool.
--   - RLS: users INSERT their own rows. No SELECT/UPDATE/DELETE for
--     anon/authenticated. Service role bypasses RLS for read-side
--     analysis via Supabase Studio or a future internal admin view.
--   - Rate-limit trigger: caps at 5 submissions per user per rolling hour.
--     Server-enforced so the client can't bypass.
--
-- What it does NOT do:
--   - Add a SELECT policy for authenticated. Users don't need to read
--     their own submissions back (no UI surfaces them). If we add a
--     "my submissions" view later, add the policy then.
--   - Add reply / triage columns. We can't reply individually (no
--     support team). The Settings sheet copy sets this expectation
--     ("We read every submission. We can't reply individually, but
--     it shapes what ships next.").
--   - Attempt to identify the user beyond user_id. No IDFV, no IP, no
--     identifying metadata. app_version + device_info are debugging
--     hints only.
--
-- Why hour-window (not day):
--   - A genuinely-frustrated user reporting back-to-back issues should
--     not be silenced for 24h. Hour-window resets fast enough that
--     legitimate use isn't blocked, while still throttling accidental
--     spam (rage-tap on Send button, runaway script, etc).
--
-- Pattern conventions match 0001 / 0012 / 0014:
--   - `create table if not exists` for idempotent re-runs
--   - DROP POLICY IF EXISTS before each CREATE POLICY for re-runnability
--   - service-role bypasses RLS (no policy granted to service_role)
--   - snake_case columns; <table>_<thing>_idx index naming
-- =========================================================================


-- =========================================================================
-- 1. feedback_submissions
-- =========================================================================

create table if not exists public.feedback_submissions (
    id              uuid primary key default gen_random_uuid(),
    user_id         uuid not null references auth.users(id) on delete cascade,
    submitted_at    timestamptz not null default now(),
    category        text not null
        check (category in ('bug', 'confusion', 'feature_request', 'other')),
    body            text not null check (char_length(body) between 10 and 4000),
    app_version     text,
    device_info     text
);

create index if not exists feedback_submissions_user_submitted_idx
    on public.feedback_submissions (user_id, submitted_at desc);

alter table public.feedback_submissions enable row level security;

drop policy if exists "users insert own feedback"
    on public.feedback_submissions;

create policy "users insert own feedback"
    on public.feedback_submissions for insert
    with check (auth.uid() = user_id);

-- Note: no SELECT/UPDATE/DELETE policies for authenticated. Service role
-- bypasses RLS for read-side analysis. Users don't need to view their
-- own submissions back via the iOS app.


-- =========================================================================
-- 2. rate-limit trigger: 5 submissions per user per rolling hour
-- =========================================================================

create or replace function public.enforce_feedback_rate_limit()
returns trigger
language plpgsql
as $$
declare
    recent_count int;
begin
    select count(*) into recent_count
      from public.feedback_submissions
     where user_id = NEW.user_id
       and submitted_at > now() - interval '1 hour';

    if recent_count >= 5 then
        raise exception 'Feedback rate limit exceeded (5/hr). Try later.'
            using errcode = 'P0001';
    end if;

    return NEW;
end;
$$;

drop trigger if exists feedback_submissions_rate_limit
    on public.feedback_submissions;
create trigger feedback_submissions_rate_limit
    before insert on public.feedback_submissions
    for each row
    execute function public.enforce_feedback_rate_limit();
