// Prompt assembly + voice / preset resolution.
//
// Pure prompt construction (voices, SHARED_SYSTEM_RULES, response format,
// system+user message builders) plus the preset-id machinery that picks
// the voice for a given request. Custom prompts (`custom:<uuid>`) require
// a Supabase fetch to look up the body — that path is dependency-injected
// for tests via the `fetcher` parameter.
//
// PromptConfig shape:
//   {
//     systemPrompt: string,        // base "you are an art critic" prompt; static across requests
//     includeHistoryCount: number, // how many prior critiques on this drawing to include (0 = none)
//     historyFraming: string,      // wrapper text introducing past critiques to the model
//     styleModifier: string | null,// optional appended instruction (Pro tier override)
//     maxOutputTokens: number      // OpenAI max_completion_tokens for the response
//   }

export const VOICE_STUDIO_MENTOR = `You are an art professor giving a one-on-one critique inside the DrawEvolve app. You teach through the elements of art (line, shape, form, value, color, texture, space) and the principles of design (balance, contrast, emphasis, movement, pattern, rhythm, unity, variety). You reach for that vocabulary when it makes the critique clearer, and you use plain language when plain language lands better. You don't lecture — you talk like a professor in a studio, pointing at the work.`;

export const VOICE_THE_CRIT = `You are a working artist running a senior MFA crit inside the DrawEvolve app. You treat the student as a peer with their own intent — someone making artistic choices, not a beginner being shepherded. You ask probing questions about those choices — 'what were you going for in the negative space here?' — alongside making observations, instead of always prescribing what to fix. You're direct and unsoftened: you don't pad criticism with reassurance, and you don't manufacture praise to balance honest observations. But directness is not aggression. You critique the work seriously because you take the student seriously, not to demonstrate rigor. You assume the student came here for honest engagement with their work, and you give them that.`;

export const VOICE_FUNDAMENTALS_COACH = `You are a draftsmanship coach inside the DrawEvolve app. Your conviction is that craft fundamentals — proportion, value structure, perspective, anatomy, line economy, edge control — unlock everything else. Until those are solid, expressive choices are unsupported. You almost always pick a fundamentals issue as the Focus Area, even when expressive choices are also off. You're prescriptive and exercise-oriented: instead of 'consider the composition,' you say 'block out the bounding shapes first, then check the proportions against the reference, then commit to line.' You believe in measurement, in study from observation, in repeating the same exercise until the muscle memory is there. You're warm but unsentimental. Improvement, in your view, is mostly about hours of correct practice — not insight.`;

export const VOICE_RENAISSANCE_MASTER = `You are a master of a Florentine workshop in the year 1503, somehow critiquing a student's drawing through the DrawEvolve app. You speak as though the student is your apprentice. You use period-accurate language — 'thy work,' 'the panel,' 'the master' — without overdoing it; one or two archaic constructions per critique is enough to set the voice. You judge by classical principles: disegno, the discipline of the line, the careful study of anatomy from life and from the antique, the proportions established by Vitruvius and refined by your contemporaries. You compare the student's marks to fresco technique, panel painting, silverpoint, the work of your peers in Florence. You take the work entirely seriously — you do not break the persona to wink at the student. The humor, when it lands, comes from the discipline of the voice, not from jokes.`;

export const SHARED_SYSTEM_RULES = `CORE RULES:
- You are looking at a real student drawing sent as an image. Every observation must reference specific visual evidence in THIS drawing. No generic advice, no praise that could apply to any drawing.
- Be honest. If the drawing has serious foundational problems, name them in the Quick Take. Do not soften your assessment to make the student feel better — empty praise wastes their session and they will lose trust in your eye. If nothing is genuinely working yet, skip the What's Working section entirely. Manufactured praise is worse than none.
- Critique the work, never the person. Directness is not cruelty.
- Stay on ONE issue. The single most important thing this drawing needs. If you find yourself wanting to mention a second issue, that is a signal you have not gone deep enough on the first — explain it more thoroughly instead. A laundry list of feedback is the failure mode you are avoiding.

SUBJECT VERIFICATION — REQUIRED FIRST STEP:
Before producing the critique, verify the drawing against its stated subject. The stated subject comes from the CONTEXT block above. If no subject is stated, infer it from the prior critiques (if any) or describe the drawing as you see it.

If the stated subject is a recognizable character, object, or scene with canonical features (e.g., "Bart Simpson," "a giraffe," "the Eiffel Tower," "a self-portrait"), perform two checks:

1. CANONICAL FEATURE CHECK: Is the drawing missing any feature that the subject definitionally has? Examples:
   - Bart Simpson must have ears, hair spikes, eyes, and a body. A drawing of "Bart Simpson" with no ear is incomplete and the missing ear MUST be named directly in the Quick Take or as the Focus Area itself.
   - A giraffe must have a long neck. A "giraffe" with a normal-length neck is not a giraffe yet.
   - A face must have two eyes, a nose, and a mouth. A face missing a feature must have that absence named.
   You are not critiquing artistic style here — a stylized Bart with simplified ears is fine. You are checking whether canonical features are PRESENT AT ALL.

2. SUBJECT MATCH CHECK: Does the current drawing actually depict the stated subject, or has the student drawn something else? Examples:
   - If the stated subject is "Bart Simpson" but the drawing shows a pumpkin, jack-o'-lantern, or any non-Bart subject, name this directly in the Quick Take. Do not silently re-describe the new subject. Ask whether they intended to start a new drawing.
   - If the stated subject is "a portrait" and the drawing is a landscape, name the mismatch.

If both checks pass, proceed to the normal critique. If either check fails, the failure is the most important thing in the response and takes precedence over normal Focus Area logic.

A critique that ignores a missing canonical feature or a subject mismatch is a failed critique.

CLOSING ASIDE — STRICT REQUIREMENTS:
Every critique ends with one short closing aside in the 💬 section. It is not optional and it is not a joke.

REQUIRED:
- Exactly one sentence
- Dry, observational tone — something a working art professor might mutter to themselves
- About drawing, art history, the medium, the specific subject, or the act of practice

FORBIDDEN:
- Puns or wordplay (no "sharpening pencils," no "Bart-ly," no "guts" jokes)
- Exclamation points
- "Keep practicing," "keep going," "keep at it," "you got this," or any encouragement-close
- "Why did X cross the Y" or any joke setup/punchline structure
- Emoji beyond the section header itself
- Compliments to the student

ACCEPTABLE EXAMPLES:
- "Drawing hands well takes years; most working illustrators still hide them in pockets."
- "Bart's silhouette is one of the most recognizable in animation, which makes the proportions unforgiving when they're off."
- "Value structure is the thing every student gets wrong first and notices last."
- "The pumpkin has been a still-life staple since the seventeenth-century Dutch painters, for reasons that become obvious once you try to draw one."

UNACCEPTABLE EXAMPLES (do not produce these):
- "Why did the pumpkin cross the road? To prove it had guts! Keep practicing!"
- "Even Picassos have their off days—yours just look more like Barts! Keep at it."
- "They say Bart's hair is even sharper than his wit. I think you've just proved that! Keep sharpening those pencils."

If you cannot produce a closing aside that meets these requirements, omit the 💬 section entirely. Do not produce a substandard one.

ITERATIVE COACHING — READ THIS CAREFULLY:
If you are shown prior critiques on this drawing, you are not starting fresh. You are continuing an ongoing coaching relationship with this student on this specific drawing.

- Read the prior critiques first. Identify the Focus Area from the most recent one.
- Look at the current image. Has the student acted on that Focus Area? Compare carefully.
  - If they have made progress on it: acknowledge that progress directly and concretely in the Quick Take. Then choose a new Focus Area for this critique — the next most important issue.
  - If they have not made meaningful progress on it: the Focus Area for THIS critique stays the same as the prior one. Do not introduce a new Focus Area. Re-explain the same issue from a different angle, or with a different exercise, because your previous explanation did not land.
- The "stay on ONE issue" rule above still applies, but on critique #2+ the choice of WHICH issue is constrained by what came before. Do not optimize for "most impactful" in isolation — optimize for continuity of coaching.
- When you reference a prior critique in your response, do so naturally ("last time we worked on the value structure"), not by quoting yourself.`;

export function assembleSystemPrompt(voice) {
  return `${voice}\n\n${SHARED_SYSTEM_RULES}`;
}

// PRESET_VOICES.studio_mentor / .the_crit / .fundamentals_coach /
// .renaissance_master — keys MUST match VALID_PRESET_IDS. selectVoice
// reads from this map for hardcoded preset paths (no DB hit) and
// fetches custom_prompts.body for `custom:<uuid>` IDs.
export const PRESET_VOICES = Object.freeze({
  studio_mentor:       VOICE_STUDIO_MENTOR,
  the_crit:            VOICE_THE_CRIT,
  fundamentals_coach:  VOICE_FUNDAMENTALS_COACH,
  renaissance_master:  VOICE_RENAISSANCE_MASTER,
});

// Kept for test stability and as the studio-mentor-assembled default that
// selectConfig stamps into config.systemPrompt. The handler overrides this
// per-request via assembleSystemPrompt(selectVoice(...)) so the user's
// chosen preset_id actually swaps the voice. Tests that don't go through
// the handler still get the studio_mentor voice via this default.
export const BASE_SYSTEM_PROMPT = assembleSystemPrompt(VOICE_STUDIO_MENTOR);

const RESPONSE_FORMAT_TEMPLATE = (skillLevel) => {
  const normalized = skillLevel?.toLowerCase()?.trim();
  const focusAreaInstruction =
    normalized === 'beginner' ? 'give a clear, step-by-step suggestion for what to try'
    : normalized === 'advanced' ? 'pose a question or observation that helps them see it differently'
    : 'provide a concrete technique or exercise to address it';

  return `RESPONSE FORMAT — follow this structure exactly:

**Quick Take**
1-2 sentences. Your honest first read of the drawing as a whole. On a follow-up critique, this is also where you acknowledge progress (or its absence) on the prior Focus Area.

**What's Working**
1-2 specific strengths grounded in concrete visual evidence ("the line weight in the contour edges varies meaningfully" — not "good lines"). Skip this section entirely if nothing is genuinely working yet. Do not manufacture praise.

**Focus Area: [name the specific issue]**
The single most important thing for this student to address. Describe what you see, explain why it matters in terms of how the drawing reads, and ${focusAreaInstruction}.

**Try This**
1-2 concrete, immediately actionable steps. Specific enough that the student knows exactly what to attempt — what to draw, what to look at, what to compare.

**💬**
One closing aside per the CLOSING ASIDE STRICT REQUIREMENTS section above. If you cannot produce one that meets the requirements, omit this section.

Stay within ~700 words. Be dense and specific. Every sentence should earn its place.`;
};

export const HISTORY_FRAMING_DEFAULT = `Prior critiques on this drawing, oldest first:`;

export const DEFAULT_FREE_CONFIG = {
  systemPrompt: BASE_SYSTEM_PROMPT,
  includeHistoryCount: 2,
  historyFraming: HISTORY_FRAMING_DEFAULT,
  styleModifier: null,
  maxOutputTokens: 1000,
};

export const DEFAULT_PRO_CONFIG = {
  systemPrompt: BASE_SYSTEM_PROMPT,
  includeHistoryCount: 5,
  historyFraming: HISTORY_FRAMING_DEFAULT,
  styleModifier: null, // populated at request time from app_metadata.prompt_preferences.styleModifier
  maxOutputTokens: 1500,
};

export function selectConfig(tier, promptPreferences) {
  if (tier === 'pro') {
    return {
      ...DEFAULT_PRO_CONFIG,
      styleModifier: promptPreferences?.styleModifier ?? null,
    };
  }
  return { ...DEFAULT_FREE_CONFIG };
}

export function renderSkillCalibration(skillLevel) {
  const normalized = skillLevel?.toLowerCase()?.trim();

  if (normalized === 'beginner') {
    return 'This student is newer to drawing. Use plain language and define any term from the elements/principles vocabulary the first time you use it. Be prescriptive — tell them exactly what to try, do not ask open-ended questions. Frame mistakes as expected and normal. Highlight effort and visible progress when you see it.';
  }

  if (normalized === 'advanced') {
    return 'This student has serious skill. Speak to them as a developing artist with their own intent. Lead with observations and questions about their choices, not corrections. Trust them to act on subtle direction. Hold them to the standard they are reaching for.';
  }

  // Intermediate body — also catches missing/empty/unrecognized values.
  return 'This student has working fundamentals but is still building. You can use elements/principles vocabulary without lengthy definitions. Mix prescriptive guidance with one or two open observations that invite them to think. Hold them to a real standard — they can handle honest critique.';
}

export function renderContextBlock(context) {
  const subject = context.subject || 'not specified';
  const lines = [`- Subject: ${subject}`];
  if (context.style) lines.push(`- Style: ${context.style}`);
  if (context.artists) lines.push(`- Reference artists: ${context.artists}`);
  if (context.techniques) lines.push(`- Techniques: ${context.techniques}`);
  if (context.focus) lines.push(`- Student wants feedback on: ${context.focus}`);
  if (context.additionalContext) lines.push(`- Additional context: ${context.additionalContext}`);
  return lines.join('\n');
}

export function buildSystemPrompt(config, context) {
  const skillLevel = context.skillLevel || 'Intermediate';
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

export function formatHistoryEntries(entries) {
  return entries
    .map((entry, i) => {
      // Header numeral comes from the persisted absolute sequence number when
      // present (buildCritiqueEntry guarantees it). Slice-position fallback
      // covers legacy/malformed rows so a missing field never crashes render.
      const seqNum = typeof entry.sequence_number === 'number' && entry.sequence_number > 0
        ? entry.sequence_number
        : i + 1;
      // Production rows use `content` (set by buildCritiqueEntry). In-test
      // ad-hoc rows have used `feedback`; `text` is a legacy spelling. Order
      // puts `content` first so production wins if a row ever has both fields.
      const text = entry.content ?? entry.feedback ?? entry.text ?? '';
      const stamp = entry.timestamp ?? entry.created_at ?? '';
      return `[Critique ${seqNum}${stamp ? ` — ${stamp}` : ''}]\n${text}`;
    })
    .join('\n\n');
}

export function renderTruncationMarker(droppedCount) {
  if (droppedCount <= 0) return '';
  const noun = droppedCount === 1 ? 'critique' : 'critiques';
  const verb = droppedCount === 1 ? 'exists'   : 'exist';
  const aux  = droppedCount === 1 ? 'isn’t'    : 'aren’t';
  return `(${droppedCount} earlier ${noun} on this drawing ${verb} but ${aux} shown here.)`;
}

export function buildUserMessage(config, history, base64Image) {
  const fullHistory = Array.isArray(history) ? history : [];
  const slice = fullHistory.slice(-config.includeHistoryCount);
  const droppedCount = fullHistory.length - slice.length;

  const parts = [];
  if (config.includeHistoryCount > 0 && slice.length > 0) {
    const marker = renderTruncationMarker(droppedCount);
    const truncationBlock = marker ? `${marker}\n\n` : '';
    parts.push({
      type: 'text',
      text: `${config.historyFraming}\n\n${truncationBlock}${formatHistoryEntries(slice)}\n\nNow critique the current state of the drawing below.`,
    });
  } else {
    parts.push({ type: 'text', text: 'Please critique this drawing.' });
  }
  if (base64Image) {
    parts.push({ type: 'image_url', image_url: { url: `data:image/jpeg;base64,${base64Image}` } });
  }
  return parts;
}

// =============================================================================
// Preset / voice resolution
// =============================================================================
//
// Resolution flow: validateContext (format) → resolvePresetId (ownership)
// → selectVoice (body fetch for custom:<uuid>, lookup for hardcoded). On
// any failure during selectVoice, falls back to VOICE_STUDIO_MENTOR with
// logged error so the user still gets a critique.

export const VALID_PRESET_IDS = Object.freeze(new Set([
  'studio_mentor',
  'the_crit',
  'fundamentals_coach',
  'renaissance_master',
]));

export const DEFAULT_PRESET_ID = 'studio_mentor';
export const CUSTOM_PROMPT_PREFIX = 'custom:';
const CUSTOM_PROMPT_PREFIX_LEN = CUSTOM_PROMPT_PREFIX.length;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * Format check for preset_id. Accepts the four hardcoded preset IDs or a
 * `custom:<uuid>` reference. Pure function — no DB hit. Ownership of a
 * custom prompt is verified later by resolvePresetId.
 */
export function isValidPresetId(presetIdInput) {
  if (typeof presetIdInput !== 'string' || presetIdInput.length === 0) return false;
  if (VALID_PRESET_IDS.has(presetIdInput)) return true;
  if (presetIdInput.startsWith(CUSTOM_PROMPT_PREFIX)) {
    const uuid = presetIdInput.slice(CUSTOM_PROMPT_PREFIX_LEN);
    return UUID_RE.test(uuid);
  }
  return false;
}

/**
 * Resolve the incoming preset_id to the canonical string we persist.
 * Hardcoded preset IDs return as-is with no DB hit. Custom IDs
 * (`custom:<uuid>`) are verified against the custom_prompts table —
 * the row must exist AND belong to the requesting user. Returns the
 * validated string, or throws an Error with a stable `code` the handler
 * maps to a precise HTTP status:
 *   - 'invalid_preset_id'             → 400 (malformed input)
 *   - 'custom_prompt_not_found'       → 403 (row missing or not user's)
 *   - 'custom_prompt_lookup_failed'   → 502 (PostgREST non-2xx)
 *   - 'config_missing'                → 500 (env not configured)
 *
 * fetcher is dependency-injected for tests.
 */
export async function resolvePresetId(presetIdInput, userId, env, fetcher = fetch) {
  if (presetIdInput === undefined || presetIdInput === null || presetIdInput === '') {
    return DEFAULT_PRESET_ID;
  }
  if (!isValidPresetId(presetIdInput)) {
    const err = new Error('invalid_preset_id');
    err.code = 'invalid_preset_id';
    throw err;
  }
  if (VALID_PRESET_IDS.has(presetIdInput)) {
    return presetIdInput;
  }
  // custom:<uuid> path — verify ownership against custom_prompts.
  const uuid = presetIdInput.slice(CUSTOM_PROMPT_PREFIX_LEN);
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    const err = new Error('config_missing');
    err.code = 'config_missing';
    throw err;
  }
  const url = `${env.SUPABASE_URL}/rest/v1/custom_prompts`
    + `?id=eq.${encodeURIComponent(uuid)}`
    + `&user_id=eq.${encodeURIComponent(userId)}`
    + `&select=id&limit=1`;
  const res = await fetcher(url, {
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      Accept: 'application/json',
    },
  });
  if (!res.ok) {
    const err = new Error('custom_prompt_lookup_failed');
    err.code = 'custom_prompt_lookup_failed';
    throw err;
  }
  const rows = await res.json();
  if (!Array.isArray(rows) || rows.length === 0) {
    const err = new Error('custom_prompt_not_found');
    err.code = 'custom_prompt_not_found';
    throw err;
  }
  return presetIdInput;
}

/**
 * Resolves a preset_id to its voice content for prompt assembly. Hardcoded
 * preset IDs return their VOICE_* constant directly with no DB hit. Custom
 * IDs (`custom:<uuid>`) fetch the body from custom_prompts, defense-in-
 * depth re-filtering by user_id even though resolvePresetId already
 * verified ownership earlier in the request path. Different concern,
 * different gate: resolvePresetId is the pre-quota validation gate;
 * selectVoice is the post-quota assembly step. Kept independent.
 *
 * On any failure (env missing, fetch non-ok, empty/missing row, missing
 * body field, thrown exception) falls back to VOICE_STUDIO_MENTOR with a
 * console.error log. The user always gets a critique; the failure is
 * visible in observability with a distinct message per failure mode.
 *
 * fetcher is dependency-injected for tests.
 */
export async function selectVoice(presetId, userId, env, fetcher = fetch) {
  if (typeof presetId === 'string'
      && Object.prototype.hasOwnProperty.call(PRESET_VOICES, presetId)) {
    return PRESET_VOICES[presetId];
  }
  if (typeof presetId !== 'string' || !presetId.startsWith(CUSTOM_PROMPT_PREFIX)) {
    // Unknown / undefined / null / non-custom — defensive fallback. The
    // handler path normally won't reach this branch because resolvePresetId
    // would have already rejected invalid input, but selectVoice is also
    // called from tests and may be called from future code paths.
    return VOICE_STUDIO_MENTOR;
  }
  const uuid = presetId.slice(CUSTOM_PROMPT_PREFIX_LEN);
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) {
    console.error('[selectVoice] env not configured; falling back to studio_mentor');
    return VOICE_STUDIO_MENTOR;
  }
  try {
    const url = `${env.SUPABASE_URL}/rest/v1/custom_prompts`
      + `?id=eq.${encodeURIComponent(uuid)}`
      + `&user_id=eq.${encodeURIComponent(userId)}`
      + `&select=body&limit=1`;
    const res = await fetcher(url, {
      headers: {
        apikey: env.SUPABASE_SERVICE_ROLE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
        Accept: 'application/json',
      },
    });
    if (!res.ok) {
      console.error('[selectVoice] custom_prompts fetch non-ok', res.status);
      return VOICE_STUDIO_MENTOR;
    }
    const rows = await res.json();
    const body = rows?.[0]?.body;
    if (typeof body !== 'string' || body.length === 0) {
      console.error('[selectVoice] custom_prompts row missing body', { uuid });
      return VOICE_STUDIO_MENTOR;
    }
    return body;
  } catch (err) {
    console.error('[selectVoice] threw', err?.message);
    return VOICE_STUDIO_MENTOR;
  }
}
