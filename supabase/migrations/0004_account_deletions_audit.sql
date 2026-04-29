-- Phase 6 — account deletion audit log.
--
-- GDPR/CCPA require we keep an audit trail of deletions even though the user
-- data itself is gone. Email is preserved as the only way to identify a
-- deletion request if law enforcement or compliance later requests
-- information about a no-longer-existent account.
--
-- No FK to auth.users: those rows are being hard-deleted, and a FK with
-- ON DELETE CASCADE would wipe the audit row out from under us. The whole
-- point is for the audit row to outlive the user.

create table if not exists public.account_deletions (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null,
    email       text,
    deleted_at  timestamptz not null default now(),
    reason      text not null default 'user_initiated'
);

create index if not exists account_deletions_user_idx
    on public.account_deletions (user_id);

alter table public.account_deletions enable row level security;

-- No policies created — service-role only. Authenticated users have no
-- access to this table. This is for legal/compliance, not user-facing data.
