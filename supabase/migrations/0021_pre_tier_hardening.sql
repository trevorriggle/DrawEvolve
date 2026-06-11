-- 0021 — Pre-tier hardening (tier sprint part 1, 2026-06-11)
-- =========================================================================
-- How to apply:
--   1. Open the Supabase dashboard for project `jkjfcjptzvieaonrmkzd`.
--   2. SQL Editor → + New query → paste this file → Run.
--   3. Re-runnable safely (create-or-replace + drop-if-exists guards).
--
-- What it does (two items from the 2026-06-11 ship audit):
--
--   1. Makes the "Worker is the sole writer of drawings.critique_history"
--      contract DATABASE-ENFORCED instead of code-enforced. iOS politely
--      omits the column from PATCH bodies today, but the drawings UPDATE
--      RLS policy would ALLOW an authenticated client to overwrite it —
--      clobbering concurrent Worker appends (and, post-tiers, the usage
--      evidence inside it). A BEFORE UPDATE trigger silently restores the
--      old value for non-service-role writers. The Worker's
--      append_critique() RPC and SQL-editor admin sessions are unaffected
--      (service_role / null auth.role() pass through).
--
--   2. account_deletions: RLS is enabled with NO policies (service-role
--      only, correct) — but that's deny-by-absence. An explicit deny-all
--      SELECT policy makes it deny-by-declaration, so a future
--      well-meaning policy addition can't accidentally expose deletion
--      audit rows (emails + reasons) to authenticated users.
--
-- What it deliberately does NOT do:
--
--   - No monthly-usage index on feedback_requests. The audit initially
--     flagged one, but the existing feedback_requests_user_time_idx
--     (user_id, requested_at desc) already serves
--     "WHERE user_id = $1 AND requested_at >= $month_start AND < $next"
--     range counts efficiently — and a date_trunc('month', timestamptz)
--     expression index isn't possible anyway (not immutable; depends on
--     the TimeZone setting). Monthly quota ENFORCEMENT lives in Worker KV
--     (quota_month:<user>:<YYYY-MM>), not Postgres; this table is the
--     audit/reconciliation trail.
-- =========================================================================

-- ── 1. critique_history write-lock ──────────────────────────────────────

create or replace function public.prevent_critique_history_client_mutation()
returns trigger
language plpgsql
as $$
begin
    -- service_role (the Worker, incl. the append_critique RPC) and
    -- direct admin sessions (auth.role() is null in the SQL editor)
    -- pass through untouched. Authenticated/anon clients get their
    -- critique_history change silently reverted — the rest of their
    -- UPDATE (title, context, etc.) still applies, matching the iOS
    -- contract where the column is never sent in the first place.
    if coalesce(auth.role(), 'service_role') <> 'service_role'
       and new.critique_history is distinct from old.critique_history then
        new.critique_history := old.critique_history;
    end if;
    return new;
end;
$$;

drop trigger if exists drawings_critique_history_write_lock on public.drawings;
create trigger drawings_critique_history_write_lock
    before update on public.drawings
    for each row
    execute function public.prevent_critique_history_client_mutation();

-- ── 2. account_deletions explicit deny-all ──────────────────────────────

drop policy if exists "account_deletions_deny_select" on public.account_deletions;
create policy "account_deletions_deny_select"
    on public.account_deletions
    for select
    using (false);
