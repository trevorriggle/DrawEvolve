// Phase A — social foundations: profile read/write endpoints.
//
// Five routes live here:
//   GET    /v1/me                          → current user's profile + tier + counts
//   PATCH  /v1/profiles/me                 → update display_name / bio / is_public /
//                                             is_searchable / username (one-time gate)
//   POST   /v1/profiles/me/avatar          → mint a Supabase signed upload URL
//   GET    /v1/profiles/:username          → public profile lookup by exact handle
//   GET    /v1/profiles/search?q=&cursor=  → trigram search across username + display_name
//
// All five gate on JWT + App Attest (same composition as routes/feedback.js).
// The composition lives inline in `requireAuth` below — we don't extract it
// into middleware/ because that would touch existing middleware files, which
// is out of scope for this PR.
//
// Worker is the sole writer to public.profiles. iOS reads through these
// endpoints (Q8 default) rather than direct PostgREST so we keep one
// chokepoint for caching / abuse signals later.

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
import { jsonResponse, unauthorized } from '../lib/http.js';

// =============================================================================
// Constants
// =============================================================================

// Mirrors the Postgres check constraint `username ~ '^[a-z0-9_]{3,24}$'`.
// Validate at the edge so a bad payload 400s without round-tripping to the DB.
const USERNAME_REGEX = /^[a-z0-9_]{3,24}$/;
const DISPLAY_NAME_MAX = 50;
const BIO_MAX = 280;

// Search rate limit — 60 requests / minute / user. Stored as a JSON array of
// timestamps in `searchlimit:<user>` with a 120s TTL, mirroring the per-minute
// pattern in middleware/rate-limit.js.
const SEARCH_LIMIT_PER_MIN = 60;
const SEARCH_LIMIT_WINDOW_MS = 60_000;
const SEARCH_LIMIT_TTL_S = 120;

// Search result page size (also the cap on q length to deter pathological
// trigram queries). Cursor is a positive integer offset.
const SEARCH_PAGE_SIZE = 20;
const SEARCH_QUERY_MAX = 100;

// =============================================================================
// Auth composition — JWT + App Attest gate, mirrors routes/feedback.js
// =============================================================================

/**
 * Run the JWT and App Attest gates against the incoming request. Returns
 * either { ok: true, userId, payload, rawBody, request } on success, or
 * { ok: false, response } where `response` is the 401 Response to return.
 *
 * `rawBody` is the raw bytes of the request body. App Attest's
 * clientDataHash signs over the exact bytes the client sent, so we read
 * the body once here and hand it back to the caller for JSON.parse.
 *
 * Distinct from middleware/auth.js's validateJWT: this composes both gates
 * AND parses the JWT off the Authorization header. validateJWT alone
 * doesn't read headers and doesn't know about App Attest.
 */
export async function requireAuth(request, env, ctx) {
  const token = request.headers.get('Authorization')?.replace(/^Bearer\s+/i, '') ?? null;
  let payload;
  try {
    payload = await validateJWT(token, env);
  } catch (err) {
    console.log('[profiles] JWT validation failed', err?.message);
    return { ok: false, response: unauthorized() };
  }
  const userId = payload.sub;

  // Read the body bytes once — App Attest's clientDataHash signs over them,
  // and PATCH/POST handlers want to JSON.parse the same bytes.
  const rawBody = new Uint8Array(await request.arrayBuffer());

  const attestHeaders = readAppAttestHeaders(request);
  if (!attestHeaders) {
    return { ok: false, response: jsonResponse({ error: 'attest_headers_missing' }, 401) };
  }
  const stored = await getAttestedKey(attestHeaders.keyId, env);
  if (!stored) {
    return { ok: false, response: jsonResponse({ error: 'attest_key_unknown' }, 401) };
  }
  const expectedEnv = env.APP_ATTEST_ENV === 'production' ? 'production' : 'development';
  if (stored.env !== expectedEnv) {
    return { ok: false, response: jsonResponse({ error: 'attest_env_mismatch' }, 401) };
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
    console.log('[profiles] App Attest assertion failed', err?.message);
    return { ok: false, response: jsonResponse({ error: 'attest_assertion_invalid' }, 401) };
  }

  return { ok: true, userId, payload, rawBody };
}

// =============================================================================
// Supabase REST helpers
// =============================================================================

function supabaseHeaders(env, extra = {}) {
  return {
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    Accept: 'application/json',
    ...extra,
  };
}

/**
 * Fetch a profile row by user_id. Returns the row or null. Throws on any
 * non-2xx Supabase response (caller decides whether to 500 or fall through).
 */
export async function fetchProfileByUserId(env, userId, fetcher = fetch) {
  const url = `${env.SUPABASE_URL}/rest/v1/profiles`
    + `?user_id=eq.${encodeURIComponent(userId)}`
    + `&select=*&limit=1`;
  const res = await fetcher(url, { headers: supabaseHeaders(env) });
  if (!res.ok) throw new Error(`fetchProfileByUserId HTTP ${res.status}`);
  const rows = await res.json();
  return Array.isArray(rows) && rows[0] ? rows[0] : null;
}

/**
 * Fetch a profile row by exact (case-insensitive) username. Returns the row
 * or null. Citext comparison happens server-side — we URL-encode the raw
 * value and Supabase's PostgREST `eq.` operator uses citext = semantics.
 */
export async function fetchProfileByUsername(env, username, fetcher = fetch) {
  const url = `${env.SUPABASE_URL}/rest/v1/profiles`
    + `?username=eq.${encodeURIComponent(username)}`
    + `&select=user_id,username,display_name,bio,avatar_path,is_public,is_searchable,`
    + `follower_count,following_count,post_count,created_at`
    + `&limit=1`;
  const res = await fetcher(url, { headers: supabaseHeaders(env) });
  if (!res.ok) throw new Error(`fetchProfileByUsername HTTP ${res.status}`);
  const rows = await res.json();
  return Array.isArray(rows) && rows[0] ? rows[0] : null;
}

/**
 * PATCH a profile row. Returns the updated row (Prefer: return=representation)
 * or null when the row was not found. Throws on conflict / other errors so
 * the route handler can map to the right status code.
 */
export async function patchProfile(env, userId, fields, fetcher = fetch) {
  const url = `${env.SUPABASE_URL}/rest/v1/profiles`
    + `?user_id=eq.${encodeURIComponent(userId)}`;
  const res = await fetcher(url, {
    method: 'PATCH',
    headers: supabaseHeaders(env, {
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
    }),
    body: JSON.stringify(fields),
  });
  if (res.status === 409) {
    const err = new Error('username_taken');
    err.code = 'username_taken';
    throw err;
  }
  if (!res.ok) {
    const err = new Error(`patchProfile HTTP ${res.status}`);
    err.code = 'profile_patch_failed';
    err.status = res.status;
    throw err;
  }
  const rows = await res.json();
  return Array.isArray(rows) && rows[0] ? rows[0] : null;
}

/**
 * Lazy-create the profile row when GET /v1/me hits but no row exists. The
 * 0006_profiles auto-create trigger should always populate this row, but
 * if the trigger ever fails (or fires before this Worker can read), we
 * back-fill on first read so iOS never sees a 404.
 */
async function ensureProfile(env, userId, email, fetcher = fetch) {
  const existing = await fetchProfileByUserId(env, userId, fetcher);
  if (existing) return existing;

  const username = 'user_' + userId.replace(/-/g, '').slice(0, 8).toLowerCase();
  const emailLocal = typeof email === 'string' ? email.split('@')[0] : '';
  const displayName = (emailLocal && emailLocal.length > 0) ? emailLocal : 'User';

  const url = `${env.SUPABASE_URL}/rest/v1/profiles`;
  const res = await fetcher(url, {
    method: 'POST',
    headers: supabaseHeaders(env, {
      'Content-Type': 'application/json',
      Prefer: 'return=representation,resolution=ignore-duplicates',
    }),
    body: JSON.stringify({ user_id: userId, username, display_name: displayName }),
  });
  if (!res.ok && res.status !== 409) {
    throw new Error(`ensureProfile HTTP ${res.status}`);
  }
  // ignore-duplicates returns no body on conflict; re-read in either case.
  return fetchProfileByUserId(env, userId, fetcher);
}

// =============================================================================
// Search rate limit
// =============================================================================

/**
 * Rolling-window per-minute search rate limit. Returns:
 *   { ok: true }                        — under the limit; attempt recorded.
 *   { ok: false, retryAfter, used }     — at-or-over the limit.
 *
 * Mirrors the `rate:<user>` pattern in middleware/rate-limit.js: store a
 * JSON array of attempt timestamps with a 120s TTL, filter to the last 60s
 * on read, reject when length >= cap.
 */
export async function enforceSearchRateLimit({ env, userId, now }) {
  const key = `searchlimit:${userId}`;
  const raw = await env.QUOTA_KV.get(key);
  let recent = [];
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed)) {
        recent = parsed.filter((t) => typeof t === 'number' && now - t < SEARCH_LIMIT_WINDOW_MS);
      }
    } catch {
      recent = [];
    }
  }
  if (recent.length >= SEARCH_LIMIT_PER_MIN) {
    const oldest = Math.min(...recent);
    const retryAfter = Math.max(1, Math.ceil((SEARCH_LIMIT_WINDOW_MS - (now - oldest)) / 1000));
    return { ok: false, retryAfter, used: recent.length, limit: SEARCH_LIMIT_PER_MIN };
  }
  await env.QUOTA_KV.put(
    key,
    JSON.stringify([...recent, now]),
    { expirationTtl: SEARCH_LIMIT_TTL_S },
  );
  return { ok: true };
}

// =============================================================================
// Validation
// =============================================================================

function validatePatchFields(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return { error: 'invalid_body' };
  }
  const out = {};
  if ('display_name' in body) {
    const v = body.display_name;
    if (typeof v !== 'string') return { error: 'invalid_display_name' };
    const trimmed = v.trim();
    if (trimmed.length < 1 || trimmed.length > DISPLAY_NAME_MAX) {
      return { error: 'invalid_display_name' };
    }
    out.display_name = trimmed;
  }
  if ('bio' in body) {
    const v = body.bio;
    if (v !== null && typeof v !== 'string') return { error: 'invalid_bio' };
    if (typeof v === 'string' && v.length > BIO_MAX) return { error: 'invalid_bio' };
    out.bio = v;
  }
  if ('is_public' in body) {
    if (typeof body.is_public !== 'boolean') return { error: 'invalid_is_public' };
    out.is_public = body.is_public;
  }
  if ('is_searchable' in body) {
    if (typeof body.is_searchable !== 'boolean') return { error: 'invalid_is_searchable' };
    out.is_searchable = body.is_searchable;
  }
  if ('username' in body) {
    if (typeof body.username !== 'string') return { error: 'invalid_username' };
    const u = body.username.trim().toLowerCase();
    if (!USERNAME_REGEX.test(u)) return { error: 'invalid_username_format' };
    out.username = u;
  }
  // avatar_path can be set explicitly (e.g. after a successful upload) or
  // cleared (null). The Worker doesn't validate that the object exists in
  // Storage — that's a missing-image surface, not a security boundary.
  if ('avatar_path' in body) {
    const v = body.avatar_path;
    if (v !== null && typeof v !== 'string') return { error: 'invalid_avatar_path' };
    if (typeof v === 'string') {
      // Path must be within the user's folder. The Storage RLS already
      // enforces this on writes; the gate here is so iOS can't claim a
      // foreign user's avatar by stamping the path on their own profile.
      // We don't know the userId here yet — caller injects it post-validation.
      out.avatar_path = v;
    } else {
      out.avatar_path = null;
    }
  }
  if (Object.keys(out).length === 0) return { error: 'no_fields' };
  return { fields: out };
}

function publicProfileShape(row) {
  // Strip server-internal columns before sending to clients. avatar_path is
  // intentionally returned as a Storage-relative path; iOS composes the
  // public URL using the avatars bucket base.
  return {
    user_id: row.user_id,
    username: row.username,
    display_name: row.display_name,
    bio: row.bio ?? null,
    avatar_path: row.avatar_path ?? null,
    is_public: row.is_public,
    is_searchable: row.is_searchable,
    follower_count: row.follower_count ?? 0,
    following_count: row.following_count ?? 0,
    post_count: row.post_count ?? 0,
    created_at: row.created_at,
  };
}

// =============================================================================
// Handlers
// =============================================================================

/**
 * GET /v1/me — return the requesting user's profile + tier + counts. Auto-
 * creates the profile row if the signup trigger missed it.
 */
export async function handleGetMe(request, env, ctx) {
  const configErr = validateWorkerConfig(env);
  if (configErr) return jsonResponse({ error: configErr }, 500);

  const auth = await requireAuth(request, env, ctx);
  if (!auth.ok) return auth.response;

  const { userId, payload } = auth;
  const { tier } = getUserTier(payload);

  let profile;
  try {
    profile = await ensureProfile(env, userId, payload.email, fetch);
  } catch (err) {
    console.error('[profiles] ensureProfile failed', err?.message);
    return jsonResponse({ error: 'profile_unavailable' }, 502);
  }
  if (!profile) {
    return jsonResponse({ error: 'profile_unavailable' }, 502);
  }
  return jsonResponse({
    profile: publicProfileShape(profile),
    tier,
    username_set: profile.username_set_at !== null,
  });
}

/**
 * PATCH /v1/profiles/me — update display_name / bio / is_public /
 * is_searchable / avatar_path / username. Username has the one-time-set gate:
 * if username_set_at is non-null, further changes return 409
 * username_immutable. The first PATCH that includes a username stamps
 * username_set_at = now() so subsequent changes are blocked.
 */
export async function handlePatchMe(request, env, ctx) {
  const configErr = validateWorkerConfig(env);
  if (configErr) return jsonResponse({ error: configErr }, 500);

  const auth = await requireAuth(request, env, ctx);
  if (!auth.ok) return auth.response;
  const { userId, rawBody } = auth;

  let body;
  try {
    body = JSON.parse(new TextDecoder().decode(rawBody));
  } catch {
    return jsonResponse({ error: 'invalid_body' }, 400);
  }
  const { error, fields } = validatePatchFields(body);
  if (error) return jsonResponse({ error }, 400);

  // avatar_path scope check — must point at the requester's own folder.
  if (typeof fields.avatar_path === 'string') {
    const segments = fields.avatar_path.split('/');
    if (segments[0] !== userId) {
      return jsonResponse({ error: 'invalid_avatar_path' }, 400);
    }
  }

  // Username one-time-set gate. Read the current row to see if username_set_at
  // is already populated; if so, block any username change. We intentionally
  // do not allow re-setting to the same value either — once set, the column
  // is immutable.
  let current;
  try {
    current = await fetchProfileByUserId(env, userId, fetch);
  } catch (err) {
    console.error('[profiles] read-before-update failed', err?.message);
    return jsonResponse({ error: 'profile_unavailable' }, 502);
  }
  if (!current) {
    return jsonResponse({ error: 'profile_not_found' }, 404);
  }
  if ('username' in fields) {
    if (current.username_set_at !== null) {
      return jsonResponse({ error: 'username_immutable' }, 409);
    }
    fields.username_set_at = new Date().toISOString();
  }

  let updated;
  try {
    updated = await patchProfile(env, userId, fields, fetch);
  } catch (err) {
    if (err?.code === 'username_taken') {
      return jsonResponse({ error: 'username_taken' }, 409);
    }
    console.error('[profiles] patchProfile failed', err?.message);
    return jsonResponse({ error: 'profile_update_failed' }, 502);
  }
  if (!updated) return jsonResponse({ error: 'profile_not_found' }, 404);
  return jsonResponse({ profile: publicProfileShape(updated) });
}

/**
 * POST /v1/profiles/me/avatar — mint a Supabase signed upload URL for the
 * requester's avatar. iOS PUTs the JPEG bytes directly to Supabase Storage,
 * then PATCHes /v1/profiles/me with `avatar_path: "<user_id>/avatar.jpg"`
 * to publish.
 *
 * We mint via Supabase Storage's "signed upload URL" endpoint
 * (POST /storage/v1/object/upload/sign/avatars/<path>) using the service-
 * role key. The returned token is single-use and short-TTL — Storage RLS
 * still applies, so the path must remain within the requester's folder.
 *
 * Why presigned upload over Worker proxy: avatars are ≤ 256 KB but can
 * spike during onboarding; keeping image bytes off the Worker saves CPU
 * + bandwidth + Worker request budget on a path that has no business
 * logic of its own.
 */
export async function handleAvatarUpload(request, env, ctx) {
  const configErr = validateWorkerConfig(env);
  if (configErr) return jsonResponse({ error: configErr }, 500);

  const auth = await requireAuth(request, env, ctx);
  if (!auth.ok) return auth.response;
  const { userId } = auth;

  const path = `${userId}/avatar.jpg`;
  const url = `${env.SUPABASE_URL}/storage/v1/object/upload/sign/avatars/${encodeURIComponent(userId)}/avatar.jpg`;
  let res;
  try {
    res = await fetch(url, {
      method: 'POST',
      headers: supabaseHeaders(env, { 'Content-Type': 'application/json' }),
      body: JSON.stringify({}),
    });
  } catch (err) {
    console.error('[profiles] signed-upload fetch threw', err?.message);
    return jsonResponse({ error: 'avatar_upload_unavailable' }, 502);
  }
  if (!res.ok) {
    let errBody = '<unavailable>';
    try { errBody = await res.text(); } catch {}
    console.error('[profiles] signed-upload non-ok', res.status, errBody);
    return jsonResponse({ error: 'avatar_upload_unavailable' }, 502);
  }
  const data = await res.json();
  // Supabase returns either { url, token } or { signedUrl, token }; normalize.
  const signedRel = data.url ?? data.signedUrl;
  if (!signedRel || !data.token) {
    console.error('[profiles] signed-upload missing url/token in response');
    return jsonResponse({ error: 'avatar_upload_unavailable' }, 502);
  }
  const uploadUrl = signedRel.startsWith('http')
    ? signedRel
    : `${env.SUPABASE_URL}/storage/v1${signedRel.startsWith('/') ? '' : '/'}${signedRel}`;
  return jsonResponse({ uploadUrl, token: data.token, path, bucket: 'avatars' });
}

/**
 * GET /v1/profiles/:username — public profile lookup by exact handle.
 * Resolves regardless of `is_searchable` (Q4: searchable=false hides from
 * search but not from direct lookup), but returns 404 when `is_public=false`
 * and the requester isn't the owner. Counts come straight from the cached
 * columns on the profiles row.
 */
export async function handleGetProfileByUsername(request, env, ctx, username) {
  const configErr = validateWorkerConfig(env);
  if (configErr) return jsonResponse({ error: configErr }, 500);

  const auth = await requireAuth(request, env, ctx);
  if (!auth.ok) return auth.response;
  const { userId } = auth;

  // Validate username at the edge so a malformed path 404s without hitting DB.
  const lower = String(username || '').toLowerCase();
  if (!USERNAME_REGEX.test(lower)) {
    return jsonResponse({ error: 'profile_not_found' }, 404);
  }

  let row;
  try {
    row = await fetchProfileByUsername(env, lower, fetch);
  } catch (err) {
    console.error('[profiles] fetchProfileByUsername failed', err?.message);
    return jsonResponse({ error: 'profile_unavailable' }, 502);
  }
  if (!row) return jsonResponse({ error: 'profile_not_found' }, 404);
  if (!row.is_public && row.user_id !== userId) {
    // Surface as not-found rather than 403 so private accounts don't reveal
    // their existence to non-followers via a different status code.
    return jsonResponse({ error: 'profile_not_found' }, 404);
  }
  return jsonResponse({ profile: publicProfileShape(row) });
}

/**
 * GET /v1/profiles/search?q=&cursor= — trigram search across username +
 * display_name, hides is_searchable=false rows. Cursor is a positive integer
 * page offset; page size is 20.
 *
 * This route reads URL search params from the GET, but the request body
 * still has to clear App Attest (which signs over the bytes). The body for
 * a GET is empty — `requireAuth` reads zero bytes and the assertion
 * verifier hashes the empty body. iOS clients must therefore send a
 * Content-Length: 0 GET, which is the default for fetch + URLSession.
 */
export async function handleProfileSearch(request, env, ctx) {
  const configErr = validateWorkerConfig(env);
  if (configErr) return jsonResponse({ error: configErr }, 500);

  const auth = await requireAuth(request, env, ctx);
  if (!auth.ok) return auth.response;
  const { userId } = auth;

  const url = new URL(request.url);
  const q = (url.searchParams.get('q') ?? '').trim();
  const cursorRaw = url.searchParams.get('cursor');
  if (q.length < 1 || q.length > SEARCH_QUERY_MAX) {
    return jsonResponse({ error: 'invalid_query' }, 400);
  }
  let offset = 0;
  if (cursorRaw !== null) {
    const parsed = parseInt(cursorRaw, 10);
    if (!Number.isFinite(parsed) || parsed < 0 || parsed > 10_000) {
      return jsonResponse({ error: 'invalid_cursor' }, 400);
    }
    offset = parsed;
  }

  const decision = await enforceSearchRateLimit({ env, userId, now: Date.now() });
  if (!decision.ok) {
    return jsonResponse(
      {
        error: 'search_rate_limited',
        limit: decision.limit,
        used: decision.used,
        retryAfter: decision.retryAfter,
      },
      429,
      { 'Retry-After': String(decision.retryAfter) },
    );
  }

  // Trigram OR ilike fallback: the GIN trgm indexes accelerate `%` (similarity
  // > pg_trgm.similarity_threshold) AND `ilike '%q%'` lookups; PostgREST
  // exposes both via its `ilike` and `phfts` operators but not `%` directly.
  // For MVP we keep the query simple — `ilike '%<q>%'` against username +
  // display_name with the trigram index doing the heavy lifting under the
  // hood. The `or=` filter combines both columns in one round-trip.
  const ilikePattern = `*${q.replace(/[*]/g, '')}*`;
  const restUrl = `${env.SUPABASE_URL}/rest/v1/profiles`
    + `?or=(username.ilike.${encodeURIComponent(ilikePattern)},display_name.ilike.${encodeURIComponent(ilikePattern)})`
    + `&is_searchable=eq.true`
    + `&select=user_id,username,display_name,avatar_path,follower_count`
    + `&order=follower_count.desc`
    + `&limit=${SEARCH_PAGE_SIZE}`
    + `&offset=${offset}`;
  let res;
  try {
    res = await fetch(restUrl, { headers: supabaseHeaders(env) });
  } catch (err) {
    console.error('[profiles] search fetch threw', err?.message);
    return jsonResponse({ error: 'search_unavailable' }, 502);
  }
  if (!res.ok) {
    console.error('[profiles] search non-ok', res.status);
    return jsonResponse({ error: 'search_unavailable' }, 502);
  }
  const rows = await res.json();
  const next = (Array.isArray(rows) && rows.length === SEARCH_PAGE_SIZE)
    ? String(offset + SEARCH_PAGE_SIZE)
    : null;
  return jsonResponse({ results: rows, cursor: next });
}
