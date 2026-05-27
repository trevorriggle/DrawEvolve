-- Eve conversation list previews — denormalized first user message.
-- =========================================================================
-- How to apply:
--   1. Open the Supabase dashboard for project `jkjfcjptzvieaonrmkzd`.
--   2. SQL Editor → + New query → paste this file → Run.
--   3. Re-runnable safely (column add is guarded; backfill skips already-
--      populated rows).
--
-- What it does:
--   - Adds `first_user_message text` to public.conversations. Nullable
--     because (a) just-created conversations have no messages yet, and
--     (b) it stays nullable in steady state for rows whose first user
--     message is genuinely empty (defensive — shouldn't happen, but the
--     column never being NOT NULL keeps the worker's insert path simple).
--   - Backfills every existing conversation from its earliest
--     conversation_messages row where role = 'user'.
--
-- Why this column exists:
--   The Eve list UI ships in this same change wave to render the first
--   user message as the row preview (replaces the stripped-down `title`
--   column for new conversations — title stays for back-compat reads on
--   pre-0016 rows). Storing it denormalized avoids a per-row
--   conversation_messages join on every list fetch. The forward-path
--   writer lives in routes/eve.js handleSendMessage, gated by the same
--   "first message" condition that derives `title` today.
--
-- What it does NOT do:
--   - Add a trigger to keep first_user_message in sync if the first
--     message is edited later. The product doesn't support editing
--     past turns; if that lands, this column becomes a denormalization
--     hazard and we'll need an UPDATE trigger or app-side guard.
--   - Touch the `title` column. Stays as-is (read-only back-compat for
--     old rows; writes stop in the worker route change in this wave).
-- =========================================================================


-- =========================================================================
-- 1. Column
-- =========================================================================

alter table public.conversations
    add column if not exists first_user_message text;


-- =========================================================================
-- 2. Backfill
-- =========================================================================

-- Correlated subquery; one round-trip per row. Small user base (<10k
-- conversations expected at deploy time), so the simple form is fine.
-- If this ever grows: rewrite as a LATERAL join or materialize the
-- per-conversation first user message into a CTE before the UPDATE.
-- The `where first_user_message is null` guard makes this re-runnable
-- as a no-op once everything's populated.
--
-- Storage cap: left(content, 500). Mirrors the worker-side cap in
-- lib/supabase.js (FIRST_USER_MESSAGE_MAX_CHARS). Anything beyond 500
-- chars is dead weight in list payloads; iOS truncates further at
-- display time (word-boundary aware). No ellipsis on storage — the
-- display layer adds its own.

update public.conversations c
   set first_user_message = (
       select left(content, 500)
         from public.conversation_messages
        where conversation_id = c.id
          and role = 'user'
        order by created_at asc
        limit 1
   )
 where first_user_message is null;
