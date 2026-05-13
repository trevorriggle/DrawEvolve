import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import {
  fetchProfileByUserId,
  fetchProfileByUsername,
  patchProfile,
  enforceSearchRateLimit,
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
  EVE_PERSONA,
  EVE_PERSONA_VERSION,
  EVE_PRODUCT_CONTEXT,
  EVE_PRODUCT_CONTEXT_VERSION,
  buildEveSystemPrompt,
  buildEveMessages,
  renderCoachingContextBlock,
  parseCritiqueSummary,
  fetchCoachingContext,
  handleRecommendations,
  isRecommendationsEnabled,
  RECOMMENDATIONS_SYSTEM_PROMPT,
  RECOMMENDATIONS_PROMPT_VERSION,
  buildRecommendationsUserMessage,
  RECOMMENDATIONS_SCHEMA,
  validateRecommendations,
  handlePalettes,
  normalizeHexColor,
  validatePaletteName,
  validateColors,
  validatePalettePayload,
  PALETTES_VALIDATION_CONSTANTS,
  EVE_TIER_LIMITS,
  readEveTierLimits,
  readEveMaxTurnsPerConversation,
  enforceEveRateLimits,
  recordSuccessfulEveTurn,
  createConversation,
  getConversation,
  listConversations,
  softDeleteConversation,
  appendMessage,
  getConversationHistory,
  findMessageByClientRequestId,
  fetchCritiqueForConversation,
  handleEve,
  HISTORY_FRAMING_DEFAULT,
  REGISTRY_FRAMING,
  REGISTRY_MIN_ROWS,
  formatRegistryEntries,
  formatRelativeTime,
  fetchUserDrawingRegistry,
  isCrossDrawingContextEnabled,
  fetchCrossDrawingPreference,
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
  CRITIQUE_CATEGORIES,
  SEVERITY_MIN,
  SEVERITY_MAX,
  classifyCritique,
  CLASSIFIER_MODEL,
  CLASSIFIER_VERSION,
  flattenCritiques,
  selectWindow,
  determineStatus,
  computeStreak,
  buildEvolutionResponseV2,
  buildSummary,
  buildReel,
  buildThemes,
  buildStats,
  buildTaggedCritiques,
  extractExcerpt,
  SOLID_FOUNDATION_CEILING,
  MEANINGFUL_DELTA,
  MIN_DATA_POINTS_GROWING,
  PRIMARY_WEIGHT,
  SECONDARY_WEIGHT,
  DEFAULT_WINDOW_CRITIQUES,
  DEFAULT_WINDOW_DAYS,
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
// Phase A — profiles foundation
// =============================================================================
//
// Unit tests for the helpers in routes/profiles.js (rate limit + REST
// wrappers) and integration tests for the five Phase A endpoints. The
// integration tests reuse the JWT + App Attest scaffolding from the
// feedback integration block above.

test('enforceSearchRateLimit allows requests under the cap and rejects at the cap', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  const userId = FREE_USER;

  // 60 attempts in the window — at the cap.
  const first = await enforceSearchRateLimit({ env, userId, now: FIXED_NOW });
  assert.equal(first.ok, true);

  // Pre-seed the KV at the cap and check the next attempt rejects.
  const stamps = Array.from({ length: 60 }, (_, i) => FIXED_NOW - 1000 - i * 10);
  await kv.put(`searchlimit:${userId}`, JSON.stringify(stamps), { expirationTtl: 120 });

  const decision = await enforceSearchRateLimit({ env, userId, now: FIXED_NOW });
  assert.equal(decision.ok, false);
  assert.equal(decision.limit, 60);
  assert.equal(decision.used, 60);
  assert.ok(decision.retryAfter >= 1 && decision.retryAfter <= 60);
});

test('enforceSearchRateLimit recovers once stamps fall outside the 60s window', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  const userId = FREE_USER;
  // 60 stamps but all are 90s old — outside the rolling 60s window.
  const stamps = Array.from({ length: 60 }, (_, i) => FIXED_NOW - 90_000 - i * 10);
  await kv.put(`searchlimit:${userId}`, JSON.stringify(stamps), { expirationTtl: 120 });

  const decision = await enforceSearchRateLimit({ env, userId, now: FIXED_NOW });
  assert.equal(decision.ok, true);
});

test('enforceSearchRateLimit treats malformed KV state as empty', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  await kv.put(`searchlimit:${FREE_USER}`, 'not-json', { expirationTtl: 120 });
  const decision = await enforceSearchRateLimit({ env, userId: FREE_USER, now: FIXED_NOW });
  assert.equal(decision.ok, true);
});

test('fetchProfileByUserId returns the row from PostgREST, or null when no match', async () => {
  const env = {
    SUPABASE_URL: 'https://test.supabase.co',
    SUPABASE_SERVICE_ROLE_KEY: 'sr-key',
  };
  let capturedUrl = null;
  const fetcher = async (url) => {
    capturedUrl = String(url);
    return { ok: true, json: async () => ([{ user_id: TEST_SUB, username: 'alice', display_name: 'Alice', is_public: true }]) };
  };
  const row = await fetchProfileByUserId(env, TEST_SUB, fetcher);
  assert.equal(row.username, 'alice');
  assert.match(capturedUrl, /\/rest\/v1\/profiles/);
  assert.match(capturedUrl, new RegExp(`user_id=eq\\.${TEST_SUB}`));

  const empty = async () => ({ ok: true, json: async () => [] });
  assert.equal(await fetchProfileByUserId(env, TEST_SUB, empty), null);
});

test('fetchProfileByUsername strips username_set_at from public lookup shape', async () => {
  const env = {
    SUPABASE_URL: 'https://test.supabase.co',
    SUPABASE_SERVICE_ROLE_KEY: 'sr-key',
  };
  let capturedUrl = null;
  const fetcher = async (url) => {
    capturedUrl = String(url);
    return { ok: true, json: async () => ([{ user_id: TEST_SUB, username: 'alice', display_name: 'Alice', is_public: true, is_searchable: true, follower_count: 0, following_count: 0, post_count: 0, created_at: '2026-05-01T00:00:00Z' }]) };
  };
  const row = await fetchProfileByUsername(env, 'alice', fetcher);
  assert.equal(row.username, 'alice');
  // Internal column must not be in the select list — guards against a future
  // edit accidentally exposing username_set_at on public profile reads.
  assert.ok(!/username_set_at/.test(capturedUrl), 'username_set_at must not appear in select for public lookups');
});

test('patchProfile maps a 409 response to an error with code=username_taken', async () => {
  const env = {
    SUPABASE_URL: 'https://test.supabase.co',
    SUPABASE_SERVICE_ROLE_KEY: 'sr-key',
  };
  const fetcher = async () => ({ ok: false, status: 409, text: async () => 'duplicate key' });
  await assert.rejects(
    () => patchProfile(env, TEST_SUB, { username: 'taken' }, fetcher),
    (err) => err.code === 'username_taken',
  );
});

// =============================================================================
// Profiles integration tests
// =============================================================================

const PROFILE_HANDLE = 'alice';

// In-memory profile state shared across mocked Supabase calls inside a single
// test. The fake-fetcher reads/writes this to mimic enough of PostgREST for
// the route handler to drive its end-to-end flow without a real Supabase.
function makeProfileState(seed = {}) {
  return {
    user_id: TEST_SUB,
    username: 'user_00000000',
    display_name: 'Alice',
    bio: null,
    avatar_path: null,
    is_public: true,
    is_searchable: true,
    follower_count: 0,
    following_count: 0,
    post_count: 0,
    created_at: '2026-05-01T00:00:00Z',
    username_set_at: null,
    ...seed,
  };
}

// Build env + ctx + globalThis.fetch override for profile integration tests.
// The fetcher mocks JWKS, the profiles table (read + patch + insert), the
// search query, and the storage signed-upload endpoint. Tests can pass
// `profileSeed` to start with a non-default row, and `searchResults` to
// stub the search query response.
async function setupProfileEnv({ jwksKey, profileSeed = {}, searchResults = null, signedUploadResponse = null, conflictOnPatch = false } = {}) {
  const kv = makeTestKV();
  const env = {
    ...TEST_JWT_ENV,
    SUPABASE_SERVICE_ROLE_KEY: 'test-service-role-key',
    QUOTA_KV: kv,
    APP_ATTEST_TEAM_ID: 'TEST123456',
    APP_ATTEST_BUNDLE_ID: 'com.drawevolve.app',
    APP_ATTEST_ENV: 'development',
  };

  const state = { profile: makeProfileState(profileSeed), patches: [] };

  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const method = (init.method ?? 'GET').toUpperCase();
    if (u.endsWith('/.well-known/jwks.json')) {
      return { ok: true, json: async () => ({ keys: [jwksKey] }) };
    }
    // Profile read by user_id.
    if (u.includes('/rest/v1/profiles') && u.includes('user_id=eq.') && method === 'GET') {
      return { ok: true, json: async () => (state.profile ? [state.profile] : []) };
    }
    // Profile read by username.
    if (u.includes('/rest/v1/profiles') && u.includes('username=eq.') && method === 'GET') {
      const m = u.match(/username=eq\.([^&]+)/);
      const requested = decodeURIComponent(m?.[1] ?? '').toLowerCase();
      if (state.profile && state.profile.username.toLowerCase() === requested) {
        return { ok: true, json: async () => [state.profile] };
      }
      return { ok: true, json: async () => [] };
    }
    // Profile search.
    if (u.includes('/rest/v1/profiles') && u.includes('or=(') && method === 'GET') {
      const rows = searchResults ?? [];
      return { ok: true, json: async () => rows };
    }
    // Profile insert (lazy-create on first GET /v1/me).
    if (u.endsWith('/rest/v1/profiles') && method === 'POST') {
      const body = init.body ? JSON.parse(init.body) : {};
      state.profile = makeProfileState(body);
      return { ok: true, json: async () => [state.profile] };
    }
    // Profile patch.
    if (u.includes('/rest/v1/profiles') && method === 'PATCH') {
      if (conflictOnPatch) {
        return { ok: false, status: 409, text: async () => 'duplicate key' };
      }
      const patch = init.body ? JSON.parse(init.body) : {};
      state.patches.push(patch);
      state.profile = { ...state.profile, ...patch };
      return { ok: true, json: async () => [state.profile] };
    }
    // Storage signed upload URL.
    if (u.includes('/storage/v1/object/upload/sign/avatars/')) {
      if (signedUploadResponse) return signedUploadResponse;
      return {
        ok: true,
        json: async () => ({
          url: `/object/upload/sign/avatars/${TEST_SUB}/avatar.jpg`,
          token: 'signed-upload-token-xyz',
        }),
      };
    }
    return { ok: true, json: async () => ({}), text: async () => '' };
  };

  const ctx = { waitUntil: (p) => { Promise.resolve(p).catch(() => {}); } };
  return {
    env,
    ctx,
    state,
    restore: () => { globalThis.fetch = originalFetch; },
  };
}

async function buildAuthedRequest({
  method,
  path,
  jwt,
  keyPair,
  attestKeyId,
  body = null,
}) {
  const url = `https://drawevolve-backend.test${path}`;
  const bodyBytes = body ? new TextEncoder().encode(JSON.stringify(body)) : new Uint8Array(0);
  const headers = {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${jwt}`,
  };
  // App Attest must always be present — every Phase A route requires it.
  if (keyPair && attestKeyId) {
    const env = { APP_ATTEST_TEAM_ID: 'TEST123456', APP_ATTEST_BUNDLE_ID: 'com.drawevolve.app' };
    const pathOnly = new URL(url).pathname || '/';
    const assertionB64 = await buildSyntheticAssertion({
      keyPair, env, method, path: pathOnly, body: bodyBytes, counter: 1,
    });
    headers['X-Apple-AppAttest-KeyId'] = attestKeyId;
    headers['X-Apple-AppAttest-Assertion'] = assertionB64;
  }
  return new Request(url, {
    method,
    headers,
    body: method === 'GET' || method === 'HEAD' ? undefined : bodyBytes,
  });
}

test('GET /v1/me with no Authorization header → 401', async () => {
  _resetJwksCacheForTests();
  const { privateKey: _pk, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env, ctx, restore } = await setupProfileEnv({ jwksKey: jwk });
  try {
    const req = new Request('https://drawevolve-backend.test/v1/me', { method: 'GET' });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 401);
  } finally {
    restore();
  }
});

test('GET /v1/me with invalid JWT → 401, never reaches App Attest', async () => {
  _resetJwksCacheForTests();
  const { publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env, ctx, restore } = await setupProfileEnv({ jwksKey: jwk });
  try {
    const req = new Request('https://drawevolve-backend.test/v1/me', {
      method: 'GET',
      headers: { Authorization: 'Bearer not.a.real.jwt' },
    });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 401);
  } finally {
    restore();
  }
});

test('GET /v1/me valid JWT but missing App Attest headers → 401 attest_headers_missing', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env, ctx, restore } = await setupProfileEnv({ jwksKey: jwk });
  try {
    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const req = new Request('https://drawevolve-backend.test/v1/me', {
      method: 'GET',
      headers: { Authorization: `Bearer ${jwt}` },
    });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 401);
    assert.equal((await res.json()).error, 'attest_headers_missing');
  } finally {
    restore();
  }
});

test('GET /v1/me happy path → 200 returns profile + tier + username_set flag', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env, ctx, restore } = await setupProfileEnv({ jwksKey: jwk });
  try {
    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pub = await p256RawPubKey(keyPair);
    const keyId = 'me-key';
    await storeAttestedKey(keyId, pub, env);

    const req = await buildAuthedRequest({
      method: 'GET', path: '/v1/me', jwt, keyPair, attestKeyId: keyId,
    });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.profile.user_id, TEST_SUB);
    assert.equal(body.tier, 'free');
    assert.equal(body.username_set, false, 'auto-generated username has username_set_at = null');
    // username_set_at must NOT leak into the response shape.
    assert.equal(body.profile.username_set_at, undefined);
  } finally {
    restore();
  }
});

test('PATCH /v1/profiles/me updates display_name + bio and reflects new values', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env, ctx, restore, state } = await setupProfileEnv({ jwksKey: jwk });
  try {
    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pub = await p256RawPubKey(keyPair);
    const keyId = 'patch-key';
    await storeAttestedKey(keyId, pub, env);

    const req = await buildAuthedRequest({
      method: 'PATCH',
      path: '/v1/profiles/me',
      jwt,
      keyPair,
      attestKeyId: keyId,
      body: { display_name: 'Alice Renamed', bio: 'Painter, mostly oils.' },
    });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.profile.display_name, 'Alice Renamed');
    assert.equal(body.profile.bio, 'Painter, mostly oils.');
    // The patch payload must NOT have included username (only changed fields).
    assert.ok(!('username' in (state.patches[0] ?? {})));
    assert.ok(!('username_set_at' in (state.patches[0] ?? {})));
  } finally {
    restore();
  }
});

test('PATCH /v1/profiles/me rejects display_name over 50 chars with invalid_display_name', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env, ctx, restore } = await setupProfileEnv({ jwksKey: jwk });
  try {
    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pub = await p256RawPubKey(keyPair);
    const keyId = 'patch-len';
    await storeAttestedKey(keyId, pub, env);

    const req = await buildAuthedRequest({
      method: 'PATCH', path: '/v1/profiles/me', jwt, keyPair, attestKeyId: keyId,
      body: { display_name: 'a'.repeat(51) },
    });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 400);
    assert.equal((await res.json()).error, 'invalid_display_name');
  } finally {
    restore();
  }
});

test('PATCH /v1/profiles/me first username set succeeds and stamps username_set_at', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env, ctx, restore, state } = await setupProfileEnv({ jwksKey: jwk });
  try {
    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pub = await p256RawPubKey(keyPair);
    const keyId = 'patch-username';
    await storeAttestedKey(keyId, pub, env);

    const req = await buildAuthedRequest({
      method: 'PATCH', path: '/v1/profiles/me', jwt, keyPair, attestKeyId: keyId,
      body: { username: 'alice_paints' },
    });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.profile.username, 'alice_paints');
    // The patch payload must include username_set_at — that's the lock.
    assert.ok('username_set_at' in state.patches[0], 'first username set must stamp username_set_at');
  } finally {
    restore();
  }
});

test('PATCH /v1/profiles/me second username change → 409 username_immutable', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  // Seed the row as if username has already been set once.
  const { env, ctx, restore } = await setupProfileEnv({
    jwksKey: jwk,
    profileSeed: { username: 'alice_paints', username_set_at: '2026-05-02T00:00:00Z' },
  });
  try {
    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pub = await p256RawPubKey(keyPair);
    const keyId = 'second-username';
    await storeAttestedKey(keyId, pub, env);

    const req = await buildAuthedRequest({
      method: 'PATCH', path: '/v1/profiles/me', jwt, keyPair, attestKeyId: keyId,
      body: { username: 'alice2' },
    });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 409);
    assert.equal((await res.json()).error, 'username_immutable');
  } finally {
    restore();
  }
});

test('PATCH /v1/profiles/me with malformed username → 400 invalid_username_format', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env, ctx, restore } = await setupProfileEnv({ jwksKey: jwk });
  try {
    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pub = await p256RawPubKey(keyPair);
    const keyId = 'bad-username';
    await storeAttestedKey(keyId, pub, env);

    const req = await buildAuthedRequest({
      method: 'PATCH', path: '/v1/profiles/me', jwt, keyPair, attestKeyId: keyId,
      body: { username: 'has spaces' },
    });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 400);
    assert.equal((await res.json()).error, 'invalid_username_format');
  } finally {
    restore();
  }
});

test('PATCH /v1/profiles/me when username already taken → 409 username_taken', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env, ctx, restore } = await setupProfileEnv({
    jwksKey: jwk,
    conflictOnPatch: true,
  });
  try {
    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pub = await p256RawPubKey(keyPair);
    const keyId = 'conflict-username';
    await storeAttestedKey(keyId, pub, env);

    const req = await buildAuthedRequest({
      method: 'PATCH', path: '/v1/profiles/me', jwt, keyPair, attestKeyId: keyId,
      body: { username: 'alice' },
    });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 409);
    assert.equal((await res.json()).error, 'username_taken');
  } finally {
    restore();
  }
});

test('PATCH /v1/profiles/me rejects avatar_path that points outside the requester’s folder', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env, ctx, restore } = await setupProfileEnv({ jwksKey: jwk });
  try {
    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pub = await p256RawPubKey(keyPair);
    const keyId = 'cross-user-avatar';
    await storeAttestedKey(keyId, pub, env);

    // Path under a different user's folder. Even if Storage RLS would block
    // the upload itself, the Worker must reject the metadata stamp so iOS
    // can't claim a victim's avatar by stamping the path on its own profile.
    const otherUser = '00000000-0000-0000-0000-000000000099';
    const req = await buildAuthedRequest({
      method: 'PATCH', path: '/v1/profiles/me', jwt, keyPair, attestKeyId: keyId,
      body: { avatar_path: `${otherUser}/avatar.jpg` },
    });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 400);
    assert.equal((await res.json()).error, 'invalid_avatar_path');
  } finally {
    restore();
  }
});

test('POST /v1/profiles/me/avatar returns a Supabase signed upload URL + token', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env, ctx, restore } = await setupProfileEnv({ jwksKey: jwk });
  try {
    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pub = await p256RawPubKey(keyPair);
    const keyId = 'avatar-key';
    await storeAttestedKey(keyId, pub, env);

    const req = await buildAuthedRequest({
      method: 'POST', path: '/v1/profiles/me/avatar', jwt, keyPair, attestKeyId: keyId,
      body: {},
    });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.bucket, 'avatars');
    assert.equal(body.path, `${TEST_SUB}/avatar.jpg`);
    assert.equal(body.token, 'signed-upload-token-xyz');
    assert.match(body.uploadUrl, /\/storage\/v1\//);
  } finally {
    restore();
  }
});

test('GET /v1/profiles/:username resolves a public profile by exact handle', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env, ctx, restore } = await setupProfileEnv({
    jwksKey: jwk,
    profileSeed: { username: PROFILE_HANDLE, is_public: true },
  });
  try {
    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pub = await p256RawPubKey(keyPair);
    const keyId = 'lookup-key';
    await storeAttestedKey(keyId, pub, env);

    const req = await buildAuthedRequest({
      method: 'GET', path: `/v1/profiles/${PROFILE_HANDLE}`, jwt, keyPair, attestKeyId: keyId,
    });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.profile.username, PROFILE_HANDLE);
  } finally {
    restore();
  }
});

test('GET /v1/profiles/:username resolves an unsearchable but public profile (Q4 default)', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env, ctx, restore } = await setupProfileEnv({
    jwksKey: jwk,
    profileSeed: { username: 'shy_user', is_public: true, is_searchable: false },
  });
  try {
    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pub = await p256RawPubKey(keyPair);
    const keyId = 'unsearchable-lookup';
    await storeAttestedKey(keyId, pub, env);

    const req = await buildAuthedRequest({
      method: 'GET', path: '/v1/profiles/shy_user', jwt, keyPair, attestKeyId: keyId,
    });
    const res = await handler.fetch(req, env, ctx);
    // Direct lookup works even though search would hide this profile.
    assert.equal(res.status, 200);
  } finally {
    restore();
  }
});

test('GET /v1/profiles/:username 404s a private profile owned by someone else', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  // Profile is owned by a DIFFERENT user (not TEST_SUB) and is_public=false.
  const { env, ctx, restore } = await setupProfileEnv({
    jwksKey: jwk,
    profileSeed: {
      user_id: '00000000-0000-0000-0000-0000000000bb',
      username: 'private_alice',
      is_public: false,
    },
  });
  try {
    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pub = await p256RawPubKey(keyPair);
    const keyId = 'private-lookup';
    await storeAttestedKey(keyId, pub, env);

    const req = await buildAuthedRequest({
      method: 'GET', path: '/v1/profiles/private_alice', jwt, keyPair, attestKeyId: keyId,
    });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 404);
  } finally {
    restore();
  }
});

test('GET /v1/profiles/search returns paginated results and a next cursor', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const fullPage = Array.from({ length: 20 }, (_, i) => ({
    user_id: `00000000-0000-0000-0000-${String(i).padStart(12, '0')}`,
    username: `user${i}`,
    display_name: `User ${i}`,
    avatar_path: null,
    follower_count: 100 - i,
  }));
  const { env, ctx, restore } = await setupProfileEnv({
    jwksKey: jwk,
    searchResults: fullPage,
  });
  try {
    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pub = await p256RawPubKey(keyPair);
    const keyId = 'search-key';
    await storeAttestedKey(keyId, pub, env);

    const req = await buildAuthedRequest({
      method: 'GET', path: '/v1/profiles/search?q=user', jwt, keyPair, attestKeyId: keyId,
    });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.results.length, 20);
    assert.equal(body.cursor, '20', 'full page implies a next cursor');
  } finally {
    restore();
  }
});

test('GET /v1/profiles/search rejects empty q with 400 invalid_query', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env, ctx, restore } = await setupProfileEnv({ jwksKey: jwk });
  try {
    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pub = await p256RawPubKey(keyPair);
    const keyId = 'empty-q';
    await storeAttestedKey(keyId, pub, env);

    const req = await buildAuthedRequest({
      method: 'GET', path: '/v1/profiles/search?q=', jwt, keyPair, attestKeyId: keyId,
    });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 400);
    assert.equal((await res.json()).error, 'invalid_query');
  } finally {
    restore();
  }
});

test('GET /v1/profiles/search returns 429 when the per-user search rate limit is full', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env, ctx, restore } = await setupProfileEnv({
    jwksKey: jwk,
    searchResults: [],
  });
  try {
    // Pre-populate the search rate-limit KV at exactly the cap so the next
    // request rejects without depending on real-time behavior.
    const stamps = Array.from({ length: 60 }, (_, i) => Date.now() - 1000 - i * 10);
    await env.QUOTA_KV.put(`searchlimit:${TEST_SUB}`, JSON.stringify(stamps), { expirationTtl: 120 });

    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const keyPair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pub = await p256RawPubKey(keyPair);
    const keyId = 'rate-search';
    await storeAttestedKey(keyId, pub, env);

    const req = await buildAuthedRequest({
      method: 'GET', path: '/v1/profiles/search?q=alice', jwt, keyPair, attestKeyId: keyId,
    });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 429);
    const body = await res.json();
    assert.equal(body.error, 'search_rate_limited');
    assert.ok(body.retryAfter > 0);
    assert.ok(res.headers.get('Retry-After'));
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

// =============================================================================
// Feature 1, Phase 1A — cross-drawing iterative coaching
// =============================================================================
//
// Three layers exercised here:
//   1. formatRelativeTime — pure bucket boundaries, no clock.
//   2. formatRegistryEntries — row rendering with fallback chain
//      (focus_area_text → primary_category → "previous critique exists",
//       plus "no critique yet" for in-progress drawings).
//   3. buildUserMessage with the new fourth `registry` argument:
//      sub-floor / at-floor / mixed / interaction with same-drawing history.
//   4. fetchUserDrawingRegistry — query shape + projection + graceful
//      failure (empty array on non-ok, throw, missing env).
//   5. fetchCrossDrawingPreference + isCrossDrawingContextEnabled — the
//      two-gate machinery on the wire.
//   6. buildCritiqueEntry — telemetry fields land in prompt_config.
//   7. Handler integration: env kill-switch off → no registry/pref reads,
//      persisted entry records crossDrawingContextEnabled=false +
//      includeRegistryCount=0.

// ---- formatRelativeTime -----------------------------------------------------

test('formatRelativeTime buckets match the approved spec exactly', () => {
  const now = Date.UTC(2026, 4, 13, 12, 0, 0); // 2026-05-13T12:00:00Z
  const days = (n) => now - n * 24 * 60 * 60 * 1000;

  assert.equal(formatRelativeTime(days(0), now),   'today');
  assert.equal(formatRelativeTime(days(1), now),   'yesterday');
  assert.equal(formatRelativeTime(days(2), now),   '2 days ago');
  assert.equal(formatRelativeTime(days(6), now),   '6 days ago');
  assert.equal(formatRelativeTime(days(7), now),   'last week');
  assert.equal(formatRelativeTime(days(13), now),  'last week');
  assert.equal(formatRelativeTime(days(14), now),  '2 weeks ago');
  assert.equal(formatRelativeTime(days(21), now),  '3 weeks ago');
  assert.equal(formatRelativeTime(days(29), now),  '4 weeks ago');
  assert.equal(formatRelativeTime(days(30), now),  'last month');
  assert.equal(formatRelativeTime(days(59), now),  'last month');
  assert.equal(formatRelativeTime(days(60), now),  '2 months ago');
  assert.equal(formatRelativeTime(days(364), now), '12 months ago');
  assert.equal(formatRelativeTime(days(365), now), 'over a year ago');
  assert.equal(formatRelativeTime(days(1000), now),'over a year ago');
});

test('formatRelativeTime accepts ISO strings, numbers, and Date instances', () => {
  const now = Date.UTC(2026, 4, 13, 12, 0, 0);
  const threeDaysAgoIso = new Date(now - 3 * 24 * 60 * 60 * 1000).toISOString();
  assert.equal(formatRelativeTime(threeDaysAgoIso, now), '3 days ago');
  assert.equal(formatRelativeTime(now - 3 * 24 * 60 * 60 * 1000, now), '3 days ago');
  assert.equal(formatRelativeTime(new Date(now - 3 * 24 * 60 * 60 * 1000), now), '3 days ago');
});

test('formatRelativeTime falls back to "recently" on malformed input', () => {
  assert.equal(formatRelativeTime(undefined),        'recently');
  assert.equal(formatRelativeTime(null),             'recently');
  assert.equal(formatRelativeTime(''),               'recently');
  assert.equal(formatRelativeTime('not a date'),     'recently');
  // Negative diff (future date) → also "recently" — defensive but it would
  // be weird to label a future row "in 3 days from now" inside a coach prompt.
  const now = Date.UTC(2026, 4, 13, 12, 0, 0);
  const future = now + 5 * 24 * 60 * 60 * 1000;
  assert.equal(formatRelativeTime(future, now), 'recently');
});

// ---- formatRegistryEntries --------------------------------------------------

function registryRow(overrides = {}) {
  return {
    drawing_id: 'd-1',
    title: 'Forest at Dusk',
    subject: 'landscape',
    relative_time: '3 days ago',
    most_recent_critique: {
      sequence_number: 2,
      created_at: '2026-05-10T12:00:00.000Z',
      primary_category: 'value',
      focus_area_text: 'value grouping',
      severity: 3,
    },
    ...overrides,
  };
}

test('formatRegistryEntries renders the full focus_area_text + severity case', () => {
  const text = formatRegistryEntries([registryRow()]);
  assert.equal(
    text,
    '- "Forest at Dusk" (landscape, 3 days ago) — last critique focused on value grouping (severity 3)',
  );
});

test('formatRegistryEntries falls back to primary_category when focus_area_text is null', () => {
  const text = formatRegistryEntries([registryRow({
    most_recent_critique: {
      ...registryRow().most_recent_critique,
      focus_area_text: null,
    },
  })]);
  // Falls back to 'value' (primary_category) — severity 3 still present.
  assert.ok(text.includes('— last critique focused on value (severity 3)'),
    `expected primary_category fallback, got: ${text}`);
});

test('formatRegistryEntries uses "previous critique exists" when both classifier fields are null', () => {
  const text = formatRegistryEntries([registryRow({
    most_recent_critique: {
      sequence_number: 1,
      created_at: '2026-05-10T12:00:00.000Z',
      primary_category: null,
      focus_area_text: null,
      severity: null,
    },
  })]);
  // Approved-tweak wording: WHOLE phrase changes, no severity, no "focused on".
  assert.ok(text.includes('— previous critique exists'),
    `expected previous-critique-exists fallback, got: ${text}`);
  assert.ok(!text.includes('focused on'),
    'should not say "focused on" when both classifier fields are null');
  assert.ok(!text.includes('severity'),
    'should not append severity when the focus phrase falls all the way through');
});

test('formatRegistryEntries renders "no critique yet" when most_recent_critique is null', () => {
  const text = formatRegistryEntries([registryRow({ most_recent_critique: null })]);
  assert.equal(
    text,
    '- "Forest at Dusk" (landscape, 3 days ago) — no critique yet',
  );
});

test('formatRegistryEntries falls back to "Untitled" when title is blank or missing', () => {
  const blank = formatRegistryEntries([registryRow({ title: '   ' })]);
  const missing = formatRegistryEntries([registryRow({ title: null })]);
  assert.ok(blank.startsWith('- "Untitled" '));
  assert.ok(missing.startsWith('- "Untitled" '));
});

test('formatRegistryEntries omits the subject clause when subject is blank', () => {
  const text = formatRegistryEntries([registryRow({ subject: '' })]);
  // Expected shape: '- "Title" (3 days ago) — ...', NOT '- "Title" (, 3 days ago) — ...'
  assert.ok(text.startsWith('- "Forest at Dusk" (3 days ago) — '),
    `unexpected: ${text}`);
  assert.ok(!text.includes('(, '), 'should not leave a stray leading comma');
});

test('formatRegistryEntries omits the (severity N) parenthetical when severity is null', () => {
  const text = formatRegistryEntries([registryRow({
    most_recent_critique: {
      ...registryRow().most_recent_critique,
      severity: null,
    },
  })]);
  assert.ok(!text.includes('(severity'),
    `should drop severity parenthetical: ${text}`);
  assert.ok(text.includes('— last critique focused on value grouping'));
});

test('formatRegistryEntries handles an empty/null registry without throwing', () => {
  assert.equal(formatRegistryEntries([]), '');
  assert.equal(formatRegistryEntries(null), '');
  assert.equal(formatRegistryEntries(undefined), '');
});

// ---- buildUserMessage with registry ----------------------------------------

function makeRegistryFixture(n, { withCritiques = true } = {}) {
  return Array.from({ length: n }, (_, i) => registryRow({
    drawing_id: `d-${i + 1}`,
    title: `Drawing ${i + 1}`,
    subject: i % 2 === 0 ? 'portrait' : 'landscape',
    relative_time: `${i + 2} days ago`,
    most_recent_critique: withCritiques ? {
      sequence_number: 1,
      created_at: '2026-05-10T12:00:00.000Z',
      primary_category: 'composition',
      focus_area_text: `focus area ${i + 1}`,
      severity: 2,
    } : null,
  }));
}

test('buildUserMessage with an empty registry renders no registry block (current behavior preserved)', () => {
  const config = selectConfig('free', null);
  const text = buildUserMessage(config, [], 'IMG', [])[0].text;
  assert.equal(text, 'Please critique this drawing.');
  assert.ok(!text.includes(REGISTRY_FRAMING));
});

test('buildUserMessage with a sub-floor registry (2 rows) skips the registry block', () => {
  assert.equal(REGISTRY_MIN_ROWS, 3, 'floor sanity — guards the test against silent floor changes');
  const config = selectConfig('free', null);
  const text = buildUserMessage(config, [], 'IMG', makeRegistryFixture(2))[0].text;
  // No history, sub-floor registry → falls back to "Please critique this drawing."
  assert.equal(text, 'Please critique this drawing.');
  assert.ok(!text.includes(REGISTRY_FRAMING));
});

test('buildUserMessage renders the registry block at floor (3 rows, no history)', () => {
  const config = selectConfig('free', null);
  const registry = makeRegistryFixture(3);
  const text = buildUserMessage(config, [], 'IMG', registry)[0].text;
  assert.ok(text.includes(REGISTRY_FRAMING), 'framing should appear');
  for (let i = 1; i <= 3; i++) {
    assert.ok(text.includes(`"Drawing ${i}"`), `drawing ${i} should appear`);
  }
  // Trailer must follow — registry section uses the same trailer the
  // history section uses, so the model gets a clean "now critique this".
  assert.ok(text.endsWith('Now critique the current state of the drawing below.'));
});

test('buildUserMessage renders a 5-row registry with all rows in order', () => {
  const config = selectConfig('free', null);
  const registry = makeRegistryFixture(5);
  const text = buildUserMessage(config, [], 'IMG', registry)[0].text;
  for (let i = 1; i <= 5; i++) {
    assert.ok(text.includes(`"Drawing ${i}"`), `drawing ${i} present`);
  }
  // Order check: drawing 1 line index < drawing 5 line index.
  assert.ok(text.indexOf('"Drawing 1"') < text.indexOf('"Drawing 5"'));
});

test('buildUserMessage renders a 10-row mixed (critiqued + in-progress) registry correctly', () => {
  const config = selectConfig('free', null);
  // 8 critiqued + 2 in-progress (mirrors the uncritiquedSlots cap in fetchUserDrawingRegistry).
  const registry = [
    ...makeRegistryFixture(8, { withCritiques: true }),
    ...makeRegistryFixture(2, { withCritiques: false }).map((row, i) => ({
      ...row,
      drawing_id: `inprog-${i + 1}`,
      title: `In-Progress ${i + 1}`,
    })),
  ];
  const text = buildUserMessage(config, [], 'IMG', registry)[0].text;

  // 8 critiqued rows should mention "last critique focused on focus area N".
  for (let i = 1; i <= 8; i++) {
    assert.ok(text.includes(`"Drawing ${i}"`), `critiqued row ${i} should appear`);
    assert.ok(text.includes(`focus area ${i}`), `critiqued row ${i} should carry its focus`);
  }
  // 2 in-progress rows should say "no critique yet" each.
  const inProgressMatches = (text.match(/— no critique yet/g) ?? []).length;
  assert.equal(inProgressMatches, 2,
    'two in-progress rows should render with "— no critique yet"');
});

test('buildUserMessage renders BOTH history and registry when both are present', () => {
  const config = selectConfig('pro', null);
  const history = [
    productionCritiqueRow({ sequence_number: 1, content: 'Same-drawing history A.' }),
    productionCritiqueRow({ sequence_number: 2, content: 'Same-drawing history B.' }),
  ];
  const registry = makeRegistryFixture(3);
  const text = buildUserMessage(config, history, 'IMG', registry)[0].text;

  // History framing first, then registry framing, then trailer.
  const histIdx = text.indexOf(HISTORY_FRAMING_DEFAULT);
  const regIdx = text.indexOf(REGISTRY_FRAMING);
  const trailerIdx = text.indexOf('Now critique the current state');

  assert.ok(histIdx >= 0,   'history framing should be present');
  assert.ok(regIdx >= 0,    'registry framing should be present');
  assert.ok(trailerIdx >= 0,'trailer should be present');
  assert.ok(histIdx < regIdx, 'history block must precede registry block');
  assert.ok(regIdx < trailerIdx, 'registry block must precede trailer');

  // Both critique bodies should be present.
  assert.ok(text.includes('Same-drawing history A.'));
  assert.ok(text.includes('Same-drawing history B.'));
  // First registry row should be present.
  assert.ok(text.includes('"Drawing 1"'));
});

test('buildUserMessage falls back to default behavior when registry argument is omitted', () => {
  const config = selectConfig('free', null);
  // Three-arg call — backward-compat path for existing callers.
  const text3 = buildUserMessage(config, [], 'IMG')[0].text;
  // Four-arg call with empty registry — should produce identical output.
  const text4 = buildUserMessage(config, [], 'IMG', [])[0].text;
  assert.equal(text3, text4);
  assert.equal(text3, 'Please critique this drawing.');
});

test('buildUserMessage tolerates a non-array registry argument', () => {
  const config = selectConfig('free', null);
  // Defensive: a future caller bug passing null/undefined/object should
  // never throw — same shape of safety as Array.isArray(history) check above.
  const fromNull = buildUserMessage(config, [], 'IMG', null)[0].text;
  const fromObj  = buildUserMessage(config, [], 'IMG', { not: 'an array' })[0].text;
  assert.equal(fromNull, 'Please critique this drawing.');
  assert.equal(fromObj,  'Please critique this drawing.');
});

// ---- isCrossDrawingContextEnabled ------------------------------------------

test('isCrossDrawingContextEnabled is strict — only the literal string "true" enables', () => {
  assert.equal(isCrossDrawingContextEnabled({ CROSS_DRAWING_CONTEXT_ENABLED: 'true' }), true);
  assert.equal(isCrossDrawingContextEnabled({ CROSS_DRAWING_CONTEXT_ENABLED: 'false' }), false);
  assert.equal(isCrossDrawingContextEnabled({ CROSS_DRAWING_CONTEXT_ENABLED: '' }), false);
  assert.equal(isCrossDrawingContextEnabled({ CROSS_DRAWING_CONTEXT_ENABLED: 'TRUE' }), false);
  assert.equal(isCrossDrawingContextEnabled({ CROSS_DRAWING_CONTEXT_ENABLED: '1' }), false);
  assert.equal(isCrossDrawingContextEnabled({ CROSS_DRAWING_CONTEXT_ENABLED: true }), false);
  assert.equal(isCrossDrawingContextEnabled({}), false);
  assert.equal(isCrossDrawingContextEnabled(null), false);
  assert.equal(isCrossDrawingContextEnabled(undefined), false);
});

// ---- fetchCrossDrawingPreference -------------------------------------------

test('fetchCrossDrawingPreference returns false when the row explicitly opts out', async () => {
  const env = { ...TEST_SUPABASE };
  const fetcher = async () => ({
    ok: true,
    json: async () => ([{ cross_drawing_context_enabled: false }]),
  });
  const pref = await fetchCrossDrawingPreference({ env, userId: FREE_USER, fetcher });
  assert.equal(pref, false);
});

test('fetchCrossDrawingPreference returns true when the row opts in', async () => {
  const env = { ...TEST_SUPABASE };
  const fetcher = async () => ({
    ok: true,
    json: async () => ([{ cross_drawing_context_enabled: true }]),
  });
  const pref = await fetchCrossDrawingPreference({ env, userId: FREE_USER, fetcher });
  assert.equal(pref, true);
});

test('fetchCrossDrawingPreference defaults to true when the row is missing', async () => {
  // Trigger should have created the row at signup, but a missing row should
  // NOT break the request path. Default-on shape.
  const env = { ...TEST_SUPABASE };
  const fetcher = async () => ({ ok: true, json: async () => ([]) });
  const pref = await fetchCrossDrawingPreference({ env, userId: FREE_USER, fetcher });
  assert.equal(pref, true);
});

test('fetchCrossDrawingPreference defaults to true on a non-ok fetch (graceful degradation)', async () => {
  const env = { ...TEST_SUPABASE };
  const fetcher = async () => ({ ok: false, status: 503, json: async () => ({}) });
  const pref = await fetchCrossDrawingPreference({ env, userId: FREE_USER, fetcher });
  assert.equal(pref, true);
});

test('fetchCrossDrawingPreference defaults to true when the fetcher throws', async () => {
  const env = { ...TEST_SUPABASE };
  const fetcher = async () => { throw new Error('network'); };
  const pref = await fetchCrossDrawingPreference({ env, userId: FREE_USER, fetcher });
  assert.equal(pref, true);
});

test('fetchCrossDrawingPreference defaults to true when env is missing config', async () => {
  const pref = await fetchCrossDrawingPreference({ env: {}, userId: FREE_USER });
  assert.equal(pref, true);
});

test('fetchCrossDrawingPreference targets the user_preferences row by user_id', async () => {
  const calls = [];
  const fetcher = async (url, init) => {
    calls.push(String(url));
    return { ok: true, json: async () => ([{ cross_drawing_context_enabled: true }]) };
  };
  await fetchCrossDrawingPreference({ env: TEST_SUPABASE, userId: FREE_USER, fetcher });
  assert.equal(calls.length, 1);
  assert.ok(calls[0].includes('/rest/v1/user_preferences'));
  assert.ok(calls[0].includes(`user_id=eq.${FREE_USER}`));
  assert.ok(calls[0].includes('select=cross_drawing_context_enabled'));
  assert.ok(calls[0].includes('limit=1'));
});

// ---- fetchUserDrawingRegistry ----------------------------------------------

const REGISTRY_NOW = Date.UTC(2026, 4, 13, 12, 0, 0);
const REGISTRY_USER = FREE_USER;
const REGISTRY_CURRENT_DRAWING = '11111111-1111-1111-1111-111111111111';

function fakeDrawingRow(overrides = {}) {
  return {
    id: '22222222-2222-2222-2222-222222222222',
    title: 'A Drawing',
    context: { subject: 'portrait' },
    created_at: '2026-05-10T12:00:00.000Z',
    updated_at: '2026-05-10T12:00:00.000Z',
    critique_history: [{
      sequence_number: 1,
      created_at: '2026-05-10T12:00:00.000Z',
      content: 'critique body',
      tags: {
        primary_category: 'composition',
        focus_area_text: 'rule of thirds',
        severity: 2,
      },
    }],
    ...overrides,
  };
}

test('fetchUserDrawingRegistry returns [] when env is missing config', async () => {
  const rows = await fetchUserDrawingRegistry({ env: {}, userId: REGISTRY_USER, now: REGISTRY_NOW });
  assert.deepEqual(rows, []);
});

test('fetchUserDrawingRegistry returns [] when userId is missing', async () => {
  const rows = await fetchUserDrawingRegistry({
    env: TEST_SUPABASE, userId: '', now: REGISTRY_NOW,
  });
  assert.deepEqual(rows, []);
});

test('fetchUserDrawingRegistry returns [] on non-ok response (graceful)', async () => {
  const fetcher = async () => ({ ok: false, status: 503, json: async () => ({}) });
  const rows = await fetchUserDrawingRegistry({
    env: TEST_SUPABASE, userId: REGISTRY_USER, now: REGISTRY_NOW, fetcher,
  });
  assert.deepEqual(rows, []);
});

test('fetchUserDrawingRegistry returns [] when the fetcher throws', async () => {
  const fetcher = async () => { throw new Error('network'); };
  const rows = await fetchUserDrawingRegistry({
    env: TEST_SUPABASE, userId: REGISTRY_USER, now: REGISTRY_NOW, fetcher,
  });
  assert.deepEqual(rows, []);
});

test('fetchUserDrawingRegistry projects to the documented registry shape and pre-computes relative_time', async () => {
  // Row updated_at = REGISTRY_NOW - 3 days → 3 days ago.
  const threeDaysAgo = new Date(REGISTRY_NOW - 3 * 24 * 60 * 60 * 1000).toISOString();
  const fetcher = async () => ({
    ok: true,
    json: async () => ([fakeDrawingRow({
      id: 'd-1',
      title: 'Forest at Dusk',
      context: { subject: 'landscape' },
      updated_at: threeDaysAgo,
    })]),
  });
  const rows = await fetchUserDrawingRegistry({
    env: TEST_SUPABASE, userId: REGISTRY_USER, now: REGISTRY_NOW, fetcher,
  });
  assert.equal(rows.length, 1);
  const row = rows[0];
  assert.equal(row.drawing_id, 'd-1');
  assert.equal(row.title, 'Forest at Dusk');
  assert.equal(row.subject, 'landscape');
  assert.equal(row.relative_time, '3 days ago');
  assert.equal(row.most_recent_critique.primary_category, 'composition');
  assert.equal(row.most_recent_critique.focus_area_text, 'rule of thirds');
  assert.equal(row.most_recent_critique.severity, 2);
});

test('fetchUserDrawingRegistry excludes the drawing being critiqued (case-insensitive match)', async () => {
  const fetcher = async () => ({
    ok: true,
    json: async () => ([
      fakeDrawingRow({ id: REGISTRY_CURRENT_DRAWING.toUpperCase() }),
      fakeDrawingRow({ id: 'd-keeper' }),
    ]),
  });
  const rows = await fetchUserDrawingRegistry({
    env: TEST_SUPABASE,
    userId: REGISTRY_USER,
    excludeDrawingId: REGISTRY_CURRENT_DRAWING,
    now: REGISTRY_NOW,
    fetcher,
  });
  assert.equal(rows.length, 1);
  assert.equal(rows[0].drawing_id, 'd-keeper');
});

test('fetchUserDrawingRegistry caps results to opts.limit', async () => {
  // 25 critiqued rows → query asks for limit+overshoot, projection caps at limit.
  const rows25 = Array.from({ length: 25 }, (_, i) => fakeDrawingRow({ id: `d-${i + 1}` }));
  const fetcher = async () => ({ ok: true, json: async () => rows25 });
  const out = await fetchUserDrawingRegistry({
    env: TEST_SUPABASE, userId: REGISTRY_USER, now: REGISTRY_NOW, fetcher, limit: 10,
  });
  assert.equal(out.length, 10);
});

test('fetchUserDrawingRegistry surfaces at most 2 uncritiqued in-progress drawings', async () => {
  // Mix: 1 critiqued + 4 uncritiqued. Should yield 1 critiqued + 2 uncritiqued
  // = 3 total. The remaining 2 uncritiqued drawings are dropped.
  const fetcher = async () => ({
    ok: true,
    json: async () => ([
      fakeDrawingRow({ id: 'd-critique' }),
      fakeDrawingRow({ id: 'd-prog-1', critique_history: [] }),
      fakeDrawingRow({ id: 'd-prog-2', critique_history: [] }),
      fakeDrawingRow({ id: 'd-prog-3', critique_history: [] }),
      fakeDrawingRow({ id: 'd-prog-4', critique_history: [] }),
    ]),
  });
  const out = await fetchUserDrawingRegistry({
    env: TEST_SUPABASE, userId: REGISTRY_USER, now: REGISTRY_NOW, fetcher, limit: 10,
  });
  assert.equal(out.length, 3);
  const ids = out.map((r) => r.drawing_id);
  assert.ok(ids.includes('d-critique'));
  assert.ok(ids.includes('d-prog-1'));
  assert.ok(ids.includes('d-prog-2'));
  assert.ok(!ids.includes('d-prog-3'));
  assert.ok(!ids.includes('d-prog-4'));
});

test('fetchUserDrawingRegistry projects most_recent_critique=null when critique_history is empty', async () => {
  const fetcher = async () => ({
    ok: true,
    json: async () => ([fakeDrawingRow({ id: 'd-uncritiqued', critique_history: [] })]),
  });
  const rows = await fetchUserDrawingRegistry({
    env: TEST_SUPABASE, userId: REGISTRY_USER, now: REGISTRY_NOW, fetcher,
  });
  assert.equal(rows.length, 1);
  assert.equal(rows[0].most_recent_critique, null);
});

test('fetchUserDrawingRegistry handles entries with no tags (pre-Phase-1 rows) gracefully', async () => {
  const fetcher = async () => ({
    ok: true,
    json: async () => ([fakeDrawingRow({
      critique_history: [{ sequence_number: 1, content: 'old critique', created_at: '2026-04-01T00:00:00Z' }],
    })]),
  });
  const rows = await fetchUserDrawingRegistry({
    env: TEST_SUPABASE, userId: REGISTRY_USER, now: REGISTRY_NOW, fetcher,
  });
  assert.equal(rows.length, 1);
  const c = rows[0].most_recent_critique;
  assert.ok(c, 'should still produce a most_recent_critique projection');
  assert.equal(c.primary_category, null);
  assert.equal(c.focus_area_text, null);
  assert.equal(c.severity, null);
});

test('fetchUserDrawingRegistry asks Postgres for the right columns + ordering', async () => {
  const calls = [];
  const fetcher = async (url) => {
    calls.push(String(url));
    return { ok: true, json: async () => ([]) };
  };
  await fetchUserDrawingRegistry({
    env: TEST_SUPABASE, userId: REGISTRY_USER, now: REGISTRY_NOW, fetcher,
  });
  assert.equal(calls.length, 1);
  const url = calls[0];
  assert.ok(url.includes('/rest/v1/drawings'));
  assert.ok(url.includes(`user_id=eq.${REGISTRY_USER}`));
  assert.ok(url.includes('select=id,title,context,created_at,updated_at,critique_history'));
  assert.ok(url.includes('order=updated_at.desc'));
  // Overshoot must be respected: the URL must request strictly more rows
  // than `limit`, to let the JS-side filter (exclude/critiqued/in-progress)
  // still find `limit` rows after dropping the current drawing + capped
  // uncritiqued slots.
  assert.match(url, /limit=(\d+)/);
  const match = url.match(/limit=(\d+)/);
  const requestedLimit = Number(match?.[1]);
  assert.ok(requestedLimit >= 30, `limit should overshoot the projection cap; got ${requestedLimit}`);
});

// ---- buildCritiqueEntry telemetry fields -----------------------------------

test('buildCritiqueEntry records includeRegistryCount + crossDrawingContextEnabled in prompt_config', () => {
  const config = {
    ...selectConfig('free', null),
    includeRegistryCount: 5,
    crossDrawingContextEnabled: true,
  };
  const entry = buildCritiqueEntry({
    feedback: 'x',
    sequenceNumber: 1,
    config,
    tier: 'free',
    usage: { prompt_tokens: 100, completion_tokens: 50 },
    now: FIXED_NOW,
    presetId: 'studio_mentor',
  });
  assert.equal(entry.prompt_config.includeRegistryCount, 5);
  assert.equal(entry.prompt_config.crossDrawingContextEnabled, true);
});

test('buildCritiqueEntry defaults the new telemetry fields when config does not set them', () => {
  // Backward compat — older code paths (or hypothetical future ones) that
  // build an entry without the new config fields must still produce a
  // schema-uniform row. Default to 0 / false.
  const entry = buildCritiqueEntry({
    feedback: 'x',
    sequenceNumber: 1,
    config: selectConfig('free', null),
    tier: 'free',
    usage: { prompt_tokens: 100, completion_tokens: 50 },
    now: FIXED_NOW,
    presetId: 'studio_mentor',
  });
  assert.equal(entry.prompt_config.includeRegistryCount, 0);
  assert.equal(entry.prompt_config.crossDrawingContextEnabled, false);
});

test('buildCritiqueEntry preserves existing prompt_config fields alongside the new ones', () => {
  // Regression guard: adding telemetry fields must not drop tier / styleModifier /
  // includeHistoryCount / customPromptModifier. Future analytics queries depend on
  // every field continuing to land.
  const config = {
    ...selectConfig('pro', { styleModifier: 'Reference Sargent.' }),
    customPromptModifier: { focus: 'anatomy' },
    includeRegistryCount: 7,
    crossDrawingContextEnabled: true,
  };
  const entry = buildCritiqueEntry({
    feedback: 'x',
    sequenceNumber: 1,
    config,
    tier: 'pro',
    usage: { prompt_tokens: 100, completion_tokens: 50 },
    now: FIXED_NOW,
    presetId: 'studio_mentor',
  });
  assert.equal(entry.prompt_config.tier, 'pro');
  assert.equal(entry.prompt_config.includeHistoryCount, DEFAULT_PRO_CONFIG.includeHistoryCount);
  assert.equal(entry.prompt_config.styleModifier, 'Reference Sargent.');
  assert.deepEqual(entry.prompt_config.customPromptModifier, { focus: 'anatomy' });
  assert.equal(entry.prompt_config.includeRegistryCount, 7);
  assert.equal(entry.prompt_config.crossDrawingContextEnabled, true);
});

// ---- SHARED_SYSTEM_RULES placement -----------------------------------------

test('SHARED_SYSTEM_RULES contains the CROSS-DRAWING COACHING block adjacent to ITERATIVE COACHING', () => {
  const sysPrompt = buildSystemPrompt(selectConfig('free', null), baseContext);
  const iterIdx = sysPrompt.indexOf('ITERATIVE COACHING — READ THIS CAREFULLY:');
  const crossIdx = sysPrompt.indexOf('CROSS-DRAWING COACHING — READ THIS CAREFULLY:');
  const summaryIdx = sysPrompt.indexOf('SUMMARY BLOCK');

  assert.ok(iterIdx > 0,    'ITERATIVE COACHING block must be present');
  assert.ok(crossIdx > 0,   'CROSS-DRAWING COACHING block must be present');
  assert.ok(summaryIdx > 0, 'SUMMARY BLOCK must be present');
  assert.ok(iterIdx < crossIdx,   'cross-drawing block must follow iterative-coaching');
  assert.ok(crossIdx < summaryIdx,'cross-drawing block must precede summary');

  // Anti-hallucination clauses are load-bearing (see MEMORY.md). Don't drift.
  assert.ok(sysPrompt.includes('Never reference a drawing that isn\'t in the registry'),
    'anti-invent clause #1 must be present');
  assert.ok(sysPrompt.includes('never invent details about a drawing that is'),
    'anti-invent clause #2 must be present');
});

// ---- Integration: CROSS_DRAWING_CONTEXT_ENABLED=false kill-switch ----------
//
// When the env flag is off, the handler MUST NOT fetch the user_preferences
// row, MUST NOT fetch the registry, and MUST persist an entry whose
// prompt_config records crossDrawingContextEnabled=false +
// includeRegistryCount=0. Spec-mandated.

test('handler integration: CROSS_DRAWING_CONTEXT_ENABLED unset skips both Supabase reads and records crossDrawingContextEnabled=false', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const { env: baseEnv, ctx, restore } = await setupHappyPathHandlerEnv({ jwksKey: jwk });
  // Disable App Attest enforcement for this test — we're verifying the
  // cross-drawing kill-switch in isolation, not the attest gate. Matches
  // the production wrangler.toml shipping state (APP_ATTEST_REQUIRED='false').
  // Leaving attest enforcement on would require building a real assertion,
  // which the dedicated attest integration tests already cover above.
  const env = { ...baseEnv, APP_ATTEST_REQUIRED: 'false' };
  try {
    // Sanity: env intentionally has no CROSS_DRAWING_CONTEXT_ENABLED.
    assert.equal(env.CROSS_DRAWING_CONTEXT_ENABLED, undefined,
      'test env must not set the flag — that\'s the whole point of this test');

    // Track fetch calls so we can assert the negative case (registry +
    // user_preferences endpoints were NEVER touched).
    const seenUrls = [];
    const persistedRpcBodies = [];
    const originalFetch = globalThis.fetch;
    globalThis.fetch = async (url, init) => {
      const u = String(url);
      seenUrls.push(u);
      if (u.includes('/rest/v1/rpc/append_critique')) {
        persistedRpcBodies.push(JSON.parse(init.body));
      }
      return originalFetch(url, init);
    };

    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const req = await buildIntegrationRequest({ jwt });
    const res = await handler.fetch(req, env, ctx);
    assert.equal(res.status, 200, `expected SUCCESS, got ${res.status}`);

    // Negative assertions: registry endpoint shape never hit.
    const hitRegistry = seenUrls.some((u) =>
      u.includes('/rest/v1/drawings')
      && u.includes('select=id,title,context,created_at,updated_at,critique_history'),
    );
    assert.equal(hitRegistry, false,
      'registry endpoint must never be called when the kill-switch is off');

    // user_preferences endpoint never hit either.
    const hitPrefs = seenUrls.some((u) => u.includes('/rest/v1/user_preferences'));
    assert.equal(hitPrefs, false,
      'user_preferences must never be read when the kill-switch is off');

    // Persisted critique entry: telemetry must read off, includeRegistryCount=0.
    assert.equal(persistedRpcBodies.length, 1, 'one persistCritique call expected');
    const entry = persistedRpcBodies[0].p_entry;
    assert.equal(entry.prompt_config.crossDrawingContextEnabled, false,
      'persisted entry should record crossDrawingContextEnabled=false');
    assert.equal(entry.prompt_config.includeRegistryCount, 0,
      'persisted entry should record includeRegistryCount=0');
  } finally {
    restore();
  }
});

// =============================================================================
// My Evolution Phase 1 — critique classifier
// =============================================================================

const CLASSIFIER_ENV = { OPENAI_API_KEY: 'sk-test-classifier' };

// Captures one OpenAI-shaped completion call. The classifier expects a
// /v1/chat/completions response with choices[0].message.content as a JSON
// string matching the json_schema response_format contract.
function makeClassifierFetcher({ ok = true, status = 200, content = '', throwErr = null } = {}) {
  const calls = [];
  const fetcher = async (url, init) => {
    if (throwErr) throw throwErr;
    calls.push({ url, init, body: JSON.parse(init.body) });
    return {
      ok,
      status,
      async json() {
        return { choices: [{ message: { content } }] };
      },
      async text() {
        return content;
      },
    };
  };
  return { fetcher, calls };
}

function silentConsoleError(fn) {
  const original = console.error;
  console.error = () => {};
  return Promise.resolve(fn()).finally(() => { console.error = original; });
}

test('CRITIQUE_CATEGORIES locks the canonical 8-bucket taxonomy', () => {
  // The taxonomy is a contract between the classifier and the future
  // Evolution endpoint. Locking it here catches accidental edits to the list.
  assert.deepEqual(CRITIQUE_CATEGORIES, [
    'anatomy',
    'composition',
    'value',
    'color',
    'line',
    'perspective',
    'subject_match',
    'general',
  ]);
  assert.equal(SEVERITY_MIN, 1);
  assert.equal(SEVERITY_MAX, 5);
});

test('CLASSIFIER_MODEL is gpt-5-mini (single line to swap if model changes)', () => {
  // Was gpt-5.1-mini until 2026-05-11 — that model name 404s on the
  // OpenAI API. The mini variant lives in the gpt-5 family, not 5.1.
  assert.equal(CLASSIFIER_MODEL, 'gpt-5-mini');
  assert.equal(CLASSIFIER_VERSION, 'v1');
});

test('classifyCritique returns parsed tags with classifier_version stamped on success', async () => {
  const tags = {
    primary_category: 'anatomy',
    secondary_categories: ['line'],
    severity: 3,
    focus_area_text: 'Tighten the shoulder construction',
    subject_inferred: 'standing figure',
    acknowledged_progress: false,
  };
  const { fetcher, calls } = makeClassifierFetcher({ content: JSON.stringify(tags) });

  const result = await classifyCritique({
    feedback: '## Quick Take\nNice gesture.\n## Focus Area: Tighten the shoulder construction\n...',
    env: CLASSIFIER_ENV,
    fetcher,
  });

  assert.deepEqual(result, { ...tags, classifier_version: 'v1' });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://api.openai.com/v1/chat/completions');
  assert.equal(calls[0].init.headers.Authorization, 'Bearer sk-test-classifier');
  // Body shape contract: model swap + json_schema strict.
  // temperature/seed dropped 2026-05-11 — gpt-5-mini rejects custom
  // temperature and the seed field outright. max_completion_tokens
  // bumped 300 → 2000 to cover gpt-5's internal reasoning tokens;
  // reasoning_effort: 'none' added to keep that overhead minimal.
  assert.equal(calls[0].body.model, 'gpt-5-mini');
  assert.equal(calls[0].body.temperature, undefined);
  assert.equal(calls[0].body.seed, undefined);
  assert.equal(calls[0].body.max_completion_tokens, 2000);
  assert.equal(calls[0].body.reasoning_effort, 'minimal');
  assert.equal(calls[0].body.response_format.type, 'json_schema');
  assert.equal(calls[0].body.response_format.json_schema.strict, true);
  assert.deepEqual(calls[0].body.response_format.json_schema.schema.properties.primary_category.enum, CRITIQUE_CATEGORIES);
  // Text-only — no image array on user content.
  assert.equal(calls[0].body.messages.length, 2);
  assert.equal(calls[0].body.messages[0].role, 'system');
  assert.equal(calls[0].body.messages[1].role, 'user');
  assert.equal(typeof calls[0].body.messages[1].content, 'string');
});

test('classifyCritique returns null on non-2xx OpenAI response', () => silentConsoleError(async () => {
  const { fetcher } = makeClassifierFetcher({ ok: false, status: 500, content: 'upstream boom' });
  const result = await classifyCritique({ feedback: 'critique body', env: CLASSIFIER_ENV, fetcher });
  assert.equal(result, null);
}));

test('classifyCritique returns null on malformed JSON content', () => silentConsoleError(async () => {
  const { fetcher } = makeClassifierFetcher({ content: '{not json' });
  const result = await classifyCritique({ feedback: 'critique body', env: CLASSIFIER_ENV, fetcher });
  assert.equal(result, null);
}));

test('classifyCritique returns null when fetcher throws', () => silentConsoleError(async () => {
  const fetcher = async () => { throw new Error('network down'); };
  const result = await classifyCritique({ feedback: 'critique body', env: CLASSIFIER_ENV, fetcher });
  assert.equal(result, null);
}));

test('classifyCritique returns null when primary_category is outside the enum', () => silentConsoleError(async () => {
  // Defense-in-depth: even if OpenAI ever returns an off-enum value (schema
  // drift, provider hiccup), the classifier must reject it rather than write
  // garbage into the JSONB column.
  const bad = {
    primary_category: 'mystery',
    secondary_categories: [],
    severity: 2,
    focus_area_text: null,
    subject_inferred: null,
    acknowledged_progress: false,
  };
  const { fetcher } = makeClassifierFetcher({ content: JSON.stringify(bad) });
  const result = await classifyCritique({ feedback: 'x', env: CLASSIFIER_ENV, fetcher });
  assert.equal(result, null);
}));

test('classifyCritique returns null when severity is out of [1,5]', () => silentConsoleError(async () => {
  const bad = {
    primary_category: 'anatomy',
    secondary_categories: [],
    severity: 7,
    focus_area_text: null,
    subject_inferred: null,
    acknowledged_progress: false,
  };
  const { fetcher } = makeClassifierFetcher({ content: JSON.stringify(bad) });
  const result = await classifyCritique({ feedback: 'x', env: CLASSIFIER_ENV, fetcher });
  assert.equal(result, null);
}));

test('classifyCritique returns null when secondary_categories duplicates primary', () => silentConsoleError(async () => {
  // The taxonomy contract: secondaries are *additional* mentions. A duplicate
  // would skew per-category trend counts, so reject rather than dedup silently.
  const bad = {
    primary_category: 'anatomy',
    secondary_categories: ['anatomy'],
    severity: 3,
    focus_area_text: null,
    subject_inferred: null,
    acknowledged_progress: false,
  };
  const { fetcher } = makeClassifierFetcher({ content: JSON.stringify(bad) });
  const result = await classifyCritique({ feedback: 'x', env: CLASSIFIER_ENV, fetcher });
  assert.equal(result, null);
}));

test('classifyCritique returns null when env has no OPENAI_API_KEY', () => silentConsoleError(async () => {
  const { fetcher, calls } = makeClassifierFetcher({ content: '{}' });
  const result = await classifyCritique({ feedback: 'x', env: {}, fetcher });
  assert.equal(result, null);
  // Must short-circuit without any network call.
  assert.equal(calls.length, 0);
}));

test('classifyCritique tolerates empty/non-string feedback by returning null without a call', () => silentConsoleError(async () => {
  const { fetcher, calls } = makeClassifierFetcher({ content: '{}' });
  assert.equal(await classifyCritique({ feedback: '', env: CLASSIFIER_ENV, fetcher }), null);
  assert.equal(await classifyCritique({ feedback: null, env: CLASSIFIER_ENV, fetcher }), null);
  assert.equal(calls.length, 0);
}));


// =============================================================================
// My Evolution v2 — reel / themes / stats / summary
// =============================================================================
//
// v1 chart-based tests removed. The v2 surface is concrete: per-row reel,
// per-category themes, footer stats, and a monthly summary. Tests drive
// the pure helpers directly; the route handler is exercised end-to-end
// via buildEvolutionResponseV2.

function evoTaggedCritique({
  primary,
  secondaries = [],
  severity,
  createdAt,
  id = null,
  content = 'sample',
  focusAreaText = null,
} = {}) {
  return {
    id,
    sequence_number: 1,
    content,
    prompt_config: { tier: 'free', includeHistoryCount: 2, styleModifier: null },
    prompt_token_count: 0,
    completion_token_count: 0,
    created_at: createdAt,
    tags: {
      primary_category: primary,
      secondary_categories: secondaries,
      severity,
      focus_area_text: focusAreaText,
      subject_inferred: null,
      acknowledged_progress: false,
      classifier_version: 'v1',
    },
  };
}

function evoDrawing(critiques, {
  id = 'd1',
  updatedAt,
  createdAt,
  title = null,
  storagePath = null,
  context = null,
} = {}) {
  return {
    id,
    created_at: createdAt ?? '2026-04-01T00:00:00.000Z',
    updated_at: updatedAt ?? '2026-04-30T00:00:00.000Z',
    critique_history: critiques,
    title,
    storage_path: storagePath,
    context,
  };
}

const EVO_DEFAULT_WINDOW = {
  windowCritiques: DEFAULT_WINDOW_CRITIQUES,
  windowDays: DEFAULT_WINDOW_DAYS,
};

// -----------------------------------------------------------------------------
// extractExcerpt
// -----------------------------------------------------------------------------

test('extractExcerpt: empty / non-string returns empty string', () => {
  assert.equal(extractExcerpt(''), '');
  assert.equal(extractExcerpt(null), '');
  assert.equal(extractExcerpt(undefined), '');
  assert.equal(extractExcerpt(42), '');
});

test('extractExcerpt: single sentence returned as-is', () => {
  assert.equal(extractExcerpt('Your composition is strong.'), 'Your composition is strong.');
});

test('extractExcerpt: prefers sentence containing progress token', () => {
  const text = 'The values are clean. Compared to your previous portrait, the eyes have improved noticeably.';
  assert.equal(
    extractExcerpt(text),
    'Compared to your previous portrait, the eyes have improved noticeably.',
  );
});

test('extractExcerpt: case-insensitive progress token match', () => {
  const text = 'Strong start. PREVIOUSLY you were flattening the nose; not this time.';
  assert.equal(
    extractExcerpt(text),
    'PREVIOUSLY you were flattening the nose; not this time.',
  );
});

test('extractExcerpt: falls back to first sentence when no progress token', () => {
  const text = 'Your line work is confident. The color palette is well chosen.';
  assert.equal(extractExcerpt(text), 'Your line work is confident.');
});

test('extractExcerpt: hard cap at 240 chars with single ellipsis', () => {
  const long = 'A'.repeat(500) + '.';
  const out = extractExcerpt(long);
  assert.equal(out.length, 240);
  assert.ok(out.endsWith('…'), 'expected ellipsis terminator');
});

// -----------------------------------------------------------------------------
// buildSummary
// -----------------------------------------------------------------------------

test('buildSummary: zero drawings produces zero counters and empty subjects', () => {
  const out = buildSummary([], {
    drawings_this_week: 0,
    drawings_this_month: 0,
    critiques_total: 0,
    drawings_total: 0,
  }, { now: Date.now() });
  assert.equal(out.drawings_this_month, 0);
  assert.equal(out.critiques_this_month, 0);
  assert.deepEqual(out.top_subjects, []);
  assert.equal(out.insights_last_updated_at, null);
});

test('buildSummary: counts critiques in last 30 days, ignores older', () => {
  const now = Date.parse('2026-05-10T00:00:00.000Z');
  const recent = '2026-05-01T00:00:00.000Z';
  const older = '2026-03-01T00:00:00.000Z';
  const drawings = [
    evoDrawing([
      evoTaggedCritique({ primary: 'anatomy', severity: 3, createdAt: recent }),
      evoTaggedCritique({ primary: 'value', severity: 2, createdAt: older }),
    ], { context: { subject: 'portrait' } }),
  ];
  const streak = computeStreak(drawings, { now });
  const out = buildSummary(drawings, streak, { now });
  assert.equal(out.critiques_this_month, 1);
});

test('buildSummary: top_subjects ranked by frequency, pluralized, top 3', () => {
  const now = Date.parse('2026-05-10T00:00:00.000Z');
  const drawings = [
    evoDrawing([], { id: 'a', context: { subject: 'portrait' } }),
    evoDrawing([], { id: 'b', context: { subject: 'portrait' } }),
    evoDrawing([], { id: 'c', context: { subject: 'landscape' } }),
    evoDrawing([], { id: 'd', context: { subject: 'still life' } }),
    evoDrawing([], { id: 'e', context: { subject: 'cat' } }),
  ];
  const streak = computeStreak(drawings, { now });
  const out = buildSummary(drawings, streak, { now });
  assert.deepEqual(out.top_subjects.slice(0, 3), ['portraits', 'cats', 'landscapes']);
});

// -----------------------------------------------------------------------------
// buildReel
// -----------------------------------------------------------------------------

test('buildReel: empty input returns empty array', () => {
  assert.deepEqual(buildReel([], new Map()), []);
});

test('buildReel: rows expose thumbnail, title, subject from drawing', () => {
  const drawing = evoDrawing(
    [evoTaggedCritique({
      id: 'c1',
      primary: 'anatomy',
      severity: 3,
      createdAt: '2026-05-08T00:00:00.000Z',
      content: 'Your placement of the eyes has improved.',
    })],
    {
      id: 'd1',
      title: 'Tuesday portrait',
      storagePath: 'user-1/d1.jpg',
      context: { subject: 'portrait' },
    },
  );
  const flat = flattenCritiques([drawing]);
  const out = buildReel(flat, new Map([['d1', drawing]]));
  assert.equal(out.length, 1);
  assert.equal(out[0].drawing_id, 'd1');
  assert.equal(out[0].drawing_title, 'Tuesday portrait');
  assert.equal(out[0].drawing_subject, 'portrait');
  assert.equal(out[0].thumbnail_path, 'user-1/d1.jpg');
  assert.equal(out[0].primary_category, 'anatomy');
  assert.equal(out[0].excerpt_paraphrase, null);
  assert.ok(out[0].excerpt_raw.includes('improved'));
});

test('buildReel: sorts newest-first and respects limit', () => {
  const dA = evoDrawing(
    [evoTaggedCritique({ id: 'c-old', primary: 'value', severity: 2, createdAt: '2026-04-01T00:00:00.000Z' })],
    { id: 'd1' },
  );
  const dB = evoDrawing(
    [evoTaggedCritique({ id: 'c-new', primary: 'value', severity: 2, createdAt: '2026-05-08T00:00:00.000Z' })],
    { id: 'd2' },
  );
  const flat = flattenCritiques([dA, dB]);
  const out = buildReel(flat, new Map([['d1', dA], ['d2', dB]]), { limit: 1 });
  assert.equal(out.length, 1);
  assert.equal(out[0].critique_id, 'c-new');
});

// -----------------------------------------------------------------------------
// buildThemes
// -----------------------------------------------------------------------------

test('buildThemes: empty input returns empty array', () => {
  assert.deepEqual(buildThemes([]), []);
});

test('buildThemes: categories with fewer than 2 mentions are skipped', () => {
  const ts1 = '2026-05-01T00:00:00.000Z';
  const d = evoDrawing([
    evoTaggedCritique({ primary: 'anatomy', severity: 3, createdAt: ts1 }),
  ]);
  const flat = flattenCritiques([d]);
  assert.deepEqual(buildThemes(flat), []);
});

test('buildThemes: returns top 3 by data_points', () => {
  const drawings = [];
  for (let i = 0; i < 4; i += 1) {
    drawings.push(evoDrawing(
      [evoTaggedCritique({ primary: 'anatomy', severity: 3, createdAt: `2026-05-0${i + 1}T00:00:00.000Z` })],
      { id: `da${i}` },
    ));
  }
  for (let i = 0; i < 3; i += 1) {
    drawings.push(evoDrawing(
      [evoTaggedCritique({ primary: 'value', severity: 2, createdAt: `2026-04-0${i + 1}T00:00:00.000Z` })],
      { id: `dv${i}` },
    ));
  }
  for (let i = 0; i < 2; i += 1) {
    drawings.push(evoDrawing(
      [evoTaggedCritique({ primary: 'color', severity: 2, createdAt: `2026-03-0${i + 1}T00:00:00.000Z` })],
      { id: `dc${i}` },
    ));
  }
  drawings.push(evoDrawing(
    [
      evoTaggedCritique({ primary: 'line', severity: 2, createdAt: '2026-02-01T00:00:00.000Z' }),
      evoTaggedCritique({ primary: 'line', severity: 2, createdAt: '2026-02-02T00:00:00.000Z' }),
    ],
    { id: 'dl' },
  ));
  const flat = flattenCritiques(drawings);
  const themes = buildThemes(flat);
  assert.equal(themes.length, 3);
  assert.equal(themes[0].category_id, 'anatomy');
  assert.equal(themes[0].data_points, 4);
});

// -----------------------------------------------------------------------------
// buildStats
// -----------------------------------------------------------------------------

test('buildStats: zero critiques returns zero and null fields', () => {
  const out = buildStats([]);
  assert.deepEqual(out, {
    total_critiques: 0,
    most_discussed_category: null,
    most_improved_category: null,
    current_focus_area: null,
  });
});

test('buildStats: most_discussed_category uses weighted count', () => {
  const d = evoDrawing([
    evoTaggedCritique({ primary: 'anatomy', secondaries: ['value'], severity: 3, createdAt: '2026-05-01T00:00:00.000Z' }),
    evoTaggedCritique({ primary: 'anatomy', severity: 3, createdAt: '2026-05-02T00:00:00.000Z' }),
    evoTaggedCritique({ primary: 'value', severity: 2, createdAt: '2026-05-03T00:00:00.000Z' }),
  ]);
  const flat = flattenCritiques([d]);
  const out = buildStats(flat);
  assert.equal(out.most_discussed_category, 'anatomy');
});

test('buildStats: current_focus_area from most-recent critique with focus text', () => {
  const d = evoDrawing([
    evoTaggedCritique({ primary: 'anatomy', severity: 3, createdAt: '2026-05-01T00:00:00.000Z', focusAreaText: 'eye placement' }),
    evoTaggedCritique({ primary: 'value', severity: 2, createdAt: '2026-05-02T00:00:00.000Z', focusAreaText: 'hand proportion' }),
  ]);
  const flat = flattenCritiques([d]);
  const out = buildStats(flat);
  assert.equal(out.current_focus_area, 'hand proportion');
});

test('buildStats: most_improved_category requires at least 4 critiques per category', () => {
  const dShort = evoDrawing([
    evoTaggedCritique({ primary: 'anatomy', severity: 5, createdAt: '2026-05-01T00:00:00.000Z' }),
    evoTaggedCritique({ primary: 'anatomy', severity: 3, createdAt: '2026-05-02T00:00:00.000Z' }),
    evoTaggedCritique({ primary: 'anatomy', severity: 1, createdAt: '2026-05-03T00:00:00.000Z' }),
  ]);
  assert.equal(buildStats(flattenCritiques([dShort])).most_improved_category, null);

  const dLong = evoDrawing([
    evoTaggedCritique({ primary: 'anatomy', severity: 5, createdAt: '2026-05-01T00:00:00.000Z' }),
    evoTaggedCritique({ primary: 'anatomy', severity: 4, createdAt: '2026-05-02T00:00:00.000Z' }),
    evoTaggedCritique({ primary: 'anatomy', severity: 2, createdAt: '2026-05-03T00:00:00.000Z' }),
    evoTaggedCritique({ primary: 'anatomy', severity: 1, createdAt: '2026-05-04T00:00:00.000Z' }),
  ]);
  assert.equal(buildStats(flattenCritiques([dLong])).most_improved_category, 'anatomy');
});

// -----------------------------------------------------------------------------
// buildEvolutionResponseV2 (end-to-end shape)
// -----------------------------------------------------------------------------

test('buildEvolutionResponseV2: empty drawings yields empty sections but all keys present', () => {
  const out = buildEvolutionResponseV2([], { ...EVO_DEFAULT_WINDOW, now: Date.now() });
  assert.equal(out.digest_sentence, null);
  assert.deepEqual(out.themes, []);
  assert.equal(out.highlight, null);
  assert.deepEqual(out.reel, []);
  assert.equal(out.stats.total_critiques, 0);
  assert.equal(out.summary.drawings_this_month, 0);
  assert.equal(out.summary.critiques_this_month, 0);
  assert.deepEqual(out.summary.top_subjects, []);
  assert.equal(out.summary.insights_last_updated_at, null);
  assert.ok('classifier_version' in out);
});

test('buildEvolutionResponseV2: Phase 1 LLM-driven fields are stub values', () => {
  const now = Date.parse('2026-05-10T00:00:00.000Z');
  const d = evoDrawing(
    [evoTaggedCritique({
      id: 'c1', primary: 'anatomy', severity: 3,
      createdAt: '2026-05-08T00:00:00.000Z',
      content: 'Eye placement improved noticeably.',
    })],
    { id: 'd1', title: 't', storagePath: 'p', context: { subject: 'portrait' } },
  );
  const out = buildEvolutionResponseV2([d], { ...EVO_DEFAULT_WINDOW, now });
  assert.equal(out.digest_sentence, null, 'Phase 1 digest is null');
  assert.equal(out.highlight, null, 'Phase 1 highlight is null');
  assert.equal(out.reel[0]?.excerpt_paraphrase, null, 'Phase 1 paraphrase is null');
});

test('buildEvolutionResponseV2: reel row exposes excerpt_raw via extractExcerpt', () => {
  const now = Date.parse('2026-05-10T00:00:00.000Z');
  const d = evoDrawing(
    [evoTaggedCritique({
      id: 'c1', primary: 'anatomy', severity: 3,
      createdAt: '2026-05-08T00:00:00.000Z',
      content: 'Strong start. Compared to last time the eyes are tighter.',
    })],
    { id: 'd1', storagePath: 'p' },
  );
  const out = buildEvolutionResponseV2([d], { ...EVO_DEFAULT_WINDOW, now });
  assert.equal(out.reel[0].excerpt_raw, 'Compared to last time the eyes are tighter.');
});

// =============================================================================
// Feature 2, Phase 2A — Eve conversational coach
// =============================================================================
//
// Layers exercised here:
//   1. buildEveSystemPrompt — persona + product context always; CURRENT
//      CONTEXT only when scope='drawing' AND a critique is hydrated.
//   2. buildEveMessages — system + history + new user turn; skips tool
//      turns; defensive against missing/malformed history rows.
//   3. Rate-limit machinery — readEveTierLimits with env overrides,
//      enforceEveRateLimits per-minute + per-day gates, recordSuccessful-
//      EveTurn increments the daily counter.
//   4. lib/supabase Eve helpers — createConversation, getConversation,
//      listConversations, softDeleteConversation, appendMessage, getConver-
//      sationHistory, findMessageByClientRequestId, fetchCritiqueForConver-
//      sation. All against stubbed fetchers.
//   5. handleEve integration — POST create, GET list, GET detail,
//      DELETE soft-delete, POST send-message with full OpenAI mock,
//      idempotency replay, conversation_full ceiling.

// ---- buildEveSystemPrompt --------------------------------------------------

test('buildEveSystemPrompt with scope=general renders persona + product context, no CURRENT CONTEXT', () => {
  const sys = buildEveSystemPrompt({ scope: 'general', critique: null });
  assert.ok(sys.includes('You are Eve, the coach inside DrawEvolve'),
    'persona must be present');
  assert.ok(sys.includes('ABOUT DRAWEVOLVE:'),
    'product context header must be present');
  assert.ok(!sys.includes('CURRENT CONTEXT:'),
    'no CURRENT CONTEXT block for scope=general');
});

test('buildEveSystemPrompt with scope=drawing + critique renders all three sections', () => {
  const sys = buildEveSystemPrompt({
    scope: 'drawing',
    critique: {
      drawing_title: 'Forest at Dusk',
      drawing_subject: 'landscape',
      sequence_number: 2,
      content: 'Sample critique markdown.',
    },
  });
  assert.ok(sys.includes('You are Eve'),
    'persona present');
  assert.ok(sys.includes('ABOUT DRAWEVOLVE:'),
    'product context present');
  assert.ok(sys.includes('CURRENT CONTEXT:'),
    'CURRENT CONTEXT block present');
  assert.ok(sys.includes('"Forest at Dusk"'),
    'title is quoted in the context block');
  assert.ok(sys.includes('Subject: landscape'),
    'subject appears on its own line');
  assert.ok(sys.includes('Critique sequence number: 2'),
    'sequence number appears');
  assert.ok(sys.includes('Sample critique markdown.'),
    'critique body appears inside the triple-quoted block');
  // Date line must NOT appear — approved spec is to omit absolute dates.
  assert.ok(!sys.includes('Critique date:'),
    'date line must not be present in the CURRENT CONTEXT block');
});

test('buildEveSystemPrompt fallbacks: Untitled / "not specified" / "?" when fields are missing', () => {
  const sys = buildEveSystemPrompt({
    scope: 'drawing',
    critique: {
      drawing_title: null,
      drawing_subject: '   ',
      sequence_number: null,
      content: 'body',
    },
  });
  assert.ok(sys.includes('"Untitled"'),
    'title falls back to Untitled when null');
  assert.ok(sys.includes('Subject: not specified'),
    'subject falls back to "not specified" when blank');
  assert.ok(sys.includes('Critique sequence number: ?'),
    'sequence falls back to ?');
});

test('buildEveSystemPrompt omits CURRENT CONTEXT when scope=drawing but no critique hydrated', () => {
  const sys = buildEveSystemPrompt({ scope: 'drawing', critique: null });
  assert.ok(sys.includes('You are Eve'));
  assert.ok(sys.includes('ABOUT DRAWEVOLVE:'));
  assert.ok(!sys.includes('CURRENT CONTEXT:'),
    'should fall back to no-critique posture when hydration fails');
});

test('buildEveSystemPrompt omits CURRENT CONTEXT when critique.content is missing or non-string', () => {
  const a = buildEveSystemPrompt({
    scope: 'drawing',
    critique: { drawing_title: 't', sequence_number: 1, content: null },
  });
  const b = buildEveSystemPrompt({
    scope: 'drawing',
    critique: { drawing_title: 't', sequence_number: 1, content: 42 },
  });
  assert.ok(!a.includes('CURRENT CONTEXT:'));
  assert.ok(!b.includes('CURRENT CONTEXT:'));
});

test('EVE_PERSONA and EVE_PRODUCT_CONTEXT version constants are >= 1 (no zero-version regressions)', () => {
  assert.ok(Number.isInteger(EVE_PERSONA_VERSION) && EVE_PERSONA_VERSION >= 1);
  assert.ok(Number.isInteger(EVE_PRODUCT_CONTEXT_VERSION) && EVE_PRODUCT_CONTEXT_VERSION >= 1);
});

test('EVE_PERSONA contains the load-bearing distinguishing language vs critique voices', () => {
  // Regression guard against accidental rewrites that erase Eve's identity.
  assert.ok(EVE_PERSONA.includes('You are Eve'));
  assert.ok(EVE_PERSONA.includes('warm but direct'));
  assert.ok(EVE_PERSONA.includes('You are not one of the critique voices'));
  assert.ok(EVE_PERSONA.includes('redirect them to the Get Feedback flow'));
});

test('EVE_PRODUCT_CONTEXT lists the load-bearing "does not exist" anti-hallucination block', () => {
  assert.ok(EVE_PRODUCT_CONTEXT.includes('WHAT DOES NOT EXIST IN DRAWEVOLVE YET'));
  assert.ok(EVE_PRODUCT_CONTEXT.includes('no sharing, following'));
  assert.ok(EVE_PRODUCT_CONTEXT.includes('AI image generation'));
  assert.ok(EVE_PRODUCT_CONTEXT.includes('mentor, not replacement'));
});

// ---- buildEveMessages ------------------------------------------------------

test('buildEveMessages produces system + history (user/assistant) + new user turn in order', () => {
  const messages = buildEveMessages({
    systemPrompt: 'SYSTEM',
    history: [
      { role: 'user', content: 'first ask' },
      { role: 'assistant', content: 'first reply' },
      { role: 'user', content: 'second ask' },
      { role: 'assistant', content: 'second reply' },
    ],
    userTurn: 'third ask',
  });
  assert.equal(messages.length, 6);
  assert.deepEqual(messages[0], { role: 'system', content: 'SYSTEM' });
  assert.deepEqual(messages[1], { role: 'user', content: 'first ask' });
  assert.deepEqual(messages[5], { role: 'user', content: 'third ask' });
});

test('buildEveMessages skips role=tool turns in 2A (no tools yet)', () => {
  const messages = buildEveMessages({
    systemPrompt: 'S',
    history: [
      { role: 'user', content: 'hi' },
      { role: 'tool', content: 'tool result that should be dropped' },
      { role: 'assistant', content: 'hello' },
    ],
    userTurn: 'next',
  });
  // Expect: [system, user, assistant, user-next] — tool row dropped.
  assert.equal(messages.length, 4);
  for (const m of messages) {
    assert.notEqual(m.role, 'tool', 'tool turn must not be passed to OpenAI in 2A');
  }
});

test('buildEveMessages silently drops malformed history rows', () => {
  const messages = buildEveMessages({
    systemPrompt: 'S',
    history: [
      null,
      undefined,
      { role: 'user' }, // missing content
      { role: 'user', content: 123 }, // non-string content
      { role: 'user', content: 'good row' },
    ],
    userTurn: 'q',
  });
  // Expect: [system, good row, q] — three rows dropped.
  assert.equal(messages.length, 3);
  assert.equal(messages[1].content, 'good row');
});

test('buildEveMessages omits userTurn when it is empty or missing', () => {
  const a = buildEveMessages({ systemPrompt: 'S', history: [], userTurn: '' });
  const b = buildEveMessages({ systemPrompt: 'S', history: [], userTurn: undefined });
  assert.equal(a.length, 1);
  assert.equal(b.length, 1);
  assert.equal(a[0].role, 'system');
});

test('buildEveMessages tolerates non-array history without throwing', () => {
  const messages = buildEveMessages({ systemPrompt: 'S', history: null, userTurn: 'q' });
  // Defensive: should produce [system, user] without blowing up.
  assert.equal(messages.length, 2);
  assert.equal(messages[1].content, 'q');
});

// ---- Eve rate-limit machinery ----------------------------------------------

test('readEveTierLimits returns defaults when env vars are unset', () => {
  const limits = readEveTierLimits({});
  assert.deepEqual(limits.free, EVE_TIER_LIMITS.free);
  assert.deepEqual(limits.pro, EVE_TIER_LIMITS.pro);
});

test('readEveTierLimits parses env overrides for both tiers', () => {
  const limits = readEveTierLimits({
    EVE_PER_MINUTE_FREE: '7',
    EVE_PER_MINUTE_PRO: '25',
    EVE_PER_DAY_FREE: '45',
    EVE_PER_DAY_PRO: '500',
  });
  assert.deepEqual(limits.free, { perMinute: 7, perDay: 45 });
  assert.deepEqual(limits.pro, { perMinute: 25, perDay: 500 });
});

test('readEveTierLimits ignores invalid values and falls back per-axis', () => {
  const limits = readEveTierLimits({
    EVE_PER_MINUTE_FREE: 'banana',
    EVE_PER_DAY_FREE: '-3',
    EVE_PER_MINUTE_PRO: '0',
    EVE_PER_DAY_PRO: '',
  });
  assert.deepEqual(limits.free, EVE_TIER_LIMITS.free);
  assert.deepEqual(limits.pro, EVE_TIER_LIMITS.pro);
});

test('readEveMaxTurnsPerConversation default + override', () => {
  assert.equal(readEveMaxTurnsPerConversation({}), 100);
  assert.equal(readEveMaxTurnsPerConversation({ EVE_MAX_TURNS_PER_CONVERSATION: '40' }), 40);
  assert.equal(readEveMaxTurnsPerConversation({ EVE_MAX_TURNS_PER_CONVERSATION: 'oops' }), 100);
});

test('enforceEveRateLimits passes when no prior counters exist', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  const decision = await enforceEveRateLimits({
    env, userId: FREE_USER, tier: 'free', now: FIXED_NOW,
  });
  assert.equal(decision.ok, true);
  assert.equal(decision.ctx.tier, 'free');
  // Per-minute bucket should have a single timestamp now.
  const minuteRaw = await kv.get(`eve_rate:${FREE_USER}`);
  assert.deepEqual(JSON.parse(minuteRaw), [FIXED_NOW]);
});

test('enforceEveRateLimits returns 429 eve_quota_exceeded when daily cap is hit', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  const dayKey = utcDayKey(FIXED_NOW);
  await kv.put(`eve_quota:${FREE_USER}:${dayKey}`, '60', { expirationTtl: 48 * 3600 });

  const decision = await enforceEveRateLimits({
    env, userId: FREE_USER, tier: 'free', now: FIXED_NOW,
  });
  assert.equal(decision.ok, false);
  assert.equal(decision.status, 429);
  assert.equal(decision.body.error, 'eve_quota_exceeded');
  assert.equal(decision.body.scope, 'daily');
  assert.equal(decision.body.tier, 'free');
  assert.equal(decision.body.limit, 60);
});

test('enforceEveRateLimits returns 429 eve_rate_limited when per-minute cap is hit', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  // 10 timestamps in the last 60s — at the free per-minute cap of 10.
  const recent = Array.from({ length: 10 }, (_, i) => FIXED_NOW - i * 1000);
  await kv.put(`eve_rate:${FREE_USER}`, JSON.stringify(recent), { expirationTtl: 120 });

  const decision = await enforceEveRateLimits({
    env, userId: FREE_USER, tier: 'free', now: FIXED_NOW,
  });
  assert.equal(decision.ok, false);
  assert.equal(decision.status, 429);
  assert.equal(decision.body.error, 'eve_rate_limited');
  assert.equal(decision.body.scope, 'minute');
  assert.ok(decision.body.retryAfter >= 1);
});

test('enforceEveRateLimits drops timestamps older than 60s before counting', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  // 10 entries but all > 60s old.
  const old = Array.from({ length: 10 }, (_, i) => FIXED_NOW - 90_000 - i * 1000);
  await kv.put(`eve_rate:${FREE_USER}`, JSON.stringify(old), { expirationTtl: 120 });

  const decision = await enforceEveRateLimits({
    env, userId: FREE_USER, tier: 'free', now: FIXED_NOW,
  });
  // Stale entries don't count — request passes.
  assert.equal(decision.ok, true);
});

test('enforceEveRateLimits uses pro tier limits when tier=pro', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  const dayKey = utcDayKey(FIXED_NOW);
  await kv.put(`eve_quota:${PRO_USER}:${dayKey}`, '60', { expirationTtl: 48 * 3600 });

  // Free user with 60 sends would be blocked; pro user with 60 should pass.
  const decision = await enforceEveRateLimits({
    env, userId: PRO_USER, tier: 'pro', now: FIXED_NOW,
  });
  assert.equal(decision.ok, true);
});

test('recordSuccessfulEveTurn increments the daily message counter by 1', async () => {
  const { env, kv } = makeEnv();
  kv.setNow(FIXED_NOW);
  const dayKey = utcDayKey(FIXED_NOW);
  const dailyKey = `eve_quota:${FREE_USER}:${dayKey}`;

  // Simulate a passing rate-limit gate then a successful turn.
  await kv.put(dailyKey, '3', { expirationTtl: 48 * 3600 });
  await recordSuccessfulEveTurn({
    env,
    ctx: { dailyKey, dailyCount: 3, tier: 'free', userId: FREE_USER, limits: EVE_TIER_LIMITS.free },
  });
  assert.equal(await kv.get(dailyKey), '4');
});

// ---- Eve supabase helpers (stubbed fetcher) --------------------------------

const EVE_USER = FREE_USER;
const EVE_CONVERSATION_ID = 'eeeeeeee-1111-2222-3333-444444444444';
const EVE_MESSAGE_ID = 'eeeeeeee-5555-6666-7777-888888888888';

test('createConversation POSTs the expected payload and returns the row', async () => {
  const calls = [];
  const fetcher = async (url, init) => {
    calls.push({ url: String(url), init });
    return {
      ok: true,
      json: async () => ([{ id: EVE_CONVERSATION_ID, user_id: EVE_USER, scope: 'general' }]),
    };
  };
  const row = await createConversation({
    env: TEST_SUPABASE,
    userId: EVE_USER,
    scope: 'general',
    fetcher,
  });
  assert.equal(row.id, EVE_CONVERSATION_ID);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].init.method, 'POST');
  assert.ok(calls[0].url.endsWith('/rest/v1/conversations'));
  const body = JSON.parse(calls[0].init.body);
  assert.equal(body.user_id, EVE_USER);
  assert.equal(body.scope, 'general');
  assert.equal(body.scope_drawing_id, null);
  // Prefer header gates representation return.
  assert.equal(calls[0].init.headers.Prefer, 'return=representation');
});

test('createConversation throws with Supabase error body on non-ok', async () => {
  const fetcher = async () => ({
    ok: false, status: 409,
    text: async () => '{"message":"duplicate key value"}',
  });
  await assert.rejects(
    () => createConversation({ env: TEST_SUPABASE, userId: EVE_USER, scope: 'general', fetcher }),
    /HTTP 409: \{"message":"duplicate key value"\}/,
  );
});

test('getConversation returns null when row missing, scopes by user + soft-delete', async () => {
  let capturedUrl = '';
  const fetcher = async (url) => {
    capturedUrl = String(url);
    return { ok: true, json: async () => ([]) };
  };
  const out = await getConversation({
    env: TEST_SUPABASE,
    userId: EVE_USER,
    conversationId: EVE_CONVERSATION_ID,
    fetcher,
  });
  assert.equal(out, null);
  assert.ok(capturedUrl.includes(`id=eq.${EVE_CONVERSATION_ID}`));
  assert.ok(capturedUrl.includes(`user_id=eq.${EVE_USER}`));
  assert.ok(capturedUrl.includes('deleted_at=is.null'));
  assert.ok(capturedUrl.includes('limit=1'));
});

test('listConversations orders by last_message_at desc and filters soft-deletes', async () => {
  let capturedUrl = '';
  const fetcher = async (url) => {
    capturedUrl = String(url);
    return { ok: true, json: async () => ([{ id: 'a' }, { id: 'b' }]) };
  };
  const out = await listConversations({ env: TEST_SUPABASE, userId: EVE_USER, fetcher });
  assert.equal(out.length, 2);
  assert.ok(capturedUrl.includes('order=last_message_at.desc'));
  assert.ok(capturedUrl.includes('deleted_at=is.null'));
});

test('softDeleteConversation PATCHes deleted_at and returns true on affected row', async () => {
  let capturedBody = '';
  const fetcher = async (url, init) => {
    capturedBody = init.body;
    return { ok: true, json: async () => ([{ id: EVE_CONVERSATION_ID }]) };
  };
  const ok = await softDeleteConversation({
    env: TEST_SUPABASE,
    userId: EVE_USER,
    conversationId: EVE_CONVERSATION_ID,
    fetcher,
  });
  assert.equal(ok, true);
  const body = JSON.parse(capturedBody);
  assert.ok(typeof body.deleted_at === 'string');
  // Verify it parses back as a valid ISO date.
  assert.ok(!Number.isNaN(Date.parse(body.deleted_at)));
});

test('softDeleteConversation returns false when no rows were affected (already deleted)', async () => {
  const fetcher = async () => ({ ok: true, json: async () => ([]) });
  const ok = await softDeleteConversation({
    env: TEST_SUPABASE,
    userId: EVE_USER,
    conversationId: EVE_CONVERSATION_ID,
    fetcher,
  });
  assert.equal(ok, false);
});

test('appendMessage POSTs the canonical message shape', async () => {
  let capturedBody = '';
  const fetcher = async (url, init) => {
    capturedBody = init.body;
    return { ok: true, json: async () => ([{ id: EVE_MESSAGE_ID }]) };
  };
  const row = await appendMessage({
    env: TEST_SUPABASE,
    conversationId: EVE_CONVERSATION_ID,
    role: 'assistant',
    content: 'hello',
    personaVersion: 1,
    productContextVersion: 1,
    promptTokenCount: 100,
    completionTokenCount: 50,
    fetcher,
  });
  assert.equal(row.id, EVE_MESSAGE_ID);
  const body = JSON.parse(capturedBody);
  assert.equal(body.conversation_id, EVE_CONVERSATION_ID);
  assert.equal(body.role, 'assistant');
  assert.equal(body.content, 'hello');
  assert.equal(body.persona_version, 1);
  assert.equal(body.product_context_version, 1);
  assert.equal(body.prompt_token_count, 100);
  assert.equal(body.completion_token_count, 50);
});

test('getConversationHistory orders by created_at asc and respects limit', async () => {
  let capturedUrl = '';
  const fetcher = async (url) => {
    capturedUrl = String(url);
    return { ok: true, json: async () => ([]) };
  };
  await getConversationHistory({
    env: TEST_SUPABASE,
    conversationId: EVE_CONVERSATION_ID,
    limit: 25,
    fetcher,
  });
  assert.ok(capturedUrl.includes('order=created_at.asc'));
  assert.ok(capturedUrl.includes('limit=25'));
  assert.ok(capturedUrl.includes(`conversation_id=eq.${EVE_CONVERSATION_ID}`));
});

test('findMessageByClientRequestId returns row when assistant message exists; null otherwise', async () => {
  const row = { id: 'msg', role: 'assistant', content: 'reply' };
  const okFetcher = async () => ({ ok: true, json: async () => ([row]) });
  const out = await findMessageByClientRequestId({
    env: TEST_SUPABASE,
    conversationId: EVE_CONVERSATION_ID,
    clientRequestId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    fetcher: okFetcher,
  });
  assert.deepEqual(out, row);

  const emptyFetcher = async () => ({ ok: true, json: async () => ([]) });
  const out2 = await findMessageByClientRequestId({
    env: TEST_SUPABASE,
    conversationId: EVE_CONVERSATION_ID,
    clientRequestId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    fetcher: emptyFetcher,
  });
  assert.equal(out2, null);
});

test('findMessageByClientRequestId returns null when either id is missing (defensive)', async () => {
  const fetcher = async () => { throw new Error('should not be called'); };
  assert.equal(
    await findMessageByClientRequestId({ env: TEST_SUPABASE, conversationId: null, clientRequestId: 'x', fetcher }),
    null,
  );
  assert.equal(
    await findMessageByClientRequestId({ env: TEST_SUPABASE, conversationId: EVE_CONVERSATION_ID, clientRequestId: null, fetcher }),
    null,
  );
});

test('fetchCritiqueForConversation projects to the shape buildEveSystemPrompt expects', async () => {
  const fetcher = async () => ({
    ok: true,
    json: async () => ([{
      id: 'drawing-id',
      title: 'Forest at Dusk',
      context: { subject: 'landscape' },
      critique_history: [
        { sequence_number: 1, content: 'first critique' },
        { sequence_number: 2, content: 'second critique' },
      ],
    }]),
  });
  const out = await fetchCritiqueForConversation({
    env: TEST_SUPABASE,
    userId: EVE_USER,
    drawingId: 'drawing-id',
    sequenceNumber: 2,
    fetcher,
  });
  assert.deepEqual(out, {
    drawing_title: 'Forest at Dusk',
    drawing_subject: 'landscape',
    sequence_number: 2,
    content: 'second critique',
  });
});

test('fetchCritiqueForConversation returns null when the sequence does not exist', async () => {
  const fetcher = async () => ({
    ok: true,
    json: async () => ([{
      id: 'drawing-id',
      title: 't',
      context: {},
      critique_history: [{ sequence_number: 1, content: 'only one' }],
    }]),
  });
  const out = await fetchCritiqueForConversation({
    env: TEST_SUPABASE,
    userId: EVE_USER,
    drawingId: 'drawing-id',
    sequenceNumber: 99,
    fetcher,
  });
  assert.equal(out, null);
});

test('fetchCritiqueForConversation returns null on missing inputs / config / non-ok / throw', async () => {
  const okEmpty = async () => ({ ok: true, json: async () => ([]) });
  assert.equal(await fetchCritiqueForConversation({ env: {}, userId: EVE_USER, drawingId: 'd', sequenceNumber: 1 }), null);
  assert.equal(await fetchCritiqueForConversation({ env: TEST_SUPABASE, userId: EVE_USER, drawingId: null, sequenceNumber: 1 }), null);
  assert.equal(await fetchCritiqueForConversation({ env: TEST_SUPABASE, userId: EVE_USER, drawingId: 'd', sequenceNumber: 'x' }), null);
  assert.equal(await fetchCritiqueForConversation({ env: TEST_SUPABASE, userId: EVE_USER, drawingId: 'd', sequenceNumber: 1, fetcher: okEmpty }), null);
  const nonOk = async () => ({ ok: false, status: 500, json: async () => ({}) });
  assert.equal(await fetchCritiqueForConversation({ env: TEST_SUPABASE, userId: EVE_USER, drawingId: 'd', sequenceNumber: 1, fetcher: nonOk }), null);
  const throws = async () => { throw new Error('boom'); };
  assert.equal(await fetchCritiqueForConversation({ env: TEST_SUPABASE, userId: EVE_USER, drawingId: 'd', sequenceNumber: 1, fetcher: throws }), null);
});

// ---- handleEve integration -------------------------------------------------
//
// Full handler-level tests that drive POST/GET/DELETE against Eve routes
// via handler.fetch. They follow the same pattern as the Phase 1A handler
// integration test: real JWT, App Attest kill-switch off, mocked globalThis.fetch
// for Supabase + OpenAI. Each test sets up its own fake fetch matcher
// because each route hits a different combination of endpoints.

function eveAuthHeaders(jwt) {
  return {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${jwt}`,
  };
}

// Builds a JWT-only env (App Attest disabled) with a signed JWT helper.
async function setupEveEnv() {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const baseEnv = {
    ...TEST_JWT_ENV,
    SUPABASE_SERVICE_ROLE_KEY: 'test-service-role-key',
    OPENAI_API_KEY: 'test-openai-key',
    QUOTA_KV: new FakeKV(),
    APP_ATTEST_REQUIRED: 'false', // skip attest gate for these tests
  };
  const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
  const ctx = {
    waitUntil: (p) => { Promise.resolve(p).catch(() => {}); },
  };

  // Stash the public key for handleEve's JWT validation.
  const originalFetch = globalThis.fetch;
  // Default fetch handler — tests override per-suite by replacing globalThis.fetch
  // after calling this helper. We pre-install the JWKS handler so JWT validation
  // works without each test repeating it.
  globalThis.fetch = async (url) => {
    if (String(url).endsWith('/.well-known/jwks.json')) {
      return { ok: true, json: async () => ({ keys: [jwk]  }) };
    }
    return { ok: true, json: async () => ({}), text: async () => '' };
  };

  return {
    env: baseEnv,
    ctx,
    jwt,
    jwk,
    restore: () => { globalThis.fetch = originalFetch; },
  };
}

test('handleEve POST /v1/eve/conversations creates a general-scope conversation', async () => {
  const { env, ctx, jwt, jwk, restore } = await setupEveEnv();
  try {
    const created = {
      id: EVE_CONVERSATION_ID,
      user_id: TEST_SUB,
      scope: 'general',
      created_at: '2026-05-13T12:00:00.000Z',
      message_count: 0,
    };
    const calls = [];
    globalThis.fetch = async (url, init) => {
      const u = String(url);
      calls.push({ url: u, method: init?.method ?? 'GET' });
      if (u.endsWith('/.well-known/jwks.json')) {
        return { ok: true, json: async () => ({ keys: [jwk] }) };
      }
      if (u.includes('/rest/v1/conversations') && init?.method === 'POST') {
        return { ok: true, json: async () => ([created]) };
      }
      return { ok: true, json: async () => ({}) };
    };

    const req = new Request('https://drawevolve-backend.test/v1/eve/conversations', {
      method: 'POST',
      headers: eveAuthHeaders(jwt),
      body: JSON.stringify({ scope: 'general' }),
    });
    const res = await handleEve(req, env, ctx);
    assert.equal(res.status, 201);
    const body = await res.json();
    assert.equal(body.conversation.id, EVE_CONVERSATION_ID);
    assert.equal(body.conversation.scope, 'general');
  } finally { restore(); }
});

test('handleEve POST /v1/eve/conversations rejects scope=evolution in 2A', async () => {
  const { env, ctx, jwt, restore } = await setupEveEnv();
  try {
    const req = new Request('https://drawevolve-backend.test/v1/eve/conversations', {
      method: 'POST',
      headers: eveAuthHeaders(jwt),
      body: JSON.stringify({ scope: 'evolution' }),
    });
    const res = await handleEve(req, env, ctx);
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.match(body.error, /unsupported scope/i);
  } finally { restore(); }
});

test('handleEve POST /v1/eve/conversations rejects scope=drawing without scope_drawing_id', async () => {
  const { env, ctx, jwt, restore } = await setupEveEnv();
  try {
    const req = new Request('https://drawevolve-backend.test/v1/eve/conversations', {
      method: 'POST',
      headers: eveAuthHeaders(jwt),
      body: JSON.stringify({ scope: 'drawing' }),
    });
    const res = await handleEve(req, env, ctx);
    assert.equal(res.status, 400);
  } finally { restore(); }
});

test('handleEve GET /v1/eve/conversations lists the calling user\'s active conversations', async () => {
  const { env, ctx, jwt, jwk, restore } = await setupEveEnv();
  try {
    const rows = [
      { id: 'c1', user_id: TEST_SUB, scope: 'general' },
      { id: 'c2', user_id: TEST_SUB, scope: 'drawing' },
    ];
    globalThis.fetch = async (url) => {
      const u = String(url);
      if (u.endsWith('/.well-known/jwks.json')) {
        return { ok: true, json: async () => ({ keys: [jwk] }) };
      }
      if (u.includes('/rest/v1/conversations')) {
        return { ok: true, json: async () => rows };
      }
      return { ok: true, json: async () => ({}) };
    };
    const req = new Request('https://drawevolve-backend.test/v1/eve/conversations', {
      method: 'GET',
      headers: eveAuthHeaders(jwt),
    });
    const res = await handleEve(req, env, ctx);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.deepEqual(body.conversations.map((c) => c.id), ['c1', 'c2']);
  } finally { restore(); }
});

test('handleEve GET /v1/eve/conversations/:id returns conversation + messages', async () => {
  const { env, ctx, jwt, jwk, restore } = await setupEveEnv();
  try {
    const conv = { id: EVE_CONVERSATION_ID, user_id: TEST_SUB, scope: 'general' };
    const msgs = [
      { id: 'm1', role: 'user', content: 'hi' },
      { id: 'm2', role: 'assistant', content: 'hello' },
    ];
    globalThis.fetch = async (url) => {
      const u = String(url);
      if (u.endsWith('/.well-known/jwks.json')) {
        return { ok: true, json: async () => ({ keys: [jwk] }) };
      }
      if (u.includes('/rest/v1/conversations') && u.includes(`id=eq.${EVE_CONVERSATION_ID}`)) {
        return { ok: true, json: async () => ([conv]) };
      }
      if (u.includes('/rest/v1/conversation_messages')) {
        return { ok: true, json: async () => msgs };
      }
      return { ok: true, json: async () => ({}) };
    };
    const req = new Request(`https://drawevolve-backend.test/v1/eve/conversations/${EVE_CONVERSATION_ID}`, {
      method: 'GET',
      headers: eveAuthHeaders(jwt),
    });
    const res = await handleEve(req, env, ctx);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.conversation.id, EVE_CONVERSATION_ID);
    assert.equal(body.messages.length, 2);
  } finally { restore(); }
});

test('handleEve GET /v1/eve/conversations/:id returns 404 when the row is missing or not owned', async () => {
  const { env, ctx, jwt, jwk, restore } = await setupEveEnv();
  try {
    globalThis.fetch = async (url) => {
      const u = String(url);
      if (u.endsWith('/.well-known/jwks.json')) {
        return { ok: true, json: async () => ({ keys: [jwk] }) };
      }
      if (u.includes('/rest/v1/conversations')) {
        return { ok: true, json: async () => ([]) };
      }
      return { ok: true, json: async () => ({}) };
    };
    const req = new Request(`https://drawevolve-backend.test/v1/eve/conversations/${EVE_CONVERSATION_ID}`, {
      method: 'GET',
      headers: eveAuthHeaders(jwt),
    });
    const res = await handleEve(req, env, ctx);
    assert.equal(res.status, 404);
  } finally { restore(); }
});

test('handleEve DELETE /v1/eve/conversations/:id soft-deletes and returns ok', async () => {
  const { env, ctx, jwt, jwk, restore } = await setupEveEnv();
  try {
    const calls = [];
    globalThis.fetch = async (url, init) => {
      const u = String(url);
      calls.push({ url: u, method: init?.method ?? 'GET' });
      if (u.endsWith('/.well-known/jwks.json')) {
        return { ok: true, json: async () => ({ keys: [jwk] }) };
      }
      if (u.includes('/rest/v1/conversations') && init?.method === 'PATCH') {
        return { ok: true, json: async () => ([{ id: EVE_CONVERSATION_ID }]) };
      }
      return { ok: true, json: async () => ({}) };
    };
    const req = new Request(`https://drawevolve-backend.test/v1/eve/conversations/${EVE_CONVERSATION_ID}`, {
      method: 'DELETE',
      headers: eveAuthHeaders(jwt),
    });
    const res = await handleEve(req, env, ctx);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.ok, true);
    // Must have made a PATCH request to conversations (the soft delete).
    assert.ok(calls.some((c) => c.method === 'PATCH' && c.url.includes('/rest/v1/conversations')));
  } finally { restore(); }
});

test('handleEve POST /v1/eve/conversations/:id/messages full happy path (general scope)', async () => {
  const { env, ctx, jwt, jwk, restore } = await setupEveEnv();
  try {
    const conv = {
      id: EVE_CONVERSATION_ID,
      user_id: TEST_SUB,
      scope: 'general',
      message_count: 0,
      scope_drawing_id: null,
      scope_critique_sequence: null,
    };
    const userRow = { id: 'umsg', role: 'user', content: 'hi Eve' };
    const assistantRow = { id: 'amsg', role: 'assistant', content: 'Hello back!' };
    let openaiCalls = 0;

    globalThis.fetch = async (url, init) => {
      const u = String(url);
      if (u.endsWith('/.well-known/jwks.json')) {
        return { ok: true, json: async () => ({ keys: [jwk] }) };
      }
      // Idempotency lookup
      if (u.includes('/rest/v1/conversation_messages')
          && u.includes('role=eq.assistant')
          && u.includes('client_request_id=eq.')) {
        return { ok: true, json: async () => ([]) };
      }
      // Conversation fetch (both pre- and post-bump call this)
      if (u.includes('/rest/v1/conversations')
          && u.includes(`id=eq.${EVE_CONVERSATION_ID}`)
          && (!init || init.method === 'GET' || init.method === undefined)) {
        return { ok: true, json: async () => ([conv]) };
      }
      // Conversation history (no prior turns yet)
      if (u.includes('/rest/v1/conversation_messages')
          && u.includes('order=created_at.asc')) {
        return { ok: true, json: async () => ([]) };
      }
      // Append user message + append assistant message
      if (u.endsWith('/rest/v1/conversation_messages') && init?.method === 'POST') {
        const body = JSON.parse(init.body);
        return { ok: true, json: async () => ([body.role === 'user' ? userRow : assistantRow]) };
      }
      // Conversation counters PATCH
      if (u.includes('/rest/v1/conversations') && init?.method === 'PATCH') {
        return { ok: true, json: async () => ({}) };
      }
      // OpenAI
      if (u.includes('api.openai.com/v1/chat/completions')) {
        openaiCalls += 1;
        return {
          ok: true,
          json: async () => ({
            choices: [{ message: { content: 'Hello back!' } }],
            usage: { prompt_tokens: 200, completion_tokens: 80 },
          }),
          text: async () => '',
        };
      }
      return { ok: true, json: async () => ({}) };
    };

    const req = new Request(
      `https://drawevolve-backend.test/v1/eve/conversations/${EVE_CONVERSATION_ID}/messages`,
      {
        method: 'POST',
        headers: eveAuthHeaders(jwt),
        body: JSON.stringify({
          content: 'hi Eve',
          client_request_id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        }),
      },
    );
    const res = await handleEve(req, env, ctx);
    assert.equal(res.status, 200, 'expected 200 on happy path');
    const body = await res.json();
    assert.equal(body.user_message.role, 'user');
    assert.equal(body.assistant_message.role, 'assistant');
    assert.equal(body.assistant_message.content, 'Hello back!');
    assert.equal(openaiCalls, 1, 'OpenAI must be called exactly once');
  } finally { restore(); }
});

test('handleEve POST /:id/messages does NOT put client_request_id on the user row (would collide with assistant row via unique constraint)', async () => {
  // Regression for prod 23505 (2026-05-13): both user + assistant rows
  // were getting the same client_request_id, tripping
  // conversation_messages_idempotency_idx on the assistant insert. Only
  // the assistant row should carry it — that's the row
  // findMessageByClientRequestId looks up for replay.
  const { env, ctx, jwt, jwk, restore } = await setupEveEnv();
  try {
    const conv = {
      id: EVE_CONVERSATION_ID, user_id: TEST_SUB, scope: 'general',
      message_count: 0, scope_drawing_id: null,
    };
    const captured = []; // bodies POSTed to conversation_messages
    globalThis.fetch = async (url, init) => {
      const u = String(url);
      if (u.endsWith('/.well-known/jwks.json')) {
        return { ok: true, json: async () => ({ keys: [jwk] }) };
      }
      if (u.includes('/rest/v1/conversation_messages')
          && u.includes('role=eq.assistant')
          && u.includes('client_request_id=eq.')) {
        return { ok: true, json: async () => ([]) }; // no replay
      }
      if (u.includes('/rest/v1/conversations')
          && u.includes(`id=eq.${EVE_CONVERSATION_ID}`)
          && (!init || init.method === 'GET' || init.method === undefined)) {
        return { ok: true, json: async () => ([conv]) };
      }
      if (u.includes('/rest/v1/conversation_messages')
          && u.includes('order=created_at.asc')) {
        return { ok: true, json: async () => ([]) };
      }
      if (u.endsWith('/rest/v1/conversation_messages') && init?.method === 'POST') {
        const body = JSON.parse(init.body);
        captured.push(body);
        return { ok: true, json: async () => ([{ id: `m-${captured.length}`, ...body }]) };
      }
      if (u.includes('/rest/v1/conversations') && init?.method === 'PATCH') {
        return { ok: true, json: async () => ({}) };
      }
      if (u.includes('api.openai.com')) {
        return {
          ok: true,
          json: async () => ({
            choices: [{ message: { content: 'reply' } }],
            usage: { prompt_tokens: 50, completion_tokens: 20 },
          }),
          text: async () => '',
        };
      }
      return { ok: true, json: async () => ({}) };
    };

    const req = new Request(
      `https://drawevolve-backend.test/v1/eve/conversations/${EVE_CONVERSATION_ID}/messages`,
      {
        method: 'POST',
        headers: eveAuthHeaders(jwt),
        body: JSON.stringify({
          content: 'hello',
          client_request_id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        }),
      },
    );
    const res = await handleEve(req, env, ctx);
    assert.equal(res.status, 200);

    // Exactly two POSTs to conversation_messages: one user, one assistant.
    assert.equal(captured.length, 2,
      `expected two message inserts, saw ${captured.length}`);
    const userInsert = captured.find((b) => b.role === 'user');
    const assistantInsert = captured.find((b) => b.role === 'assistant');
    assert.ok(userInsert, 'user insert must happen');
    assert.ok(assistantInsert, 'assistant insert must happen');

    // The LOAD-BEARING ASSERTION: user row must NOT carry client_request_id.
    assert.equal(userInsert.client_request_id, null,
      'user row must not carry client_request_id (collides with assistant row via unique index)');
    // Assistant row MUST carry it (used by findMessageByClientRequestId).
    assert.equal(assistantInsert.client_request_id,
      'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      'assistant row must carry the client_request_id for replay lookup');
  } finally { restore(); }
});

test('handleEve POST /:id/messages returns cached assistant row on retry (idempotency replay)', async () => {
  const { env, ctx, jwt, jwk, restore } = await setupEveEnv();
  try {
    const conv = {
      id: EVE_CONVERSATION_ID, user_id: TEST_SUB, scope: 'general',
      message_count: 2, scope_drawing_id: null,
    };
    const cachedAssistant = {
      id: 'cached', role: 'assistant',
      content: 'cached reply', client_request_id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
    };
    let openaiCalls = 0;

    globalThis.fetch = async (url, init) => {
      const u = String(url);
      if (u.endsWith('/.well-known/jwks.json')) {
        return { ok: true, json: async () => ({ keys: [jwk] }) };
      }
      if (u.includes('/rest/v1/conversations') && u.includes(`id=eq.${EVE_CONVERSATION_ID}`)) {
        return { ok: true, json: async () => ([conv]) };
      }
      if (u.includes('/rest/v1/conversation_messages')
          && u.includes('role=eq.assistant')
          && u.includes('client_request_id=eq.')) {
        // Existing assistant row → idempotent replay.
        return { ok: true, json: async () => ([cachedAssistant]) };
      }
      if (u.includes('api.openai.com')) openaiCalls += 1;
      return { ok: true, json: async () => ({}) };
    };

    const req = new Request(
      `https://drawevolve-backend.test/v1/eve/conversations/${EVE_CONVERSATION_ID}/messages`,
      {
        method: 'POST',
        headers: eveAuthHeaders(jwt),
        body: JSON.stringify({
          content: 'retry of an already-answered question',
          client_request_id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        }),
      },
    );
    const res = await handleEve(req, env, ctx);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('X-Idempotent-Replay'), '1');
    const body = await res.json();
    assert.equal(body.assistant_message.id, 'cached');
    assert.equal(openaiCalls, 0, 'OpenAI must not be called on replay');
  } finally { restore(); }
});

test('handleEve POST /:id/messages returns 409 conversation_full when at the turn ceiling', async () => {
  const { env, ctx, jwt, jwk, restore } = await setupEveEnv();
  try {
    // Set the cap low so we don't have to seed hundreds of messages.
    env.EVE_MAX_TURNS_PER_CONVERSATION = '3';
    const conv = {
      id: EVE_CONVERSATION_ID, user_id: TEST_SUB, scope: 'general',
      message_count: 6, // = 3 turns * 2 messages — at the ceiling
      scope_drawing_id: null,
    };
    globalThis.fetch = async (url) => {
      const u = String(url);
      if (u.endsWith('/.well-known/jwks.json')) {
        return { ok: true, json: async () => ({ keys: [jwk] }) };
      }
      if (u.includes('/rest/v1/conversations') && u.includes(`id=eq.${EVE_CONVERSATION_ID}`)) {
        return { ok: true, json: async () => ([conv]) };
      }
      // Idempotency lookup returns nothing.
      if (u.includes('/rest/v1/conversation_messages')) {
        return { ok: true, json: async () => ([]) };
      }
      return { ok: true, json: async () => ({}) };
    };

    const req = new Request(
      `https://drawevolve-backend.test/v1/eve/conversations/${EVE_CONVERSATION_ID}/messages`,
      {
        method: 'POST',
        headers: eveAuthHeaders(jwt),
        body: JSON.stringify({
          content: 'one more',
          client_request_id: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        }),
      },
    );
    const res = await handleEve(req, env, ctx);
    assert.equal(res.status, 409);
    const body = await res.json();
    assert.equal(body.error, 'conversation_full');
  } finally { restore(); }
});

test('handleEve POST /:id/messages rejects oversize content', async () => {
  const { env, ctx, jwt, restore } = await setupEveEnv();
  try {
    const huge = 'A'.repeat(9 * 1024); // 9 KB — over the 8 KB cap
    const req = new Request(
      `https://drawevolve-backend.test/v1/eve/conversations/${EVE_CONVERSATION_ID}/messages`,
      {
        method: 'POST',
        headers: eveAuthHeaders(jwt),
        body: JSON.stringify({
          content: huge,
          client_request_id: 'cccccccc-cccc-cccc-cccc-cccccccccccc',
        }),
      },
    );
    const res = await handleEve(req, env, ctx);
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.match(body.error, /exceeds/);
  } finally { restore(); }
});

test('handleEve unrouted path returns 404; wrong method returns 405', async () => {
  const { env, ctx, jwt, restore } = await setupEveEnv();
  try {
    // Wrong method on /v1/eve/conversations
    const badMethod = new Request('https://drawevolve-backend.test/v1/eve/conversations', {
      method: 'PUT',
      headers: eveAuthHeaders(jwt),
    });
    const r1 = await handleEve(badMethod, env, ctx);
    assert.equal(r1.status, 405);

    // Unmatched sub-path
    const noMatch = new Request('https://drawevolve-backend.test/v1/eve/conversations/xxxx/something', {
      method: 'GET',
      headers: eveAuthHeaders(jwt),
    });
    const r2 = await handleEve(noMatch, env, ctx);
    assert.equal(r2.status, 404);
  } finally { restore(); }
});

// =============================================================================
// Feature 2, Phase 2A.1 — Eve coaching context + persona tightening
// =============================================================================

// ---- parseCritiqueSummary --------------------------------------------------

test('parseCritiqueSummary tier 1: extracts bullets from closed comment block', () => {
  const content = `**Quick Take**
Some critique body.

<!--summary-->
- First takeaway
- Second takeaway
- Third takeaway
<!--/summary-->`;
  assert.deepEqual(
    parseCritiqueSummary(content),
    ['First takeaway', 'Second takeaway', 'Third takeaway'],
  );
});

test('parseCritiqueSummary tier 1: tolerates whitespace + case variations in tags', () => {
  const variants = [
    '<!-- summary --> \n- a\n- b\n<!-- /summary -->',
    '<!--SUMMARY-->\n- a\n- b\n<!--/SUMMARY-->',
    '<!--summary-->\n- a\n- b\n<!--  /  summary  -->',
  ];
  for (const v of variants) {
    assert.deepEqual(parseCritiqueSummary(v), ['a', 'b'], `failed on: ${v}`);
  }
});

test('parseCritiqueSummary tier 1: last-wins when multiple blocks exist', () => {
  // Model wrote a block, reconsidered, wrote another. We use the second.
  const content = `<!--summary-->
- old one
- discarded
<!--/summary-->

later text...

<!--summary-->
- the real one
- final
<!--/summary-->`;
  assert.deepEqual(parseCritiqueSummary(content), ['the real one', 'final']);
});

test('parseCritiqueSummary tier 1: skips non-bullet lines inside the block', () => {
  const content = `<!--summary-->
some preamble
- real bullet 1
random noise
- real bullet 2
<!--/summary-->`;
  assert.deepEqual(parseCritiqueSummary(content), ['real bullet 1', 'real bullet 2']);
});

test('parseCritiqueSummary tier 1: accepts both - and * bullet markers', () => {
  const content = `<!--summary-->
- dashy bullet
* starry bullet
<!--/summary-->`;
  assert.deepEqual(parseCritiqueSummary(content), ['dashy bullet', 'starry bullet']);
});

test('parseCritiqueSummary tier 2: opener with no closer treated as truncated', () => {
  // The completion ran out of tokens mid-summary. We still extract what
  // was written. This is a graceful-degradation path; the iOS parser
  // has the same shape.
  const content = `**Quick Take**
body here

<!--summary-->
- got the first one in
- second one too
- maybe a third`;
  assert.deepEqual(
    parseCritiqueSummary(content),
    ['got the first one in', 'second one too', 'maybe a third'],
  );
});

test('parseCritiqueSummary tier 3: markdown header fallback (## Summary)', () => {
  const content = `body text here

## Summary
- fallback bullet 1
- fallback bullet 2`;
  assert.deepEqual(parseCritiqueSummary(content), ['fallback bullet 1', 'fallback bullet 2']);
});

test('parseCritiqueSummary tier 3: markdown header fallback (**Summary**)', () => {
  const content = `body text here

**Summary:**
- a
- b`;
  assert.deepEqual(parseCritiqueSummary(content), ['a', 'b']);
});

test('parseCritiqueSummary returns [] on legacy critique without any summary block', () => {
  const content = `**Quick Take**
Just a normal critique body, no summary at all.

**Focus Area**
Some focus area.`;
  assert.deepEqual(parseCritiqueSummary(content), []);
});

test('parseCritiqueSummary returns [] on malformed / empty / non-string input', () => {
  assert.deepEqual(parseCritiqueSummary(''), []);
  assert.deepEqual(parseCritiqueSummary(null), []);
  assert.deepEqual(parseCritiqueSummary(undefined), []);
  assert.deepEqual(parseCritiqueSummary(42), []);
  assert.deepEqual(parseCritiqueSummary('<!--summary--><!--/summary-->'), []); // empty block
  assert.deepEqual(parseCritiqueSummary('<!--summary-->\n\n\n<!--/summary-->'), []); // no bullets
});

// ---- fetchCoachingContext --------------------------------------------------

const COACHING_NOW = Date.UTC(2026, 4, 13, 12, 0, 0);
const COACHING_USER = FREE_USER;
const COACHING_CURRENT_DRAWING = '11111111-1111-1111-1111-111111111111';
const COACHING_OTHER_DRAWING = '22222222-2222-2222-2222-222222222222';

function fakeCoachingDrawingRow(overrides = {}) {
  return {
    id: COACHING_OTHER_DRAWING,
    title: 'Forest at Dusk',
    context: { subject: 'landscape' },
    created_at: '2026-05-09T12:00:00.000Z',
    updated_at: '2026-05-11T12:00:00.000Z',
    critique_history: [{
      sequence_number: 1,
      created_at: '2026-05-11T12:00:00.000Z',
      content: `Body of critique.

<!--summary-->
- value structure flat
- try three-zone plan
- squint test reveals it
<!--/summary-->`,
      tags: {
        primary_category: 'value',
        focus_area_text: 'value grouping',
        severity: 3,
      },
    }],
    ...overrides,
  };
}

test('fetchCoachingContext returns empty on missing env config', async () => {
  const out = await fetchCoachingContext({ env: {}, userId: COACHING_USER, now: COACHING_NOW });
  assert.deepEqual(out, { drawings: [], summaries: [] });
});

test('fetchCoachingContext returns empty when userId is missing', async () => {
  const out = await fetchCoachingContext({
    env: TEST_SUPABASE, userId: '', now: COACHING_NOW,
  });
  assert.deepEqual(out, { drawings: [], summaries: [] });
});

test('fetchCoachingContext returns empty on non-ok response', async () => {
  const fetcher = async () => ({ ok: false, status: 503, json: async () => ({}) });
  const out = await fetchCoachingContext({
    env: TEST_SUPABASE, userId: COACHING_USER, now: COACHING_NOW, fetcher,
  });
  assert.deepEqual(out, { drawings: [], summaries: [] });
});

test('fetchCoachingContext returns empty when fetcher throws', async () => {
  const fetcher = async () => { throw new Error('network'); };
  const out = await fetchCoachingContext({
    env: TEST_SUPABASE, userId: COACHING_USER, now: COACHING_NOW, fetcher,
  });
  assert.deepEqual(out, { drawings: [], summaries: [] });
});

test('fetchCoachingContext projects drawing rows to the expected shape', async () => {
  const fetcher = async () => ({
    ok: true,
    json: async () => ([fakeCoachingDrawingRow()]),
  });
  const out = await fetchCoachingContext({
    env: TEST_SUPABASE, userId: COACHING_USER, now: COACHING_NOW, fetcher,
  });
  assert.equal(out.drawings.length, 1);
  const d = out.drawings[0];
  assert.equal(d.drawing_id, COACHING_OTHER_DRAWING);
  assert.equal(d.title, 'Forest at Dusk');
  assert.equal(d.subject, 'landscape');
  assert.equal(d.total_critiques, 1);
  assert.ok(d.last_critique);
  assert.equal(d.last_critique.focus_area_text, 'value grouping');
  assert.equal(d.last_critique.primary_category, 'value');
  assert.equal(d.last_critique.severity, 3);
});

test('fetchCoachingContext projects summaries with parsed bullets, newest first', async () => {
  // Three rows: A latest, B middle, C oldest. We expect A→B→C order in
  // the summaries list regardless of which row came first from Postgres.
  const rowA = fakeCoachingDrawingRow({
    id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    title: 'A',
    updated_at: '2026-05-11T12:00:00.000Z',
    critique_history: [{
      sequence_number: 1, created_at: '2026-05-11T12:00:00.000Z',
      content: '<!--summary-->\n- A bullet 1\n- A bullet 2\n<!--/summary-->',
      tags: { primary_category: 'composition' },
    }],
  });
  const rowB = fakeCoachingDrawingRow({
    id: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    title: 'B',
    updated_at: '2026-05-10T12:00:00.000Z',
    critique_history: [{
      sequence_number: 1, created_at: '2026-05-10T12:00:00.000Z',
      content: '<!--summary-->\n- B bullet\n<!--/summary-->',
      tags: { primary_category: 'value' },
    }],
  });
  const rowC = fakeCoachingDrawingRow({
    id: 'cccccccc-cccc-cccc-cccc-cccccccccccc',
    title: 'C',
    updated_at: '2026-05-08T12:00:00.000Z',
    critique_history: [{
      sequence_number: 1, created_at: '2026-05-08T12:00:00.000Z',
      content: '<!--summary-->\n- C bullet\n<!--/summary-->',
      tags: { primary_category: 'line' },
    }],
  });
  const fetcher = async () => ({ ok: true, json: async () => ([rowA, rowB, rowC]) });
  const out = await fetchCoachingContext({
    env: TEST_SUPABASE, userId: COACHING_USER, now: COACHING_NOW, fetcher,
  });
  assert.equal(out.summaries.length, 3);
  assert.deepEqual(out.summaries.map((s) => s.drawing_title), ['A', 'B', 'C']);
  assert.deepEqual(out.summaries[0].summary_bullets, ['A bullet 1', 'A bullet 2']);
});

test('fetchCoachingContext excludeDrawingId drops that drawing from drawings list', async () => {
  const fetcher = async () => ({
    ok: true,
    json: async () => ([
      fakeCoachingDrawingRow({ id: COACHING_CURRENT_DRAWING.toUpperCase(), title: 'current' }),
      fakeCoachingDrawingRow({ id: 'd-keeper', title: 'keeper' }),
    ]),
  });
  const out = await fetchCoachingContext({
    env: TEST_SUPABASE, userId: COACHING_USER, now: COACHING_NOW,
    excludeDrawingId: COACHING_CURRENT_DRAWING, fetcher,
  });
  assert.equal(out.drawings.length, 1);
  assert.equal(out.drawings[0].title, 'keeper');
});

test('fetchCoachingContext excludeCritiqueSequence drops only that specific critique from summaries', async () => {
  // Same drawing, two critiques. We exclude sequence 2 — sequence 1
  // should still appear in summaries since it's on the same drawing
  // but a different critique.
  const fetcher = async () => ({
    ok: true,
    json: async () => ([fakeCoachingDrawingRow({
      id: COACHING_CURRENT_DRAWING,
      title: 'Forest at Dusk',
      critique_history: [
        {
          sequence_number: 1, created_at: '2026-05-08T12:00:00.000Z',
          content: '<!--summary-->\n- seq 1 bullet\n<!--/summary-->',
          tags: { primary_category: 'composition' },
        },
        {
          sequence_number: 2, created_at: '2026-05-11T12:00:00.000Z',
          content: '<!--summary-->\n- seq 2 bullet (excluded)\n<!--/summary-->',
          tags: { primary_category: 'value' },
        },
      ],
    })]),
  });
  const out = await fetchCoachingContext({
    env: TEST_SUPABASE, userId: COACHING_USER, now: COACHING_NOW,
    excludeDrawingId: COACHING_CURRENT_DRAWING,
    excludeCritiqueSequence: 2,
    fetcher,
  });
  // Drawing is excluded entirely from drawings list (it's the current).
  assert.equal(out.drawings.length, 0);
  // Summary for sequence 1 survives even though same drawing.
  assert.equal(out.summaries.length, 1);
  assert.equal(out.summaries[0].critique_sequence, 1);
  assert.deepEqual(out.summaries[0].summary_bullets, ['seq 1 bullet']);
});

test('fetchCoachingContext respects drawingsLimit + summariesLimit', async () => {
  // Build 30 drawings each with one critique that has a summary.
  const rows = Array.from({ length: 30 }, (_, i) => fakeCoachingDrawingRow({
    id: `d${i.toString().padStart(8, '0')}-aaaa-aaaa-aaaa-aaaaaaaaaaaa`,
    updated_at: new Date(COACHING_NOW - i * 86400000).toISOString(),
    critique_history: [{
      sequence_number: 1,
      created_at: new Date(COACHING_NOW - i * 86400000).toISOString(),
      content: '<!--summary-->\n- a bullet\n<!--/summary-->',
      tags: { primary_category: 'composition' },
    }],
  }));
  const fetcher = async () => ({ ok: true, json: async () => rows });
  const out = await fetchCoachingContext({
    env: TEST_SUPABASE, userId: COACHING_USER, now: COACHING_NOW,
    drawingsLimit: 5, summariesLimit: 3, fetcher,
  });
  assert.equal(out.drawings.length, 5);
  assert.equal(out.summaries.length, 3);
});

test('fetchCoachingContext drops summaries with no parseable bullets', async () => {
  // Two rows: one with a real summary, one with no summary block.
  const fetcher = async () => ({
    ok: true,
    json: async () => ([
      fakeCoachingDrawingRow({
        id: 'with-summary-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        title: 'has-summary',
        critique_history: [{
          sequence_number: 1, created_at: '2026-05-11T12:00:00.000Z',
          content: '<!--summary-->\n- real bullet\n<!--/summary-->',
          tags: { primary_category: 'value' },
        }],
      }),
      fakeCoachingDrawingRow({
        id: 'no-summary-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        title: 'no-summary',
        critique_history: [{
          sequence_number: 1, created_at: '2026-05-11T12:00:00.000Z',
          content: 'a critique without any summary block',
          tags: { primary_category: 'value' },
        }],
      }),
    ]),
  });
  const out = await fetchCoachingContext({
    env: TEST_SUPABASE, userId: COACHING_USER, now: COACHING_NOW, fetcher,
  });
  // Both drawings appear in drawings list.
  assert.equal(out.drawings.length, 2);
  // Only the one with a parseable summary appears in summaries.
  assert.equal(out.summaries.length, 1);
  assert.equal(out.summaries[0].drawing_title, 'has-summary');
});

// ---- renderCoachingContextBlock --------------------------------------------

test('renderCoachingContextBlock returns null on missing / empty coachingContext', () => {
  assert.equal(renderCoachingContextBlock(null), null);
  assert.equal(renderCoachingContextBlock(undefined), null);
  assert.equal(renderCoachingContextBlock({}), null);
  assert.equal(renderCoachingContextBlock({ drawings: [], summaries: [] }), null);
});

test('renderCoachingContextBlock renders drawings-only when summaries are empty', () => {
  const block = renderCoachingContextBlock({
    drawings: [{
      drawing_id: 'd1', title: 'Forest at Dusk', subject: 'landscape',
      relative_time: '3 days ago', total_critiques: 2,
      last_critique: { relative_time: '2 days ago', focus_area_text: 'value grouping', primary_category: 'value', severity: 3 },
    }],
    summaries: [],
  });
  assert.ok(block.includes('YOUR DRAWING JOURNEY'));
  assert.ok(block.includes('"Forest at Dusk"'));
  assert.ok(block.includes('value grouping'));
  assert.ok(!block.includes('Recent critique summaries'),
    'summaries header must be absent when no summaries');
});

test('renderCoachingContextBlock renders summaries-only when drawings are empty', () => {
  const block = renderCoachingContextBlock({
    drawings: [],
    summaries: [{
      drawing_id: 'd1', drawing_title: 'Forest at Dusk', drawing_subject: 'landscape',
      relative_time: '2 days ago',
      summary_bullets: ['value structure flat', 'try three-zone plan'],
    }],
  });
  assert.ok(block.includes('YOUR DRAWING JOURNEY'));
  assert.ok(!block.includes("You're working on these drawings"),
    'drawings header must be absent when no drawings');
  assert.ok(block.includes('Recent critique summaries'));
  assert.ok(block.includes('value structure flat'));
});

test('renderCoachingContextBlock applies fallbacks (Untitled, no subject, no last critique)', () => {
  const block = renderCoachingContextBlock({
    drawings: [{
      drawing_id: 'd1', title: null, subject: '',
      relative_time: '2 weeks ago', total_critiques: 0,
      last_critique: null,
    }],
    summaries: [],
  });
  assert.ok(block.includes('"Untitled"'));
  assert.ok(block.includes('no critique yet'));
  // No empty subject parenthetical like "(, 2 weeks ago)".
  assert.ok(!block.includes('(, '), `block contains stray comma: ${block}`);
});

test('renderCoachingContextBlock keeps the "never imply you have seen the drawings" guardrail', () => {
  // Load-bearing per Eve's audit. Regression guard so future copy edits
  // don't drop the anti-hallucination clause.
  const block = renderCoachingContextBlock({
    drawings: [{ drawing_id: 'd1', title: 'X', relative_time: 'today', total_critiques: 0, last_critique: null }],
    summaries: [],
  });
  assert.ok(block.includes("never imply you've seen the actual drawings"),
    'anti-hallucination clause is load-bearing — do not remove');
  assert.ok(block.includes("I haven't seen it"),
    'redirect line is load-bearing');
});

// ---- buildEveSystemPrompt with coachingContext -----------------------------

test('buildEveSystemPrompt includes coaching context block when present', () => {
  const sys = buildEveSystemPrompt({
    scope: 'general',
    critique: null,
    coachingContext: {
      drawings: [{ drawing_id: 'd1', title: 'Forest at Dusk', subject: 'landscape',
                   relative_time: '3 days ago', total_critiques: 1,
                   last_critique: { relative_time: '3 days ago', focus_area_text: 'value', primary_category: 'value', severity: 2 } }],
      summaries: [],
    },
  });
  assert.ok(sys.includes('YOUR DRAWING JOURNEY'));
  assert.ok(sys.includes('"Forest at Dusk"'));
});

test('buildEveSystemPrompt omits coaching block when coachingContext is empty', () => {
  const sys = buildEveSystemPrompt({
    scope: 'general',
    critique: null,
    coachingContext: { drawings: [], summaries: [] },
  });
  assert.ok(!sys.includes('YOUR DRAWING JOURNEY'),
    'empty coaching context must not render the block');
});

test('buildEveSystemPrompt omits coaching block when coachingContext is undefined (backwards compat)', () => {
  const sys = buildEveSystemPrompt({ scope: 'general', critique: null });
  assert.ok(!sys.includes('YOUR DRAWING JOURNEY'));
  // Persona + product context still present.
  assert.ok(sys.includes('You are Eve'));
  assert.ok(sys.includes('ABOUT DRAWEVOLVE'));
});

test('buildEveSystemPrompt places coaching context BEFORE current context', () => {
  // Order matters: the current critique is the conversation anchor and
  // should be the freshest thing in the model's recall.
  const sys = buildEveSystemPrompt({
    scope: 'drawing',
    critique: {
      drawing_title: 'Current Piece',
      drawing_subject: 'still life',
      sequence_number: 2,
      content: 'full critique markdown body',
    },
    coachingContext: {
      drawings: [{ drawing_id: 'd1', title: 'Other Drawing', subject: 'portrait',
                   relative_time: '5 days ago', total_critiques: 1,
                   last_critique: { relative_time: '5 days ago', focus_area_text: 'edges', primary_category: 'line', severity: 2 } }],
      summaries: [],
    },
  });
  const coachingIdx = sys.indexOf('YOUR DRAWING JOURNEY');
  const currentIdx = sys.indexOf('CURRENT CONTEXT:');
  assert.ok(coachingIdx >= 0, 'coaching block must render');
  assert.ok(currentIdx >= 0, 'current context block must render');
  assert.ok(coachingIdx < currentIdx,
    'coaching context must precede current context');
});

// ---- Persona / product-context regression guards ---------------------------

test('EVE_PERSONA_VERSION is 3 (Phase 2A.1)', () => {
  assert.equal(EVE_PERSONA_VERSION, 3);
});

test('EVE_PRODUCT_CONTEXT_VERSION is 2 (Phase 2A.1)', () => {
  assert.equal(EVE_PRODUCT_CONTEXT_VERSION, 2);
});

test('EVE_PERSONA contains brevity ceiling, hard domain boundary, tool recommendations', () => {
  // Load-bearing copy. Regression guards so future edits don't silently
  // drop the rules that govern Eve's verbosity, domain scope, or tool
  // recommendation behavior.
  assert.ok(EVE_PERSONA.includes('Default response length: 1-3 sentences'));
  assert.ok(EVE_PERSONA.includes('No headers, no bullet lists'));
  assert.ok(EVE_PERSONA.includes('Use markdown structure'));
  assert.ok(EVE_PERSONA.includes("That's outside what I help with"),
    'hard domain boundary redirect line must be present');
  assert.ok(EVE_PERSONA.includes('TOOL RECOMMENDATIONS:'));
  assert.ok(EVE_PERSONA.includes('name both what it does and what to look for visually'),
    'function-name-plus-icon-name instruction must be present');
  // Pattern catalogue lives in the persona too.
  assert.ok(EVE_PERSONA.includes('figure pose reference overlay'));
  assert.ok(EVE_PERSONA.includes('blur adjustment'));
});

test('EVE_PRODUCT_CONTEXT contains tile-location naming for tools', () => {
  assert.ok(EVE_PRODUCT_CONTEXT.includes('left-side tool rail'));
  assert.ok(EVE_PRODUCT_CONTEXT.includes('filled drop icon'),
    'paint bucket icon name must use the function+icon pattern');
  assert.ok(EVE_PRODUCT_CONTEXT.includes('figure-standing icon'));
  assert.ok(EVE_PRODUCT_CONTEXT.includes('raised-hand icon'));
  assert.ok(EVE_PRODUCT_CONTEXT.includes('right-side action column'),
    'app chrome location should be distinct from tool rail');
});

// ---- Integration: handleSendMessage threads coaching context through ------

test('handleEve POST /:id/messages fetches coaching context and includes it in the system prompt', async () => {
  const { env, ctx, jwt, jwk, restore } = await setupEveEnv();
  try {
    const conv = {
      id: EVE_CONVERSATION_ID, user_id: TEST_SUB, scope: 'general',
      message_count: 0, scope_drawing_id: null, scope_critique_sequence: null,
    };
    let openaiCallSystemPrompt = '';
    let coachingFetchHit = false;
    globalThis.fetch = async (url, init) => {
      const u = String(url);
      if (u.endsWith('/.well-known/jwks.json')) {
        return { ok: true, json: async () => ({ keys: [jwk] }) };
      }
      if (u.includes('/rest/v1/conversation_messages')
          && u.includes('role=eq.assistant')
          && u.includes('client_request_id=eq.')) {
        return { ok: true, json: async () => ([]) };
      }
      if (u.includes('/rest/v1/conversations')
          && u.includes(`id=eq.${EVE_CONVERSATION_ID}`)
          && (!init || init.method === 'GET' || init.method === undefined)) {
        return { ok: true, json: async () => ([conv]) };
      }
      if (u.includes('/rest/v1/drawings')
          && u.includes(`user_id=eq.${TEST_SUB}`)
          && u.includes('select=id,title,context,created_at,updated_at,critique_history')) {
        // This is the coaching-context fetch. Return one drawing with a summary.
        coachingFetchHit = true;
        return {
          ok: true,
          json: async () => ([{
            id: 'd-coach-1', title: 'Test Drawing',
            context: { subject: 'portrait' },
            created_at: '2026-05-10T12:00:00.000Z',
            updated_at: '2026-05-11T12:00:00.000Z',
            critique_history: [{
              sequence_number: 1, created_at: '2026-05-11T12:00:00.000Z',
              content: '<!--summary-->\n- coaching bullet wired through\n<!--/summary-->',
              tags: { primary_category: 'value' },
            }],
          }]),
        };
      }
      if (u.includes('/rest/v1/conversation_messages')
          && u.includes('order=created_at.asc')) {
        return { ok: true, json: async () => ([]) };
      }
      if (u.endsWith('/rest/v1/conversation_messages') && init?.method === 'POST') {
        const body = JSON.parse(init.body);
        return { ok: true, json: async () => ([{ id: `m-${body.role}`, ...body }]) };
      }
      if (u.includes('/rest/v1/conversations') && init?.method === 'PATCH') {
        return { ok: true, json: async () => ({}) };
      }
      if (u.includes('api.openai.com')) {
        // Capture the system prompt the model would see so we can assert
        // the coaching context made it in.
        const body = JSON.parse(init.body);
        openaiCallSystemPrompt = body.messages?.[0]?.content ?? '';
        return {
          ok: true,
          json: async () => ({
            choices: [{ message: { content: 'reply' } }],
            usage: { prompt_tokens: 100, completion_tokens: 30 },
          }),
          text: async () => '',
        };
      }
      return { ok: true, json: async () => ({}) };
    };

    const req = new Request(
      `https://drawevolve-backend.test/v1/eve/conversations/${EVE_CONVERSATION_ID}/messages`,
      {
        method: 'POST',
        headers: eveAuthHeaders(jwt),
        body: JSON.stringify({
          content: 'hi Eve',
          client_request_id: 'aaaaaaaa-1111-1111-1111-111111111111',
        }),
      },
    );
    const res = await handleEve(req, env, ctx);
    assert.equal(res.status, 200);
    assert.equal(coachingFetchHit, true,
      'handleSendMessage must fetch coaching context');
    assert.ok(openaiCallSystemPrompt.includes('YOUR DRAWING JOURNEY'),
      'OpenAI system prompt must include the coaching context block');
    assert.ok(openaiCallSystemPrompt.includes('coaching bullet wired through'),
      'OpenAI system prompt must include the parsed summary bullets');
  } finally { restore(); }
});

test('handleEve POST /:id/messages on drawing scope excludes current drawing + sequence from coaching context', async () => {
  const { env, ctx, jwt, jwk, restore } = await setupEveEnv();
  try {
    const CURRENT_DRAWING = '33333333-3333-3333-3333-333333333333';
    const conv = {
      id: EVE_CONVERSATION_ID, user_id: TEST_SUB, scope: 'drawing',
      message_count: 0,
      scope_drawing_id: CURRENT_DRAWING,
      scope_critique_sequence: 2,
    };
    let openaiCallSystemPrompt = '';
    globalThis.fetch = async (url, init) => {
      const u = String(url);
      if (u.endsWith('/.well-known/jwks.json')) {
        return { ok: true, json: async () => ({ keys: [jwk] }) };
      }
      if (u.includes('/rest/v1/conversation_messages')
          && u.includes('role=eq.assistant')
          && u.includes('client_request_id=eq.')) {
        return { ok: true, json: async () => ([]) };
      }
      if (u.includes('/rest/v1/conversations')
          && u.includes(`id=eq.${EVE_CONVERSATION_ID}`)
          && (!init || init.method === 'GET' || init.method === undefined)) {
        return { ok: true, json: async () => ([conv]) };
      }
      // CURRENT critique fetch (for the CURRENT CONTEXT block) — matches
      // a different select shape than coaching context.
      if (u.includes('/rest/v1/drawings')
          && u.includes(`id=eq.${CURRENT_DRAWING}`)
          && u.includes('select=id,title,context,critique_history')) {
        return {
          ok: true,
          json: async () => ([{
            id: CURRENT_DRAWING, title: 'Current Anchor',
            context: { subject: 'portrait' },
            critique_history: [
              { sequence_number: 2, created_at: '2026-05-11T12:00:00.000Z',
                content: 'this is the full anchor critique body',
                tags: { primary_category: 'value' } },
            ],
          }]),
        };
      }
      // COACHING context fetch — returns the current drawing AND another.
      // The current drawing should get filtered from the drawings list,
      // and any summary tied to (current drawing, seq 2) should be filtered
      // from summaries.
      if (u.includes('/rest/v1/drawings')
          && u.includes(`user_id=eq.${TEST_SUB}`)
          && u.includes('select=id,title,context,created_at,updated_at,critique_history')) {
        return {
          ok: true,
          json: async () => ([
            // The current drawing — should NOT appear in coaching drawings.
            {
              id: CURRENT_DRAWING, title: 'Current Anchor',
              context: { subject: 'portrait' },
              created_at: '2026-05-09T12:00:00.000Z',
              updated_at: '2026-05-11T12:00:00.000Z',
              critique_history: [{
                sequence_number: 2, created_at: '2026-05-11T12:00:00.000Z',
                content: '<!--summary-->\n- excluded summary\n<!--/summary-->',
                tags: { primary_category: 'value' },
              }],
            },
            // Another drawing — SHOULD appear.
            {
              id: 'd-other-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
              title: 'Other Drawing',
              context: { subject: 'landscape' },
              created_at: '2026-05-05T12:00:00.000Z',
              updated_at: '2026-05-08T12:00:00.000Z',
              critique_history: [{
                sequence_number: 1, created_at: '2026-05-08T12:00:00.000Z',
                content: '<!--summary-->\n- KEEPER SUMMARY BULLET\n<!--/summary-->',
                tags: { primary_category: 'composition' },
              }],
            },
          ]),
        };
      }
      if (u.includes('/rest/v1/conversation_messages')
          && u.includes('order=created_at.asc')) {
        return { ok: true, json: async () => ([]) };
      }
      if (u.endsWith('/rest/v1/conversation_messages') && init?.method === 'POST') {
        const body = JSON.parse(init.body);
        return { ok: true, json: async () => ([{ id: `m-${body.role}`, ...body }]) };
      }
      if (u.includes('/rest/v1/conversations') && init?.method === 'PATCH') {
        return { ok: true, json: async () => ({}) };
      }
      if (u.includes('api.openai.com')) {
        const body = JSON.parse(init.body);
        openaiCallSystemPrompt = body.messages?.[0]?.content ?? '';
        return {
          ok: true,
          json: async () => ({
            choices: [{ message: { content: 'reply' } }],
            usage: { prompt_tokens: 200, completion_tokens: 40 },
          }),
          text: async () => '',
        };
      }
      return { ok: true, json: async () => ({}) };
    };

    const req = new Request(
      `https://drawevolve-backend.test/v1/eve/conversations/${EVE_CONVERSATION_ID}/messages`,
      {
        method: 'POST',
        headers: eveAuthHeaders(jwt),
        body: JSON.stringify({
          content: 'hi',
          client_request_id: 'bbbbbbbb-2222-2222-2222-222222222222',
        }),
      },
    );
    const res = await handleEve(req, env, ctx);
    assert.equal(res.status, 200);

    // Current drawing must NOT appear in the coaching context drawing list.
    // We check for the keeper title positively and the excluded-via-summary
    // bullet negatively.
    assert.ok(openaiCallSystemPrompt.includes('"Other Drawing"'),
      'other (non-current) drawing must appear in coaching block');
    assert.ok(openaiCallSystemPrompt.includes('KEEPER SUMMARY BULLET'),
      'other drawing\'s summary must appear');
    assert.ok(!openaiCallSystemPrompt.includes('excluded summary'),
      'current drawing + current sequence summary must NOT appear in coaching context');

    // CURRENT CONTEXT block must include the full anchor critique.
    assert.ok(openaiCallSystemPrompt.includes('CURRENT CONTEXT:'),
      'CURRENT CONTEXT block must render');
    assert.ok(openaiCallSystemPrompt.includes('this is the full anchor critique body'),
      'full critique body must appear in CURRENT CONTEXT');
  } finally { restore(); }
});

// =============================================================================
// Phase 4 — Subject Recommendations
// =============================================================================

// ---- isRecommendationsEnabled (kill switch) --------------------------------

test('isRecommendationsEnabled is strict — only the literal string "true" enables', () => {
  assert.equal(isRecommendationsEnabled({ RECOMMENDATIONS_ENABLED: 'true' }), true);
  assert.equal(isRecommendationsEnabled({ RECOMMENDATIONS_ENABLED: 'false' }), false);
  assert.equal(isRecommendationsEnabled({ RECOMMENDATIONS_ENABLED: '' }), false);
  assert.equal(isRecommendationsEnabled({ RECOMMENDATIONS_ENABLED: 'TRUE' }), false);
  assert.equal(isRecommendationsEnabled({ RECOMMENDATIONS_ENABLED: '1' }), false);
  assert.equal(isRecommendationsEnabled({ RECOMMENDATIONS_ENABLED: true }), false);
  assert.equal(isRecommendationsEnabled({}), false);
  assert.equal(isRecommendationsEnabled(null), false);
});

// ---- RECOMMENDATIONS_SCHEMA + system prompt regression guards --------------

test('RECOMMENDATIONS_PROMPT_VERSION is 3 (Phase 4 + brevity + capitalization + focus_area format)', () => {
  assert.equal(RECOMMENDATIONS_PROMPT_VERSION, 3);
});

test('RECOMMENDATIONS_SYSTEM_PROMPT contains the three load-bearing mix rules', () => {
  // Regression guard: don't drop the skill_targeting / variety / stretch
  // mix rule without a deliberate version bump.
  assert.ok(RECOMMENDATIONS_SYSTEM_PROMPT.includes('Skill targeting'));
  assert.ok(RECOMMENDATIONS_SYSTEM_PROMPT.includes('Variety'));
  assert.ok(RECOMMENDATIONS_SYSTEM_PROMPT.includes('Stretch'));
  assert.ok(RECOMMENDATIONS_SYSTEM_PROMPT.includes('exactly 5'));
  assert.ok(RECOMMENDATIONS_SYSTEM_PROMPT.includes('fundamentals'),
    'empty-portfolio fallback instruction must be present');
});

test('RECOMMENDATIONS_SYSTEM_PROMPT contains the brevity guardrails (v2)', () => {
  // Live testing on 2026-05-13 showed the model producing 100+ char
  // subjects that hit the schema cap mid-word. v2 added explicit brevity
  // rules + good/bad examples. Don't drop them without a version bump.
  assert.ok(RECOMMENDATIONS_SYSTEM_PROMPT.includes('under 10 words'));
  assert.ok(RECOMMENDATIONS_SYSTEM_PROMPT.includes('headline only'));
  assert.ok(RECOMMENDATIONS_SYSTEM_PROMPT.includes('GOOD SUBJECT LENGTHS'));
  assert.ok(RECOMMENDATIONS_SYSTEM_PROMPT.includes('BAD SUBJECT LENGTHS'));
});

test('RECOMMENDATIONS_SYSTEM_PROMPT contains capitalization + focus_area format rules (v3)', () => {
  // Live testing on 2026-05-13 evening showed the model emitting
  // all-lowercase subjects ("one-page of single-stroke circles") and
  // snake_case focus areas ("line_control"). v3 forces sentence-case
  // subjects + plain-English focus phrases. Don't drop these without
  // a version bump.
  assert.ok(RECOMMENDATIONS_SYSTEM_PROMPT.includes('capital letter'),
    'capitalization rule must be present');
  assert.ok(RECOMMENDATIONS_SYSTEM_PROMPT.includes('NEVER all-lowercase'),
    'NEVER all-lowercase rule must be present');
  assert.ok(RECOMMENDATIONS_SYSTEM_PROMPT.includes('FOCUS AREA FORMAT'),
    'focus_area format section header must be present');
  assert.ok(RECOMMENDATIONS_SYSTEM_PROMPT.includes('Never snake_case'),
    'snake_case prohibition must be present');
  assert.ok(RECOMMENDATIONS_SYSTEM_PROMPT.includes('plain-English'),
    'plain-English requirement must be present');
});

test('RECOMMENDATIONS_SCHEMA enforces minItems and maxItems at 5', () => {
  assert.equal(RECOMMENDATIONS_SCHEMA.schema.properties.recommendations.minItems, 5);
  assert.equal(RECOMMENDATIONS_SCHEMA.schema.properties.recommendations.maxItems, 5);
  assert.equal(RECOMMENDATIONS_SCHEMA.strict, true);
  // additionalProperties: false on both levels — OpenAI's strict mode
  // requires this on every object in the schema.
  assert.equal(RECOMMENDATIONS_SCHEMA.schema.additionalProperties, false);
  assert.equal(RECOMMENDATIONS_SCHEMA.schema.properties.recommendations.items.additionalProperties, false);
});

test('RECOMMENDATIONS_SCHEMA enum stays at the agreed 3 values', () => {
  const enums = RECOMMENDATIONS_SCHEMA.schema.properties.recommendations.items
    .properties.recommendation_type.enum;
  assert.deepEqual(enums, ['skill_targeting', 'variety', 'stretch']);
});

// ---- buildRecommendationsUserMessage ---------------------------------------

test('buildRecommendationsUserMessage uses fundamentals path on empty portfolio', () => {
  const msg = buildRecommendationsUserMessage({ drawings: [], summaries: [] });
  assert.ok(msg.includes('new user with no drawings yet'));
  assert.ok(msg.includes('fundamentals'));
  assert.ok(msg.includes('exactly 5'));
});

test('buildRecommendationsUserMessage renders drawing rows + summary blocks when present', () => {
  const msg = buildRecommendationsUserMessage({
    drawings: [{
      drawing_id: 'd1', title: 'Forest at Dusk', subject: 'landscape',
      relative_time: '3 days ago', total_critiques: 2,
      last_critique: { focus_area_text: 'value grouping', primary_category: 'value' },
    }],
    summaries: [{
      drawing_id: 'd1', drawing_title: 'Forest at Dusk',
      relative_time: '3 days ago',
      summary_bullets: ['values flat', 'try three-zone'],
    }],
  });
  assert.ok(msg.includes('"Forest at Dusk"'));
  assert.ok(msg.includes('landscape'));
  assert.ok(msg.includes('3 days ago'));
  assert.ok(msg.includes('value grouping'));
  assert.ok(msg.includes('values flat'));
  // No Eve guardrails — recommendations don't reference drawings the
  // user could ask about, they generate new ones.
  assert.ok(!msg.includes('never imply'),
    'Eve guardrail copy must not appear in recommendations user message');
  assert.ok(!msg.includes('YOUR DRAWING JOURNEY'),
    'coaching header is Eve-specific, not for recommendations');
});

test('buildRecommendationsUserMessage gracefully handles malformed coaching context', () => {
  assert.ok(buildRecommendationsUserMessage(null).length > 0);
  assert.ok(buildRecommendationsUserMessage({}).length > 0);
  assert.ok(buildRecommendationsUserMessage({ drawings: 'not-an-array' }).length > 0);
});

// ---- validateRecommendations -----------------------------------------------

function validRec(overrides = {}) {
  return {
    subject: 'still life with three glass objects',
    rationale: 'You have not done a glass study yet and your value work is ready for it.',
    focus_area: 'value structure',
    recommendation_type: 'skill_targeting',
    ...overrides,
  };
}

function validPayload(recs) {
  return { recommendations: recs ?? Array.from({ length: 5 }, () => validRec()) };
}

test('validateRecommendations accepts a well-formed 5-item payload', () => {
  const out = validateRecommendations(validPayload());
  assert.equal(out.ok, true);
  assert.equal(out.value.length, 5);
  assert.equal(out.value[0].subject, 'still life with three glass objects');
});

test('validateRecommendations trims string fields', () => {
  const out = validateRecommendations(validPayload([
    validRec({ subject: '  trim me  ', rationale: '  trim this rationale too  ', focus_area: '  values  ' }),
    validRec(), validRec(), validRec(), validRec(),
  ]));
  assert.equal(out.ok, true);
  assert.equal(out.value[0].subject, 'trim me');
  assert.equal(out.value[0].rationale, 'trim this rationale too');
  assert.equal(out.value[0].focus_area, 'values');
});

test('validateRecommendations rejects wrong count', () => {
  assert.equal(validateRecommendations({ recommendations: [validRec(), validRec(), validRec()] }).ok, false);
  assert.equal(validateRecommendations({ recommendations: Array(6).fill(validRec()) }).ok, false);
  assert.equal(validateRecommendations({ recommendations: [] }).ok, false);
});

test('validateRecommendations rejects missing required fields', () => {
  const baseRecs = Array.from({ length: 4 }, () => validRec());
  assert.equal(validateRecommendations({ recommendations: [...baseRecs, { rationale: 'no subject', focus_area: 'x', recommendation_type: 'variety' }] }).ok, false);
  assert.equal(validateRecommendations({ recommendations: [...baseRecs, validRec({ subject: '' })] }).ok, false);
  assert.equal(validateRecommendations({ recommendations: [...baseRecs, validRec({ rationale: 'too short' }) /* < 10 chars */] }).ok, false);
  assert.equal(validateRecommendations({ recommendations: [...baseRecs, validRec({ recommendation_type: 'unknown_type' })] }).ok, false);
});

test('validateRecommendations rejects oversized strings', () => {
  const baseRecs = Array.from({ length: 4 }, () => validRec());
  // subject max 150 (bumped from 100 on 2026-05-13 after live truncation)
  assert.equal(validateRecommendations({ recommendations: [...baseRecs, validRec({ subject: 'a'.repeat(151) })] }).ok, false);
  // subject at 150 still accepted
  assert.equal(validateRecommendations({ recommendations: [...baseRecs, validRec({ subject: 'a'.repeat(150) })] }).ok, true);
  // rationale max 200
  assert.equal(validateRecommendations({ recommendations: [...baseRecs, validRec({ rationale: 'a'.repeat(201) })] }).ok, false);
  // focus_area max 50
  assert.equal(validateRecommendations({ recommendations: [...baseRecs, validRec({ focus_area: 'a'.repeat(51) })] }).ok, false);
});

test('validateRecommendations rejects non-object / non-array shapes', () => {
  assert.equal(validateRecommendations(null).ok, false);
  assert.equal(validateRecommendations({}).ok, false);
  assert.equal(validateRecommendations({ recommendations: 'not-an-array' }).ok, false);
  assert.equal(validateRecommendations(undefined).ok, false);
});

// ---- handleRecommendations integration -------------------------------------

test('handleRecommendations: 405 on non-POST', async () => {
  _resetJwksCacheForTests();
  const env = { ...TEST_JWT_ENV, RECOMMENDATIONS_ENABLED: 'true', APP_ATTEST_REQUIRED: 'false' };
  const req = new Request('https://drawevolve-backend.test/v1/recommendations', {
    method: 'GET',
  });
  const res = await handleRecommendations(req, env, { waitUntil: () => {} });
  assert.equal(res.status, 405);
});

test('handleRecommendations: 503 when kill switch is off', async () => {
  _resetJwksCacheForTests();
  const env = { ...TEST_JWT_ENV, APP_ATTEST_REQUIRED: 'false' /* RECOMMENDATIONS_ENABLED unset */ };
  const req = new Request('https://drawevolve-backend.test/v1/recommendations', {
    method: 'POST',
    body: '',
  });
  const res = await handleRecommendations(req, env, { waitUntil: () => {} });
  assert.equal(res.status, 503);
  const body = await res.json();
  assert.equal(body.error, 'recommendations_disabled');
});

test('handleRecommendations: 401 on missing / invalid JWT', async () => {
  _resetJwksCacheForTests();
  const { publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const env = {
    ...TEST_JWT_ENV,
    RECOMMENDATIONS_ENABLED: 'true',
    APP_ATTEST_REQUIRED: 'false',
    QUOTA_KV: new FakeKV(),
    SUPABASE_SERVICE_ROLE_KEY: 'fake',
    OPENAI_API_KEY: 'fake',
  };
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    if (String(url).endsWith('/.well-known/jwks.json')) {
      return { ok: true, json: async () => ({ keys: [jwk] }) };
    }
    return { ok: true, json: async () => ({}) };
  };
  try {
    const req = new Request('https://drawevolve-backend.test/v1/recommendations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '',
    });
    const res = await handleRecommendations(req, env, { waitUntil: () => {} });
    assert.equal(res.status, 401);
  } finally { globalThis.fetch = originalFetch; }
});

test('handleRecommendations: happy path returns 5 valid recommendations with empty portfolio', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const env = {
    ...TEST_JWT_ENV,
    RECOMMENDATIONS_ENABLED: 'true',
    APP_ATTEST_REQUIRED: 'false',
    QUOTA_KV: new FakeKV(),
    SUPABASE_SERVICE_ROLE_KEY: 'fake',
    OPENAI_API_KEY: 'fake',
  };

  const fiveRecs = Array.from({ length: 5 }, (_, i) => ({
    subject: `subject ${i + 1} with enough chars`,
    rationale: `rationale ${i + 1} that meets the minimum length cap.`,
    focus_area: `focus${i}`,
    recommendation_type: 'skill_targeting',
  }));

  const originalFetch = globalThis.fetch;
  let openaiCalls = 0;
  let openaiBody = null;
  globalThis.fetch = async (url, init) => {
    const u = String(url);
    if (u.endsWith('/.well-known/jwks.json')) {
      return { ok: true, json: async () => ({ keys: [jwk] }) };
    }
    // Coaching context fetch — empty portfolio.
    if (u.includes('/rest/v1/drawings')
        && u.includes('select=id,title,context,created_at,updated_at,critique_history')) {
      return { ok: true, json: async () => ([]) };
    }
    // OpenAI.
    if (u.includes('api.openai.com')) {
      openaiCalls += 1;
      openaiBody = JSON.parse(init.body);
      return {
        ok: true,
        json: async () => ({
          choices: [{ message: { content: JSON.stringify({ recommendations: fiveRecs }) } }],
          usage: { prompt_tokens: 500, completion_tokens: 300 },
        }),
        text: async () => '',
      };
    }
    return { ok: true, json: async () => ({}) };
  };

  try {
    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const req = new Request('https://drawevolve-backend.test/v1/recommendations', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${jwt}`,
      },
      body: '',
    });
    const res = await handleRecommendations(req, env, { waitUntil: () => {} });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.recommendations.length, 5);
    assert.equal(body.context_summary.drawing_count, 0);
    assert.equal(body.context_summary.summary_count, 0);
    assert.equal(openaiCalls, 1, 'OpenAI must be called exactly once');
    // Confirm strict json_schema mode was used.
    assert.equal(openaiBody.response_format?.type, 'json_schema');
    assert.equal(openaiBody.response_format?.json_schema?.name, 'recommendations');
    assert.equal(openaiBody.response_format?.json_schema?.strict, true);
    // Empty-portfolio user message present.
    const sysMsg = openaiBody.messages[0].content;
    const userMsg = openaiBody.messages[1].content;
    assert.ok(sysMsg.includes('You are a drawing coach'));
    assert.ok(userMsg.includes('new user with no drawings yet'));
  } finally { globalThis.fetch = originalFetch; }
});

test('handleRecommendations: 502 when model returns malformed JSON', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const env = {
    ...TEST_JWT_ENV,
    RECOMMENDATIONS_ENABLED: 'true',
    APP_ATTEST_REQUIRED: 'false',
    QUOTA_KV: new FakeKV(),
    SUPABASE_SERVICE_ROLE_KEY: 'fake',
    OPENAI_API_KEY: 'fake',
  };
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    const u = String(url);
    if (u.endsWith('/.well-known/jwks.json')) {
      return { ok: true, json: async () => ({ keys: [jwk] }) };
    }
    if (u.includes('/rest/v1/drawings')
        && u.includes('select=id,title,context,created_at,updated_at,critique_history')) {
      return { ok: true, json: async () => ([]) };
    }
    if (u.includes('api.openai.com')) {
      return {
        ok: true,
        json: async () => ({
          choices: [{ message: { content: '{not-valid-json' } }],
          usage: { prompt_tokens: 10, completion_tokens: 5 },
        }),
        text: async () => '',
      };
    }
    return { ok: true, json: async () => ({}) };
  };
  try {
    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const req = new Request('https://drawevolve-backend.test/v1/recommendations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${jwt}` },
      body: '',
    });
    const res = await handleRecommendations(req, env, { waitUntil: () => {} });
    assert.equal(res.status, 502);
  } finally { globalThis.fetch = originalFetch; }
});

test('handleRecommendations: 502 when validation rejects model output (wrong count)', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const env = {
    ...TEST_JWT_ENV,
    RECOMMENDATIONS_ENABLED: 'true',
    APP_ATTEST_REQUIRED: 'false',
    QUOTA_KV: new FakeKV(),
    SUPABASE_SERVICE_ROLE_KEY: 'fake',
    OPENAI_API_KEY: 'fake',
  };
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    const u = String(url);
    if (u.endsWith('/.well-known/jwks.json')) {
      return { ok: true, json: async () => ({ keys: [jwk] }) };
    }
    if (u.includes('/rest/v1/drawings')
        && u.includes('select=id,title,context,created_at,updated_at,critique_history')) {
      return { ok: true, json: async () => ([]) };
    }
    if (u.includes('api.openai.com')) {
      // Model returns only 3 recommendations — schema would catch this,
      // but if the schema is ever loosened the validator still bites.
      const onlyThree = Array.from({ length: 3 }, () => validRec());
      return {
        ok: true,
        json: async () => ({
          choices: [{ message: { content: JSON.stringify({ recommendations: onlyThree }) } }],
          usage: { prompt_tokens: 10, completion_tokens: 5 },
        }),
        text: async () => '',
      };
    }
    return { ok: true, json: async () => ({}) };
  };
  try {
    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const req = new Request('https://drawevolve-backend.test/v1/recommendations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${jwt}` },
      body: '',
    });
    const res = await handleRecommendations(req, env, { waitUntil: () => {} });
    assert.equal(res.status, 502);
  } finally { globalThis.fetch = originalFetch; }
});

test('handleRecommendations: happy path with realistic portfolio includes drawings + summaries in user message', async () => {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const env = {
    ...TEST_JWT_ENV,
    RECOMMENDATIONS_ENABLED: 'true',
    APP_ATTEST_REQUIRED: 'false',
    QUOTA_KV: new FakeKV(),
    SUPABASE_SERVICE_ROLE_KEY: 'fake',
    OPENAI_API_KEY: 'fake',
  };

  const fiveRecs = Array.from({ length: 5 }, (_, i) => ({
    subject: `subject ${i + 1} with enough chars`,
    rationale: `rationale ${i + 1} reasonable length.`,
    focus_area: `focus${i}`,
    recommendation_type: i === 0 ? 'skill_targeting' : i === 1 ? 'variety' : 'stretch',
  }));

  const originalFetch = globalThis.fetch;
  let userMsgSeen = '';
  globalThis.fetch = async (url, init) => {
    const u = String(url);
    if (u.endsWith('/.well-known/jwks.json')) {
      return { ok: true, json: async () => ({ keys: [jwk] }) };
    }
    if (u.includes('/rest/v1/drawings')
        && u.includes('select=id,title,context,created_at,updated_at,critique_history')) {
      return {
        ok: true,
        json: async () => ([{
          id: 'd-fixture-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
          title: 'Forest at Dusk',
          context: { subject: 'landscape' },
          created_at: '2026-05-09T12:00:00.000Z',
          updated_at: '2026-05-11T12:00:00.000Z',
          critique_history: [{
            sequence_number: 1, created_at: '2026-05-11T12:00:00.000Z',
            content: '<!--summary-->\n- values flat\n- try three-zone plan\n<!--/summary-->',
            tags: { primary_category: 'value', focus_area_text: 'value grouping', severity: 3 },
          }],
        }]),
      };
    }
    if (u.includes('api.openai.com')) {
      const body = JSON.parse(init.body);
      userMsgSeen = body.messages[1].content;
      return {
        ok: true,
        json: async () => ({
          choices: [{ message: { content: JSON.stringify({ recommendations: fiveRecs }) } }],
          usage: { prompt_tokens: 800, completion_tokens: 300 },
        }),
        text: async () => '',
      };
    }
    return { ok: true, json: async () => ({}) };
  };
  try {
    const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
    const req = new Request('https://drawevolve-backend.test/v1/recommendations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${jwt}` },
      body: '',
    });
    const res = await handleRecommendations(req, env, { waitUntil: () => {} });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.recommendations.length, 5);
    assert.equal(body.context_summary.drawing_count, 1);
    assert.equal(body.context_summary.summary_count, 1);
    // User message must include the portfolio context.
    assert.ok(userMsgSeen.includes('Forest at Dusk'));
    assert.ok(userMsgSeen.includes('values flat'));
    assert.ok(userMsgSeen.includes('value grouping'));
    assert.ok(!userMsgSeen.includes('new user with no drawings'),
      'realistic portfolio must NOT trigger the empty-portfolio path');
  } finally { globalThis.fetch = originalFetch; }
});

// =============================================================================
// Feature 5, Phase 3 — Color System Overhaul: palette CRUD + validation
// =============================================================================

// ---- normalizeHexColor -----------------------------------------------------

test('normalizeHexColor accepts 6-digit hex with or without leading #', () => {
  assert.equal(normalizeHexColor('#ff8844'), '#ff8844');
  assert.equal(normalizeHexColor('ff8844'), '#ff8844');
  assert.equal(normalizeHexColor('#FF8844'), '#ff8844');
  assert.equal(normalizeHexColor('FF8844'), '#ff8844');
  assert.equal(normalizeHexColor('  #FF8844  '), '#ff8844');
  assert.equal(normalizeHexColor('aBcDeF'), '#abcdef');
});

test('normalizeHexColor rejects 3-digit, 8-digit, non-hex, non-string', () => {
  assert.equal(normalizeHexColor('#abc'), null, '3-digit hex not allowed');
  assert.equal(normalizeHexColor('#aabbccdd'), null, '8-digit hex (with alpha) not allowed');
  assert.equal(normalizeHexColor('#zzzzzz'), null, 'non-hex chars rejected');
  assert.equal(normalizeHexColor(''), null);
  assert.equal(normalizeHexColor(null), null);
  assert.equal(normalizeHexColor(undefined), null);
  assert.equal(normalizeHexColor(0xff8844), null, 'numbers rejected (must be string)');
  assert.equal(normalizeHexColor(['#ff8844']), null);
});

// ---- validatePaletteName ---------------------------------------------------

test('validatePaletteName accepts a trimmed non-empty string under 50 chars', () => {
  assert.deepEqual(validatePaletteName('My palette'), { ok: true, value: 'My palette' });
  assert.deepEqual(validatePaletteName('  My palette  '), { ok: true, value: 'My palette' });
});

test('validatePaletteName rejects empty, oversize, non-string', () => {
  assert.equal(validatePaletteName('').ok, false);
  assert.equal(validatePaletteName('   ').ok, false);
  assert.equal(validatePaletteName('a'.repeat(51)).ok, false);
  assert.equal(validatePaletteName(null).ok, false);
  assert.equal(validatePaletteName(42).ok, false);
});

// ---- validateColors --------------------------------------------------------

test('validateColors normalizes a well-formed array', () => {
  const r = validateColors(['#FF8844', 'aabbcc', '#11AA33']);
  assert.equal(r.ok, true);
  assert.deepEqual(r.value, ['#ff8844', '#aabbcc', '#11aa33']);
});

test('validateColors accepts an empty array (empty palette)', () => {
  assert.deepEqual(validateColors([]), { ok: true, value: [] });
});

test('validateColors rejects non-array', () => {
  assert.equal(validateColors('not an array').ok, false);
  assert.equal(validateColors({ '0': '#ff8844' }).ok, false);
  assert.equal(validateColors(null).ok, false);
});

test('validateColors rejects oversize array (> 100)', () => {
  const tooMany = Array(101).fill('#ff8844');
  const r = validateColors(tooMany);
  assert.equal(r.ok, false);
  assert.match(r.reason, /hard cap/);
});

test('validateColors rejects any bad entry, reporting the index', () => {
  const r = validateColors(['#ff8844', '#aabbcc', 'not-a-hex']);
  assert.equal(r.ok, false);
  assert.match(r.reason, /colors\[2\]/);
});

// ---- validatePalettePayload ------------------------------------------------

test('validatePalettePayload POST shape requires name + colors', () => {
  const ok = validatePalettePayload({ name: 'My palette', colors: ['#ff8844'] });
  assert.deepEqual(ok, { ok: true, value: { name: 'My palette', colors: ['#ff8844'] } });

  // Missing name
  assert.equal(validatePalettePayload({ colors: ['#ff8844'] }).ok, false);
  // Missing colors
  assert.equal(validatePalettePayload({ name: 'My palette' }).ok, false);
});

test('validatePalettePayload PATCH shape allows partial updates', () => {
  // Just name
  assert.deepEqual(
    validatePalettePayload({ name: 'Renamed' }, { requireAtLeastOne: true }),
    { ok: true, value: { name: 'Renamed' } },
  );
  // Just colors
  assert.deepEqual(
    validatePalettePayload({ colors: ['#ff8844'] }, { requireAtLeastOne: true }),
    { ok: true, value: { colors: ['#ff8844'] } },
  );
  // Both
  assert.deepEqual(
    validatePalettePayload({ name: 'Renamed', colors: ['#ff8844'] }, { requireAtLeastOne: true }),
    { ok: true, value: { name: 'Renamed', colors: ['#ff8844'] } },
  );
});

test('validatePalettePayload PATCH rejects empty body', () => {
  const r = validatePalettePayload({}, { requireAtLeastOne: true });
  assert.equal(r.ok, false);
  assert.match(r.reason, /PATCH must include/);
});

test('validatePalettePayload rejects non-object body', () => {
  assert.equal(validatePalettePayload(null).ok, false);
  assert.equal(validatePalettePayload('hello').ok, false);
  assert.equal(validatePalettePayload([]).ok, false);
});

// ---- handlePalettes integration ---------------------------------------------

const PALETTE_TEST_ID = '11111111-aaaa-bbbb-cccc-222222222222';

async function setupPalettesEnv() {
  _resetJwksCacheForTests();
  const { privateKey, publicKey } = await generateES256Keypair();
  const jwk = await exportPublicJWK(publicKey);
  const env = {
    ...TEST_JWT_ENV,
    SUPABASE_SERVICE_ROLE_KEY: 'fake',
    APP_ATTEST_REQUIRED: 'false',
    QUOTA_KV: new FakeKV(),
  };
  const jwt = await signES256JWT({ privateKey, payload: realNowBasePayload() });
  const ctx = { waitUntil: (p) => { Promise.resolve(p).catch(() => {}); } };
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    if (String(url).endsWith('/.well-known/jwks.json')) {
      return { ok: true, json: async () => ({ keys: [jwk] }) };
    }
    return { ok: true, json: async () => ({}) };
  };
  return {
    env, ctx, jwt, jwk,
    restore: () => { globalThis.fetch = originalFetch; },
  };
}

function paletteAuthHeaders(jwt) {
  return {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${jwt}`,
  };
}

test('handlePalettes 401 on missing JWT', async () => {
  _resetJwksCacheForTests();
  const env = {
    ...TEST_JWT_ENV,
    SUPABASE_SERVICE_ROLE_KEY: 'fake',
    APP_ATTEST_REQUIRED: 'false',
  };
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: true, json: async () => ({ keys: [] }) });
  try {
    const req = new Request('https://drawevolve-backend.test/v1/palettes', {
      method: 'GET',
    });
    const res = await handlePalettes(req, env, { waitUntil: () => {} });
    assert.equal(res.status, 401);
  } finally { globalThis.fetch = originalFetch; }
});

test('handlePalettes GET /v1/palettes lists user palettes', async () => {
  const { env, ctx, jwt, jwk, restore } = await setupPalettesEnv();
  try {
    const rows = [
      { id: 'a', user_id: TEST_SUB, name: 'My palette', colors: ['#ff8844'], created_at: 't1', updated_at: 't2', deleted_at: null },
      { id: 'b', user_id: TEST_SUB, name: 'Forest', colors: ['#1a1a1a', '#aabbcc'], created_at: 't0', updated_at: 't1', deleted_at: null },
    ];
    globalThis.fetch = async (url) => {
      const u = String(url);
      if (u.endsWith('/.well-known/jwks.json')) {
        return { ok: true, json: async () => ({ keys: [jwk] }) };
      }
      if (u.includes('/rest/v1/user_palettes')) {
        return { ok: true, json: async () => rows };
      }
      return { ok: true, json: async () => ({}) };
    };
    const req = new Request('https://drawevolve-backend.test/v1/palettes', {
      method: 'GET',
      headers: paletteAuthHeaders(jwt),
    });
    const res = await handlePalettes(req, env, ctx);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.deepEqual(body.palettes.map((p) => p.id), ['a', 'b']);
  } finally { restore(); }
});

test('handlePalettes POST /v1/palettes creates a palette', async () => {
  const { env, ctx, jwt, jwk, restore } = await setupPalettesEnv();
  try {
    const created = {
      id: PALETTE_TEST_ID,
      user_id: TEST_SUB,
      name: 'My palette',
      colors: ['#ff8844'],
      created_at: 't1',
      updated_at: 't1',
      deleted_at: null,
    };
    let postBody = null;
    globalThis.fetch = async (url, init) => {
      const u = String(url);
      if (u.endsWith('/.well-known/jwks.json')) {
        return { ok: true, json: async () => ({ keys: [jwk] }) };
      }
      if (u.includes('/rest/v1/user_palettes') && init?.method === 'POST') {
        postBody = JSON.parse(init.body);
        return { ok: true, json: async () => ([created]) };
      }
      return { ok: true, json: async () => ({}) };
    };
    const req = new Request('https://drawevolve-backend.test/v1/palettes', {
      method: 'POST',
      headers: paletteAuthHeaders(jwt),
      body: JSON.stringify({ name: 'My palette', colors: ['#FF8844'] }),
    });
    const res = await handlePalettes(req, env, ctx);
    assert.equal(res.status, 201);
    const body = await res.json();
    assert.equal(body.palette.id, PALETTE_TEST_ID);
    // Hex normalized to lowercase on the way in.
    assert.deepEqual(postBody.colors, ['#ff8844']);
    assert.equal(postBody.user_id, TEST_SUB);
  } finally { restore(); }
});

test('handlePalettes POST rejects 8-digit hex (alpha not allowed in palettes)', async () => {
  const { env, ctx, jwt, restore } = await setupPalettesEnv();
  try {
    const req = new Request('https://drawevolve-backend.test/v1/palettes', {
      method: 'POST',
      headers: paletteAuthHeaders(jwt),
      body: JSON.stringify({ name: 'X', colors: ['#ff884480'] }),
    });
    const res = await handlePalettes(req, env, ctx);
    assert.equal(res.status, 400);
  } finally { restore(); }
});

test('handlePalettes PATCH /v1/palettes/:id rejects empty body', async () => {
  const { env, ctx, jwt, restore } = await setupPalettesEnv();
  try {
    const req = new Request(`https://drawevolve-backend.test/v1/palettes/${PALETTE_TEST_ID}`, {
      method: 'PATCH',
      headers: paletteAuthHeaders(jwt),
      body: JSON.stringify({}),
    });
    const res = await handlePalettes(req, env, ctx);
    assert.equal(res.status, 400);
  } finally { restore(); }
});

test('handlePalettes PATCH /v1/palettes/:id allows partial updates', async () => {
  const { env, ctx, jwt, jwk, restore } = await setupPalettesEnv();
  try {
    let patchBody = null;
    globalThis.fetch = async (url, init) => {
      const u = String(url);
      if (u.endsWith('/.well-known/jwks.json')) {
        return { ok: true, json: async () => ({ keys: [jwk] }) };
      }
      if (u.includes('/rest/v1/user_palettes') && init?.method === 'PATCH') {
        patchBody = JSON.parse(init.body);
        return { ok: true, json: async () => ([{ id: PALETTE_TEST_ID, name: 'Renamed' }]) };
      }
      return { ok: true, json: async () => ({}) };
    };
    const req = new Request(`https://drawevolve-backend.test/v1/palettes/${PALETTE_TEST_ID}`, {
      method: 'PATCH',
      headers: paletteAuthHeaders(jwt),
      body: JSON.stringify({ name: 'Renamed' }),
    });
    const res = await handlePalettes(req, env, ctx);
    assert.equal(res.status, 200);
    assert.deepEqual(patchBody, { name: 'Renamed' });
  } finally { restore(); }
});

test('handlePalettes PATCH returns 404 when no row affected', async () => {
  const { env, ctx, jwt, jwk, restore } = await setupPalettesEnv();
  try {
    globalThis.fetch = async (url) => {
      const u = String(url);
      if (u.endsWith('/.well-known/jwks.json')) {
        return { ok: true, json: async () => ({ keys: [jwk] }) };
      }
      if (u.includes('/rest/v1/user_palettes')) {
        return { ok: true, json: async () => ([]) }; // no rows affected
      }
      return { ok: true, json: async () => ({}) };
    };
    const req = new Request(`https://drawevolve-backend.test/v1/palettes/${PALETTE_TEST_ID}`, {
      method: 'PATCH',
      headers: paletteAuthHeaders(jwt),
      body: JSON.stringify({ name: 'Renamed' }),
    });
    const res = await handlePalettes(req, env, ctx);
    assert.equal(res.status, 404);
  } finally { restore(); }
});

test('handlePalettes DELETE /v1/palettes/:id soft-deletes (idempotent)', async () => {
  const { env, ctx, jwt, jwk, restore } = await setupPalettesEnv();
  try {
    let patchBody = null;
    globalThis.fetch = async (url, init) => {
      const u = String(url);
      if (u.endsWith('/.well-known/jwks.json')) {
        return { ok: true, json: async () => ({ keys: [jwk] }) };
      }
      if (u.includes('/rest/v1/user_palettes') && init?.method === 'PATCH') {
        patchBody = JSON.parse(init.body);
        return { ok: true, json: async () => ([{ id: PALETTE_TEST_ID, deleted_at: 'stamped' }]) };
      }
      return { ok: true, json: async () => ({}) };
    };
    const req = new Request(`https://drawevolve-backend.test/v1/palettes/${PALETTE_TEST_ID}`, {
      method: 'DELETE',
      headers: paletteAuthHeaders(jwt),
    });
    const res = await handlePalettes(req, env, ctx);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.ok, true);
    assert.ok(patchBody.deleted_at, 'soft-delete must stamp deleted_at');
    assert.ok(!Number.isNaN(Date.parse(patchBody.deleted_at)));
  } finally { restore(); }
});

test('handlePalettes returns 405 on wrong method, 404 on unmatched path', async () => {
  const { env, ctx, jwt, restore } = await setupPalettesEnv();
  try {
    // Wrong method on collection
    const wrongMethod = new Request('https://drawevolve-backend.test/v1/palettes', {
      method: 'PUT',
      headers: paletteAuthHeaders(jwt),
    });
    const r1 = await handlePalettes(wrongMethod, env, ctx);
    assert.equal(r1.status, 405);

    // Bogus subpath
    const noMatch = new Request('https://drawevolve-backend.test/v1/palettes/abc/extra', {
      method: 'GET',
      headers: paletteAuthHeaders(jwt),
    });
    const r2 = await handlePalettes(noMatch, env, ctx);
    assert.equal(r2.status, 404);
  } finally { restore(); }
});

test('handlePalettes GET /v1/palettes/:id rejects invalid UUID', async () => {
  const { env, ctx, jwt, restore } = await setupPalettesEnv();
  try {
    const req = new Request('https://drawevolve-backend.test/v1/palettes/not-a-uuid', {
      method: 'GET',
      headers: paletteAuthHeaders(jwt),
    });
    const res = await handlePalettes(req, env, ctx);
    assert.equal(res.status, 400);
  } finally { restore(); }
});
