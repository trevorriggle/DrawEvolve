// /v1/eve/* — Eve conversational coach endpoints.
//
// Endpoints (all require JWT + App Attest, identical posture to /):
//   POST   /v1/eve/conversations              — create a conversation
//   GET    /v1/eve/conversations              — list this user's conversations
//   GET    /v1/eve/conversations/:id          — fetch one + its messages
//   DELETE /v1/eve/conversations/:id          — soft delete
//   POST   /v1/eve/conversations/:id/messages — send a user turn, return
//                                                full assistant response
//                                                (no streaming in 2A)
//
// Pro gating: every handler accepts a `requiresPro` flag that the dispatch
// table sets. In 2A every flag is `false` (free) because StoreKit hasn't
// shipped — but the wiring is in place so gating activates by config
// change when monetization lands.
//
// Method dispatch: index.js routes /v1/eve/conversations and
// /v1/eve/conversations/:id and /v1/eve/conversations/:id/messages here
// regardless of HTTP method. We dispatch on method internally so 405 stays
// a route concern, not a router concern.

import {
  validateJWT,
  validateWorkerConfig,
  getUserTier,
} from '../middleware/auth.js';
import {
  isAppAttestRequired,
  readAppAttestHeaders,
  getAttestedKey,
  computeAppAttestClientDataHash,
  verifyAppAttestAssertion,
  updateAttestedKeyCounter,
} from '../middleware/app-attest.js';
import {
  enforceEveRateLimits,
  recordSuccessfulEveTurn,
  readEveMaxTurnsPerConversation,
  enforceCostCeilings,
  recordRequestUsage,
} from '../middleware/rate-limit.js';
import {
  createConversation,
  getConversation,
  listConversations,
  softDeleteConversation,
  appendMessage,
  bumpConversationCounters,
  getConversationHistory,
  findMessageByClientRequestId,
  fetchCritiqueForConversation,
  fetchCoachingContext,
} from '../lib/supabase.js';
import {
  buildEveSystemPrompt,
  buildEveMessages,
  EVE_PERSONA_VERSION,
  EVE_PRODUCT_CONTEXT_VERSION,
} from '../lib/eve-prompt.js';
import { jsonResponse, unauthorized } from '../lib/http.js';

// =============================================================================
// Validation
// =============================================================================

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const VALID_SCOPES = new Set(['drawing', 'evolution', 'general']);

// Per-message content cap. 8 KB of plain text is ~2K tokens — gives the
// user room to ask a long question but blocks pasting a whole document
// as the message body. The system prompt + history are server-controlled,
// so this is the only user-controllable input that flows into the prompt.
const MAX_MESSAGE_CONTENT_BYTES = 8 * 1024;

function isValidUuid(s) {
  return typeof s === 'string' && UUID_RE.test(s);
}

// =============================================================================
// Auth + App Attest (same gate sequence as routes/feedback.js)
// =============================================================================

async function authenticate(request, env, ctx, rawBody) {
  const configErr = validateWorkerConfig(env);
  if (configErr) {
    console.error('[eve]', configErr);
    return { response: jsonResponse({ error: configErr }, 500) };
  }

  const token = request.headers.get('Authorization')?.replace(/^Bearer\s+/i, '') ?? null;
  let payload;
  try {
    payload = await validateJWT(token, env);
  } catch (err) {
    console.log('[eve] JWT validation failed', err?.message);
    return { response: unauthorized() };
  }
  const userId = payload.sub;

  if (isAppAttestRequired(env)) {
    const attestHeaders = readAppAttestHeaders(request);
    if (!attestHeaders) {
      return { response: jsonResponse({ error: 'attest_headers_missing' }, 401) };
    }
    const stored = await getAttestedKey(attestHeaders.keyId, env);
    if (!stored) {
      return { response: jsonResponse({ error: 'attest_key_unknown' }, 401) };
    }
    const expectedEnv = env.APP_ATTEST_ENV === 'production' ? 'production' : 'development';
    if (stored.env !== expectedEnv) {
      return { response: jsonResponse({ error: 'attest_env_mismatch' }, 401) };
    }
    const expectedClientDataHash = await computeAppAttestClientDataHash(
      request.method,
      new URL(request.url).pathname || '/',
      rawBody,
    );
    try {
      const { newCounter } = await verifyAppAttestAssertion({
        assertionB64: attestHeaders.assertion,
        storedPubKey: stored.pub,
        storedCounter: stored.counter,
        expectedClientDataHash,
        env,
      });
      ctx.waitUntil(updateAttestedKeyCounter(attestHeaders.keyId, newCounter, env));
    } catch (err) {
      console.log('[eve] assertion failed', err?.message);
      return { response: jsonResponse({ error: 'attest_assertion_invalid' }, 401) };
    }
  } else {
    console.log('[eve] attest enforcement disabled — request on JWT alone');
  }

  return { userId, payload };
}

/**
 * Centralized Pro gate. In 2A every endpoint passes `requiresPro: false`
 * — the wiring exists so when StoreKit ships, gating is a configuration
 * flip per route, not a refactor. The check itself reads tier from the
 * JWT app_metadata block via the existing getUserTier helper, so the
 * same auth path that drives critique tier gating drives Eve gating.
 */
function checkProGate({ payload, requiresPro }) {
  if (!requiresPro) return null;
  const { tier } = getUserTier(payload);
  if (tier !== 'pro') {
    return jsonResponse({
      error: 'pro_required',
      message: 'This feature requires DrawEvolve Pro.',
    }, 402); // 402 Payment Required — semantically correct, parsed by iOS
  }
  return null;
}

// =============================================================================
// OpenAI request tunables for Eve
// =============================================================================
//
// Same model as the critique path so behavior is consistent. Eve responses
// are conversational — shorter and less structured than a critique — so
// the max-tokens ceiling sits lower. Temperature stays at 0.4 for the
// same stability reasons documented in routes/feedback.js.
//
// reasoning_effort='none' matches production critique. If Eve consistently
// fails to integrate tool results in 2C, escalate to 'low' for Eve
// specifically without changing the critique path.

const OPENAI_MODEL = 'gpt-5.1';
const OPENAI_TEMPERATURE = 0.4;
const OPENAI_REASONING_EFFORT = 'none';
const OPENAI_MAX_OUTPUT_TOKENS = 800;

// =============================================================================
// Handlers
// =============================================================================

async function readJsonBody(request) {
  const rawBody = new Uint8Array(await request.arrayBuffer());
  let body = null;
  try { body = JSON.parse(new TextDecoder().decode(rawBody)); }
  catch { body = null; }
  return { rawBody, body };
}

/**
 * POST /v1/eve/conversations
 *
 * Body:
 *   scope: 'drawing' | 'general' (only these two in 2A — 'evolution'
 *          ships in 2C alongside the tools that read evolution data)
 *   scope_drawing_id?: uuid (required when scope='drawing')
 *   scope_critique_sequence?: int (1-indexed; defaults to "most recent"
 *          via the iOS client passing the seq from the panel)
 *   title?: string (optional, defaults to null and the iOS client
 *          synthesizes a label from scope/drawing)
 *   client_request_id?: uuid (idempotency for retried creates — a
 *          double-tap on "Ask Eve" should not produce two rows)
 *
 * Returns: { conversation }
 */
async function handleCreateConversation(request, env, ctx, requiresPro) {
  const { rawBody, body } = await readJsonBody(request);
  if (!body || typeof body !== 'object') {
    return jsonResponse({ error: 'Invalid request body' }, 400);
  }

  const auth = await authenticate(request, env, ctx, rawBody);
  if (auth.response) return auth.response;
  const { userId, payload } = auth;

  const gate = checkProGate({ payload, requiresPro });
  if (gate) return gate;

  // Scope validation. 2A accepts 'drawing' and 'general'. 'evolution'
  // is reserved in the schema but the route rejects it until 2C, when
  // the evolution tools land.
  const scope = body.scope;
  if (!VALID_SCOPES.has(scope) || scope === 'evolution') {
    return jsonResponse({ error: 'Invalid or unsupported scope' }, 400);
  }

  let scopeDrawingId = null;
  let scopeCritiqueSequence = null;
  if (scope === 'drawing') {
    if (!isValidUuid(body.scope_drawing_id)) {
      return jsonResponse({ error: 'scope_drawing_id required for scope=drawing' }, 400);
    }
    scopeDrawingId = body.scope_drawing_id.toLowerCase();
    if (body.scope_critique_sequence !== undefined && body.scope_critique_sequence !== null) {
      const seq = Number(body.scope_critique_sequence);
      if (!Number.isInteger(seq) || seq < 1) {
        return jsonResponse({ error: 'scope_critique_sequence must be a positive integer' }, 400);
      }
      scopeCritiqueSequence = seq;
    }
  }

  let title = null;
  if (body.title !== undefined && body.title !== null) {
    if (typeof body.title !== 'string' || body.title.length > 200) {
      return jsonResponse({ error: 'title must be a string under 200 chars' }, 400);
    }
    title = body.title;
  }

  let clientRequestId = null;
  if (body.client_request_id !== undefined && body.client_request_id !== null) {
    if (!isValidUuid(body.client_request_id)) {
      return jsonResponse({ error: 'client_request_id must be a lowercase UUID' }, 400);
    }
    clientRequestId = body.client_request_id;
  }

  try {
    const conversation = await createConversation({
      env, userId, scope,
      scopeDrawingId, scopeCritiqueSequence,
      title, clientRequestId,
    });
    return jsonResponse({ conversation }, 201);
  } catch (err) {
    // Unique-constraint hit on client_request_id (PostgreSQL 23505 →
    // PostgREST 409) means a retry of the same create. Look up the
    // existing row and return it so the client treats the second call
    // as idempotent success.
    if (clientRequestId && err?.message?.includes('409')) {
      const existing = await listConversations({ env, userId, limit: 50 })
        .then((rows) => rows.find((r) => r.client_request_id === clientRequestId) ?? null)
        .catch(() => null);
      if (existing) return jsonResponse({ conversation: existing }, 200);
    }
    console.error('[eve] create failed', err?.message);
    return jsonResponse({ error: 'Internal server error' }, 500);
  }
}

/**
 * GET /v1/eve/conversations
 *
 * Query params:
 *   limit?: int (default 50, max 100)
 *
 * Returns: { conversations: [...] }
 */
async function handleListConversations(request, env, ctx, requiresPro) {
  // GET requests have no body to sign with App Attest. We still validate
  // attestation if enforcement is on; the rawBody passed to authenticate
  // is the empty Uint8Array (matches the assertion contract).
  const auth = await authenticate(request, env, ctx, new Uint8Array(0));
  if (auth.response) return auth.response;
  const { userId, payload } = auth;

  const gate = checkProGate({ payload, requiresPro });
  if (gate) return gate;

  const url = new URL(request.url);
  const limitRaw = url.searchParams.get('limit');
  const limit = limitRaw ? Math.min(100, Math.max(1, parseInt(limitRaw, 10) || 50)) : 50;

  try {
    const conversations = await listConversations({ env, userId, limit });
    return jsonResponse({ conversations });
  } catch (err) {
    console.error('[eve] list failed', err?.message);
    return jsonResponse({ error: 'Internal server error' }, 500);
  }
}

/**
 * GET /v1/eve/conversations/:id
 *
 * Returns: { conversation, messages }
 */
async function handleGetConversation(request, env, ctx, conversationId, requiresPro) {
  if (!isValidUuid(conversationId)) {
    return jsonResponse({ error: 'Invalid conversation id' }, 400);
  }

  const auth = await authenticate(request, env, ctx, new Uint8Array(0));
  if (auth.response) return auth.response;
  const { userId, payload } = auth;

  const gate = checkProGate({ payload, requiresPro });
  if (gate) return gate;

  try {
    const conversation = await getConversation({ env, userId, conversationId });
    if (!conversation) {
      return jsonResponse({ error: 'Conversation not found' }, 404);
    }
    const messages = await getConversationHistory({ env, conversationId });
    return jsonResponse({ conversation, messages });
  } catch (err) {
    console.error('[eve] get failed', err?.message);
    return jsonResponse({ error: 'Internal server error' }, 500);
  }
}

/**
 * DELETE /v1/eve/conversations/:id
 *
 * Soft-delete. Returns 200 on success (whether or not anything was
 * affected — DELETE is idempotent by spec, and a 404 here would leak
 * existence to an attacker who knew the id).
 */
async function handleDeleteConversation(request, env, ctx, conversationId, requiresPro) {
  if (!isValidUuid(conversationId)) {
    return jsonResponse({ error: 'Invalid conversation id' }, 400);
  }

  const auth = await authenticate(request, env, ctx, new Uint8Array(0));
  if (auth.response) return auth.response;
  const { userId, payload } = auth;

  const gate = checkProGate({ payload, requiresPro });
  if (gate) return gate;

  try {
    await softDeleteConversation({ env, userId, conversationId });
    return jsonResponse({ ok: true });
  } catch (err) {
    console.error('[eve] delete failed', err?.message);
    return jsonResponse({ error: 'Internal server error' }, 500);
  }
}

/**
 * POST /v1/eve/conversations/:id/messages
 *
 * Body:
 *   content: string (the user turn)
 *   client_request_id: uuid (per-conversation idempotency; required so a
 *                            retried send doesn't double-charge OpenAI)
 *
 * Returns:
 *   { user_message, assistant_message, conversation }
 *
 * Flow:
 *   1. Validate auth + body.
 *   2. Fetch the conversation. 404 if not found / not owned.
 *   3. Idempotency: if an assistant row already exists for this
 *      (conversation_id, client_request_id), return it verbatim with
 *      `X-Idempotent-Replay: 1` and skip OpenAI.
 *   4. Rate limits: Eve per-minute / per-day + global daily spend cap.
 *   5. Per-conversation turn cap: SELECT count(*) — if at the ceiling,
 *      reject with 409 conversation_full.
 *   6. Insert the user message row immediately (durability — the user's
 *      question persists even if OpenAI fails).
 *   7. Hydrate scope context (critique for scope='drawing').
 *   8. Assemble system prompt + messages, call OpenAI.
 *   9. Insert assistant message row with persona + product context versions.
 *  10. Bump conversation counters (message_count, tokens, last_message_at).
 *  11. Record Eve daily-message counter + global per-user token counter.
 */
async function handleSendMessage(request, env, ctx, conversationId, requiresPro) {
  if (!isValidUuid(conversationId)) {
    return jsonResponse({ error: 'Invalid conversation id' }, 400);
  }

  const { rawBody, body } = await readJsonBody(request);
  if (!body || typeof body !== 'object') {
    return jsonResponse({ error: 'Invalid request body' }, 400);
  }

  const auth = await authenticate(request, env, ctx, rawBody);
  if (auth.response) return auth.response;
  const { userId, payload } = auth;

  const gate = checkProGate({ payload, requiresPro });
  if (gate) return gate;

  // Body validation.
  const content = body.content;
  if (typeof content !== 'string' || content.length === 0) {
    return jsonResponse({ error: 'content must be a non-empty string' }, 400);
  }
  if (new TextEncoder().encode(content).length > MAX_MESSAGE_CONTENT_BYTES) {
    return jsonResponse({ error: `content exceeds ${MAX_MESSAGE_CONTENT_BYTES} bytes` }, 400);
  }
  const clientRequestId = body.client_request_id;
  if (!isValidUuid(clientRequestId)) {
    return jsonResponse({ error: 'client_request_id must be a lowercase UUID' }, 400);
  }

  // Conversation ownership + scope discovery.
  let conversation;
  try {
    conversation = await getConversation({ env, userId, conversationId });
  } catch (err) {
    console.error('[eve] get for send failed', err?.message);
    return jsonResponse({ error: 'Internal server error' }, 500);
  }
  if (!conversation) {
    return jsonResponse({ error: 'Conversation not found' }, 404);
  }

  // Idempotency replay — return the existing assistant message verbatim.
  const replay = await findMessageByClientRequestId({
    env, conversationId, clientRequestId,
  });
  if (replay) {
    return jsonResponse({
      user_message: null,
      assistant_message: replay,
      conversation,
    }, 200, { 'X-Idempotent-Replay': '1' });
  }

  const { tier } = getUserTier(payload);
  const now = Date.now();

  // Eve rate limits (per-minute + per-day message count).
  const rateDecision = await enforceEveRateLimits({ env, userId, tier, now });
  if (!rateDecision.ok) {
    return jsonResponse(rateDecision.body, rateDecision.status, {
      'Retry-After': String(rateDecision.body.retryAfter),
    });
  }

  // Per-conversation hard ceiling. Stop runaway threads from
  // accumulating prompt cost. message_count is the cheap counter; the
  // canonical count is SELECT count(*) but for a hard ceiling the
  // soft counter is good enough — we just need to prevent infinite
  // growth, not get the precise number right.
  const maxTurns = readEveMaxTurnsPerConversation(env);
  if ((conversation.message_count ?? 0) >= maxTurns * 2) {
    // *2 because each "turn" is two messages (user + assistant).
    return jsonResponse({
      error: 'conversation_full',
      message: `This conversation is at the maximum length of ${maxTurns} turns. Start a new conversation to continue.`,
    }, 409);
  }

  // Global cost ceilings — daily spend + per-user token. Same gates the
  // critique path runs through; one wallet, two paths.
  const ceilingDecision = await enforceCostCeilings({ env, userId, now });
  if (!ceilingDecision.ok) {
    return jsonResponse(ceilingDecision.body, ceilingDecision.status, {
      'Retry-After': String(ceilingDecision.body.retryAfter),
    });
  }
  const todayKey = ceilingDecision.ctx.dayKey;

  // Insert the user message FIRST. If OpenAI fails, the user's question
  // still persists and they see their own bubble in the thread.
  //
  // `client_request_id` is intentionally OMITTED on the user row — only
  // the assistant row carries it. The unique index
  // conversation_messages_idempotency_idx scopes by (conversation_id,
  // client_request_id) for any non-null client_request_id, so putting
  // the id on BOTH rows would trip the constraint on the assistant
  // insert. findMessageByClientRequestId only looks for assistant rows
  // anyway (the replay shape is "did we already produce an answer for
  // this logical send?"), so the user-row mirror added nothing.
  let userMessage;
  try {
    userMessage = await appendMessage({
      env,
      conversationId,
      role: 'user',
      content,
    });
  } catch (err) {
    console.error('[eve] append user message failed', err?.message);
    return jsonResponse({ error: 'Internal server error' }, 500);
  }

  // Scope hydration runs in parallel with coaching-context fetch and
  // conversation-history fetch. All three feed buildEveSystemPrompt /
  // buildEveMessages, and they're independent of each other — no reason
  // to serialize them. fetchCoachingContext + fetchCritiqueForConversation
  // both return null/empty on failure, so a Supabase hiccup degrades
  // gracefully instead of 500'ing the whole send.
  //
  // The exclude pair on coaching context keeps the current drawing /
  // current critique out of the coaching block — CURRENT CONTEXT
  // already carries the full critique, so repeating its summary would
  // burn tokens and read redundantly.
  const scopeDrawingId = conversation.scope === 'drawing'
    ? conversation.scope_drawing_id
    : null;
  const scopeCritiqueSeq = (conversation.scope === 'drawing'
    && typeof conversation.scope_critique_sequence === 'number')
    ? conversation.scope_critique_sequence
    : null;

  let critique = null;
  let coachingContext = { drawings: [], summaries: [] };
  let history = [];
  try {
    const [critiqueResult, coachingResult, historyResult] = await Promise.all([
      scopeDrawingId && scopeCritiqueSeq !== null
        ? fetchCritiqueForConversation({
            env, userId,
            drawingId: scopeDrawingId,
            sequenceNumber: scopeCritiqueSeq,
          })
        : Promise.resolve(null),
      fetchCoachingContext({
        env, userId,
        drawingsLimit: 20,
        summariesLimit: 10,
        excludeDrawingId: scopeDrawingId,
        excludeCritiqueSequence: scopeCritiqueSeq,
      }),
      getConversationHistory({ env, conversationId }),
    ]);
    critique = critiqueResult;
    coachingContext = coachingResult;
    history = historyResult;
  } catch (err) {
    console.error('[eve] parallel hydration failed', err?.message);
    return jsonResponse({ error: 'Internal server error' }, 500);
  }
  // The user message we just inserted will be in `history`. Strip it so
  // it isn't duplicated when we pass `userTurn` to buildEveMessages.
  const historyWithoutCurrent = history.filter((m) => m.id !== userMessage?.id);

  // Telemetry: log coaching context size so a future "Eve quality dipped"
  // investigation can correlate to whether the user had data preloaded.
  // No new schema field — conversation_messages doesn't carry a
  // prompt_config column, and adding one for two ints isn't worth a
  // migration. wrangler tail captures these logs.
  console.log('[eve] coaching context loaded', {
    conversationId,
    drawingCount: coachingContext?.drawings?.length ?? 0,
    summaryCount: coachingContext?.summaries?.length ?? 0,
    scope: conversation.scope,
  });

  const systemPrompt = buildEveSystemPrompt({
    scope: conversation.scope,
    critique,
    coachingContext,
  });
  const messages = buildEveMessages({
    systemPrompt,
    history: historyWithoutCurrent,
    userTurn: content,
  });

  // OpenAI call.
  let openaiResponse;
  try {
    openaiResponse = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      },
      body: JSON.stringify({
        model: OPENAI_MODEL,
        messages,
        max_completion_tokens: OPENAI_MAX_OUTPUT_TOKENS,
        temperature: OPENAI_TEMPERATURE,
        reasoning_effort: OPENAI_REASONING_EFFORT,
        user: userId,
      }),
    });
  } catch (err) {
    console.error('[eve] openai fetch threw', err?.message);
    return jsonResponse({ error: 'Upstream model error' }, 502);
  }

  if (!openaiResponse.ok) {
    let errorBody = '<unavailable>';
    try { errorBody = await openaiResponse.text(); } catch {}
    console.error('[eve] openai non-ok', openaiResponse.status, 'body:', errorBody);
    return jsonResponse({ error: 'Upstream model error' }, 502);
  }

  const data = await openaiResponse.json();
  const assistantContent = data.choices?.[0]?.message?.content;
  if (typeof assistantContent !== 'string' || assistantContent.length === 0) {
    return jsonResponse({ error: 'No response generated' }, 502);
  }
  const usage = data.usage ?? {};

  // Persist the assistant turn. clientRequestId persists on the assistant
  // row so future retries hit the idempotency cache.
  let assistantMessage;
  try {
    assistantMessage = await appendMessage({
      env,
      conversationId,
      role: 'assistant',
      content: assistantContent,
      clientRequestId,
      promptTokenCount: usage.prompt_tokens ?? null,
      completionTokenCount: usage.completion_tokens ?? null,
      personaVersion: EVE_PERSONA_VERSION,
      productContextVersion: EVE_PRODUCT_CONTEXT_VERSION,
    });
  } catch (err) {
    // Orphan path: the user message persisted, OpenAI returned, but the
    // assistant row didn't write. Log + return what we have. The user
    // sees the response in this round-trip; subsequent fetches of the
    // conversation will miss the assistant row, but a retry of the
    // send-message call (idempotent on client_request_id) will land
    // somewhere downstream.
    console.error('[eve] append assistant message failed', err?.message);
    return jsonResponse({
      user_message: userMessage,
      assistant_message: { content: assistantContent, role: 'assistant' },
      conversation,
      warning: 'persistence_orphan',
    }, 200);
  }

  // Bookkeeping — all fire-and-forget. The user has their response;
  // failure here doesn't affect them.
  bumpConversationCounters({
    env,
    conversationId,
    incrementBy: 2,
    inputTokens: usage.prompt_tokens ?? 0,
    outputTokens: usage.completion_tokens ?? 0,
  }).catch((err) => console.error('[eve] bumpConversationCounters', err?.message));

  recordSuccessfulEveTurn({ env, ctx: rateDecision.ctx })
    .catch((err) => console.error('[eve] recordSuccessfulEveTurn', err?.message));

  recordRequestUsage({ env, userId, dayKey: todayKey, usage })
    .catch((err) => console.error('[eve] recordRequestUsage', err?.message));

  // Refresh conversation snapshot for the response. Cheap re-read so the
  // client sees the post-bump counters / last_message_at. Best-effort —
  // if the read fails we just return the pre-bump version.
  let freshConversation = conversation;
  try {
    const re = await getConversation({ env, userId, conversationId });
    if (re) freshConversation = re;
  } catch { /* keep pre-bump */ }

  return jsonResponse({
    user_message: userMessage,
    assistant_message: assistantMessage,
    conversation: freshConversation,
  });
}

// =============================================================================
// Top-level method dispatcher
// =============================================================================
//
// index.js routes everything under /v1/eve/conversations[/...] here.
// We dispatch on (path shape, method) and 405 anything else. The Pro
// gate is wired per-handler so future routes can have different posture
// (e.g. listing free + sending pro) without code reshuffling.

export async function handleEve(request, env, ctx) {
  const url = new URL(request.url);
  const pathname = url.pathname;
  const method = request.method;

  // Pro gating posture for 2A — every route is FREE. Bump these to true
  // when StoreKit ships. Each handler accepts the flag so route-level
  // configuration is one line per endpoint, not a refactor.
  const REQUIRES_PRO_CREATE        = false;
  const REQUIRES_PRO_LIST          = false;
  const REQUIRES_PRO_GET           = false;
  const REQUIRES_PRO_DELETE        = false;
  const REQUIRES_PRO_SEND_MESSAGE  = false;

  // POST   /v1/eve/conversations           — create
  // GET    /v1/eve/conversations           — list
  if (pathname === '/v1/eve/conversations') {
    if (method === 'POST') return handleCreateConversation(request, env, ctx, REQUIRES_PRO_CREATE);
    if (method === 'GET')  return handleListConversations(request, env, ctx, REQUIRES_PRO_LIST);
    return jsonResponse({ error: 'Method not allowed' }, 405);
  }

  // POST /v1/eve/conversations/:id/messages — send message
  const sendMatch = pathname.match(/^\/v1\/eve\/conversations\/([^/]+)\/messages$/);
  if (sendMatch) {
    if (method === 'POST') {
      return handleSendMessage(request, env, ctx, sendMatch[1], REQUIRES_PRO_SEND_MESSAGE);
    }
    return jsonResponse({ error: 'Method not allowed' }, 405);
  }

  // GET    /v1/eve/conversations/:id       — fetch + messages
  // DELETE /v1/eve/conversations/:id       — soft delete
  const idMatch = pathname.match(/^\/v1\/eve\/conversations\/([^/]+)$/);
  if (idMatch) {
    if (method === 'GET')    return handleGetConversation(request, env, ctx, idMatch[1], REQUIRES_PRO_GET);
    if (method === 'DELETE') return handleDeleteConversation(request, env, ctx, idMatch[1], REQUIRES_PRO_DELETE);
    return jsonResponse({ error: 'Method not allowed' }, 405);
  }

  return jsonResponse({ error: 'Not found' }, 404);
}
