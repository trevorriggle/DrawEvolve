import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import {
  DEFAULT_FREE_CONFIG,
  DEFAULT_PRO_CONFIG,
  HISTORY_FRAMING_DEFAULT,
  selectConfig,
  buildSystemPrompt,
  buildUserMessage,
  validateImagePayload,
  validateContext,
  getUserTier,
  TIER_LIMITS,
  IP_HOURLY_CAP,
  ANOMALY_MULTIPLIER,
  utcDayKey,
  enforceRateLimits,
  recordSuccessfulCritique,
  isValidClientRequestId,
  checkIdempotency,
  recordIdempotent,
  buildCritiqueEntry,
  persistCritique,
} from './index.js';

const baseContext = {
  skillLevel: 'Intermediate',
  subject: 'a portrait',
  style: '',
  artists: '',
  techniques: '',
  focus: '',
  additionalContext: '',
};

// Helper: build a base64 payload that starts with the given magic bytes,
// padded out so atob() of the first slice has at least 4 bytes to inspect.
function base64WithMagic(magicBytes, padBytes = 32) {
  const buf = Buffer.from([...magicBytes, ...new Array(padBytes).fill(0)]);
  return buf.toString('base64');
}

// =============================================================================
// Existing prompt-pipeline tests (unchanged from Phase 1)
// =============================================================================

test('free tier with no history produces a user message with no history block', () => {
  const config = selectConfig('free', null);
  const userContent = buildUserMessage(config, [], 'BASE64IMG');

  // Two parts: text + image. Text must NOT contain the history framing.
  assert.equal(userContent.length, 2);
  assert.equal(userContent[0].type, 'text');
  assert.equal(userContent[0].text, 'Please critique this drawing.');
  assert.ok(!userContent[0].text.includes(HISTORY_FRAMING_DEFAULT));
  assert.equal(userContent[1].type, 'image_url');
});

test('free tier with history but includeHistoryCount=0 still skips history (sanity)', () => {
  const config = { ...DEFAULT_FREE_CONFIG, includeHistoryCount: 0 };
  const userContent = buildUserMessage(
    config,
    [{ feedback: 'old', timestamp: '2026-04-01' }],
    'IMG',
  );
  assert.equal(userContent[0].text, 'Please critique this drawing.');
});

test('pro tier with 3 prior critiques and styleModifier injects all three and appends the modifier', () => {
  const promptPreferences = { styleModifier: 'Focus extra hard on anatomy.' };
  const config = selectConfig('pro', promptPreferences);

  // Sanity: pro preset is in use.
  assert.equal(config.includeHistoryCount, DEFAULT_PRO_CONFIG.includeHistoryCount);
  assert.equal(config.maxOutputTokens, DEFAULT_PRO_CONFIG.maxOutputTokens);
  assert.equal(config.styleModifier, 'Focus extra hard on anatomy.');

  const history = [
    { feedback: 'First critique: tighten the jawline.', timestamp: '2026-04-01' },
    { feedback: 'Second critique: values are flat.',    timestamp: '2026-04-10' },
    { feedback: 'Third critique: edges read mushy.',    timestamp: '2026-04-20' },
  ];

  const userContent = buildUserMessage(config, history, 'IMG');
  const userText = userContent[0].text;
  assert.ok(userText.includes(HISTORY_FRAMING_DEFAULT), 'history framing should be present');
  assert.ok(userText.includes('tighten the jawline'),   'first critique should be injected');
  assert.ok(userText.includes('values are flat'),       'second critique should be injected');
  assert.ok(userText.includes('edges read mushy'),      'third critique should be injected');

  const systemPrompt = buildSystemPrompt(config, baseContext);
  assert.ok(
    systemPrompt.includes('Focus extra hard on anatomy.'),
    'styleModifier should be appended to system prompt',
  );
  assert.ok(
    systemPrompt.includes('ADDITIONAL STYLE GUIDANCE'),
    'styleModifier should be wrapped in the labeled section',
  );
});

test('pro tier respects includeHistoryCount cap when more history exists', () => {
  const config = selectConfig('pro', null);
  const tooMuchHistory = Array.from({ length: 10 }, (_, i) => ({
    feedback: `Critique number ${i + 1}.`,
    timestamp: `2026-03-${String(i + 1).padStart(2, '0')}`,
  }));
  const userContent = buildUserMessage(config, tooMuchHistory, 'IMG');
  const userText = userContent[0].text;

  // Should include the LAST 5 (per DEFAULT_PRO_CONFIG.includeHistoryCount), not earlier ones.
  for (let i = 6; i <= 10; i++) {
    assert.ok(userText.includes(`Critique number ${i}.`), `critique ${i} should be present`);
  }
  for (let i = 1; i <= 5; i++) {
    assert.ok(!userText.includes(`Critique number ${i}.`), `critique ${i} should be dropped`);
  }
});

test('tier override from app_metadata correctly overrides the preset', () => {
  // Same prompt preferences object, different tier values → different configs.
  const prefs = { styleModifier: 'Be encouraging.' };

  const freeConfig = selectConfig('free', prefs);
  const proConfig  = selectConfig('pro',  prefs);

  // Free preset MUST NOT pick up styleModifier (only Pro merges it).
  assert.equal(freeConfig.styleModifier, null);
  assert.equal(freeConfig.includeHistoryCount, DEFAULT_FREE_CONFIG.includeHistoryCount);
  assert.equal(freeConfig.maxOutputTokens,     DEFAULT_FREE_CONFIG.maxOutputTokens);

  // Pro preset DOES pick up styleModifier.
  assert.equal(proConfig.styleModifier, 'Be encouraging.');
  assert.equal(proConfig.includeHistoryCount, DEFAULT_PRO_CONFIG.includeHistoryCount);
  assert.equal(proConfig.maxOutputTokens,     DEFAULT_PRO_CONFIG.maxOutputTokens);

  // Unknown tier value falls back to free (default behavior).
  const unknownTier = selectConfig('enterprise', prefs);
  assert.deepEqual(unknownTier, { ...DEFAULT_FREE_CONFIG });

  // Reflected in the actual built system prompt: free has no style guidance section.
  const freeSystem = buildSystemPrompt(freeConfig, baseContext);
  const proSystem  = buildSystemPrompt(proConfig,  baseContext);
  assert.ok(!freeSystem.includes('ADDITIONAL STYLE GUIDANCE'));
  assert.ok( proSystem.includes('ADDITIONAL STYLE GUIDANCE'));
  assert.ok( proSystem.includes('Be encouraging.'));
});

test('mutating returned config does not pollute presets', () => {
  // selectConfig must return a fresh object so Pro overrides on one request can't
  // leak into the next request's free-tier config.
  const a = selectConfig('free', null);
  a.maxOutputTokens = 99999;
  const b = selectConfig('free', null);
  assert.equal(b.maxOutputTokens, DEFAULT_FREE_CONFIG.maxOutputTokens);
});

// =============================================================================
// Phase 5b — validateImagePayload
// =============================================================================

test('validateImagePayload accepts a JPEG by magic bytes', () => {
  const jpegBase64 = base64WithMagic([0xff, 0xd8, 0xff, 0xe0]);
  assert.equal(validateImagePayload(jpegBase64), 'jpeg');
});

test('validateImagePayload accepts a PNG by magic bytes', () => {
  const pngBase64 = base64WithMagic([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  assert.equal(validateImagePayload(pngBase64), 'png');
});

test('validateImagePayload rejects arbitrary non-image bytes', () => {
  const garbageBase64 = base64WithMagic([0x00, 0x01, 0x02, 0x03, 0x04, 0x05]);
  assert.equal(validateImagePayload(garbageBase64), false);
});

test('validateImagePayload rejects oversized payloads (>8MB base64)', () => {
  // 9 MB of base64 chars — well over the 8 MB cap.
  const oversized = 'A'.repeat(9 * 1024 * 1024);
  assert.equal(validateImagePayload(oversized), false);
});

test('validateImagePayload rejects empty / non-string input', () => {
  assert.equal(validateImagePayload(''),         false);
  assert.equal(validateImagePayload(null),       false);
  assert.equal(validateImagePayload(undefined),  false);
  assert.equal(validateImagePayload(12345),      false);
  assert.equal(validateImagePayload({}),         false);
});

test('validateImagePayload rejects malformed base64', () => {
  // Characters outside the base64 alphabet → atob() throws.
  assert.equal(validateImagePayload('!!!!!!!!!!!!!!!'), false);
});

// =============================================================================
// Phase 5b — validateContext
// =============================================================================

test('validateContext accepts a fully-populated DrawingContext shape', () => {
  assert.equal(validateContext(baseContext), true);
});

test('validateContext accepts an empty object (all fields optional)', () => {
  assert.equal(validateContext({}), true);
});

test('validateContext accepts a partial object', () => {
  assert.equal(validateContext({ subject: 'a tree', skillLevel: 'Beginner' }), true);
});

test('validateContext rejects null / non-object / array', () => {
  assert.equal(validateContext(null),       false);
  assert.equal(validateContext(undefined),  false);
  assert.equal(validateContext('string'),   false);
  assert.equal(validateContext(42),         false);
  assert.equal(validateContext([]),         false); // arrays are typeof 'object' — must be rejected
});

test('validateContext rejects when a known field has a wrong type', () => {
  assert.equal(validateContext({ subject: 12345 }),          false);
  assert.equal(validateContext({ skillLevel: ['Beginner'] }),false);
  assert.equal(validateContext({ additionalContext: {} }),   false);
});

test('validateContext tolerates unknown keys (forward-compat)', () => {
  assert.equal(validateContext({ subject: 'x', futureField: 'y' }), true);
});

// =============================================================================
// Phase 5a — getUserTier (now reads from validated JWT payload, not a stub)
// =============================================================================

test('getUserTier defaults to free when payload has no app_metadata.tier', () => {
  assert.deepEqual(
    getUserTier({ sub: 'abc', app_metadata: {} }),
    { tier: 'free', promptPreferences: null },
  );
});

test('getUserTier defaults to free when payload is missing entirely', () => {
  assert.deepEqual(
    getUserTier(undefined),
    { tier: 'free', promptPreferences: null },
  );
});

test('getUserTier returns pro + promptPreferences when present', () => {
  const payload = {
    sub: 'abc',
    app_metadata: {
      tier: 'pro',
      prompt_preferences: { styleModifier: 'Be brutal.' },
    },
  };
  assert.deepEqual(getUserTier(payload), {
    tier: 'pro',
    promptPreferences: { styleModifier: 'Be brutal.' },
  });
});

test('getUserTier ignores unknown tier values and falls back to free', () => {
  const payload = { sub: 'abc', app_metadata: { tier: 'enterprise' } };
  assert.deepEqual(
    getUserTier(payload),
    { tier: 'free', promptPreferences: null },
  );
});

test('getUserTier flow into selectConfig respects pro promptPreferences', () => {
  // Integration sanity: payload → tier → config all line up.
  const payload = {
    sub: 'abc',
    app_metadata: {
      tier: 'pro',
      prompt_preferences: { styleModifier: 'Reference Sargent.' },
    },
  };
  const { tier, promptPreferences } = getUserTier(payload);
  const config = selectConfig(tier, promptPreferences);
  assert.equal(config.styleModifier, 'Reference Sargent.');
  assert.equal(config.includeHistoryCount, DEFAULT_PRO_CONFIG.includeHistoryCount);
});

// =============================================================================
// Phase 5c — rate limits + quotas
// =============================================================================
//
// FakeKV mirrors the relevant slice of the Workers KV API: get/put + an
// expirationTtl option interpreted against an injectable now (`setNow`) so
// the UTC-midnight reset test can fast-forward without touching real time.

class FakeKV {
  constructor() {
    this.store = new Map();
    this.now = 0;
  }
  setNow(now) { this.now = now; }
  async get(key) {
    const entry = this.store.get(key);
    if (!entry) return null;
    if (entry.expiresAt !== null && entry.expiresAt <= this.now) {
      this.store.delete(key);
      return null;
    }
    return entry.value;
  }
  async put(key, value, options = {}) {
    const expiresAt = options.expirationTtl
      ? this.now + options.expirationTtl * 1000
      : null;
    this.store.set(key, { value: String(value), expiresAt });
  }
}

function makeEnv(extra = {}) {
  const kv = new FakeKV();
  return { env: { QUOTA_KV: kv, ...extra }, kv };
}

const FREE_USER = '00000000-0000-0000-0000-000000000001';
const PRO_USER  = '00000000-0000-0000-0000-000000000002';
const FIXED_NOW = Date.UTC(2026, 3, 29, 12, 0, 0); // 2026-04-29T12:00:00Z

test('free tier 21st daily request returns 429 with correct shape and retryAfter', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  const dayKey = utcDayKey(FIXED_NOW);
  await kv.put(`quota:${FREE_USER}:${dayKey}`, '20', { expirationTtl: 48 * 3600 });

  const decision = await enforceRateLimits({
    env, userId: FREE_USER, ip: '203.0.113.1', tier: 'free', now: FIXED_NOW,
  });

  assert.equal(decision.ok, false);
  assert.equal(decision.status, 429);
  assert.equal(decision.body.error, 'quota_exceeded');
  assert.equal(decision.body.scope, 'daily');
  assert.equal(decision.body.tier, 'free');
  assert.equal(decision.body.limit, TIER_LIMITS.free.perDay);
  assert.equal(decision.body.used, 20);
  // Noon UTC → 12 hours until midnight = 43200s. Allow ±2s slack.
  assert.ok(Math.abs(decision.body.retryAfter - 12 * 3600) < 2);
  assert.match(decision.body.message, /free tier/i);
  assert.match(decision.body.message, /upgrade to pro/i);
});

test('pro tier 16th request in 60s returns 429 with minute scope', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  // 15 timestamps within the last 60s — at the perMinute cap for pro.
  const stamps = Array.from({ length: 15 }, (_, i) => FIXED_NOW - (1000 + i * 100));
  await kv.put(`rate:${PRO_USER}`, JSON.stringify(stamps), { expirationTtl: 120 });

  const decision = await enforceRateLimits({
    env, userId: PRO_USER, ip: '203.0.113.2', tier: 'pro', now: FIXED_NOW,
  });

  assert.equal(decision.ok, false);
  assert.equal(decision.status, 429);
  assert.equal(decision.body.error, 'rate_limited');
  assert.equal(decision.body.scope, 'minute');
  assert.equal(decision.body.tier, 'pro');
  assert.equal(decision.body.limit, TIER_LIMITS.pro.perMinute);
  assert.equal(decision.body.used, 15);
  assert.ok(decision.body.retryAfter >= 1 && decision.body.retryAfter <= 60);
  assert.match(decision.body.message, /slow down/i);
});

test('per-IP backstop blocks the 101st hourly request even with valid JWTs', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  // Pre-populate the IP counter at the cap. We don't know the hash up front,
  // so derive it from sha256Hex via the same import.
  const { sha256Hex, utcHourKey } = await import('./index.js');
  const ip = '198.51.100.99';
  const hash = await sha256Hex(ip);
  await kv.put(`ip:${hash}:${utcHourKey(FIXED_NOW)}`, String(IP_HOURLY_CAP), { expirationTtl: 3600 });

  const decision = await enforceRateLimits({
    env, userId: FREE_USER, ip, tier: 'free', now: FIXED_NOW,
  });

  assert.equal(decision.ok, false);
  assert.equal(decision.status, 429);
  assert.equal(decision.body.error, 'ip_rate_limited');
  assert.equal(decision.body.scope, 'ip');
  // IP message must NOT leak tier information.
  assert.ok(!/free|pro/i.test(decision.body.message));
  assert.match(decision.body.message, /network/i);
});

test('daily counter is keyed by UTC day — request at next-day 00:00:01Z lands on a fresh key', async () => {
  const { env, kv } = makeEnv();
  // 2026-04-29T23:59:59Z — fully consumed quota.
  const lateNight = Date.UTC(2026, 3, 29, 23, 59, 59);
  kv.setNow(lateNight);
  await kv.put(`quota:${FREE_USER}:${utcDayKey(lateNight)}`, '20', { expirationTtl: 48 * 3600 });

  // Verify same day still 429s.
  const blocked = await enforceRateLimits({
    env, userId: FREE_USER, ip: '203.0.113.5', tier: 'free', now: lateNight,
  });
  assert.equal(blocked.ok, false);
  assert.equal(blocked.body.scope, 'daily');

  // Roll over.
  const nextDay = Date.UTC(2026, 3, 30, 0, 0, 1);
  kv.setNow(nextDay);
  const fresh = await enforceRateLimits({
    env, userId: FREE_USER, ip: '203.0.113.5', tier: 'free', now: nextDay,
  });
  assert.equal(fresh.ok, true, 'next-UTC-day request should pass the daily gate');
  assert.notEqual(utcDayKey(lateNight), utcDayKey(nextDay));
});

test('anomaly alert fires exactly once on 5× daily quota threshold (no webhook → console.error)', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  const threshold = TIER_LIMITS.free.perDay * ANOMALY_MULTIPLIER;
  // Pre-populate the hourly counter at threshold-1 so the next success crosses.
  const { utcHourKey } = await import('./index.js');
  const hourKey = utcHourKey(FIXED_NOW);
  await kv.put(`hourly:${FREE_USER}:${hourKey}`, String(threshold - 1), { expirationTtl: 2 * 3600 });

  const ctx = {
    dailyKey: `quota:${FREE_USER}:${utcDayKey(FIXED_NOW)}`,
    dailyCount: 0,
    tier: 'free',
    userId: FREE_USER,
    hourKey,
    limits: TIER_LIMITS.free,
  };

  const calls = [];
  const originalError = console.error;
  console.error = (...args) => { calls.push(args); };
  try {
    // Crossing call — should log.
    await recordSuccessfulCritique({ env, ctx, now: FIXED_NOW });
    assert.equal(calls.length, 1, 'console.error should fire exactly once on threshold crossing');
    assert.match(String(calls[0][0]), /anomaly/i);

    // Subsequent call in same window — must NOT fire again.
    await recordSuccessfulCritique({ env, ctx: { ...ctx, dailyCount: 1 }, now: FIXED_NOW });
    assert.equal(calls.length, 1, 'console.error should not fire again after threshold');
  } finally {
    console.error = originalError;
  }
});

// =============================================================================
// Phase 5d — server-side persistence + idempotency
// =============================================================================

const TEST_REQUEST_ID = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const TEST_DRAWING_ID = '11111111-2222-3333-4444-555555555555';
const TEST_SUPABASE = {
  SUPABASE_URL: 'https://test.supabase.co',
  SUPABASE_SERVICE_ROLE_KEY: 'fake-service-role-key',
};

test('isValidClientRequestId accepts lowercase UUIDs only', () => {
  assert.equal(isValidClientRequestId(TEST_REQUEST_ID), true);
  // Uppercase rejected — project convention is lowercase everywhere.
  assert.equal(isValidClientRequestId(TEST_REQUEST_ID.toUpperCase()), false);
  // Missing hyphens.
  assert.equal(isValidClientRequestId(TEST_REQUEST_ID.replaceAll('-', '')), false);
  // Non-string.
  assert.equal(isValidClientRequestId(null), false);
  assert.equal(isValidClientRequestId(undefined), false);
  assert.equal(isValidClientRequestId(12345), false);
  // Wrong length.
  assert.equal(isValidClientRequestId('aaaaaaaa-bbbb-cccc-dddd-eee'), false);
});

test('persistCritique calls append_critique RPC with the canonical entry shape', async () => {
  const { env } = makeEnv(TEST_SUPABASE);
  const calls = [];
  const fetcher = async (url, init) => {
    calls.push({ url, init });
    return { ok: true, status: 200 };
  };

  const config = selectConfig('pro', { styleModifier: 'Reference Sargent.' });
  const entry = buildCritiqueEntry({
    feedback: 'Nice gesture in the shoulder line.',
    sequenceNumber: 3,
    config,
    tier: 'pro',
    usage: { prompt_tokens: 800, completion_tokens: 350 },
    now: FIXED_NOW,
  });

  await persistCritique({ env, drawingId: TEST_DRAWING_ID, entry, fetcher });

  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://test.supabase.co/rest/v1/rpc/append_critique');
  assert.equal(calls[0].init.method, 'POST');
  assert.equal(calls[0].init.headers.apikey, 'fake-service-role-key');
  assert.equal(calls[0].init.headers.Authorization, 'Bearer fake-service-role-key');

  const sentBody = JSON.parse(calls[0].init.body);
  assert.equal(sentBody.p_drawing_id, TEST_DRAWING_ID);
  assert.equal(sentBody.p_entry.sequence_number, 3);
  assert.equal(sentBody.p_entry.content, 'Nice gesture in the shoulder line.');
  assert.equal(sentBody.p_entry.prompt_config.tier, 'pro');
  assert.equal(sentBody.p_entry.prompt_config.includeHistoryCount, DEFAULT_PRO_CONFIG.includeHistoryCount);
  assert.equal(sentBody.p_entry.prompt_config.styleModifier, 'Reference Sargent.');
  assert.equal(sentBody.p_entry.prompt_token_count, 800);
  assert.equal(sentBody.p_entry.completion_token_count, 350);
  // ISO-8601, derived from the injected `now`.
  assert.equal(sentBody.p_entry.created_at, new Date(FIXED_NOW).toISOString());
});

test('persistCritique throws on non-2xx and the orphan log path includes userId + drawingId', async () => {
  const { env } = makeEnv(TEST_SUPABASE);
  const fetcher = async () => ({ ok: false, status: 503 });
  const entry = buildCritiqueEntry({
    feedback: 'x',
    sequenceNumber: 1,
    config: selectConfig('free', null),
    tier: 'free',
    usage: { prompt_tokens: 0, completion_tokens: 0 },
    now: FIXED_NOW,
  });

  await assert.rejects(
    () => persistCritique({ env, drawingId: TEST_DRAWING_ID, entry, fetcher }),
    /append_critique HTTP 503/,
  );

  // The fetch handler wraps this in console.error with both ids — verify
  // shape directly so future refactors don't drop a field.
  const calls = [];
  const originalError = console.error;
  console.error = (...args) => { calls.push(args); };
  try {
    try {
      await persistCritique({ env, drawingId: TEST_DRAWING_ID, entry, fetcher });
    } catch (err) {
      console.error('[persistence] orphan critique', {
        drawingId: TEST_DRAWING_ID,
        userId: FREE_USER,
        error: err?.message,
      });
    }
    assert.equal(calls.length, 1);
    assert.match(String(calls[0][0]), /orphan critique/);
    assert.deepEqual(calls[0][1], {
      drawingId: TEST_DRAWING_ID,
      userId: FREE_USER,
      error: 'append_critique HTTP 503',
    });
  } finally {
    console.error = originalError;
  }
});

test('idempotent retry returns cached body and never re-invokes RPC or quota helpers', async () => {
  const { env, kv } = makeEnv(TEST_SUPABASE);
  kv.setNow(FIXED_NOW);

  // Seed cache as if the original request had completed.
  const originalBody = {
    feedback: 'First take: composition is solid.',
    critique_entry: { sequence_number: 1, content: 'First take: composition is solid.' },
  };
  await recordIdempotent({ env, userId: FREE_USER, clientRequestId: TEST_REQUEST_ID, body: originalBody });

  // Cache key shape contract: idempotency:<uid>:<crid>.
  const expectedKey = `idempotency:${FREE_USER}:${TEST_REQUEST_ID}`;
  assert.ok(await kv.get(expectedKey), 'cache should have the seeded entry under the documented key');

  const replay = await checkIdempotency({ env, userId: FREE_USER, clientRequestId: TEST_REQUEST_ID });
  assert.deepEqual(replay, originalBody, 'replay must return the exact original body');

  // Different user, same request id → miss (scoping prevents cross-user leak).
  const otherUserReplay = await checkIdempotency({ env, userId: PRO_USER, clientRequestId: TEST_REQUEST_ID });
  assert.equal(otherUserReplay, null);
});

test('idempotency cache expires after 1h TTL', async () => {
  const { env, kv } = makeEnv(TEST_SUPABASE);
  kv.setNow(FIXED_NOW);
  await recordIdempotent({
    env,
    userId: FREE_USER,
    clientRequestId: TEST_REQUEST_ID,
    body: { feedback: 'cached' },
  });

  // 59 minutes later — still fresh.
  kv.setNow(FIXED_NOW + 59 * 60 * 1000);
  assert.notEqual(
    await checkIdempotency({ env, userId: FREE_USER, clientRequestId: TEST_REQUEST_ID }),
    null,
  );

  // 1h 1min later — expired.
  kv.setNow(FIXED_NOW + 61 * 60 * 1000);
  assert.equal(
    await checkIdempotency({ env, userId: FREE_USER, clientRequestId: TEST_REQUEST_ID }),
    null,
  );
});

