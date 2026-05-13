// Eve system-prompt + OpenAI-messages assembly.
//
// The system prompt has three load-bearing sections in fixed order:
//   1. EVE_PERSONA — who Eve is, what she's not (the critique voices)
//   2. EVE_PRODUCT_CONTEXT — what the app can and cannot do
//   3. CURRENT CONTEXT block — only when scope='drawing' AND a critique
//      was hydrated server-side. Frames the critique as shared history
//      the coach has already read.
//
// CURRENT CONTEXT sits LAST because the model's later context wins more
// often than not (same rationale as critique pipeline's iteration rules).
// Putting the critique last means the model has fresh recall of the
// specific drawing/critique when generating its first reply.
//
// The date line is intentionally omitted from CURRENT CONTEXT — relative
// recency doesn't sharpen the coaching, and the absolute ISO date in a
// prompt block reads as "tutorial bot pasting metadata" rather than
// "coach who's read this."

import { EVE_PERSONA, EVE_PERSONA_VERSION } from './eve-persona.js';
import { EVE_PRODUCT_CONTEXT, EVE_PRODUCT_CONTEXT_VERSION } from './eve-product-context.js';

export { EVE_PERSONA, EVE_PERSONA_VERSION };
export { EVE_PRODUCT_CONTEXT, EVE_PRODUCT_CONTEXT_VERSION };

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
 * When scope !== 'drawing' (or scope === 'drawing' but no critique was
 * hydrated — e.g. classifier-failed or pre-Phase-1 row), the CURRENT
 * CONTEXT block is omitted entirely and Eve falls back to her general
 * persona + product context posture.
 */
export function buildEveSystemPrompt({ scope, critique }) {
  const sections = [EVE_PERSONA, EVE_PRODUCT_CONTEXT];

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
"""`
    );
  }

  return sections.join('\n\n');
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
 */
export function buildEveMessages({ systemPrompt, history, userTurn }) {
  const messages = [{ role: 'system', content: systemPrompt }];

  for (const m of Array.isArray(history) ? history : []) {
    if (!m || typeof m.content !== 'string') continue;
    if (m.role === 'user' || m.role === 'assistant') {
      messages.push({ role: m.role, content: m.content });
    }
    // role === 'tool' deliberately skipped in 2A.
  }

  if (typeof userTurn === 'string' && userTurn.length > 0) {
    messages.push({ role: 'user', content: userTurn });
  }
  return messages;
}
