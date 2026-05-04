// POST / — the AI critique endpoint. Validates the request, enforces rate
// limits + ownership, calls OpenAI, persists the critique, and logs the
// outcome. The 335-line orchestrator at the bottom (`handleFeedback`) is
// the same flow that lived inline in index.js prior to the modular split;
// the helpers above it (validation, persistence, logging) used to be
// scattered across that file too.
//
// Phase notes (preserved for context):
//   5a — JWT validation (lives in middleware/auth.js)
//   5b — request validation (validateImagePayload / validateContext below)
//   5c — rate limits (middleware/rate-limit.js)
//   5d — idempotency + server-side persistence (middleware/idempotency.js
//        for the cache; persistCritique below for the append_critique RPC)
//   5e — request logging (logRequest below)

import {
  selectConfig,
  buildSystemPrompt,
  buildUserMessage,
  assembleSystemPrompt,
  resolvePresetId,
  selectVoice,
  selectCustomPromptParameters,
  isValidPresetId,
  DEFAULT_PRESET_ID,
} from '../lib/prompt.js';
import {
  validateJWT,
  validateWorkerConfig,
  getUserTier,
} from '../middleware/auth.js';
import {
  readAppAttestHeaders,
  getAttestedKey,
  computeAppAttestClientDataHash,
  verifyAppAttestAssertion,
  updateAttestedKeyCounter,
} from '../middleware/app-attest.js';
import {
  enforceRateLimits,
  recordSuccessfulCritique,
  sha256Hex,
  utcDayKey,
  incrementDailySpend,
  computeRequestCost,
  enforceCostCeilings,
  recordRequestUsage,
  ESTIMATED_REQUEST_COST_USD,
} from '../middleware/rate-limit.js';
import {
  isValidClientRequestId,
  checkIdempotency,
  recordIdempotent,
} from '../middleware/idempotency.js';
import { jsonResponse, unauthorized } from '../lib/http.js';

// =============================================================================
// Phase 5b — request validation
// =============================================================================

const MAX_IMAGE_BASE64_BYTES = 8 * 1024 * 1024; // 8 MB of base64 chars (~6 MB binary)

/**
 * Returns 'jpeg' | 'png' | false. Validates payload size + magic bytes; does
 * not fully validate the image (we trust GPT-4o Vision to handle malformed
 * pixels without burning tokens — we just block obvious junk + oversized junk).
 */
export function validateImagePayload(base64) {
  if (typeof base64 !== 'string' || base64.length === 0) return false;
  if (base64.length > MAX_IMAGE_BASE64_BYTES) return false;
  let head;
  try {
    head = atob(base64.slice(0, 16));
  } catch {
    return false;
  }
  if (head.length < 4) return false;
  const b0 = head.charCodeAt(0);
  const b1 = head.charCodeAt(1);
  const b2 = head.charCodeAt(2);
  const b3 = head.charCodeAt(3);
  // JPEG: FF D8 FF (next byte varies — E0/E1/DB/etc.)
  if (b0 === 0xff && b1 === 0xd8 && b2 === 0xff) return 'jpeg';
  // PNG: 89 50 4E 47
  if (b0 === 0x89 && b1 === 0x50 && b2 === 0x4e && b3 === 0x47) return 'png';
  return false;
}

const CONTEXT_STRING_FIELDS = [
  'skillLevel',
  'subject',
  'style',
  'artists',
  'techniques',
  'focus',
  'additionalContext',
  'preset_id',
];

// Per-field length caps. Closes a cost-amplification path: the unbounded
// strings would otherwise flow straight into the prompt, inflating prompt
// tokens × every-request × every-user. Sizes match realistic UI inputs:
// short labels (200), comma-separated artist list (500), free-form notes
// (2000). preset_id is a short identifier — `custom:<uuid>` is 43 chars,
// 50 leaves headroom for any future preset namespace.
const CONTEXT_FIELD_MAX_LENGTHS = {
  skillLevel: 200,
  subject: 200,
  style: 200,
  artists: 500,
  techniques: 200,
  focus: 200,
  additionalContext: 2000,
  preset_id: 50,
};

export function validateContext(context) {
  if (!context || typeof context !== 'object' || Array.isArray(context)) return false;
  for (const key of CONTEXT_STRING_FIELDS) {
    if (key in context && typeof context[key] !== 'string') return false;
  }
  return true;
}

/**
 * Returns null if every present string field is within its length cap; else
 * returns { field, max, length } describing the first violation. Run AFTER
 * validateContext (which guarantees fields are strings when present), so this
 * function only checks length, not type.
 */
export function validateContextLengths(context) {
  if (!context || typeof context !== 'object') return null;
  for (const [key, max] of Object.entries(CONTEXT_FIELD_MAX_LENGTHS)) {
    const val = context[key];
    if (typeof val === 'string' && val.length > max) {
      return { field: key, max, length: val.length };
    }
  }
  return null;
}

// =============================================================================
// Drawing ownership + history (PostgREST helpers, service-role auth)
// =============================================================================

/**
 * Returns true iff a row exists in `drawings` with the given id AND user_id.
 * Uses the service_role key so RLS is bypassed — we're enforcing scope
 * ourselves via the WHERE clause, which is what we want for ownership checks
 * (we already know the user from a validated JWT).
 */
export async function verifyDrawingOwnership(userId, drawingId, env) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) return false;
  const url = `${env.SUPABASE_URL}/rest/v1/drawings`
    + `?id=eq.${encodeURIComponent(drawingId)}`
    + `&user_id=eq.${encodeURIComponent(userId)}`
    + `&select=id&limit=1`;
  const res = await fetch(url, {
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      Accept: 'application/json',
    },
  });
  if (!res.ok) {
    console.log('[ownership] supabase non-ok status', res.status);
    return false;
  }
  const rows = await res.json();
  return Array.isArray(rows) && rows.length > 0;
}

/**
 * Pulls the critique_history jsonb array AND the current preset_id for the
 * given drawing id. Returns { history, presetId }. Used so the iterative-
 * coaching prompt has prior critiques to reference, and so the handler can
 * decide whether to write through a new preset_id (only on change). Returns
 * { history: [], presetId: DEFAULT_PRESET_ID } on any failure — feedback
 * will still generate, just without history context.
 */
export async function fetchCritiqueHistory(drawingId, env) {
  const empty = { history: [], presetId: DEFAULT_PRESET_ID };
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) return empty;
  const url = `${env.SUPABASE_URL}/rest/v1/drawings`
    + `?id=eq.${encodeURIComponent(drawingId)}`
    + `&select=critique_history,preset_id&limit=1`;
  const res = await fetch(url, {
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      Accept: 'application/json',
    },
  });
  if (!res.ok) return empty;
  const rows = await res.json();
  const row = rows?.[0];
  return {
    history: Array.isArray(row?.critique_history) ? row.critique_history : [],
    presetId: typeof row?.preset_id === 'string' ? row.preset_id : DEFAULT_PRESET_ID,
  };
}

/**
 * PATCH drawings.preset_id when it differs from what's currently on the row.
 * Caller decides whether to invoke based on the comparison; this helper
 * just does the write. fetcher is dependency-injected for tests.
 */
export async function updateDrawingPresetId({ env, drawingId, presetId, fetcher = fetch }) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('updateDrawingPresetId env not configured');
  }
  const url = `${env.SUPABASE_URL}/rest/v1/drawings?id=eq.${encodeURIComponent(drawingId)}`;
  const res = await fetcher(url, {
    method: 'PATCH',
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      'Content-Type': 'application/json',
      Prefer: 'return=minimal',
    },
    body: JSON.stringify({ preset_id: presetId }),
  });
  if (!res.ok) throw new Error(`updateDrawingPresetId HTTP ${res.status}`);
}

/**
 * PATCH user_preferences.preferred_preset_id. The signup trigger guarantees
 * the row exists; if the trigger ever fails to seed it, the PATCH 404s, the
 * caller logs, and the user-facing critique still succeeds (graceful
 * degradation). The "ensure a row exists" responsibility belongs to the
 * trigger, not the request path.
 */
export async function updateUserPreferredPreset({ env, userId, presetId, fetcher = fetch }) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('updateUserPreferredPreset env not configured');
  }
  const url = `${env.SUPABASE_URL}/rest/v1/user_preferences?user_id=eq.${encodeURIComponent(userId)}`;
  const res = await fetcher(url, {
    method: 'PATCH',
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      'Content-Type': 'application/json',
      Prefer: 'return=minimal',
    },
    body: JSON.stringify({ preferred_preset_id: presetId }),
  });
  if (!res.ok) throw new Error(`updateUserPreferredPreset HTTP ${res.status}`);
}

// =============================================================================
// Critique entry construction + persistence
// =============================================================================
//
// After OpenAI returns a critique, the Worker (not the client) appends the
// entry to drawings.critique_history via a security-definer Postgres function
// `append_critique(uuid, jsonb)`. The function does an atomic
// `critique_history || jsonb_build_array($entry)` so concurrent writes
// linearize without a SELECT-then-UPDATE race.
//
// Failure modes:
//   - OpenAI fails → 502, no quota burn, no Postgres write, no cache.
//   - Postgres write fails after OpenAI succeeded → user still gets the
//     critique (graceful degradation), orphan logged via console.error,
//     quota IS counted (the OpenAI cost was real), idempotency cache IS
//     written (so the same request_id won't double-spend).

export function buildCritiqueEntry({ feedback, sequenceNumber, config, tier, usage, now, presetId }) {
  return {
    sequence_number: sequenceNumber,
    // preset_id sits at the top level (not inside prompt_config) because it
    // identifies the voice that produced the row, not a prompt-shaping knob.
    // Future analytics queries are cleaner this way.
    preset_id: presetId ?? DEFAULT_PRESET_ID,
    content: feedback,
    prompt_config: {
      tier,
      includeHistoryCount: config.includeHistoryCount,
      styleModifier: config.styleModifier ?? null,
      // Snapshot the bounded-knob parameters used for THIS critique. Stored
      // even when empty so the schema is uniform across rows. Preserves
      // reproducibility: a later edit to the user's custom_prompts row
      // doesn't retroactively change what produced an old critique.
      customPromptModifier: config.customPromptModifier ?? null,
    },
    prompt_token_count: usage?.prompt_tokens ?? 0,
    completion_token_count: usage?.completion_tokens ?? 0,
    created_at: new Date(now).toISOString(),
  };
}

/**
 * Atomically append a critique entry to drawings.critique_history. fetcher is
 * dependency-injected so tests can stub the Postgres call without touching
 * globalThis.fetch.
 */
export async function persistCritique({ env, drawingId, entry, fetcher = fetch }) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('persistCritique env not configured');
  }
  const url = `${env.SUPABASE_URL}/rest/v1/rpc/append_critique`;
  const res = await fetcher(url, {
    method: 'POST',
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ p_drawing_id: drawingId, p_entry: entry }),
  });
  if (!res.ok) throw new Error(`append_critique HTTP ${res.status}`);
}

// =============================================================================
// Phase 5e — request logging
// =============================================================================
//
// One row per request hitting a terminal state lands in
// public.feedback_requests via service_role insert. Logging is non-blocking
// (callers wrap in ctx.waitUntil) and non-load-bearing — a logging failure
// must never break the user-facing flow. RLS hides null-user_id (auth_failed)
// rows from authenticated reads; only service_role sees them.
//
// Status semantics (canonical set, document changes here AND in the auth plan):
//   success            — critique returned and persisted to drawings.critique_history
//   quota_exceeded     — 429 daily / per-minute / per-IP limit hit
//   auth_failed        — 401 invalid or missing JWT
//   validation_failed  — 400 malformed body, image, context, or client_request_id
//   ownership_denied   — 403 drawing doesn't belong to the JWT's user
//   model_error        — 502 OpenAI returned non-ok or empty completion
//   internal_error     — 500 Worker bug / KV failure / anything that's *our* fault
//                        (kept distinct from model_error so abuse-detection
//                         queries don't conflate "OpenAI hiccup" with "our bug")
//   idempotent_replay  — 200 served from idempotency cache (still logged so
//                        repeat-pattern analytics can see it)
//   persistence_orphan — OpenAI succeeded, append_critique RPC failed.
//                        Token counts populated; user got the critique.

export const REQUEST_STATUS = Object.freeze({
  SUCCESS:            'success',
  QUOTA_EXCEEDED:     'quota_exceeded',
  AUTH_FAILED:        'auth_failed',
  VALIDATION_FAILED:  'validation_failed',
  OWNERSHIP_DENIED:   'ownership_denied',
  MODEL_ERROR:        'model_error',
  INTERNAL_ERROR:     'internal_error',
  IDEMPOTENT_REPLAY:  'idempotent_replay',
  PERSISTENCE_ORPHAN: 'persistence_orphan',
});

/**
 * Insert one row into feedback_requests. Non-blocking by design: callers
 * pass this Promise to ctx.waitUntil(). Wrapped in try/catch — a logging
 * failure must never propagate to the user response. fetcher is dependency-
 * injected so tests can stub without globals.
 */
export async function logRequest({
  env,
  status,
  userId = null,
  drawingId = null,
  ipHash = null,
  promptTokens = null,
  completionTokens = null,
  fetcher = fetch,
}) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) return;
  try {
    const res = await fetcher(`${env.SUPABASE_URL}/rest/v1/feedback_requests`, {
      method: 'POST',
      headers: {
        apikey: env.SUPABASE_SERVICE_ROLE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
        'Content-Type': 'application/json',
        Prefer: 'return=minimal',
      },
      body: JSON.stringify({
        user_id: userId,
        drawing_id: drawingId,
        status,
        prompt_token_count: promptTokens,
        completion_token_count: completionTokens,
        client_ip_hash: ipHash,
      }),
    });
    if (!res.ok) console.error('[log] feedback_requests non-ok', res.status);
  } catch (err) {
    console.error('[log] feedback_requests threw', err?.message);
  }
}

// =============================================================================
// OpenAI request tunables
// =============================================================================
//
// Per-request knobs for the chat completion. All four apply in the body of
// the OpenAI fetch in handleFeedback below.
//   - model: extracted to a constant so we can A/B different OpenAI models
//     without touching the request body. Currently gpt-5.1 (mid-tier, Nov
//     2025). An earlier gpt-5.1 attempt returned 400 from OpenAI and was
//     rolled back; permanent error-body logging is now in place (in the
//     fetch handler) so any recurrence surfaces in Cloudflare logs.
//   - temperature 0.4 reduces non-determinism without making output robotic.
//     OpenAI's default is 1.0, which combined with no seed produces
//     contradictory Focus Areas across replays of the same drawing state.
//   - seed is best-effort on OpenAI's side — not a guarantee of identical
//     outputs, but with reduced temperature it makes replays meaningfully
//     more stable for debugging and a more consistent student experience.
//   - reasoning effort: passed as a flat `reasoning_effort` field on the
//     /v1/chat/completions request body (NOT the nested `reasoning: { effort }`
//     shape — that's the /v1/responses endpoint's API. An earlier attempt
//     used the nested form and OpenAI 400'd with "Unknown parameter:
//     'reasoning'"). For gpt-5.1, OpenAI's accepted values are 'none' /
//     'low' / 'medium' / 'high' — confirmed empirically by production
//     400s. We tried 'minimal' during the migration based on a training-
//     data assumption that gpt-5 series accepted it; OpenAI rejected
//     it as unsupported for this model. 'none' is the cheapest option
//     and means "do as little reasoning as possible." Escalate to 'low'
//     or higher if scrutiny failures persist after model + prompt rules.
//
// The request also forwards the authenticated Supabase user id as the
// `user` field on the request body — OpenAI uses this for their own abuse
// detection. Free signal, set inline at the call site since it varies.

const OPENAI_MODEL = 'gpt-5.1';
const OPENAI_TEMPERATURE = 0.4;
const OPENAI_SEED = 42;
const OPENAI_REASONING_EFFORT = 'none';

// =============================================================================
// Handler — orchestrates the full critique flow
// =============================================================================

export async function handleFeedback(request, env, ctx) {
  // Fail fast on missing required env. Previously SUPABASE_JWT_ISSUER was
  // silently optional in validateJWT, which meant a misconfigured deploy
  // would weaken auth without anyone noticing. Now we 500 visibly.
  const configErr = validateWorkerConfig(env);
  if (configErr) {
    console.error('[config]', configErr);
    return jsonResponse({ error: configErr }, 500);
  }

  // Phase 5e — capture IP up front so auth_failed / validation_failed
  // logs have ipHash even when no other request context is available.
  const ip = request.headers.get('CF-Connecting-IP') ?? '';
  const ipHash = await sha256Hex(ip || 'unknown');

  // Phase 5a — auth gate. Anything other than a valid Supabase JWT → 401.
  // Runs FIRST, before App Attest: JWT proves who the user is and is the
  // cheapest gate (module-cached JWKS). App Attest is a separate, equally
  // load-bearing gate that runs second below — both must pass.
  const token = request.headers.get('Authorization')?.replace(/^Bearer\s+/i, '') ?? null;
  let payload;
  try {
    payload = await validateJWT(token, env);
  } catch (err) {
    // Both signals: console for live wrangler tail debugging, table row
    // for retrospective analysis. Different audiences, different lifetimes.
    console.log('[fetch] JWT validation failed', err?.message);
    ctx.waitUntil(logRequest({ env, status: REQUEST_STATUS.AUTH_FAILED, ipHash }));
    return unauthorized();
  }
  // Supabase auth.uid() is always lowercase. App Attest produces a separate
  // device identifier extracted at its own gate; downstream code (rate limits,
  // billing, request scoping) treats user identity and device identity as
  // distinct keys, not a composite.
  const userId = payload.sub;

  let drawingIdLower = null; // available to the catch block once parsed
  try {
    // Phase 5f — read raw bytes so we can both (a) compute the App Attest
    // clientDataHash over the exact bytes the client signed and (b) parse
    // them as JSON for the existing critique flow. request.json() consumes
    // the body, so we must do it ourselves.
    const rawBody = new Uint8Array(await request.arrayBuffer());
    let body = null;
    try { body = JSON.parse(new TextDecoder().decode(rawBody)); }
    catch { body = null; }
    if (!body || typeof body !== 'object') {
      ctx.waitUntil(logRequest({ env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, ipHash }));
      return jsonResponse({ error: 'Invalid request body' }, 400);
    }

    // Phase 5f — App Attest assertion gate. Runs after JWT (so we know
    // who's calling) and after body parse (so the hash is over the exact
    // bytes the client signed) but before all other validation (so
    // unattested devices can't probe other endpoint behavior). Failures
    // return 401 with a stable error code — clients use the code to decide
    // whether to wipe their cached keyId and re-register.
    const attestHeaders = readAppAttestHeaders(request);
    if (!attestHeaders) {
      console.log('[attest] missing headers from authed user', userId);
      ctx.waitUntil(logRequest({ env, status: REQUEST_STATUS.AUTH_FAILED, userId, ipHash }));
      return jsonResponse({ error: 'attest_headers_missing' }, 401);
    }
    const stored = await getAttestedKey(attestHeaders.keyId, env);
    if (!stored) {
      // Either the device never registered, or its TTL expired in KV.
      // A distinct code lets the client wipe + re-register without
      // confusing this with a JWT failure.
      ctx.waitUntil(logRequest({ env, status: REQUEST_STATUS.AUTH_FAILED, userId, ipHash }));
      return jsonResponse({ error: 'attest_key_unknown' }, 401);
    }
    // Production env keys must not be accepted in development (or vice
    // versa) — they're cryptographically distinguishable via AAGUID at
    // registration, but cross-env replay is still worth gating here.
    const expectedEnv = env.APP_ATTEST_ENV === 'production' ? 'production' : 'development';
    if (stored.env !== expectedEnv) {
      ctx.waitUntil(logRequest({ env, status: REQUEST_STATUS.AUTH_FAILED, userId, ipHash }));
      return jsonResponse({ error: 'attest_env_mismatch' }, 401);
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
      // Fire-and-forget the counter update so a KV blip doesn't block the
      // user. A counter that fails to persist just means the next request
      // will see the same storedCounter — assertion verification still
      // requires newCounter > storedCounter, so the worst case is a one-
      // request replay window which the IP/user rate limits already bound.
      ctx.waitUntil(updateAttestedKeyCounter(attestHeaders.keyId, newCounter, env));
    } catch (err) {
      console.log('[attest] assertion failed', err?.message);
      ctx.waitUntil(logRequest({ env, status: REQUEST_STATUS.AUTH_FAILED, userId, ipHash }));
      return jsonResponse({ error: 'attest_assertion_invalid' }, 401);
    }

    const { image, context, drawingId, client_request_id: clientRequestIdRaw } = body;

    // Phase 5b — request validation. Cheap checks first; ownership query last.
    if (typeof drawingId !== 'string' || drawingId.length === 0) {
      ctx.waitUntil(logRequest({ env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, ipHash }));
      return jsonResponse({ error: 'Missing drawing_id' }, 400);
    }
    drawingIdLower = drawingId.toLowerCase(); // pattern compliance from Phase 3

    // Phase 5d — idempotency gate. Validates the request id format and short-
    // circuits replays before image validation / rate limits / OpenAI. A
    // cached hit returns the original response verbatim and never burns
    // quota again.
    if (typeof clientRequestIdRaw !== 'string') {
      ctx.waitUntil(logRequest({
        env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, drawingId: drawingIdLower, ipHash,
      }));
      return jsonResponse({ error: 'Missing client_request_id' }, 400);
    }
    const clientRequestId = clientRequestIdRaw.toLowerCase();
    if (!isValidClientRequestId(clientRequestId)) {
      ctx.waitUntil(logRequest({
        env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, drawingId: drawingIdLower, ipHash,
      }));
      return jsonResponse({ error: 'Invalid client_request_id' }, 400);
    }
    const cached = await checkIdempotency({ env, userId, clientRequestId });
    if (cached) {
      ctx.waitUntil(logRequest({
        env, status: REQUEST_STATUS.IDEMPOTENT_REPLAY, userId, drawingId: drawingIdLower, ipHash,
      }));
      return jsonResponse(cached, 200, { 'X-Idempotent-Replay': '1' });
    }

    if (!validateImagePayload(image)) {
      ctx.waitUntil(logRequest({
        env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, drawingId: drawingIdLower, ipHash,
      }));
      return jsonResponse({ error: 'Invalid or oversized image payload' }, 400);
    }
    if (!validateContext(context)) {
      ctx.waitUntil(logRequest({
        env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, drawingId: drawingIdLower, ipHash,
      }));
      return jsonResponse({ error: 'Invalid context' }, 400);
    }
    const lengthErr = validateContextLengths(context);
    if (lengthErr) {
      ctx.waitUntil(logRequest({
        env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, drawingId: drawingIdLower, ipHash,
      }));
      return jsonResponse({
        error: `Context field '${lengthErr.field}' exceeds maximum length of ${lengthErr.max} characters.`,
      }, 400);
    }

    // preset_id format check (cheap; defense before rate-limit gate). The
    // ownership check on custom:<uuid> happens later via resolvePresetId.
    if (context?.preset_id !== undefined && !isValidPresetId(context.preset_id)) {
      ctx.waitUntil(logRequest({
        env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, drawingId: drawingIdLower, ipHash,
      }));
      return jsonResponse({ error: 'Invalid preset_id format.' }, 400);
    }

    // set_as_default is a top-level body field (not inside context) — it's
    // a per-request command, not part of the drawing context.
    if (body.set_as_default !== undefined && typeof body.set_as_default !== 'boolean') {
      ctx.waitUntil(logRequest({
        env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, drawingId: drawingIdLower, ipHash,
      }));
      return jsonResponse({ error: 'set_as_default must be a boolean.' }, 400);
    }

    const { tier, promptPreferences } = getUserTier(payload);

    // Phase 5c — rate limits. Run before the ownership query so we don't
    // burn a Postgres call on a request we're about to 429 anyway.
    const now = Date.now();
    const decision = await enforceRateLimits({ env, userId, ip, tier, now });
    if (!decision.ok) {
      ctx.waitUntil(logRequest({
        env, status: REQUEST_STATUS.QUOTA_EXCEEDED, userId, drawingId: drawingIdLower, ipHash,
      }));
      return jsonResponse(decision.body, decision.status, {
        'Retry-After': String(decision.body.retryAfter),
      });
    }

    const owns = await verifyDrawingOwnership(userId, drawingIdLower, env);
    if (!owns) {
      ctx.waitUntil(logRequest({
        env, status: REQUEST_STATUS.OWNERSHIP_DENIED, userId, drawingId: drawingIdLower, ipHash,
      }));
      return jsonResponse({ error: 'Forbidden' }, 403);
    }

    const baseConfig = selectConfig(tier, promptPreferences);
    const { history, presetId: existingPresetId } = await fetchCritiqueHistory(drawingIdLower, env);

    // Resolve preset_id. For custom:<uuid>, this verifies the row exists
    // AND belongs to this user. Hardcoded preset IDs short-circuit
    // without a DB hit.
    let resolvedPresetId;
    try {
      resolvedPresetId = await resolvePresetId(context?.preset_id, userId, env);
    } catch (err) {
      const status = err?.code === 'custom_prompt_not_found' ? 403
                   : err?.code === 'custom_prompt_lookup_failed' ? 502
                   : err?.code === 'config_missing' ? 500
                   : 400;
      ctx.waitUntil(logRequest({
        env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, drawingId: drawingIdLower, ipHash,
      }));
      return jsonResponse({ error: err?.code ?? 'preset_id_resolution_failed' }, status);
    }

    // Select the voice for this request and assemble the system prompt
    // with it. selectVoice falls back to VOICE_STUDIO_MENTOR on any
    // failure with a console.error log; the user always gets a critique.
    const voice = await selectVoice(resolvedPresetId, userId, env);
    // Bounded-knob custom-prompt parameters (focus, tone, depth, techniques)
    // ride alongside the voice. Empty for hardcoded preset_ids and for
    // legacy custom_prompts rows that still use freeform body. Rendered
    // by buildSystemPrompt as a "PROMPT CUSTOMIZATION" section.
    const customPromptModifier = await selectCustomPromptParameters(resolvedPresetId, userId, env);
    const config = {
      ...baseConfig,
      systemPrompt: assembleSystemPrompt(voice),
      customPromptModifier,
    };

    const systemPrompt = buildSystemPrompt(config, context ?? {});
    const userContent = buildUserMessage(config, history, image);

    // Pre-flight cost ceilings — both fail-closed with 429 and a stable
    // error code the iOS client surfaces as "Daily limit reached, try again
    // tomorrow." Run AFTER tier rate limits, BEFORE the OpenAI call. These
    // are absolute provider/user spend caps; the tier-based per-minute /
    // per-day quotas above are independent soft rate limits.
    const ceilingDecision = await enforceCostCeilings({ env, userId, now });
    if (!ceilingDecision.ok) {
      console.error('[cost-ceiling] hit', {
        error: ceilingDecision.body.error,
        userId,
      });
      ctx.waitUntil(logRequest({
        env, status: REQUEST_STATUS.QUOTA_EXCEEDED, userId, drawingId: drawingIdLower, ipHash,
      }));
      return jsonResponse(ceilingDecision.body, ceilingDecision.status, {
        'Retry-After': String(ceilingDecision.body.retryAfter),
      });
    }
    const todayKey = ceilingDecision.ctx.dayKey;

    const response = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      },
      body: JSON.stringify({
        model: OPENAI_MODEL,
        messages: [
          { role: 'system', content: systemPrompt },
          { role: 'user', content: userContent },
        ],
        // gpt-5 series uses max_completion_tokens; max_tokens is rejected as
        // unsupported. Same migration footgun as the reasoning_effort rename.
        max_completion_tokens: config.maxOutputTokens,
        temperature: OPENAI_TEMPERATURE,
        seed: OPENAI_SEED,
        reasoning_effort: OPENAI_REASONING_EFFORT,
        user: userId,
      }),
    });

    if (!response.ok) {
      // Permanent diagnostic: surface OpenAI's error body, not just the
      // status code. Future migrations (model swaps, new request fields)
      // benefit from seeing the actual error message. Wrapped in try/catch
      // because response.text() can throw on certain malformed bodies, and
      // logging must never block the user-facing 502.
      let errorBody = '<unavailable>';
      try { errorBody = await response.text(); } catch {}
      console.error('[openai] non-ok status', response.status, 'body:', errorBody);
      ctx.waitUntil(logRequest({
        env, status: REQUEST_STATUS.MODEL_ERROR, userId, drawingId: drawingIdLower, ipHash,
      }));
      return jsonResponse({ error: 'Upstream model error' }, 502);
    }

    const data = await response.json();
    const feedback = data.choices?.[0]?.message?.content;
    if (!feedback) {
      ctx.waitUntil(logRequest({
        env, status: REQUEST_STATUS.MODEL_ERROR, userId, drawingId: drawingIdLower, ipHash,
      }));
      return jsonResponse({ error: 'No feedback generated' }, 502);
    }

    // Phase 5d — persistence. Build the canonical entry, append atomically
    // to drawings.critique_history. Failures are logged but don't block the
    // response: the user gets their critique once even if the row write
    // failed (graceful degradation).
    const sequenceNumber = (Array.isArray(history) ? history.length : 0) + 1;
    const entry = buildCritiqueEntry({
      feedback,
      sequenceNumber,
      config,
      tier,
      usage: data.usage,
      now,
      presetId: resolvedPresetId,
    });
    let persisted = true;
    try {
      await persistCritique({ env, drawingId: drawingIdLower, entry });
    } catch (err) {
      persisted = false;
      console.error('[persistence] orphan critique', {
        drawingId: drawingIdLower,
        userId,
        error: err?.message,
      });
    }

    // Write-through: if the resolved preset_id differs from what's currently
    // on the drawings row, update it. Skip the round-trip when they match
    // (the common case once a user settles on a preset). Fire-and-forget;
    // failure is logged. The critique entry already records the resolved
    // preset_id, so a missed write-through doesn't lose data.
    if (resolvedPresetId !== existingPresetId) {
      updateDrawingPresetId({ env, drawingId: drawingIdLower, presetId: resolvedPresetId }).catch((err) =>
        console.error('[preset] updateDrawingPresetId failed', err?.message),
      );
    }

    // set_as_default flag → user_preferences.preferred_preset_id. Only fires
    // when the request explicitly opts in. Same fire-and-forget shape.
    if (body.set_as_default === true) {
      updateUserPreferredPreset({ env, userId, presetId: resolvedPresetId }).catch((err) =>
        console.error('[preset] updateUserPreferredPreset failed', err?.message),
      );
    }

    // Quota burns only on a delivered critique. Anomaly counter rides along.
    // Don't await — the response shouldn't wait on bookkeeping, and any
    // failure here is logged but doesn't affect the user.
    recordSuccessfulCritique({ env, ctx: decision.ctx, now }).catch((err) =>
      console.error('[quota] recordSuccessfulCritique failed', err?.message),
    );

    // Update the global daily spend total for the cap. Same fire-and-forget
    // shape as recordSuccessfulCritique — failure is logged, never blocks
    // the user response. Computed from THIS request's reported usage.
    const requestCost = computeRequestCost(data.usage);
    incrementDailySpend(env, todayKey, requestCost).catch((err) =>
      console.error('[spend-cap] incrementDailySpend failed', err?.message),
    );

    // Per-user daily token cap — record actual usage post-flight so the
    // next pre-flight check sees this request's consumption. Pre-flight
    // intentionally doesn't estimate tokens (no reliable estimator without
    // the model in the loop), so the user's first over-cap request lands;
    // their next one is rejected. Fire-and-forget.
    recordRequestUsage({ env, userId, dayKey: todayKey, usage: data.usage }).catch((err) =>
      console.error('[cost-ceiling] recordRequestUsage failed', err?.message),
    );

    // Phase 5d — idempotency cache. Stores the body we're about to return so
    // a retry of the same client_request_id within 1h gets the exact same
    // response without re-charging OpenAI.
    const responseBody = { feedback, critique_entry: entry };
    recordIdempotent({ env, userId, clientRequestId, body: responseBody }).catch((err) =>
      console.error('[idempotency] recordIdempotent failed', err?.message),
    );

    // Phase 5e — terminal log. Tokens populated in both branches because
    // OpenAI delivered; status differs based on whether the row write stuck.
    const promptTokens = data.usage?.prompt_tokens ?? null;
    const completionTokens = data.usage?.completion_tokens ?? null;
    ctx.waitUntil(logRequest({
      env,
      status: persisted ? REQUEST_STATUS.SUCCESS : REQUEST_STATUS.PERSISTENCE_ORPHAN,
      userId,
      drawingId: drawingIdLower,
      ipHash,
      promptTokens,
      completionTokens,
    }));

    return jsonResponse(responseBody);
  } catch (error) {
    // INTERNAL_ERROR (Worker bug, KV outage, anything that's *our* fault).
    // Distinct from MODEL_ERROR so abuse-detection queries don't conflate
    // OpenAI hiccups with our own bugs.
    ctx.waitUntil(logRequest({
      env, status: REQUEST_STATUS.INTERNAL_ERROR, userId, drawingId: drawingIdLower, ipHash,
    }));
    // Server-side: full message lands in wrangler tail for debugging.
    // Client-side: generic copy only — never leak KV/JSON-parse/supabase-js
    // stack traces or internal field paths to callers.
    console.error('[fetch] internal error', error?.message);
    return jsonResponse({ error: 'Internal server error' }, 500);
  }
}
