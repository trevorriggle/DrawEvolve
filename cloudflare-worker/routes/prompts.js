// /v1/prompts/* — CRUD for user-authored custom prompts (bounded-knobs only).
//
// Endpoints (all require JWT + App Attest, identical posture to /):
//   GET    /v1/prompts/me      — list this user's active prompts (newest first)
//   POST   /v1/prompts         — create one. Body: { name, parameters }
//   GET    /v1/prompts/:id     — fetch one (404 if not found, 403 if not owned)
//   PATCH  /v1/prompts/:id     — update name and/or parameters
//   DELETE /v1/prompts/:id     — soft delete (stamps deleted_at)
//
// SECURITY POSTURE — bounded knobs only.
// Every input that ends up in the OpenAI prompt is server-controlled. The
// client sends an enum value; the Worker maps that value to a curated
// fragment. The `body` text column from migration 0005 is intentionally
// not writable through this surface — exposing freeform text would re-
// introduce the styleModifier prompt-injection footgun this product
// surface was designed to avoid (CUSTOMPROMPTSPLAN.md §2.3). New rows
// from this surface always carry parameters and never carry body.
//
// Method dispatch: index.js routes /v1/prompts/* here regardless of HTTP
// method. We dispatch on method internally so 405 stays a Worker concern,
// not a routing concern.

import {
  validateJWT,
  validateWorkerConfig,
} from '../middleware/auth.js';
import {
  readAppAttestHeaders,
  getAttestedKey,
  computeAppAttestClientDataHash,
  verifyAppAttestAssertion,
  updateAttestedKeyCounter,
} from '../middleware/app-attest.js';
import {
  validatePromptParameters,
  PROMPT_TEMPLATE_VERSION,
} from '../lib/prompt.js';
import { jsonResponse, unauthorized } from '../lib/http.js';

// =============================================================================
// Validation
// =============================================================================

const NAME_MAX = 50; // matches custom_prompts.name CHECK in 0005

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function isValidUuid(s) {
  return typeof s === 'string' && UUID_RE.test(s);
}

function validateName(input) {
  if (typeof input !== 'string') return { error: 'name must be a string' };
  const trimmed = input.trim();
  if (trimmed.length === 0) return { error: 'name must be non-empty' };
  if (trimmed.length > NAME_MAX) return { error: `name exceeds ${NAME_MAX} chars` };
  return { value: trimmed };
}

// =============================================================================
// Auth + App Attest (shared with feedback.js — same gates apply here)
// =============================================================================

/**
 * Returns { userId } on success, or a Response on failure (401/500). Failure
 * responses are pre-built with the correct CORS headers — caller should
 * return them verbatim. Mirrors the JWT + App Attest pair-gate sequence
 * from routes/feedback.js. Body bytes are required so the assertion's
 * clientDataHash can be re-derived from them.
 */
async function authenticate(request, env, ctx, rawBody) {
  const configErr = validateWorkerConfig(env);
  if (configErr) {
    console.error('[prompts]', configErr);
    return { response: jsonResponse({ error: configErr }, 500) };
  }

  const token = request.headers.get('Authorization')?.replace(/^Bearer\s+/i, '') ?? null;
  let payload;
  try {
    payload = await validateJWT(token, env);
  } catch (err) {
    console.log('[prompts] JWT validation failed', err?.message);
    return { response: unauthorized() };
  }
  const userId = payload.sub;

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
    console.log('[prompts] assertion failed', err?.message);
    return { response: jsonResponse({ error: 'attest_assertion_invalid' }, 401) };
  }

  return { userId };
}

// =============================================================================
// PostgREST helpers (service-role; RLS bypassed, scope enforced via WHERE)
// =============================================================================

function supabaseHeaders(env, extra = {}) {
  return {
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    Accept: 'application/json',
    ...extra,
  };
}

async function listPromptsForUser(env, userId) {
  // Active rows only (deleted_at is null). Newest first so the list view
  // surfaces what the user just created at the top. Selecting only the
  // columns the iOS list needs — body is intentionally omitted (legacy
  // freeform bodies aren't editable through this surface and don't render
  // in the bounded-knobs UI).
  const url = `${env.SUPABASE_URL}/rest/v1/custom_prompts`
    + `?user_id=eq.${encodeURIComponent(userId)}`
    + `&deleted_at=is.null`
    + `&select=id,name,parameters,template_version,created_at,updated_at`
    + `&order=created_at.desc`;
  const res = await fetch(url, { headers: supabaseHeaders(env) });
  if (!res.ok) throw new Error(`list HTTP ${res.status}`);
  return res.json();
}

async function fetchPromptForUser(env, userId, id) {
  const url = `${env.SUPABASE_URL}/rest/v1/custom_prompts`
    + `?id=eq.${encodeURIComponent(id)}`
    + `&user_id=eq.${encodeURIComponent(userId)}`
    + `&deleted_at=is.null`
    + `&select=id,name,parameters,template_version,created_at,updated_at`
    + `&limit=1`;
  const res = await fetch(url, { headers: supabaseHeaders(env) });
  if (!res.ok) throw new Error(`fetch HTTP ${res.status}`);
  const rows = await res.json();
  return Array.isArray(rows) && rows.length > 0 ? rows[0] : null;
}

async function insertPrompt(env, userId, { name, parameters }) {
  const url = `${env.SUPABASE_URL}/rest/v1/custom_prompts`;
  const res = await fetch(url, {
    method: 'POST',
    headers: supabaseHeaders(env, {
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
    }),
    body: JSON.stringify({
      user_id: userId,
      name,
      parameters,
      template_version: PROMPT_TEMPLATE_VERSION,
    }),
  });
  if (!res.ok) throw new Error(`insert HTTP ${res.status}`);
  const rows = await res.json();
  return rows[0];
}

async function updatePromptForUser(env, userId, id, patch) {
  // Filter on user_id + deleted_at as a defense-in-depth so a leaked id
  // never lets one user mutate another's row. Prefer=return=representation
  // so we can return the post-write state directly.
  const url = `${env.SUPABASE_URL}/rest/v1/custom_prompts`
    + `?id=eq.${encodeURIComponent(id)}`
    + `&user_id=eq.${encodeURIComponent(userId)}`
    + `&deleted_at=is.null`;
  const res = await fetch(url, {
    method: 'PATCH',
    headers: supabaseHeaders(env, {
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
    }),
    body: JSON.stringify(patch),
  });
  if (!res.ok) throw new Error(`update HTTP ${res.status}`);
  const rows = await res.json();
  return Array.isArray(rows) && rows.length > 0 ? rows[0] : null;
}

async function softDeletePromptForUser(env, userId, id) {
  // Idempotent: PATCHing an already-deleted row updates 0 rows but doesn't
  // error. Caller's "200 if affected, 404 otherwise" decision uses the
  // returned representation length.
  const url = `${env.SUPABASE_URL}/rest/v1/custom_prompts`
    + `?id=eq.${encodeURIComponent(id)}`
    + `&user_id=eq.${encodeURIComponent(userId)}`
    + `&deleted_at=is.null`;
  const res = await fetch(url, {
    method: 'PATCH',
    headers: supabaseHeaders(env, {
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
    }),
    body: JSON.stringify({ deleted_at: new Date().toISOString() }),
  });
  if (!res.ok) throw new Error(`delete HTTP ${res.status}`);
  const rows = await res.json();
  return Array.isArray(rows) && rows.length > 0;
}

// =============================================================================
// Per-method handlers
// =============================================================================

async function handleList(env, userId) {
  try {
    const rows = await listPromptsForUser(env, userId);
    return jsonResponse({ prompts: rows });
  } catch (err) {
    console.error('[prompts] list failed', err?.message);
    return jsonResponse({ error: 'internal_error' }, 500);
  }
}

async function handleCreate(env, userId, body) {
  if (!body || typeof body !== 'object') {
    return jsonResponse({ error: 'invalid_body' }, 400);
  }
  const nameResult = validateName(body.name);
  if (nameResult.error) return jsonResponse({ error: nameResult.error }, 400);
  const paramsResult = validatePromptParameters(body.parameters);
  if (paramsResult.error) return jsonResponse({ error: paramsResult.error }, 400);

  try {
    const row = await insertPrompt(env, userId, {
      name: nameResult.value,
      parameters: paramsResult.value,
    });
    return jsonResponse({ prompt: row }, 201);
  } catch (err) {
    console.error('[prompts] create failed', err?.message);
    return jsonResponse({ error: 'internal_error' }, 500);
  }
}

async function handleFetch(env, userId, id) {
  try {
    const row = await fetchPromptForUser(env, userId, id);
    if (!row) return jsonResponse({ error: 'not_found' }, 404);
    return jsonResponse({ prompt: row });
  } catch (err) {
    console.error('[prompts] fetch failed', err?.message);
    return jsonResponse({ error: 'internal_error' }, 500);
  }
}

async function handleUpdate(env, userId, id, body) {
  if (!body || typeof body !== 'object') {
    return jsonResponse({ error: 'invalid_body' }, 400);
  }
  const patch = {};
  if ('name' in body) {
    const nameResult = validateName(body.name);
    if (nameResult.error) return jsonResponse({ error: nameResult.error }, 400);
    patch.name = nameResult.value;
  }
  if ('parameters' in body) {
    const paramsResult = validatePromptParameters(body.parameters);
    if (paramsResult.error) return jsonResponse({ error: paramsResult.error }, 400);
    patch.parameters = paramsResult.value;
    // When parameters change, refresh the authored-against template
    // version so drift detection uses the right baseline going forward.
    patch.template_version = PROMPT_TEMPLATE_VERSION;
  }
  if (Object.keys(patch).length === 0) {
    return jsonResponse({ error: 'no_fields_to_update' }, 400);
  }

  try {
    const row = await updatePromptForUser(env, userId, id, patch);
    if (!row) return jsonResponse({ error: 'not_found' }, 404);
    return jsonResponse({ prompt: row });
  } catch (err) {
    console.error('[prompts] update failed', err?.message);
    return jsonResponse({ error: 'internal_error' }, 500);
  }
}

async function handleDelete(env, userId, id) {
  try {
    const ok = await softDeletePromptForUser(env, userId, id);
    if (!ok) return jsonResponse({ error: 'not_found' }, 404);
    return jsonResponse({ ok: true });
  } catch (err) {
    console.error('[prompts] delete failed', err?.message);
    return jsonResponse({ error: 'internal_error' }, 500);
  }
}

// =============================================================================
// Top-level dispatcher (called from index.js)
// =============================================================================

/**
 * Handles every /v1/prompts* request. Method + path together pick the
 * concrete handler. Auth runs once up front so every protected branch
 * shares the same gate.
 */
export async function handlePrompts(request, env, ctx) {
  const method = request.method.toUpperCase();
  const pathname = new URL(request.url).pathname;

  // Read body once — needed for App Attest clientDataHash on every method
  // (including GET/DELETE, which sign over zero bytes). request.json()
  // would consume it; we own the parse so the hash is over the exact
  // bytes the client signed.
  const rawBody = new Uint8Array(await request.arrayBuffer());
  let body = null;
  if (rawBody.length > 0) {
    try { body = JSON.parse(new TextDecoder().decode(rawBody)); }
    catch { body = null; }
  }

  const auth = await authenticate(request, env, ctx, rawBody);
  if (auth.response) return auth.response;
  const { userId } = auth;

  // /v1/prompts/me — list (GET only)
  if (pathname === '/v1/prompts/me') {
    if (method !== 'GET') return jsonResponse({ error: 'method_not_allowed' }, 405);
    return handleList(env, userId);
  }

  // /v1/prompts — create (POST only)
  if (pathname === '/v1/prompts') {
    if (method !== 'POST') return jsonResponse({ error: 'method_not_allowed' }, 405);
    return handleCreate(env, userId, body);
  }

  // /v1/prompts/:id — fetch / update / delete
  const idMatch = pathname.match(/^\/v1\/prompts\/([^/]+)$/);
  if (idMatch) {
    const id = idMatch[1].toLowerCase();
    if (!isValidUuid(id)) return jsonResponse({ error: 'invalid_id' }, 400);
    if (method === 'GET')    return handleFetch(env, userId, id);
    if (method === 'PATCH')  return handleUpdate(env, userId, id, body);
    if (method === 'DELETE') return handleDelete(env, userId, id);
    return jsonResponse({ error: 'method_not_allowed' }, 405);
  }

  return jsonResponse({ error: 'not_found' }, 404);
}
