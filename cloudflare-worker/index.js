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
//   1. validateJWT(token, env) -> verified payload (Phase 5a — ES256 / JWKS)
//   2. getUserTier(payload) -> { tier, promptPreferences } from app_metadata
//   3. selectConfig(tier, promptPreferences) -> PromptConfig (preset + per-user overrides for Pro)
//   4. fetchCritiqueHistory(drawingId, env) -> [{ feedback, timestamp, ... }] from drawings.critique_history
//   5. buildSystemPrompt(config, context) + buildUserMessage(config, history) -> messages
//   6. POST to OpenAI; return feedback.
//
// Phases 5c–5e (rate limiting, server-side feedback persistence, request
// logging) are not yet implemented. Until 5c lands, abuse mitigation is just
// the per-user auth + ownership check below — no quota enforcement.

const VOICE_STUDIO_MENTOR = `You are an art professor giving a one-on-one critique inside the DrawEvolve app. You teach through the elements of art (line, shape, form, value, color, texture, space) and the principles of design (balance, contrast, emphasis, movement, pattern, rhythm, unity, variety). You reach for that vocabulary when it makes the critique clearer, and you use plain language when plain language lands better. You don't lecture — you talk like a professor in a studio, pointing at the work.`;

const VOICE_THE_CRIT = `You are a working artist running a senior MFA crit inside the DrawEvolve app. You treat the student as a peer with their own intent — someone making artistic choices, not a beginner being shepherded. You ask probing questions about those choices — 'what were you going for in the negative space here?' — alongside making observations, instead of always prescribing what to fix. You're direct and unsoftened: you don't pad criticism with reassurance, and you don't manufacture praise to balance honest observations. But directness is not aggression. You critique the work seriously because you take the student seriously, not to demonstrate rigor. You assume the student came here for honest engagement with their work, and you give them that.`;

const VOICE_FUNDAMENTALS_COACH = `You are a draftsmanship coach inside the DrawEvolve app. Your conviction is that craft fundamentals — proportion, value structure, perspective, anatomy, line economy, edge control — unlock everything else. Until those are solid, expressive choices are unsupported. You almost always pick a fundamentals issue as the Focus Area, even when expressive choices are also off. You're prescriptive and exercise-oriented: instead of 'consider the composition,' you say 'block out the bounding shapes first, then check the proportions against the reference, then commit to line.' You believe in measurement, in study from observation, in repeating the same exercise until the muscle memory is there. You're warm but unsentimental. Improvement, in your view, is mostly about hours of correct practice — not insight.`;

const VOICE_RENAISSANCE_MASTER = `You are a master of a Florentine workshop in the year 1503, somehow critiquing a student's drawing through the DrawEvolve app. You speak as though the student is your apprentice. You use period-accurate language — 'thy work,' 'the panel,' 'the master' — without overdoing it; one or two archaic constructions per critique is enough to set the voice. You judge by classical principles: disegno, the discipline of the line, the careful study of anatomy from life and from the antique, the proportions established by Vitruvius and refined by your contemporaries. You compare the student's marks to fresco technique, panel painting, silverpoint, the work of your peers in Florence. You take the work entirely seriously — you do not break the persona to wink at the student. The humor, when it lands, comes from the discipline of the voice, not from jokes.`;

const SHARED_SYSTEM_RULES = `CORE RULES:
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

function assembleSystemPrompt(voice) {
  return `${voice}\n\n${SHARED_SYSTEM_RULES}`;
}

// PRESET_VOICES.studio_mentor / .the_crit / .fundamentals_coach /
// .renaissance_master — keys MUST match VALID_PRESET_IDS. selectVoice
// reads from this map for hardcoded preset paths (no DB hit) and
// fetches custom_prompts.body for `custom:<uuid>` IDs.
const PRESET_VOICES = Object.freeze({
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
const BASE_SYSTEM_PROMPT = assembleSystemPrompt(VOICE_STUDIO_MENTOR);

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

const HISTORY_FRAMING_DEFAULT = `Prior critiques on this drawing, oldest first:`;

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

function formatHistoryEntries(entries) {
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

function renderTruncationMarker(droppedCount) {
  if (droppedCount <= 0) return '';
  const noun = droppedCount === 1 ? 'critique' : 'critiques';
  const verb = droppedCount === 1 ? 'exists'   : 'exist';
  const aux  = droppedCount === 1 ? 'isn’t'    : 'aren’t';
  return `(${droppedCount} earlier ${noun} on this drawing ${verb} but ${aux} shown here.)`;
}

function buildUserMessage(config, history, base64Image) {
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
// Phase 5a — JWT validation (ES256 / JWKS)
// =============================================================================
//
// Supabase signs project JWTs with ES256 (ECDSA P-256). Public keys are
// published at <SUPABASE_URL>/auth/v1/.well-known/jwks.json. We fetch + cache
// them at module scope; cache survives across requests within a Worker isolate.
// On `kid` rotation (new signing key Supabase hasn't published before our cache
// expires) we invalidate-and-refetch once before giving up.

const JWKS_TTL_MS = 10 * 60 * 1000;   // 10 minutes per Phase 5a spec
let jwksCache = { keys: null, fetchedAt: 0 };

async function fetchJWKS(env) {
  if (!env.SUPABASE_URL) {
    throw new Error('SUPABASE_URL not configured');
  }
  const url = `${env.SUPABASE_URL}/auth/v1/.well-known/jwks.json`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`JWKS fetch failed: ${res.status}`);
  const body = await res.json();
  if (!Array.isArray(body.keys)) throw new Error('JWKS response missing keys array');
  jwksCache = { keys: body.keys, fetchedAt: Date.now() };
  return body.keys;
}

async function getJWKS(env) {
  const fresh = jwksCache.keys && (Date.now() - jwksCache.fetchedAt) < JWKS_TTL_MS;
  return fresh ? jwksCache.keys : fetchJWKS(env);
}

async function findKeyByKid(kid, env) {
  let keys = await getJWKS(env);
  let key = keys.find((k) => k.kid === kid);
  if (key) return key;
  // Possible key rotation — invalidate cache and try one more time.
  jwksCache = { keys: null, fetchedAt: 0 };
  keys = await getJWKS(env);
  return keys.find((k) => k.kid === kid) ?? null;
}

function base64UrlToBytes(b64u) {
  const pad = '='.repeat((4 - (b64u.length % 4)) % 4);
  const b64 = (b64u + pad).replace(/-/g, '+').replace(/_/g, '/');
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function base64UrlToString(b64u) {
  return new TextDecoder().decode(base64UrlToBytes(b64u));
}

/**
 * Verify a Supabase ES256 JWT against the project's JWKS. Returns the decoded
 * payload on success; throws on any failure (malformed, expired, bad sig,
 * wrong issuer/audience). Callers should treat any thrown error as 401 — we
 * deliberately do NOT surface the reason to the client.
 */
async function validateJWT(token, env) {
  if (!token || typeof token !== 'string') throw new Error('No token');
  const parts = token.split('.');
  if (parts.length !== 3) throw new Error('Malformed JWT');
  const [headerB64, payloadB64, sigB64] = parts;

  const header = JSON.parse(base64UrlToString(headerB64));
  if (header.alg !== 'ES256') throw new Error(`Unexpected alg: ${header.alg}`);
  if (!header.kid) throw new Error('Missing kid');

  const jwk = await findKeyByKid(header.kid, env);
  if (!jwk) throw new Error('No matching kid in JWKS');

  const cryptoKey = await crypto.subtle.importKey(
    'jwk',
    jwk,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['verify'],
  );
  const sig = base64UrlToBytes(sigB64);
  const data = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const ok = await crypto.subtle.verify(
    { name: 'ECDSA', hash: 'SHA-256' },
    cryptoKey,
    sig,
    data,
  );
  if (!ok) throw new Error('Signature invalid');

  const payload = JSON.parse(base64UrlToString(payloadB64));
  const now = Math.floor(Date.now() / 1000);
  if (typeof payload.exp !== 'number' || payload.exp < now) throw new Error('Token expired');
  // SUPABASE_JWT_ISSUER is required — the handler validates env before calling
  // here, so we always have a comparator. Previously this check was skipped
  // when the env var was unset, silently weakening auth on misconfigured deploys.
  if (payload.iss !== env.SUPABASE_JWT_ISSUER) {
    throw new Error('Bad issuer');
  }
  // Tokens with no `aud` claim must fail — `aud && ...` would have permitted
  // a valid-sig forgery missing the claim entirely.
  if (payload.aud !== 'authenticated') {
    throw new Error('Bad audience');
  }
  if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
    throw new Error('Missing sub');
  }
  return payload;
}

/**
 * Returns null if all required env config is present; else returns a string
 * describing the missing piece. Run at the top of the fetch handler before
 * any auth or KV work so a misconfigured deploy fails fast and visibly
 * rather than degrading silently. Add new required env keys here.
 */
function validateWorkerConfig(env) {
  if (!env || typeof env !== 'object') {
    return 'Server misconfigured: env missing.';
  }
  if (!env.SUPABASE_JWT_ISSUER) {
    return 'Server misconfigured: SUPABASE_JWT_ISSUER missing.';
  }
  return null;
}

// =============================================================================
// Phase 5b — request validation
// =============================================================================

const MAX_IMAGE_BASE64_BYTES = 8 * 1024 * 1024; // 8 MB of base64 chars (~6 MB binary)

/**
 * Returns 'jpeg' | 'png' | false. Validates payload size + magic bytes; does
 * not fully validate the image (we trust GPT-4o Vision to handle malformed
 * pixels without burning tokens — we just block obvious junk + oversized junk).
 */
function validateImagePayload(base64) {
  if (typeof base64 !== 'string' || base64.length === 0) return false;
  if (base64.length > MAX_IMAGE_BASE64_BYTES) return false;
  let head;
  try {
    head = atob(base64.slice(0, 16));
  } catch {
    return false;
  }
  if (head.length < 4) return false;
  const b0 = head.charCodeAt(0);
  const b1 = head.charCodeAt(1);
  const b2 = head.charCodeAt(2);
  const b3 = head.charCodeAt(3);
  // JPEG: FF D8 FF (next byte varies — E0/E1/DB/etc.)
  if (b0 === 0xff && b1 === 0xd8 && b2 === 0xff) return 'jpeg';
  // PNG: 89 50 4E 47
  if (b0 === 0x89 && b1 === 0x50 && b2 === 0x4e && b3 === 0x47) return 'png';
  return false;
}

const CONTEXT_STRING_FIELDS = [
  'skillLevel',
  'subject',
  'style',
  'artists',
  'techniques',
  'focus',
  'additionalContext',
  'preset_id',
];

// Per-field length caps. Closes a cost-amplification path: the unbounded
// strings would otherwise flow straight into the prompt, inflating prompt
// tokens × every-request × every-user. Sizes match realistic UI inputs:
// short labels (200), comma-separated artist list (500), free-form notes
// (2000). preset_id is a short identifier — `custom:<uuid>` is 43 chars,
// 50 leaves headroom for any future preset namespace.
const CONTEXT_FIELD_MAX_LENGTHS = {
  skillLevel: 200,
  subject: 200,
  style: 200,
  artists: 500,
  techniques: 200,
  focus: 200,
  additionalContext: 2000,
  preset_id: 50,
};

function validateContext(context) {
  if (!context || typeof context !== 'object' || Array.isArray(context)) return false;
  for (const key of CONTEXT_STRING_FIELDS) {
    if (key in context && typeof context[key] !== 'string') return false;
  }
  return true;
}

/**
 * Returns null if every present string field is within its length cap; else
 * returns { field, max, length } describing the first violation. Run AFTER
 * validateContext (which guarantees fields are strings when present), so this
 * function only checks length, not type.
 */
function validateContextLengths(context) {
  if (!context || typeof context !== 'object') return null;
  for (const [key, max] of Object.entries(CONTEXT_FIELD_MAX_LENGTHS)) {
    const val = context[key];
    if (typeof val === 'string' && val.length > max) {
      return { field: key, max, length: val.length };
    }
  }
  return null;
}

/**
 * Returns true iff a row exists in `drawings` with the given id AND user_id.
 * Uses the service_role key so RLS is bypassed — we're enforcing scope
 * ourselves via the WHERE clause, which is what we want for ownership checks
 * (we already know the user from a validated JWT).
 */
async function verifyDrawingOwnership(userId, drawingId, env) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) return false;
  const url = `${env.SUPABASE_URL}/rest/v1/drawings`
    + `?id=eq.${encodeURIComponent(drawingId)}`
    + `&user_id=eq.${encodeURIComponent(userId)}`
    + `&select=id&limit=1`;
  const res = await fetch(url, {
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      Accept: 'application/json',
    },
  });
  if (!res.ok) {
    console.log('[ownership] supabase non-ok status', res.status);
    return false;
  }
  const rows = await res.json();
  return Array.isArray(rows) && rows.length > 0;
}

// =============================================================================
// Tier + history (replaces the Phase 1 stubs)
// =============================================================================

/**
 * Reads tier + Pro overrides from a validated JWT payload's app_metadata.
 * Default: free tier with no styleModifier. Synchronous because everything
 * comes from the JWT we already have in hand.
 */
function getUserTier(payload) {
  const tier = payload?.app_metadata?.tier === 'pro' ? 'pro' : 'free';
  const promptPreferences = payload?.app_metadata?.prompt_preferences ?? null;
  return { tier, promptPreferences };
}

/**
 * Pulls the critique_history jsonb array AND the current preset_id for the
 * given drawing id. Returns { history, presetId }. Used so the iterative-
 * coaching prompt has prior critiques to reference, and so the handler can
 * decide whether to write through a new preset_id (only on change). Returns
 * { history: [], presetId: DEFAULT_PRESET_ID } on any failure — feedback
 * will still generate, just without history context.
 */
async function fetchCritiqueHistory(drawingId, env) {
  const empty = { history: [], presetId: DEFAULT_PRESET_ID };
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) return empty;
  const url = `${env.SUPABASE_URL}/rest/v1/drawings`
    + `?id=eq.${encodeURIComponent(drawingId)}`
    + `&select=critique_history,preset_id&limit=1`;
  const res = await fetch(url, {
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      Accept: 'application/json',
    },
  });
  if (!res.ok) return empty;
  const rows = await res.json();
  const row = rows?.[0];
  return {
    history: Array.isArray(row?.critique_history) ? row.critique_history : [],
    presetId: typeof row?.preset_id === 'string' ? row.preset_id : DEFAULT_PRESET_ID,
  };
}

// =============================================================================
// Phase 5c — rate limiting + cost ceilings
// =============================================================================
//
// Three KV-backed gates run in front of the OpenAI call, plus one anomaly
// counter that runs behind it:
//
//   quota:<user_id>:<utc-day>       daily counter, 48h TTL  → tier.perDay
//   rate:<user_id>                  rolling window of timestamps, 120s TTL → tier.perMinute
//   ip:<sha256(ip)>:<utc-hour>      per-IP counter, 1h TTL  → IP_HOURLY_CAP
//   hourly:<user_id>:<utc-hour>     anomaly counter, 2h TTL → 5× tier.perDay fires alert
//
// Daily quota counts *delivered* critiques (incremented after OpenAI success).
// Per-minute + per-IP record the *attempt* before OpenAI so concurrent bursts
// can't slip past the gate while OpenAI is still responding.

const TIER_LIMITS = {
  free: { perMinute: 5,  perDay: 20  },
  pro:  { perMinute: 15, perDay: 200 },
};
const IP_HOURLY_CAP = 100;
const ANOMALY_MULTIPLIER = 5;

function utcDayKey(now) {
  const d = new Date(now);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, '0');
  const day = String(d.getUTCDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

function utcHourKey(now) {
  const d = new Date(now);
  const h = String(d.getUTCHours()).padStart(2, '0');
  return `${utcDayKey(now)}T${h}`;
}

function secondsUntilNextUtcMidnight(now) {
  const d = new Date(now);
  const next = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1);
  return Math.max(1, Math.ceil((next - now) / 1000));
}

function formatDuration(seconds) {
  if (seconds < 60) return `${seconds}s`;
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (h > 0 && m > 0) return `${h}h ${m}m`;
  if (h > 0) return `${h}h`;
  return `${m}m`;
}

async function sha256Hex(input) {
  const buf = new TextEncoder().encode(input);
  const hash = await crypto.subtle.digest('SHA-256', buf);
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function dailyMessage(tier, limit, retryAfterSeconds) {
  const reset = formatDuration(retryAfterSeconds);
  if (tier === 'pro') {
    return `You've reached the Pro tier limit of ${limit} critiques today. Your quota resets at midnight UTC (in ${reset}).`;
  }
  const proLimit = TIER_LIMITS.pro.perDay;
  return `You've reached the free tier limit of ${limit} critiques today. Your quota resets at midnight UTC (in ${reset}). Upgrade to Pro for ${proLimit} critiques per day.`;
}

function perMinuteMessage(retryAfterSeconds) {
  return `Slow down a moment — you're sending requests too quickly. Try again in ${formatDuration(retryAfterSeconds)}.`;
}

function ipMessage() {
  return 'Too many requests from your network. Please try again in about an hour.';
}

/**
 * Reads the three rate-limit counters and either rejects with a 429 decision
 * or records the attempt (per-minute + per-IP) and returns a ctx for the
 * post-OpenAI daily increment. KV is eventually consistent — under high
 * concurrency a small overshoot is possible; that's acceptable for a soft
 * rate limit and the per-IP backstop bounds the worst case.
 */
async function enforceRateLimits({ env, userId, ip, tier, now }) {
  const limits = TIER_LIMITS[tier] ?? TIER_LIMITS.free;
  const dayKey = utcDayKey(now);
  const hourKey = utcHourKey(now);
  const ipHash = await sha256Hex(ip || 'unknown');

  const dailyKey   = `quota:${userId}:${dayKey}`;
  const minuteKey  = `rate:${userId}`;
  const ipKey      = `ip:${ipHash}:${hourKey}`;

  const [dailyRaw, minuteRaw, ipRaw] = await Promise.all([
    env.QUOTA_KV.get(dailyKey),
    env.QUOTA_KV.get(minuteKey),
    env.QUOTA_KV.get(ipKey),
  ]);

  const dailyCount = parseInt(dailyRaw ?? '0', 10) || 0;
  if (dailyCount >= limits.perDay) {
    const retryAfter = secondsUntilNextUtcMidnight(now);
    return {
      ok: false,
      status: 429,
      body: {
        error: 'quota_exceeded',
        scope: 'daily',
        tier,
        limit: limits.perDay,
        used: dailyCount,
        retryAfter,
        message: dailyMessage(tier, limits.perDay, retryAfter),
      },
    };
  }

  let recent = [];
  if (minuteRaw) {
    try {
      const parsed = JSON.parse(minuteRaw);
      if (Array.isArray(parsed)) {
        recent = parsed.filter((t) => typeof t === 'number' && now - t < 60_000);
      }
    } catch {
      recent = [];
    }
  }
  if (recent.length >= limits.perMinute) {
    const oldest = Math.min(...recent);
    const retryAfter = Math.max(1, Math.ceil((60_000 - (now - oldest)) / 1000));
    return {
      ok: false,
      status: 429,
      body: {
        error: 'rate_limited',
        scope: 'minute',
        tier,
        limit: limits.perMinute,
        used: recent.length,
        retryAfter,
        message: perMinuteMessage(retryAfter),
      },
    };
  }

  const ipCount = parseInt(ipRaw ?? '0', 10) || 0;
  if (ipCount >= IP_HOURLY_CAP) {
    return {
      ok: false,
      status: 429,
      body: {
        error: 'ip_rate_limited',
        scope: 'ip',
        limit: IP_HOURLY_CAP,
        used: ipCount,
        retryAfter: 3600,
        message: ipMessage(),
      },
    };
  }

  // All gates passed — record the attempt against per-minute + per-IP now so
  // concurrent requests in flight see the bump. Daily is incremented later,
  // only on OpenAI success.
  await Promise.all([
    env.QUOTA_KV.put(minuteKey, JSON.stringify([...recent, now]), { expirationTtl: 120 }),
    env.QUOTA_KV.put(ipKey, String(ipCount + 1), { expirationTtl: 3600 }),
  ]);

  return { ok: true, ctx: { dailyKey, dailyCount, tier, userId, hourKey, limits } };
}

/**
 * Increments the daily quota counter and the hourly anomaly counter. Called
 * AFTER a successful OpenAI response — failed requests don't burn quota. If
 * the hourly counter crosses 5× the daily quota on this request (and only on
 * the transition, not on subsequent requests in the same window) fires the
 * webhook or falls back to console.error.
 */
async function recordSuccessfulCritique({ env, ctx, now }) {
  const { dailyKey, dailyCount, tier, userId, hourKey, limits } = ctx;
  const newDaily = dailyCount + 1;

  const anomalyKey = `hourly:${userId}:${hourKey}`;
  const prevHourlyRaw = await env.QUOTA_KV.get(anomalyKey);
  const prevHourly = parseInt(prevHourlyRaw ?? '0', 10) || 0;
  const newHourly = prevHourly + 1;

  await Promise.all([
    env.QUOTA_KV.put(dailyKey, String(newDaily), { expirationTtl: 48 * 3600 }),
    env.QUOTA_KV.put(anomalyKey, String(newHourly), { expirationTtl: 2 * 3600 }),
  ]);

  const threshold = limits.perDay * ANOMALY_MULTIPLIER;
  if (prevHourly < threshold && newHourly >= threshold) {
    const payload = {
      user_id: userId,
      tier,
      count: newHourly,
      limit: limits.perDay,
      window: hourKey,
      timestamp: new Date(now).toISOString(),
    };
    if (env.ANOMALY_ALERT_WEBHOOK) {
      try {
        await fetch(env.ANOMALY_ALERT_WEBHOOK, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload),
        });
      } catch (err) {
        console.error('[anomaly] webhook fetch failed', err?.message);
      }
    } else {
      console.error('[anomaly] threshold crossed (no webhook configured)', payload);
    }
  }
}

// =============================================================================
// Phase 5d — server-side persistence + idempotency
// =============================================================================
//
// After OpenAI returns a critique, the Worker (not the client) appends the
// entry to drawings.critique_history via a security-definer Postgres function
// `append_critique(uuid, jsonb)`. The function does an atomic
// `critique_history || jsonb_build_array($entry)` so concurrent writes
// linearize without a SELECT-then-UPDATE race.
//
// Idempotency: every request carries a client-generated UUID
// `client_request_id`. The first response is cached at
// `idempotency:<user_id>:<client_request_id>` for 1h. Replays return the same
// body verbatim with `X-Idempotent-Replay: 1`, do not call OpenAI, do not
// write to Postgres, do not increment quota.
//
// Failure modes:
//   - OpenAI fails → 502, no quota burn, no Postgres write, no cache.
//   - Postgres write fails after OpenAI succeeded → user still gets the
//     critique (graceful degradation), orphan logged via console.error,
//     quota IS counted (the OpenAI cost was real), idempotency cache IS
//     written (so the same request_id won't double-spend).

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function isValidClientRequestId(s) {
  return typeof s === 'string' && UUID_RE.test(s);
}

/**
 * Format check for preset_id. Accepts the four hardcoded preset IDs or a
 * `custom:<uuid>` reference. Pure function — no DB hit. Ownership of a
 * custom prompt is verified later by resolvePresetId.
 */
function isValidPresetId(presetIdInput) {
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
async function resolvePresetId(presetIdInput, userId, env, fetcher = fetch) {
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
async function selectVoice(presetId, userId, env, fetcher = fetch) {
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

/**
 * PATCH drawings.preset_id when it differs from what's currently on the row.
 * Caller decides whether to invoke based on the comparison; this helper
 * just does the write. fetcher is dependency-injected for tests.
 */
async function updateDrawingPresetId({ env, drawingId, presetId, fetcher = fetch }) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('updateDrawingPresetId env not configured');
  }
  const url = `${env.SUPABASE_URL}/rest/v1/drawings?id=eq.${encodeURIComponent(drawingId)}`;
  const res = await fetcher(url, {
    method: 'PATCH',
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      'Content-Type': 'application/json',
      Prefer: 'return=minimal',
    },
    body: JSON.stringify({ preset_id: presetId }),
  });
  if (!res.ok) throw new Error(`updateDrawingPresetId HTTP ${res.status}`);
}

/**
 * PATCH user_preferences.preferred_preset_id. The signup trigger guarantees
 * the row exists; if the trigger ever fails to seed it, the PATCH 404s, the
 * caller logs, and the user-facing critique still succeeds (graceful
 * degradation). The "ensure a row exists" responsibility belongs to the
 * trigger, not the request path.
 */
async function updateUserPreferredPreset({ env, userId, presetId, fetcher = fetch }) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('updateUserPreferredPreset env not configured');
  }
  const url = `${env.SUPABASE_URL}/rest/v1/user_preferences?user_id=eq.${encodeURIComponent(userId)}`;
  const res = await fetcher(url, {
    method: 'PATCH',
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      'Content-Type': 'application/json',
      Prefer: 'return=minimal',
    },
    body: JSON.stringify({ preferred_preset_id: presetId }),
  });
  if (!res.ok) throw new Error(`updateUserPreferredPreset HTTP ${res.status}`);
}

async function checkIdempotency({ env, userId, clientRequestId }) {
  const key = `idempotency:${userId}:${clientRequestId}`;
  const raw = await env.QUOTA_KV.get(key);
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

async function recordIdempotent({ env, userId, clientRequestId, body }) {
  const key = `idempotency:${userId}:${clientRequestId}`;
  await env.QUOTA_KV.put(key, JSON.stringify(body), { expirationTtl: 3600 });
}

function buildCritiqueEntry({ feedback, sequenceNumber, config, tier, usage, now, presetId }) {
  return {
    sequence_number: sequenceNumber,
    // preset_id sits at the top level (not inside prompt_config) because it
    // identifies the voice that produced the row, not a prompt-shaping knob.
    // Future analytics queries are cleaner this way.
    preset_id: presetId ?? DEFAULT_PRESET_ID,
    content: feedback,
    prompt_config: {
      tier,
      includeHistoryCount: config.includeHistoryCount,
      styleModifier: config.styleModifier ?? null,
    },
    prompt_token_count: usage?.prompt_tokens ?? 0,
    completion_token_count: usage?.completion_tokens ?? 0,
    created_at: new Date(now).toISOString(),
  };
}

/**
 * Atomically append a critique entry to drawings.critique_history. fetcher is
 * dependency-injected so tests can stub the Postgres call without touching
 * globalThis.fetch.
 */
async function persistCritique({ env, drawingId, entry, fetcher = fetch }) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('persistCritique env not configured');
  }
  const url = `${env.SUPABASE_URL}/rest/v1/rpc/append_critique`;
  const res = await fetcher(url, {
    method: 'POST',
    headers: {
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ p_drawing_id: drawingId, p_entry: entry }),
  });
  if (!res.ok) throw new Error(`append_critique HTTP ${res.status}`);
}

// =============================================================================
// Phase 5e — request logging
// =============================================================================
//
// One row per request hitting a terminal state lands in
// public.feedback_requests via service_role insert. Logging is non-blocking
// (callers wrap in ctx.waitUntil) and non-load-bearing — a logging failure
// must never break the user-facing flow. RLS hides null-user_id (auth_failed)
// rows from authenticated reads; only service_role sees them.
//
// Status semantics (canonical set, document changes here AND in the auth plan):
//   success            — critique returned and persisted to drawings.critique_history
//   quota_exceeded     — 429 daily / per-minute / per-IP limit hit
//   auth_failed        — 401 invalid or missing JWT
//   validation_failed  — 400 malformed body, image, context, or client_request_id
//   ownership_denied   — 403 drawing doesn't belong to the JWT's user
//   model_error        — 502 OpenAI returned non-ok or empty completion
//   internal_error     — 500 Worker bug / KV failure / anything that's *our* fault
//                        (kept distinct from model_error so abuse-detection
//                         queries don't conflate "OpenAI hiccup" with "our bug")
//   idempotent_replay  — 200 served from idempotency cache (still logged so
//                        repeat-pattern analytics can see it)
//   persistence_orphan — OpenAI succeeded, append_critique RPC failed.
//                        Token counts populated; user got the critique.

const REQUEST_STATUS = Object.freeze({
  SUCCESS:            'success',
  QUOTA_EXCEEDED:     'quota_exceeded',
  AUTH_FAILED:        'auth_failed',
  VALIDATION_FAILED:  'validation_failed',
  OWNERSHIP_DENIED:   'ownership_denied',
  MODEL_ERROR:        'model_error',
  INTERNAL_ERROR:     'internal_error',
  IDEMPOTENT_REPLAY:  'idempotent_replay',
  PERSISTENCE_ORPHAN: 'persistence_orphan',
});

/**
 * Insert one row into feedback_requests. Non-blocking by design: callers
 * pass this Promise to ctx.waitUntil(). Wrapped in try/catch — a logging
 * failure must never propagate to the user response. fetcher is dependency-
 * injected so tests can stub without globals.
 */
async function logRequest({
  env,
  status,
  userId = null,
  drawingId = null,
  ipHash = null,
  promptTokens = null,
  completionTokens = null,
  fetcher = fetch,
}) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) return;
  try {
    const res = await fetcher(`${env.SUPABASE_URL}/rest/v1/feedback_requests`, {
      method: 'POST',
      headers: {
        apikey: env.SUPABASE_SERVICE_ROLE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
        'Content-Type': 'application/json',
        Prefer: 'return=minimal',
      },
      body: JSON.stringify({
        user_id: userId,
        drawing_id: drawingId,
        status,
        prompt_token_count: promptTokens,
        completion_token_count: completionTokens,
        client_ip_hash: ipHash,
      }),
    });
    if (!res.ok) console.error('[log] feedback_requests non-ok', res.status);
  } catch (err) {
    console.error('[log] feedback_requests threw', err?.message);
  }
}

// =============================================================================
// OpenAI request tunables
// =============================================================================
//
// Per-request knobs for the chat completion. All four apply in the body of the
// fetch at the bottom of the handler.
//   - model: extracted to a constant so we can A/B different OpenAI models
//     without touching the request body. Currently gpt-5.1 (mid-tier, Nov
//     2025). An earlier gpt-5.1 attempt returned 400 from OpenAI and was
//     rolled back; permanent error-body logging is now in place (in the
//     fetch handler) so any recurrence surfaces in Cloudflare logs.
//   - temperature 0.4 reduces non-determinism without making output robotic.
//     OpenAI's default is 1.0, which combined with no seed produces
//     contradictory Focus Areas across replays of the same drawing state.
//   - seed is best-effort on OpenAI's side — not a guarantee of identical
//     outputs, but with reduced temperature it makes replays meaningfully
//     more stable for debugging and a more consistent student experience.
//   - reasoning effort: passed as a flat `reasoning_effort` field on the
//     /v1/chat/completions request body (NOT the nested `reasoning: { effort }`
//     shape — that's the /v1/responses endpoint's API. An earlier attempt
//     used the nested form and OpenAI 400'd with "Unknown parameter:
//     'reasoning'"; the rename plus the documented-value swap below fixes
//     it). Default is 'minimal' — the cheapest documented gpt-5 value,
//     meaning "do as little reasoning as possible." 'low' / 'medium' /
//     'high' enable reasoning at additional cost.
//
// The request also forwards the authenticated Supabase user id as the
// `user` field on the request body — OpenAI uses this for their own abuse
// detection. Free signal, set inline at the call site since it varies.

const OPENAI_MODEL = 'gpt-5.1';
const OPENAI_TEMPERATURE = 0.4;
const OPENAI_SEED = 42;
const OPENAI_REASONING_EFFORT = 'minimal';

// Preset voices the Worker swaps into the system prompt per request.
// Resolution flow: validateContext (format) → resolvePresetId (ownership)
// → selectVoice (body fetch for custom:<uuid>, lookup for hardcoded). On
// any failure during selectVoice, falls back to VOICE_STUDIO_MENTOR with
// logged error so the user still gets a critique.
const VALID_PRESET_IDS = Object.freeze(new Set([
  'studio_mentor',
  'the_crit',
  'fundamentals_coach',
  'renaissance_master',
]));

const DEFAULT_PRESET_ID = 'studio_mentor';
const CUSTOM_PROMPT_PREFIX = 'custom:';
const CUSTOM_PROMPT_PREFIX_LEN = CUSTOM_PROMPT_PREFIX.length;

// Hard provider-level daily spend ceiling enforced at the Worker before any
// OpenAI call. Fail-closes with 503 once exceeded, until UTC midnight rolls
// the day key over. Sized for TestFlight; revisit upward as user volume grows.
// This is a HARD ceiling, not a per-user limit — see TIER_LIMITS for those.
const DAILY_SPEND_CAP_USD = 5.00;

// Approximate per-token rates for cost computation. Kept as a flat pair
// because we run on a single model at a time. When OPENAI_MODEL changes,
// update these to match the new model's published rates.
const COST_PER_INPUT_TOKEN_USD = 0.63 / 1_000_000;   // gpt-5.1
const COST_PER_OUTPUT_TOKEN_USD = 5.00 / 1_000_000;  // gpt-5.1

function computeRequestCost(usage) {
  const inputTokens = usage?.prompt_tokens ?? 0;
  const outputTokens = usage?.completion_tokens ?? 0;
  return inputTokens * COST_PER_INPUT_TOKEN_USD + outputTokens * COST_PER_OUTPUT_TOKEN_USD;
}

async function getDailySpend(env, dayKey) {
  if (!env.QUOTA_KV) return 0;
  const raw = await env.QUOTA_KV.get(`daily_spend:${dayKey}`);
  const parsed = parseFloat(raw ?? '0');
  return Number.isFinite(parsed) ? parsed : 0;
}

async function incrementDailySpend(env, dayKey, amountUsd) {
  // Read-modify-write — small undercount possible under concurrent writes.
  // Acceptable for a daily ceiling at TestFlight scale; the per-IP and
  // per-user rate limits ahead of this gate bound the realistic concurrency.
  // 48h TTL prevents stale day-keys from accumulating in KV.
  if (!env.QUOTA_KV) return amountUsd;
  const current = await getDailySpend(env, dayKey);
  const next = current + amountUsd;
  await env.QUOTA_KV.put(`daily_spend:${dayKey}`, String(next), { expirationTtl: 48 * 3600 });
  return next;
}

// =============================================================================
// HTTP scaffolding
// =============================================================================

// CORS locked to the production web origin. The iOS app is the primary
// client and doesn't trigger CORS, so this only matters for browser callers.
// Previously '*', which let any origin call the endpoint with a stolen JWT.
// If localhost or another origin needs access later, add it here — the cost
// of plurality is one extra header value, not architectural.
const CORS_HEADERS = {
  'Access-Control-Allow-Origin': 'https://drawevolve.com',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

function jsonResponse(body, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS, ...extraHeaders },
  });
}

function unauthorized() {
  // No body — don't leak which routes exist or why the JWT was rejected.
  return new Response(null, { status: 401, headers: CORS_HEADERS });
}

export default {
  async fetch(request, env, ctx) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: CORS_HEADERS });
    }
    if (request.method !== 'POST') {
      return jsonResponse({ error: 'Method not allowed' }, 405);
    }

    // Fail fast on missing required env. Previously SUPABASE_JWT_ISSUER was
    // silently optional in validateJWT, which meant a misconfigured deploy
    // would weaken auth without anyone noticing. Now we 500 visibly.
    const configErr = validateWorkerConfig(env);
    if (configErr) {
      console.error('[config]', configErr);
      return jsonResponse({ error: configErr }, 500);
    }

    // Phase 5e — capture IP up front so auth_failed / validation_failed
    // logs have ipHash even when no other request context is available.
    const ip = request.headers.get('CF-Connecting-IP') ?? '';
    const ipHash = await sha256Hex(ip || 'unknown');

    // Phase 5a — auth gate. Anything other than a valid Supabase JWT → 401.
    const token = request.headers.get('Authorization')?.replace(/^Bearer\s+/i, '') ?? null;
    let payload;
    try {
      payload = await validateJWT(token, env);
    } catch (err) {
      // Both signals: console for live wrangler tail debugging, table row
      // for retrospective analysis. Different audiences, different lifetimes.
      console.log('[fetch] JWT validation failed', err?.message);
      ctx.waitUntil(logRequest({ env, status: REQUEST_STATUS.AUTH_FAILED, ipHash }));
      return unauthorized();
    }
    const userId = payload.sub; // Supabase auth.uid() is always lowercase.

    let drawingIdLower = null; // available to the catch block once parsed
    try {
      const body = await request.json().catch(() => null);
      if (!body || typeof body !== 'object') {
        ctx.waitUntil(logRequest({ env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, ipHash }));
        return jsonResponse({ error: 'Invalid request body' }, 400);
      }

      const { image, context, drawingId, client_request_id: clientRequestIdRaw } = body;

      // Phase 5b — request validation. Cheap checks first; ownership query last.
      if (typeof drawingId !== 'string' || drawingId.length === 0) {
        ctx.waitUntil(logRequest({ env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, ipHash }));
        return jsonResponse({ error: 'Missing drawing_id' }, 400);
      }
      drawingIdLower = drawingId.toLowerCase(); // pattern compliance from Phase 3

      // Phase 5d — idempotency gate. Validates the request id format and short-
      // circuits replays before image validation / rate limits / OpenAI. A
      // cached hit returns the original response verbatim and never burns
      // quota again.
      if (typeof clientRequestIdRaw !== 'string') {
        ctx.waitUntil(logRequest({
          env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, drawingId: drawingIdLower, ipHash,
        }));
        return jsonResponse({ error: 'Missing client_request_id' }, 400);
      }
      const clientRequestId = clientRequestIdRaw.toLowerCase();
      if (!isValidClientRequestId(clientRequestId)) {
        ctx.waitUntil(logRequest({
          env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, drawingId: drawingIdLower, ipHash,
        }));
        return jsonResponse({ error: 'Invalid client_request_id' }, 400);
      }
      const cached = await checkIdempotency({ env, userId, clientRequestId });
      if (cached) {
        ctx.waitUntil(logRequest({
          env, status: REQUEST_STATUS.IDEMPOTENT_REPLAY, userId, drawingId: drawingIdLower, ipHash,
        }));
        return jsonResponse(cached, 200, { 'X-Idempotent-Replay': '1' });
      }

      if (!validateImagePayload(image)) {
        ctx.waitUntil(logRequest({
          env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, drawingId: drawingIdLower, ipHash,
        }));
        return jsonResponse({ error: 'Invalid or oversized image payload' }, 400);
      }
      if (!validateContext(context)) {
        ctx.waitUntil(logRequest({
          env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, drawingId: drawingIdLower, ipHash,
        }));
        return jsonResponse({ error: 'Invalid context' }, 400);
      }
      const lengthErr = validateContextLengths(context);
      if (lengthErr) {
        ctx.waitUntil(logRequest({
          env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, drawingId: drawingIdLower, ipHash,
        }));
        return jsonResponse({
          error: `Context field '${lengthErr.field}' exceeds maximum length of ${lengthErr.max} characters.`,
        }, 400);
      }

      // preset_id format check (cheap; defense before rate-limit gate). The
      // ownership check on custom:<uuid> happens later via resolvePresetId.
      if (context?.preset_id !== undefined && !isValidPresetId(context.preset_id)) {
        ctx.waitUntil(logRequest({
          env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, drawingId: drawingIdLower, ipHash,
        }));
        return jsonResponse({ error: 'Invalid preset_id format.' }, 400);
      }

      // set_as_default is a top-level body field (not inside context) — it's
      // a per-request command, not part of the drawing context.
      if (body.set_as_default !== undefined && typeof body.set_as_default !== 'boolean') {
        ctx.waitUntil(logRequest({
          env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, drawingId: drawingIdLower, ipHash,
        }));
        return jsonResponse({ error: 'set_as_default must be a boolean.' }, 400);
      }

      const { tier, promptPreferences } = getUserTier(payload);

      // Phase 5c — rate limits. Run before the ownership query so we don't
      // burn a Postgres call on a request we're about to 429 anyway.
      const now = Date.now();
      const decision = await enforceRateLimits({ env, userId, ip, tier, now });
      if (!decision.ok) {
        ctx.waitUntil(logRequest({
          env, status: REQUEST_STATUS.QUOTA_EXCEEDED, userId, drawingId: drawingIdLower, ipHash,
        }));
        return jsonResponse(decision.body, decision.status, {
          'Retry-After': String(decision.body.retryAfter),
        });
      }

      const owns = await verifyDrawingOwnership(userId, drawingIdLower, env);
      if (!owns) {
        ctx.waitUntil(logRequest({
          env, status: REQUEST_STATUS.OWNERSHIP_DENIED, userId, drawingId: drawingIdLower, ipHash,
        }));
        return jsonResponse({ error: 'Forbidden' }, 403);
      }

      const baseConfig = selectConfig(tier, promptPreferences);
      const { history, presetId: existingPresetId } = await fetchCritiqueHistory(drawingIdLower, env);

      // Resolve preset_id. For custom:<uuid>, this verifies the row exists
      // AND belongs to this user. Hardcoded preset IDs short-circuit
      // without a DB hit.
      let resolvedPresetId;
      try {
        resolvedPresetId = await resolvePresetId(context?.preset_id, userId, env);
      } catch (err) {
        const status = err?.code === 'custom_prompt_not_found' ? 403
                     : err?.code === 'custom_prompt_lookup_failed' ? 502
                     : err?.code === 'config_missing' ? 500
                     : 400;
        ctx.waitUntil(logRequest({
          env, status: REQUEST_STATUS.VALIDATION_FAILED, userId, drawingId: drawingIdLower, ipHash,
        }));
        return jsonResponse({ error: err?.code ?? 'preset_id_resolution_failed' }, status);
      }

      // Select the voice for this request and assemble the system prompt
      // with it. selectVoice falls back to VOICE_STUDIO_MENTOR on any
      // failure with a console.error log; the user always gets a critique.
      const voice = await selectVoice(resolvedPresetId, userId, env);
      const config = { ...baseConfig, systemPrompt: assembleSystemPrompt(voice) };

      const systemPrompt = buildSystemPrompt(config, context ?? {});
      const userContent = buildUserMessage(config, history, image);

      // Pre-flight: enforce the global daily spend cap. Fail-closed before we
      // hit OpenAI's dashboard limit so the failure mode is a graceful 503
      // rather than scattered 429/500s from OpenAI itself. Read-modify-write
      // via KV; small undercounts under high concurrency are acceptable for
      // a hard ceiling at TestFlight scale.
      const todayKey = utcDayKey(now);
      const dailySpend = await getDailySpend(env, todayKey);
      if (dailySpend >= DAILY_SPEND_CAP_USD) {
        console.error('[spend-cap] daily limit hit', {
          spent: dailySpend.toFixed(4),
          cap: DAILY_SPEND_CAP_USD,
          dayKey: todayKey,
        });
        ctx.waitUntil(logRequest({
          env, status: REQUEST_STATUS.QUOTA_EXCEEDED, userId, drawingId: drawingIdLower, ipHash,
        }));
        return jsonResponse({
          error: 'Service temporarily unavailable due to daily limit. Please try again tomorrow.',
        }, 503);
      }

      const response = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${env.OPENAI_API_KEY}`,
        },
        body: JSON.stringify({
          model: OPENAI_MODEL,
          messages: [
            { role: 'system', content: systemPrompt },
            { role: 'user', content: userContent },
          ],
          max_tokens: config.maxOutputTokens,
          temperature: OPENAI_TEMPERATURE,
          seed: OPENAI_SEED,
          reasoning_effort: OPENAI_REASONING_EFFORT,
          user: userId,
        }),
      });

      if (!response.ok) {
        // Permanent diagnostic: surface OpenAI's error body, not just the
        // status code. Future migrations (model swaps, new request fields)
        // benefit from seeing the actual error message. Wrapped in try/catch
        // because response.text() can throw on certain malformed bodies, and
        // logging must never block the user-facing 502.
        let errorBody = '<unavailable>';
        try { errorBody = await response.text(); } catch {}
        console.error('[openai] non-ok status', response.status, 'body:', errorBody);
        ctx.waitUntil(logRequest({
          env, status: REQUEST_STATUS.MODEL_ERROR, userId, drawingId: drawingIdLower, ipHash,
        }));
        return jsonResponse({ error: 'Upstream model error' }, 502);
      }

      const data = await response.json();
      const feedback = data.choices?.[0]?.message?.content;
      if (!feedback) {
        ctx.waitUntil(logRequest({
          env, status: REQUEST_STATUS.MODEL_ERROR, userId, drawingId: drawingIdLower, ipHash,
        }));
        return jsonResponse({ error: 'No feedback generated' }, 502);
      }

      // Phase 5d — persistence. Build the canonical entry, append atomically
      // to drawings.critique_history. Failures are logged but don't block the
      // response: the user gets their critique once even if the row write
      // failed (graceful degradation).
      const sequenceNumber = (Array.isArray(history) ? history.length : 0) + 1;
      const entry = buildCritiqueEntry({
        feedback,
        sequenceNumber,
        config,
        tier,
        usage: data.usage,
        now,
        presetId: resolvedPresetId,
      });
      let persisted = true;
      try {
        await persistCritique({ env, drawingId: drawingIdLower, entry });
      } catch (err) {
        persisted = false;
        console.error('[persistence] orphan critique', {
          drawingId: drawingIdLower,
          userId,
          error: err?.message,
        });
      }

      // Write-through: if the resolved preset_id differs from what's currently
      // on the drawings row, update it. Skip the round-trip when they match
      // (the common case once a user settles on a preset). Fire-and-forget;
      // failure is logged. The critique entry already records the resolved
      // preset_id, so a missed write-through doesn't lose data.
      if (resolvedPresetId !== existingPresetId) {
        updateDrawingPresetId({ env, drawingId: drawingIdLower, presetId: resolvedPresetId }).catch((err) =>
          console.error('[preset] updateDrawingPresetId failed', err?.message),
        );
      }

      // set_as_default flag → user_preferences.preferred_preset_id. Only fires
      // when the request explicitly opts in. Same fire-and-forget shape.
      if (body.set_as_default === true) {
        updateUserPreferredPreset({ env, userId, presetId: resolvedPresetId }).catch((err) =>
          console.error('[preset] updateUserPreferredPreset failed', err?.message),
        );
      }

      // Quota burns only on a delivered critique. Anomaly counter rides along.
      // Don't await — the response shouldn't wait on bookkeeping, and any
      // failure here is logged but doesn't affect the user.
      recordSuccessfulCritique({ env, ctx: decision.ctx, now }).catch((err) =>
        console.error('[quota] recordSuccessfulCritique failed', err?.message),
      );

      // Update the global daily spend total for the cap. Same fire-and-forget
      // shape as recordSuccessfulCritique — failure is logged, never blocks
      // the user response. Computed from THIS request's reported usage.
      const requestCost = computeRequestCost(data.usage);
      incrementDailySpend(env, todayKey, requestCost).catch((err) =>
        console.error('[spend-cap] incrementDailySpend failed', err?.message),
      );

      // Phase 5d — idempotency cache. Stores the body we're about to return so
      // a retry of the same client_request_id within 1h gets the exact same
      // response without re-charging OpenAI.
      const responseBody = { feedback, critique_entry: entry };
      recordIdempotent({ env, userId, clientRequestId, body: responseBody }).catch((err) =>
        console.error('[idempotency] recordIdempotent failed', err?.message),
      );

      // Phase 5e — terminal log. Tokens populated in both branches because
      // OpenAI delivered; status differs based on whether the row write stuck.
      const promptTokens = data.usage?.prompt_tokens ?? null;
      const completionTokens = data.usage?.completion_tokens ?? null;
      ctx.waitUntil(logRequest({
        env,
        status: persisted ? REQUEST_STATUS.SUCCESS : REQUEST_STATUS.PERSISTENCE_ORPHAN,
        userId,
        drawingId: drawingIdLower,
        ipHash,
        promptTokens,
        completionTokens,
      }));

      return jsonResponse(responseBody);
    } catch (error) {
      // INTERNAL_ERROR (Worker bug, KV outage, anything that's *our* fault).
      // Distinct from MODEL_ERROR so abuse-detection queries don't conflate
      // OpenAI hiccups with our own bugs.
      ctx.waitUntil(logRequest({
        env, status: REQUEST_STATUS.INTERNAL_ERROR, userId, drawingId: drawingIdLower, ipHash,
      }));
      // Server-side: full message lands in wrangler tail for debugging.
      // Client-side: generic copy only — never leak KV/JSON-parse/supabase-js
      // stack traces or internal field paths to callers.
      console.error('[fetch] internal error', error?.message);
      return jsonResponse({ error: 'Internal server error' }, 500);
    }
  },
};

// Named exports for unit tests (see test.mjs).
export {
  BASE_SYSTEM_PROMPT,
  VOICE_STUDIO_MENTOR,
  VOICE_THE_CRIT,
  VOICE_FUNDAMENTALS_COACH,
  VOICE_RENAISSANCE_MASTER,
  PRESET_VOICES,
  selectVoice,
  assembleSystemPrompt,
  SHARED_SYSTEM_RULES,
  HISTORY_FRAMING_DEFAULT,
  DEFAULT_FREE_CONFIG,
  DEFAULT_PRO_CONFIG,
  selectConfig,
  buildSystemPrompt,
  buildUserMessage,
  formatHistoryEntries,
  renderTruncationMarker,
  renderSkillCalibration,
  renderContextBlock,
  validateImagePayload,
  validateContext,
  validateContextLengths,
  validateWorkerConfig,
  isValidPresetId,
  resolvePresetId,
  updateDrawingPresetId,
  updateUserPreferredPreset,
  VALID_PRESET_IDS,
  DEFAULT_PRESET_ID,
  CUSTOM_PROMPT_PREFIX,
  getUserTier,
  DAILY_SPEND_CAP_USD,
  computeRequestCost,
  getDailySpend,
  incrementDailySpend,
  TIER_LIMITS,
  IP_HOURLY_CAP,
  ANOMALY_MULTIPLIER,
  utcDayKey,
  utcHourKey,
  secondsUntilNextUtcMidnight,
  sha256Hex,
  enforceRateLimits,
  recordSuccessfulCritique,
  isValidClientRequestId,
  checkIdempotency,
  recordIdempotent,
  buildCritiqueEntry,
  persistCritique,
  REQUEST_STATUS,
  logRequest,
};
