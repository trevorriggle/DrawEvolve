// Recommendations system prompt + user message builder (Phase 4).
//
// Returns 5 subject recommendations tailored to the user's drawing
// history + critique focus areas. Reuses the same data layer as Eve's
// coaching context (lib/supabase.js → fetchCoachingContext) but renders
// a leaner prompt-time framing: no Eve-specific guardrails (we're
// generating new subjects, not coaching about existing critiques), no
// "never imply you've seen the drawings" copy.
//
// Bump RECOMMENDATIONS_PROMPT_VERSION on any change to the system
// prompt below — same telemetry pattern as Eve's persona/product
// context versions, ready to add to persisted analytics later if
// recommendations ever get logged per-user.

export const RECOMMENDATIONS_PROMPT_VERSION = 1;

export const RECOMMENDATIONS_SYSTEM_PROMPT = `You are a drawing coach inside DrawEvolve, recommending what an artist should draw next. You have access to the user's recent drawings and critique focus areas.

Recommend exactly 5 subjects to draw. Each recommendation must:
- Be a specific, drawable subject (e.g., "still life with three glass objects" not "practice values")
- Be achievable in a single drawing session (not a multi-week project)
- Include a one-sentence rationale tied to what you can see in the user's history
- Map to a primary focus area

Mix three types of recommendations across the five:
1. Skill targeting: subjects that drill weaknesses the critiques have flagged repeatedly
2. Variety: subjects in categories the user hasn't tried recently
3. Stretch: subjects slightly harder than what the user has been making, building on shown strengths

Don't recommend the same subjects the user has already drawn recently. Don't recommend anything outside the user's apparent skill level — too easy is boring, too hard is discouraging.

Each rationale should sound like a real coach: specific, encouraging, never preachy. Reference what's in the user's history. Don't lecture about technique.

If the user has fewer than 3 drawings in their history, your recommendations should lean toward fundamentals (basic still life, simple portraits, gesture studies) and frame them as starting points, not skill targeting. In that case, mark them all as recommendation_type "skill_targeting" — the universal weakness is lack of foundation, and the type enum is bounded to the three values in the schema.`;

/**
 * Build the user-role message for the recommendations request.
 *
 * `coachingContext` is the same shape as Eve's (from
 * lib/supabase.js → fetchCoachingContext). Rendered leaner here than
 * in eve-prompt.js: no Eve guardrails, no "reference this naturally"
 * copy. The system prompt has all the behavioral guidance.
 *
 * On empty portfolio, the message still asks for 5 recommendations;
 * the system prompt's fundamentals-lean instruction kicks in.
 */
export function buildRecommendationsUserMessage(coachingContext) {
  const drawings = Array.isArray(coachingContext?.drawings) ? coachingContext.drawings : [];
  const summaries = Array.isArray(coachingContext?.summaries) ? coachingContext.summaries : [];

  if (drawings.length === 0 && summaries.length === 0) {
    return `This is a new user with no drawings yet. Recommend 5 subjects to draw, leaning toward fundamentals as starting points.

Return exactly 5 recommendations as structured JSON per the schema.`;
  }

  const parts = ['Based on this user\'s drawing history, recommend 5 subjects to draw next.'];

  if (drawings.length > 0) {
    parts.push('Recent drawings (newest activity first):');
    parts.push(drawings.map(renderRecDrawingRow).join('\n'));
  }

  if (summaries.length > 0) {
    parts.push('Recent critique summaries (newest first):');
    parts.push(summaries.map(renderRecSummaryRow).join('\n\n'));
  }

  parts.push('Return exactly 5 recommendations as structured JSON per the schema.');
  return parts.join('\n\n');
}

function renderRecDrawingRow(row) {
  const title = (typeof row?.title === 'string' && row.title.trim()) ? row.title.trim() : 'Untitled';
  const subjectRaw = typeof row?.subject === 'string' ? row.subject.trim() : '';
  const subjectPart = subjectRaw ? `${subjectRaw}, ` : '';
  const when = (typeof row?.relative_time === 'string' && row.relative_time) ? row.relative_time : 'recently';
  const total = typeof row?.total_critiques === 'number' ? row.total_critiques : 0;
  const word = total === 1 ? 'critique' : 'critiques';
  if (total === 0 || !row?.last_critique) {
    return `- "${title}" (${subjectPart}${when}, ${total} ${word})`;
  }
  const last = row.last_critique;
  const focus = (typeof last.focus_area_text === 'string' && last.focus_area_text.trim())
    ? last.focus_area_text.trim()
    : (typeof last.primary_category === 'string' && last.primary_category)
      ? last.primary_category
      : 'general';
  return `- "${title}" (${subjectPart}${when}, ${total} ${word} — last focus: ${focus})`;
}

function renderRecSummaryRow(row) {
  const title = (typeof row?.drawing_title === 'string' && row.drawing_title.trim())
    ? row.drawing_title.trim()
    : 'Untitled';
  const when = (typeof row?.relative_time === 'string' && row.relative_time) ? row.relative_time : 'recently';
  const bullets = Array.isArray(row?.summary_bullets) ? row.summary_bullets : [];
  return `[${when} — "${title}"]\n${bullets.map((b) => `- ${b}`).join('\n')}`;
}
