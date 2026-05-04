// Phase 5a — JWT validation (ES256 / JWKS) + tier extraction + deploy config gate.
//
// Supabase signs project JWTs with ES256 (ECDSA P-256). Public keys are
// published at <SUPABASE_URL>/auth/v1/.well-known/jwks.json. We fetch + cache
// them at module scope; cache survives across requests within a Worker isolate.
// On `kid` rotation (new signing key Supabase hasn't published before our cache
// expires) we invalidate-and-refetch once before giving up.
//
// App Attest integration point: this layer answers "who is the user?" via the
// validated JWT's `sub`. App Attest (middleware/app-attest.js) is a separate
// layer that answers "is the request coming from a legitimate iOS app instance
// on a real Apple device?" Both layers run per request and both must pass
// independently — neither subsumes the other. Wire-in convention in
// routes/feedback.js: validate JWT first (cheap; module-cached JWKS), then
// validate the App Attest assertion using the request body + a key id header.
// Pass both `userId` (from JWT) and `deviceKeyId` (from App Attest) into
// downstream handlers. Do not collapse the two into a single auth function —
// they fail independently and need distinct telemetry (`auth_failed` vs
// `attest_*` codes).

const JWKS_TTL_MS = 10 * 60 * 1000;   // 10 minutes per Phase 5a spec
let jwksCache = { keys: null, fetchedAt: 0 };

async function fetchJWKS(env, fetcher = fetch) {
  if (!env.SUPABASE_URL) {
    throw new Error('SUPABASE_URL not configured');
  }
  const url = `${env.SUPABASE_URL}/auth/v1/.well-known/jwks.json`;
  const res = await fetcher(url);
  if (!res.ok) throw new Error(`JWKS fetch failed: ${res.status}`);
  const body = await res.json();
  if (!Array.isArray(body.keys)) throw new Error('JWKS response missing keys array');
  jwksCache = { keys: body.keys, fetchedAt: Date.now() };
  return body.keys;
}

async function getJWKS(env, fetcher = fetch) {
  const fresh = jwksCache.keys && (Date.now() - jwksCache.fetchedAt) < JWKS_TTL_MS;
  return fresh ? jwksCache.keys : fetchJWKS(env, fetcher);
}

async function findKeyByKid(kid, env, fetcher = fetch) {
  let keys = await getJWKS(env, fetcher);
  let key = keys.find((k) => k.kid === kid);
  if (key) return key;
  // Possible key rotation — invalidate cache and try one more time.
  jwksCache = { keys: null, fetchedAt: 0 };
  keys = await getJWKS(env, fetcher);
  return keys.find((k) => k.kid === kid) ?? null;
}

// Test-only seam: clears the module-scope JWKS cache so unit tests can
// re-stub the fetcher without one test's cached keys leaking into the next.
// Production callers never need this — Worker isolates are short-lived and
// kid-rotation refetch handles the only legitimate invalidation case.
export function _resetJwksCacheForTests() {
  jwksCache = { keys: null, fetchedAt: 0 };
}

function base64UrlToBytes(b64u) {
  const pad = '='.repeat((4 - (b64u.length % 4)) % 4);
  const b64 = (b64u + pad).replace(/-/g, '+').replace(/_/g, '/');
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function base64UrlToString(b64u) {
  return new TextDecoder().decode(base64UrlToBytes(b64u));
}

/**
 * Verify a Supabase ES256 JWT against the project's JWKS. Returns the decoded
 * payload on success; throws on any failure (malformed, expired, bad sig,
 * wrong issuer/audience). Callers should treat any thrown error as 401 — we
 * deliberately do NOT surface the reason to the client.
 *
 * `opts.fetcher` and `opts.nowSeconds` are dependency-injection seams for
 * tests. Production callers omit them and get global fetch + wall-clock time.
 */
export async function validateJWT(token, env, opts = {}) {
  const { fetcher = fetch, nowSeconds = Math.floor(Date.now() / 1000) } = opts;
  if (!token || typeof token !== 'string') throw new Error('No token');
  const parts = token.split('.');
  if (parts.length !== 3) throw new Error('Malformed JWT');
  const [headerB64, payloadB64, sigB64] = parts;

  const header = JSON.parse(base64UrlToString(headerB64));
  if (header.alg !== 'ES256') throw new Error(`Unexpected alg: ${header.alg}`);
  if (!header.kid) throw new Error('Missing kid');

  const jwk = await findKeyByKid(header.kid, env, fetcher);
  if (!jwk) throw new Error('No matching kid in JWKS');

  const cryptoKey = await crypto.subtle.importKey(
    'jwk',
    jwk,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['verify'],
  );
  const sig = base64UrlToBytes(sigB64);
  const data = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const ok = await crypto.subtle.verify(
    { name: 'ECDSA', hash: 'SHA-256' },
    cryptoKey,
    sig,
    data,
  );
  if (!ok) throw new Error('Signature invalid');

  const payload = JSON.parse(base64UrlToString(payloadB64));
  if (typeof payload.exp !== 'number' || payload.exp < nowSeconds) throw new Error('Token expired');
  // SUPABASE_JWT_ISSUER is required — the handler validates env before calling
  // here, so we always have a comparator. Previously this check was skipped
  // when the env var was unset, silently weakening auth on misconfigured deploys.
  if (payload.iss !== env.SUPABASE_JWT_ISSUER) {
    throw new Error('Bad issuer');
  }
  // Tokens with no `aud` claim must fail — `aud && ...` would have permitted
  // a valid-sig forgery missing the claim entirely.
  if (payload.aud !== 'authenticated') {
    throw new Error('Bad audience');
  }
  if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
    throw new Error('Missing sub');
  }
  return payload;
}

/**
 * Returns null if all required env config is present; else returns a string
 * describing the missing piece. Run at the top of the fetch handler before
 * any auth or KV work so a misconfigured deploy fails fast and visibly
 * rather than degrading silently. Add new required env keys here.
 */
export function validateWorkerConfig(env) {
  if (!env || typeof env !== 'object') {
    return 'Server misconfigured: env missing.';
  }
  if (!env.SUPABASE_JWT_ISSUER) {
    return 'Server misconfigured: SUPABASE_JWT_ISSUER missing.';
  }
  return null;
}

/**
 * Reads tier + Pro overrides from a validated JWT payload's app_metadata.
 * Default: free tier with no styleModifier. Synchronous because everything
 * comes from the JWT we already have in hand.
 */
export function getUserTier(payload) {
  const tier = payload?.app_metadata?.tier === 'pro' ? 'pro' : 'free';
  const promptPreferences = payload?.app_metadata?.prompt_preferences ?? null;
  return { tier, promptPreferences };
}
