// /v1/palettes — CRUD for user palettes (Feature 5, Phase 3).
//
// Endpoints (all require JWT + App Attest when enforced, identical
// posture to /v1/prompts and /v1/eve/*):
//   GET    /v1/palettes        — list active palettes for this user
//   POST   /v1/palettes        — create one. Body: { name, colors[] }
//   GET    /v1/palettes/:id    — fetch one (404 if not found / not owned)
//   PATCH  /v1/palettes/:id    — update name and/or colors
//   DELETE /v1/palettes/:id    — soft delete (stamp deleted_at)
//
// Method dispatch: index.js routes /v1/palettes/* here regardless of
// HTTP method. This route owns its own method gating and 405s — same
// shape as handlePrompts.
//
// AI palette generation (POST /v1/palettes/generate) is NOT in this
// route. v1's AI palette generation runs on-device via iOS Core Image
// + vImage histogram (no server call needed). If we later add an
// OpenAI-vision-based "smart palette" Pro feature, it would live on
// its own route — easier to gate, easier to A/B than mixing CRUD and
// AI-generation behind the same path.

import {
  validateJWT,
  validateWorkerConfig,
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
  validatePalettePayload,
} from '../lib/palettes-validation.js';
import { jsonResponse, unauthorized } from '../lib/http.js';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function isValidUuid(s) {
  return typeof s === 'string' && UUID_RE.test(s);
}

// =============================================================================
// Auth + App Attest (same gate sequence as routes/prompts.js + routes/eve.js)
// =============================================================================

async function authenticate(request, env, ctx, rawBody) {
  const configErr = validateWorkerConfig(env);
  if (configErr) {
    console.error('[palettes]', configErr);
    return { response: jsonResponse({ error: configErr }, 500) };
  }

  const token = request.headers.get('Authorization')?.replace(/^Bearer\s+/i, '') ?? null;
  let payload;
  try {
    payload = await validateJWT(token, env);
  } catch (err) {
    console.log('[palettes] JWT validation failed', err?.message);
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
      console.log('[palettes] assertion failed', err?.message);
      return { response: jsonResponse({ error: 'attest_assertion_invalid' }, 401) };
    }
  } else {
    console.log('[palettes] attest enforcement disabled — request on JWT alone');
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

const PALETTE_COLUMNS = 'id,user_id,name,colors,created_at,updated_at,deleted_at';

async function listPalettesForUser(env, userId, fetcher = fetch) {
  const url = `${env.SUPABASE_URL}/rest/v1/user_palettes`
    + `?user_id=eq.${encodeURIComponent(userId)}`
    + `&deleted_at=is.null`
    + `&select=${PALETTE_COLUMNS}`
    + `&order=updated_at.desc`;
  const res = await fetcher(url, { headers: supabaseHeaders(env) });
  if (!res.ok) {
    const body = await res.text().catch(() => '<unreadable>');
    throw new Error(`list HTTP ${res.status}: ${body.slice(0, 500)}`);
  }
  return res.json();
}

async function fetchPaletteForUser(env, userId, id, fetcher = fetch) {
  const url = `${env.SUPABASE_URL}/rest/v1/user_palettes`
    + `?id=eq.${encodeURIComponent(id)}`
    + `&user_id=eq.${encodeURIComponent(userId)}`
    + `&deleted_at=is.null`
    + `&select=${PALETTE_COLUMNS}`
    + `&limit=1`;
  const res = await fetcher(url, { headers: supabaseHeaders(env) });
  if (!res.ok) {
    const body = await res.text().catch(() => '<unreadable>');
    throw new Error(`fetch HTTP ${res.status}: ${body.slice(0, 500)}`);
  }
  const rows = await res.json();
  return Array.isArray(rows) && rows.length > 0 ? rows[0] : null;
}

async function insertPalette(env, userId, { name, colors }, fetcher = fetch) {
  const url = `${env.SUPABASE_URL}/rest/v1/user_palettes`;
  const res = await fetcher(url, {
    method: 'POST',
    headers: supabaseHeaders(env, {
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
    }),
    body: JSON.stringify({ user_id: userId, name, colors }),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '<unreadable>');
    throw new Error(`insert HTTP ${res.status}: ${body.slice(0, 500)}`);
  }
  const rows = await res.json();
  return rows[0];
}

async function updatePaletteForUser(env, userId, id, patch, fetcher = fetch) {
  // Filter on user_id + deleted_at IS NULL as a defense-in-depth so a
  // leaked id never lets one user mutate another's palette and so
  // soft-deleted palettes are immutable.
  const url = `${env.SUPABASE_URL}/rest/v1/user_palettes`
    + `?id=eq.${encodeURIComponent(id)}`
    + `&user_id=eq.${encodeURIComponent(userId)}`
    + `&deleted_at=is.null`;
  const res = await fetcher(url, {
    method: 'PATCH',
    headers: supabaseHeaders(env, {
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
    }),
    body: JSON.stringify(patch),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '<unreadable>');
    throw new Error(`update HTTP ${res.status}: ${body.slice(0, 500)}`);
  }
  const rows = await res.json();
  return Array.isArray(rows) && rows.length > 0 ? rows[0] : null;
}

async function softDeletePaletteForUser(env, userId, id, fetcher = fetch) {
  const url = `${env.SUPABASE_URL}/rest/v1/user_palettes`
    + `?id=eq.${encodeURIComponent(id)}`
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
    throw new Error(`delete HTTP ${res.status}: ${body.slice(0, 500)}`);
  }
  const rows = await res.json();
  return Array.isArray(rows) && rows.length > 0;
}

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

async function handleList(request, env, ctx) {
  const auth = await authenticate(request, env, ctx, new Uint8Array(0));
  if (auth.response) return auth.response;
  try {
    const palettes = await listPalettesForUser(env, auth.userId);
    return jsonResponse({ palettes });
  } catch (err) {
    console.error('[palettes] list failed', err?.message);
    return jsonResponse({ error: 'Internal server error' }, 500);
  }
}

async function handleCreate(request, env, ctx) {
  const { rawBody, body } = await readJsonBody(request);
  const auth = await authenticate(request, env, ctx, rawBody);
  if (auth.response) return auth.response;

  const validation = validatePalettePayload(body, { requireAtLeastOne: false });
  if (!validation.ok) {
    return jsonResponse({ error: validation.reason }, 400);
  }

  try {
    const created = await insertPalette(env, auth.userId, validation.value);
    return jsonResponse({ palette: created }, 201);
  } catch (err) {
    console.error('[palettes] create failed', err?.message);
    return jsonResponse({ error: 'Internal server error' }, 500);
  }
}

async function handleGet(request, env, ctx, id) {
  if (!isValidUuid(id)) {
    return jsonResponse({ error: 'Invalid palette id' }, 400);
  }
  const auth = await authenticate(request, env, ctx, new Uint8Array(0));
  if (auth.response) return auth.response;
  try {
    const palette = await fetchPaletteForUser(env, auth.userId, id);
    if (!palette) return jsonResponse({ error: 'Palette not found' }, 404);
    return jsonResponse({ palette });
  } catch (err) {
    console.error('[palettes] get failed', err?.message);
    return jsonResponse({ error: 'Internal server error' }, 500);
  }
}

async function handlePatch(request, env, ctx, id) {
  if (!isValidUuid(id)) {
    return jsonResponse({ error: 'Invalid palette id' }, 400);
  }
  const { rawBody, body } = await readJsonBody(request);
  const auth = await authenticate(request, env, ctx, rawBody);
  if (auth.response) return auth.response;

  const validation = validatePalettePayload(body, { requireAtLeastOne: true });
  if (!validation.ok) {
    return jsonResponse({ error: validation.reason }, 400);
  }

  try {
    const updated = await updatePaletteForUser(env, auth.userId, id, validation.value);
    if (!updated) {
      // Either the id doesn't exist, doesn't belong to the user, or is
      // soft-deleted. Same 404 in all cases — don't leak existence.
      return jsonResponse({ error: 'Palette not found' }, 404);
    }
    return jsonResponse({ palette: updated });
  } catch (err) {
    console.error('[palettes] patch failed', err?.message);
    return jsonResponse({ error: 'Internal server error' }, 500);
  }
}

async function handleDelete(request, env, ctx, id) {
  if (!isValidUuid(id)) {
    return jsonResponse({ error: 'Invalid palette id' }, 400);
  }
  const auth = await authenticate(request, env, ctx, new Uint8Array(0));
  if (auth.response) return auth.response;
  try {
    await softDeletePaletteForUser(env, auth.userId, id);
    // Idempotent — return 200 whether or not a row was affected. Same
    // shape as Eve's DELETE so iOS doesn't have to special-case re-deletes.
    return jsonResponse({ ok: true });
  } catch (err) {
    console.error('[palettes] delete failed', err?.message);
    return jsonResponse({ error: 'Internal server error' }, 500);
  }
}

// =============================================================================
// Top-level method dispatcher
// =============================================================================

export async function handlePalettes(request, env, ctx) {
  const pathname = new URL(request.url).pathname;
  const method = request.method;

  // GET /v1/palettes / POST /v1/palettes
  if (pathname === '/v1/palettes') {
    if (method === 'GET') return handleList(request, env, ctx);
    if (method === 'POST') return handleCreate(request, env, ctx);
    return jsonResponse({ error: 'Method not allowed' }, 405);
  }

  // /v1/palettes/:id — GET / PATCH / DELETE
  const idMatch = pathname.match(/^\/v1\/palettes\/([^/]+)$/);
  if (idMatch) {
    if (method === 'GET')    return handleGet(request, env, ctx, idMatch[1]);
    if (method === 'PATCH')  return handlePatch(request, env, ctx, idMatch[1]);
    if (method === 'DELETE') return handleDelete(request, env, ctx, idMatch[1]);
    return jsonResponse({ error: 'Method not allowed' }, 405);
  }

  return jsonResponse({ error: 'Not found' }, 404);
}
