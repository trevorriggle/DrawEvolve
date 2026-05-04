// Phase 5d — request idempotency cache.
//
// Every request carries a client-generated UUID `client_request_id`. The
// first response is cached at `idempotency:<user_id>:<client_request_id>`
// for 1h. Replays return the same body verbatim with `X-Idempotent-Replay: 1`,
// do not call OpenAI, do not write to Postgres, do not increment quota.

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function isValidClientRequestId(s) {
  return typeof s === 'string' && UUID_RE.test(s);
}

export async function checkIdempotency({ env, userId, clientRequestId }) {
  const key = `idempotency:${userId}:${clientRequestId}`;
  const raw = await env.QUOTA_KV.get(key);
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

export async function recordIdempotent({ env, userId, clientRequestId, body }) {
  const key = `idempotency:${userId}:${clientRequestId}`;
  await env.QUOTA_KV.put(key, JSON.stringify(body), { expirationTtl: 3600 });
}
