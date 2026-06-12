// /v1/recommendations — Phase 4 subject-recommendation endpoint.
//
// Returns 5 personalized recommendations of what the artist should draw
// next, based on their drawing history + critique focus areas. Triggered
// by an explicit user action (tap "See suggestions" on the new-canvas
// setup screen, or tap a card in Evolution's "Recommended next" section
// — both call POST /v1/recommendations).
//
// Why no caching in v1: recommendations are cheap (one OpenAI call per
// request, ~$0.003 typical), the user can tap "See suggestions" twice
// to roll for a different mix, and a stale cached set across days would
// feel wrong ("why is Eve still recommending this — I drew it last
// week"). If usage data shows users tap repeatedly within a session,
// add a 60s per-user KV cache then.
//
// Posture: same JWT + App-Attest gate as the Eve routes. Shares the
// global PER_USER_DAILY_TOKEN_CAP with critiques + Eve via
// enforceCostCeilings — recommendations don't have their own per-minute
// bucket because they're driven by explicit user action (not chat-
// style tempo) and the global token cap is the real ceiling.

import {
  validateJWT,
  validateWorkerConfig,
  getUserTier,
} from '../middleware/auth.js';
import {
  isAppAttestRequired,
  readAppAttestHeaders,
  getAttestedKey,
  computeAppAttestClientDataHash,
  verifyAppAttestAssertion,
  updateAttestedKeyCounter,
} from '../middleware/app-attest.js';
import {
  enforceCostCeilings,
  recordRequestUsage,
} from '../middleware/rate-limit.js';
import { fetchCoachingContext } from '../lib/supabase.js';
import {
  RECOMMENDATIONS_SYSTEM_PROMPT,
  buildRecommendationsUserMessage,
} from '../lib/recommendations-prompt.js';
import {
  RECOMMENDATIONS_SCHEMA,
  validateRecommendations,
} from '../lib/recommendations-validation.js';
import { jsonResponse, unauthorized } from '../lib/http.js';

// =============================================================================
// Tunables
// =============================================================================
//
// Same model as critiques + Eve. Recommendations are short structured
// output, so max_completion_tokens is well below the critique ceiling.
// reasoning_effort='none' is fine — the schema enforces the shape and
// the prompt does the work. If recommendations start feeling generic
// across A/B tests, bump to 'low' for recommendations only without
// touching the other paths.

const OPENAI_MODEL = 'gpt-5.1';
const OPENAI_TEMPERATURE = 0.7;
const OPENAI_REASONING_EFFORT = 'none';
const OPENAI_MAX_OUTPUT_TOKENS = 800;

// =============================================================================
// Kill switch
// =============================================================================
//
// RECOMMENDATIONS_ENABLED env var — flip to "false" in the Cloudflare
// dashboard to disable the endpoint without redeploying. Same
// fail-closed shape as isCrossDrawingContextEnabled: only the literal
// string "true" enables. Missing / empty / any other value → off.

export function isRecommendationsEnabled(env) {
  return env?.RECOMMENDATIONS_ENABLED === 'true';
}

// =============================================================================
// Handler
// =============================================================================

export async function handleRecommendations(request, env, ctx) {
  if (request.method !== 'POST') {
    return jsonResponse({ error: 'Method not allowed' }, 405);
  }

  if (!isRecommendationsEnabled(env)) {
    return jsonResponse({
      error: 'recommendations_disabled',
      message: 'Subject recommendations are temporarily unavailable.',
    }, 503);
  }

  const configErr = validateWorkerConfig(env);
  if (configErr) {
    console.error('[recommendations]', configErr);
    return jsonResponse({ error: configErr }, 500);
  }

  // Read raw bytes for App Attest (signs over exact body bytes — empty
  // body is fine here since recommendations is a GET-shaped POST with
  // no body content; the empty-bytes hash is still a valid assertion).
  const rawBody = new Uint8Array(await request.arrayBuffer());

  // JWT gate.
  const token = request.headers.get('Authorization')?.replace(/^Bearer\s+/i, '') ?? null;
  let payload;
  try {
    payload = await validateJWT(token, env);
  } catch (err) {
    console.log('[recommendations] JWT validation failed', err?.message);
    return unauthorized();
  }
  const userId = payload.sub;

  // App Attest gate (skipped when kill-switch off, same shape as Eve).
  if (isAppAttestRequired(env)) {
    const attestHeaders = readAppAttestHeaders(request);
    if (!attestHeaders) {
      return jsonResponse({ error: 'attest_headers_missing' }, 401);
    }
    const stored = await getAttestedKey(attestHeaders.keyId, env);
    if (!stored) {
      return jsonResponse({ error: 'attest_key_unknown' }, 401);
    }
    const expectedEnv = env.APP_ATTEST_ENV === 'production' ? 'production' : 'development';
    if (stored.env !== expectedEnv) {
      return jsonResponse({ error: 'attest_env_mismatch' }, 401);
    }
    const expectedClientDataHash = await computeAppAttestClientDataHash(
      request.method,
      new URL(request.url).pathname || '/',
      rawBody,
    );
    try {
      const { newCounter } = await verifyAppAttestAssertion({
        assertionB64: attestHeaders.assertion,
        storedPubKey: stored.pub,
        storedCounter: stored.counter,
        expectedClientDataHash,
        env,
      });
      ctx.waitUntil(updateAttestedKeyCounter(attestHeaders.keyId, newCounter, env));
    } catch (err) {
      console.log('[recommendations] assertion failed', err?.message);
      return jsonResponse({ error: 'attest_assertion_invalid' }, 401);
    }
  } else {
    console.log('[recommendations] attest enforcement disabled — request on JWT alone');
  }

  // Global cost ceilings — shared daily $/cap + per-user daily token
  // cap. Recommendations don't have their own per-minute bucket because
  // they're explicit user actions, not chat tempo.
  const now = Date.now();
  const ceilingDecision = await enforceCostCeilings({
    env, userId, now, tier: getUserTier(payload).tier,
  });
  if (!ceilingDecision.ok) {
    return jsonResponse(ceilingDecision.body, ceilingDecision.status, {
      'Retry-After': String(ceilingDecision.body.retryAfter),
    });
  }
  const todayKey = ceilingDecision.ctx.dayKey;

  // Fetch coaching context. Reuses the same data layer Eve uses. We
  // pass excludeDrawingId/excludeCritiqueSequence as null because
  // recommendations aren't scoped to a specific drawing — they're
  // portfolio-wide.
  let coachingContext;
  try {
    coachingContext = await fetchCoachingContext({
      env,
      userId,
      drawingsLimit: 20,
      summariesLimit: 10,
      excludeDrawingId: null,
      excludeCritiqueSequence: null,
      now,
    });
  } catch (err) {
    console.error('[recommendations] coaching context fetch threw', err?.message);
    // Empty coaching context → fundamentals-lean path. Don't 500.
    coachingContext = { drawings: [], summaries: [] };
  }

  const drawingCount = coachingContext?.drawings?.length ?? 0;
  const summaryCount = coachingContext?.summaries?.length ?? 0;
  console.log('[recommendations] coaching context loaded', {
    userId,
    drawingCount,
    summaryCount,
  });

  // Assemble messages.
  const userMessage = buildRecommendationsUserMessage(coachingContext);

  // OpenAI call with structured outputs.
  let openaiResponse;
  try {
    openaiResponse = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      },
      body: JSON.stringify({
        model: OPENAI_MODEL,
        messages: [
          { role: 'system', content: RECOMMENDATIONS_SYSTEM_PROMPT },
          { role: 'user', content: userMessage },
        ],
        max_completion_tokens: OPENAI_MAX_OUTPUT_TOKENS,
        temperature: OPENAI_TEMPERATURE,
        reasoning_effort: OPENAI_REASONING_EFFORT,
        response_format: {
          type: 'json_schema',
          json_schema: RECOMMENDATIONS_SCHEMA,
        },
        user: userId,
      }),
    });
  } catch (err) {
    console.error('[recommendations] openai fetch threw', err?.message);
    return jsonResponse({ error: 'Upstream model error' }, 502);
  }

  if (!openaiResponse.ok) {
    let errorBody = '<unavailable>';
    try { errorBody = await openaiResponse.text(); } catch {}
    console.error('[recommendations] openai non-ok', openaiResponse.status, 'body:', errorBody);
    return jsonResponse({ error: 'Upstream model error' }, 502);
  }

  const data = await openaiResponse.json();
  const rawContent = data?.choices?.[0]?.message?.content;
  if (typeof rawContent !== 'string' || rawContent.length === 0) {
    console.error('[recommendations] empty response from openai');
    return jsonResponse({ error: 'No recommendations generated' }, 502);
  }

  // Parse the structured JSON.
  let parsed;
  try {
    parsed = JSON.parse(rawContent);
  } catch (err) {
    console.error('[recommendations] JSON parse failed', err?.message, 'raw:', rawContent.slice(0, 500));
    return jsonResponse({ error: 'Malformed model output' }, 502);
  }

  // Server-side validation (defense-in-depth even with strict schema mode).
  const validation = validateRecommendations(parsed);
  if (!validation.ok) {
    console.error('[recommendations] validation failed', validation.reason);
    return jsonResponse({ error: 'Malformed model output' }, 502);
  }

  // Post-flight: bump per-user daily token counter by actual usage.
  // Fire-and-forget — failure doesn't block the user response.
  if (data.usage) {
    recordRequestUsage({ env, userId, dayKey: todayKey, usage: data.usage })
      .catch((err) => console.error('[recommendations] recordRequestUsage failed', err?.message));
  }

  return jsonResponse({
    recommendations: validation.value,
    // Telemetry for the iOS client — useful for "we saw 3 drawings
    // but no critiques yet" empty-state messaging if we ever want it.
    context_summary: {
      drawing_count: drawingCount,
      summary_count: summaryCount,
    },
  });
}
