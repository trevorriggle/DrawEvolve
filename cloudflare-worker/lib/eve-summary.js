// Eve rolling per-conversation summary — Feature 2, Phase 2A.x.
//
// Runs OUT OF BAND, post-turn, via ctx.waitUntil from routes/eve.js. NEVER
// on the critical path of a send. Failures resolve to null and are
// swallowed by the caller's .catch() — see proposal §3 + R3 for the
// graceful-degradation contract.
//
// Goal: condense the part of a long Eve conversation that falls behind
// the raw-tail window into a single ~400-word memory paragraph so Eve
// retains continuity past `tailLimit` messages without paying linearly-
// growing input-token cost per turn. Hydration in routes/eve.js then
// reads `conversations.rolling_summary` and renders it into the system
// prompt as the CONVERSATION SO FAR block (see lib/eve-prompt.js).
//
// Hard rules (enforced by maybeRegenerateRollingSummary in routes/eve.js):
//   - Runs AFTER the assistant message is persisted. By the time this
//     fires, the user has already received their response.
//   - On ANY failure, generateRollingSummary resolves to null. Never
//     throws. Caller leaves rolling_summary at its prior value; next
//     post-turn regen tries again.
//   - Smaller, cheaper model than Eve herself. Pattern-matched to
//     lib/classifier.js for shape, reasoning_effort, and error handling.
//
// Why not on the critical path: the rolling-summary work is what makes
// per-send cost roughly constant. Re-introducing it as a synchronous
// fallback under failure conditions trades the (acceptable) degraded
// memory window for a (unacceptable) latency regression on the send
// path. The wrangler tail signal `[eve.summary] regen failed` is the
// operational lever; sustained failures are documented as a known
// graceful-degradation mode (proposal R3), not a silent bug.

// gpt-5.1 family ships gpt-5.1 only; the mini variant lives in the gpt-5
// family. Matches lib/classifier.js:22-29 (which absorbed the same
// "gpt-5.1-mini doesn't exist" lesson the hard way). The design proposal
// §4 said "gpt-5.1-mini" — that was wrong on the model name only; the
// pattern + intent are unchanged.
export const SUMMARY_MODEL = 'gpt-5-mini';

// Bump when SUMMARY_SYSTEM_PROMPT changes in a way that affects the
// summary's shape or interpretation. Persisted on the conversation row
// as rolling_summary_version (migration 0020). Lets the renderer in
// lib/eve-prompt.js branch on version if we ever need to support two
// formats concurrently during a rollout.
export const SUMMARY_PROMPT_VERSION = 1;

// Hard cap on output tokens. Soft target ~400 words; the model
// occasionally overshoots and we don't want runaway output ballooning
// the summary itself (which would defeat the constant-per-send-cost
// goal — the summary rides in every subsequent system prompt).
export const SUMMARY_MAX_OUTPUT_TOKENS = 800;

// 'minimal' is the cheapest gpt-5-mini reasoning level. Summary is
// condensation, not analysis — no reasoning headroom needed. Same value
// the classifier uses (lib/classifier.js:148). 'none' would be cheaper
// but is gpt-5.1-specific and gpt-5-mini 400s on it (CLAUDE.md gotcha
// #7 + classifier.js comment block).
const SUMMARY_REASONING_EFFORT = 'minimal';

export const SUMMARY_SYSTEM_PROMPT = `You are condensing a coaching conversation between an art teacher (Eve) and a student so Eve can pick up the conversation later without re-reading every turn.

Output ONE block of prose summarizing the conversation so far. Capture:
- What the student is working on (drawing, subject, phase of work).
- The coaching threads that have come up (techniques discussed, struggles named, breakthroughs).
- Anything the student has explicitly asked Eve to remember or come back to.
- Eve's running takes / through-lines.

Skip: pleasantries, throwaway clarifications, anything that doesn't carry forward.

Voice: third-person, factual. Not Eve's voice — this is a memory aid for Eve, not a turn she'd write. Around 400 words. Hard cap 800 tokens output.`;

/**
 * Generate (or regenerate) a rolling summary covering messages up to and
 * including `throughCreatedAt`.
 *
 * Inputs:
 *   - priorSummary: the previous rolling_summary text on the conversation,
 *     or null. When non-null, it's prepended as an assistant-role turn
 *     so the model picks up where the last summary left off rather than
 *     re-summarizing from scratch (cheaper + more stable across regens).
 *   - messages: chronological array of { role, content } strings for the
 *     UN-SUMMARIZED messages being folded into this regen (everything
 *     past the prior summary boundary, up through throughCreatedAt).
 *   - throughCreatedAt: ISO timestamp of the LAST message included.
 *     Round-trips on the return value so the caller can persist it onto
 *     the conversation row in the same PATCH.
 *
 * Returns { text, usage, throughCreatedAt, promptVersion } on success.
 * Returns null on any failure — never throws. The caller's .catch()
 * never sees an exception from this path.
 *
 * fetcher is dependency-injected so tests can stub the OpenAI call
 * without setting up env.OPENAI_API_KEY or hitting the network.
 */
export async function generateRollingSummary({
  env,
  priorSummary,
  messages,
  throughCreatedAt,
  fetcher = fetch,
}) {
  if (!Array.isArray(messages) || messages.length === 0) return null;
  if (typeof throughCreatedAt !== 'string' || throughCreatedAt.length === 0) return null;
  if (!env?.OPENAI_API_KEY) {
    console.error('[eve.summary] missing OPENAI_API_KEY');
    return null;
  }

  // Build the prompt: [system rules] + [optional prior summary as an
  // assistant turn so the model treats it as its own prior output] +
  // [the new messages to fold in] + [a final user instruction so the
  // model knows where input ends and output begins].
  const promptMessages = [
    { role: 'system', content: SUMMARY_SYSTEM_PROMPT },
  ];
  if (typeof priorSummary === 'string' && priorSummary.length > 0) {
    promptMessages.push({
      role: 'assistant',
      content: `PRIOR SUMMARY (your previous condensation of earlier turns — update and extend, do not duplicate):\n\n${priorSummary}`,
    });
  }
  for (const m of messages) {
    if (!m || typeof m.content !== 'string') continue;
    if (m.role !== 'user' && m.role !== 'assistant') continue;
    promptMessages.push({ role: m.role, content: m.content });
  }
  promptMessages.push({
    role: 'user',
    content: 'Produce the updated summary now. ~400 words, third-person, prose.',
  });

  try {
    const res = await fetcher('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      },
      body: JSON.stringify({
        model: SUMMARY_MODEL,
        messages: promptMessages,
        max_completion_tokens: SUMMARY_MAX_OUTPUT_TOKENS,
        reasoning_effort: SUMMARY_REASONING_EFFORT,
        // gpt-5 series only accepts the default temperature (1) and
        // rejects the `seed` field. Both omitted; same constraint the
        // classifier honors (lib/classifier.js:149-151).
      }),
    });
    if (!res.ok) {
      let body = '<unavailable>';
      try { body = await res.text(); } catch {}
      // Flatten whitespace so the whole error fits one tail line —
      // OpenAI's JSON error bodies span multiple lines and break grep
      // filters in wrangler tail. Same shape as classifier's error log.
      const flat = body.replace(/\s+/g, ' ').slice(0, 500);
      console.error('[eve.summary] non-ok status', res.status, 'body:', flat);
      return null;
    }
    const data = await res.json();
    const content = data?.choices?.[0]?.message?.content;
    if (typeof content !== 'string' || content.length === 0) {
      console.error('[eve.summary] empty content');
      return null;
    }
    return {
      text: content,
      usage: data.usage ?? null,
      throughCreatedAt,
      promptVersion: SUMMARY_PROMPT_VERSION,
    };
  } catch (err) {
    console.error('[eve.summary] threw', err?.message);
    return null;
  }
}
