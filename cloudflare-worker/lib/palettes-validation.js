// Palettes validation helpers (Feature 5, Phase 3).
//
// The worker is the only writer to public.user_palettes via service_role,
// so validation here is the canonical correctness gate before any
// PostgREST write. iOS sends what the user typed; we validate, normalize,
// and persist. Same posture as routes/eve.js and routes/prompts.js —
// reject malformed input with HTTP 400 + a stable error code.
//
// Validators are pure functions returning { ok, value } or { ok, reason }.
// Caller maps reason → HTTP 400 with a human-readable message.

const HEX6_RE = /^#?[0-9a-fA-F]{6}$/;

// Soft cap: 30 colors per palette. We accept up to 100 to prevent abuse
// at the API surface (a malicious or runaway client shouldn't be able to
// post 10,000 colors to a single row), but iOS shows a warning at 30 and
// the UI nudges back. Server-side hard reject keeps storage bounded.
const COLORS_HARD_CAP = 100;
const NAME_MAX = 50;

/**
 * Normalize a single color string to canonical form: lowercased,
 * leading "#", 6 digits, no alpha. Returns the normalized string on
 * success, null on validation failure (caller maps to 400).
 */
export function normalizeHexColor(input) {
  if (typeof input !== 'string') return null;
  const trimmed = input.trim();
  if (!HEX6_RE.test(trimmed)) return null;
  const lower = trimmed.toLowerCase();
  return lower.startsWith('#') ? lower : `#${lower}`;
}

/**
 * Validate + normalize a palette name. Returns { ok, value } where
 * value is the trimmed, length-checked name. Empty / oversize / non-
 * string inputs are rejected.
 */
export function validatePaletteName(input) {
  if (typeof input !== 'string') {
    return { ok: false, reason: 'name must be a string' };
  }
  const trimmed = input.trim();
  if (trimmed.length === 0) {
    return { ok: false, reason: 'name must be non-empty' };
  }
  if (trimmed.length > NAME_MAX) {
    return { ok: false, reason: `name exceeds ${NAME_MAX} chars` };
  }
  return { ok: true, value: trimmed };
}

/**
 * Validate + normalize a colors array. Returns { ok, value } where
 * value is the array of normalized 6-digit hex strings. Rejects
 * non-arrays, oversize arrays, and any entry that isn't a valid
 * 6-digit hex.
 *
 * The check is "validate-and-reject" rather than "validate-and-narrow"
 * — silently dropping a bad color would surprise the user when they
 * see their palette saved with fewer colors than they typed.
 */
export function validateColors(input) {
  if (!Array.isArray(input)) {
    return { ok: false, reason: 'colors must be an array' };
  }
  if (input.length > COLORS_HARD_CAP) {
    return { ok: false, reason: `colors exceeds hard cap of ${COLORS_HARD_CAP}` };
  }
  const out = [];
  for (let i = 0; i < input.length; i += 1) {
    const normalized = normalizeHexColor(input[i]);
    if (!normalized) {
      return { ok: false, reason: `colors[${i}] is not a valid 6-digit hex` };
    }
    out.push(normalized);
  }
  return { ok: true, value: out };
}

/**
 * Full body validation for POST /v1/palettes and PATCH /v1/palettes/:id.
 * For PATCH, name and colors are both optional but at least one must be
 * present — caller passes `requireAtLeastOne: true` for PATCH and false
 * (or default) for POST where both are required.
 *
 * Returns { ok, value } where value is the (possibly partial) payload
 * to send to PostgREST.
 */
export function validatePalettePayload(body, { requireAtLeastOne = false } = {}) {
  if (!body || typeof body !== 'object') {
    return { ok: false, reason: 'request body must be an object' };
  }

  const out = {};
  let touched = 0;

  if ('name' in body) {
    const r = validatePaletteName(body.name);
    if (!r.ok) return r;
    out.name = r.value;
    touched += 1;
  } else if (!requireAtLeastOne) {
    return { ok: false, reason: 'name is required' };
  }

  if ('colors' in body) {
    const r = validateColors(body.colors);
    if (!r.ok) return r;
    out.colors = r.value;
    touched += 1;
  } else if (!requireAtLeastOne) {
    return { ok: false, reason: 'colors is required' };
  }

  if (requireAtLeastOne && touched === 0) {
    return { ok: false, reason: 'PATCH must include name and/or colors' };
  }

  return { ok: true, value: out };
}

export const PALETTES_VALIDATION_CONSTANTS = Object.freeze({
  HEX6_RE: HEX6_RE.source,
  COLORS_HARD_CAP,
  NAME_MAX,
});
