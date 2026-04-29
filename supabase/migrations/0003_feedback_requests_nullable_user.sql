-- Phase 5e — auth-failed requests have no validated user, so user_id needs
-- to be nullable for those rows. The FK to auth.users still applies when
-- populated; the existing RLS policy `auth.uid() = user_id` naturally
-- returns false for null rows, so users only see their own logged
-- requests and never any auth_failed entries (those stay service-role-only).

alter table public.feedback_requests
    alter column user_id drop not null;
