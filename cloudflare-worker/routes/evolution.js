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
  DEFAULT_WINDOW_CRITIQUES,
  MAX_WINDOW_CRITIQUES,
  DEFAULT_WINDOW_DAYS,
  MAX_WINDOW_DAYS,
} from '../lib/evolution-aggregation.js';

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

  return jsonResponse(buildEvolutionResponse(drawings, {
    windowCritiques,
    windowDays,
    now: Date.now(),
  }));
}
