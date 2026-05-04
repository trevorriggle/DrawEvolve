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

// Categories below this many data points show up in `warming_up` instead of
// `categories` — too few points to render a trend honestly. Status
// determination also requires this minimum (callers below the floor get
// status = null, which never reaches the response).
export const MIN_DATA_POINTS = 5;

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
        created_at: entry.created_at,
        created_ts: ts,
        tags: entry.tags,
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
 */
export function determineStatus(series) {
  if (!Array.isArray(series) || series.length < MIN_DATA_POINTS) return null;
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
 * Returns { categories, warmingUp, window }:
 *   - categories: { id, data_points, current_value, series, status } for
 *     each category with data_points >= MIN_DATA_POINTS, sorted by
 *     data_points DESC then id ASC for deterministic output.
 *   - warmingUp:  { id, data_points, needed } for categories below the
 *     threshold (data_points > 0).
 *   - window:     { critique_count, earliest_at, latest_at, span_days }.
 */
export function aggregateCategories(windowEntries) {
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
    if (dp >= MIN_DATA_POINTS) {
      categories.push({
        id,
        data_points: dp,
        current_value: series[series.length - 1],
        series,
        status: determineStatus(series),
      });
    } else {
      warmingUp.push({ id, data_points: dp, needed: MIN_DATA_POINTS });
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
