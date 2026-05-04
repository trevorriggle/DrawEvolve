// DrawEvolve Worker — top-level router.
//
// Per-route logic lives under routes/. Shared primitives live under
// middleware/ (auth, rate-limit, idempotency, app-attest) and lib/ (prompt
// assembly, HTTP scaffolding, Supabase REST helper).
//
// The legacy single endpoint (POST /) is the AI critique flow handled by
// routes/feedback.js. /attest/challenge and /attest/register are unauth'd
// device registration endpoints — they intentionally run BEFORE the JWT
// gate so first-launch registration works without a session token.
//
// The named re-exports at the bottom of this file preserve the historical
// import surface for test.mjs (and any future tooling that imports from
// `./index.js`). Adding a new export means: define it in its module, then
// add it here.

import { handleFeedback } from './routes/feedback.js';
import { handleAttestChallenge } from './routes/attest/challenge.js';
import { handleAttestRegister } from './routes/attest/register.js';
import { CORS_HEADERS, jsonResponse } from './lib/http.js';

export default {
  async fetch(request, env, ctx) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: CORS_HEADERS });
    }
    if (request.method !== 'POST') {
      return jsonResponse({ error: 'Method not allowed' }, 405);
    }
    const pathname = new URL(request.url).pathname;
    if (pathname === '/') return handleFeedback(request, env, ctx);
    if (pathname === '/attest/challenge') return handleAttestChallenge(request, env, ctx);
    if (pathname === '/attest/register') return handleAttestRegister(request, env, ctx);
    return jsonResponse({ error: 'Not found' }, 404);
  },
};

// =============================================================================
// Test surface — preserves the historical 49-symbol export shape.
// =============================================================================

export {
  BASE_SYSTEM_PROMPT,
  VOICE_STUDIO_MENTOR,
  VOICE_THE_CRIT,
  VOICE_FUNDAMENTALS_COACH,
  VOICE_RENAISSANCE_MASTER,
  PRESET_VOICES,
  selectVoice,
  assembleSystemPrompt,
  SHARED_SYSTEM_RULES,
  HISTORY_FRAMING_DEFAULT,
  DEFAULT_FREE_CONFIG,
  DEFAULT_PRO_CONFIG,
  selectConfig,
  buildSystemPrompt,
  buildUserMessage,
  formatHistoryEntries,
  renderTruncationMarker,
  renderSkillCalibration,
  renderContextBlock,
  isValidPresetId,
  resolvePresetId,
  VALID_PRESET_IDS,
  DEFAULT_PRESET_ID,
  CUSTOM_PROMPT_PREFIX,
} from './lib/prompt.js';

export {
  validateJWT,
  validateWorkerConfig,
  getUserTier,
  _resetJwksCacheForTests,
} from './middleware/auth.js';

export {
  bytesEqual,
  bytesToHex,
  hexToBytes,
  cborDecode,
  ecdsaDerToRaw,
  computeAppAttestClientDataHash,
  verifyAppAttestAttestation,
  verifyAppAttestAssertion,
  issueAppAttestChallenge,
  consumeAppAttestChallenge,
  storeAttestedKey,
  getAttestedKey,
  updateAttestedKeyCounter,
  readAppAttestHeaders,
} from './middleware/app-attest.js';

export {
  TIER_LIMITS,
  IP_HOURLY_CAP,
  ANOMALY_MULTIPLIER,
  utcDayKey,
  utcHourKey,
  secondsUntilNextUtcMidnight,
  sha256Hex,
  enforceRateLimits,
  recordSuccessfulCritique,
  DAILY_SPEND_CAP_USD,
  computeRequestCost,
  getDailySpend,
  incrementDailySpend,
} from './middleware/rate-limit.js';

export {
  isValidClientRequestId,
  checkIdempotency,
  recordIdempotent,
} from './middleware/idempotency.js';

export {
  validateImagePayload,
  validateContext,
  validateContextLengths,
  updateDrawingPresetId,
  updateUserPreferredPreset,
  buildCritiqueEntry,
  persistCritique,
  REQUEST_STATUS,
  logRequest,
} from './routes/feedback.js';
