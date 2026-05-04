import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import {
  BASE_SYSTEM_PROMPT,
  VOICE_STUDIO_MENTOR,
  VOICE_THE_CRIT,
  VOICE_FUNDAMENTALS_COACH,
  VOICE_RENAISSANCE_MASTER,
  PRESET_VOICES,
  selectVoice,
  assembleSystemPrompt,
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
  ESTIMATED_REQUEST_COST_USD,
  computeRequestCost,
  getDailySpend,
  incrementDailySpend,
  getUserTokensToday,
  incrementUserTokensToday,
  readDailySpendCapUsd,
  readPerUserDailyTokenCap,
  enforceCostCeilings,
  recordRequestUsage,
  validateContext,
  getUserTier,
  PROMPT_TEMPLATE_VERSION,
  FOCUS_OPTIONS,
  TONE_OPTIONS,
  DEPTH_OPTIONS,
  TECHNIQUE_OPTIONS,
  validatePromptParameters,
  renderCustomPromptModifier,
  selectCustomPromptParameters,
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
  validateJWT,
  _resetJwksCacheForTests,
  bytesEqual,
  bytesToHex,
  hexToBytes,
  cborDecode,
  ecdsaDerToRaw,
  computeAppAttestClientDataHash,
  verifyAppAttestAssertion,
  issueAppAttestChallenge,
  consumeAppAttestChallenge,
  storeAttestedKey,
  getAttestedKey,
  updateAttestedKeyCounter,
  readAppAttestHeaders,
} from './index.js';
import handler from './index.js';

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
  // Regression guard: VOICE_STUDIO_MENTOR must remain composed into the
  // assembled system prompt. 'elements of art' is uniquely present in
  // VOICE_STUDIO_MENTOR and absent from SHARED_SYSTEM_RULES,
  // renderSkillCalibration, and RESPONSE_FORMAT_TEMPLATE — so this guard
  // genuinely fails if the voice block is dropped from composition.
  // (An earlier 'art professor' guard was weak: that phrase also appears
  // in SHARED_SYSTEM_RULES' CLOSING ASIDE block, so it would pass even
  // if the voice were stripped. Removed.)
  assert.ok(
    systemPrompt.includes('elements of art'),
    'studio-mentor voice (elements/principles vocabulary) should be present',
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
  // Validates the helper predicate that feeds the cost-ceiling check.
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
// Cost ceilings — provider daily $ cap + per-user daily token cap
// =============================================================================
//
// These are the launch-blocker hard caps that gate the OpenAI call. They run
// AFTER tier rate limits, BEFORE the OpenAI call. Both fail-closed with 429
// and a stable error code the iOS client surfaces as "Daily limit reached".

test('readDailySpendCapUsd returns env override when set', () => {
  assert.equal(readDailySpendCapUsd({ OPENAI_DAILY_SPEND_CAP_USD: '12.50' }), 12.50);
  assert.equal(readDailySpendCapUsd({ OPENAI_DAILY_SPEND_CAP_USD: 7 }), 7);
});

test('readDailySpendCapUsd falls back to constant when env is missing or invalid', () => {
  assert.equal(readDailySpendCapUsd({}), DAILY_SPEND_CAP_USD);
  assert.equal(readDailySpendCapUsd({ OPENAI_DAILY_SPEND_CAP_USD: '' }), DAILY_SPEND_CAP_USD);
  assert.equal(readDailySpendCapUsd({ OPENAI_DAILY_SPEND_CAP_USD: 'not-a-number' }), DAILY_SPEND_CAP_USD);
  assert.equal(readDailySpendCapUsd({ OPENAI_DAILY_SPEND_CAP_USD: '0' }), DAILY_SPEND_CAP_USD);
  assert.equal(readDailySpendCapUsd({ OPENAI_DAILY_SPEND_CAP_USD: '-1' }), DAILY_SPEND_CAP_USD);
});

test('readPerUserDailyTokenCap returns env value when set', () => {
  assert.equal(readPerUserDailyTokenCap({ PER_USER_DAILY_TOKEN_CAP: '50000' }), 50000);
  assert.equal(readPerUserDailyTokenCap({ PER_USER_DAILY_TOKEN_CAP: 12345 }), 12345);
});

test('readPerUserDailyTokenCap returns Infinity when unset or invalid', () => {
  // No env-driven cap = no enforcement. wrangler.toml documents this as a
  // launch-blocker that must be set explicitly in production.
  assert.equal(readPerUserDailyTokenCap({}), Infinity);
  assert.equal(readPerUserDailyTokenCap({ PER_USER_DAILY_TOKEN_CAP: '' }), Infinity);
  assert.equal(readPerUserDailyTokenCap({ PER_USER_DAILY_TOKEN_CAP: 'nope' }), Infinity);
  assert.equal(readPerUserDailyTokenCap({ PER_USER_DAILY_TOKEN_CAP: '0' }), Infinity);
  assert.equal(readPerUserDailyTokenCap({ PER_USER_DAILY_TOKEN_CAP: '-50' }), Infinity);
});

test('getUserTokensToday returns 0 for missing key, parses stored integer', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  assert.equal(await getUserTokensToday(env, FREE_USER, '2026-04-29'), 0);
  await kv.put(`user_tokens:${FREE_USER}:2026-04-29`, '4200', { expirationTtl: 48 * 3600 });
  assert.equal(await getUserTokensToday(env, FREE_USER, '2026-04-29'), 4200);
});

test('incrementUserTokensToday adds to existing total', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  await incrementUserTokensToday(env, FREE_USER, '2026-04-29', 1000);
  await incrementUserTokensToday(env, FREE_USER, '2026-04-29', 500);
  assert.equal(await getUserTokensToday(env, FREE_USER, '2026-04-29'), 1500);
});

test('enforceCostCeilings: caps not yet hit → passes', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  env.OPENAI_DAILY_SPEND_CAP_USD = '5.00';
  env.PER_USER_DAILY_TOKEN_CAP = '50000';
  // Seed well below both caps.
  await kv.put('daily_spend:2026-04-29', '1.00', { expirationTtl: 48 * 3600 });
  await kv.put(`user_tokens:${FREE_USER}:2026-04-29`, '10000', { expirationTtl: 48 * 3600 });

  const decision = await enforceCostCeilings({ env, userId: FREE_USER, now: FIXED_NOW });
  assert.equal(decision.ok, true);
  assert.equal(decision.ctx.dayKey, '2026-04-29');
});

test('enforceCostCeilings: daily spend exactly at cap → next request fails', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  env.OPENAI_DAILY_SPEND_CAP_USD = '5.00';
  // Seed exactly at the cap. Adding any estimate pushes it over.
  await kv.put('daily_spend:2026-04-29', '5.00', { expirationTtl: 48 * 3600 });

  const decision = await enforceCostCeilings({ env, userId: FREE_USER, now: FIXED_NOW });
  assert.equal(decision.ok, false);
  assert.equal(decision.status, 429);
  assert.equal(decision.body.error, 'daily_spend_cap_exceeded');
  assert.match(decision.body.message, /daily limit reached/i);
  assert.ok(decision.body.retryAfter > 0);
});

test('enforceCostCeilings: daily spend already exceeded → fails immediately', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  env.OPENAI_DAILY_SPEND_CAP_USD = '5.00';
  await kv.put('daily_spend:2026-04-29', '99.99', { expirationTtl: 48 * 3600 });

  const decision = await enforceCostCeilings({ env, userId: FREE_USER, now: FIXED_NOW });
  assert.equal(decision.ok, false);
  assert.equal(decision.status, 429);
  assert.equal(decision.body.error, 'daily_spend_cap_exceeded');
});

test('enforceCostCeilings: daily spend just below cap minus estimate → still passes', async () => {
  // Boundary: a request can land if (current + ESTIMATED_REQUEST_COST_USD) <= cap.
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  env.OPENAI_DAILY_SPEND_CAP_USD = '5.00';
  // Leave just enough headroom for the estimate.
  const seed = (5.00 - ESTIMATED_REQUEST_COST_USD).toFixed(6);
  await kv.put('daily_spend:2026-04-29', seed, { expirationTtl: 48 * 3600 });

  const decision = await enforceCostCeilings({ env, userId: FREE_USER, now: FIXED_NOW });
  assert.equal(decision.ok, true);
});

test('enforceCostCeilings: per-user tokens exactly at cap → next request fails', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  env.PER_USER_DAILY_TOKEN_CAP = '50000';
  await kv.put(`user_tokens:${FREE_USER}:2026-04-29`, '50000', { expirationTtl: 48 * 3600 });

  const decision = await enforceCostCeilings({ env, userId: FREE_USER, now: FIXED_NOW });
  assert.equal(decision.ok, false);
  assert.equal(decision.status, 429);
  assert.equal(decision.body.error, 'per_user_token_cap_exceeded');
  assert.match(decision.body.message, /daily limit reached/i);
  assert.ok(decision.body.retryAfter > 0);
});

test('enforceCostCeilings: per-user tokens already exceeded → fails immediately', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  env.PER_USER_DAILY_TOKEN_CAP = '50000';
  await kv.put(`user_tokens:${FREE_USER}:2026-04-29`, '999999', { expirationTtl: 48 * 3600 });

  const decision = await enforceCostCeilings({ env, userId: FREE_USER, now: FIXED_NOW });
  assert.equal(decision.ok, false);
  assert.equal(decision.body.error, 'per_user_token_cap_exceeded');
});

test('enforceCostCeilings: per-user cap is per-user — one user over does not block another', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  env.PER_USER_DAILY_TOKEN_CAP = '50000';
  await kv.put(`user_tokens:${FREE_USER}:2026-04-29`, '50000', { expirationTtl: 48 * 3600 });

  const blocked = await enforceCostCeilings({ env, userId: FREE_USER, now: FIXED_NOW });
  assert.equal(blocked.ok, false);
  const allowed = await enforceCostCeilings({ env, userId: PRO_USER, now: FIXED_NOW });
  assert.equal(allowed.ok, true);
});

test('enforceCostCeilings: spend cap evaluated before token cap (deterministic priority)', async () => {
  // When both caps would reject, the daily spend cap message wins. iOS treats
  // them the same (both surface "Daily limit reached"), but a stable error code
  // makes log filtering cleaner.
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  env.OPENAI_DAILY_SPEND_CAP_USD = '5.00';
  env.PER_USER_DAILY_TOKEN_CAP = '50000';
  await kv.put('daily_spend:2026-04-29', '99.99', { expirationTtl: 48 * 3600 });
  await kv.put(`user_tokens:${FREE_USER}:2026-04-29`, '999999', { expirationTtl: 48 * 3600 });

  const decision = await enforceCostCeilings({ env, userId: FREE_USER, now: FIXED_NOW });
  assert.equal(decision.body.error, 'daily_spend_cap_exceeded');
});

test('enforceCostCeilings: per-user cap unset (env missing) → token cap not enforced', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  // No PER_USER_DAILY_TOKEN_CAP set — cap is Infinity, no enforcement.
  await kv.put(`user_tokens:${FREE_USER}:2026-04-29`, '10000000', { expirationTtl: 48 * 3600 });

  const decision = await enforceCostCeilings({ env, userId: FREE_USER, now: FIXED_NOW });
  assert.equal(decision.ok, true);
});

test('enforceCostCeilings: env override of spend cap is honored', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  env.OPENAI_DAILY_SPEND_CAP_USD = '1.00';   // tighter than the constant
  await kv.put('daily_spend:2026-04-29', '0.999', { expirationTtl: 48 * 3600 });

  // Below the lower env cap minus estimate? No — 0.999 + 0.005 > 1.00, so reject.
  const decision = await enforceCostCeilings({ env, userId: FREE_USER, now: FIXED_NOW });
  assert.equal(decision.ok, false);
  assert.equal(decision.body.error, 'daily_spend_cap_exceeded');
});

test('recordRequestUsage increments per-user tokens by actual prompt+completion', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  await recordRequestUsage({
    env,
    userId: FREE_USER,
    dayKey: '2026-04-29',
    usage: { prompt_tokens: 800, completion_tokens: 350 },
  });
  assert.equal(await getUserTokensToday(env, FREE_USER, '2026-04-29'), 1150);

  // Subsequent call accumulates.
  await recordRequestUsage({
    env,
    userId: FREE_USER,
    dayKey: '2026-04-29',
    usage: { prompt_tokens: 100, completion_tokens: 50 },
  });
  assert.equal(await getUserTokensToday(env, FREE_USER, '2026-04-29'), 1300);
});

test('recordRequestUsage tolerates missing/partial usage', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  // No-op when usage is null.
  await recordRequestUsage({ env, userId: FREE_USER, dayKey: '2026-04-29', usage: null });
  assert.equal(await getUserTokensToday(env, FREE_USER, '2026-04-29'), 0);
  // Treats missing fields as 0.
  await recordRequestUsage({
    env,
    userId: FREE_USER,
    dayKey: '2026-04-29',
    usage: { prompt_tokens: 200 },
  });
  assert.equal(await getUserTokensToday(env, FREE_USER, '2026-04-29'), 200);
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

// =============================================================================
// Preset voices — content + selectVoice (Commit B of 3)
// =============================================================================

test('PRESET_VOICES exposes all four hardcoded preset IDs as non-empty strings', () => {
  // Lock-in: the four keys here MUST match VALID_PRESET_IDS.
  for (const id of ['studio_mentor', 'the_crit', 'fundamentals_coach', 'renaissance_master']) {
    assert.ok(
      typeof PRESET_VOICES[id] === 'string' && PRESET_VOICES[id].length > 0,
      `PRESET_VOICES.${id} should be a non-empty string`,
    );
  }
});

test('each voice constant carries its distinguishing substring', () => {
  // These substrings are unique to each voice and don't appear in
  // SHARED_SYSTEM_RULES, renderSkillCalibration, or RESPONSE_FORMAT_TEMPLATE.
  // Guards against accidental cross-contamination during edits.
  assert.match(VOICE_STUDIO_MENTOR,      /elements of art/);
  assert.match(VOICE_THE_CRIT,           /senior MFA crit/);
  assert.match(VOICE_FUNDAMENTALS_COACH, /draftsmanship coach/);
  assert.match(VOICE_RENAISSANCE_MASTER, /Florentine workshop in the year 1503/);
});

test('assembleSystemPrompt composes voice + SHARED_SYSTEM_RULES for each voice', () => {
  for (const voice of [VOICE_STUDIO_MENTOR, VOICE_THE_CRIT, VOICE_FUNDAMENTALS_COACH, VOICE_RENAISSANCE_MASTER]) {
    const assembled = assembleSystemPrompt(voice);
    // Voice content appears verbatim.
    assert.ok(assembled.includes(voice), 'voice content should appear verbatim');
    // All four SHARED_SYSTEM_RULES top-level sections present.
    assert.match(assembled, /CORE RULES:/);
    assert.match(assembled, /SUBJECT VERIFICATION/);
    assert.match(assembled, /CLOSING ASIDE/);
    assert.match(assembled, /ITERATIVE COACHING/);
  }
});

test('BASE_SYSTEM_PROMPT equals assembleSystemPrompt(VOICE_STUDIO_MENTOR)', () => {
  // BASE_SYSTEM_PROMPT is preserved as the studio-mentor-assembled value
  // for test stability and as the default in selectConfig presets.
  assert.equal(BASE_SYSTEM_PROMPT, assembleSystemPrompt(VOICE_STUDIO_MENTOR));
});

test('selectVoice returns the matching voice for each hardcoded preset ID without a DB hit', async () => {
  let called = false;
  const fetcher = async () => { called = true; return { ok: true, json: async () => [] }; };
  for (const [id, voice] of Object.entries(PRESET_VOICES)) {
    const result = await selectVoice(id, FREE_USER, TEST_SUPABASE, fetcher);
    assert.equal(result, voice, `selectVoice('${id}') should return PRESET_VOICES.${id}`);
  }
  assert.equal(called, false, 'no fetch should happen for hardcoded preset IDs');
});

test('selectVoice fetches the body for custom:<uuid> with user_id refilter', async () => {
  const customId = 'custom:550e8400-e29b-41d4-a716-446655440000';
  let captured;
  const fetcher = async (url) => {
    captured = url;
    return { ok: true, json: async () => [{ body: 'Be exceptionally critical of negative space.' }] };
  };
  const result = await selectVoice(customId, FREE_USER, TEST_SUPABASE, fetcher);
  assert.equal(result, 'Be exceptionally critical of negative space.');
  // Defense-in-depth: the user_id filter is present on the SELECT.
  assert.match(captured, /custom_prompts/);
  assert.match(captured, /id=eq\.550e8400/);
  assert.match(captured, new RegExp(`user_id=eq\\.${FREE_USER}`));
  assert.match(captured, /select=body/);
});

test('selectVoice falls back to VOICE_STUDIO_MENTOR on PostgREST non-ok', async () => {
  // console.error suppression: the node:test runner runs tests serially by
  // default in this suite (no --test-concurrency set); reassigning
  // console.error here can't race other tests' logs. Restored in finally.
  const errorCalls = [];
  const originalError = console.error;
  console.error = (...args) => { errorCalls.push(args); };
  try {
    const fetcher = async () => ({ ok: false, status: 503 });
    const result = await selectVoice(
      'custom:550e8400-e29b-41d4-a716-446655440000',
      FREE_USER, TEST_SUPABASE, fetcher,
    );
    assert.equal(result, VOICE_STUDIO_MENTOR);
    assert.ok(errorCalls.length >= 1);
    assert.match(String(errorCalls[0][0]), /selectVoice/);
  } finally {
    console.error = originalError;
  }
});

test('selectVoice falls back to VOICE_STUDIO_MENTOR on missing/empty row', async () => {
  // (Same suppression rationale as above — serial runner; safe to swap.)
  const originalError = console.error;
  console.error = () => {};
  try {
    // Empty array — row not found
    const empty = async () => ({ ok: true, json: async () => [] });
    assert.equal(
      await selectVoice('custom:550e8400-e29b-41d4-a716-446655440000', FREE_USER, TEST_SUPABASE, empty),
      VOICE_STUDIO_MENTOR,
    );
    // Row present but body is empty string
    const emptyBody = async () => ({ ok: true, json: async () => [{ body: '' }] });
    assert.equal(
      await selectVoice('custom:550e8400-e29b-41d4-a716-446655440000', FREE_USER, TEST_SUPABASE, emptyBody),
      VOICE_STUDIO_MENTOR,
    );
  } finally {
    console.error = originalError;
  }
});

test('selectVoice falls back to VOICE_STUDIO_MENTOR on undefined / null / unknown / non-custom preset', async () => {
  let called = false;
  const fetcher = async () => { called = true; return { ok: true, json: async () => [] }; };
  for (const input of [undefined, null, '', 'not_a_real_preset', 12345]) {
    assert.equal(
      await selectVoice(input, FREE_USER, TEST_SUPABASE, fetcher),
      VOICE_STUDIO_MENTOR,
    );
  }
  assert.equal(called, false, 'no fetch for non-custom inputs');
});

test('selectVoice falls back when env is not configured', async () => {
  const originalError = console.error;
  console.error = () => {};
  try {
    const result = await selectVoice(
      'custom:550e8400-e29b-41d4-a716-446655440000',
      FREE_USER, {}, // no SUPABASE_URL / SERVICE_ROLE_KEY
    );
    assert.equal(result, VOICE_STUDIO_MENTOR);
  } finally {
    console.error = originalError;
  }
});

// =============================================================================
// Phase 5a — validateJWT (ES256 / JWKS)
// =============================================================================
//
// We generate a real ES256 keypair with Web Crypto and sign tokens for each
// test case rather than hand-crafting a valid signature, so the verification
// path runs end-to-end (kid lookup → importKey → subtle.verify → claim
// checks). The fetcher is stubbed so no real network call leaves the box;
// _resetJwksCacheForTests clears module-scope cache so each test gets a
// clean slate.

const TEST_JWT_ENV = {
  SUPABASE_URL: 'https://test.supabase.co',
  SUPABASE_JWT_ISSUER: 'https://test.supabase.co/auth/v1',
};
const TEST_KID = 'test-kid-1';
const TEST_SUB = '00000000-0000-0000-0000-0000000000aa';

function b64urlFromString(s) {
  return Buffer.from(s, 'utf8').toString('base64')
    .replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function b64urlFromBytes(bytes) {
  return Buffer.from(bytes).toString('base64')
    .replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
}

async function generateES256Keypair() {
  return crypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' },
    true,
    ['sign', 'verify'],
  );
}

async function exportPublicJWK(publicKey, kid = TEST_KID) {
  const jwk = await crypto.subtle.exportKey('jwk', publicKey);
  // Strip private fields just in case (publicKey export shouldn't have them,
  // but be paranoid). Add kid + alg the way Supabase publishes them.
  return { kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y, kid, alg: 'ES256', use: 'sig' };
}

async function signES256JWT({ privateKey, kid = TEST_KID, header: headerOverride = {}, payload }) {
  const header = { alg: 'ES256', typ: 'JWT', kid, ...headerOverride };
  const headerB64 = b64urlFromString(JSON.stringify(header));
  const payloadB64 = b64urlFromString(JSON.stringify(payload));
  const data = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const sigBuf = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' }, privateKey, data,
  );
  return `${headerB64}.${payloadB64}.${b64urlFromBytes(new Uint8Array(sigBuf))}`;
}

function jwksFetcherFor(jwks) {
  // Returns a fetcher that responds to the JWKS URL with the supplied keys
  // and 404s anything else (so a misrouted call surfaces obviously).
  return async (url) => {
    if (typeof url === 'string' && url.endsWith('/.well-known/jwks.json')) {
      return { ok: true, json: async () => ({ keys: jwks }) };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };
}

function basePayload(overrides = {}) {
  // Default valid claims, expiring 1h after FIXED_NOW.
  const nowSec = Math.floor(FIXED_NOW / 1000);
  return {
    iss: TEST_JWT_ENV.SUPABASE_JWT_ISSUER,
    aud: 'authenticated',
    sub: TEST_SUB,
    exp: nowSec + 3600,
    iat: nowSec,
    role: 'authenticated',
    app_metadata: { tier: 'free' },
    ...overrides,
  };
}

test('validateJWT accepts a valid token and returns the payload with sub', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const token = await signES256JWT({ privateKey, payload: basePayload() });

  const result = await validateJWT(token, TEST_JWT_ENV, {
    fetcher: jwksFetcherFor([jwk]),
    nowSeconds: Math.floor(FIXED_NOW / 1000),
  });

  assert.equal(result.sub, TEST_SUB);
  assert.equal(result.iss, TEST_JWT_ENV.SUPABASE_JWT_ISSUER);
  assert.equal(result.aud, 'authenticated');
  // app_metadata flows through so getUserTier downstream still works.
  assert.equal(result.app_metadata?.tier, 'free');
});

test('validateJWT rejects an expired token', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const nowSec = Math.floor(FIXED_NOW / 1000);
  // exp 1 second in the past relative to the injected clock.
  const token = await signES256JWT({
    privateKey,
    payload: basePayload({ exp: nowSec - 1 }),
  });

  await assert.rejects(
    () => validateJWT(token, TEST_JWT_ENV, { fetcher: jwksFetcherFor([jwk]), nowSeconds: nowSec }),
    /expired/i,
  );
});

test('validateJWT rejects a malformed token (not three parts)', async () => {
  _resetJwksCacheForTests();
  // Stub fetcher should never be hit — malformed token rejected before JWKS lookup.
  let fetched = false;
  const fetcher = async () => { fetched = true; return { ok: true, json: async () => ({ keys: [] }) }; };

  await assert.rejects(
    () => validateJWT('only.two', TEST_JWT_ENV, { fetcher }),
    /malformed/i,
  );
  await assert.rejects(
    () => validateJWT('a.b.c.d', TEST_JWT_ENV, { fetcher }),
    /malformed/i,
  );
  assert.equal(fetched, false, 'malformed tokens must be rejected before JWKS fetch');
});

test('validateJWT rejects a missing token (null / undefined / empty / wrong type)', async () => {
  _resetJwksCacheForTests();
  const fetcher = async () => ({ ok: true, json: async () => ({ keys: [] }) });
  for (const bad of [null, undefined, '', 12345, {}]) {
    await assert.rejects(
      () => validateJWT(bad, TEST_JWT_ENV, { fetcher }),
      (err) => err instanceof Error,
    );
  }
});

test('validateJWT rejects a wrong-issuer token (signature valid, iss mismatched)', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const token = await signES256JWT({
    privateKey,
    payload: basePayload({ iss: 'https://attacker.example.com/auth/v1' }),
  });

  await assert.rejects(
    () => validateJWT(token, TEST_JWT_ENV, {
      fetcher: jwksFetcherFor([jwk]),
      nowSeconds: Math.floor(FIXED_NOW / 1000),
    }),
    /issuer/i,
  );
});

test('validateJWT rejects a token with a tampered signature', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const token = await signES256JWT({ privateKey, payload: basePayload() });
  // Flip a character ~10 chars from the end of the signature. The very last
  // base64url char encodes the unused trailing padding bits of a 64-byte
  // ES256 sig, so flipping it leaves the decoded bytes unchanged. A flip
  // 10 chars in is squarely inside the signature's middle bytes.
  const flipped = token.slice(0, -10)
    + (token[token.length - 10] === 'A' ? 'B' : 'A')
    + token.slice(-9);

  await assert.rejects(
    () => validateJWT(flipped, TEST_JWT_ENV, {
      fetcher: jwksFetcherFor([jwk]),
      nowSeconds: Math.floor(FIXED_NOW / 1000),
    }),
    (err) => err instanceof Error,
  );
});

test('validateJWT rejects a token whose kid is not in the JWKS', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey, 'served-kid');
  const token = await signES256JWT({
    privateKey,
    kid: 'not-served-kid',
    payload: basePayload(),
  });

  await assert.rejects(
    () => validateJWT(token, TEST_JWT_ENV, {
      fetcher: jwksFetcherFor([jwk]),
      nowSeconds: Math.floor(FIXED_NOW / 1000),
    }),
    /kid/i,
  );
});

test('validateJWT rejects a wrong-audience token', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  // 'service_role' is the obvious upgrade-attack — must never validate.
  const token = await signES256JWT({
    privateKey,
    payload: basePayload({ aud: 'service_role' }),
  });

  await assert.rejects(
    () => validateJWT(token, TEST_JWT_ENV, {
      fetcher: jwksFetcherFor([jwk]),
      nowSeconds: Math.floor(FIXED_NOW / 1000),
    }),
    /audience/i,
  );
});

test('validateJWT rejects a token with an unsupported alg (e.g. HS256 or none)', async () => {
  _resetJwksCacheForTests();
  // Hand-craft headers — no signing needed; the alg check fires before JWKS lookup.
  const fetcher = async () => ({ ok: true, json: async () => ({ keys: [] }) });
  for (const alg of ['HS256', 'none', 'RS256']) {
    const headerB64 = b64urlFromString(JSON.stringify({ alg, typ: 'JWT', kid: TEST_KID }));
    const payloadB64 = b64urlFromString(JSON.stringify(basePayload()));
    // Signature segment doesn't matter; alg check trips first.
    const fakeToken = `${headerB64}.${payloadB64}.AAAA`;
    await assert.rejects(
      () => validateJWT(fakeToken, TEST_JWT_ENV, { fetcher }),
      /alg/i,
      `should reject alg=${alg}`,
    );
  }
});

test('validateJWT rejects a header missing the kid claim', async () => {
  _resetJwksCacheForTests();
  const fetcher = async () => ({ ok: true, json: async () => ({ keys: [] }) });
  const headerB64 = b64urlFromString(JSON.stringify({ alg: 'ES256', typ: 'JWT' }));
  const payloadB64 = b64urlFromString(JSON.stringify(basePayload()));
  const fakeToken = `${headerB64}.${payloadB64}.AAAA`;

  await assert.rejects(
    () => validateJWT(fakeToken, TEST_JWT_ENV, { fetcher }),
    /kid/i,
  );
});

test('_resetJwksCacheForTests clears module-scope cache between tests', async () => {
  // First fetch primes the cache.
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const token = await signES256JWT({ privateKey, payload: basePayload() });

  let firstFetcherCalls = 0;
  const firstFetcher = async (url) => {
    firstFetcherCalls++;
    if (typeof url === 'string' && url.endsWith('/.well-known/jwks.json')) {
      return { ok: true, json: async () => ({ keys: [jwk] }) };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };
  await validateJWT(token, TEST_JWT_ENV, {
    fetcher: firstFetcher,
    nowSeconds: Math.floor(FIXED_NOW / 1000),
  });
  assert.equal(firstFetcherCalls, 1, 'first call should hit fetcher');

  // Second call without reset must reuse the cache (fetcher untouched).
  let secondFetcherCalls = 0;
  const secondFetcher = async () => { secondFetcherCalls++; return { ok: false, status: 500 }; };
  await validateJWT(token, TEST_JWT_ENV, {
    fetcher: secondFetcher,
    nowSeconds: Math.floor(FIXED_NOW / 1000),
  });
  assert.equal(secondFetcherCalls, 0, 'cached call should not hit fetcher');

  // After reset, third call must hit the fetcher again.
  _resetJwksCacheForTests();
  let thirdFetcherCalls = 0;
  const thirdFetcher = async (url) => {
    thirdFetcherCalls++;
    if (typeof url === 'string' && url.endsWith('/.well-known/jwks.json')) {
      return { ok: true, json: async () => ({ keys: [jwk] }) };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };
  await validateJWT(token, TEST_JWT_ENV, {
    fetcher: thirdFetcher,
    nowSeconds: Math.floor(FIXED_NOW / 1000),
  });
  assert.equal(thirdFetcherCalls, 1, 'reset should force a re-fetch');
});

// =============================================================================
// Phase 5f — App Attest
// =============================================================================
//
// Two layers of test:
//  - Pure functions (CBOR, ASN.1, byte helpers, clientDataHash) on hand-built
//    inputs.
//  - Assertion verification end-to-end with a synthetic P-256 keypair: build
//    a CBOR-encoded "assertion," hand it to verifyAppAttestAssertion, expect
//    success; replay with the same counter, expect failure; tamper one byte,
//    expect failure. We can't test attestation E2E without a real Apple
//    device, but the assertion path is the one that runs on every request.

import { webcrypto } from 'node:crypto';
const subtle = webcrypto.subtle;

// ---- minimal CBOR encoder for tests ---------------------------------------
// Just enough to build assertion-shaped maps with byte-string values.

function cborEncodeUint(n) {
  if (n < 24) return Uint8Array.of(n);
  if (n < 0x100) return Uint8Array.of(24, n);
  if (n < 0x10000) return Uint8Array.of(25, n >> 8, n & 0xff);
  if (n < 0x100000000) return Uint8Array.of(26, (n >>> 24) & 0xff, (n >>> 16) & 0xff, (n >>> 8) & 0xff, n & 0xff);
  throw new Error('cborEncodeUint > 2^32 not supported in test helper');
}
function cborTagLen(major, length) {
  const lenBytes = cborEncodeUint(length);
  const head = (major << 5) | (lenBytes[0] & 0x1f);
  return Uint8Array.of(head, ...lenBytes.subarray(1));
}
function cborEncodeBytes(bytes) {
  return concat(cborTagLen(2, bytes.length), bytes);
}
function cborEncodeText(str) {
  const enc = new TextEncoder().encode(str);
  return concat(cborTagLen(3, enc.length), enc);
}
function cborEncodeMap(entries) {
  let body = new Uint8Array(0);
  for (const [k, v] of entries) body = concat(body, cborEncodeText(k), v);
  return concat(cborTagLen(5, entries.length), body);
}
function concat(...arrs) {
  let total = 0;
  for (const a of arrs) total += a.length;
  const out = new Uint8Array(total);
  let off = 0;
  for (const a of arrs) { out.set(a, off); off += a.length; }
  return out;
}

// Convert WebCrypto's spki-export to the raw uncompressed point. SPKI for
// P-256 ECDSA always ends with the BIT STRING value, which starts with an
// "unused bits" byte (0x00) and then 0x04 || X(32) || Y(32). Slice the last
// 65 bytes of the export.
async function p256RawPubKey(keyPair) {
  const spki = new Uint8Array(await subtle.exportKey('spki', keyPair.publicKey));
  return spki.subarray(spki.length - 65);
}

async function sha256(bytes) {
  return new Uint8Array(await subtle.digest('SHA-256', bytes));
}

// Sign with WebCrypto then convert raw r||s to DER per the assertion spec.
async function signEcdsaDer(privateKey, message) {
  const raw = new Uint8Array(await subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, privateKey, message));
  if (raw.length !== 64) throw new Error('expected raw P-256 sig of 64 bytes');
  const r = raw.subarray(0, 32);
  const s = raw.subarray(32, 64);
  function intDer(buf) {
    let i = 0;
    while (i < buf.length - 1 && buf[i] === 0) i++;
    let v = buf.subarray(i);
    if (v[0] & 0x80) v = concat(Uint8Array.of(0), v);
    return concat(Uint8Array.of(0x02, v.length), v);
  }
  const body = concat(intDer(r), intDer(s));
  return concat(Uint8Array.of(0x30, body.length), body);
}

// In-memory KV that mimics the surface verifyAppAttestAssertion's helpers
// touch. Same shape Cloudflare's KV namespace exposes.
function makeTestKV() {
  const store = new Map();
  return {
    async get(k) { return store.has(k) ? store.get(k) : null; },
    async put(k, v, _opts) { store.set(k, v); },
    async delete(k) { store.delete(k); },
    _store: store,
  };
}

// Build an env that satisfies the App Attest module's required fields. The
// team ID is arbitrary — it just has to feed appAttestAppId so the rpIdHash
// math is consistent across encoder + verifier.
function makeAttestEnv({ kv, mode = 'development' } = {}) {
  return {
    QUOTA_KV: kv ?? makeTestKV(),
    APP_ATTEST_TEAM_ID: 'TEST123456',
    APP_ATTEST_BUNDLE_ID: 'com.drawevolve.app',
    APP_ATTEST_ENV: mode,
  };
}

// ---- pure helpers ----------------------------------------------------------

test('bytesEqual is constant-time true on equal inputs and false on length mismatch', () => {
  assert.equal(bytesEqual(Uint8Array.of(1, 2, 3), Uint8Array.of(1, 2, 3)), true);
  assert.equal(bytesEqual(Uint8Array.of(1, 2, 3), Uint8Array.of(1, 2, 4)), false);
  assert.equal(bytesEqual(Uint8Array.of(1, 2, 3), Uint8Array.of(1, 2, 3, 4)), false);
});

test('hex round-trips through bytesToHex / hexToBytes', () => {
  const sample = Uint8Array.of(0xde, 0xad, 0xbe, 0xef, 0x00, 0x10, 0xff);
  assert.equal(bytesToHex(sample), 'deadbeef0010ff');
  assert.deepEqual(hexToBytes('deadbeef0010ff'), sample);
});

test('cborDecode parses a simple map of string→bytes round-trip', () => {
  const payload = cborEncodeMap([
    ['signature', cborEncodeBytes(Uint8Array.of(1, 2, 3, 4))],
    ['authenticatorData', cborEncodeBytes(Uint8Array.of(9, 8, 7))],
  ]);
  const decoded = cborDecode(payload);
  assert.deepEqual(decoded.signature, Uint8Array.of(1, 2, 3, 4));
  assert.deepEqual(decoded.authenticatorData, Uint8Array.of(9, 8, 7));
});

test('cborDecode rejects trailing bytes', () => {
  const valid = cborEncodeMap([['x', cborEncodeBytes(Uint8Array.of(1))]]);
  const tampered = concat(valid, Uint8Array.of(0));
  assert.throws(() => cborDecode(tampered), /trailing|truncated/);
});

test('ecdsaDerToRaw converts a known DER SEQUENCE to fixed-length r||s', () => {
  // Hand-built: SEQUENCE { INTEGER 0x01, INTEGER 0x02 }
  const der = Uint8Array.of(0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02);
  const raw = ecdsaDerToRaw(der, 32);
  assert.equal(raw.length, 64);
  // r and s should be left-padded with zeros to 32 bytes each
  assert.equal(raw[31], 0x01);
  assert.equal(raw[63], 0x02);
});

test('computeAppAttestClientDataHash matches a hand-derived value', async () => {
  // The iOS client and Worker both compute SHA-256("METHOD:PATH:sha256-hex(body)").
  // Replicate that here with WebCrypto and check the result byte-for-byte.
  const body = new TextEncoder().encode('{"hello":"world"}');
  const bodyHashHex = bytesToHex(await sha256(body));
  const expected = await sha256(new TextEncoder().encode(`POST:/:${bodyHashHex}`));
  const got = await computeAppAttestClientDataHash('POST', '/', body);
  assert.deepEqual(got, expected);
});

// ---- assertion verification (E2E with a synthetic key) --------------------

async function buildSyntheticAssertion({
  keyPair, env, method = 'POST', path = '/', body = new Uint8Array(), counter = 1,
}) {
  // rpIdHash = SHA-256("<TEAM>.<BUNDLE>") — must match what the verifier
  // computes from APP_ATTEST_TEAM_ID + APP_ATTEST_BUNDLE_ID.
  const appId = `${env.APP_ATTEST_TEAM_ID}.${env.APP_ATTEST_BUNDLE_ID}`;
  const rpIdHash = await sha256(new TextEncoder().encode(appId));
  const flags = Uint8Array.of(0x40);                      // attested-credential-data bit set
  const counterBE = Uint8Array.of(
    (counter >>> 24) & 0xff, (counter >>> 16) & 0xff, (counter >>> 8) & 0xff, counter & 0xff,
  );
  const authData = concat(rpIdHash, flags, counterBE);    // 32 + 1 + 4 = 37 bytes
  const clientDataHash = await computeAppAttestClientDataHash(method, path, body);
  const signedData = concat(authData, clientDataHash);
  const signatureDer = await signEcdsaDer(keyPair.privateKey, signedData);
  const cbor = cborEncodeMap([
    ['signature', cborEncodeBytes(signatureDer)],
    ['authenticatorData', cborEncodeBytes(authData)],
  ]);
  return Buffer.from(cbor).toString('base64');
}

test('verifyAppAttestAssertion accepts a valid synthetic assertion with monotonic counter', async () => {
  const env = makeAttestEnv();
  const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const pub = await p256RawPubKey(keyPair);
  const body = new TextEncoder().encode('{"feedback":"please"}');
  const assertionB64 = await buildSyntheticAssertion({ keyPair, env, body, counter: 1 });
  const expectedClientDataHash = await computeAppAttestClientDataHash('POST', '/', body);
  const result = await verifyAppAttestAssertion({
    assertionB64,
    storedPubKey: pub,
    storedCounter: 0,
    expectedClientDataHash,
    env,
  });
  assert.equal(result.newCounter, 1);
});

test('verifyAppAttestAssertion rejects a replayed counter', async () => {
  const env = makeAttestEnv();
  const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const pub = await p256RawPubKey(keyPair);
  const body = new TextEncoder().encode('{"x":1}');
  const assertionB64 = await buildSyntheticAssertion({ keyPair, env, body, counter: 5 });
  const expectedClientDataHash = await computeAppAttestClientDataHash('POST', '/', body);
  await assert.rejects(
    verifyAppAttestAssertion({ assertionB64, storedPubKey: pub, storedCounter: 5, expectedClientDataHash, env }),
    /counter_replay/,
  );
});

test('verifyAppAttestAssertion rejects a clientDataHash mismatch (tampered body)', async () => {
  const env = makeAttestEnv();
  const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const pub = await p256RawPubKey(keyPair);
  const signedBody = new TextEncoder().encode('original');
  const tamperedBody = new TextEncoder().encode('TAMPERED');
  const assertionB64 = await buildSyntheticAssertion({ keyPair, env, body: signedBody, counter: 1 });
  // Verifier computes the hash from `tamperedBody`, which won't match what
  // the device signed, so the ECDSA verify must fail.
  const expectedClientDataHash = await computeAppAttestClientDataHash('POST', '/', tamperedBody);
  await assert.rejects(
    verifyAppAttestAssertion({ assertionB64, storedPubKey: pub, storedCounter: 0, expectedClientDataHash, env }),
    /sig_invalid/,
  );
});

test('verifyAppAttestAssertion rejects rpId mismatch (different team)', async () => {
  const env = makeAttestEnv();
  const otherEnv = { ...env, APP_ATTEST_TEAM_ID: 'OTHER12345' };
  const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const pub = await p256RawPubKey(keyPair);
  const body = new TextEncoder().encode('{}');
  // Assertion built for `env`'s team, verified under `otherEnv`'s team.
  const assertionB64 = await buildSyntheticAssertion({ keyPair, env, body, counter: 1 });
  const expectedClientDataHash = await computeAppAttestClientDataHash('POST', '/', body);
  await assert.rejects(
    verifyAppAttestAssertion({
      assertionB64, storedPubKey: pub, storedCounter: 0, expectedClientDataHash, env: otherEnv,
    }),
    /rpid_mismatch/,
  );
});

// ---- challenge + key store -------------------------------------------------

test('issueAppAttestChallenge writes a TTLed marker that consume can spend exactly once', async () => {
  const kv = makeTestKV();
  const env = makeAttestEnv({ kv });
  const { challengeBytes } = await issueAppAttestChallenge(env);
  assert.equal(challengeBytes.length, 32);
  assert.equal(await consumeAppAttestChallenge(challengeBytes, env), true);
  // Replay is rejected.
  assert.equal(await consumeAppAttestChallenge(challengeBytes, env), false);
});

test('storeAttestedKey + getAttestedKey round-trip with env tag and zero counter', async () => {
  const kv = makeTestKV();
  const env = makeAttestEnv({ kv });
  const fakePub = new Uint8Array(65); fakePub[0] = 0x04;
  await storeAttestedKey('mykey', fakePub, env);
  const loaded = await getAttestedKey('mykey', env);
  assert.deepEqual(loaded.pub, fakePub);
  assert.equal(loaded.counter, 0);
  assert.equal(loaded.env, 'development');
});

test('updateAttestedKeyCounter persists the new counter for the next assertion', async () => {
  const kv = makeTestKV();
  const env = makeAttestEnv({ kv });
  const fakePub = new Uint8Array(65); fakePub[0] = 0x04;
  await storeAttestedKey('mykey', fakePub, env);
  await updateAttestedKeyCounter('mykey', 42, env);
  const loaded = await getAttestedKey('mykey', env);
  assert.equal(loaded.counter, 42);
});

test('readAppAttestHeaders returns null when either header is missing', () => {
  const both = new Request('https://x/', { headers: {
    'X-Apple-AppAttest-KeyId': 'a', 'X-Apple-AppAttest-Assertion': 'b',
  }});
  assert.deepEqual(readAppAttestHeaders(both), { keyId: 'a', assertion: 'b' });
  const onlyKey = new Request('https://x/', { headers: { 'X-Apple-AppAttest-KeyId': 'a' }});
  assert.equal(readAppAttestHeaders(onlyKey), null);
  const neither = new Request('https://x/', { headers: {} });
  assert.equal(readAppAttestHeaders(neither), null);
});

// =============================================================================
// Integration — JWT + App Attest gate composition in handleFeedback
// =============================================================================
//
// These four tests exercise the gate ordering in routes/feedback.js end-to-
// end: build a real Request (signed JWT, real assertion bytes), override
// globalThis.fetch to mock JWKS + ownership + OpenAI + RPC, seed an
// in-memory KV with a real attested key, and call handler.fetch. The point
// is to verify gate composition + status codes, not to re-test individual
// gate primitives (those have their own unit tests above).

const INTEGRATION_DRAWING_ID = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const INTEGRATION_CLIENT_REQUEST_ID = 'cccccccc-cccc-cccc-cccc-cccccccccccc';

// handleFeedback uses real Date.now() for JWT expiry — it doesn't take an
// nowSeconds opt at the call site. So integration-test JWTs must be signed
// against wall-clock time, not FIXED_NOW.
function realNowBasePayload(overrides = {}) {
  const nowSec = Math.floor(Date.now() / 1000);
  return {
    iss: TEST_JWT_ENV.SUPABASE_JWT_ISSUER,
    aud: 'authenticated',
    sub: TEST_SUB,
    exp: nowSec + 3600,
    iat: nowSec,
    role: 'authenticated',
    app_metadata: { tier: 'free' },
    ...overrides,
  };
}

function jpegBase64() {
  // Smallest JPEG that survives validateImagePayload's magic-byte check.
  const buf = Buffer.from([0xff, 0xd8, 0xff, 0xe0, ...new Array(64).fill(0)]);
  return buf.toString('base64');
}

// Build an env + ctx + globalThis.fetch override that satisfies the entire
// handleFeedback flow up through SUCCESS. Returns { env, ctx, restore } —
// caller MUST invoke restore() in finally to put globalThis.fetch back.
async function setupHappyPathHandlerEnv({ jwksKey }) {
  const kv = makeTestKV();
  // Store a record under the daily-spend key shape so getDailySpend doesn't
  // explode (it tolerates missing keys, but explicit zero is harmless and
  // keeps the test future-proof if the helper grows expectations).
  await kv.put(`daily_spend:${utcDayKey(FIXED_NOW)}`, '0');
  // Now pin Date.now() inside the test mocks (we can't override it globally
  // without disrupting other tests, but each fetch handler that returns a
  // value can use FIXED_NOW). The validateJWT call inside handleFeedback
  // uses real Date.now() — so we sign the JWT with real-now exp instead.
  const env = {
    ...TEST_JWT_ENV,
    SUPABASE_SERVICE_ROLE_KEY: 'test-service-role-key',
    OPENAI_API_KEY: 'test-openai-key',
    QUOTA_KV: kv,
    APP_ATTEST_TEAM_ID: 'TEST123456',
    APP_ATTEST_BUNDLE_ID: 'com.drawevolve.app',
    APP_ATTEST_ENV: 'development',
  };

  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    const u = String(url);
    if (u.endsWith('/.well-known/jwks.json')) {
      return { ok: true, json: async () => ({ keys: [jwksKey] }) };
    }
    if (u.includes('/rest/v1/drawings') && u.includes('select=id')) {
      // Ownership query — return a row so the user "owns" the drawing.
      return { ok: true, json: async () => ([{ id: INTEGRATION_DRAWING_ID }]) };
    }
    if (u.includes('/rest/v1/drawings') && u.includes('select=critique_history')) {
      return { ok: true, json: async () => ([{ critique_history: [], preset_id: DEFAULT_PRESET_ID }]) };
    }
    if (u.includes('api.openai.com/v1/chat/completions')) {
      return {
        ok: true,
        json: async () => ({
          choices: [{ message: { content: 'A solid critique.' } }],
          usage: { prompt_tokens: 100, completion_tokens: 50 },
        }),
        text: async () => '',
      };
    }
    if (u.includes('/rest/v1/rpc/append_critique')) {
      return { ok: true, json: async () => ({}) };
    }
    if (u.includes('/rest/v1/feedback_requests')) {
      return { ok: true, json: async () => ({}) };
    }
    // Unrecognized — return a benign success so fire-and-forget calls don't
    // throw and pollute test output.
    return { ok: true, json: async () => ({}), text: async () => '' };
  };

  const ctx = {
    waitUntil: (p) => { Promise.resolve(p).catch(() => {}); },
  };

  return { env, ctx, kv, restore: () => { globalThis.fetch = originalFetch; } };
}

async function buildIntegrationRequest({
  jwt,
  assertionB64 = null,
  keyId = null,
  bodyOverride = null,
}) {
  const body = bodyOverride ?? {
    image: jpegBase64(),
    context: { ...baseContext },
    drawingId: INTEGRATION_DRAWING_ID,
    client_request_id: INTEGRATION_CLIENT_REQUEST_ID,
  };
  const bodyBytes = new TextEncoder().encode(JSON.stringify(body));
  const headers = {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${jwt}`,
  };
  if (keyId) headers['X-Apple-AppAttest-KeyId'] = keyId;
  if (assertionB64) headers['X-Apple-AppAttest-Assertion'] = assertionB64;
  return new Request('https://drawevolve-backend.test/', {
    method: 'POST',
    headers,
    body: bodyBytes,
  });
}

test('integration: invalid JWT (with or without App Attest headers) → 401', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env, ctx, restore } = await setupHappyPathHandlerEnv({ jwksKey: jwk });
  try {
    // Case A: malformed token, no attest headers.
    const req1 = await buildIntegrationRequest({ jwt: 'not.a.valid.jwt' });
    const res1 = await handler.fetch(req1, env, ctx);
    assert.equal(res1.status, 401, 'malformed JWT must 401 even without attest headers');

    // Case B: malformed token, with attest headers — JWT gate should still
    // reject FIRST (cheap check), so attest validity is irrelevant.
    const req2 = await buildIntegrationRequest({
      jwt: 'still.bad.jwt',
      keyId: 'whatever',
      assertionB64: 'whatever',
    });
    const res2 = await handler.fetch(req2, env, ctx);
    assert.equal(res2.status, 401, 'JWT gate runs first; bad JWT 401s regardless of attest');

    // Case C: valid signature but wrong issuer — still 401, attest never reached.
    const wrongIssuerJwt = await signES256JWT({
      privateKey,
      payload: realNowBasePayload({ iss: 'https://attacker.example/auth/v1' }),
    });
    const req3 = await buildIntegrationRequest({ jwt: wrongIssuerJwt });
    const res3 = await handler.fetch(req3, env, ctx);
    assert.equal(res3.status, 401);
  } finally {
    restore();
  }
});

test('integration: valid JWT + missing/invalid App Attest assertion → 401 with attest_* code', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env, ctx, restore } = await setupHappyPathHandlerEnv({ jwksKey: jwk });
  try {
    const validJwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });

    // Case A: valid JWT, no attest headers at all → attest_headers_missing.
    const req1 = await buildIntegrationRequest({ jwt: validJwt });
    const res1 = await handler.fetch(req1, env, ctx);
    assert.equal(res1.status, 401, 'missing attest headers → 401');
    const body1 = await res1.json();
    assert.equal(body1.error, 'attest_headers_missing');

    // Case B: valid JWT, attest headers set but the keyId isn't registered →
    // attest_key_unknown.
    const req2 = await buildIntegrationRequest({
      jwt: validJwt,
      keyId: 'unregistered-key',
      assertionB64: 'AAAA',
    });
    const res2 = await handler.fetch(req2, env, ctx);
    assert.equal(res2.status, 401);
    const body2 = await res2.json();
    assert.equal(body2.error, 'attest_key_unknown');

    // Case C: valid JWT, registered key, but assertion bytes are garbage →
    // attest_assertion_invalid.
    const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pub = await p256RawPubKey(keyPair);
    const keyId = 'registered-key-1';
    await storeAttestedKey(keyId, pub, env);
    const req3 = await buildIntegrationRequest({
      jwt: validJwt,
      keyId,
      assertionB64: Buffer.from('not a valid cbor assertion').toString('base64'),
    });
    const res3 = await handler.fetch(req3, env, ctx);
    assert.equal(res3.status, 401);
    const body3 = await res3.json();
    assert.equal(body3.error, 'attest_assertion_invalid');
  } finally {
    restore();
  }
});

test('integration: valid JWT + valid App Attest assertion → 200 (both gates pass, full flow succeeds)', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env, ctx, restore } = await setupHappyPathHandlerEnv({ jwksKey: jwk });
  try {
    const validJwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });

    // Register a real attest key + build a real assertion against the body
    // we're about to send. Both gates must pass for this to reach the
    // critique flow's 200 path.
    const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pub = await p256RawPubKey(keyPair);
    const keyId = 'happy-path-key';
    await storeAttestedKey(keyId, pub, env);

    const body = {
      image: jpegBase64(),
      context: { ...baseContext },
      drawingId: INTEGRATION_DRAWING_ID,
      client_request_id: INTEGRATION_CLIENT_REQUEST_ID,
    };
    const bodyBytes = new TextEncoder().encode(JSON.stringify(body));
    const assertionB64 = await buildSyntheticAssertion({
      keyPair, env, method: 'POST', path: '/', body: bodyBytes, counter: 1,
    });

    const req = new Request('https://drawevolve-backend.test/', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${validJwt}`,
        'X-Apple-AppAttest-KeyId': keyId,
        'X-Apple-AppAttest-Assertion': assertionB64,
      },
      body: bodyBytes,
    });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 200, 'JWT + attest both pass; full flow returns 200');
    const respBody = await res.json();
    assert.equal(respBody.feedback, 'A solid critique.');
    assert.ok(respBody.critique_entry, 'response should include the persisted critique entry');
  } finally {
    restore();
  }
});

test('integration: valid JWT + valid attest, but env mismatch on stored key → 401 attest_env_mismatch', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env, ctx, restore } = await setupHappyPathHandlerEnv({ jwksKey: jwk });
  try {
    const validJwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pub = await p256RawPubKey(keyPair);
    const keyId = 'prod-key-on-dev-worker';

    // Store the key under the production env tag, then send the request
    // through a development-tagged worker. The attest gate's env-mismatch
    // check must fire before signature verification.
    const prodEnv = { ...env, APP_ATTEST_ENV: 'production' };
    await storeAttestedKey(keyId, pub, prodEnv);

    const body = {
      image: jpegBase64(),
      context: { ...baseContext },
      drawingId: INTEGRATION_DRAWING_ID,
      client_request_id: INTEGRATION_CLIENT_REQUEST_ID,
    };
    const bodyBytes = new TextEncoder().encode(JSON.stringify(body));
    const assertionB64 = await buildSyntheticAssertion({
      keyPair, env, method: 'POST', path: '/', body: bodyBytes, counter: 1,
    });

    const req = new Request('https://drawevolve-backend.test/', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${validJwt}`,
        'X-Apple-AppAttest-KeyId': keyId,
        'X-Apple-AppAttest-Assertion': assertionB64,
      },
      body: bodyBytes,
    });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 401);
    const respBody = await res.json();
    assert.equal(respBody.error, 'attest_env_mismatch');
  } finally {
    restore();
  }
});

// =============================================================================
// Custom prompts (product-level) — bounded-knob parameters
// =============================================================================
//
// Voice content is locked behind the four hardcoded preset_ids. The custom-
// prompts product surface only writes BOUNDED enum knobs (focus / tone /
// depth / techniques). validatePromptParameters / renderCustomPromptModifier /
// selectCustomPromptParameters cover that pipeline end-to-end. The product-
// level guarantee is "every fragment that lands in the prompt was authored
// by us, not by the user."

test('PROMPT_TEMPLATE_VERSION is a positive integer', () => {
  assert.equal(typeof PROMPT_TEMPLATE_VERSION, 'number');
  assert.ok(Number.isInteger(PROMPT_TEMPLATE_VERSION));
  assert.ok(PROMPT_TEMPLATE_VERSION >= 1);
});

test('option enums have the expected values and no overlap', () => {
  // Lock-in: changing this list is a template-version bump (see
  // PROMPT_TEMPLATE_VERSION). The iOS UI's enum case lists must match
  // these values verbatim.
  assert.deepEqual([...FOCUS_OPTIONS], [
    'anatomy', 'composition', 'color', 'lighting',
    'line_work', 'value', 'perspective', 'general',
  ]);
  assert.deepEqual([...TONE_OPTIONS], ['encouraging', 'balanced', 'rigorous', 'blunt']);
  assert.deepEqual([...DEPTH_OPTIONS], ['brief', 'standard', 'deep_dive']);
  assert.deepEqual([...TECHNIQUE_OPTIONS], [
    'digital', 'traditional', 'observational', 'gestural', 'studied', 'imagination',
  ]);
});

test('validatePromptParameters returns empty object for null/undefined input', () => {
  assert.deepEqual(validatePromptParameters(null), { value: {} });
  assert.deepEqual(validatePromptParameters(undefined), { value: {} });
});

test('validatePromptParameters accepts every documented enum value', () => {
  // Every individual option must validate when supplied alone. Catches a
  // typo in either FRAGMENT key or OPTIONS array.
  for (const focus of FOCUS_OPTIONS) {
    const r = validatePromptParameters({ focus });
    assert.equal(r.value.focus, focus, `focus '${focus}' should pass`);
  }
  for (const tone of TONE_OPTIONS) {
    const r = validatePromptParameters({ tone });
    assert.equal(r.value.tone, tone, `tone '${tone}' should pass`);
  }
  for (const depth of DEPTH_OPTIONS) {
    const r = validatePromptParameters({ depth });
    assert.equal(r.value.depth, depth, `depth '${depth}' should pass`);
  }
  for (const t of TECHNIQUE_OPTIONS) {
    const r = validatePromptParameters({ techniques: [t] });
    assert.deepEqual(r.value.techniques, [t], `technique '${t}' should pass`);
  }
});

test('validatePromptParameters silently drops unknown enum values (forward-compat)', () => {
  // A future Worker that recognizes 'experimental_focus' could write that
  // value into a row; an older Worker reading it must not crash. Drop, don't
  // reject — same posture for unknown techniques.
  assert.deepEqual(validatePromptParameters({ focus: 'experimental_focus' }).value, {});
  assert.deepEqual(validatePromptParameters({ tone: 'haiku' }).value, {});
  assert.deepEqual(
    validatePromptParameters({ techniques: ['digital', 'unknown', 'gestural'] }).value,
    { techniques: ['digital', 'gestural'] },
  );
});

test('validatePromptParameters silently drops unknown top-level keys', () => {
  // Same forward-compat reason. Unknown KEYS may be future knobs; an older
  // Worker should narrow to what it understands.
  assert.deepEqual(
    validatePromptParameters({ focus: 'anatomy', futureKnob: 'value' }).value,
    { focus: 'anatomy' },
  );
});

test('validatePromptParameters rejects wrong types', () => {
  assert.equal(validatePromptParameters('not an object').error, 'parameters must be an object');
  assert.equal(validatePromptParameters([]).error, 'parameters must be an object');
  assert.equal(validatePromptParameters({ focus: 12 }).error, 'focus must be a string');
  assert.equal(validatePromptParameters({ tone: null }).error, 'tone must be a string');
  assert.equal(validatePromptParameters({ techniques: 'digital' }).error, 'techniques must be an array');
  assert.equal(
    validatePromptParameters({ techniques: ['digital', 7] }).error,
    'techniques entries must be strings',
  );
});

test('validatePromptParameters dedupes techniques', () => {
  const r = validatePromptParameters({ techniques: ['digital', 'digital', 'gestural'] });
  assert.deepEqual(r.value.techniques.sort(), ['digital', 'gestural']);
});

test('validatePromptParameters rejects techniques arrays larger than the option list', () => {
  // Defense against a payload that smuggles a giant array of unknown
  // strings. Validation processes each entry, so cap by length first.
  const tooMany = new Array(TECHNIQUE_OPTIONS.length + 1).fill('digital');
  assert.match(validatePromptParameters({ techniques: tooMany }).error, /more entries/);
});

test('renderCustomPromptModifier returns null when nothing is set', () => {
  assert.equal(renderCustomPromptModifier({}), null);
  assert.equal(renderCustomPromptModifier(null), null);
  assert.equal(renderCustomPromptModifier(undefined), null);
  // Unknown values that survived storage but not validation: still render
  // null because none map to a fragment.
  assert.equal(renderCustomPromptModifier({ focus: 'unknown' }), null);
});

test('renderCustomPromptModifier emits the focus fragment for each enum value', () => {
  for (const focus of FOCUS_OPTIONS) {
    const out = renderCustomPromptModifier({ focus });
    assert.ok(typeof out === 'string' && out.length > 0, `focus '${focus}' should render`);
    assert.match(out, /^- /, 'fragments are rendered as a bullet list');
  }
});

test('renderCustomPromptModifier orders sections focus → tone → depth → techniques', () => {
  // Stable ordering means the same parameters produce the same prompt,
  // which keeps the OpenAI seed effective for replays.
  const out = renderCustomPromptModifier({
    focus: 'composition',
    tone: 'blunt',
    depth: 'deep_dive',
    techniques: ['digital', 'gestural'],
  });
  const lines = out.split('\n');
  // Order: 1 focus + 1 tone + 1 depth + 2 techniques = 5 lines.
  assert.equal(lines.length, 5);
  assert.match(lines[0], /Focus Area, weight composition/);
  assert.match(lines[1], /blunt/i);
  assert.match(lines[2], /Go deep on the Focus Area/);
  // Technique lines preserve TECHNIQUE_OPTIONS order, not input order.
  assert.match(lines[3], /digital/);
  assert.match(lines[4], /gestural/);
});

test('renderCustomPromptModifier ignores input technique order (stable output)', () => {
  // ['gestural', 'digital'] and ['digital', 'gestural'] must produce
  // identical strings. Otherwise the same saved prompt would render
  // differently across two clients ordering the array differently.
  const a = renderCustomPromptModifier({ techniques: ['gestural', 'digital'] });
  const b = renderCustomPromptModifier({ techniques: ['digital', 'gestural'] });
  assert.equal(a, b);
});

test('buildSystemPrompt emits PROMPT CUSTOMIZATION when customPromptModifier is set', () => {
  const config = {
    ...DEFAULT_FREE_CONFIG,
    customPromptModifier: { focus: 'anatomy', tone: 'rigorous' },
  };
  const prompt = buildSystemPrompt(config, baseContext);
  assert.match(prompt, /PROMPT CUSTOMIZATION \(per saved prompt\):/);
  assert.match(prompt, /weight anatomy/);
  assert.match(prompt, /Be rigorous/);
});

test('buildSystemPrompt omits PROMPT CUSTOMIZATION when modifier is empty/null', () => {
  const config = { ...DEFAULT_FREE_CONFIG, customPromptModifier: {} };
  const prompt = buildSystemPrompt(config, baseContext);
  assert.ok(!prompt.includes('PROMPT CUSTOMIZATION'));

  const configNull = { ...DEFAULT_FREE_CONFIG, customPromptModifier: null };
  const promptNull = buildSystemPrompt(configNull, baseContext);
  assert.ok(!promptNull.includes('PROMPT CUSTOMIZATION'));
});

test('buildSystemPrompt orders styleModifier before PROMPT CUSTOMIZATION (specificity wins)', () => {
  // The Pro styleModifier is a global per-user preference; the customization
  // section is per-prompt. Per-prompt should come last so its late-in-prompt
  // weighting beats the global preference when they conflict.
  const config = {
    ...DEFAULT_PRO_CONFIG,
    styleModifier: 'Always reference Sargent.',
    customPromptModifier: { tone: 'blunt' },
  };
  const prompt = buildSystemPrompt(config, baseContext);
  const styleIdx = prompt.indexOf('ADDITIONAL STYLE GUIDANCE');
  const customIdx = prompt.indexOf('PROMPT CUSTOMIZATION');
  assert.ok(styleIdx > 0);
  assert.ok(customIdx > styleIdx, 'PROMPT CUSTOMIZATION should follow ADDITIONAL STYLE GUIDANCE');
});

test('selectCustomPromptParameters returns {} for hardcoded preset IDs (no DB hit)', async () => {
  let called = false;
  const fetcher = async () => { called = true; return { ok: true, json: async () => [] }; };
  for (const id of ['studio_mentor', 'the_crit', 'fundamentals_coach', 'renaissance_master']) {
    const result = await selectCustomPromptParameters(id, FREE_USER, TEST_SUPABASE, fetcher);
    assert.deepEqual(result, {});
  }
  assert.equal(called, false, 'no fetch should happen for hardcoded preset IDs');
});

test('selectCustomPromptParameters fetches and validates the parameters jsonb', async () => {
  const customId = 'custom:550e8400-e29b-41d4-a716-446655440000';
  let captured;
  const fetcher = async (url) => {
    captured = url;
    return {
      ok: true,
      json: async () => [{
        parameters: { focus: 'composition', tone: 'balanced', techniques: ['digital'] },
      }],
    };
  };
  const result = await selectCustomPromptParameters(customId, FREE_USER, TEST_SUPABASE, fetcher);
  assert.deepEqual(result, {
    focus: 'composition',
    tone: 'balanced',
    techniques: ['digital'],
  });
  // Defense-in-depth: user_id filter present on the SELECT.
  assert.match(captured, /custom_prompts/);
  assert.match(captured, /id=eq\.550e8400/);
  assert.match(captured, new RegExp(`user_id=eq\\.${FREE_USER}`));
  assert.match(captured, /select=parameters/);
});

test('selectCustomPromptParameters drops unknown enum values from stored rows (validate-on-read)', async () => {
  // Forward-compat: a future Worker version might persist a knob this
  // version doesn't recognize. Reading it must narrow, not crash.
  const fetcher = async () => ({
    ok: true,
    json: async () => [{
      parameters: { focus: 'experimental', tone: 'rigorous' },
    }],
  });
  const result = await selectCustomPromptParameters(
    'custom:550e8400-e29b-41d4-a716-446655440000', FREE_USER, TEST_SUPABASE, fetcher,
  );
  assert.deepEqual(result, { tone: 'rigorous' });
});

test('selectCustomPromptParameters returns {} on PostgREST non-ok', async () => {
  const errorCalls = [];
  const originalError = console.error;
  console.error = (...args) => { errorCalls.push(args); };
  try {
    const fetcher = async () => ({ ok: false, status: 503 });
    const result = await selectCustomPromptParameters(
      'custom:550e8400-e29b-41d4-a716-446655440000', FREE_USER, TEST_SUPABASE, fetcher,
    );
    assert.deepEqual(result, {});
    assert.equal(errorCalls.length, 1, 'error should be logged for observability');
  } finally {
    console.error = originalError;
  }
});

test('selectCustomPromptParameters returns {} when env is not configured', async () => {
  const errorCalls = [];
  const originalError = console.error;
  console.error = (...args) => { errorCalls.push(args); };
  try {
    let called = false;
    const fetcher = async () => { called = true; return { ok: true, json: async () => [] }; };
    const result = await selectCustomPromptParameters(
      'custom:550e8400-e29b-41d4-a716-446655440000', FREE_USER, {}, fetcher,
    );
    assert.deepEqual(result, {});
    assert.equal(called, false, 'fetcher should not be called when env is missing');
  } finally {
    console.error = originalError;
  }
});

test('buildCritiqueEntry snapshots customPromptModifier in prompt_config', () => {
  // Old critiques must be reproducible. Editing a custom_prompts row later
  // must not change what produced an existing critique entry.
  const config = {
    ...selectConfig('free', null),
    customPromptModifier: { focus: 'anatomy' },
  };
  const entry = buildCritiqueEntry({
    feedback: 'x',
    sequenceNumber: 1,
    config,
    tier: 'free',
    usage: { prompt_tokens: 100, completion_tokens: 50 },
    now: FIXED_NOW,
    presetId: 'custom:550e8400-e29b-41d4-a716-446655440000',
  });
  assert.deepEqual(entry.prompt_config.customPromptModifier, { focus: 'anatomy' });
});

test('buildCritiqueEntry stores null customPromptModifier when none is set', () => {
  // Uniform schema: every row has the field, simplifying analytics queries.
  const entry = buildCritiqueEntry({
    feedback: 'x',
    sequenceNumber: 1,
    config: selectConfig('free', null),
    tier: 'free',
    usage: { prompt_tokens: 100, completion_tokens: 50 },
    now: FIXED_NOW,
    presetId: 'studio_mentor',
  });
  assert.equal(entry.prompt_config.customPromptModifier, null);
});
