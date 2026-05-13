// Recommendations response validation (Phase 4).
//
// Two pieces:
//   1. RECOMMENDATIONS_SCHEMA — the json_schema we hand to OpenAI's
//      `response_format` so the model output is constrained at
//      generation time.
//   2. validateRecommendations(payload) — defense-in-depth: re-checks
//      the parsed payload server-side before returning to iOS. Even
//      with strict schema mode, we still verify count, lengths, and
//      enum membership in case OpenAI ever loosens schema enforcement
//      or returns a malformed wrapper.
//
// On any validation failure the caller responds 502 (the model gave
// us something we can't trust) rather than passing through to iOS.
// Better to surface a clear error than show a broken card stack.

export const RECOMMENDATIONS_SCHEMA = {
  name: 'recommendations',
  strict: true,
  schema: {
    type: 'object',
    additionalProperties: false,
    properties: {
      recommendations: {
        type: 'array',
        minItems: 5,
        maxItems: 5,
        items: {
          type: 'object',
          additionalProperties: false,
          properties: {
            subject: { type: 'string', minLength: 3, maxLength: 100 },
            rationale: { type: 'string', minLength: 10, maxLength: 200 },
            focus_area: { type: 'string', maxLength: 50 },
            recommendation_type: {
              type: 'string',
              enum: ['skill_targeting', 'variety', 'stretch'],
            },
          },
          required: ['subject', 'rationale', 'focus_area', 'recommendation_type'],
        },
      },
    },
    required: ['recommendations'],
  },
};

const ALLOWED_TYPES = new Set(['skill_targeting', 'variety', 'stretch']);
const SUBJECT_MIN = 3;
const SUBJECT_MAX = 100;
const RATIONALE_MIN = 10;
const RATIONALE_MAX = 200;
const FOCUS_AREA_MAX = 50;
const REQUIRED_COUNT = 5;

/**
 * Validate the recommendations payload server-side. Returns
 * { ok: true, value } on success, { ok: false, reason } otherwise.
 * `value` is the recommendations array, ready to return.
 *
 * Trims string fields defensively — if the model emits trailing
 * whitespace the iOS layer shouldn't see it. focus_area may be an
 * empty string (rare), in which case it stays empty rather than
 * being filled in with a placeholder.
 */
export function validateRecommendations(payload) {
  if (!payload || typeof payload !== 'object') {
    return { ok: false, reason: 'payload is not an object' };
  }
  const recs = payload.recommendations;
  if (!Array.isArray(recs)) {
    return { ok: false, reason: 'recommendations is not an array' };
  }
  if (recs.length !== REQUIRED_COUNT) {
    return { ok: false, reason: `expected ${REQUIRED_COUNT} recommendations, got ${recs.length}` };
  }

  const out = [];
  for (let i = 0; i < recs.length; i += 1) {
    const r = recs[i];
    if (!r || typeof r !== 'object') {
      return { ok: false, reason: `recommendation ${i} is not an object` };
    }
    const subject = typeof r.subject === 'string' ? r.subject.trim() : '';
    if (subject.length < SUBJECT_MIN || subject.length > SUBJECT_MAX) {
      return { ok: false, reason: `recommendation ${i} subject length out of bounds` };
    }
    const rationale = typeof r.rationale === 'string' ? r.rationale.trim() : '';
    if (rationale.length < RATIONALE_MIN || rationale.length > RATIONALE_MAX) {
      return { ok: false, reason: `recommendation ${i} rationale length out of bounds` };
    }
    const focusArea = typeof r.focus_area === 'string' ? r.focus_area.trim() : '';
    if (focusArea.length > FOCUS_AREA_MAX) {
      return { ok: false, reason: `recommendation ${i} focus_area too long` };
    }
    const type = r.recommendation_type;
    if (typeof type !== 'string' || !ALLOWED_TYPES.has(type)) {
      return { ok: false, reason: `recommendation ${i} recommendation_type not in enum` };
    }

    out.push({
      subject,
      rationale,
      focus_area: focusArea,
      recommendation_type: type,
    });
  }

  return { ok: true, value: out };
}
