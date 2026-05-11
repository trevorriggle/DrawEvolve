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
import { CLASSIFIER_VERSION, classifyCritique } from '../lib/classifier.js';
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
    // Stats's `total_critiques` should reflect ALL critiques, not
    // just classified ones — otherwise a user with 41 pre-classifier
    // critiques sees "Total critiques: 0" until they backfill, which
    // contradicts the header's "41 critiques" line. The category-
    // based stats (most_discussed, most_improved, current_focus) all
    // safely skip untagged entries via internal `if (!c.tags) continue`
    // guards, so passing the unfiltered list is safe.
    stats: buildStats(allReelCritiques),
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

// =============================================================================
// POST /v1/me/evolution/refresh — backfill missing tags + reload
// =============================================================================
//
// Walks the user's critique_history and classifies every entry whose
// `tags` field is missing (pre-classifier critiques + classifier-failed
// rows). Writes the newly-tagged history back via PATCH on the drawing
// row. Caps the per-call work at REFRESH_BACKFILL_CAP entries so a power
// user with hundreds of untagged critiques doesn't blow the OpenAI
// budget in a single tap — they'd hit Refresh again to chip down the
// backlog.
//
// On the wire:
//   - 200 → { backfilled, scanned, cap_reached, ...full GET /v1/me/evolution body }
//   - 401/403/500 → standard error envelope
//
// Race-safe-enough: the PATCH writes the entire critique_history array
// for each drawing whose entries were tagged. If a fresh critique lands
// from the feedback path BETWEEN our read and write, the fresh entry
// gets clobbered. For backfill (rare, manual trigger, no concurrent
// taps), the window is small enough to accept. A migration adding an
// `update_critique_entry_tags(uuid, uuid, jsonb)` RPC would close it.

// Cap on classifier calls per refresh tap. Sized against Cloudflare's
// 50-subrequest-per-invocation limit (drawings fetch + PATCHes consume
// some, leaving headroom for classifier fan-out) and the ~30s wall-
// clock budget. Classifier calls run in parallel via Promise.all so
// the total wall-clock is roughly the slowest single call, not the
// sum — without parallelism, 40 sequential calls at 2-3s each would
// blow the worker timeout.
const REFRESH_BACKFILL_CAP = 40;

async function patchDrawingCritiqueHistory({ env, drawingId, history, fetcher = fetch }) {
  const url = `${env.SUPABASE_URL}/rest/v1/drawings?id=eq.${encodeURIComponent(drawingId)}`;
  const res = await fetcher(url, {
    method: 'PATCH',
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      'Content-Type': 'application/json',
      Prefer: 'return=minimal',
    },
    body: JSON.stringify({ critique_history: history }),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '<unreadable>');
    throw new Error(`patch drawing HTTP ${res.status}: ${body.slice(0, 500)}`);
  }
}

export async function handleEvolutionRefresh(request, env, ctx, fetcher = fetch) {
  const configErr = validateWorkerConfig(env);
  if (configErr) return jsonResponse({ error: configErr }, 500);

  const auth = await requireAuth(request, env, ctx);
  if (!auth.ok) return auth.response;
  const { userId } = auth;

  let drawings;
  try {
    drawings = await fetchUserDrawings({ env, userId, fetcher });
  } catch (err) {
    console.error('[evolution-refresh] fetch drawings failed', err?.message);
    return jsonResponse({ error: 'evolution_unavailable' }, 502);
  }

  // Diagnostic: how many drawings + total entries + tagged-already + untagged?
  // Logs once per refresh so wrangler tail shows the situation at a glance.
  {
    let totalEntries = 0;
    let alreadyTagged = 0;
    let needsTags = 0;
    let emptyContent = 0;
    for (const d of drawings) {
      const entries = Array.isArray(d?.critique_history) ? d.critique_history : [];
      totalEntries += entries.length;
      for (const e of entries) {
        if (e?.tags) {
          alreadyTagged += 1;
        } else {
          const content = typeof e?.content === 'string' ? e.content.trim() : '';
          if (content.length === 0) emptyContent += 1;
          else needsTags += 1;
        }
      }
    }
    console.log('[evolution-refresh] user', userId,
      'drawings', drawings.length,
      'total_entries', totalEntries,
      'already_tagged', alreadyTagged,
      'needs_tags', needsTags,
      'empty_content', emptyContent);
  }

  // Build a flat list of entries-to-classify across all drawings.
  // We need to remember each entry's drawing + array position so we
  // can put the classified tags back in the right slot after the
  // parallel fan-out. Chronological order across drawings so a
  // capped backfill progresses oldest-first; users see their full
  // history fill in across taps.
  const work = [];       // { drawingId, entryIndex, entry, content }
  const sortedByDrawing = new Map();  // drawing_id → sorted entries array
  for (const d of drawings) {
    const entries = Array.isArray(d?.critique_history) ? d.critique_history : [];
    if (entries.length === 0) continue;
    const sorted = [...entries].sort((a, b) => {
      const ta = a?.created_at ? Date.parse(a.created_at) : 0;
      const tb = b?.created_at ? Date.parse(b.created_at) : 0;
      return ta - tb;
    });
    sortedByDrawing.set(d.id, sorted);
    for (let i = 0; i < sorted.length; i += 1) {
      const entry = sorted[i];
      if (!entry || typeof entry !== 'object') continue;
      if (entry.tags) continue;
      const content = typeof entry.content === 'string' ? entry.content : '';
      if (content.trim().length === 0) continue;
      work.push({ drawingId: d.id, entryIndex: i, entry, content });
    }
  }
  // Cross-drawing chronological order: oldest first.
  work.sort((a, b) => {
    const ta = a.entry?.created_at ? Date.parse(a.entry.created_at) : 0;
    const tb = b.entry?.created_at ? Date.parse(b.entry.created_at) : 0;
    return ta - tb;
  });
  const scanned = work.length;
  const capReached = scanned > REFRESH_BACKFILL_CAP;
  const todo = work.slice(0, REFRESH_BACKFILL_CAP);

  // PARALLEL classifier fan-out. Sequential calls would blow CF's ~30s
  // wall-clock budget (~3s/call × 40 calls = 120s). Promise.all caps
  // at the slowest single call — typically 5-8 seconds for gpt-5-mini
  // with json_schema. OpenAI's rate limits absorb 40 simultaneous
  // requests comfortably for the small-model tier.
  const tagsResults = await Promise.all(
    todo.map((w) => classifyCritique({ feedback: w.content, env, fetcher }))
  );

  // Apply tags into the sorted arrays, track patches per drawing.
  let backfilled = 0;
  let classifierNulls = 0;
  const drawingsToPatch = new Map();
  for (let i = 0; i < todo.length; i += 1) {
    const w = todo[i];
    const tags = tagsResults[i];
    if (!tags) {
      classifierNulls += 1;
      continue;
    }
    const sorted = sortedByDrawing.get(w.drawingId);
    if (!sorted) continue;
    sorted[w.entryIndex] = { ...w.entry, tags };
    drawingsToPatch.set(w.drawingId, sorted);
    backfilled += 1;
  }
  console.log('[evolution-refresh] summary',
    'scanned', scanned,
    'backfilled', backfilled,
    'classifier_nulls', classifierNulls,
    'patches', drawingsToPatch.size,
    'cap_reached', capReached);

  // Write back. Each PATCH is its own request — if one fails, the rest
  // still land. The catch logs but doesn't fail the response; the user
  // sees a partial backfill which is better than an all-or-nothing
  // 500 that reverts everything.
  for (const [drawingId, history] of drawingsToPatch) {
    try {
      await patchDrawingCritiqueHistory({ env, drawingId, history, fetcher });
    } catch (err) {
      console.error('[evolution-refresh] patch failed', drawingId, err?.message);
    }
  }

  // After backfill, re-read drawings and return the full evolution
  // payload so the iOS client doesn't need a second round-trip.
  let freshDrawings;
  try {
    freshDrawings = await fetchUserDrawings({ env, userId, fetcher });
  } catch (err) {
    console.error('[evolution-refresh] post-backfill fetch failed', err?.message);
    // Even if the re-read fails, we still report the backfill count.
    return jsonResponse({
      backfilled,
      scanned,
      cap_reached: capReached,
      classifier_version: CLASSIFIER_VERSION,
      error: 'reload_failed',
    }, 200);
  }

  const body = buildEvolutionResponseV2(freshDrawings, {
    windowCritiques: DEFAULT_WINDOW_CRITIQUES,
    windowDays: DEFAULT_WINDOW_DAYS,
    now: Date.now(),
  });

  return jsonResponse({
    ...body,
    backfilled,
    scanned,
    cap_reached: capReached,
  });
}
