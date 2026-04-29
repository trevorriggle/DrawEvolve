// JWT verification for the delete-account edge function. Mirrors the
// Worker's Phase 5a validateJWT: ES256 / P-256 against the Supabase project's
// JWKS, with a 10-min in-process cache and a one-shot refetch on kid miss
// (handles key rotation).
//
// We deliberately verify explicitly rather than relying on Supabase's
// `verify_jwt = true` default — an account-deletion endpoint warrants
// belt-and-suspenders, and the pattern matches what the Worker already does.

const JWKS_TTL_MS = 10 * 60 * 1000;

interface JwksKey {
  kid: string;
  // The rest of the JWK fields aren't typed — crypto.subtle.importKey
  // accepts the raw object.
  [k: string]: unknown;
}

let jwksCache: { keys: JwksKey[] | null; fetchedAt: number } = {
  keys: null,
  fetchedAt: 0,
};

async function fetchJWKS(supabaseUrl: string): Promise<JwksKey[]> {
  const url = `${supabaseUrl}/auth/v1/.well-known/jwks.json`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`JWKS fetch failed: ${res.status}`);
  const body = await res.json();
  if (!Array.isArray(body.keys)) throw new Error("JWKS response missing keys array");
  jwksCache = { keys: body.keys, fetchedAt: Date.now() };
  return body.keys;
}

async function getJWKS(supabaseUrl: string): Promise<JwksKey[]> {
  const fresh =
    jwksCache.keys && Date.now() - jwksCache.fetchedAt < JWKS_TTL_MS;
  return fresh ? (jwksCache.keys as JwksKey[]) : fetchJWKS(supabaseUrl);
}

async function findKeyByKid(kid: string, supabaseUrl: string): Promise<JwksKey | null> {
  let keys = await getJWKS(supabaseUrl);
  let key = keys.find((k) => k.kid === kid);
  if (key) return key;
  // Possible key rotation — invalidate and try once more.
  jwksCache = { keys: null, fetchedAt: 0 };
  keys = await getJWKS(supabaseUrl);
  return keys.find((k) => k.kid === kid) ?? null;
}

function base64UrlToBytes(b64u: string): Uint8Array {
  const pad = "=".repeat((4 - (b64u.length % 4)) % 4);
  const b64 = (b64u + pad).replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function base64UrlToString(b64u: string): string {
  return new TextDecoder().decode(base64UrlToBytes(b64u));
}

export interface VerifiedJwt {
  sub: string;
  email: string | null;
}

/**
 * Verify a Supabase ES256 JWT. Returns the caller's user_id (sub) and email
 * on success; throws on any failure (bad sig, wrong issuer, expired, etc.).
 * Callers should treat any thrown error as a 401 — never surface the reason
 * to the client.
 */
export async function verifyJwt(token: string, supabaseUrl: string, expectedIssuer: string): Promise<VerifiedJwt> {
  if (!token || typeof token !== "string") throw new Error("No token");
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("Malformed JWT");
  const [headerB64, payloadB64, sigB64] = parts;

  const header = JSON.parse(base64UrlToString(headerB64));
  if (header.alg !== "ES256") throw new Error(`Unexpected alg: ${header.alg}`);
  if (!header.kid) throw new Error("Missing kid");

  const jwk = await findKeyByKid(header.kid, supabaseUrl);
  if (!jwk) throw new Error("No matching kid in JWKS");

  const cryptoKey = await crypto.subtle.importKey(
    "jwk",
    jwk as JsonWebKey,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  const sig = base64UrlToBytes(sigB64);
  const data = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    cryptoKey,
    sig,
    data,
  );
  if (!ok) throw new Error("Signature invalid");

  const payload = JSON.parse(base64UrlToString(payloadB64));
  const now = Math.floor(Date.now() / 1000);
  if (typeof payload.exp !== "number" || payload.exp < now) throw new Error("Token expired");
  if (expectedIssuer && payload.iss !== expectedIssuer) throw new Error("Bad issuer");
  // Tokens with no `aud` claim must fail — `aud && ...` would have permitted
  // a valid-sig forgery missing the claim entirely.
  if (payload.aud !== "authenticated") throw new Error("Bad audience");
  if (typeof payload.sub !== "string" || payload.sub.length === 0) throw new Error("Missing sub");

  return {
    sub: payload.sub,
    email: typeof payload.email === "string" ? payload.email : null,
  };
}
