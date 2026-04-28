// DrawEvolve feedback Worker.
//
// Prompt construction is intentionally externalized from the request handler.
// To iterate on prompts, edit the constants and presets below — do NOT inline
// prompt strings into fetch().
//
// PromptConfig shape:
//   {
//     systemPrompt: string,        // base "you are an art critic" prompt; static across requests
//     includeHistoryCount: number, // how many prior critiques on this drawing to include (0 = none)
//     historyFraming: string,      // wrapper text introducing past critiques to the model
//     styleModifier: string | null,// optional appended instruction (Pro tier override)
//     maxOutputTokens: number      // OpenAI max_tokens for the response
//   }
//
// Tier flow:
//   1. getUserTier(jwt, env) -> { tier, promptPreferences } from auth.users.app_metadata
//   2. selectConfig(tier, promptPreferences) -> PromptConfig (preset + per-user overrides for Pro)
//   3. fetchCritiqueHistory(drawingId, env) -> [{ feedback, timestamp, ... }] from drawings.critique_history
//   4. buildSystemPrompt(config, context) + buildUserMessage(config, history) -> messages
//   5. POST to OpenAI; return feedback.
//
// Phases 1, 2, 5a, 5b of authandratelimitingandsecurity.md will fill in real JWT
// validation + Postgres reads. Until those land the stubs return safe defaults
// (free tier, no history) so the Worker keeps working unchanged for existing
// clients.

const BASE_SYSTEM_PROMPT = `You are a seasoned drawing coach inside the DrawEvolve app. You have 15 years of studio teaching experience, you've seen thousands of student portfolios, and you give feedback the way a sharp, honest mentor would over someone's shoulder — specific to what you see, never generic.

CORE RULES:
- You are analyzing a real student drawing sent as an image. EVERY observation must reference specific visual evidence in THIS drawing. Never produce generic art advice.
- Be honest and constructive. Praise only what genuinely works, and be direct about what doesn't. Critique the work, never the person.
- Focus on the ONE most impactful improvement — not a laundry list. Depth over breadth.
- End with one natural, friendly joke or witty aside related to the drawing or the artistic process. Keep it warm and brief — never punch down at the student.`;

const RESPONSE_FORMAT_TEMPLATE = (skillLevel) => `RESPONSE FORMAT — follow this structure exactly:

**Quick Take**
1-2 sentences. Your honest gut reaction to the drawing as a whole. Be real — what stands out immediately, good or bad?

**What's Working**
1-2 specific strengths you observe in the actual drawing. Reference concrete visual evidence (e.g., "the line weight variation in the hair" not "nice work"). Skip this section entirely if nothing genuinely succeeds yet — don't manufacture praise.

**Focus Area: [Name the specific issue]**
The single most impactful thing to improve. Describe what you see, explain why it matters, and ${skillLevel === 'Beginner' ? 'give a clear, step-by-step suggestion for what to try.' : skillLevel === 'Advanced' ? 'pose a question or observation that helps them see it differently.' : 'provide a concrete technique or exercise to address it.'}

**Try This**
1-2 specific, actionable next steps the student can do immediately. Be concrete enough that they know exactly what to attempt.

**💬**
One brief, friendly joke or aside related to the drawing, subject, or artistic process. Keep it natural.

IMPORTANT: Stay within ~700 words. Be dense and specific, not padded. Every sentence should earn its place.`;

const HISTORY_FRAMING_DEFAULT = `Here is your prior feedback on this drawing, oldest first. Evaluate whether the student has acted on it. If they have, acknowledge that progress directly. If they haven't, gently bring the unresolved point back into focus rather than introducing a brand-new issue:`;

const DEFAULT_FREE_CONFIG = {
  systemPrompt: BASE_SYSTEM_PROMPT,
  includeHistoryCount: 2,
  historyFraming: HISTORY_FRAMING_DEFAULT,
  styleModifier: null,
  maxOutputTokens: 1000,
};

const DEFAULT_PRO_CONFIG = {
  systemPrompt: BASE_SYSTEM_PROMPT,
  includeHistoryCount: 5,
  historyFraming: HISTORY_FRAMING_DEFAULT,
  styleModifier: null, // populated at request time from app_metadata.prompt_preferences.styleModifier
  maxOutputTokens: 1500,
};

function selectConfig(tier, promptPreferences) {
  if (tier === 'pro') {
    return {
      ...DEFAULT_PRO_CONFIG,
      styleModifier: promptPreferences?.styleModifier ?? null,
    };
  }
  return { ...DEFAULT_FREE_CONFIG };
}

function renderSkillCalibration(skillLevel) {
  if (skillLevel === 'Beginner') {
    return `This student is a BEGINNER.
- Use plain, accessible language. Define any art term you introduce.
- Be more prescriptive: tell them exactly what to try ("make the shadow side darker") rather than asking open questions.
- Limit feedback to one concept. Encouragement matters — highlight genuine effort and visible progress.
- Frame mistakes as normal and expected. Never compare to professional standards.
- Keep your tone warm and patient, like a first day in a supportive studio class.`;
  }
  if (skillLevel === 'Intermediate') {
    return `This student is INTERMEDIATE.
- Use art vocabulary freely (value, composition, gesture, negative space, etc.) without over-explaining.
- Balance observation with targeted diagnosis: name the specific issue and explain why it matters.
- Challenge them to leave comfort zones — suggest unfamiliar angles, techniques, or subjects.
- They can see problems before they can fix them. Offer concrete techniques, not just identification.
- If their work shows consistent competence in an area, push them toward the next challenge.`;
  }
  if (skillLevel === 'Advanced') {
    return `This student is ADVANCED.
- Treat them as a peer. Use nuanced language — edge quality, value key, temperature shifts, mark economy.
- Ask questions more than give answers: "What were you going for with this edge treatment?"
- Focus on style development, conceptual choices, and subtlety — not fundamentals.
- Reference relevant artists or traditions when it adds insight (not to show off).
- Be more descriptive than prescriptive. Trust their ability to problem-solve once they see the issue.`;
  }
  return '';
}

function renderContextBlock(context) {
  const subject = context.subject || 'not specified';
  const lines = [`- Subject: ${subject}`];
  if (context.style) lines.push(`- Style: ${context.style}`);
  if (context.artists) lines.push(`- Reference artists: ${context.artists}`);
  if (context.techniques) lines.push(`- Techniques: ${context.techniques}`);
  if (context.focus) lines.push(`- Student wants feedback on: ${context.focus}`);
  if (context.additionalContext) lines.push(`- Additional context: ${context.additionalContext}`);
  return lines.join('\n');
}

function buildSystemPrompt(config, context) {
  const skillLevel = context.skillLevel || 'Beginner';
  const sections = [
    config.systemPrompt,
    `SKILL LEVEL CALIBRATION:\n${renderSkillCalibration(skillLevel)}`,
    `CONTEXT (use what's provided, ignore empty fields):\n${renderContextBlock(context)}`,
    RESPONSE_FORMAT_TEMPLATE(skillLevel),
  ];
  if (config.styleModifier) {
    sections.push(`ADDITIONAL STYLE GUIDANCE (per user preference):\n${config.styleModifier}`);
  }
  return sections.join('\n\n');
}

function formatHistoryEntries(entries) {
  return entries
    .map((entry, i) => {
      const stamp = entry.timestamp ?? entry.created_at ?? '';
      const text = entry.feedback ?? entry.text ?? '';
      return `[Critique ${i + 1}${stamp ? ` — ${stamp}` : ''}]\n${text}`;
    })
    .join('\n\n');
}

function buildUserMessage(config, history, base64Image) {
  const slice = Array.isArray(history)
    ? history.slice(-config.includeHistoryCount)
    : [];
  const parts = [];
  if (config.includeHistoryCount > 0 && slice.length > 0) {
    parts.push({
      type: 'text',
      text: `${config.historyFraming}\n\n${formatHistoryEntries(slice)}\n\nNow critique the current state of the drawing below.`,
    });
  } else {
    parts.push({ type: 'text', text: 'Please critique this drawing.' });
  }
  if (base64Image) {
    parts.push({ type: 'image_url', image_url: { url: `data:image/jpeg;base64,${base64Image}` } });
  }
  return parts;
}

// Stubs — Phase 1 / 5a will replace these with real JWT validation + Postgres reads.
async function getUserTier(_jwt, _env) {
  return { tier: 'free', promptPreferences: null };
}

async function fetchCritiqueHistory(_drawingId, _env) {
  return [];
}

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  });
}

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: CORS_HEADERS });
    }
    if (request.method !== 'POST') {
      return jsonResponse({ error: 'Method not allowed' }, 405);
    }

    try {
      const { image, context, drawingId } = await request.json();
      const jwt = request.headers.get('Authorization')?.replace(/^Bearer\s+/, '') ?? null;

      const { tier, promptPreferences } = await getUserTier(jwt, env);
      const config = selectConfig(tier, promptPreferences);
      const history = await fetchCritiqueHistory(drawingId, env);

      const systemPrompt = buildSystemPrompt(config, context ?? {});
      const userContent = buildUserMessage(config, history, image);

      const response = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${env.OPENAI_API_KEY}`,
        },
        body: JSON.stringify({
          model: 'gpt-4o',
          messages: [
            { role: 'system', content: systemPrompt },
            { role: 'user', content: userContent },
          ],
          max_tokens: config.maxOutputTokens,
        }),
      });

      const data = await response.json();
      return jsonResponse({
        feedback: data.choices?.[0]?.message?.content || 'No feedback generated',
      });
    } catch (error) {
      return jsonResponse({ error: 'Internal server error', details: error.message }, 500);
    }
  },
};

// Named exports for unit tests (see test.mjs).
export {
  BASE_SYSTEM_PROMPT,
  HISTORY_FRAMING_DEFAULT,
  DEFAULT_FREE_CONFIG,
  DEFAULT_PRO_CONFIG,
  selectConfig,
  buildSystemPrompt,
  buildUserMessage,
  formatHistoryEntries,
  renderSkillCalibration,
  renderContextBlock,
};
