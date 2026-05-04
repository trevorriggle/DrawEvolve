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
// /v1/* are the social/profile endpoints (Phase A — profiles foundation).
//
// The named re-exports at the bottom of this file preserve the historical
// import surface for test.mjs (and any future tooling that imports from
// `./index.js`). Adding a new export means: define it in its module, then
// add it here.

import { handleFeedback } from './routes/feedback.js';
import { handleAttestChallenge } from './routes/attest/challenge.js';
import { handleAttestRegister } from './routes/attest/register.js';
import {
  handleGetMe,
  handlePatchMe,
  handleAvatarUpload,
  handleGetProfileByUsername,
  handleProfileSearch,
} from './routes/profiles.js';
import { handlePrompts } from './routes/prompts.js';
import { CORS_HEADERS, jsonResponse } from './lib/http.js';

// Methods allowed on the legacy POST-only routes (/, /attest/*). The new
// /v1/prompts/* routes accept GET / POST / PATCH / DELETE — those route
// matches happen before this gate.
const POST_ONLY_PATHS = new Set(['/', '/attest/challenge', '/attest/register']);

export default {
  async fetch(request, env, ctx) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: CORS_HEADERS });
    }
    const pathname = new URL(request.url).pathname;
    const method = request.method;

    // Profile routes (Phase A). `/v1/profiles/search` is matched before the
    // dynamic `/v1/profiles/:username` so the literal "search" path doesn't
    // resolve as a username lookup.
    if (method === 'GET' && pathname === '/v1/me') {
      return handleGetMe(request, env, ctx);
    }
    if (method === 'PATCH' && pathname === '/v1/profiles/me') {
      return handlePatchMe(request, env, ctx);
    }
    if (method === 'POST' && pathname === '/v1/profiles/me/avatar') {
      return handleAvatarUpload(request, env, ctx);
    }
    if (method === 'GET' && pathname === '/v1/profiles/search') {
      return handleProfileSearch(request, env, ctx);
    }
    if (method === 'GET' && pathname.startsWith('/v1/profiles/')) {
      const tail = pathname.slice('/v1/profiles/'.length);
      // Reject extra path segments (e.g. /v1/profiles/foo/bar) — only the
      // bare username form is supported here. Followers / following list
      // routes will be added in a later phase.
      if (tail.length === 0 || tail.includes('/')) {
        return jsonResponse({ error: 'Not found' }, 404);
      }
      return handleGetProfileByUsername(request, env, ctx, decodeURIComponent(tail));
    }

    if (method !== 'POST') {

    // /v1/prompts/* dispatches all methods to handlePrompts; that route
    // owns its own method gating and 405s.
    if (pathname === '/v1/prompts'
        || pathname === '/v1/prompts/me'
        || /^\/v1\/prompts\/[^/]+$/.test(pathname)) {
      return handlePrompts(request, env, ctx);
    }

    if (POST_ONLY_PATHS.has(pathname) && request.method !== 'POST') {
      return jsonResponse({ error: 'Method not allowed' }, 405);
    }
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
  PROMPT_TEMPLATE_VERSION,
  FOCUS_OPTIONS,
  TONE_OPTIONS,
  DEPTH_OPTIONS,
  TECHNIQUE_OPTIONS,
  validatePromptParameters,
  renderCustomPromptModifier,
  selectCustomPromptParameters,
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

export {
  requireAuth,
  fetchProfileByUserId,
  fetchProfileByUsername,
  patchProfile,
  enforceSearchRateLimit,
  handleGetMe,
  handlePatchMe,
  handleAvatarUpload,
  handleGetProfileByUsername,
  handleProfileSearch,
} from './routes/profiles.js';
