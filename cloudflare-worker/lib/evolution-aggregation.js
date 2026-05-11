// Pure aggregation logic for GET /v1/me/evolution. No I/O — every function
// in this file takes plain data, returns plain data, and is unit-testable
// in isolation. The route handler in routes/evolution.js handles auth +
// Supabase fetch and delegates the math here.
//
// Why JS (not SQL): per-user data volumes are small (capped at 50 drawings,
// 200 critiques in the analysis), and the trend / status logic is easier
// to test and reason about as functions than as nested SQL CTEs.

import { CRITIQUE_CATEGORIES, SEVERITY_MIN, SEVERITY_MAX } from './taxonomy.js';

// =============================================================================
// Status thresholds — load-bearing for how the future "My Evolution" UI feels
// =============================================================================
//
// These two constants are the knobs that decide whether a user reads the
// app as "I'm improving" vs. "I'm plateauing." Tweaking them shifts the
// emotional tone of every category card, so the calls are documented
// here rather than buried inside branch logic.

// Recent-average severity at or below this counts as the user having
// mastered a category — status reads as "solid_foundation" regardless of
// trend direction. Tied to the 1-5 severity scale: 1 is a minor refinement,
// so a recent average ≤ 1.5 means the category is hovering just above
// "no real issue" land. Set higher and steady-but-mediocre work gets
// branded as solid; set lower and only near-perfect work qualifies.
export const SOLID_FOUNDATION_CEILING = 1.5;

// Minimum gap between first-half and second-half averages to call a trend
// "meaningfully" improving or worsening. Below this, the series reads as
// "steady" regardless of direction. Calibrated against the 1-5 severity
// scale: ~0.75 is roughly one severity-level of average shift, which feels
// like real motion to the user without flipping at every minor wobble.
export const MEANINGFUL_DELTA = 0.75;

// =============================================================================
// Other constants
// =============================================================================

// Threshold for when a category has enough data to render a trend honestly
// (vs. landing in `warming_up`). State-dependent as of Phase 2.5: a "mature"
// user (10+ critiques) needs the full 5-point floor; a "growing" user (3-9
// critiques) sees categories at 2+ data points so the chart isn't empty for
// most of their first month. Same series data either way — the threshold
// only decides which array a category lands in (and whether status gets
// computed for it).
export const MIN_DATA_POINTS_MATURE = 5;
export const MIN_DATA_POINTS_GROWING = 2;

// Back-compat alias. External callers (and the existing test that locks the
// constant) reference MIN_DATA_POINTS by its original name; keep it pointed
// at the mature threshold so the old default behavior is preserved when no
// state is in play.
export const MIN_DATA_POINTS = MIN_DATA_POINTS_MATURE;

// Severity-weighted point values: a category mentioned as primary counts
// fully, as secondary counts half. Reflects the stronger signal of being
// the Focus Area vs. an aside in the same critique.
export const PRIMARY_WEIGHT = 1.0;
export const SECONDARY_WEIGHT = 0.5;

// Hard cap on how many critique entries we feed into the aggregation,
// even if the caller asks for more. Bounds per-request cost when a
// power user has accumulated thousands of critiques.
export const MAX_AGGREGATION_ENTRIES = 200;

// Query-param defaults + caps. Parked here (not in the route) so they're
// importable in tests next to the rest of the windowing logic.
export const DEFAULT_WINDOW_CRITIQUES = 20;
export const MAX_WINDOW_CRITIQUES = 200;
export const DEFAULT_WINDOW_DAYS = 90;
export const MAX_WINDOW_DAYS = 365;

const MS_PER_DAY = 24 * 60 * 60 * 1000;

// =============================================================================
// Internal helpers
// =============================================================================

function isValidTags(tags) {
  if (!tags || typeof tags !== 'object' || Array.isArray(tags)) return false;
  if (!CRITIQUE_CATEGORIES.includes(tags.primary_category)) return false;
  if (!Array.isArray(tags.secondary_categories)) return false;
  if (tags.secondary_categories.length > 2) return false;
  for (const c of tags.secondary_categories) {
    if (!CRITIQUE_CATEGORIES.includes(c)) return false;
  }
  if (!Number.isInteger(tags.severity)) return false;
  if (tags.severity < SEVERITY_MIN || tags.severity > SEVERITY_MAX) return false;
  return true;
}

function mean(arr) {
  if (arr.length === 0) return 0;
  let s = 0;
  for (const x of arr) s += x;
  return s / arr.length;
}

// =============================================================================
// Public functions
// =============================================================================

/**
 * Pull every critique_history entry off the drawings, drop pre-Phase-1
 * entries (no tags) and malformed-tag entries, return the remainder sorted
 * by created_at DESC. Pure: takes the array shape returned by Supabase
 * REST and returns a normalized array.
 *
 * Carries `drawing_id` so downstream consumers (notably the v2 reel) can
 * join each critique back to its source drawing's title / thumbnail /
 * subject without re-traversing the drawings array. Also carries the
 * critique `id` and `content` for excerpt extraction. The original
 * chart-aggregation path (aggregateCategories + determineStatus) only
 * reads created_ts + tags, so the extra fields are free for legacy
 * callers.
 */
export function flattenCritiques(drawings) {
  if (!Array.isArray(drawings)) return [];
  const out = [];
  for (const d of drawings) {
    const entries = Array.isArray(d?.critique_history) ? d.critique_history : [];
    for (const entry of entries) {
      if (!entry || typeof entry !== 'object') continue;
      if (!entry.tags) continue;                  // pre-Phase-1 row, skip silently
      if (!isValidTags(entry.tags)) continue;     // malformed tags, skip silently
      const ts = entry.created_at ? Date.parse(entry.created_at) : NaN;
      if (!Number.isFinite(ts)) continue;
      out.push({
        critique_id: entry.id ?? null,
        drawing_id: d?.id ?? null,
        content: typeof entry.content === 'string' ? entry.content : '',
        created_at: entry.created_at,
        created_ts: ts,
        has_tags: true,
        tags: entry.tags,
      });
    }
  }
  out.sort((a, b) => b.created_ts - a.created_ts);
  return out;
}

/**
 * Variant for the v2 reel: returns every critique with valid metadata,
 * regardless of whether it carries classifier tags. Pre-Phase-1
 * critiques predate the classifier; later critiques where the
 * classifier silently failed also lack tags. Either way they belong
 * in the reel — the user's intent is "show me my recent critiques,"
 * not "show me my recent classifier-validated critiques." Themes and
 * stats still go through the tag-requiring `flattenCritiques` because
 * their math depends on the structured tags.
 *
 * Entries without tags get `has_tags: false` and `tags: null` so
 * downstream consumers (notably `buildReel.primary_category`) know to
 * render them without a category chip.
 */
export function flattenCritiquesForReel(drawings) {
  if (!Array.isArray(drawings)) return [];
  const out = [];
  for (const d of drawings) {
    const entries = Array.isArray(d?.critique_history) ? d.critique_history : [];
    for (const entry of entries) {
      if (!entry || typeof entry !== 'object') continue;
      const ts = entry.created_at ? Date.parse(entry.created_at) : NaN;
      if (!Number.isFinite(ts)) continue;
      // Skip entries with no content — nothing to surface. Tag-less
      // entries with content are explicitly OK.
      const content = typeof entry.content === 'string' ? entry.content : '';
      if (content.trim().length === 0) continue;
      const tags = entry.tags && isValidTags(entry.tags) ? entry.tags : null;
      out.push({
        critique_id: entry.id ?? null,
        drawing_id: d?.id ?? null,
        content,
        created_at: entry.created_at,
        created_ts: ts,
        has_tags: tags !== null,
        tags,
      });
    }
  }
  out.sort((a, b) => b.created_ts - a.created_ts);
  return out;
}

/**
 * Pick the analysis window. Receives entries sorted DESC, returns a
 * subset still sorted DESC.
 *
 * Rule (per Phase 2 spec): take the first `windowCritiques` entries OR
 * everything within the last `windowDays`, whichever has MORE entries.
 * Tie goes to the count cap (set A) so the response is deterministic when
 * both windows resolve to the same count.
 */
export function selectWindow(entries, { windowCritiques, windowDays, now }) {
  if (!Array.isArray(entries) || entries.length === 0) return [];
  const cap = Math.min(windowCritiques, MAX_AGGREGATION_ENTRIES);
  const setA = entries.slice(0, cap);
  const cutoff = now - windowDays * MS_PER_DAY;
  const setB = entries
    .filter((e) => e.created_ts >= cutoff)
    .slice(0, MAX_AGGREGATION_ENTRIES);
  return setB.length > setA.length ? setB : setA;
}

/**
 * Determine status for one category's series. series is oldest-first;
 * data_points = series.length. Returns one of the four status strings, or
 * null when below the data threshold (caller should route those to
 * warming_up instead).
 *
 * `threshold` defaults to MIN_DATA_POINTS_MATURE so existing call sites
 * (and tests) that don't pass it keep the original 5-point floor. Phase
 * 2.5 callers pass MIN_DATA_POINTS_GROWING (2) when the user is in
 * "growing" state.
 */
export function determineStatus(series, threshold = MIN_DATA_POINTS_MATURE) {
  if (!Array.isArray(series) || series.length < threshold) return null;
  const half = Math.floor(series.length / 2);
  const firstAvg = mean(series.slice(0, half));
  const secondAvg = mean(series.slice(half));
  const delta = secondAvg - firstAvg;
  if (secondAvg <= SOLID_FOUNDATION_CEILING) return 'solid_foundation';
  if (delta <= -MEANINGFUL_DELTA) return 'improving';
  if (delta >= MEANINGFUL_DELTA) return 'current_focus';
  return 'steady';
}

/**
 * Aggregate per-category series + warming_up across the chosen window.
 * windowEntries should be the result of selectWindow (newest-first; this
 * function reorders internally).
 *
 * `threshold` (Phase 2.5) decides where categories land:
 *   - data_points >= threshold → `categories` (with status computed)
 *   - data_points <  threshold → `warming_up` (with `needed: threshold`)
 * Defaults to MIN_DATA_POINTS_MATURE so existing call sites keep the
 * original 5-point behavior. Pass MIN_DATA_POINTS_GROWING for the lowered
 * "growing"-state floor.
 *
 * Returns { categories, warmingUp, window }:
 *   - categories: { id, data_points, current_value, series, status } for
 *     each category with data_points >= threshold, sorted by data_points
 *     DESC then id ASC for deterministic output.
 *   - warmingUp:  { id, data_points, needed } for categories below the
 *     threshold (data_points > 0).
 *   - window:     { critique_count, earliest_at, latest_at, span_days }.
 */
export function aggregateCategories(windowEntries, { threshold = MIN_DATA_POINTS_MATURE } = {}) {
  if (!Array.isArray(windowEntries) || windowEntries.length === 0) {
    return {
      categories: [],
      warmingUp: [],
      window: { critique_count: 0, earliest_at: null, latest_at: null, span_days: 0 },
    };
  }
  // Iterate oldest-first so each category's series accumulates in
  // chronological order. Spec lock: "criticality over time, oldest first."
  const ordered = [...windowEntries].sort((a, b) => a.created_ts - b.created_ts);

  const buckets = new Map();
  for (const cat of CRITIQUE_CATEGORIES) buckets.set(cat, []);

  for (const e of ordered) {
    const t = e.tags;
    const primary = t.primary_category;
    buckets.get(primary).push(t.severity * PRIMARY_WEIGHT);
    for (const sec of t.secondary_categories) {
      // The classifier validator already rejects primary appearing in
      // secondaries, but defense-in-depth: don't double-count if a row
      // ever slips through.
      if (sec === primary) continue;
      buckets.get(sec).push(t.severity * SECONDARY_WEIGHT);
    }
  }

  const categories = [];
  const warmingUp = [];
  for (const [id, series] of buckets) {
    const dp = series.length;
    if (dp === 0) continue;
    if (dp >= threshold) {
      categories.push({
        id,
        data_points: dp,
        current_value: series[series.length - 1],
        series,
        status: determineStatus(series, threshold),
      });
    } else {
      warmingUp.push({ id, data_points: dp, needed: threshold });
    }
  }

  const cmp = (a, b) =>
    b.data_points - a.data_points || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  categories.sort(cmp);
  warmingUp.sort(cmp);

  const earliest = ordered[0];
  const latest = ordered[ordered.length - 1];
  return {
    categories,
    warmingUp,
    window: {
      critique_count: ordered.length,
      earliest_at: earliest.created_at,
      latest_at: latest.created_at,
      span_days: Math.round((latest.created_ts - earliest.created_ts) / MS_PER_DAY),
    },
  };
}

/**
 * Compute streak counters from the drawings list. drawings is the raw
 * Supabase row shape: { id, created_at, updated_at, critique_history }.
 *
 * NOTE: drawings_total / critiques_total reflect the rows the caller
 * passed in (capped at LIMIT 50 in the route, ordered by updated_at DESC).
 * For users with > 50 drawings these numbers undercount lifetime totals;
 * the 7-day / 30-day windows are accurate as long as the user has not
 * updated > 50 drawings in 30 days. Acceptable trade for keeping this to
 * a single Supabase round-trip; revisit if a user case actually hits the
 * ceiling.
 */
export function computeStreak(drawings, { now }) {
  if (!Array.isArray(drawings)) {
    return {
      drawings_this_week: 0,
      drawings_this_month: 0,
      critiques_total: 0,
      drawings_total: 0,
    };
  }
  const weekCutoff = now - 7 * MS_PER_DAY;
  const monthCutoff = now - 30 * MS_PER_DAY;
  let weekCount = 0;
  let monthCount = 0;
  let critiquesTotal = 0;
  for (const d of drawings) {
    if (Array.isArray(d?.critique_history)) critiquesTotal += d.critique_history.length;
    const ts = d?.updated_at ? Date.parse(d.updated_at) : NaN;
    if (!Number.isFinite(ts)) continue;
    if (ts >= weekCutoff) weekCount += 1;
    if (ts >= monthCutoff) monthCount += 1;
  }
  return {
    drawings_this_week: weekCount,
    drawings_this_month: monthCount,
    critiques_total: critiquesTotal,
    drawings_total: drawings.length,
  };
}

// =============================================================================
// Phase 2.5 — state derivation, summary text, example payload
// =============================================================================
//
// The Phase 2 endpoint shape works once a user has accumulated 10+ tagged
// critiques, but is barely useful before that. Phase 2.5 layers four
// additional concerns on top of the pure aggregation:
//
//   1. A `state` discriminator the iOS UI keys off ("example" / "early" /
//      "growing" / "mature"). Derived from streak.critiques_total — pure
//      function so tests can drive every boundary without a fixture.
//   2. A state-dependent threshold (MIN_DATA_POINTS_GROWING vs
//      MIN_DATA_POINTS_MATURE) so growing users see categories in the chart
//      sooner. Plumbed through aggregateCategories above.
//   3. A `summary_text` string composed from real aggregation data when the
//      user is "early" or "growing". Plain template, no AI call.
//   4. A hardcoded EXAMPLE_PAYLOAD substituted into the response when the
//      user has zero tagged critiques, so the iOS Evolution tab shows
//      something illustrative on first launch instead of an empty chart.
//
// All four pieces are pure functions / constants. Orchestration (deciding
// which to invoke) lives in routes/evolution.js.

/**
 * Map lifetime tagged-critique count to a state string. Boundary
 * inclusivity is locked: 0 → example, 1-2 → early, 3-9 → growing,
 * 10+ → mature. Implemented as explicit branches rather than a lookup
 * table because the rule is short and the boundaries are load-bearing.
 *
 * Negative or non-finite inputs are coerced to "example" defensively
 * (they shouldn't happen — computeStreak only returns non-negative
 * integers — but a stray NaN reaching the iOS UI would render as an
 * uncovered state).
 */
export function deriveState(critiquesTotal) {
  if (!Number.isFinite(critiquesTotal) || critiquesTotal <= 0) return 'example';
  if (critiquesTotal <= 2) return 'early';
  if (critiquesTotal <= 9) return 'growing';
  return 'mature';
}

// =============================================================================
// Summary text composition
// =============================================================================

// Templates parked at module scope so future tuning is a one-line change.
// Variables: {N} = critiques_total, {N_PHRASE} = "critique" | "2 critiques",
// {CATEGORIES} = rendered category list, {TOP} = top category id (lowercase),
// {CAT_CAP} = category id with first letter uppercased.
const EARLY_PREFIX_1 = 'Your last critique covered ';
const EARLY_PREFIX_N = 'Your last {N} critiques covered ';
const EARLY_SUFFIX = '. Trends start filling in around 3 critiques.';

const GROWING_HEAD = 'Across your last {N} critiques, the most-mentioned theme is {TOP}.';
const GROWING_FOCUS_TAIL = ' {CAT_CAP} is your current focus.';
const GROWING_IMPROVING_TAIL = ' {CAT_CAP} is improving.';
const GROWING_EMPTY = 'Across your last {N} critiques, no consistent theme yet.';

const SUMMARY_MAX_CHARS = 200;

function capitalizeId(id) {
  if (typeof id !== 'string' || id.length === 0) return id;
  return id.charAt(0).toUpperCase() + id.slice(1);
}

/**
 * Render a list of category ids in human form. 1 → "anatomy"; 2 →
 * "anatomy and composition"; 3+ → Oxford-comma form. Pure helper, no
 * truncation; the caller decides whether the full list fits the cap.
 */
function renderCategoryList(ids) {
  if (ids.length === 0) return '';
  if (ids.length === 1) return ids[0];
  if (ids.length === 2) return `${ids[0]} and ${ids[1]}`;
  return `${ids.slice(0, -1).join(', ')}, and ${ids[ids.length - 1]}`;
}

/**
 * Compose the early-state summary, falling back to a "and N others"
 * shortened form if the full list would push the result past
 * SUMMARY_MAX_CHARS. Returns the final string (always under the cap).
 */
function composeEarlySummary(critiquesTotal, sortedIds) {
  const prefix = critiquesTotal === 1
    ? EARLY_PREFIX_1
    : EARLY_PREFIX_N.replace('{N}', String(critiquesTotal));
  const fullList = renderCategoryList(sortedIds);
  const fullText = `${prefix}${fullList}${EARLY_SUFFIX}`;
  if (fullText.length <= SUMMARY_MAX_CHARS) return fullText;
  // Defensive truncation: keep the first two ids verbatim, replace the
  // rest with "and N others". With 8 taxonomy categories total and
  // 1-2 critiques contributing at most ~6 distinct ids, this branch is
  // unlikely to fire in practice — but the cap is a hard contract.
  const remaining = sortedIds.length - 2;
  const truncated = remaining > 0
    ? `${sortedIds[0]}, ${sortedIds[1]}, and ${remaining} others`
    : renderCategoryList(sortedIds);
  return `${prefix}${truncated}${EARLY_SUFFIX}`;
}

/**
 * Compose the growing-state summary. Picks the first category in
 * sorted-by-data_points order with status === "current_focus" for the
 * second sentence; falls back to the first "improving"; omits the
 * second sentence otherwise. Falls back to GROWING_EMPTY if categories
 * is empty (defensive — unlikely with threshold 2).
 */
function composeGrowingSummary(critiquesTotal, categories) {
  if (categories.length === 0) {
    return GROWING_EMPTY.replace('{N}', String(critiquesTotal));
  }
  const top = categories[0].id;
  const head = GROWING_HEAD
    .replace('{N}', String(critiquesTotal))
    .replace('{TOP}', top);
  const focus = categories.find((c) => c.status === 'current_focus');
  const improving = focus ? null : categories.find((c) => c.status === 'improving');
  let tail = '';
  if (focus) tail = GROWING_FOCUS_TAIL.replace('{CAT_CAP}', capitalizeId(focus.id));
  else if (improving) tail = GROWING_IMPROVING_TAIL.replace('{CAT_CAP}', capitalizeId(improving.id));
  const full = `${head}${tail}`;
  // Cap defensively. Head + tail with the longest taxonomy id
  // ("subject_match" → "Subject_match") tops out well under 200 chars,
  // but if a future taxonomy bump pushes it over, drop the tail.
  if (full.length <= SUMMARY_MAX_CHARS) return full;
  return head;
}

/**
 * Compose plain-language summary text for the iOS Evolution tab.
 * Returns a string for "early" and "growing" states, returns null for
 * "mature" and "example" (caller should omit the field from the
 * response when null).
 *
 * Pure function — no I/O, no AI call. The category data passed in is
 * the pre-substitution real-user data (so even when the route ends up
 * emptying categories/warming_up for "early" state, the summary text
 * still reflects what the user has actually been working on).
 */
export function composeSummaryText(state, categories, warmingUp, streak) {
  if (state !== 'early' && state !== 'growing') return null;
  const critiquesTotal = streak?.critiques_total ?? 0;

  if (state === 'early') {
    // Combine categories + warming_up — at threshold 5 (the default this
    // route runs at before state is known), 1-2 critiques produce only
    // warming_up entries, but we want the summary to list every category
    // touched regardless of which array it's in.
    const merged = [...(categories ?? []), ...(warmingUp ?? [])];
    merged.sort((a, b) =>
      b.data_points - a.data_points || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    const ids = merged.map((c) => c.id);
    return composeEarlySummary(critiquesTotal, ids);
  }

  // state === 'growing'
  return composeGrowingSummary(critiquesTotal, categories ?? []);
}

// =============================================================================
// Example payload — substituted into the response when state === "example"
// =============================================================================
//
// Represents a believable artist after ~25 critiques. The series numbers are
// chosen so each declared status is what the production determineStatus
// function would compute from the series (firstAvg / secondAvg / delta vs.
// SOLID_FOUNDATION_CEILING and MEANINGFUL_DELTA). Verified by hand against
// the same math the real aggregator uses; if those constants change, the
// status fields here may need recomputing.
//
// Sorted by data_points DESC, matching the deterministic order
// aggregateCategories produces for real users — the iOS UI shouldn't have
// to special-case ordering for the example.

export const EXAMPLE_PAYLOAD = {
  example_artist_label:
    'Example: this is what your evolution looks like after about 25 critiques. Yours will keep growing from here.',
  categories: [
    {
      id: 'anatomy',
      data_points: 8,
      series: [4, 4.5, 3.5, 4, 3, 2.5, 2, 2],
      current_value: 2,
      status: 'improving',
    },
    {
      id: 'composition',
      data_points: 7,
      series: [2, 2.5, 3, 2.5, 3.5, 4, 4],
      current_value: 4,
      status: 'current_focus',
    },
    {
      id: 'value',
      data_points: 6,
      series: [3, 2.5, 3, 3.5, 3, 2.5],
      current_value: 2.5,
      status: 'steady',
    },
    {
      id: 'perspective',
      data_points: 5,
      series: [1, 1.5, 1, 1, 1.5],
      current_value: 1.5,
      status: 'solid_foundation',
    },
  ],
  warming_up: [
    { id: 'color', data_points: 3, needed: 5 },
    { id: 'line', data_points: 2, needed: 5 },
  ],
};

// =============================================================================
// v2 helpers — drawing reel, summary, stats
// =============================================================================
//
// The v1 chart-based panel collapsed all critique data into per-category
// trend lines. The v2 panel keeps the structured tags but reframes the
// surface around concrete drawings + their critiques. These helpers
// produce the new response sections; the chart-side helpers above remain
// intact (and unused by the v2 route) for reference and in case we ever
// want to A/B back to the chart presentation.

// Excerpt cap. Long critiques are typical (gpt-5.1 outputs 2-4 paragraphs)
// but the reel row should fit two lines on iPad. 240 chars is two visible
// lines at the default body type size.
const EXCERPT_MAX_CHARS = 240;

// Heuristic markers — sentences containing any of these tokens are
// preferred for the excerpt because they describe progress relative to
// past critiques. Lowercased for case-insensitive match.
const EXCERPT_PROGRESS_TOKENS = ['compared', 'previously', 'improv', 'since your last', 'since the last'];

/**
 * Deterministic excerpt picker. No LLM. Phase 2 will overlay an
 * LLM-paraphrased version on top of this; Phase 1 ships with the raw
 * sentence pick rendered to the reel.
 *
 * Algorithm:
 *   1. Split critique text on sentence boundaries (`. `, `! `, `? `).
 *   2. Prefer the first sentence containing any of EXCERPT_PROGRESS_TOKENS
 *      (case-insensitive) — those sentences describe growth, which is the
 *      reel's whole point.
 *   3. Fall back to the first sentence.
 *   4. Hard cap at EXCERPT_MAX_CHARS with single-character ellipsis.
 *
 * Pure function. Returns "" for empty/non-string input.
 */
export function extractExcerpt(text) {
  if (typeof text !== 'string' || text.length === 0) return '';
  // Split on sentence-end punctuation followed by whitespace. Preserves
  // the punctuation. Anchors split on whitespace specifically so abbrev.
  // dots (e.g. "Mr.") don't fragment sentences.
  const sentences = text
    .split(/(?<=[.!?])\s+/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  if (sentences.length === 0) return '';

  const lower = sentences.map((s) => s.toLowerCase());
  let pick = sentences[0];
  for (let i = 0; i < sentences.length; i += 1) {
    if (EXCERPT_PROGRESS_TOKENS.some((tok) => lower[i].includes(tok))) {
      pick = sentences[i];
      break;
    }
  }
  if (pick.length <= EXCERPT_MAX_CHARS) return pick;
  return pick.slice(0, EXCERPT_MAX_CHARS - 1).trimEnd() + '…';
}

/**
 * Build the v2 summary block. Inputs:
 *   - drawings: raw Supabase rows (with `context` jsonb already parsed by
 *     the route — the v2 SELECT pulls `context` alongside id/title/etc).
 *   - streak: the same shape computeStreak returns; used for drawings_this_month
 *     and to derive critiques_this_month.
 *   - now: epoch ms; used to count critiques in the 30-day window.
 *
 * Returns { drawings_this_month, critiques_this_month, top_subjects,
 *           insights_last_updated_at }.
 *
 * `critiques_this_month` counts critiques (not drawings) whose
 * `created_at` falls in the last 30 days. This is a more honest "what
 * have you been doing recently" signal than `critiques_total` (which is
 * lifetime) or `drawings_this_month` (which doesn't reflect critique
 * volume).
 *
 * `top_subjects` is up to 3 most-frequent `context.subject` strings
 * across the drawings list, lowercased and pluralized via a tiny rule
 * (append "s" unless already plural-looking). Stripped of empties.
 *
 * `insights_last_updated_at` is null in Phase 1 (no LLM cache yet);
 * Phase 2 populates it from the KV synthesis cache.
 */
export function buildSummary(drawings, streak, { now }) {
  const safeDrawings = Array.isArray(drawings) ? drawings : [];
  const monthCutoff = now - 30 * MS_PER_DAY;

  let critiquesThisMonth = 0;
  const subjectCounts = new Map();
  for (const d of safeDrawings) {
    const entries = Array.isArray(d?.critique_history) ? d.critique_history : [];
    for (const e of entries) {
      const ts = e?.created_at ? Date.parse(e.created_at) : NaN;
      if (Number.isFinite(ts) && ts >= monthCutoff) critiquesThisMonth += 1;
    }
    const subject = typeof d?.context?.subject === 'string'
      ? d.context.subject.trim().toLowerCase()
      : '';
    if (subject.length > 0) {
      subjectCounts.set(subject, (subjectCounts.get(subject) ?? 0) + 1);
    }
  }

  const topSubjects = [...subjectCounts.entries()]
    .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
    .slice(0, 3)
    .map(([s]) => pluralizeSubject(s));

  return {
    drawings_this_month: streak?.drawings_this_month ?? 0,
    critiques_this_month: critiquesThisMonth,
    top_subjects: topSubjects,
    insights_last_updated_at: null,
  };
}

// Tiny plural rule. Acceptable English imperfection for v1 — "still lifes"
// is the right plural for "still life" but the rule below produces
// "still lifes" too because the input is already lowercased. Edge cases
// like "fish" / "person" don't appear in DrawEvolve's subject vocabulary
// (the questionnaire surfaces typical art subjects).
function pluralizeSubject(subject) {
  if (subject.endsWith('s')) return subject;
  return subject + 's';
}

/**
 * Build the v2 reel. Inputs:
 *   - critiques: oldest-first OR newest-first array of flattenCritiques
 *     output (function reorders internally).
 *   - drawingsById: Map<drawing_id, drawing row> for joining title/
 *     storage_path/context.subject onto each row.
 *   - limit: max rows to return (default 10 per proposal §4.5).
 *
 * Returns the array of reel rows, newest-first.
 *
 * Each row carries both `excerpt_paraphrase` and `excerpt_raw`. In
 * Phase 1, `excerpt_paraphrase` is null (no LLM yet); Phase 2 populates
 * it from the synthesis cache. The iOS reel renders paraphrase when
 * present and falls back to raw.
 */
export function buildReel(critiques, drawingsById, { limit = 10 } = {}) {
  if (!Array.isArray(critiques) || critiques.length === 0) return [];
  const sorted = [...critiques].sort((a, b) => b.created_ts - a.created_ts);
  const out = [];
  for (const c of sorted) {
    if (out.length >= limit) break;
    if (!c.drawing_id) continue;
    const drawing = drawingsById.get(c.drawing_id);
    if (!drawing) continue;
    const title = typeof drawing.title === 'string' && drawing.title.trim().length > 0
      ? drawing.title.trim()
      : null;
    const subject = typeof drawing.context?.subject === 'string'
      ? drawing.context.subject.trim()
      : null;
    // Tag-less rows render with no category chip but still get a
    // thumbnail, title, date, and excerpt — they're as much "recent
    // work" as a tagged row is.
    const primaryCategory = c.tags && typeof c.tags.primary_category === 'string'
      ? c.tags.primary_category
      : null;
    out.push({
      critique_id: c.critique_id,
      drawing_id: c.drawing_id,
      drawing_title: title,
      drawing_subject: subject,
      thumbnail_path: drawing.storage_path ?? null,
      created_at: c.created_at,
      excerpt_paraphrase: null,
      excerpt_raw: extractExcerpt(c.content),
      primary_category: primaryCategory,
    });
  }
  return out;
}

/**
 * Build the v2 stats footer. Inputs:
 *   - critiques: full flattenCritiques output (NOT windowed — stats are
 *     lifetime-scoped within the fetched 50-drawing limit).
 *
 * Returns { total_critiques, most_discussed_category,
 *           most_improved_category, current_focus_area }.
 *
 * `most_discussed_category` = category with the highest weighted mention
 *   count (primary = 1, secondary = 0.5, same weighting as the legacy
 *   chart aggregation). Single id or null if no critiques.
 *
 * `most_improved_category` = category with the largest negative delta
 *   between first-half and second-half severity averages (lower severity
 *   = better). Only computed when there are >= 4 critiques (need 2 per
 *   half to be meaningful). null otherwise.
 *
 * `current_focus_area` = focus_area_text from the most-recent critique
 *   that has one set. null if none.
 */
export function buildStats(critiques) {
  const safe = Array.isArray(critiques) ? critiques : [];
  const total = safe.length;
  if (total === 0) {
    return {
      total_critiques: 0,
      most_discussed_category: null,
      most_improved_category: null,
      current_focus_area: null,
    };
  }

  // Most-discussed: weighted category mention counter.
  const mentionWeight = new Map();
  for (const cat of CRITIQUE_CATEGORIES) mentionWeight.set(cat, 0);
  for (const c of safe) {
    const t = c.tags;
    if (!t) continue;
    mentionWeight.set(t.primary_category,
      (mentionWeight.get(t.primary_category) ?? 0) + PRIMARY_WEIGHT);
    for (const sec of t.secondary_categories) {
      if (sec === t.primary_category) continue;
      mentionWeight.set(sec, (mentionWeight.get(sec) ?? 0) + SECONDARY_WEIGHT);
    }
  }
  let mostDiscussed = null;
  let mostDiscussedWeight = 0;
  for (const [id, w] of mentionWeight) {
    if (w > mostDiscussedWeight) {
      mostDiscussedWeight = w;
      mostDiscussed = id;
    }
  }

  // Most-improved: per-category, average severity first half vs second half
  // (oldest-first order). The strongest negative delta (= biggest drop in
  // severity) wins. Need at least 4 critiques total AND the winning
  // category needs at least 2 per half.
  let mostImproved = null;
  if (total >= 4) {
    const ordered = [...safe].sort((a, b) => a.created_ts - b.created_ts);
    const perCat = new Map();
    for (const cat of CRITIQUE_CATEGORIES) perCat.set(cat, []);
    for (const c of ordered) {
      const t = c.tags;
      if (!t) continue;
      perCat.get(t.primary_category).push(t.severity);
    }
    let bestDelta = 0;
    for (const [id, series] of perCat) {
      if (series.length < 4) continue;
      const half = Math.floor(series.length / 2);
      const firstAvg = mean(series.slice(0, half));
      const secondAvg = mean(series.slice(half));
      const delta = secondAvg - firstAvg;     // negative = improving
      if (delta < bestDelta) {
        bestDelta = delta;
        mostImproved = id;
      }
    }
  }

  // Current focus area: most-recent critique with a non-empty
  // focus_area_text. safe is newest-first per flattenCritiques.
  let focusArea = null;
  for (const c of safe) {
    const f = c.tags?.focus_area_text;
    if (typeof f === 'string' && f.trim().length > 0) {
      focusArea = f.trim();
      break;
    }
  }

  return {
    total_critiques: total,
    most_discussed_category: mostDiscussed,
    most_improved_category: mostImproved,
    current_focus_area: focusArea,
  };
}

/**
 * Build the v2 Themes section. Phase 1: returns up to 3 categories with
 * status chips + a deterministic placeholder synthesis ("N critiques
 * discussed {category}."). Phase 2 swaps the synthesis string for the
 * LLM-paraphrased version cached in KV.
 *
 * Inputs:
 *   - critiques: full flattenCritiques output (NOT windowed; themes look
 *     across the user's recent history).
 *   - limit: max themes to return (default 3 per proposal §4.3).
 *
 * Returns array of { category_id, status, synthesis, data_points }.
 *
 * A theme appears when the category has at least 2 critique mentions
 * (primary or secondary). Status is computed by determineStatus over
 * the category's severity series, using MIN_DATA_POINTS_GROWING (=2) as
 * the floor so themes can render with only a couple of critiques. When
 * the series is below that floor, status falls back to null and the
 * iOS chip renders neutrally.
 */
export function buildThemes(critiques, { limit = 3 } = {}) {
  const safe = Array.isArray(critiques) ? critiques : [];
  if (safe.length === 0) return [];
  // oldest-first for determineStatus
  const ordered = [...safe].sort((a, b) => a.created_ts - b.created_ts);

  const buckets = new Map();
  for (const cat of CRITIQUE_CATEGORIES) buckets.set(cat, []);
  for (const c of ordered) {
    const t = c.tags;
    if (!t) continue;
    buckets.get(t.primary_category).push(t.severity * PRIMARY_WEIGHT);
    for (const sec of t.secondary_categories) {
      if (sec === t.primary_category) continue;
      buckets.get(sec).push(t.severity * SECONDARY_WEIGHT);
    }
  }

  const themes = [];
  for (const [id, series] of buckets) {
    if (series.length < 2) continue;
    themes.push({
      category_id: id,
      status: determineStatus(series, MIN_DATA_POINTS_GROWING),
      synthesis: defaultThemeSynthesis(id, series.length),
      data_points: series.length,
    });
  }
  themes.sort((a, b) => b.data_points - a.data_points
    || (a.category_id < b.category_id ? -1 : 1));
  return themes.slice(0, limit);
}

// Phase 1 fallback synthesis text. Plain template. Phase 2 will replace
// this string with an LLM-paraphrased sentence pulled from the actual
// critique excerpts for that category.
function defaultThemeSynthesis(categoryId, dataPoints) {
  return `${dataPoints} recent critique${dataPoints === 1 ? '' : 's'} touched on ${categoryId}.`;
}

// =============================================================================
// v3 — tagged_critiques (Studio Wall + Skill Radar input)
// =============================================================================
//
// Returns every classified critique joined with its drawing's metadata
// (title / thumbnail / subject). The iOS Studio Wall renders this as a
// horizontal timeline of drawings with dots per critique tag; the
// Skill Radar aggregates by category to produce "then vs now"
// polygons.
//
// Differs from buildReel in three ways:
//   1. Includes EVERY classified critique, not just the most recent 10
//      — the wall is meant to scroll back through history.
//   2. Surfaces secondary_categories alongside primary, since the
//      wall renders a dot per tag (primary + secondaries).
//   3. Carries the raw severity number (1–5), not a paraphrase or
//      excerpt, since the wall encodes severity as dot brightness.
//
// Skips entries without classifier tags — those rows have no severity
// or category to plot, so they can't appear in the visualization.
// (The v2 reel still surfaces them so the user's general history
// isn't lost.)

export function buildTaggedCritiques(critiques, drawingsById) {
  if (!Array.isArray(critiques) || critiques.length === 0) return [];
  const sorted = [...critiques].sort((a, b) => a.created_ts - b.created_ts);
  const out = [];
  for (const c of sorted) {
    if (!c.tags || !c.drawing_id) continue;
    const drawing = drawingsById.get(c.drawing_id);
    if (!drawing) continue;
    const title = typeof drawing.title === 'string' && drawing.title.trim().length > 0
      ? drawing.title.trim()
      : null;
    const subject = typeof drawing.context?.subject === 'string'
      ? drawing.context.subject.trim()
      : null;
    out.push({
      critique_id: c.critique_id,
      drawing_id: c.drawing_id,
      drawing_title: title,
      drawing_subject: subject,
      thumbnail_path: drawing.storage_path ?? null,
      created_at: c.created_at,
      content_excerpt: extractExcerpt(c.content),
      primary_category: c.tags.primary_category,
      secondary_categories: Array.isArray(c.tags.secondary_categories)
        ? c.tags.secondary_categories
        : [],
      severity: c.tags.severity,
    });
  }
  return out;
}
