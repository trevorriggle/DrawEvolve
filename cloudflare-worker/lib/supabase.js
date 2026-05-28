// Thin Supabase REST wrapper. Adds service-role auth headers and the rest/v1
// base path so future route handlers don't repeat the same boilerplate. The
// existing feedback handler (routes/feedback.js) still uses inline fetch for
// its PostgREST calls — keeping that diff out of this refactor preserves
// behavior bit-for-bit. New routes added later should use this helper.
//
// Returns the Response unchanged — caller decides how to interpret status
// and parse the body. Throws only if env config is missing.

import { formatRelativeTime } from './time.js';
import { parseCritiqueSummary } from './critique-summary.js';

export async function supabaseFetch(env, path, init = {}) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY not configured');
  }
  const url = `${env.SUPABASE_URL}/rest/v1${path}`;
  const headers = {
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    Accept: 'application/json',
    ...(init.headers ?? {}),
  };
  return fetch(url, { ...init, headers });
}

// =============================================================================
// Cross-drawing registry — Feature 1, Phase 1A
// =============================================================================
//
// `fetchUserDrawingRegistry` powers the cross-drawing coaching prompt block.
// Returns up to `limit` of the calling user's most recently-updated drawings
// (excluding the current one), projected to a compact registry shape that
// the prompt builder renders into the user-role message.
//
// Per the spec:
//   - Order by updated_at desc (uses existing drawings_user_id_idx).
//   - No time window — recency is bounded only by `limit`.
//   - Exclude the drawing being critiqued right now.
//   - Include drawings with at least one critique (jsonb_array_length > 0)
//     OR drawings that are still uncritiqued (so "you have a new piece going"
//     is surface-able). We pull more rows than `limit` from Postgres and
//     filter/cap on the JS side so the SQL stays one PostgREST call without
//     a custom RPC.
//   - `relative_time` is pre-computed against `now` so the prompt builder
//     stays pure (Option B from the spec).
//
// On any fetch failure: returns []. Caller renders nothing. Critique still
// generates without cross-drawing context — graceful degradation.

const REGISTRY_FETCH_OVERSHOOT = 20; // raw rows pulled; trimmed to limit after filtering

export async function fetchUserDrawingRegistry({
  env,
  userId,
  excludeDrawingId,
  limit = 10,
  now = Date.now(),
  fetcher = fetch,
}) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) return [];
  if (!userId) return [];

  const fetchLimit = Math.max(limit + REGISTRY_FETCH_OVERSHOOT, limit);
  const url = `${env.SUPABASE_URL}/rest/v1/drawings`
    + `?user_id=eq.${encodeURIComponent(userId)}`
    + `&select=id,title,context,created_at,updated_at,critique_history`
    + `&order=updated_at.desc`
    + `&limit=${fetchLimit}`;

  let rows;
  try {
    const res = await fetcher(url, {
      headers: {
        apikey: env.SUPABASE_SERVICE_ROLE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
        Accept: 'application/json',
      },
    });
    if (!res.ok) {
      console.error('[registry] non-ok status', res.status);
      return [];
    }
    rows = await res.json();
  } catch (err) {
    console.error('[registry] fetch threw', err?.message);
    return [];
  }
  if (!Array.isArray(rows)) return [];

  const excludeLower = typeof excludeDrawingId === 'string'
    ? excludeDrawingId.toLowerCase()
    : null;

  const out = [];
  // Allow up to 2 uncritiqued in-progress drawings so a user with mostly
  // new work still gets the "you have a new piece going" signal, without
  // letting an enormous sketches-only portfolio drown out critiqued rows.
  let uncritiquedSlots = 2;

  for (const row of rows) {
    if (out.length >= limit) break;
    if (!row || typeof row.id !== 'string') continue;
    if (excludeLower && row.id.toLowerCase() === excludeLower) continue;

    const history = Array.isArray(row.critique_history) ? row.critique_history : [];
    const hasCritique = history.length > 0;

    if (!hasCritique) {
      if (uncritiquedSlots <= 0) continue;
      uncritiquedSlots -= 1;
    }

    out.push(projectRegistryRow(row, history, now));
  }

  return out;
}

// =============================================================================
// Eve conversations — Feature 2, Phase 2A
// =============================================================================
//
// Worker-side helpers for the Eve conversational coach. All run with the
// service-role key; RLS is enforced ourselves via user_id / conversation_id
// WHERE clauses for ownership. Soft-delete is the only delete shape: the
// `deleted_at` column gets stamped, and every read filters on
// `deleted_at is null` (or its index-friendly equivalent).

const CONVERSATION_BASE_COLUMNS = [
  'id',
  'user_id',
  'title',
  'first_user_message',
  'scope',
  'scope_drawing_id',
  'scope_critique_sequence',
  'client_request_id',
  'created_at',
  'updated_at',
  'last_message_at',
  'message_count',
  'total_input_tokens',
  'total_output_tokens',
  'deleted_at',
  // Phase 2A.x — rolling summary (per-conversation continuity).
  // See supabase/migrations/0020_eve_rolling_summary.sql + lib/eve-summary.js.
  // Selecting these on the existing getConversation fetch means hydration
  // pays zero added round-trips for the new summary path.
  'rolling_summary',
  'rolling_summary_through_created_at',
  'rolling_summary_generated_at',
  'rolling_summary_version',
].join(',');

const MESSAGE_BASE_COLUMNS = [
  'id',
  'conversation_id',
  'role',
  'content',
  'tool_calls',
  'tool_call_id',
  'attached_drawing_id',
  'client_request_id',
  'created_at',
  'prompt_token_count',
  'completion_token_count',
  'persona_version',
  'product_context_version',
].join(',');

function supabaseHeaders(env, extra = {}) {
  return {
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    Accept: 'application/json',
    ...extra,
  };
}

/**
 * Insert a new row into public.conversations. The worker passes the
 * scope-specific fields explicitly so the contract is visible at the
 * call site. `client_request_id` is the conversation-creation
 * idempotency key (separate from per-message idempotency); a retry of
 * the same `client_request_id` returns the existing row via the unique
 * constraint and a follow-up SELECT.
 *
 * Returns the inserted row. Throws on non-2xx with the Supabase error
 * body in the message so the route handler's logging shows the real
 * cause (missing migration, broken FK, etc.).
 */
export async function createConversation({
  env,
  userId,
  scope,
  scopeDrawingId = null,
  scopeCritiqueSequence = null,
  title = null,
  clientRequestId = null,
  fetcher = fetch,
}) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('createConversation: env not configured');
  }
  const url = `${env.SUPABASE_URL}/rest/v1/conversations`;
  const res = await fetcher(url, {
    method: 'POST',
    headers: supabaseHeaders(env, {
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
    }),
    body: JSON.stringify({
      user_id: userId,
      scope,
      scope_drawing_id: scopeDrawingId,
      scope_critique_sequence: scopeCritiqueSequence,
      title,
      client_request_id: clientRequestId,
    }),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '<unreadable>');
    throw new Error(`createConversation HTTP ${res.status}: ${body.slice(0, 500)}`);
  }
  const rows = await res.json();
  return Array.isArray(rows) && rows.length > 0 ? rows[0] : null;
}

/**
 * Fetch a single conversation by id, scoped to the calling user.
 * Soft-deleted rows are filtered out — callers see the same not-found
 * shape whether the row never existed, belongs to another user, or is
 * soft-deleted. (Defense in depth: a leaked id should not differentiate.)
 *
 * Returns the row or null. Throws on non-2xx.
 */
export async function getConversation({ env, userId, conversationId, fetcher = fetch }) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('getConversation: env not configured');
  }
  const url = `${env.SUPABASE_URL}/rest/v1/conversations`
    + `?id=eq.${encodeURIComponent(conversationId)}`
    + `&user_id=eq.${encodeURIComponent(userId)}`
    + `&deleted_at=is.null`
    + `&select=${CONVERSATION_BASE_COLUMNS}`
    + `&limit=1`;
  const res = await fetcher(url, { headers: supabaseHeaders(env) });
  if (!res.ok) {
    const body = await res.text().catch(() => '<unreadable>');
    throw new Error(`getConversation HTTP ${res.status}: ${body.slice(0, 500)}`);
  }
  const rows = await res.json();
  return Array.isArray(rows) && rows.length > 0 ? rows[0] : null;
}

/**
 * List the calling user's conversations, newest activity first. Soft-
 * deleted rows are filtered. `limit` is bounded (caller passes whatever
 * the route validates against). No pagination tokens in 2A — list view
 * UI ships in 2B and will land them then.
 */
export async function listConversations({ env, userId, limit = 50, fetcher = fetch }) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('listConversations: env not configured');
  }
  const url = `${env.SUPABASE_URL}/rest/v1/conversations`
    + `?user_id=eq.${encodeURIComponent(userId)}`
    + `&deleted_at=is.null`
    + `&select=${CONVERSATION_BASE_COLUMNS}`
    + `&order=last_message_at.desc`
    + `&limit=${limit}`;
  const res = await fetcher(url, { headers: supabaseHeaders(env) });
  if (!res.ok) {
    const body = await res.text().catch(() => '<unreadable>');
    throw new Error(`listConversations HTTP ${res.status}: ${body.slice(0, 500)}`);
  }
  const rows = await res.json();
  return Array.isArray(rows) ? rows : [];
}

/**
 * Soft-delete a conversation. Idempotent: PATCHing an already-deleted
 * row updates zero rows and returns []. Returns true when one row was
 * affected, false otherwise. Caller maps to 200 / 404.
 *
 * Future cleanup (NOT shipped here): a cron job to hard-delete rows
 * where deleted_at < now() - interval '90 days'. Right now soft-deleted
 * rows accumulate forever (no growth pressure since they're filtered
 * out of every read), but eventually we'll want to reclaim the storage.
 * Tracked as a followup; do not add here without a separate proposal.
 */
export async function softDeleteConversation({ env, userId, conversationId, fetcher = fetch }) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('softDeleteConversation: env not configured');
  }
  const url = `${env.SUPABASE_URL}/rest/v1/conversations`
    + `?id=eq.${encodeURIComponent(conversationId)}`
    + `&user_id=eq.${encodeURIComponent(userId)}`
    + `&deleted_at=is.null`;
  const res = await fetcher(url, {
    method: 'PATCH',
    headers: supabaseHeaders(env, {
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
    }),
    body: JSON.stringify({ deleted_at: new Date().toISOString() }),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '<unreadable>');
    throw new Error(`softDeleteConversation HTTP ${res.status}: ${body.slice(0, 500)}`);
  }
  const rows = await res.json();
  return Array.isArray(rows) && rows.length > 0;
}

/**
 * Insert one row into public.conversation_messages and bump the parent
 * conversation's counters in the same logical operation. PostgREST
 * doesn't give us a multi-statement transaction, so this is two fetches
 * — the message insert + the conversation PATCH. Race window: a
 * concurrent message insert under the same conversation could land
 * between these two writes, leaving message_count off by one. That's
 * acceptable for a soft analytics counter (the canonical count is
 * always SELECT count(*) on conversation_messages). Token totals carry
 * the same caveat. Hard ordering requires a Postgres function; deferred.
 *
 * Returns the inserted message row.
 */
export async function appendMessage({
  env,
  conversationId,
  role,
  content,
  toolCalls = null,
  toolCallId = null,
  attachedDrawingId = null,
  clientRequestId = null,
  promptTokenCount = null,
  completionTokenCount = null,
  personaVersion = null,
  productContextVersion = null,
  fetcher = fetch,
}) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('appendMessage: env not configured');
  }
  const url = `${env.SUPABASE_URL}/rest/v1/conversation_messages`;
  const res = await fetcher(url, {
    method: 'POST',
    headers: supabaseHeaders(env, {
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
    }),
    body: JSON.stringify({
      conversation_id: conversationId,
      role,
      content,
      tool_calls: toolCalls,
      tool_call_id: toolCallId,
      attached_drawing_id: attachedDrawingId,
      client_request_id: clientRequestId,
      prompt_token_count: promptTokenCount,
      completion_token_count: completionTokenCount,
      persona_version: personaVersion,
      product_context_version: productContextVersion,
    }),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '<unreadable>');
    throw new Error(`appendMessage HTTP ${res.status}: ${body.slice(0, 500)}`);
  }
  const rows = await res.json();
  return Array.isArray(rows) && rows.length > 0 ? rows[0] : null;
}

/**
 * Bump conversation counters after a successful turn. Fire-and-forget
 * from the caller (the user-visible response shouldn't wait on this).
 *
 * `incrementBy` is the message-count delta — typically 2 for a user
 * turn + an assistant turn, but the caller passes the actual count so
 * tool turns can bump by 3+ in 2C without changing this helper.
 */
export async function bumpConversationCounters({
  env,
  conversationId,
  incrementBy = 2,
  inputTokens = 0,
  outputTokens = 0,
  fetcher = fetch,
}) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('bumpConversationCounters: env not configured');
  }
  // Read-modify-write — same shape as incrementDailySpend in rate-limit.js.
  // PostgREST has no atomic increment without an RPC; the small undercount
  // possible under concurrent writes is acceptable for soft counters.
  const readUrl = `${env.SUPABASE_URL}/rest/v1/conversations`
    + `?id=eq.${encodeURIComponent(conversationId)}`
    + `&select=message_count,total_input_tokens,total_output_tokens&limit=1`;
  const readRes = await fetcher(readUrl, { headers: supabaseHeaders(env) });
  if (!readRes.ok) {
    throw new Error(`bumpConversationCounters read HTTP ${readRes.status}`);
  }
  const rows = await readRes.json();
  const row = Array.isArray(rows) && rows.length > 0 ? rows[0] : null;
  if (!row) throw new Error('bumpConversationCounters: conversation not found');

  const nextMessageCount = (row.message_count ?? 0) + incrementBy;
  const nextInput = (row.total_input_tokens ?? 0) + (inputTokens ?? 0);
  const nextOutput = (row.total_output_tokens ?? 0) + (outputTokens ?? 0);

  const writeUrl = `${env.SUPABASE_URL}/rest/v1/conversations`
    + `?id=eq.${encodeURIComponent(conversationId)}`;
  const writeRes = await fetcher(writeUrl, {
    method: 'PATCH',
    headers: supabaseHeaders(env, {
      'Content-Type': 'application/json',
      Prefer: 'return=minimal',
    }),
    body: JSON.stringify({
      message_count: nextMessageCount,
      total_input_tokens: nextInput,
      total_output_tokens: nextOutput,
      last_message_at: new Date().toISOString(),
    }),
  });
  if (!writeRes.ok) {
    throw new Error(`bumpConversationCounters write HTTP ${writeRes.status}`);
  }
}

/**
 * Pulls the full message history for a conversation in chronological
 * order. The `limit` ceiling caps how many turns we feed back into Eve
 * on a fresh request — even with `EVE_MAX_TURNS_PER_CONVERSATION` at
 * 100, only the most recent N feed the prompt to keep token cost flat.
 *
 * In 2A this returns ALL messages (limit defaults to 100) — sliding-
 * window summarization is a 2C+ concern. The caller is responsible for
 * truncation if needed.
 */
export async function getConversationHistory({
  env,
  conversationId,
  limit = 100,
  fetcher = fetch,
}) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('getConversationHistory: env not configured');
  }
  const url = `${env.SUPABASE_URL}/rest/v1/conversation_messages`
    + `?conversation_id=eq.${encodeURIComponent(conversationId)}`
    + `&select=${MESSAGE_BASE_COLUMNS}`
    + `&order=created_at.asc`
    + `&limit=${limit}`;
  const res = await fetcher(url, { headers: supabaseHeaders(env) });
  if (!res.ok) {
    const body = await res.text().catch(() => '<unreadable>');
    throw new Error(`getConversationHistory HTTP ${res.status}: ${body.slice(0, 500)}`);
  }
  const rows = await res.json();
  return Array.isArray(rows) ? rows : [];
}

/**
 * Returns the most recent `limit` messages whose created_at is strictly
 * greater than `afterCreatedAt`. When `afterCreatedAt` is null/undefined,
 * returns the most recent `limit` messages overall — used during the
 * weak-first-send backfill path described in the rolling-summary
 * proposal §5 (existing conversations with no summary yet).
 *
 * Always returns rows in chronological (asc) order to match what
 * buildEveMessages expects. The two query shapes:
 *   - afterCreatedAt set: ORDER BY created_at ASC, filter `gt`. Index
 *     does the work directly via
 *     conversation_messages_conversation_idx (conversation_id, created_at asc).
 *   - afterCreatedAt null: ORDER BY created_at DESC + LIMIT, then reverse
 *     client-side to get chronological order. PostgREST has no native
 *     `last N` primitive, so the DESC fetch is the only way to bound the
 *     scan to the tail without pulling all rows.
 *
 * `limit` is a hard cap on rows returned, not a window-after-summary
 * count. Callers pick the value (hydration uses readEveRawTailMessages;
 * post-turn regen passes a generous cap so it sees everything past the
 * summary boundary).
 */
export async function getConversationTail({
  env,
  conversationId,
  afterCreatedAt,
  limit,
  fetcher = fetch,
}) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('getConversationTail: env not configured');
  }
  const hasBoundary = typeof afterCreatedAt === 'string' && afterCreatedAt.length > 0;
  const params = [
    `conversation_id=eq.${encodeURIComponent(conversationId)}`,
    `select=${MESSAGE_BASE_COLUMNS}`,
    `limit=${limit}`,
  ];
  if (hasBoundary) {
    params.push(`created_at=gt.${encodeURIComponent(afterCreatedAt)}`);
    params.push('order=created_at.asc');
  } else {
    params.push('order=created_at.desc');
  }
  const url = `${env.SUPABASE_URL}/rest/v1/conversation_messages?${params.join('&')}`;
  const res = await fetcher(url, { headers: supabaseHeaders(env) });
  if (!res.ok) {
    const body = await res.text().catch(() => '<unreadable>');
    throw new Error(`getConversationTail HTTP ${res.status}: ${body.slice(0, 500)}`);
  }
  const rows = await res.json();
  if (!Array.isArray(rows)) return [];
  // DESC fetch needs reversing to give the caller chronological order.
  // ASC fetch is already chronological.
  return hasBoundary ? rows : [...rows].reverse();
}

/**
 * PATCH the four rolling_summary_* columns on a conversation row in a
 * single write. Caller fire-and-forgets via ctx.waitUntil so a failure
 * here doesn't block the user's response (see proposal §3 + R3).
 *
 * Last-write-wins under concurrent regen — the proposal's R2 tier 1
 * accepts this for v1. If we add the conditional-PATCH lock (R2 tier 2)
 * later, the gate goes on the URL as a `rolling_summary_generated_at=lt.<t>`
 * filter, not inside this helper.
 */
export async function updateConversationRollingSummary({
  env,
  conversationId,
  summary,
  throughCreatedAt,
  generatedAt,
  promptVersion,
  fetcher = fetch,
}) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('updateConversationRollingSummary: env not configured');
  }
  const url = `${env.SUPABASE_URL}/rest/v1/conversations`
    + `?id=eq.${encodeURIComponent(conversationId)}`;
  const res = await fetcher(url, {
    method: 'PATCH',
    headers: supabaseHeaders(env, {
      'Content-Type': 'application/json',
      Prefer: 'return=minimal',
    }),
    body: JSON.stringify({
      rolling_summary: summary,
      rolling_summary_through_created_at: throughCreatedAt,
      rolling_summary_generated_at: generatedAt,
      rolling_summary_version: promptVersion,
    }),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '<unreadable>');
    throw new Error(`updateConversationRollingSummary HTTP ${res.status}: ${body.slice(0, 500)}`);
  }
}

/**
 * Update the title on a conversation row, but only when it is still
 * null. The `&title=is.null` filter is the safety net for the lazy-
 * backfill path: even if two concurrent first-message sends or two
 * concurrent list-load backfills race, the second PATCH no-ops instead
 * of clobbering a freshly-derived title. Fire-and-forget from callers
 * — the user-visible response shouldn't wait on this.
 *
 * Still used by the lazy-backfill path in handleListConversations
 * (back-compat for pre-0016 rows that have title=null AND first_user_message
 * non-null after the migration). The forward path in handleSendMessage
 * no longer calls this — new conversations populate first_user_message
 * instead (see updateConversationFirstUserMessage below).
 */
export async function updateConversationTitle({
  env,
  conversationId,
  title,
  fetcher = fetch,
}) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('updateConversationTitle: env not configured');
  }
  const url = `${env.SUPABASE_URL}/rest/v1/conversations`
    + `?id=eq.${encodeURIComponent(conversationId)}`
    + `&title=is.null`;
  const res = await fetcher(url, {
    method: 'PATCH',
    headers: supabaseHeaders(env, {
      'Content-Type': 'application/json',
      Prefer: 'return=minimal',
    }),
    body: JSON.stringify({ title }),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '<unreadable>');
    throw new Error(`updateConversationTitle HTTP ${res.status}: ${body.slice(0, 500)}`);
  }
}

/**
 * Hard cap on the stored length of first_user_message. Anything beyond
 * this is dead weight in list payloads — iOS truncates display down to
 * ~60 chars (row) or ~40 chars (nav title) anyway. No ellipsis on
 * storage; the iOS display layer adds its own when truncating further.
 * Mirrored in supabase/migrations/0016 backfill (left(content, 500)).
 */
export const FIRST_USER_MESSAGE_MAX_CHARS = 500;

/**
 * Cap firstUserMessage at FIRST_USER_MESSAGE_MAX_CHARS for storage.
 * Exposed so the handleSendMessage in-memory mirror can match what was
 * persisted (response carries the truncated value, not the raw input).
 */
export function capFirstUserMessageForStorage(content) {
  if (typeof content !== 'string') return content;
  return content.length > FIRST_USER_MESSAGE_MAX_CHARS
    ? content.slice(0, FIRST_USER_MESSAGE_MAX_CHARS)
    : content;
}

/**
 * Stamp the first user message onto a conversation row, gated on
 * first_user_message=is.null so concurrent first-message races (or a
 * future runtime backfill) can't clobber. Fire-and-forget from
 * handleSendMessage on the first-message gate.
 *
 * Storage policy: caps at FIRST_USER_MESSAGE_MAX_CHARS to keep list
 * payloads bounded. No ellipsis on storage. iOS truncates further for
 * display (word-boundary aware, ~60 chars in list rows, ~40 chars in
 * nav title) — see Phase 3d.
 *
 * Replaces updateConversationTitle on the forward path (per Path Y).
 * Old conversations with title populated stay as-is; the iOS client
 * reads first_user_message > title > "New chat" fallback.
 */
export async function updateConversationFirstUserMessage({
  env,
  conversationId,
  firstUserMessage,
  fetcher = fetch,
}) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('updateConversationFirstUserMessage: env not configured');
  }
  const stored = capFirstUserMessageForStorage(firstUserMessage);
  const url = `${env.SUPABASE_URL}/rest/v1/conversations`
    + `?id=eq.${encodeURIComponent(conversationId)}`
    + `&first_user_message=is.null`;
  const res = await fetcher(url, {
    method: 'PATCH',
    headers: supabaseHeaders(env, {
      'Content-Type': 'application/json',
      Prefer: 'return=minimal',
    }),
    body: JSON.stringify({ first_user_message: stored }),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '<unreadable>');
    throw new Error(`updateConversationFirstUserMessage HTTP ${res.status}: ${body.slice(0, 500)}`);
  }
}

/**
 * Count the user's active (non-deleted, non-empty) conversations.
 * Used by the cap-enforcement path in handleCreateConversation —
 * the cap (MAX_ACTIVE_CONVERSATIONS in routes/eve.js) only counts
 * conversations with message_count > 0, so empty drafts created by
 * the iOS "+ New Chat" flow don't trip eviction until they receive
 * a message.
 *
 * Uses PostgREST's `Prefer: count=exact` header + a tiny SELECT to
 * get the total without fetching rows. Content-Range comes back as
 * "0-N/total" or "* /0" when empty — we parse the slash-delimited
 * total. Returns 0 on any header parse error so the cap path fails
 * open rather than blocking creates.
 */
export async function countActiveConversations({ env, userId, fetcher = fetch }) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('countActiveConversations: env not configured');
  }
  const url = `${env.SUPABASE_URL}/rest/v1/conversations`
    + `?user_id=eq.${encodeURIComponent(userId)}`
    + `&deleted_at=is.null`
    + `&message_count=gt.0`
    + `&select=id`;
  const res = await fetcher(url, {
    headers: supabaseHeaders(env, {
      Prefer: 'count=exact',
      Range: '0-0',
    }),
  });
  if (!res.ok && res.status !== 206) {
    const body = await res.text().catch(() => '<unreadable>');
    throw new Error(`countActiveConversations HTTP ${res.status}: ${body.slice(0, 500)}`);
  }
  const contentRange = res.headers.get('content-range') || '';
  const slash = contentRange.lastIndexOf('/');
  if (slash < 0) return 0;
  const totalStr = contentRange.slice(slash + 1).trim();
  const total = parseInt(totalStr, 10);
  return Number.isFinite(total) ? total : 0;
}

/**
 * Find the user's oldest active+non-empty conversation by last_message_at
 * and soft-delete it. Returns the evicted conversation's id, or null if
 * the user has no active conversations to evict (shouldn't happen on the
 * cap-enforcement path since the caller already counted ≥ cap, but
 * defensive). Two round-trips: a SELECT to find the victim, a PATCH to
 * stamp deleted_at. Not atomic with the subsequent INSERT in
 * handleCreateConversation — see the race-condition note there.
 */
export async function evictOldestActiveConversation({ env, userId, fetcher = fetch }) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('evictOldestActiveConversation: env not configured');
  }
  const selectUrl = `${env.SUPABASE_URL}/rest/v1/conversations`
    + `?user_id=eq.${encodeURIComponent(userId)}`
    + `&deleted_at=is.null`
    + `&message_count=gt.0`
    + `&select=id`
    + `&order=last_message_at.asc`
    + `&limit=1`;
  const selRes = await fetcher(selectUrl, { headers: supabaseHeaders(env) });
  if (!selRes.ok) {
    const body = await selRes.text().catch(() => '<unreadable>');
    throw new Error(`evictOldestActiveConversation SELECT HTTP ${selRes.status}: ${body.slice(0, 500)}`);
  }
  const rows = await selRes.json();
  const victim = Array.isArray(rows) && rows.length > 0 ? rows[0] : null;
  if (!victim?.id) return null;

  const ok = await softDeleteConversation({
    env, userId, conversationId: victim.id, fetcher,
  });
  return ok ? victim.id : null;
}

/**
 * Fetch the first user message in a conversation, ordered by created_at
 * ascending. Used by the lazy-backfill path to derive a title for older
 * conversations that pre-date the auto-naming feature. Returns the row
 * (with at least `content`) or null when the conversation has no user
 * messages yet (newly-created and untouched, or in a corrupt state).
 */
export async function fetchFirstUserMessage({
  env,
  conversationId,
  fetcher = fetch,
}) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) return null;
  if (!conversationId) return null;
  const url = `${env.SUPABASE_URL}/rest/v1/conversation_messages`
    + `?conversation_id=eq.${encodeURIComponent(conversationId)}`
    + `&role=eq.user`
    + `&select=content`
    + `&order=created_at.asc`
    + `&limit=1`;
  try {
    const res = await fetcher(url, { headers: supabaseHeaders(env) });
    if (!res.ok) return null;
    const rows = await res.json();
    return Array.isArray(rows) && rows.length > 0 ? rows[0] : null;
  } catch {
    return null;
  }
}

/**
 * Look up an existing assistant message with the same per-conversation
 * client_request_id. Used for idempotency on retried send-message calls:
 * if a row already exists, return it verbatim instead of calling OpenAI
 * again. Returns the row or null.
 */
export async function findMessageByClientRequestId({
  env,
  conversationId,
  clientRequestId,
  fetcher = fetch,
}) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) return null;
  if (!conversationId || !clientRequestId) return null;
  const url = `${env.SUPABASE_URL}/rest/v1/conversation_messages`
    + `?conversation_id=eq.${encodeURIComponent(conversationId)}`
    + `&client_request_id=eq.${encodeURIComponent(clientRequestId)}`
    + `&role=eq.assistant`
    + `&select=${MESSAGE_BASE_COLUMNS}`
    + `&limit=1`;
  try {
    const res = await fetcher(url, { headers: supabaseHeaders(env) });
    if (!res.ok) return null;
    const rows = await res.json();
    return Array.isArray(rows) && rows.length > 0 ? rows[0] : null;
  } catch {
    return null;
  }
}

/**
 * Hydrate the critique a conversation is scoped to. Reads
 * drawings.critique_history, plucks the entry at `sequence`, returns
 * the projected shape buildEveSystemPrompt expects (title, subject,
 * sequence_number, content). Returns null on any failure — the caller
 * falls back to the no-critique path, which means scope='drawing'
 * conversations without a usable critique behave like scope='general'.
 *
 * Sequence number is 1-indexed (matches buildCritiqueEntry).
 */
export async function fetchCritiqueForConversation({
  env,
  userId,
  drawingId,
  sequenceNumber,
  fetcher = fetch,
}) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) return null;
  if (!drawingId || typeof sequenceNumber !== 'number') return null;
  const url = `${env.SUPABASE_URL}/rest/v1/drawings`
    + `?id=eq.${encodeURIComponent(drawingId)}`
    + `&user_id=eq.${encodeURIComponent(userId)}`
    + `&select=id,title,context,critique_history`
    + `&limit=1`;
  try {
    const res = await fetcher(url, { headers: supabaseHeaders(env) });
    if (!res.ok) return null;
    const rows = await res.json();
    const row = Array.isArray(rows) && rows.length > 0 ? rows[0] : null;
    if (!row) return null;
    const history = Array.isArray(row.critique_history) ? row.critique_history : [];
    // Sequence is 1-indexed in the persisted entry. Find by sequence_number
    // rather than slice index so a non-contiguous (legacy) row still works.
    const entry = history.find((e) => e && e.sequence_number === sequenceNumber)
      ?? history[sequenceNumber - 1]
      ?? null;
    if (!entry || typeof entry.content !== 'string') return null;
    return {
      drawing_title: typeof row.title === 'string' ? row.title : null,
      drawing_subject: typeof row?.context?.subject === 'string' ? row.context.subject : null,
      sequence_number: typeof entry.sequence_number === 'number'
        ? entry.sequence_number
        : sequenceNumber,
      content: entry.content,
    };
  } catch (err) {
    console.error('[eve] fetchCritiqueForConversation threw', err?.message);
    return null;
  }
}

function projectRegistryRow(row, history, now) {
  const subject =
    typeof row?.context?.subject === 'string' ? row.context.subject : null;

  const lastEntry = history.length > 0 ? history[history.length - 1] : null;
  let mostRecentCritique = null;
  if (lastEntry && typeof lastEntry === 'object') {
    const tags = lastEntry.tags && typeof lastEntry.tags === 'object'
      ? lastEntry.tags
      : null;
    mostRecentCritique = {
      sequence_number: typeof lastEntry.sequence_number === 'number'
        ? lastEntry.sequence_number
        : null,
      created_at: typeof lastEntry.created_at === 'string'
        ? lastEntry.created_at
        : null,
      primary_category: tags && typeof tags.primary_category === 'string'
        ? tags.primary_category
        : null,
      focus_area_text: tags && typeof tags.focus_area_text === 'string'
        ? tags.focus_area_text
        : null,
      severity: tags && typeof tags.severity === 'number'
        ? tags.severity
        : null,
    };
  }

  return {
    drawing_id: row.id,
    title: typeof row.title === 'string' ? row.title : null,
    subject,
    created_at: typeof row.created_at === 'string' ? row.created_at : null,
    updated_at: typeof row.updated_at === 'string' ? row.updated_at : null,
    relative_time: formatRelativeTime(row.updated_at ?? row.created_at, now),
    most_recent_critique: mostRecentCritique,
  };
}

// =============================================================================
// Eve coaching context — Feature 2, Phase 2A.1
// =============================================================================
//
// fetchCoachingContext pulls the data Eve needs to coach across the user's
// portfolio without seeing the actual drawings: each drawing's title +
// subject + timestamps + last-critique tag block, plus the most recent
// critique summaries (bullet text from <!--summary-->) flattened across
// all drawings newest-first.
//
// What this DOES NOT include:
//   - Full critique markdown bodies (token bloat — Eve's own audit callout).
//     Eve sees the SUMMARY of each critique, not the whole thing.
//   - Storage paths or image data (Eve has no vision).
//   - Layered drawing manifests / per-layer info.
//
// Filters:
//   - excludeDrawingId: when scope='drawing', omit the current drawing
//     from the projected drawing list — CURRENT CONTEXT already covers it.
//   - excludeCritiqueSequence: when paired with excludeDrawingId, omit
//     that specific critique from the summaries list. Other critiques
//     on the same drawing remain eligible for summaries.
//
// Failure mode: returns { drawings: [], summaries: [] } on any error
// (env missing, fetch non-ok, throw). Caller renders nothing. Eve falls
// back to her general persona + product context posture.

const COACHING_CONTEXT_FETCH_OVERSHOOT = 10;

export async function fetchCoachingContext({
  env,
  userId,
  drawingsLimit = 20,
  summariesLimit = 10,
  excludeDrawingId = null,
  excludeCritiqueSequence = null,
  now = Date.now(),
  fetcher = fetch,
}) {
  const empty = { drawings: [], summaries: [] };
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) return empty;
  if (!userId) return empty;

  // Fetch slightly more than the drawing limit so the JS-side exclude
  // filter (current drawing) still has enough rows to fill the projection.
  const fetchLimit = Math.max(drawingsLimit + COACHING_CONTEXT_FETCH_OVERSHOOT, drawingsLimit);
  const url = `${env.SUPABASE_URL}/rest/v1/drawings`
    + `?user_id=eq.${encodeURIComponent(userId)}`
    + `&select=id,title,context,created_at,updated_at,critique_history`
    + `&order=updated_at.desc`
    + `&limit=${fetchLimit}`;

  let rows;
  try {
    const res = await fetcher(url, {
      headers: {
        apikey: env.SUPABASE_SERVICE_ROLE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
        Accept: 'application/json',
      },
    });
    if (!res.ok) {
      console.error('[coaching-context] non-ok status', res.status);
      return empty;
    }
    rows = await res.json();
  } catch (err) {
    console.error('[coaching-context] fetch threw', err?.message);
    return empty;
  }
  if (!Array.isArray(rows)) return empty;

  const excludeLower = typeof excludeDrawingId === 'string'
    ? excludeDrawingId.toLowerCase()
    : null;

  // --- drawings projection ---
  const drawings = [];
  for (const row of rows) {
    if (drawings.length >= drawingsLimit) break;
    if (!row || typeof row.id !== 'string') continue;
    if (excludeLower && row.id.toLowerCase() === excludeLower) continue;

    const history = Array.isArray(row.critique_history) ? row.critique_history : [];
    drawings.push(projectCoachingDrawing(row, history, now));
  }

  // --- summaries projection ---
  // Walk every drawing's critique_history, flatten into a single list
  // sorted by critique created_at desc, take the top N. The excluded
  // (drawing, sequence) pair is dropped here too — that specific critique
  // is already in CURRENT CONTEXT verbatim, no need to repeat its summary.
  const flattened = [];
  for (const row of rows) {
    if (!row || typeof row.id !== 'string') continue;
    const history = Array.isArray(row.critique_history) ? row.critique_history : [];
    const isExcludedDrawing = excludeLower && row.id.toLowerCase() === excludeLower;
    for (const entry of history) {
      if (!entry || typeof entry !== 'object') continue;
      if (isExcludedDrawing
          && typeof excludeCritiqueSequence === 'number'
          && entry.sequence_number === excludeCritiqueSequence) {
        continue;
      }
      if (typeof entry.content !== 'string' || entry.content.length === 0) continue;
      const bullets = parseCritiqueSummary(entry.content);
      // Drop summaries that yielded no bullets — they'd render as an
      // empty row with just a header, which is noise. The drawing
      // itself still appears in the drawings list with its last-critique
      // tag block; Eve has enough to reference it.
      if (bullets.length === 0) continue;
      flattened.push({
        drawing_id: row.id,
        drawing_title: typeof row.title === 'string' ? row.title : null,
        drawing_subject: typeof row?.context?.subject === 'string' ? row.context.subject : null,
        critique_created_at: typeof entry.created_at === 'string' ? entry.created_at : null,
        critique_sequence: typeof entry.sequence_number === 'number'
          ? entry.sequence_number : null,
        primary_category: typeof entry?.tags?.primary_category === 'string'
          ? entry.tags.primary_category : null,
        focus_area_text: typeof entry?.tags?.focus_area_text === 'string'
          ? entry.tags.focus_area_text : null,
        severity: typeof entry?.tags?.severity === 'number' ? entry.tags.severity : null,
        relative_time: formatRelativeTime(entry.created_at, now),
        summary_bullets: bullets,
        // Eye Test M4 — project the composition findings (if any)
        // into Eve's coaching context. Without this projection,
        // cross-drawing coaching ignores Composition findings.
        // renderCoachingSummaryRow consumes this in lib/eve-prompt.js.
        // Note: the prompt-side limitation framing
        // (renderCompositionFindingsBlock in lib/prompt.js) lives in
        // the per-critique system prompt, not Eve's context — Eve's
        // context renders only the lightweight summary below.
        composition_findings: entry && typeof entry.composition_findings === 'object'
          ? entry.composition_findings
          : null,
      });
    }
  }
  flattened.sort((a, b) => {
    const aTs = a.critique_created_at ? Date.parse(a.critique_created_at) : 0;
    const bTs = b.critique_created_at ? Date.parse(b.critique_created_at) : 0;
    return bTs - aTs;
  });
  const summaries = flattened.slice(0, summariesLimit);

  return { drawings, summaries };
}

function projectCoachingDrawing(row, history, now) {
  const subject = typeof row?.context?.subject === 'string' ? row.context.subject : null;

  let lastCritique = null;
  if (history.length > 0) {
    const lastEntry = history[history.length - 1];
    if (lastEntry && typeof lastEntry === 'object') {
      const tags = lastEntry.tags && typeof lastEntry.tags === 'object' ? lastEntry.tags : null;
      lastCritique = {
        created_at: typeof lastEntry.created_at === 'string' ? lastEntry.created_at : null,
        relative_time: formatRelativeTime(lastEntry.created_at, now),
        primary_category: tags && typeof tags.primary_category === 'string'
          ? tags.primary_category : null,
        focus_area_text: tags && typeof tags.focus_area_text === 'string'
          ? tags.focus_area_text : null,
        severity: tags && typeof tags.severity === 'number' ? tags.severity : null,
      };
    }
  }

  return {
    drawing_id: row.id,
    title: typeof row.title === 'string' ? row.title : null,
    subject,
    created_at: typeof row.created_at === 'string' ? row.created_at : null,
    updated_at: typeof row.updated_at === 'string' ? row.updated_at : null,
    relative_time: formatRelativeTime(row.updated_at ?? row.created_at, now),
    total_critiques: history.length,
    last_critique: lastCritique,
  };
}
