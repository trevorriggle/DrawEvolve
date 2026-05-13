-- Feature 2, Phase 2A — Eve conversational coach: schema bootstrap.
-- =========================================================================
-- How to apply:
--   1. Open the Supabase dashboard for project `jkjfcjptzvieaonrmkzd`.
--   2. SQL Editor → + New query → paste this file → Run.
--   3. Re-runnable safely (every statement is idempotent or guarded).
--
-- What it does:
--   - Creates public.conversations (one row per Eve chat session).
--   - Creates public.conversation_messages (one row per turn or tool call).
--   - Indexes for the read paths the worker uses (list by user, fetch
--     messages by conversation in chronological order).
--   - Partial unique index on conversation_messages.client_request_id
--     scoped to (conversation_id, client_request_id) for per-conversation
--     idempotency on retried sends.
--   - RLS policies matching the existing per-user table pattern
--     (drawings / user_preferences / custom_prompts).
--
-- What it does NOT do:
--   - Add streaming infrastructure (Phase 2B).
--   - Add a `tool_definitions` registry — tools come in 2C and won't
--     require a new table; they'll live in worker code as a constants
--     module. The role='tool' enum value is added now so 2C doesn't
--     need a schema migration to enable tool turns.
--   - Add a global signup trigger seeding a starter conversation —
--     a conversation row is created on the first POST per session.
--   - Track per-conversation tier (Pro gating uses request-time JWT
--     claims; the conversation row doesn't need to know its tier).
--
-- Pattern conventions match 0001 / 0005 / 0011:
--   - `create table if not exists` for idempotent re-runs
--   - DROP POLICY IF EXISTS before each CREATE POLICY for re-runnability
--   - service-role bypasses RLS for all worker writes
--   - soft-delete via `deleted_at timestamptz` column; the list-by-user
--     index has a `where deleted_at is null` predicate so soft-deleted
--     rows fall out of the user's "my conversations" view immediately
-- =========================================================================


-- =========================================================================
-- 1. conversations
-- =========================================================================

create table if not exists public.conversations (
    id                       uuid primary key default gen_random_uuid(),
    user_id                  uuid not null references auth.users(id) on delete cascade,
    title                    text,
    scope                    text not null check (scope in ('drawing', 'evolution', 'general')),
    scope_drawing_id         uuid references public.drawings(id) on delete set null,
    scope_critique_sequence  int,
    client_request_id        text unique,
    created_at               timestamptz not null default now(),
    updated_at               timestamptz not null default now(),
    last_message_at          timestamptz not null default now(),
    message_count            int not null default 0,
    total_input_tokens       bigint not null default 0,
    total_output_tokens      bigint not null default 0,
    deleted_at               timestamptz
);

create index if not exists conversations_user_id_idx
    on public.conversations (user_id, last_message_at desc)
    where deleted_at is null;

-- Reuses public.touch_updated_at() defined in 0001_init.sql.
drop trigger if exists conversations_touch_updated_at on public.conversations;
create trigger conversations_touch_updated_at
    before update on public.conversations
    for each row
    execute function public.touch_updated_at();

alter table public.conversations enable row level security;

drop policy if exists "users read own conversations"   on public.conversations;
drop policy if exists "users insert own conversations" on public.conversations;
drop policy if exists "users update own conversations" on public.conversations;

create policy "users read own conversations"
    on public.conversations for select
    using (auth.uid() = user_id);

create policy "users insert own conversations"
    on public.conversations for insert
    with check (auth.uid() = user_id);

create policy "users update own conversations"
    on public.conversations for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

-- Note: no DELETE policy — deletion is soft (set deleted_at). The worker
-- (service_role) is the only writer in practice; user-side soft-delete
-- goes through DELETE /v1/eve/conversations/:id in 2B, not direct PostgREST.


-- =========================================================================
-- 2. conversation_messages
-- =========================================================================

create table if not exists public.conversation_messages (
    id                       uuid primary key default gen_random_uuid(),
    conversation_id          uuid not null references public.conversations(id) on delete cascade,
    role                     text not null check (role in ('user', 'assistant', 'tool')),
    content                  text not null,
    tool_calls               jsonb,
    tool_call_id             text,
    attached_drawing_id      uuid references public.drawings(id) on delete set null,
    client_request_id        text,
    created_at               timestamptz not null default now(),
    prompt_token_count       int,
    completion_token_count   int,
    persona_version          int,
    product_context_version  int
);

create index if not exists conversation_messages_conversation_idx
    on public.conversation_messages (conversation_id, created_at asc);

-- Partial unique constraint on retried sends. The same client_request_id
-- under a different conversation does not collide; only same-conversation
-- retries of the same logical send do. The partial predicate keeps the
-- index small (assistant + tool rows set client_request_id to null).
create unique index if not exists conversation_messages_idempotency_idx
    on public.conversation_messages (conversation_id, client_request_id)
    where client_request_id is not null;

alter table public.conversation_messages enable row level security;

drop policy if exists "users read messages in own conversations"   on public.conversation_messages;
drop policy if exists "users insert messages in own conversations" on public.conversation_messages;

create policy "users read messages in own conversations"
    on public.conversation_messages for select
    using (
        exists (
            select 1 from public.conversations c
            where c.id = conversation_id and c.user_id = auth.uid()
        )
    );

create policy "users insert messages in own conversations"
    on public.conversation_messages for insert
    with check (
        exists (
            select 1 from public.conversations c
            where c.id = conversation_id and c.user_id = auth.uid()
        )
    );

-- Note: no UPDATE / DELETE policies. Messages are append-only from a user
-- perspective. The worker (service_role) is the only writer in practice
-- — RLS exists to defend the read path and to keep the rare "what if the
-- client-side library tried" case fail-closed.
