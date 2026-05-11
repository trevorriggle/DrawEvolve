// Critique classifier — Phase 1 of the "My Evolution" feature.
//
// Runs as a SECOND OpenAI call after the main critique returns successfully.
// Tags the critique with structured metadata (primary craft category, up to
// two secondaries, severity, focus-area headline, inferred subject, whether
// the Quick Take acknowledged progress) so a downstream Evolution tab can
// chart what the user has been working on, what's improving, and what
// recurs across drawings.
//
// Hard rules (enforced by the orchestrator in routes/feedback.js):
//   - Runs AFTER critique generation, BEFORE persistCritique.
//   - On ANY failure, classifyCritique resolves to null. Never throws.
//     The orchestrator persists with entry.tags = null in that case.
//   - Text-only — does NOT receive the image. The model classifies from
//     the critique Markdown, which already contains the SUBJECT VERIFICATION
//     verdict, the Focus Area heading, and the rest of the response.
//   - Smaller, cheaper model than the critique itself (CLASSIFIER_MODEL is
//     the single line to swap if the model changes).

import { CRITIQUE_CATEGORIES, SEVERITY_MIN, SEVERITY_MAX } from './taxonomy.js';

// Was `gpt-5.1-mini` — OpenAI 404s on that model name (the 5.1
// family ships gpt-5.1 only; the mini variant lives in the gpt-5
// family). Switched to `gpt-5-mini` on 2026-05-11 after wrangler
// tail confirmed every classifier call was 404'ing silently and
// every critique's `tags` field was being left null at ingest time.
// CLAUDE.md noted "gpt-5.1-mini for classifier" — that was aspirational
// rather than verified at the time the doc was written.
export const CLASSIFIER_MODEL = 'gpt-5-mini';
export const CLASSIFIER_VERSION = 'v1';

// Bumped whenever we change the prompt's INSTRUCTIONS in a way that affects
// tag values; lets future analytics queries ignore tags from older versions
// when comparing apples-to-apples. The schema-shape itself is also versioned
// here — a structural change is a breaking change for downstream consumers
// and they will need to handle the older shape until backfill.
//
// Update CLASSIFIER_VERSION above (not in the prompt text) when the meaning
// of an output field shifts.

export const CLASSIFIER_SYSTEM_PROMPT = [
  "You tag art critiques with structured metadata for trend analysis.",
  "You are given the full Markdown text of a critique. Identify:",
  "- the primary craft category the Focus Area addresses",
  "- up to 2 secondary categories also mentioned (excluding primary)",
  "- severity 1-5 of the issue raised in the Focus Area, where 1 is a minor refinement and 5 is a foundational problem",
  "- the verbatim Focus Area heading text (the part after 'Focus Area:')",
  "- the subject of the drawing as a short noun phrase",
  "- whether the Quick Take acknowledges progress on a prior critique's Focus Area",
  "If the critique is a SUBJECT VERIFICATION failure (canonical feature missing or stated-subject mismatch), use 'subject_match' as the primary category regardless of which craft area is also mentioned.",
  "If no category fits, use 'general'. Do not invent categories outside the allowed enum.",
].join('\n');

const CLASSIFIER_JSON_SCHEMA = {
  name: 'critique_tags',
  strict: true,
  schema: {
    type: 'object',
    additionalProperties: false,
    required: [
      'primary_category',
      'secondary_categories',
      'severity',
      'focus_area_text',
      'subject_inferred',
      'acknowledged_progress',
    ],
    properties: {
      primary_category: { type: 'string', enum: CRITIQUE_CATEGORIES },
      secondary_categories: {
        type: 'array',
        items: { type: 'string', enum: CRITIQUE_CATEGORIES },
        maxItems: 2,
      },
      severity: { type: 'integer', minimum: SEVERITY_MIN, maximum: SEVERITY_MAX },
      // Nullable per OpenAI strict-mode convention: type as an array
      // including 'null'. The model emits null when the field is absent
      // (e.g. SUBJECT VERIFICATION failure with no Focus Area section).
      focus_area_text: { type: ['string', 'null'], maxLength: 240 },
      subject_inferred: { type: ['string', 'null'], maxLength: 60 },
      acknowledged_progress: { type: 'boolean' },
    },
  },
};

const FOCUS_AREA_TEXT_MAX = 240;
const SUBJECT_INFERRED_MAX = 60;

// Belt-and-suspenders validation for the parsed JSON. The strict json_schema
// constraint should already enforce this on the OpenAI side, but a malformed
// response (provider hiccup, schema drift) must not flow into Postgres.
function validateTags(t) {
  if (!t || typeof t !== 'object' || Array.isArray(t)) return false;
  if (!CRITIQUE_CATEGORIES.includes(t.primary_category)) return false;
  if (!Array.isArray(t.secondary_categories) || t.secondary_categories.length > 2) return false;
  for (const c of t.secondary_categories) {
    if (!CRITIQUE_CATEGORIES.includes(c)) return false;
    if (c === t.primary_category) return false;
  }
  if (!Number.isInteger(t.severity) || t.severity < SEVERITY_MIN || t.severity > SEVERITY_MAX) return false;
  if (t.focus_area_text !== null) {
    if (typeof t.focus_area_text !== 'string') return false;
    if (t.focus_area_text.length > FOCUS_AREA_TEXT_MAX) return false;
  }
  if (t.subject_inferred !== null) {
    if (typeof t.subject_inferred !== 'string') return false;
    if (t.subject_inferred.length > SUBJECT_INFERRED_MAX) return false;
  }
  if (typeof t.acknowledged_progress !== 'boolean') return false;
  return true;
}

export async function classifyCritique({ feedback, env, fetcher = fetch }) {
  if (typeof feedback !== 'string' || feedback.length === 0) return null;
  if (!env?.OPENAI_API_KEY) {
    console.error('[classifier] missing OPENAI_API_KEY');
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
        model: CLASSIFIER_MODEL,
        messages: [
          { role: 'system', content: CLASSIFIER_SYSTEM_PROMPT },
          { role: 'user', content: feedback },
        ],
        // gpt-5 series is a reasoning model — it spends tokens on
        // internal chain-of-thought BEFORE producing visible output.
        // max_completion_tokens has to cover BOTH reasoning + output.
        // 300 was enough for gpt-4o (non-reasoning) but starved gpt-5-mini
        // → response.content came back empty every time. Bumped to 2000.
        max_completion_tokens: 2000,
        // gpt-5-mini accepts: 'minimal' | 'low' | 'medium' | 'high' as
        // a FLAT field on chat/completions. (gpt-5.1 takes 'none' —
        // different model, different allowed values. CLAUDE.md gotcha
        // #7 documented 'none' for gpt-5.1 and it doesn't carry over;
        // OpenAI 400s on 'none' for gpt-5-mini.) 'minimal' tells the
        // model "do as little reasoning as possible" — perfect for a
        // classifier whose job is pure JSON schema fill-in. The
        // nested `reasoning: { effort }` shape is the /v1/responses
        // endpoint; flat is the chat/completions form.
        reasoning_effort: 'minimal',
        // gpt-5 series only accepts the default temperature (1) and
        // rejects the `seed` field. Both omitted; determinism is
        // shoulderable since json_schema constrains the response shape.
        response_format: { type: 'json_schema', json_schema: CLASSIFIER_JSON_SCHEMA },
      }),
    });
    if (!res.ok) {
      let body = '<unavailable>';
      try { body = await res.text(); } catch {}
      // Flatten whitespace so the whole error fits one tail line —
      // OpenAI's JSON error bodies span 4-5 lines and break grep
      // filters in wrangler tail.
      const flat = body.replace(/\s+/g, ' ').slice(0, 500);
      console.error('[classifier] non-ok status', res.status, 'body:', flat);
      return null;
    }
    const data = await res.json();
    const content = data?.choices?.[0]?.message?.content;
    if (typeof content !== 'string' || content.length === 0) {
      console.error('[classifier] empty content');
      return null;
    }
    let parsed;
    try {
      parsed = JSON.parse(content);
    } catch (err) {
      console.error('[classifier] json parse failed', err?.message);
      return null;
    }
    if (!validateTags(parsed)) {
      console.error('[classifier] schema validation failed');
      return null;
    }
    return {
      primary_category: parsed.primary_category,
      secondary_categories: parsed.secondary_categories,
      severity: parsed.severity,
      focus_area_text: parsed.focus_area_text,
      subject_inferred: parsed.subject_inferred,
      acknowledged_progress: parsed.acknowledged_progress,
      classifier_version: CLASSIFIER_VERSION,
    };
  } catch (err) {
    console.error('[classifier] threw', err?.message);
    return null;
  }
}
