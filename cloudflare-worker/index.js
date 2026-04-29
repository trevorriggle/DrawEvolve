// DrawEvolve feedback Worker.
//
// Prompt construction is intentionally externalized from the request handler.
// To iterate on prompts, edit the constants and presets below — do NOT inline
// prompt strings into fetch().
//
// PromptConfig shape:
//   {
//     systemPrompt: string,        // base "you are an art critic" prompt; static across requests
//     includeHistoryCount: number, // how many prior critiques on this drawing to include (0 = none)
//     historyFraming: string,      // wrapper text introducing past critiques to the model
//     styleModifier: string | null,// optional appended instruction (Pro tier override)
//     maxOutputTokens: number      // OpenAI max_tokens for the response
//   }
//
// Tier flow:
//   1. validateJWT(token, env) -> verified payload (Phase 5a — ES256 / JWKS)
//   2. getUserTier(payload) -> { tier, promptPreferences } from app_metadata
//   3. selectConfig(tier, promptPreferences) -> PromptConfig (preset + per-user overrides for Pro)
//   4. fetchCritiqueHistory(drawingId, env) -> [{ feedback, timestamp, ... }] from drawings.critique_history
//   5. buildSystemPrompt(config, context) + buildUserMessage(config, history) -> messages
//   6. POST to OpenAI; return feedback.
//
// Phases 5c–5e (rate limiting, server-side feedback persistence, request
// logging) are not yet implemented. Until 5c lands, abuse mitigation is just
// the per-user auth + ownership check below — no quota enforcement.

const BASE_SYSTEM_PROMPT = `You are a seasoned drawing coach inside the DrawEvolve app. You have 15 years of studio teaching experience, you've seen thousands of student portfolios, and you give feedback the way a sharp, honest mentor would over someone's shoulder — specific to what you see, never generic.

CORE RULES:
- You are analyzing a real student drawing sent as an image. EVERY observation must reference specific visual evidence in THIS drawing. Never produce generic art advice.
- Be honest and constructive. Praise only what genuinely works, and be direct about what doesn't. Critique the work, never the person.
- Focus on the ONE most impactful improvement — not a laundry list. Depth over breadth.
- End with one natural, friendly joke or witty aside related to the drawing or the artistic process. Keep it warm and brief — never punch down at the student.`;

const RESPONSE_FORMAT_TEMPLATE = (skillLevel) => `RESPONSE FORMAT — follow this structure exactly:

**Quick Take**
1-2 sentences. Your honest gut reaction to the drawing as a whole. Be real — what stands out immediately, good or bad?

**What's Working**
1-2 specific strengths you observe in the actual drawing. Reference concrete visual evidence (e.g., "the line weight variation in the hair" not "nice work"). Skip this section entirely if nothing genuinely succeeds yet — don't manufacture praise.

**Focus Area: [Name the specific issue]**
The single most impactful thing to improve. Describe what you see, explain why it matters, and ${skillLevel === 'Beginner' ? 'give a clear, step-by-step suggestion for what to try.' : skillLevel === 'Advanced' ? 'pose a question or observation that helps them see it differently.' : 'provide a concrete technique or exercise to address it.'}

**Try This**
1-2 specific, actionable next steps the student can do immediately. Be concrete enough that they know exactly what to attempt.

**💬**
One brief, friendly joke or aside related to the drawing, subject, or artistic process. Keep it natural.

IMPORTANT: Stay within ~700 words. Be dense and specific, not padded. Every sentence should earn its place.`;

const HISTORY_FRAMING_DEFAULT = `Here is your prior feedback on this drawing, oldest first. Evaluate whether the student has acted on it. If they have, acknowledge that progress directly. If they haven't, gently bring the unresolved point back into focus rather than introducing a brand-new issue:`;

const DEFAULT_FREE_CONFIG = {
  systemPrompt: BASE_SYSTEM_PROMPT,
  includeHistoryCount: 2,
  historyFraming: HISTORY_FRAMING_DEFAULT,
  styleModifier: null,
  maxOutputTokens: 1000,
};

const DEFAULT_PRO_CONFIG = {
  systemPrompt: BASE_SYSTEM_PROMPT,
  includeHistoryCount: 5,
  historyFraming: HISTORY_FRAMING_DEFAULT,
  styleModifier: null, // populated at request time from app_metadata.prompt_preferences.styleModifier
  maxOutputTokens: 1500,
};

function selectConfig(tier, promptPreferences) {
  if (tier === 'pro') {
    return {
      ...DEFAULT_PRO_CONFIG,
      styleModifier: promptPreferences?.styleModifier ?? null,
    };
  }
  return { ...DEFAULT_FREE_CONFIG };
}

function renderSkillCalibration(skillLevel) {
  if (skillLevel === 'Beginner') {
    return `This student is a BEGINNER.
- Use plain, accessible language. Define any art term you introduce.
- Be more prescriptive: tell them exactly what to try ("make the shadow side darker") rather than asking open questions.
- Limit feedback to one concept. Encouragement matters — highlight genuine effort and visible progress.
- Frame mistakes as normal and expected. Never compare to professional standards.
- Keep your tone warm and patient, like a first day in a supportive studio class.`;
  }
  if (skillLevel === 'Intermediate') {
    return `This student is INTERMEDIATE.
- Use art vocabulary freely (value, composition, gesture, negative space, etc.) without over-explaining.
- Balance observation with targeted diagnosis: name the specific issue and explain why it matters.
- Challenge them to leave comfort zones — suggest unfamiliar angles, techniques, or subjects.
- They can see problems before they can fix them. Offer concrete techniques, not just identification.
- If their work shows consistent competence in an area, push them toward the next challenge.`;
  }
  if (skillLevel === 'Advanced') {
    return `This student is ADVANCED.
- Treat them as a peer. Use nuanced language — edge quality, value key, temperature shifts, mark economy.
- Ask questions more than give answers: "What were you going for with this edge treatment?"
- Focus on style development, conceptual choices, and subtlety — not fundamentals.
- Reference relevant artists or traditions when it adds insight (not to show off).
- Be more descriptive than prescriptive. Trust their ability to problem-solve once they see the issue.`;
  }
  return '';
}

function renderContextBlock(context) {
  const subject = context.subject || 'not specified';
  const lines = [`- Subject: ${subject}`];
  if (context.style) lines.push(`- Style: ${context.style}`);
  if (context.artists) lines.push(`- Reference artists: ${context.artists}`);
  if (context.techniques) lines.push(`- Techniques: ${context.techniques}`);
  if (context.focus) lines.push(`- Student wants feedback on: ${context.focus}`);
  if (context.additionalContext) lines.push(`- Additional context: ${context.additionalContext}`);
  return lines.join('\n');
}

function buildSystemPrompt(config, context) {
  const skillLevel = context.skillLevel || 'Beginner';
  const sections = [
    config.systemPrompt,
    `SKILL LEVEL CALIBRATION:\n${renderSkillCalibration(skillLevel)}`,
    `CONTEXT (use what's provided, ignore empty fields):\n${renderContextBlock(context)}`,
    RESPONSE_FORMAT_TEMPLATE(skillLevel),
  ];
  if (config.styleModifier) {
    sections.push(`ADDITIONAL STYLE GUIDANCE (per user preference):\n${config.styleModifier}`);
  }
  return sections.join('\n\n');
}

function formatHistoryEntries(entries) {
  return entries
    .map((entry, i) => {
      const stamp = entry.timestamp ?? entry.created_at ?? '';
      const text = entry.feedback ?? entry.text ?? '';
      return `[Critique ${i + 1}${stamp ? ` — ${stamp}` : ''}]\n${text}`;
    })
    .join('\n\n');
}

function buildUserMessage(config, history, base64Image) {
  const slice = Array.isArray(history)
    ? history.slice(-config.includeHistoryCount)
    : [];
  const parts = [];
  if (config.includeHistoryCount > 0 && slice.length > 0) {
    parts.push({
      type: 'text',
      text: `${config.historyFraming}\n\n${formatHistoryEntries(slice)}\n\nNow critique the current state of the drawing below.`,
    });
  } else {
    parts.push({ type: 'text', text: 'Please critique this drawing.' });
  }
  if (base64Image) {
    parts.push({ type: 'image_url', image_url: { url: `data:image/jpeg;base64,${base64Image}` } });
  }
  return parts;
}

// =============================================================================
// Phase 5a — JWT validation (ES256 / JWKS)
// =============================================================================
//
// Supabase signs project JWTs with ES256 (ECDSA P-256). Public keys are
// published at <SUPABASE_URL>/auth/v1/.well-known/jwks.json. We fetch + cache
// them at module scope; cache survives across requests within a Worker isolate.
// On `kid` rotation (new signing key Supabase hasn't published before our cache
// expires) we invalidate-and-refetch once before giving up.

const JWKS_TTL_MS = 10 * 60 * 1000;   // 10 minutes per Phase 5a spec
let jwksCache = { keys: null, fetchedAt: 0 };

async function fetchJWKS(env) {
  if (!env.SUPABASE_URL) {
    throw new Error('SUPABASE_URL not configured');
  }
  const url = `${env.SUPABASE_URL}/auth/v1/.well-known/jwks.json`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`JWKS fetch failed: ${res.status}`);
  const body = await res.json();
  if (!Array.isArray(body.keys)) throw new Error('JWKS response missing keys array');
  jwksCache = { keys: body.keys, fetchedAt: Date.now() };
  return body.keys;
}

async function getJWKS(env) {
  const fresh = jwksCache.keys && (Date.now() - jwksCache.fetchedAt) < JWKS_TTL_MS;
  return fresh ? jwksCache.keys : fetchJWKS(env);
}

async function findKeyByKid(kid, env) {
  let keys = await getJWKS(env);
  let key = keys.find((k) => k.kid === kid);
  if (key) return key;
  // Possible key rotation — invalidate cache and try one more time.
  jwksCache = { keys: null, fetchedAt: 0 };
  keys = await getJWKS(env);
  return keys.find((k) => k.kid === kid) ?? null;
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
 */
async function validateJWT(token, env) {
  if (!token || typeof token !== 'string') throw new Error('No token');
  const parts = token.split('.');
  if (parts.length !== 3) throw new Error('Malformed JWT');
  const [headerB64, payloadB64, sigB64] = parts;

  const header = JSON.parse(base64UrlToString(headerB64));
  if (header.alg !== 'ES256') throw new Error(`Unexpected alg: ${header.alg}`);
  if (!header.kid) throw new Error('Missing kid');

  const jwk = await findKeyByKid(header.kid, env);
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
  const now = Math.floor(Date.now() / 1000);
  if (typeof payload.exp !== 'number' || payload.exp < now) throw new Error('Token expired');
  if (env.SUPABASE_JWT_ISSUER && payload.iss !== env.SUPABASE_JWT_ISSUER) {
    throw new Error('Bad issuer');
  }
  if (payload.aud && payload.aud !== 'authenticated') {
    throw new Error('Bad audience');
  }
  if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
    throw new Error('Missing sub');
  }
  return payload;
}

// =============================================================================
// Phase 5b — request validation
// =============================================================================

const MAX_IMAGE_BASE64_BYTES = 8 * 1024 * 1024; // 8 MB of base64 chars (~6 MB binary)

/**
 * Returns 'jpeg' | 'png' | false. Validates payload size + magic bytes; does
 * not fully validate the image (we trust GPT-4o Vision to handle malformed
 * pixels without burning tokens — we just block obvious junk + oversized junk).
 */
function validateImagePayload(base64) {
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
];

function validateContext(context) {
  if (!context || typeof context !== 'object' || Array.isArray(context)) return false;
  for (const key of CONTEXT_STRING_FIELDS) {
    if (key in context && typeof context[key] !== 'string') return false;
  }
  return true;
}

/**
 * Returns true iff a row exists in `drawings` with the given id AND user_id.
 * Uses the service_role key so RLS is bypassed — we're enforcing scope
 * ourselves via the WHERE clause, which is what we want for ownership checks
 * (we already know the user from a validated JWT).
 */
async function verifyDrawingOwnership(userId, drawingId, env) {
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

// =============================================================================
// Tier + history (replaces the Phase 1 stubs)
// =============================================================================

/**
 * Reads tier + Pro overrides from a validated JWT payload's app_metadata.
 * Default: free tier with no styleModifier. Synchronous because everything
 * comes from the JWT we already have in hand.
 */
function getUserTier(payload) {
  const tier = payload?.app_metadata?.tier === 'pro' ? 'pro' : 'free';
  const promptPreferences = payload?.app_metadata?.prompt_preferences ?? null;
  return { tier, promptPreferences };
}

/**
 * Pulls the critique_history jsonb array for the given drawing id. Used so the
 * iterative-coaching prompt has prior critiques to reference. Returns [] on
 * any failure — feedback will still generate, just without history context.
 */
async function fetchCritiqueHistory(drawingId, env) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) return [];
  const url = `${env.SUPABASE_URL}/rest/v1/drawings`
    + `?id=eq.${encodeURIComponent(drawingId)}`
    + `&select=critique_history&limit=1`;
  const res = await fetch(url, {
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      Accept: 'application/json',
    },
  });
  if (!res.ok) return [];
  const rows = await res.json();
  const history = rows?.[0]?.critique_history;
  return Array.isArray(history) ? history : [];
}

// =============================================================================
// Phase 5c — rate limiting + cost ceilings
// =============================================================================
//
// Three KV-backed gates run in front of the OpenAI call, plus one anomaly
// counter that runs behind it:
//
//   quota:<user_id>:<utc-day>       daily counter, 48h TTL  → tier.perDay
//   rate:<user_id>                  rolling window of timestamps, 120s TTL → tier.perMinute
//   ip:<sha256(ip)>:<utc-hour>      per-IP counter, 1h TTL  → IP_HOURLY_CAP
//   hourly:<user_id>:<utc-hour>     anomaly counter, 2h TTL → 5× tier.perDay fires alert
//
// Daily quota counts *delivered* critiques (incremented after OpenAI success).
// Per-minute + per-IP record the *attempt* before OpenAI so concurrent bursts
// can't slip past the gate while OpenAI is still responding.

const TIER_LIMITS = {
  free: { perMinute: 5,  perDay: 20  },
  pro:  { perMinute: 15, perDay: 200 },
};
const IP_HOURLY_CAP = 100;
const ANOMALY_MULTIPLIER = 5;

function utcDayKey(now) {
  const d = new Date(now);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, '0');
  const day = String(d.getUTCDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

function utcHourKey(now) {
  const d = new Date(now);
  const h = String(d.getUTCHours()).padStart(2, '0');
  return `${utcDayKey(now)}T${h}`;
}

function secondsUntilNextUtcMidnight(now) {
  const d = new Date(now);
  const next = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1);
  return Math.max(1, Math.ceil((next - now) / 1000));
}

function formatDuration(seconds) {
  if (seconds < 60) return `${seconds}s`;
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (h > 0 && m > 0) return `${h}h ${m}m`;
  if (h > 0) return `${h}h`;
  return `${m}m`;
}

async function sha256Hex(input) {
  const buf = new TextEncoder().encode(input);
  const hash = await crypto.subtle.digest('SHA-256', buf);
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function dailyMessage(tier, limit, retryAfterSeconds) {
  const reset = formatDuration(retryAfterSeconds);
  if (tier === 'pro') {
    return `You've reached the Pro tier limit of ${limit} critiques today. Your quota resets at midnight UTC (in ${reset}).`;
  }
  const proLimit = TIER_LIMITS.pro.perDay;
  return `You've reached the free tier limit of ${limit} critiques today. Your quota resets at midnight UTC (in ${reset}). Upgrade to Pro for ${proLimit} critiques per day.`;
}

function perMinuteMessage(retryAfterSeconds) {
  return `Slow down a moment — you're sending requests too quickly. Try again in ${formatDuration(retryAfterSeconds)}.`;
}

function ipMessage() {
  return 'Too many requests from your network. Please try again in about an hour.';
}

/**
 * Reads the three rate-limit counters and either rejects with a 429 decision
 * or records the attempt (per-minute + per-IP) and returns a ctx for the
 * post-OpenAI daily increment. KV is eventually consistent — under high
 * concurrency a small overshoot is possible; that's acceptable for a soft
 * rate limit and the per-IP backstop bounds the worst case.
 */
async function enforceRateLimits({ env, userId, ip, tier, now }) {
  const limits = TIER_LIMITS[tier] ?? TIER_LIMITS.free;
  const dayKey = utcDayKey(now);
  const hourKey = utcHourKey(now);
  const ipHash = await sha256Hex(ip || 'unknown');

  const dailyKey   = `quota:${userId}:${dayKey}`;
  const minuteKey  = `rate:${userId}`;
  const ipKey      = `ip:${ipHash}:${hourKey}`;

  const [dailyRaw, minuteRaw, ipRaw] = await Promise.all([
    env.QUOTA_KV.get(dailyKey),
    env.QUOTA_KV.get(minuteKey),
    env.QUOTA_KV.get(ipKey),
  ]);

  const dailyCount = parseInt(dailyRaw ?? '0', 10) || 0;
  if (dailyCount >= limits.perDay) {
    const retryAfter = secondsUntilNextUtcMidnight(now);
    return {
      ok: false,
      status: 429,
      body: {
        error: 'quota_exceeded',
        scope: 'daily',
        tier,
        limit: limits.perDay,
        used: dailyCount,
        retryAfter,
        message: dailyMessage(tier, limits.perDay, retryAfter),
      },
    };
  }

  let recent = [];
  if (minuteRaw) {
    try {
      const parsed = JSON.parse(minuteRaw);
      if (Array.isArray(parsed)) {
        recent = parsed.filter((t) => typeof t === 'number' && now - t < 60_000);
      }
    } catch {
      recent = [];
    }
  }
  if (recent.length >= limits.perMinute) {
    const oldest = Math.min(...recent);
    const retryAfter = Math.max(1, Math.ceil((60_000 - (now - oldest)) / 1000));
    return {
      ok: false,
      status: 429,
      body: {
        error: 'rate_limited',
        scope: 'minute',
        tier,
        limit: limits.perMinute,
        used: recent.length,
        retryAfter,
        message: perMinuteMessage(retryAfter),
      },
    };
  }

  const ipCount = parseInt(ipRaw ?? '0', 10) || 0;
  if (ipCount >= IP_HOURLY_CAP) {
    return {
      ok: false,
      status: 429,
      body: {
        error: 'ip_rate_limited',
        scope: 'ip',
        limit: IP_HOURLY_CAP,
        used: ipCount,
        retryAfter: 3600,
        message: ipMessage(),
      },
    };
  }

  // All gates passed — record the attempt against per-minute + per-IP now so
  // concurrent requests in flight see the bump. Daily is incremented later,
  // only on OpenAI success.
  await Promise.all([
    env.QUOTA_KV.put(minuteKey, JSON.stringify([...recent, now]), { expirationTtl: 120 }),
    env.QUOTA_KV.put(ipKey, String(ipCount + 1), { expirationTtl: 3600 }),
  ]);

  return { ok: true, ctx: { dailyKey, dailyCount, tier, userId, hourKey, limits } };
}

/**
 * Increments the daily quota counter and the hourly anomaly counter. Called
 * AFTER a successful OpenAI response — failed requests don't burn quota. If
 * the hourly counter crosses 5× the daily quota on this request (and only on
 * the transition, not on subsequent requests in the same window) fires the
 * webhook or falls back to console.error.
 */
async function recordSuccessfulCritique({ env, ctx, now }) {
  const { dailyKey, dailyCount, tier, userId, hourKey, limits } = ctx;
  const newDaily = dailyCount + 1;

  const anomalyKey = `hourly:${userId}:${hourKey}`;
  const prevHourlyRaw = await env.QUOTA_KV.get(anomalyKey);
  const prevHourly = parseInt(prevHourlyRaw ?? '0', 10) || 0;
  const newHourly = prevHourly + 1;

  await Promise.all([
    env.QUOTA_KV.put(dailyKey, String(newDaily), { expirationTtl: 48 * 3600 }),
    env.QUOTA_KV.put(anomalyKey, String(newHourly), { expirationTtl: 2 * 3600 }),
  ]);

  const threshold = limits.perDay * ANOMALY_MULTIPLIER;
  if (prevHourly < threshold && newHourly >= threshold) {
    const payload = {
      user_id: userId,
      tier,
      count: newHourly,
      limit: limits.perDay,
      window: hourKey,
      timestamp: new Date(now).toISOString(),
    };
    if (env.ANOMALY_ALERT_WEBHOOK) {
      try {
        await fetch(env.ANOMALY_ALERT_WEBHOOK, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload),
        });
      } catch (err) {
        console.error('[anomaly] webhook fetch failed', err?.message);
      }
    } else {
      console.error('[anomaly] threshold crossed (no webhook configured)', payload);
    }
  }
}

// =============================================================================
// Phase 5d — server-side persistence + idempotency
// =============================================================================
//
// After OpenAI returns a critique, the Worker (not the client) appends the
// entry to drawings.critique_history via a security-definer Postgres function
// `append_critique(uuid, jsonb)`. The function does an atomic
// `critique_history || jsonb_build_array($entry)` so concurrent writes
// linearize without a SELECT-then-UPDATE race.
//
// Idempotency: every request carries a client-generated UUID
// `client_request_id`. The first response is cached at
// `idempotency:<user_id>:<client_request_id>` for 1h. Replays return the same
// body verbatim with `X-Idempotent-Replay: 1`, do not call OpenAI, do not
// write to Postgres, do not increment quota.
//
// Failure modes:
//   - OpenAI fails → 502, no quota burn, no Postgres write, no cache.
//   - Postgres write fails after OpenAI succeeded → user still gets the
//     critique (graceful degradation), orphan logged via console.error,
//     quota IS counted (the OpenAI cost was real), idempotency cache IS
//     written (so the same request_id won't double-spend).

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function isValidClientRequestId(s) {
  return typeof s === 'string' && UUID_RE.test(s);
}

async function checkIdempotency({ env, userId, clientRequestId }) {
  const key = `idempotency:${userId}:${clientRequestId}`;
  const raw = await env.QUOTA_KV.get(key);
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

async function recordIdempotent({ env, userId, clientRequestId, body }) {
  const key = `idempotency:${userId}:${clientRequestId}`;
  await env.QUOTA_KV.put(key, JSON.stringify(body), { expirationTtl: 3600 });
}

function buildCritiqueEntry({ feedback, sequenceNumber, config, tier, usage, now }) {
  return {
    sequence_number: sequenceNumber,
    content: feedback,
    prompt_config: {
      tier,
      includeHistoryCount: config.includeHistoryCount,
      styleModifier: config.styleModifier ?? null,
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
async function persistCritique({ env, drawingId, entry, fetcher = fetch }) {
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
// HTTP scaffolding
// =============================================================================

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

function jsonResponse(body, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS, ...extraHeaders },
  });
}

function unauthorized() {
  // No body — don't leak which routes exist or why the JWT was rejected.
  return new Response(null, { status: 401, headers: CORS_HEADERS });
}

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: CORS_HEADERS });
    }
    if (request.method !== 'POST') {
      return jsonResponse({ error: 'Method not allowed' }, 405);
    }

    // Phase 5a — auth gate. Anything other than a valid Supabase JWT → 401.
    const token = request.headers.get('Authorization')?.replace(/^Bearer\s+/i, '') ?? null;
    let payload;
    try {
      payload = await validateJWT(token, env);
    } catch (err) {
      console.log('[fetch] JWT validation failed', err?.message);
      return unauthorized();
    }
    const userId = payload.sub; // Supabase auth.uid() is always lowercase.

    try {
      const body = await request.json().catch(() => null);
      if (!body || typeof body !== 'object') {
        return jsonResponse({ error: 'Invalid request body' }, 400);
      }

      const { image, context, drawingId, client_request_id: clientRequestIdRaw } = body;

      // Phase 5b — request validation. Cheap checks first; ownership query last.
      if (typeof drawingId !== 'string' || drawingId.length === 0) {
        return jsonResponse({ error: 'Missing drawing_id' }, 400);
      }
      const drawingIdLower = drawingId.toLowerCase(); // pattern compliance from Phase 3

      // Phase 5d — idempotency gate. Validates the request id format and short-
      // circuits replays before image validation / rate limits / OpenAI. A
      // cached hit returns the original response verbatim and never burns
      // quota again.
      if (typeof clientRequestIdRaw !== 'string') {
        return jsonResponse({ error: 'Missing client_request_id' }, 400);
      }
      const clientRequestId = clientRequestIdRaw.toLowerCase();
      if (!isValidClientRequestId(clientRequestId)) {
        return jsonResponse({ error: 'Invalid client_request_id' }, 400);
      }
      const cached = await checkIdempotency({ env, userId, clientRequestId });
      if (cached) {
        return jsonResponse(cached, 200, { 'X-Idempotent-Replay': '1' });
      }

      if (!validateImagePayload(image)) {
        return jsonResponse({ error: 'Invalid or oversized image payload' }, 400);
      }
      if (!validateContext(context)) {
        return jsonResponse({ error: 'Invalid context' }, 400);
      }

      const { tier, promptPreferences } = getUserTier(payload);

      // Phase 5c — rate limits. Run before the ownership query so we don't
      // burn a Postgres call on a request we're about to 429 anyway.
      const ip = request.headers.get('CF-Connecting-IP') ?? '';
      const now = Date.now();
      const decision = await enforceRateLimits({ env, userId, ip, tier, now });
      if (!decision.ok) {
        return jsonResponse(decision.body, decision.status, {
          'Retry-After': String(decision.body.retryAfter),
        });
      }

      const owns = await verifyDrawingOwnership(userId, drawingIdLower, env);
      if (!owns) {
        return jsonResponse({ error: 'Forbidden' }, 403);
      }

      const config = selectConfig(tier, promptPreferences);
      const history = await fetchCritiqueHistory(drawingIdLower, env);

      const systemPrompt = buildSystemPrompt(config, context ?? {});
      const userContent = buildUserMessage(config, history, image);

      const response = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${env.OPENAI_API_KEY}`,
        },
        body: JSON.stringify({
          model: 'gpt-4o',
          messages: [
            { role: 'system', content: systemPrompt },
            { role: 'user', content: userContent },
          ],
          max_tokens: config.maxOutputTokens,
        }),
      });

      if (!response.ok) {
        console.error('[openai] non-ok status', response.status);
        return jsonResponse({ error: 'Upstream model error' }, 502);
      }

      const data = await response.json();
      const feedback = data.choices?.[0]?.message?.content;
      if (!feedback) {
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
      });
      try {
        await persistCritique({ env, drawingId: drawingIdLower, entry });
      } catch (err) {
        console.error('[persistence] orphan critique', {
          drawingId: drawingIdLower,
          userId,
          error: err?.message,
        });
      }

      // Quota burns only on a delivered critique. Anomaly counter rides along.
      // Don't await — the response shouldn't wait on bookkeeping, and any
      // failure here is logged but doesn't affect the user.
      recordSuccessfulCritique({ env, ctx: decision.ctx, now }).catch((err) =>
        console.error('[quota] recordSuccessfulCritique failed', err?.message),
      );

      // Phase 5d — idempotency cache. Stores the body we're about to return so
      // a retry of the same client_request_id within 1h gets the exact same
      // response without re-charging OpenAI.
      const responseBody = { feedback, critique_entry: entry };
      recordIdempotent({ env, userId, clientRequestId, body: responseBody }).catch((err) =>
        console.error('[idempotency] recordIdempotent failed', err?.message),
      );

      return jsonResponse(responseBody);
    } catch (error) {
      return jsonResponse({ error: 'Internal server error', details: error.message }, 500);
    }
  },
};

// Named exports for unit tests (see test.mjs).
export {
  BASE_SYSTEM_PROMPT,
  HISTORY_FRAMING_DEFAULT,
  DEFAULT_FREE_CONFIG,
  DEFAULT_PRO_CONFIG,
  selectConfig,
  buildSystemPrompt,
  buildUserMessage,
  formatHistoryEntries,
  renderSkillCalibration,
  renderContextBlock,
  validateImagePayload,
  validateContext,
  getUserTier,
  TIER_LIMITS,
  IP_HOURLY_CAP,
  ANOMALY_MULTIPLIER,
  utcDayKey,
  utcHourKey,
  secondsUntilNextUtcMidnight,
  sha256Hex,
  enforceRateLimits,
  recordSuccessfulCritique,
  isValidClientRequestId,
  checkIdempotency,
  recordIdempotent,
  buildCritiqueEntry,
  persistCritique,
};
