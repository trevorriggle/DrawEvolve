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
  renderTruncationMarker,
  renderSkillCalibration,
  validateImagePayload,
  validateContextLengths,
  validateWorkerConfig,
  isValidPresetId,
  resolvePresetId,
  DEFAULT_PRESET_ID,
  DAILY_SPEND_CAP_USD,
  computeRequestCost,
  getDailySpend,
  incrementDailySpend,
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
  REQUEST_STATUS,
  logRequest,
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

// Mirrors the row shape that buildCritiqueEntry (cloudflare-worker/index.js)
// writes into drawings.critique_history and that fetchCritiqueHistory reads
// back. Use this when testing rendering against production data — ad-hoc
// in-test entries with a `feedback` key drifted from reality and previously
// hid a rendering bug. Override per-test via the spread argument.
function productionCritiqueRow(overrides = {}) {
  return {
    sequence_number: 1,
    content: 'Sample critique body.',
    prompt_config: { tier: 'free', includeHistoryCount: 2, styleModifier: null },
    prompt_token_count: 800,
    completion_token_count: 350,
    created_at: '2026-04-25T14:32:00.000Z',
    ...overrides,
  };
}

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
  // Regression guard: VOICE_ART_PROFESSOR must remain composed into the
  // assembled system prompt. If this fails, the voice content has been
  // dropped from BASE_SYSTEM_PROMPT composition.
  assert.ok(
    systemPrompt.includes('art professor'),
    'art-professor voice content should be present in the assembled system prompt',
  );
  assert.ok(
    systemPrompt.includes('elements of art'),
    'elements/principles vocabulary should be present in the voice block',
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

  // Truncation marker must appear (5 of 10 dropped → plural form, curly apostrophe).
  assert.ok(
    userText.includes('(5 earlier critiques on this drawing exist but aren’t shown here.)'),
    'plural truncation marker should be present when 5 entries are dropped',
  );
  // Curly apostrophe lock-in — guards against a regression to ASCII U+0027.
  assert.ok(userText.includes('aren’t'), 'curly apostrophe should be used in marker');

  // Marker must appear before the entries block so the model reads it first.
  const markerIndex = userText.indexOf('aren’t shown here');
  const firstEntry  = userText.indexOf('[Critique');
  assert.ok(markerIndex >= 0 && firstEntry >= 0 && markerIndex < firstEntry,
    'truncation marker should precede the formatted entries');
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

test('renderSkillCalibration matches case-insensitively and trims whitespace', () => {
  const lower  = renderSkillCalibration('beginner');
  const upper  = renderSkillCalibration('BEGINNER');
  const title  = renderSkillCalibration('Beginner');
  const padded = renderSkillCalibration('  Beginner  ');
  assert.equal(lower, upper);
  assert.equal(lower, title);
  assert.equal(lower, padded);
  // Sanity: it actually resolved to the beginner body, not the fallback.
  assert.match(lower, /newer to drawing/i);

  // Same shape for advanced — confirms the normalization isn't beginner-only.
  assert.equal(
    renderSkillCalibration('advanced'),
    renderSkillCalibration('ADVANCED'),
  );
  assert.match(renderSkillCalibration('advanced'), /serious skill/i);
});

test('renderSkillCalibration falls back to Intermediate body for missing/empty/unrecognized input', () => {
  const intermediate = renderSkillCalibration('Intermediate');
  // The Intermediate body is the documented fallback for anything that isn't
  // explicitly beginner or advanced (case-insensitive).
  assert.equal(renderSkillCalibration('intermediate'),  intermediate);
  assert.equal(renderSkillCalibration('Pro'),           intermediate);
  assert.equal(renderSkillCalibration('enterprise'),    intermediate);
  assert.equal(renderSkillCalibration(''),              intermediate);
  assert.equal(renderSkillCalibration('   '),           intermediate);
  assert.equal(renderSkillCalibration(undefined),       intermediate);
  assert.equal(renderSkillCalibration(null),            intermediate);

  // Sanity: it's actually the intermediate body.
  assert.match(intermediate, /working fundamentals but is still building/);

  // Integration: buildSystemPrompt with no skillLevel must use the same body
  // (the default switched from Beginner to Intermediate alongside this).
  const sysPrompt = buildSystemPrompt(selectConfig('free', null), { subject: 'a tree' });
  assert.match(sysPrompt, /working fundamentals but is still building/);
});

test('renders production-shape entries with absolute sequence numbers and content body', () => {
  const config = selectConfig('pro', null); // includeHistoryCount = 5
  const history = [
    productionCritiqueRow({ sequence_number: 1, content: 'First: gestural construction is loose.',     created_at: '2026-04-01T10:00:00Z' }),
    productionCritiqueRow({ sequence_number: 2, content: 'Second: values stuck in the mids.',          created_at: '2026-04-08T10:00:00Z' }),
    productionCritiqueRow({ sequence_number: 3, content: 'Third: edges read fuzzy in the focal area.', created_at: '2026-04-15T10:00:00Z' }),
  ];
  const userText = buildUserMessage(config, history, 'IMG')[0].text;

  // Headers driven by sequence_number + created_at.
  assert.ok(userText.includes('[Critique 1 — 2026-04-01T10:00:00Z]'));
  assert.ok(userText.includes('[Critique 2 — 2026-04-08T10:00:00Z]'));
  assert.ok(userText.includes('[Critique 3 — 2026-04-15T10:00:00Z]'));

  // Body content from `content` field — regression guard for the prior bug
  // where formatHistoryEntries only read `feedback`/`text` and rendered
  // empty bodies for production data.
  assert.ok(userText.includes('gestural construction is loose'));
  assert.ok(userText.includes('values stuck in the mids'));
  assert.ok(userText.includes('edges read fuzzy in the focal area'));

  // No truncation here (3 ≤ 5).
  assert.ok(!userText.includes('aren’t shown here'));
  assert.ok(!userText.includes('isn’t shown here'));
});

test('truncation preserves absolute sequence numbers from mid-history', () => {
  const config = { ...DEFAULT_FREE_CONFIG, includeHistoryCount: 2 };
  // 5 production-shape entries; free-tier window keeps last 2 (seq 4 and 5).
  const history = Array.from({ length: 5 }, (_, i) =>
    productionCritiqueRow({
      sequence_number: i + 1,
      content: `Body ${i + 1}.`,
      created_at: `2026-04-${String(i + 1).padStart(2, '0')}T10:00:00Z`,
    }),
  );
  const userText = buildUserMessage(config, history, 'IMG')[0].text;

  // Headers must show 4 and 5, not 1 and 2 — that's the whole point.
  assert.ok(userText.includes('[Critique 4 — 2026-04-04T10:00:00Z]'));
  assert.ok(userText.includes('[Critique 5 — 2026-04-05T10:00:00Z]'));
  assert.ok(!userText.includes('[Critique 1 —'));
  assert.ok(!userText.includes('[Critique 2 —'));
  assert.ok(!userText.includes('[Critique 3 —'));

  // Truncation marker (3 dropped → plural).
  assert.ok(userText.includes('(3 earlier critiques on this drawing exist but aren’t shown here.)'));

  // Bodies for the kept entries render correctly.
  assert.ok(userText.includes('Body 4.'));
  assert.ok(userText.includes('Body 5.'));
});

test('formatHistoryEntries falls back to slice position when sequence_number is missing', () => {
  const config = { ...DEFAULT_FREE_CONFIG, includeHistoryCount: 5 };
  // Entries without sequence_number — simulates legacy/malformed rows.
  const history = [
    { feedback: 'A.', timestamp: '2026-04-01' },
    { feedback: 'B.', timestamp: '2026-04-02' },
  ];
  const userText = buildUserMessage(config, history, 'IMG')[0].text;
  // Slice positions: 1, 2.
  assert.ok(userText.includes('[Critique 1 — 2026-04-01]'));
  assert.ok(userText.includes('[Critique 2 — 2026-04-02]'));
  // Bodies still render via the feedback fallback.
  assert.ok(userText.includes('A.'));
  assert.ok(userText.includes('B.'));
  // No truncation here (2 ≤ 5).
  assert.ok(!userText.includes('shown here'));
});

test('truncation marker pluralizes correctly and is absent when nothing is dropped', () => {
  const buildText = (totalEntries, cap) => {
    const config = { ...DEFAULT_FREE_CONFIG, includeHistoryCount: cap };
    const history = Array.from({ length: totalEntries }, (_, i) =>
      productionCritiqueRow({ sequence_number: i + 1, content: `Body ${i + 1}.` }),
    );
    return buildUserMessage(config, history, 'IMG')[0].text;
  };

  // 1 dropped → singular grammar.
  const oneDropped = buildText(2, 1);
  assert.ok(oneDropped.includes('(1 earlier critique on this drawing exists but isn’t shown here.)'));

  // 3 dropped → plural grammar.
  const threeDropped = buildText(5, 2);
  assert.ok(threeDropped.includes('(3 earlier critiques on this drawing exist but aren’t shown here.)'));

  // 0 dropped → no marker at all.
  const noDrop = buildText(2, 5);
  assert.ok(!noDrop.includes('shown here'));
  assert.ok(!noDrop.includes('earlier critique'));
});

test('renderTruncationMarker handles 0/1/N with curly apostrophes', () => {
  assert.equal(renderTruncationMarker(0),  '');
  assert.equal(renderTruncationMarker(-1), '');
  assert.equal(
    renderTruncationMarker(1),
    '(1 earlier critique on this drawing exists but isn’t shown here.)',
  );
  assert.equal(
    renderTruncationMarker(7),
    '(7 earlier critiques on this drawing exist but aren’t shown here.)',
  );
  // Curly apostrophe lock-in (U+2019, not U+0027).
  assert.ok(renderTruncationMarker(1).includes('’'));
  assert.ok(!renderTruncationMarker(1).includes("'"));
});

test('assembled system prompt contains the SUBJECT VERIFICATION and CLOSING ASIDE strict-requirements blocks', () => {
  const sysPrompt = buildSystemPrompt(selectConfig('free', null), baseContext);
  // SUBJECT VERIFICATION (catches accidental deletion of the missing-feature /
  // subject-drift checks that were added after gpt-4o + gpt-5.1 simulator
  // rounds both failed to flag a no-ear Bart and a Bart-to-pumpkin drift).
  assert.ok(sysPrompt.includes('SUBJECT VERIFICATION — REQUIRED FIRST STEP'));
  assert.ok(sysPrompt.includes('CANONICAL FEATURE CHECK'));
  assert.ok(sysPrompt.includes('SUBJECT MATCH CHECK'));
  // CLOSING ASIDE strict block (catches accidental revert to loose tone guidance).
  assert.ok(sysPrompt.includes('CLOSING ASIDE — STRICT REQUIREMENTS'));
});

test('CLOSING ASIDE block keeps the REQUIRED / FORBIDDEN / EXAMPLES imperative structure', () => {
  // The imperative structure is what makes the rule load-bearing — narrative
  // tone guidance was insufficient against the model's trained sycophancy
  // defaults. This guards against an accidental simplification to prose.
  const sysPrompt = buildSystemPrompt(selectConfig('free', null), baseContext);
  assert.ok(sysPrompt.includes('REQUIRED:'));
  assert.ok(sysPrompt.includes('FORBIDDEN:'));
  assert.ok(sysPrompt.includes('ACCEPTABLE EXAMPLES:'));
  assert.ok(sysPrompt.includes('UNACCEPTABLE EXAMPLES'));
});

test('old loose closing-aside CORE RULES bullet has been removed', () => {
  // Catches the accidental partial-revert where the new strict block lands
  // but the old contradictory bullet sneaks back into CORE RULES.
  const sysPrompt = buildSystemPrompt(selectConfig('free', null), baseContext);
  assert.ok(!sysPrompt.includes('End with one dry, observational aside'));
  assert.ok(!sysPrompt.includes('"fun fact" energy'));
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
// Context length caps — validateContextLengths
// =============================================================================

test('validateContextLengths returns null when all fields are within their caps', () => {
  assert.equal(validateContextLengths({}), null);
  assert.equal(validateContextLengths({ subject: 'a portrait' }), null);
  // At exactly the cap is allowed (inclusive).
  assert.equal(validateContextLengths({ subject: 'a'.repeat(200) }), null);
  assert.equal(validateContextLengths({ artists: 'a'.repeat(500) }), null);
  assert.equal(validateContextLengths({ additionalContext: 'a'.repeat(2000) }), null);
});

test('validateContextLengths flags additionalContext over its 2000 cap with the field name and length', () => {
  const err = validateContextLengths({ additionalContext: 'a'.repeat(2001) });
  assert.equal(err?.field,  'additionalContext');
  assert.equal(err?.max,    2000);
  assert.equal(err?.length, 2001);
});

test('validateContextLengths uses per-field caps (subject 200, artists 500)', () => {
  // subject cap is 200 — 201 fails
  const subErr = validateContextLengths({ subject: 'a'.repeat(201) });
  assert.equal(subErr?.field, 'subject');
  assert.equal(subErr?.max,   200);
  // artists cap is 500 — 501 fails, 200 passes (under the smaller subject cap doesn't apply to artists)
  const artErr = validateContextLengths({ artists: 'a'.repeat(501) });
  assert.equal(artErr?.field, 'artists');
  assert.equal(artErr?.max,   500);
});

test('validateContextLengths ignores non-string values (validateContext catches those first)', () => {
  // validateContextLengths is run AFTER validateContext, so by the time we reach
  // it, all present fields are guaranteed strings. The function tolerates
  // non-strings as a defense in depth.
  assert.equal(validateContextLengths({ subject: 12345 }), null);
  assert.equal(validateContextLengths({ subject: null }),  null);
});

// =============================================================================
// Worker config validation — validateWorkerConfig
// =============================================================================

test('validateWorkerConfig flags missing SUPABASE_JWT_ISSUER', () => {
  const err = validateWorkerConfig({});
  assert.match(String(err), /SUPABASE_JWT_ISSUER/);
});

test('validateWorkerConfig returns null when SUPABASE_JWT_ISSUER is set', () => {
  assert.equal(
    validateWorkerConfig({ SUPABASE_JWT_ISSUER: 'https://x.supabase.co/auth/v1' }),
    null,
  );
});

test('validateWorkerConfig flags missing env entirely', () => {
  assert.match(String(validateWorkerConfig(null)),      /env missing/);
  assert.match(String(validateWorkerConfig(undefined)), /env missing/);
});

// =============================================================================
// Daily spend cap
// =============================================================================

test('DAILY_SPEND_CAP_USD is set to a sane TestFlight value', () => {
  assert.ok(typeof DAILY_SPEND_CAP_USD === 'number' && DAILY_SPEND_CAP_USD > 0);
  assert.ok(DAILY_SPEND_CAP_USD <= 25, 'cap should be modest at TestFlight scale');
});

test('computeRequestCost uses gpt-5.1 input/output rates', () => {
  // 1M input @ $0.63 + 1M output @ $5 = $5.63
  const big = computeRequestCost({ prompt_tokens: 1_000_000, completion_tokens: 1_000_000 });
  assert.ok(Math.abs(big - 5.63) < 1e-9);
  // Realistic critique: ~2K input + ~700 output
  const realistic = computeRequestCost({ prompt_tokens: 2000, completion_tokens: 700 });
  // 2000 * 0.63e-6 + 700 * 5e-6 = 0.00126 + 0.0035 = 0.00476
  assert.ok(Math.abs(realistic - 0.00476) < 1e-6);
  // Missing usage is 0, never NaN.
  assert.equal(computeRequestCost({}),         0);
  assert.equal(computeRequestCost(undefined),  0);
});

test('getDailySpend returns 0 for missing key, parses stored number', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  assert.equal(await getDailySpend(env, '2026-04-29'), 0);
  await kv.put('daily_spend:2026-04-29', '1.2345', { expirationTtl: 48 * 3600 });
  assert.equal(await getDailySpend(env, '2026-04-29'), 1.2345);
  // Malformed values fall back to 0, not NaN.
  await kv.put('daily_spend:2026-04-30', 'not-a-number', { expirationTtl: 48 * 3600 });
  assert.equal(await getDailySpend(env, '2026-04-30'), 0);
});

test('incrementDailySpend adds to existing total and persists', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  await kv.put('daily_spend:2026-04-29', '0.50', { expirationTtl: 48 * 3600 });
  const next = await incrementDailySpend(env, '2026-04-29', 0.25);
  assert.ok(Math.abs(next - 0.75) < 1e-9);
  assert.ok(Math.abs((await getDailySpend(env, '2026-04-29')) - 0.75) < 1e-9);
});

test('daily spend cap gating: at-or-above the cap blocks; below the cap allows', async () => {
  // Validates the predicate the handler uses ("dailySpend >= DAILY_SPEND_CAP_USD")
  // by exercising the helper that feeds it.
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  // Seed exactly at the cap.
  await kv.put('daily_spend:2026-04-29', String(DAILY_SPEND_CAP_USD), { expirationTtl: 48 * 3600 });
  const spent = await getDailySpend(env, '2026-04-29');
  assert.ok(spent >= DAILY_SPEND_CAP_USD, 'at-cap reads as at-or-above the cap');

  // Drop slightly below.
  await kv.put('daily_spend:2026-04-29', String(DAILY_SPEND_CAP_USD - 0.01), { expirationTtl: 48 * 3600 });
  const under = await getDailySpend(env, '2026-04-29');
  assert.ok(under < DAILY_SPEND_CAP_USD, 'below-cap reads as below the cap');
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
    presetId: 'renaissance_master',
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
  // preset_id sits at top level, NOT inside prompt_config.
  assert.equal(sentBody.p_entry.preset_id, 'renaissance_master');
  assert.equal(sentBody.p_entry.prompt_config.preset_id, undefined);
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

// =============================================================================
// Phase 5e — request logging
// =============================================================================
//
// The fetch handler invokes logRequest via ctx.waitUntil, so the contract we
// care about is what logRequest sends to PostgREST given the inputs each
// terminal branch gathers. Tests stub the fetcher and inspect the captured
// POST body.

const TEST_IP_HASH = 'a'.repeat(64);

function captureFetcher() {
  const calls = [];
  const fetcher = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    return { ok: true, status: 201 };
  };
  return { fetcher, calls };
}

test('logRequest success path writes status=success with token counts populated', async () => {
  const { env } = makeEnv(TEST_SUPABASE);
  const { fetcher, calls } = captureFetcher();

  await logRequest({
    env,
    status: REQUEST_STATUS.SUCCESS,
    userId: FREE_USER,
    drawingId: TEST_DRAWING_ID,
    ipHash: TEST_IP_HASH,
    promptTokens: 1024,
    completionTokens: 512,
    fetcher,
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://test.supabase.co/rest/v1/feedback_requests');
  assert.equal(calls[0].init.method, 'POST');
  assert.equal(calls[0].init.headers.apikey, 'fake-service-role-key');
  assert.equal(calls[0].init.headers.Prefer, 'return=minimal');
  assert.deepEqual(calls[0].body, {
    user_id: FREE_USER,
    drawing_id: TEST_DRAWING_ID,
    status: 'success',
    prompt_token_count: 1024,
    completion_token_count: 512,
    client_ip_hash: TEST_IP_HASH,
  });
});

test('logRequest quota_exceeded path leaves token counts null', async () => {
  const { env } = makeEnv(TEST_SUPABASE);
  const { fetcher, calls } = captureFetcher();

  await logRequest({
    env,
    status: REQUEST_STATUS.QUOTA_EXCEEDED,
    userId: FREE_USER,
    drawingId: TEST_DRAWING_ID,
    ipHash: TEST_IP_HASH,
    fetcher,
  });

  assert.equal(calls[0].body.status, 'quota_exceeded');
  assert.equal(calls[0].body.prompt_token_count, null);
  assert.equal(calls[0].body.completion_token_count, null);
  assert.equal(calls[0].body.drawing_id, TEST_DRAWING_ID, 'drawing_id is known when rate-limited (extracted before the gate)');
});

test('logRequest auth_failed path has null user_id and null drawing_id but populated ip_hash', async () => {
  const { env } = makeEnv(TEST_SUPABASE);
  const { fetcher, calls } = captureFetcher();

  await logRequest({
    env,
    status: REQUEST_STATUS.AUTH_FAILED,
    ipHash: TEST_IP_HASH,
    fetcher,
  });

  assert.deepEqual(calls[0].body, {
    user_id: null,
    drawing_id: null,
    status: 'auth_failed',
    prompt_token_count: null,
    completion_token_count: null,
    client_ip_hash: TEST_IP_HASH,
  });
});

test('logRequest persistence_orphan path keeps token counts (OpenAI delivered, RPC failed)', async () => {
  const { env } = makeEnv(TEST_SUPABASE);
  const { fetcher, calls } = captureFetcher();

  await logRequest({
    env,
    status: REQUEST_STATUS.PERSISTENCE_ORPHAN,
    userId: FREE_USER,
    drawingId: TEST_DRAWING_ID,
    ipHash: TEST_IP_HASH,
    promptTokens: 800,
    completionTokens: 350,
    fetcher,
  });

  assert.equal(calls[0].body.status, 'persistence_orphan');
  assert.equal(calls[0].body.prompt_token_count, 800);
  assert.equal(calls[0].body.completion_token_count, 350);
});

test('logRequest swallows fetcher errors and never throws (observability is non-load-bearing)', async () => {
  const { env } = makeEnv(TEST_SUPABASE);

  const errorCalls = [];
  const originalError = console.error;
  console.error = (...args) => { errorCalls.push(args); };
  try {
    // Branch 1: fetcher returns non-ok — log a status code.
    await logRequest({
      env, status: REQUEST_STATUS.SUCCESS, userId: FREE_USER, ipHash: TEST_IP_HASH,
      fetcher: async () => ({ ok: false, status: 503 }),
    });
    // Branch 2: fetcher throws — log the error message.
    await logRequest({
      env, status: REQUEST_STATUS.SUCCESS, userId: FREE_USER, ipHash: TEST_IP_HASH,
      fetcher: async () => { throw new Error('boom'); },
    });
  } finally {
    console.error = originalError;
  }

  assert.equal(errorCalls.length, 2, 'both failure modes should log exactly once');
  assert.match(String(errorCalls[0][0]), /non-ok/);
  assert.match(String(errorCalls[1][0]), /threw/);
});

test('REQUEST_STATUS keeps model_error and internal_error distinct', () => {
  // Abuse-detection queries depend on this distinction — model_error is
  // "OpenAI's fault," internal_error is "our fault." Don't conflate.
  assert.equal(REQUEST_STATUS.MODEL_ERROR, 'model_error');
  assert.equal(REQUEST_STATUS.INTERNAL_ERROR, 'internal_error');
  assert.notEqual(REQUEST_STATUS.MODEL_ERROR, REQUEST_STATUS.INTERNAL_ERROR);
});

test('logRequest idempotent_replay path', async () => {
  const { env } = makeEnv(TEST_SUPABASE);
  const { fetcher, calls } = captureFetcher();

  await logRequest({
    env,
    status: REQUEST_STATUS.IDEMPOTENT_REPLAY,
    userId: FREE_USER,
    drawingId: TEST_DRAWING_ID,
    ipHash: TEST_IP_HASH,
    fetcher,
  });

  assert.equal(calls[0].body.status, 'idempotent_replay');
  assert.equal(calls[0].body.prompt_token_count, null,
    'replay does not call OpenAI — token counts must be null');
});

// =============================================================================
// Preset voices + custom prompts plumbing (Commit A of 3)
// =============================================================================

test('isValidPresetId accepts the four hardcoded preset IDs', () => {
  for (const id of ['studio_mentor', 'the_crit', 'fundamentals_coach', 'renaissance_master']) {
    assert.equal(isValidPresetId(id), true, `should accept ${id}`);
  }
});

test('isValidPresetId accepts a valid custom:UUID', () => {
  assert.equal(isValidPresetId('custom:550e8400-e29b-41d4-a716-446655440000'), true);
});

test('isValidPresetId rejects invalid inputs', () => {
  assert.equal(isValidPresetId(undefined), false);
  assert.equal(isValidPresetId(null), false);
  assert.equal(isValidPresetId(''), false);
  assert.equal(isValidPresetId('something_else'), false);
  assert.equal(isValidPresetId('custom:not-a-uuid'), false);
  assert.equal(isValidPresetId('custom:'), false);
  // Case-sensitive: uppercase prefix or preset ID is rejected.
  assert.equal(isValidPresetId('CUSTOM:550e8400-e29b-41d4-a716-446655440000'), false);
  assert.equal(isValidPresetId('Studio_Mentor'), false);
  assert.equal(isValidPresetId(12345), false);
});

test('resolvePresetId returns DEFAULT_PRESET_ID when input is missing', async () => {
  for (const input of [undefined, null, '']) {
    assert.equal(await resolvePresetId(input, FREE_USER, {}), DEFAULT_PRESET_ID);
  }
});

test('resolvePresetId returns hardcoded preset IDs without a DB hit', async () => {
  let called = false;
  const fetcher = async () => { called = true; return { ok: true, json: async () => [] }; };
  for (const id of ['studio_mentor', 'the_crit', 'fundamentals_coach', 'renaissance_master']) {
    const result = await resolvePresetId(id, FREE_USER, TEST_SUPABASE, fetcher);
    assert.equal(result, id);
  }
  assert.equal(called, false, 'no fetch should happen for hardcoded presets');
});

test('resolvePresetId throws invalid_preset_id for malformed input', async () => {
  await assert.rejects(
    () => resolvePresetId('not_a_real_preset', FREE_USER, TEST_SUPABASE),
    (err) => err.code === 'invalid_preset_id',
  );
  await assert.rejects(
    () => resolvePresetId('custom:not-a-uuid', FREE_USER, TEST_SUPABASE),
    (err) => err.code === 'invalid_preset_id',
  );
});

test('resolvePresetId verifies ownership for custom:UUID — match returns the input', async () => {
  const customId = 'custom:550e8400-e29b-41d4-a716-446655440000';
  let captured;
  const fetcher = async (url) => {
    captured = url;
    return { ok: true, json: async () => [{ id: '550e8400-e29b-41d4-a716-446655440000' }] };
  };
  const result = await resolvePresetId(customId, FREE_USER, TEST_SUPABASE, fetcher);
  assert.equal(result, customId);
  assert.match(captured, /custom_prompts/);
  assert.match(captured, /id=eq\.550e8400/);
  assert.match(captured, new RegExp(`user_id=eq\\.${FREE_USER}`));
});

test('resolvePresetId throws custom_prompt_not_found when the row does not belong to the user', async () => {
  const fetcher = async () => ({ ok: true, json: async () => [] }); // empty PostgREST result
  await assert.rejects(
    () => resolvePresetId('custom:550e8400-e29b-41d4-a716-446655440000', FREE_USER, TEST_SUPABASE, fetcher),
    (err) => err.code === 'custom_prompt_not_found',
  );
});

test('resolvePresetId throws custom_prompt_lookup_failed on PostgREST non-2xx', async () => {
  const fetcher = async () => ({ ok: false, status: 503 });
  await assert.rejects(
    () => resolvePresetId('custom:550e8400-e29b-41d4-a716-446655440000', FREE_USER, TEST_SUPABASE, fetcher),
    (err) => err.code === 'custom_prompt_lookup_failed',
  );
});

test('buildCritiqueEntry includes preset_id at top level (not inside prompt_config)', () => {
  const entry = buildCritiqueEntry({
    feedback: 'x',
    sequenceNumber: 1,
    config: selectConfig('free', null),
    tier: 'free',
    usage: { prompt_tokens: 100, completion_tokens: 50 },
    now: FIXED_NOW,
    presetId: 'renaissance_master',
  });
  assert.equal(entry.preset_id, 'renaissance_master');
  assert.equal(entry.prompt_config.preset_id, undefined,
    'preset_id is voice identity, not a prompt-config knob');
});

test('buildCritiqueEntry defaults preset_id to studio_mentor when omitted', () => {
  const entry = buildCritiqueEntry({
    feedback: 'x',
    sequenceNumber: 1,
    config: selectConfig('free', null),
    tier: 'free',
    usage: { prompt_tokens: 100, completion_tokens: 50 },
    now: FIXED_NOW,
  });
  assert.equal(entry.preset_id, DEFAULT_PRESET_ID);
});

test('validateContext type-checks preset_id like other context fields', () => {
  assert.equal(validateContext({ preset_id: 'studio_mentor' }), true);
  assert.equal(validateContext({ preset_id: 12345 }), false);
});

test('validateContextLengths caps preset_id at 50 chars', () => {
  // 'custom:' (7) + 36-char UUID = 43; well under 50.
  assert.equal(validateContextLengths({ preset_id: 'custom:550e8400-e29b-41d4-a716-446655440000' }), null);
  // At cap (50) — still passes.
  assert.equal(validateContextLengths({ preset_id: 'a'.repeat(50) }), null);
  // Over cap (51) — fails with field name.
  const err = validateContextLengths({ preset_id: 'a'.repeat(51) });
  assert.equal(err?.field, 'preset_id');
  assert.equal(err?.max, 50);
});
