# DrawEvolve Critique Generation — Read-Only Audit

## 1. THE CRITIQUE PROMPT(S)

**Files inspected**
- `cloudflare-worker/lib/prompt.js`
- `cloudflare-worker/routes/feedback.js`

**What I found**
The system prompt is assembled per-request from three layered pieces concatenated together:
1. A **voice** (one of four hardcoded preset voices, OR a user-authored custom prompt body fetched from `custom_prompts.body`, OR studio_mentor as fallback).
2. **`SHARED_SYSTEM_RULES`** — universal rules block including the "iterative coaching" instructions.
3. **Skill calibration** + **CONTEXT block** + **RESPONSE FORMAT** template + optional `styleModifier` (Pro tier) + optional `customPromptModifier` (bounded knobs).

The user-turn prompt is short prose plus the image. The same prompt template fires for every request — there's no separate "first critique vs. follow-up" code path. Iteration is signaled to the model entirely by whether prior critiques are interpolated into the user-turn text.

---

### 1a. The four preset voices (`lib/prompt.js:18-24`)

```javascript
export const VOICE_STUDIO_MENTOR = `You are an art professor giving a one-on-one critique inside the DrawEvolve app. You teach through the elements of art (line, shape, form, value, color, texture, space) and the principles of design (balance, contrast, emphasis, movement, pattern, rhythm, unity, variety). You reach for that vocabulary when it makes the critique clearer, and you use plain language when plain language lands better. You don't lecture — you talk like a professor in a studio, pointing at the work.`;

export const VOICE_THE_CRIT = `You are a working artist running a senior MFA crit inside the DrawEvolve app. You treat the student as a peer with their own intent — someone making artistic choices, not a beginner being shepherded. You ask probing questions about those choices — 'what were you going for in the negative space here?' — alongside making observations, instead of always prescribing what to fix. You're direct and unsoftened: you don't pad criticism with reassurance, and you don't manufacture praise to balance honest observations. But directness is not aggression. You critique the work seriously because you take the student seriously, not to demonstrate rigor. You assume the student came here for honest engagement with their work, and you give them that.`;

export const VOICE_FUNDAMENTALS_COACH = `You are a draftsmanship coach inside the DrawEvolve app. Your conviction is that craft fundamentals — proportion, value structure, perspective, anatomy, line economy, edge control — unlock everything else. Until those are solid, expressive choices are unsupported. You almost always pick a fundamentals issue as the Focus Area, even when expressive choices are also off. You're prescriptive and exercise-oriented: instead of 'consider the composition,' you say 'block out the bounding shapes first, then check the proportions against the reference, then commit to line.' You believe in measurement, in study from observation, in repeating the same exercise until the muscle memory is there. You're warm but unsentimental. Improvement, in your view, is mostly about hours of correct practice — not insight.`;

export const VOICE_RENAISSANCE_MASTER = `You are a master of a Florentine workshop in the year 1503, somehow critiquing a student's drawing through the DrawEvolve app. You speak as though the student is your apprentice. You use period-accurate language — 'thy work,' 'the panel,' 'the master' — without overdoing it; one or two archaic constructions per critique is enough to set the voice. You judge by classical principles: disegno, the discipline of the line, the careful study of anatomy from life and from the antique, the proportions established by Vitruvius and refined by your contemporaries. You compare the student's marks to fresco technique, panel painting, silverpoint, the work of your peers in Florence. You take the work entirely seriously — you do not break the persona to wink at the student. The humor, when it lands, comes from the discipline of the voice, not from jokes.`;
```

### 1b. `SHARED_SYSTEM_RULES` — the universal rules block (`lib/prompt.js:26-88`)

This is the biggest single piece of prompt and contains the iterative-coaching directive. Verbatim:

```javascript
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
```

### 1c. The full system-prompt assembly (`lib/prompt.js:90-92, 193-215`)

```javascript
export function assembleSystemPrompt(voice) {
  return `${voice}\n\n${SHARED_SYSTEM_RULES}`;
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
  if (config.customPromptModifier) {
    const rendered = renderCustomPromptModifier(config.customPromptModifier);
    if (rendered) {
      sections.push(`PROMPT CUSTOMIZATION (per saved prompt):\n${rendered}`);
    }
  }
  return sections.join('\n\n');
}
```

`config.systemPrompt` here equals `assembleSystemPrompt(selectedVoice)` — set by the handler at `routes/feedback.js:666`.

### 1d. Skill calibration (`lib/prompt.js:167-180`)

```javascript
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
```

### 1e. CONTEXT block (`lib/prompt.js:182-191`)

```javascript
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
```

### 1f. RESPONSE FORMAT template (`lib/prompt.js:112-137`)

```javascript
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
```

### 1g. Bounded prompt-customization knobs (`lib/prompt.js:459-523, 575-598`)

Custom prompts are *parameters* now (closed enums), not free text. The Worker maps each enum value to a curated fragment. Eight focus options, four tones, three depths, six techniques. Renders as a `PROMPT CUSTOMIZATION` section appended after `ADDITIONAL STYLE GUIDANCE`.

### 1h. The user-turn prompt (`lib/prompt.js:217-264`)

```javascript
export function formatHistoryEntries(entries) {
  return entries
    .map((entry, i) => {
      const seqNum = typeof entry.sequence_number === 'number' && entry.sequence_number > 0
        ? entry.sequence_number
        : i + 1;
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
```

`config.historyFraming` = `'Prior critiques on this drawing, oldest first:'` (lib/prompt.js:139).

### 1i. Multiple prompts? Summary

There is **one prompt assembly path**. It varies by:
- **Voice** — one of four hardcoded preset voices, or a custom-prompt body, or studio_mentor fallback (selected at `routes/feedback.js:658`).
- **Skill level** — alters the calibration paragraph and the `focusAreaInstruction` substring of the response-format template.
- **Tier** — only changes `includeHistoryCount` (free=2, pro=5), `maxOutputTokens` (1000/1500), and whether `styleModifier` is appended (Pro only).
- **Iteration** — when `history.length > 0`, the user-turn message switches from `'Please critique this drawing.'` to a templated block that injects up to `includeHistoryCount` prior entries. The system-prompt iterative-coaching rules (in `SHARED_SYSTEM_RULES`) are present **on every request whether or not history is included**.
- **Custom-prompt knobs** — appends a `PROMPT CUSTOMIZATION` section.

There is **no separate "first vs. follow-up" prompt** — the only branch is in `buildUserMessage`'s text body.

---

## 2. THE REQUEST SHAPE

**Files inspected**
- `cloudflare-worker/routes/feedback.js`
- `DrawEvolve/DrawEvolve/Services/OpenAIManager.swift`
- `DrawEvolve/DrawEvolve/ViewModels/CanvasStateManager.swift` (image source)

**What I found**
- **Provider**: OpenAI (`https://api.openai.com/v1/chat/completions`).
- **Model**: `gpt-5.1` (a constant; CLAUDE.md notes a prior failed attempt — this one is live).
- **Image**: JPEG, base64-encoded data URL, sent inline as an `image_url` content part. **No client-side resizing** — whatever `CanvasRenderer.exportImage(layers:)` produces (2048² or 4096²) goes through `image.jpegData(compressionQuality: 0.8)` and over the wire. The Worker validates magic bytes and a 8 MB base64 cap, nothing more.
- **Prior context**: yes — server-side. iOS sends only the new image + context; the Worker fetches `drawings.critique_history` and slices `-includeHistoryCount` entries (last 2 free / last 5 pro) into the user-turn text.

### 2a. OpenAI request body (`routes/feedback.js:425-428, 693-713`)

```javascript
const OPENAI_MODEL = 'gpt-5.1';
const OPENAI_TEMPERATURE = 0.4;
const OPENAI_SEED = 42;
const OPENAI_REASONING_EFFORT = 'none';
```

```javascript
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
    max_completion_tokens: config.maxOutputTokens,
    temperature: OPENAI_TEMPERATURE,
    seed: OPENAI_SEED,
    reasoning_effort: OPENAI_REASONING_EFFORT,
    user: userId,
  }),
});
```

- `max_completion_tokens`: 1000 (free) / 1500 (pro). No `max_tokens`, no `response_format`, no tools, no JSON mode.
- `userContent` is the array returned by `buildUserMessage` — `[{type:'text',text:...}, {type:'image_url',image_url:{url:'data:image/jpeg;base64,...'}}]`.
- `user: userId` — Supabase auth.uid forwarded for OpenAI's abuse detection.

### 2b. iOS request shape (`Services/OpenAIManager.swift:124-150`)

```swift
let clientRequestId = UUID().uuidString.lowercased()

let selectedPresetID = UserDefaults.standard.string(forKey: "selectedPresetID") ?? "studio_mentor"

let requestBody: [String: Any] = [
    "image": base64Image,
    "drawingId": drawingId.uuidString.lowercased(),
    "client_request_id": clientRequestId,
    "context": [
        "skillLevel": context.skillLevel,
        "subject": context.subject,
        "style": context.style,
        "artists": context.artists,
        "techniques": context.techniques,
        "focus": context.focus,
        "additionalContext": context.additionalContext,
        "preset_id": selectedPresetID,
    ],
]
```

Image encoding:
```swift
guard let imageData = image.jpegData(compressionQuality: 0.8) else { ... }
let base64Image = imageData.base64EncodedString()
```

### 2c. Prior-context fetch (`routes/feedback.js:181-201, 636`)

```javascript
export async function fetchCritiqueHistory(drawingId, env) {
  const empty = { history: [], presetId: DEFAULT_PRESET_ID };
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) return empty;
  const url = `${env.SUPABASE_URL}/rest/v1/drawings`
    + `?id=eq.${encodeURIComponent(drawingId)}`
    + `&select=critique_history,preset_id&limit=1`;
  const res = await fetch(url, { ... });
  if (!res.ok) return empty;
  const rows = await res.json();
  const row = rows?.[0];
  return {
    history: Array.isArray(row?.critique_history) ? row.critique_history : [],
    presetId: typeof row?.preset_id === 'string' ? row.preset_id : DEFAULT_PRESET_ID,
  };
}
```

```javascript
const { history, presetId: existingPresetId } = await fetchCritiqueHistory(drawingIdLower, env);
```

### 2d. What's NOT sent

- No tool-use / function-calling.
- No `response_format` JSON-mode constraint.
- No stroke count, time spent, canvas size, tool/medium metadata. (`DrawingTool.swift` exists in iOS but its data is not surfaced to the Worker.)
- No prior-drawing history across drawings — context is scoped strictly to the single drawing's `critique_history`.

**Worth flagging**
- The Markdown comment about `OPENAI_REASONING_EFFORT` (`routes/feedback.js:410-419`) and the constant `'none'` are wired to the request body via the flat `reasoning_effort` field. CLAUDE.md mentions the constant is "parked but not wired" — that's stale; it IS wired (line 710).
- Image is sent at full canvas resolution — potentially 4096² JPEG. No resize before encoding.

---

## 3. THE RESPONSE SHAPE

**Files inspected**
- `cloudflare-worker/routes/feedback.js`
- `DrawEvolve/DrawEvolve/Services/OpenAIManager.swift`
- `DrawEvolve/DrawEvolve/Models/CritiqueHistory.swift`

**What I found**
- The model returns **freeform Markdown prose** in the structure dictated by `RESPONSE_FORMAT_TEMPLATE`: `**Quick Take**`, `**What's Working**` (optional), `**Focus Area: ...**`, `**Try This**`, `**💬**`. No JSON, no tool-use shape.
- Nothing is extracted from it post-hoc — no tagging, no severity scoring, no Focus Area parsing. The Markdown blob is stored verbatim under `content` and rendered as-is in iOS.
- No example response is logged or stored anywhere checked-in. The structure is inferable only from the template.

### 3a. Worker parsing (`routes/feedback.js:730-737`)

```javascript
const data = await response.json();
const feedback = data.choices?.[0]?.message?.content;
if (!feedback) {
  ctx.waitUntil(logRequest({
    env, status: REQUEST_STATUS.MODEL_ERROR, userId, drawingId: drawingIdLower, ipHash,
  }));
  return jsonResponse({ error: 'No feedback generated' }, 502);
}
```

The single field `feedback` is the entire Markdown blob. No further parsing.

### 3b. Worker response body to iOS (`routes/feedback.js:811`)

```javascript
const responseBody = { feedback, critique_entry: entry };
```

Where `entry` is the structure built by `buildCritiqueEntry` (see §4).

### 3c. iOS decoding (`Services/OpenAIManager.swift:246-281`)

```swift
guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let feedback = json["feedback"] as? String else {
    let error = OpenAIError.invalidResponse
    CrashReporter.shared.logError(error, context: "OpenAIManager.requestFeedback - Invalid response format")
    throw error
}

var critiqueEntry: CritiqueEntry?
if let entryDict = json["critique_entry"] as? [String: Any],
   let entryData = try? JSONSerialization.data(withJSONObject: entryDict) {
    let decoder = JSONDecoder()
    let isoFractional = ISO8601DateFormatter()
    isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoPlain = ISO8601DateFormatter()
    isoPlain.formatOptions = [.withInternetDateTime]
    decoder.dateDecodingStrategy = .custom { dec in
        let container = try dec.singleValueContainer()
        let str = try container.decode(String.self)
        if let date = isoFractional.date(from: str) { return date }
        if let date = isoPlain.date(from: str) { return date }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unparseable critique_entry date: \(str)"
        )
    }
    critiqueEntry = try? decoder.decode(CritiqueEntry.self, from: entryData)
}

return FeedbackResponse(feedback: feedback, critiqueEntry: critiqueEntry)
```

### 3d. Swift Codable shape (`Models/CritiqueHistory.swift:18-68`)

```swift
struct CritiqueEntry: Codable, Identifiable {
    let id: UUID
    let feedback: String
    let timestamp: Date
    let context: DrawingContext?
    let sequenceNumber: Int?
    let promptConfig: PromptConfigSnapshot?
    let promptTokenCount: Int?
    let completionTokenCount: Int?

    struct PromptConfigSnapshot: Codable, Equatable {
        let tier: String
        let includeHistoryCount: Int
        let styleModifier: String?
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case feedback                                  // legacy iOS-only key
        case content                                   // Phase 5d server key
        case timestamp                                 // legacy iOS-only key
        case createdAt = "created_at"                  // Phase 5d server key
        case context
        case sequenceNumber = "sequence_number"
        case promptConfig = "prompt_config"
        case promptTokenCount = "prompt_token_count"
        case completionTokenCount = "completion_token_count"
    }
    ...
}
```

**Worth flagging**
- `PromptConfigSnapshot` on iOS does NOT include `customPromptModifier`, but the Worker writes that field into `prompt_config` (see §4). On decode, this extra field is silently dropped — no failure, but iOS can't introspect the knobs that produced a critique.
- `preset_id` on the entry is at the top level of the JSONB row (Worker side) but NOT modeled in `CritiqueEntry` Swift. iOS has no way to know which voice produced any specific past critique without re-parsing the raw JSON.

---

## 4. PERSISTENCE

**Files inspected**
- `supabase/migrations/0001_init.sql`
- `supabase/migrations/0002_append_critique_function.sql`
- `supabase/migrations/0005_preset_voices_and_custom_prompts.sql`
- `cloudflare-worker/routes/feedback.js`

### 4a. `drawings` table DDL (`migrations/0001_init.sql:32-42`)

```sql
create table if not exists public.drawings (
    id               uuid primary key default gen_random_uuid(),
    user_id          uuid not null references auth.users(id) on delete cascade,
    title            text not null,
    storage_path     text not null,
    context          jsonb,
    feedback         text,
    critique_history jsonb not null default '[]'::jsonb,
    created_at       timestamptz not null default now(),
    updated_at       timestamptz not null default now()
);
```

`preset_id text not null default 'studio_mentor'` is added in `migrations/0005_preset_voices_and_custom_prompts.sql:125-126`:

```sql
alter table public.drawings
    add column if not exists preset_id text not null default 'studio_mentor';
```

### 4b. The atomic append function (`migrations/0002_append_critique_function.sql:11-26`)

```sql
create or replace function public.append_critique(
  p_drawing_id uuid,
  p_entry jsonb
) returns void
language sql
security definer
set search_path = public
as $$
  update public.drawings
  set critique_history = critique_history || jsonb_build_array(p_entry),
      updated_at = now()
  where id = p_drawing_id;
$$;

revoke all on function public.append_critique(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.append_critique(uuid, jsonb) to service_role;
```

iOS cannot call this — only `service_role` (the Worker) can.

### 4c. The exact JSONB entry the Worker writes (`routes/feedback.js:268-290`)

```javascript
export function buildCritiqueEntry({ feedback, sequenceNumber, config, tier, usage, now, presetId }) {
  return {
    sequence_number: sequenceNumber,
    preset_id: presetId ?? DEFAULT_PRESET_ID,
    content: feedback,
    prompt_config: {
      tier,
      includeHistoryCount: config.includeHistoryCount,
      styleModifier: config.styleModifier ?? null,
      customPromptModifier: config.customPromptModifier ?? null,
    },
    prompt_token_count: usage?.prompt_tokens ?? 0,
    completion_token_count: usage?.completion_tokens ?? 0,
    created_at: new Date(now).toISOString(),
  };
}
```

The whole row is appended as a JSONB element via `persistCritique` (`routes/feedback.js:297-312`):

```javascript
export async function persistCritique({ env, drawingId, entry, fetcher = fetch }) {
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
```

There are **no typed columns for individual critiques** — the entire critique array is a single JSONB column on `drawings`. No separate `critiques` table, no foreign-key relationships.

### 4d. Other tables involved

`feedback_requests` — one log row per request, regardless of outcome. Not the critique itself; the critique text is NOT stored here. Schema (`migrations/0001_init.sql:98-107`):

```sql
create table if not exists public.feedback_requests (
    id                     uuid primary key default gen_random_uuid(),
    user_id                uuid not null references auth.users(id) on delete cascade,
    drawing_id             uuid references public.drawings(id) on delete set null,
    requested_at           timestamptz not null default now(),
    status                 text not null,
    prompt_token_count     int,
    completion_token_count int,
    client_ip_hash         text
);
```

`user_preferences` (`migrations/0005:45-50`) — holds `preferred_preset_id text not null default 'studio_mentor'`.

`custom_prompts` (`migrations/0005:137-144`) — holds user-authored prompt bodies + (per migration 0009) bounded knob parameters.

**Worth flagging for the My Evolution feature**
- All historical critique text is in `drawings.critique_history` JSONB. Querying across drawings (e.g. "show me every Focus Area I've gotten on portraits") requires a JSONB unnest + jsonb_path_query, no schema indexes.
- The Markdown is unparsed prose. Any cross-critique analytics (Focus Area trends, progress, recurring weaknesses) need either post-hoc parsing or schema additions — neither exists today.
- `feedback_requests` token counts give you "how many critiques per day," but the row doesn't carry `preset_id` or any prompt taxonomy.

---

## 5. THE ITERATIVE-CRITIQUE MECHANISM

**Files inspected**
- `cloudflare-worker/lib/prompt.js`
- `cloudflare-worker/routes/feedback.js`

**What I found**
Iteration is implemented via **full-text inclusion of prior critiques in the user-turn message** plus a system-prompt rule. There is no summarization, no embedding-based retrieval, no structured progress tracking.

### 5a. The decision point (`routes/feedback.js:636, 671`)

```javascript
const { history, presetId: existingPresetId } = await fetchCritiqueHistory(drawingIdLower, env);
...
const userContent = buildUserMessage(config, history, image);
```

There is no "is this iteration N" branch. `buildUserMessage` itself decides whether to render the history block based on `history.length > 0` and `config.includeHistoryCount > 0` (lib/prompt.js:250):

```javascript
if (config.includeHistoryCount > 0 && slice.length > 0) {
  ...
  parts.push({
    type: 'text',
    text: `${config.historyFraming}\n\n${truncationBlock}${formatHistoryEntries(slice)}\n\nNow critique the current state of the drawing below.`,
  });
} else {
  parts.push({ type: 'text', text: 'Please critique this drawing.' });
}
```

### 5b. What "prior context" actually contains

Each rendered prior entry (`lib/prompt.js:217-234`):

```
[Critique <N> — <ISO timestamp>]
<full Markdown content of that critique>
```

So if a user is on critique #4 (free tier, `includeHistoryCount=2`), the model sees the full Markdown of critiques #2 and #3, plus a truncation marker noting that #1 exists but isn't shown.

### 5c. Does the model know to evaluate progress?

**Yes, explicitly** — via the `ITERATIVE COACHING — READ THIS CAREFULLY` block in `SHARED_SYSTEM_RULES` (lib/prompt.js:80-88, see §1b). The model is told to identify the prior Focus Area, decide if the student acted on it, and either acknowledge progress (and pick a new Focus Area) or repeat the same Focus Area from a different angle.

CLAUDE.md confirms this lives in `SHARED_SYSTEM_RULES` (system prompt) by design, not in the user-role framing — the placement is load-bearing.

**Worth flagging**
- No structured signal of which Focus Area the prior critique chose. The model has to re-parse the Markdown of `[Critique N]` to find the "Focus Area: ..." line each time. If that line isn't extracted/structured anywhere, the My Evolution view will face the same parsing problem.
- The system rule fires on **every request** (it's static in `SHARED_SYSTEM_RULES`). On a first critique with no prior history, the model is told the iteration rules, sees no prior critiques in the user turn, and produces a fresh critique. Harmless but worth knowing.

---

## 6. WHAT THE PROMPT KNOWS ABOUT THE DRAWING

**Files inspected**
- `cloudflare-worker/lib/prompt.js`
- `DrawEvolve/DrawEvolve/Models/DrawingContext.swift`
- `DrawEvolve/DrawEvolve/Services/OpenAIManager.swift`

### 6a. What the model sees about the drawing

Only what's in `renderContextBlock` (lib/prompt.js:182-191) plus skill calibration plus the image itself:

| Field | Source | Passed to model? | Stored? |
|---|---|---|---|
| `subject` | User-supplied text from pre-drawing questionnaire | **Yes** (always, defaults to "not specified") | Yes — in `drawings.context` jsonb and on each critique entry's `context`-decoding-side |
| `style` | User-supplied text | Yes (only if non-empty) | Yes |
| `artists` (reference artists) | User-supplied text | Yes (only if non-empty) | Yes |
| `techniques` (free-text) | User-supplied text | Yes (only if non-empty) | Yes |
| `focus` ("Student wants feedback on") | User-supplied text | Yes (only if non-empty) | Yes |
| `additionalContext` | User-supplied text | Yes (only if non-empty) | Yes |
| `skillLevel` | User-supplied; defaults to "Intermediate" on iOS | **Yes** (drives `renderSkillCalibration`) | Yes — but iOS default is "Intermediate" while Worker fallback is also "Intermediate" (CLAUDE.md gotcha #4 mentions divergence — it's actually `"Beginner"` on iOS per `DrawingContext.swift:12`) |
| **Tool/medium info** (DrawingTool, brush type, layers, eraser) | iOS canvas state | **NOT passed** | Tool definitions exist in `Models/DrawingTool.swift` but are not surfaced to the Worker |
| **Stroke count / time spent / canvas size** | iOS canvas state | **NOT passed** | **NOT stored** anywhere checked-in |
| **Goals** | Implicit in `focus` field | Yes (as text) | Yes |

### 6b. `DrawingContext` source of truth (`Models/DrawingContext.swift:11-19`)

```swift
struct DrawingContext: Codable {
    var skillLevel: String = "Intermediate"
    var subject: String = ""
    var style: String = ""
    var artists: String = ""
    var techniques: String = ""
    var focus: String = ""
    var additionalContext: String = ""
    ...
}
```

### 6c. Subject matter detection

**Not detected — user-provided** via the `subject` text field. The system prompt's `SUBJECT VERIFICATION — REQUIRED FIRST STEP` block instructs the model to compare what it sees in the image against the user-provided `subject` text. Mismatch handling is done by the model, not by code.

**Worth flagging**
- The image is the only signal the model has about tools, medium, technique, time, effort. The Worker passes nothing else from canvas state. For a "My Evolution" view that wants to plot e.g. "skill_level over time" or "preset over time," skill_level/preset are stored per-critique in `prompt_config.tier` (just the billing tier) and at the top level (`preset_id`); the user's self-described skillLevel is NOT stored in the entry's `prompt_config` snapshot — it's only in the drawing's `context` jsonb (frozen at first save).
- No medium-vs-digital distinction is captured. `techniques` is a free-text user field, not an enum.

---

## 7. THE ENDPOINT

**Files inspected**
- `cloudflare-worker/index.js`
- `cloudflare-worker/routes/feedback.js`
- `DrawEvolve/DrawEvolve/Services/OpenAIManager.swift`

### 7a. Route + method (`index.js:18, 36-87`)

```javascript
import { handleFeedback } from './routes/feedback.js';
...
const POST_ONLY_PATHS = new Set(['/', '/attest/challenge', '/attest/register']);
...
if (pathname === '/') return handleFeedback(request, env, ctx);
```

**`POST /`** is the critique endpoint. (Yes — the root path. No `/feedback` or `/v1/critique`.)

### 7b. Auth/validation gates (in order, `routes/feedback.js:438-633`)

1. `validateWorkerConfig(env)` — fail fast on missing required env (auth.js).
2. **JWT validation** — Bearer Supabase JWT against JWKS (auth.js); 401 on failure.
3. **App Attest assertion** — headers required + key in KV + env match + assertion verify (app-attest.js); distinct 401 codes per failure (`attest_headers_missing`, `attest_key_unknown`, `attest_env_mismatch`, `attest_assertion_invalid`).
4. **Body parse** — JSON parse; 400 on failure.
5. **`drawingId` presence + lowercase** — 400 on missing.
6. **Idempotency** — `client_request_id` present + lowercase UUID format; checks idempotency cache and short-circuits to a cached body if hit.
7. **`validateImagePayload(image)`** — base64 size cap 8 MB + JPEG/PNG magic bytes; 400 on failure.
8. **`validateContext(context)`** — type check on each context field; 400 on failure.
9. **`validateContextLengths(context)`** — per-field length caps (skillLevel/subject/style/techniques/focus 200, artists 500, additionalContext 2000, preset_id 50); 400 on failure.
10. **`isValidPresetId(context.preset_id)`** — format check, 400 on bad format.
11. **`set_as_default` boolean check** — 400 on bad type.
12. **Tier-based rate limits** — `enforceRateLimits`; 429 on exceeded.
13. **Drawing ownership** — `verifyDrawingOwnership(userId, drawingIdLower, env)`; 403 on mismatch.
14. **`resolvePresetId`** — for `custom:<uuid>`, verifies the row exists AND belongs to the user; 403/502/500/400 by error code.
15. **`enforceCostCeilings`** — daily-spend USD cap + per-user daily token cap; 429 on exceeded.

Then the OpenAI call fires. Everything is logged to `feedback_requests` with the appropriate `REQUEST_STATUS` regardless of branch taken.

### 7c. iOS call site (`Services/OpenAIManager.swift:54-59, 89-186`)

```swift
actor OpenAIManager {
    static let shared = OpenAIManager()
    private let backendURL = "https://drawevolve-backend.trevorriggle.workers.dev"
    ...
}
```

```swift
func requestFeedback(image: UIImage, context: DrawingContext, drawingId: UUID) async throws -> FeedbackResponse {
    guard let imageData = image.jpegData(compressionQuality: 0.8) else { ... }
    let base64Image = imageData.base64EncodedString()

    guard let client = SupabaseManager.shared.client else { ... }
    let accessToken: String
    do {
        let session = try await client.auth.session
        accessToken = session.accessToken
    } catch { ... }

    let clientRequestId = UUID().uuidString.lowercased()
    let selectedPresetID = UserDefaults.standard.string(forKey: "selectedPresetID") ?? "studio_mentor"

    let requestBody: [String: Any] = [
        "image": base64Image,
        "drawingId": drawingId.uuidString.lowercased(),
        "client_request_id": clientRequestId,
        "context": [ ... see §2b ... ],
    ]

    guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody),
          let url = URL(string: backendURL) else { ... }

    let attestHeaders: [String: String]
    do {
        attestHeaders = try await AppAttestManager.shared.attestedHeaders(
            method: "POST",
            path: url.path.isEmpty ? "/" : url.path,
            body: jsonData
        )
    } catch { ... }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    for (name, value) in attestHeaders {
        request.setValue(value, forHTTPHeaderField: name)
    }
    request.httpBody = jsonData

    let (data, response) = try await URLSession.shared.data(for: request)
    ...
}
```

Caller chain: `Views/DrawingCanvasView.swift:968-976` → `ViewModels/CanvasStateManager.swift:526-543` → `OpenAIManager.requestFeedback`.

---

## Summary findings worth flagging for the My Evolution build

1. **All critique data lives in `drawings.critique_history` JSONB.** No critique table, no parsed taxonomy. Cross-drawing analytics require JSONB unnest queries.
2. **Critique text is freeform Markdown.** Focus Area, Quick Take, Try This sections are sectioned by `**Header**` Markdown bolds — *not* extracted into typed fields. Anything My Evolution wants to surface (e.g. "your last 5 Focus Areas") needs either prose parsing or a schema/prompt change.
3. **`prompt_config` snapshot stored on each entry omits the user's `skillLevel`.** It records `tier` (billing tier), `includeHistoryCount`, `styleModifier`, `customPromptModifier`. The user-described skill level only lives on the drawing's `context` jsonb (set when the drawing was created).
4. **`preset_id` is on the entry top level** (good for "voice over time" timeline), but **iOS `CritiqueEntry` Swift model doesn't decode it** — so the iOS layer has no field for it without a model change.
5. **No tool/medium/stroke/time signals are captured anywhere.** Time-in-canvas, tool used, stroke counts, layer count — none of it is in iOS storage, Postgres, or the prompt. Adding any of this for My Evolution requires both client instrumentation and schema work.
6. **The iterative-coaching system prompt fires on every request.** No "is this iteration N" branch — the model decides based on what's in the user-turn history block.
7. **`feedback_requests` is the only structured per-request audit log.** Has `status`, `prompt_token_count`, `completion_token_count`, `requested_at`, `drawing_id`. No `preset_id`, no Focus Area, no skill level. Useful for "critiques over time" charts; not useful for content-of-critique trends.
