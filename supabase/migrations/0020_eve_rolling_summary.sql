-- Feature 2, Phase 2A.x — Eve rolling per-conversation summary.
-- =========================================================================
-- How to apply:
--   1. Open the Supabase dashboard for project `jkjfcjptzvieaonrmkzd`.
--   2. SQL Editor → + New query → paste this file → Run.
--   3. Re-runnable safely (every statement is idempotent).
--
-- What it does:
--   - rolling_summary text — the latest condensed memory of older turns.
--     NULL when no summary has been generated yet for this conversation.
--   - rolling_summary_through_created_at timestamptz — the created_at of
--     the LAST message included in the latest summary. The send-path
--     tail fetch reads messages with created_at > this value; everything
--     older is represented by `rolling_summary` text.
--   - rolling_summary_generated_at timestamptz — telemetry + staleness
--     check. Used by the post-turn regen orchestrator to skip
--     near-simultaneous regens (R2 tier 1 in the design proposal).
--   - rolling_summary_version smallint NOT NULL DEFAULT 1 — schema-shape
--     versioning. Bump when SUMMARY_SYSTEM_PROMPT changes in a way that
--     affects output interpretation; lib/eve-prompt.js renderer can then
--     branch on version. Default 1 matches lib/eve-summary.js
--     SUMMARY_PROMPT_VERSION at the time this migration ships.
--
-- Why columns (not a new table):
--   The send path already fetches the conversation row via getConversation
--   (cloudflare-worker/lib/supabase.js). Adding columns means zero new
--   round-trips on the hot path. A side-table would force a JOIN or an
--   extra Promise.all slot — avoidable cost.
--
-- Why through_created_at (not _through_message_id or _through_message_count):
--   created_at lines up with the existing index
--   conversation_messages_conversation_idx (conversation_id, created_at asc)
--   from 0012_eve_conversations.sql. Tail query becomes a single
--   index lookup. message_count is best-effort (the bumpConversationCounters
--   race documented at lib/supabase.js:312-318) so it would inherit drift
--   if used as a summary boundary.
--
-- What it does NOT do:
--   - No backfill SQL. Existing conversations get rolling_summary = NULL
--     on first hit; weak-first-send hydration falls back to "raw tail
--     only" and post-turn regen populates the column. See proposal §5.
--   - No RLS policy changes — the new columns inherit the existing
--     `users read/update own conversations` policies from 0012.
--   - No new index. The summary columns are only read after fetching the
--     conversation by id; no new query pattern needs indexing.
-- =========================================================================


-- =========================================================================
-- 1. Add rolling summary columns to public.conversations
-- =========================================================================

alter table public.conversations
    add column if not exists rolling_summary text,
    add column if not exists rolling_summary_through_created_at timestamptz,
    add column if not exists rolling_summary_generated_at timestamptz,
    add column if not exists rolling_summary_version smallint not null default 1;

-- Idempotency note: `add column if not exists … not null default 1` on a
-- re-run where the column already exists is a no-op. On first run against
-- a populated table, Postgres backfills existing rows with the default,
-- which is the intended behavior (every existing conversation gets
-- version=1).
