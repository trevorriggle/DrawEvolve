// GET /v1/me/evolution — read-only summary of the calling user's tagged
// critique history for the future "My Evolution" UI. Returns per-category
// trend series, status, streak counters, and a "warming_up" list for
// categories with insufficient data.
//
// Auth: same composition as the rest of /v1/* (JWT + App Attest via
// requireAuth). App Attest IS required even though this is a read-only,
// non-AI endpoint — matches the established pattern, and the response
// exposes user activity data that should only be reachable from verified
// devices. Same protection that gates critique generation gates this.
//
// Aggregation runs in JavaScript (not SQL): per-user data volumes are
// small (capped at 50 drawings, MAX_AGGREGATION_ENTRIES critiques into the
// analysis), and the trend / status logic is easier to test and reason
// about as pure functions. All math lives in lib/evolution-aggregation.js.

import { validateWorkerConfig } from '../middleware/auth.js';
import { jsonResponse } from '../lib/http.js';
import { requireAuth } from './profiles.js';
import { CLASSIFIER_VERSION } from '../lib/classifier.js';
import {
  flattenCritiques,
  selectWindow,
  aggregateCategories,
  computeStreak,
  deriveState,
  composeSummaryText,
  EXAMPLE_PAYLOAD,
  MIN_DATA_POINTS_GROWING,
  MIN_DATA_POINTS_MATURE,
  DEFAULT_WINDOW_CRITIQUES,
  MAX_WINDOW_CRITIQUES,
  DEFAULT_WINDOW_DAYS,
  MAX_WINDOW_DAYS,
} from '../lib/evolution-aggregation.js';

const MS_PER_DAY = 24 * 60 * 60 * 1000;

// Drawings to fetch per request. 50 * average critiques/drawing should
// comfortably exceed MAX_AGGREGATION_ENTRIES (200) for any realistic user.
// See computeStreak's note about totals undercounting beyond this cap.
const DRAWING_FETCH_LIMIT = 50;

function supabaseHeaders(env) {
  return {
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    Accept: 'application/json',
  };
}

/**
 * Fetch the calling user's drawings. Returns an array of rows with the
 * fields needed for both the streak counters (updated_at) and the
 * aggregation (critique_history).
 */
export async function fetchUserDrawings({ env, userId, fetcher = fetch }) {
  const url = `${env.SUPABASE_URL}/rest/v1/drawings`
    + `?user_id=eq.${encodeURIComponent(userId)}`
    + `&select=id,created_at,updated_at,critique_history`
    + `&order=updated_at.desc`
    + `&limit=${DRAWING_FETCH_LIMIT}`;
  const res = await fetcher(url, { headers: supabaseHeaders(env) });
  if (!res.ok) throw new Error(`fetchUserDrawings HTTP ${res.status}`);
  const rows = await res.json();
  return Array.isArray(rows) ? rows : [];
}

function parseIntegerParam(raw, fallback, max) {
  if (raw === null || raw === undefined) return fallback;
  const n = parseInt(raw, 10);
  if (!Number.isFinite(n) || n < 1) return fallback;
  return Math.min(n, max);
}

/**
 * Pure body-builder: given the drawings list and window params, produce
 * the response object. Exported so tests can drive the full response
 * shape (per Phase 2 spec: "test the route handler at the level of
 * 'given this set of drawings, produce this response.'") without mocking
 * the Supabase fetch.
 *
 * NOTE: This function is intentionally kept stateless per Phase 2 — no
 * `state` field, no example substitution, no summary text. Phase 2.5
 * layers those in via `buildEvolutionResponseWithState` below; the
 * existing 16 evolution tests still drive this function directly and
 * lock its shape.
 */
export function buildEvolutionResponse(drawings, { windowCritiques, windowDays, now }) {
  const allEntries = flattenCritiques(drawings);
  const windowEntries = selectWindow(allEntries, { windowCritiques, windowDays, now });
  const { categories, warmingUp, window } = aggregateCategories(windowEntries);
  const streak = computeStreak(drawings, { now });
  return {
    window,
    streak,
    categories,
    warming_up: warmingUp,
    classifier_version: CLASSIFIER_VERSION,
  };
}

/**
 * Phase 2.5 orchestrator. Layers state derivation, threshold reselection,
 * summary text composition, and example substitution on top of the pure
 * Phase 2 builder. The route handler calls this; tests for the new
 * Phase 2.5 behavior also drive this directly.
 *
 * Order of operations (load-bearing):
 *
 *   1. Compute streak first — `state` derives from `streak.critiques_total`.
 *   2. Select threshold from state (mature → 5, growing → 2). Early/example
 *      states don't render a chart from real data, so the threshold doesn't
 *      affect their categories arrays in the response.
 *   3. Aggregate with the chosen threshold.
 *   4. Compose summary text from the (pre-substitution) aggregation result —
 *      so even when "early" state empties categories/warming_up in the
 *      response, the summary still reflects what the user actually drew.
 *   5. For "early" state: empty out categories and warming_up in the body
 *      (the chart isn't rendered; the summary carries the message).
 *   6. For "example" state: substitute EXAMPLE_PAYLOAD's categories and
 *      warming_up, override window to describe the example, attach
 *      example_artist_label. Streak stays as the user's real (zero) values
 *      — we don't fake activity counters.
 *   7. Assemble final body. `summary_text` and `example_artist_label`
 *      keys are omitted (not set to null) when not applicable.
 */
export function buildEvolutionResponseWithState(drawings, { windowCritiques, windowDays, now }) {
  const allEntries = flattenCritiques(drawings);
  const windowEntries = selectWindow(allEntries, { windowCritiques, windowDays, now });
  const streak = computeStreak(drawings, { now });
  const state = deriveState(streak.critiques_total);

  const threshold = state === 'growing' ? MIN_DATA_POINTS_GROWING : MIN_DATA_POINTS_MATURE;
  const { categories, warmingUp, window } = aggregateCategories(windowEntries, { threshold });

  // Compose BEFORE any state-driven substitution: the early-state body
  // empties these arrays, but the summary is computed from the real data.
  const summaryText = composeSummaryText(state, categories, warmingUp, streak);

  let bodyCategories = categories;
  let bodyWarmingUp = warmingUp;
  let bodyWindow = window;
  let exampleLabel = null;

  if (state === 'early') {
    // No chart in this state. The summary text carries the message.
    bodyCategories = [];
    bodyWarmingUp = [];
  } else if (state === 'example') {
    bodyCategories = EXAMPLE_PAYLOAD.categories;
    bodyWarmingUp = EXAMPLE_PAYLOAD.warming_up;
    exampleLabel = EXAMPLE_PAYLOAD.example_artist_label;
    // Override window so the iOS UI can label endpoints with sensible
    // dates instead of nulls. critique_count = sum of data_points across
    // example categories per the Phase 2.5 spec.
    const exampleCritiqueCount = EXAMPLE_PAYLOAD.categories
      .reduce((acc, c) => acc + c.data_points, 0);
    const latestTs = now;
    const earliestTs = now - 30 * MS_PER_DAY;
    bodyWindow = {
      critique_count: exampleCritiqueCount,
      earliest_at: new Date(earliestTs).toISOString(),
      latest_at: new Date(latestTs).toISOString(),
      span_days: 30,
    };
  }

  const body = {
    window: bodyWindow,
    streak,
    categories: bodyCategories,
    warming_up: bodyWarmingUp,
    state,
    classifier_version: CLASSIFIER_VERSION,
  };
  if (summaryText !== null) body.summary_text = summaryText;
  if (exampleLabel !== null) body.example_artist_label = exampleLabel;
  return body;
}

export async function handleEvolution(request, env, ctx, fetcher = fetch) {
  const configErr = validateWorkerConfig(env);
  if (configErr) return jsonResponse({ error: configErr }, 500);

  const auth = await requireAuth(request, env, ctx);
  if (!auth.ok) return auth.response;
  const { userId } = auth;

  const url = new URL(request.url);
  const windowCritiques = parseIntegerParam(
    url.searchParams.get('window_critiques'),
    DEFAULT_WINDOW_CRITIQUES,
    MAX_WINDOW_CRITIQUES,
  );
  const windowDays = parseIntegerParam(
    url.searchParams.get('window_days'),
    DEFAULT_WINDOW_DAYS,
    MAX_WINDOW_DAYS,
  );

  let drawings;
  try {
    drawings = await fetchUserDrawings({ env, userId, fetcher });
  } catch (err) {
    console.error('[evolution] fetch drawings failed', err?.message);
    return jsonResponse({ error: 'evolution_unavailable' }, 502);
  }

  return jsonResponse(buildEvolutionResponseWithState(drawings, {
    windowCritiques,
    windowDays,
    now: Date.now(),
  }));
}
