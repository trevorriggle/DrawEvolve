// Critique annotations — "ghost layer" feature (markup ghost layers).
//
// Runs as an additional OpenAI call after the main critique returns
// successfully, ALONGSIDE the tag classifier. Grounds the critique's
// concrete, localizable feedback onto the drawing itself: each annotation
// is a normalized region (x, y, radius in 0..1 image space) plus a short
// label and the critique excerpt it grounds. iOS renders these as
// toggleable ghost markers over the canvas.
//
// Hard rules (mirroring lib/classifier.js — enforced by the orchestrator
// in routes/feedback.js):
//   - Runs AFTER critique generation, BEFORE persistCritique, so the
//     annotations ride along in the same critique_history append.
//   - On ANY failure (HTTP error, malformed JSON, schema violation,
//     timeout), generateAnnotations resolves to null. Never throws. The
//     entry persists with annotations = null and the critique is
//     unaffected — ghost markers are garnish, not the meal.
//   - Vision call: unlike the classifier this one DOES receive the image
//     (grounding needs to see the drawing). Same mini model, minimal
//     reasoning, strict json_schema output.
//   - Confidence-filtered: the model self-reports confidence per marker
//     and we drop anything below MIN_CONFIDENCE. A missing marker reads
//     fine; a marker pointing at the wrong region reads broken. Zero
//     surviving markers ⇒ null (iOS treats null and absent identically).

export const ANNOTATOR_MODEL = 'gpt-5-mini';
export const ANNOTATOR_VERSION = 'v1';

// Markers below this self-reported confidence are dropped server-side.
export const MIN_ANNOTATION_CONFIDENCE = 0.5;
// Hard cap on markers per critique — more than this reads as clutter,
// and the prompt asks for at most 4 (5th slot is headroom for ties).
export const MAX_ANNOTATIONS = 5;

export const ANNOTATOR_SYSTEM_PROMPT = [
  'You ground an art critique onto the drawing it critiques.',
  'You are given the drawing image and the full Markdown text of its critique.',
  'Emit up to 4 annotations marking the SPECIFIC regions of the image the critique references.',
  'Coordinates are normalized to the image: x runs left→right 0..1, y runs top→bottom 0..1.',
  'radius is the normalized radius of a circle generously covering the referenced region (0.03 minimum, 0.35 maximum).',
  'label: a short actionable phrase tied to the critique point (max 60 chars), e.g. "Deepen the shadow here".',
  'excerpt: a short quote or close paraphrase of the critique sentence this marker grounds (max 200 chars).',
  'confidence: 0..1 — how certain you are that this region is what the critique refers to.',
  'Only annotate concrete, localizable feedback. Skip global comments (overall composition, palette-wide notes, general encouragement).',
  'Prefer fewer, more certain markers. Return an empty annotations array rather than guessing.',
].join('\n');

const ANNOTATOR_JSON_SCHEMA = {
  name: 'critique_annotations',
  strict: true,
  schema: {
    type: 'object',
    additionalProperties: false,
    required: ['annotations'],
    properties: {
      annotations: {
        type: 'array',
        maxItems: MAX_ANNOTATIONS,
        items: {
          type: 'object',
          additionalProperties: false,
          required: ['x', 'y', 'radius', 'label', 'excerpt', 'confidence'],
          properties: {
            x: { type: 'number', minimum: 0, maximum: 1 },
            y: { type: 'number', minimum: 0, maximum: 1 },
            radius: { type: 'number', minimum: 0.03, maximum: 0.35 },
            label: { type: 'string', maxLength: 60 },
            excerpt: { type: ['string', 'null'], maxLength: 200 },
            confidence: { type: 'number', minimum: 0, maximum: 1 },
          },
        },
      },
    },
  },
};

const LABEL_MAX = 60;
const EXCERPT_MAX = 200;

// Belt-and-suspenders validation for one parsed annotation. The strict
// json_schema constraint should already enforce this on the OpenAI side,
// but a malformed response must not flow into Postgres (same defensive
// posture as validateTags in classifier.js).
export function validateAnnotation(a) {
  if (!a || typeof a !== 'object' || Array.isArray(a)) return false;
  for (const key of ['x', 'y', 'confidence']) {
    if (typeof a[key] !== 'number' || !Number.isFinite(a[key])) return false;
    if (a[key] < 0 || a[key] > 1) return false;
  }
  if (typeof a.radius !== 'number' || !Number.isFinite(a.radius)) return false;
  if (a.radius < 0.03 || a.radius > 0.35) return false;
  if (typeof a.label !== 'string' || a.label.length === 0 || a.label.length > LABEL_MAX) return false;
  if (a.excerpt !== null) {
    if (typeof a.excerpt !== 'string') return false;
    if (a.excerpt.length > EXCERPT_MAX) return false;
  }
  return true;
}

/// Ground the critique onto the drawing. Resolves to an array of
/// validated, confidence-filtered annotations (1..MAX_ANNOTATIONS items)
/// or null — never throws, never returns an empty array.
export async function generateAnnotations({ imageBase64, feedback, env, fetcher = fetch }) {
  if (typeof feedback !== 'string' || feedback.length === 0) return null;
  if (typeof imageBase64 !== 'string' || imageBase64.length === 0) return null;
  if (!env?.OPENAI_API_KEY) {
    console.error('[annotator] missing OPENAI_API_KEY');
    return null;
  }

  try {
    const res = await fetcher('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      },
      body: JSON.stringify({
        model: ANNOTATOR_MODEL,
        messages: [
          { role: 'system', content: ANNOTATOR_SYSTEM_PROMPT },
          {
            role: 'user',
            content: [
              { type: 'image_url', image_url: { url: `data:image/jpeg;base64,${imageBase64}` } },
              { type: 'text', text: feedback },
            ],
          },
        ],
        // gpt-5 series reasoning-token budget — see classifier.js for the
        // 2000-token rationale (covers reasoning + output; 300 starved it).
        max_completion_tokens: 2000,
        // 'minimal' is the gpt-5-mini flat chat/completions value (NOT
        // 'none' — that's gpt-5.1's vocabulary; see CLAUDE.md gotcha #7
        // and the classifier.js comment).
        reasoning_effort: 'minimal',
        response_format: { type: 'json_schema', json_schema: ANNOTATOR_JSON_SCHEMA },
      }),
    });
    if (!res.ok) {
      let body = '<unavailable>';
      try { body = await res.text(); } catch {}
      const flat = body.replace(/\s+/g, ' ').slice(0, 500);
      console.error('[annotator] non-ok status', res.status, 'body:', flat);
      return null;
    }
    const data = await res.json();
    const content = data?.choices?.[0]?.message?.content;
    if (typeof content !== 'string' || content.length === 0) {
      console.error('[annotator] empty content');
      return null;
    }
    let parsed;
    try {
      parsed = JSON.parse(content);
    } catch (err) {
      console.error('[annotator] json parse failed', err?.message);
      return null;
    }
    if (!parsed || !Array.isArray(parsed.annotations)) {
      console.error('[annotator] schema validation failed (no annotations array)');
      return null;
    }
    const kept = parsed.annotations
      .filter(validateAnnotation)
      .filter((a) => a.confidence >= MIN_ANNOTATION_CONFIDENCE)
      .slice(0, MAX_ANNOTATIONS)
      .map((a) => ({
        x: a.x,
        y: a.y,
        radius: a.radius,
        label: a.label,
        excerpt: a.excerpt,
        confidence: a.confidence,
      }));
    if (kept.length === 0) return null;
    return kept;
  } catch (err) {
    console.error('[annotator] threw', err?.message);
    return null;
  }
}
