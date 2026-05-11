// GET /v1/me/evolution — v2 surface for the rebuilt My Evolution panel.
//
// Returns four sections:
//   - summary: monthly counts + top subjects + insights_last_updated_at
//   - digest_sentence + themes + highlight: LLM-synthesized (Phase 2 / 3).
//     Phase 1 returns them as null / [] / null respectively.
//   - reel: up to 10 recent critiques joined with their drawing for
//     thumbnail + title + subject, with a deterministic excerpt.
//   - stats: lifetime aggregates (total critiques, most-discussed
//     category, most-improved category, current focus area).
//
// The v1 chart-based shape (`window`, `categories`, `warming_up`,
// `summary_text`, `state`, `example_artist_label`) has been removed. iOS
// updates ship paired with this deploy; no flag, no transitional shape
// per the v2 overhaul proposal §4.
//
// Auth: same composition as the rest of /v1/* (JWT + App Attest via
// requireAuth). App Attest IS required even though this is a read-only,
// non-AI endpoint — matches the established pattern, and the response
// exposes user activity data that should only be reachable from verified
// devices.

import { validateWorkerConfig } from '../middleware/auth.js';
import { jsonResponse } from '../lib/http.js';
import { requireAuth } from './profiles.js';
import { CLASSIFIER_VERSION } from '../lib/classifier.js';
import {
  flattenCritiques,
  flattenCritiquesForReel,
  selectWindow,
  computeStreak,
  buildSummary,
  buildReel,
  buildThemes,
  buildStats,
  buildTaggedCritiques,
  DEFAULT_WINDOW_CRITIQUES,
  MAX_WINDOW_CRITIQUES,
  DEFAULT_WINDOW_DAYS,
  MAX_WINDOW_DAYS,
} from '../lib/evolution-aggregation.js';

// Drawings to fetch per request. Same 50-drawing ceiling as v1 — the
// streak counters and reel join happily off the same fetch.
const DRAWING_FETCH_LIMIT = 50;

// Reel page size. iOS renders 10 + a Load-more affordance for older
// critiques (proposal §4.5). The server returns the most-recent N
// regardless of windowing — the reel is "what have you done recently",
// not "what's in the analysis window."
const REEL_PAGE_SIZE = 10;

function supabaseHeaders(env) {
  return {
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    Accept: 'application/json',
  };
}

/**
 * Fetch the calling user's drawings. v2 pulls richer columns than v1
 * because the reel needs title/storage_path/context to render rows:
 *   - id, created_at, updated_at — streak math + ordering
 *   - critique_history — flatten + aggregation source
 *   - title, storage_path — reel display
 *   - context — top_subjects + reel drawing_subject
 */
export async function fetchUserDrawings({ env, userId, fetcher = fetch }) {
  const url = `${env.SUPABASE_URL}/rest/v1/drawings`
    + `?user_id=eq.${encodeURIComponent(userId)}`
    + `&select=id,created_at,updated_at,critique_history,title,storage_path,context`
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
 * Build the v2 response. Pure body-builder, exported so tests can drive
 * the response shape directly without mocking Supabase fetch.
 *
 * `windowCritiques` / `windowDays` are accepted but only affect Themes
 * (themes look across the analysis window). The reel always shows the
 * most recent REEL_PAGE_SIZE critiques regardless of window, and the
 * stats are lifetime-scoped within the fetched 50-drawing limit.
 */
export function buildEvolutionResponseV2(drawings, { windowCritiques, windowDays, now }) {
  const safeDrawings = Array.isArray(drawings) ? drawings : [];

  // drawingsById map for the reel join — built once, used inside buildReel.
  const drawingsById = new Map();
  for (const d of safeDrawings) {
    if (d?.id) drawingsById.set(d.id, d);
  }

  // Two flatteners:
  //   - `flattenCritiques` requires classifier tags (drops pre-Phase-1
  //     and classifier-failed entries). Themes + stats depend on the
  //     structured tags so they use this strict view.
  //   - `flattenCritiquesForReel` includes every critique with non-empty
  //     content. The reel is "show me my recent work" and shouldn't
  //     disappear just because the classifier didn't run.
  const taggedCritiques = flattenCritiques(safeDrawings);
  const allReelCritiques = flattenCritiquesForReel(safeDrawings);
  const windowCritiquesEntries = selectWindow(taggedCritiques, { windowCritiques, windowDays, now });
  const streak = computeStreak(safeDrawings, { now });

  return {
    summary: buildSummary(safeDrawings, streak, { now }),
    digest_sentence: null,                  // Phase 2 — LLM synthesis
    themes: buildThemes(windowCritiquesEntries),
    highlight: null,                        // Phase 3 — same-subject pair
    reel: buildReel(allReelCritiques, drawingsById, { limit: REEL_PAGE_SIZE }),
    stats: buildStats(taggedCritiques),
    // v3 (Studio Wall + Skill Radar): every classified critique with
    // its drawing's metadata + full severity tag set. Oldest-first;
    // iOS renders newest on the right of the wall.
    tagged_critiques: buildTaggedCritiques(taggedCritiques, drawingsById),
    streak,                                  // retained for callers that want raw counts
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

  return jsonResponse(buildEvolutionResponseV2(drawings, {
    windowCritiques,
    windowDays,
    now: Date.now(),
  }));
}
