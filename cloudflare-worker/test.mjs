import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_FREE_CONFIG,
  DEFAULT_PRO_CONFIG,
  HISTORY_FRAMING_DEFAULT,
  selectConfig,
  buildSystemPrompt,
  buildUserMessage,
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
