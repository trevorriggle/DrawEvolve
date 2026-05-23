// Eve system-prompt + OpenAI-messages assembly.
//
// The system prompt has five load-bearing sections in fixed order:
//   1. EVE_PERSONA — who Eve is, what she's not (the critique voices)
//   2. EVE_PRODUCT_CONTEXT — what the app can and cannot do
//   3. COACHING CONTEXT block — preloaded portfolio data (drawings +
//      critique summaries). Always present when coachingContext is
//      non-empty; lets Eve coach across the user's body of work without
//      tool calls. NEVER includes full critique bodies, only summaries.
//   4. CURRENT CONTEXT block — only when scope='drawing' AND a critique
//      was hydrated server-side. Frames the critique as shared history
//      the coach has already read. INCLUDES the full critique body —
//      this is the conversation anchor and needs full nuance for
//      follow-up questions.
//   5. CURRENT CANVAS block — only when the student attached their live
//      canvas this turn. Sits last so the per-turn override of the
//      "you haven't seen the drawings" rule is the freshest instruction
//      in model recall. Also defends Eve persona against slipping into
//      critique register just because an image is attached.
//
// COACHING CONTEXT sits BEFORE CURRENT CONTEXT so the current critique
// stays the freshest thing in the model's recall. CURRENT CANVAS sits
// after both for the same reason.
//
// The date line is intentionally omitted from CURRENT CONTEXT — relative
// recency doesn't sharpen the coaching, and the absolute ISO date in a
// prompt block reads as "tutorial bot pasting metadata" rather than
// "coach who's read this."

import { EVE_PERSONA, EVE_PERSONA_VERSION } from './eve-persona.js';
import { EVE_PRODUCT_CONTEXT, EVE_PRODUCT_CONTEXT_VERSION } from './eve-product-context.js';

export { EVE_PERSONA, EVE_PERSONA_VERSION };
export { EVE_PRODUCT_CONTEXT, EVE_PRODUCT_CONTEXT_VERSION };

// Bumped when the CURRENT CANVAS block copy changes. Not persisted on
// the message row today (assistant rows only track persona + product
// context versions), but exported for future telemetry if Eve quality
// dips correlate to canvas-attached turns specifically.
export const EVE_CANVAS_BLOCK_VERSION = 1;

/**
 * Returns the full system prompt Eve sees on every turn of a conversation.
 *
 * `critique` shape (server-hydrated from drawings.critique_history when
 * scope='drawing'):
 *   {
 *     drawing_title: string | null,
 *     drawing_subject: string | null,
 *     sequence_number: number,
 *     content: string (markdown)
 *   }
 *
 * `coachingContext` shape (Phase 2A.1, fetched fresh per turn from
 * lib/supabase.js fetchCoachingContext):
 *   {
 *     drawings: [{ drawing_id, title, subject, relative_time,
 *                  total_critiques,
 *                  last_critique: { relative_time, focus_area_text,
 *                                   primary_category, severity } | null }],
 *     summaries: [{ drawing_title, drawing_subject, relative_time,
 *                   focus_area_text, primary_category, severity,
 *                   summary_bullets: [string] }]
 *   }
 *
 * The COACHING CONTEXT block renders only when coachingContext is present
 * AND has at least one drawing or one summary. New users with no drawings
 * get just the persona + product context — Eve introduces herself rather
 * than referencing an empty portfolio.
 *
 * When scope !== 'drawing' (or scope === 'drawing' but no critique was
 * hydrated), the CURRENT CONTEXT block is omitted; COACHING CONTEXT
 * remains.
 */
export function buildEveSystemPrompt({ scope, critique, coachingContext, attachedCanvas } = {}) {
  const sections = [EVE_PERSONA, EVE_PRODUCT_CONTEXT];

  const coachingBlock = renderCoachingContextBlock(coachingContext);
  if (coachingBlock) sections.push(coachingBlock);

  if (scope === 'drawing' && critique && typeof critique.content === 'string') {
    const title = (typeof critique.drawing_title === 'string' && critique.drawing_title.trim())
      ? critique.drawing_title.trim()
      : 'Untitled';
    const subject = (typeof critique.drawing_subject === 'string' && critique.drawing_subject.trim())
      ? critique.drawing_subject.trim()
      : 'not specified';
    const seq = typeof critique.sequence_number === 'number' ? critique.sequence_number : '?';

    sections.push(
`CURRENT CONTEXT:
The student tapped "Ask Eve" while looking at a specific critique on a specific drawing. Here is that critique, in full. Treat it as shared context — you've read it. Don't repeat it back at them verbatim. Reference it the way a coach would reference a recent session: "the value-grouping issue we talked about," not "in critique #${seq} you said…"

Drawing title: "${title}"
Subject: ${subject}
Critique sequence number: ${seq}

Critique text:
"""
${critique.content}
"""

If a follow-up question needs visual confirmation — the student asks about a specific area, a color choice, the proportions of a particular shape, or anything you can't reasonably answer from the critique text alone — don't guess and don't claim to see the drawing. Ask them to tap the "Show Eve my canvas" pill above the input bar so you can see what they're working on now. You only see images when the student explicitly shares one this turn; the critique text above is the only thing you have on the drawing's appearance.`
    );
  }

  if (attachedCanvas === true) {
    sections.push(CURRENT_CANVAS_BLOCK);
  }

  return sections.join('\n\n');
}

// =============================================================================
// CURRENT CANVAS block (per-turn override)
// =============================================================================
//
// Spliced ONLY when the student attaches their in-progress canvas this turn.
// Three load-bearing jobs:
//   1. Override the "you haven't seen the actual drawings" guardrail from
//      the coaching block — but tightly scoped to "this turn only" so Eve
//      doesn't start claiming to have seen other drawings later.
//   2. Defend Eve persona against the model's instinct to switch into
//      critique register when it sees an image. The whole point of the
//      Ask-Eve surface is that it's NOT the formal critique flow.
//   3. Keep the response focused on what the student actually typed,
//      not a free-form tour of everything Eve sees.
//
// Sits after CURRENT CONTEXT so the override is the freshest instruction
// in model recall. Keep this terse — every line is fighting against a
// strong "you saw an image, perform critique" default.

const CURRENT_CANVAS_BLOCK =
`CURRENT CANVAS (just for this turn — the student attached their in-progress canvas):
You can see what they're working on right now. The "you haven't seen the actual drawings" rule from above is overridden FOR THIS TURN ONLY — you may speak to what you see on the canvas they just shared.

Stay in your normal voice. This is not a critique request. You're glancing over their shoulder, not delivering an assessment. No numbered lists, no category headers, no "here are three things to fix" structure. Conversational length, conversational shape. React the way a coach who happens to be nearby would: one observation, maybe a question back, the casual register of mid-session help.

The student typed something specific to go with this canvas. Focus on what they actually asked. Don't volunteer a tour of everything you notice — they didn't ask for a full read-out.`;

// =============================================================================
// COACHING CONTEXT renderer
// =============================================================================
//
// Renders the YOUR DRAWING JOURNEY block from a hydrated coachingContext.
// Returns null when no drawings AND no summaries exist (block omitted from
// the system prompt entirely — Eve falls back to persona + product context).
//
// The guardrail copy at the bottom of the block ("never imply you've seen
// the actual drawings") is load-bearing — it's Eve's own audit
// recommendation, verbatim intent. Without it she will at some point
// describe a drawing she has not, in fact, seen.

export function renderCoachingContextBlock(coachingContext) {
  if (!coachingContext || typeof coachingContext !== 'object') return null;
  const drawings = Array.isArray(coachingContext.drawings) ? coachingContext.drawings : [];
  const summaries = Array.isArray(coachingContext.summaries) ? coachingContext.summaries : [];
  if (drawings.length === 0 && summaries.length === 0) return null;

  const parts = [
    'YOUR DRAWING JOURNEY (preloaded — reference this naturally, don\'t quote it verbatim):',
  ];

  if (drawings.length > 0) {
    parts.push('You\'re working on these drawings (newest activity first):');
    parts.push(drawings.map(renderCoachingDrawingRow).join('\n'));
  }

  if (summaries.length > 0) {
    parts.push('Recent critique summaries (newest first):');
    parts.push(summaries.map(renderCoachingSummaryRow).join('\n\n'));
  }

  parts.push(
`You may reference this data naturally — "your Forest at Dusk has been getting better on values over the last week" — but never quote it as a list, and never imply you've seen the actual drawings. You only know what the critiques said. If asked about the drawing itself ("did the eye look better in the new version?"), redirect: "I haven't seen it — what did the critique say?"

You can say things like: "based on what the critique called out, you might want to focus on..." or "the value-grouping issue from your last Forest at Dusk critique would apply here too." That's coaching — connecting what's known across their work.`
  );

  return parts.join('\n\n');
}

function renderCoachingDrawingRow(row) {
  const title = (typeof row?.title === 'string' && row.title.trim()) ? row.title.trim() : 'Untitled';
  const subjectRaw = typeof row?.subject === 'string' ? row.subject.trim() : '';
  const subjectPart = subjectRaw ? `${subjectRaw}, ` : '';
  const when = typeof row?.relative_time === 'string' && row.relative_time
    ? row.relative_time
    : 'recently';
  const total = typeof row?.total_critiques === 'number' ? row.total_critiques : 0;
  const critiqueWord = total === 1 ? 'critique' : 'critiques';

  if (total === 0 || !row?.last_critique) {
    return `- "${title}" (${subjectPart}${when}, ${total} ${critiqueWord} — no critique yet)`;
  }

  const last = row.last_critique;
  const lastWhen = typeof last.relative_time === 'string' && last.relative_time
    ? last.relative_time
    : 'recently';
  const focus = (typeof last.focus_area_text === 'string' && last.focus_area_text.trim())
    ? last.focus_area_text.trim()
    : (typeof last.primary_category === 'string' && last.primary_category)
      ? last.primary_category
      : 'general critique';

  return `- "${title}" (${subjectPart}${when}, ${total} ${critiqueWord} — last ${lastWhen}, ${focus})`;
}

function renderCoachingSummaryRow(row) {
  const title = (typeof row?.drawing_title === 'string' && row.drawing_title.trim())
    ? row.drawing_title.trim()
    : 'Untitled';
  const when = typeof row?.relative_time === 'string' && row.relative_time
    ? row.relative_time
    : 'recently';
  const bullets = Array.isArray(row?.summary_bullets) ? row.summary_bullets : [];
  const bulletLines = bullets.map((b) => `- ${b}`).join('\n');
  const compositionLine = renderCompositionSummaryLine(row?.composition_findings);
  const tail = compositionLine ? `\n${compositionLine}` : '';
  return `[${when} — "${title}"]\n${bulletLines}${tail}`;
}

/**
 * One-line composition-findings summary for the coaching context
 * block. Designed to be lightweight — the heavyweight limitation
 * framing lives in the per-critique system prompt
 * (renderCompositionFindingsBlock in lib/prompt.js), not here. This
 * function just gives Eve enough context to acknowledge composition
 * findings exist across the user's history without restating the
 * caveats every row.
 *
 * Returns null if there are no findings to summarize.
 *
 * Eve must not cite saliency findings as authoritative — that
 * constraint is set elsewhere in the system prompt (Eve persona
 * + the per-critique block). This summary is informational.
 */
function renderCompositionSummaryLine(findings) {
  if (!findings || typeof findings !== 'object') return null;

  if (typeof findings.readiness_reason === 'string' && findings.readiness_reason) {
    return '- Composition: on-device saliency was refused by the readiness gate (canvas was too sparse or lacked value structure).';
  }

  const intent = findings.intent_marker;
  const hasIntent = intent && typeof intent === 'object'
    && typeof intent.x === 'number' && typeof intent.y === 'number';
  const confidenceLow = findings.confidence_low === true;

  if (confidenceLow) {
    const intentPart = hasIntent
      ? ' Student had marked an intended focal point.'
      : '';
    return `- Composition: saliency findings were low-confidence (Vision couldn't read the drawing clearly).${intentPart}`;
  }

  const hotspots = Array.isArray(findings.attention_hotspots) ? findings.attention_hotspots : [];
  if (hotspots.length === 0 && !hasIntent) return null;

  const parts = [];
  if (hotspots.length > 0) {
    const tentativeCount = hotspots.filter((h) => h && typeof h.confidence === 'number' && h.confidence < 0.5).length;
    const tentativeNote = tentativeCount > 0 ? ` (${tentativeCount} tentative)` : '';
    parts.push(`top-${hotspots.length} attention hotspots recorded${tentativeNote}`);
  }
  if (hasIntent) {
    parts.push(`student marked intended focal point at ${(intent.x * 100).toFixed(0)}% across, ${(intent.y * 100).toFixed(0)}% down`);
  } else {
    parts.push('no intended focal point marked');
  }
  return `- Composition: ${parts.join('; ')}.`;
}

/**
 * Builds the OpenAI messages array for a single turn.
 *   - One system message (assembled by buildEveSystemPrompt above)
 *   - All prior turns in this conversation, oldest first
 *   - The new user turn at the end
 *
 * `history` is what the worker pulled from conversation_messages
 * (oldest first). `userTurn` is the just-arrived user message text.
 * Messages with role='tool' are skipped in 2A — no tools yet, but the
 * role enum is already in the schema so 2C can add them without a
 * migration. Non-string content / missing fields are silently dropped
 * so a malformed row never breaks the request path.
 *
 * When `attachedImageB64` is provided, the new user turn becomes a
 * multimodal content array (text part + image_url part). History
 * entries stay text-only — past-turn images are not re-attached on
 * subsequent turns. Eve's persisted history shows a `[canvas attached
 * this turn]` marker on the user row instead, which is enough for her
 * to recall "the student showed me something earlier" without
 * replaying expensive vision tokens.
 *
 * Image detail level is left unset, matching the critique flow's
 * default ('auto') — OpenAI picks resolution based on image size.
 */
export function buildEveMessages({ systemPrompt, history, userTurn, attachedImageB64 } = {}) {
  const messages = [{ role: 'system', content: systemPrompt }];

  for (const m of Array.isArray(history) ? history : []) {
    if (!m || typeof m.content !== 'string') continue;
    if (m.role === 'user' || m.role === 'assistant') {
      messages.push({ role: m.role, content: m.content });
    }
    // role === 'tool' deliberately skipped in 2A.
  }

  if (typeof userTurn === 'string' && userTurn.length > 0) {
    if (typeof attachedImageB64 === 'string' && attachedImageB64.length > 0) {
      messages.push({
        role: 'user',
        content: [
          { type: 'text', text: userTurn },
          { type: 'image_url', image_url: { url: `data:image/jpeg;base64,${attachedImageB64}` } },
        ],
      });
    } else {
      messages.push({ role: 'user', content: userTurn });
    }
  }
  return messages;
}
