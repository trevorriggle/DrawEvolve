# DrawEvolve - Pipeline Features & Roadmap

**Last meaningful update of this doc:** 2025-11-06.
**Refreshed against code state:** 2026-05-05 — see "Status snapshot" below.
**Status:** MVP+ complete; auth, layered storage, custom prompts, social Phase A, and My Evolution Phase 1/1b/2 shipped. Phase 3 Evolution UI deferred. Social Phases B–G deferred.

---

## ✅ Status snapshot (2026-05-05)

This roadmap pre-dates a lot of what's now landed. Cross-walking against PRs on `main`:

| Roadmap section | Code state |
|---|---|
| **Phase 1 — Progress Tracking & Evolution** | Backend Phase 1 (critique classifier, PR #15 `af52f58`), Phase 1b (`d788e7a`), Phase 2 (GET `/v1/me/evolution` aggregation, PR #16 `f788e3a`) ✅ shipped. Frontend Phase 3 (Evolution tab UI, charts) ☐ deferred. |
| **Phase 2 — Custom AI Art Teachers** | Bounded-knobs custom prompts (PR #9 `c096546`) ✅ shipped — voice text + parameter knobs. Multi-agent feedback / agent library / sharing ☐ deferred (see CUSTOMPROMPTSPLAN.md §8). |
| **Phase 3 — Social & Community** | Phase A foundations (profiles table + Worker `/v1/me`, `/v1/profiles/*`, PR #10 `f266c5b`) ✅ shipped. Phases B–G (posts, reactions, comments, follows, feeds, search, notifications) ☐ deferred. See ONLINEIMPLEMENTATIONPLANS.md. |
| **Phase 4 — Advanced Drawing Tools** | Largely unchanged. Download to Photos shipped (PR #4 `8fa041f`). |
| **Phase 5 — Monetization** | ☐ Not started. Credit-system design exists in RATELIMITSPLAN.md but is not built. Cost ceilings (provider $/day + per-user tokens/day, PR #7 `e2cae45`) shipped as a backstop. |
| **Phase 6 — Advanced AI Features** | ☐ Not started. |
| **Phase 7 — Portfolio Analysis Pipeline (Agentic System)** | The classifier + aggregation backend (PR #15 / #16) is the foundation; agentic orchestrator not built. |
| **Infrastructure / Auth** | ✅ Shipped — see `authandratelimitingandsecurity.md`. JWT validation (PR #5), App Attest (PR #5), cost ceilings (PR #7), layered cloud sync (PR #12, #14, #17). |

### Stale claims worth flagging

- "Currently basic, needs full implementation" auth section ➜ actually fully shipped (Sign in with Apple + email magic link + Supabase Auth + JWT validation + App Attest).
- "Cloud sync (infrastructure exists, needs full implementation)" ➜ shipped end-to-end (Phase 3 of `authandratelimitingandsecurity.md`).
- References to `TOOL_IMPLEMENTATION_ROADMAP.md` and `toolaudit.md` — those files are not in the repo at root; treat as superseded.
- "8 tools remain unimplemented" — current state per `DrawEvolve, April 27th` Tool Inventory (which is itself dated; see that doc for the actual current state).
- Phase 7 SQL sketch references a `users` table — DrawEvolve uses `auth.users` (Supabase) directly. Use that as the FK target.

The original roadmap text below is preserved; the snapshot above is what's actually true today.

---

## ⚠️ Known Issues (November 2025 — historical)

### Deferred Features
2. **Unimplemented Tools** - 8 tools remain unimplemented (Smudge, Clone Stamp, Move). See `TOOL_IMPLEMENTATION_ROADMAP.md` and `toolaudit.md` for details. *(Both referenced files are not present in the repo as of 2026-05-05.)*
3. **Blur/Sharpen Brush Mode** - Currently apply globally to entire layer instead of brush-based application.

---

## 🎯 Core Philosophy

DrawEvolve isn't just a drawing app with AI feedback - it's a **creative practice platform** where users track their artistic evolution, learn from personalized AI mentors, and share their journey with a community.

---

## ✅ MVP + (Current - EXCEEDS MVP)

### Drawing Engine ✅ MOSTLY COMPLETE
- ✅ Metal-based rendering (60 FPS, GPU-accelerated)
- ✅ Multi-layer system with thumbnails and blend modes
- ✅ **12 Working Tools:**
  - Drawing: Brush, Eraser
  - Shapes: Line, Rectangle, Circle, Polygon
  - Fill/Color: Paint Bucket, Eyedropper
  - Selection: Rectangle Select, Lasso, Magic Wand
  - Effects: Blur (global), Sharpen (global)
  - Utility: Text
- ✅ **Canvas Transforms:** Zoom (0.1x-10x), Pan, and Rotation all working correctly
- ⚠️ **Transform Handles:** Scale and rotate integrated into selection tools (Oct 21, 2025)
- ✅ Undo/redo system with texture snapshots
- ✅ Export to image
- ✅ Pressure sensitivity (Apple Pencil support)

### AI Feedback System ✅ COMPLETE
- ✅ Secure backend proxy (Cloudflare Workers)
- ✅ GPT-4o Vision integration
- ✅ Context-aware feedback (subject, style, artists, techniques, focus areas)
- ✅ Encouraging, constructive tone with personality
- ✅ Markdown formatting in feedback display

### Gallery & Storage ✅ COMPLETE
- ✅ **Gallery View** with grid layout
- ✅ **Drawing Cards** with thumbnails and AI feedback badges
- ✅ **Drawing Detail View** showing full image + context + feedback
- ✅ **Local Storage** via DrawingStorageManager
- ✅ Save/Load/Delete functionality
- ✅ Drawing metadata (title, date, context, feedback)
- ✅ Pull-to-refresh
- ✅ Search/filter ready (infrastructure in place)

### Infrastructure ✅ COMPLETE
- ✅ iOS app (Swift/Metal/SwiftUI)
- ✅ Cloudflare Worker backend
- ✅ OpenAI API integration
- ✅ Professional UI/UX (collapsible toolbar, layer panel, feedback view, gallery)
- ✅ Dark mode support
- ✅ Debug tools (clear all, layer inspection)

**Current Status:** Beyond MVP - approaching Phase 1 territory with gallery + storage complete!

---

## 📊 Phase 1: Progress Tracking & Evolution (The Snapshot System)

**Goal:** Make users addicted to seeing their own improvement

**Status:** 40% Complete (Infrastructure exists, need analytics layer)

### Features
- ✅ **Drawing Snapshots** (COMPLETE)
  - ✅ Capture drawing + AI feedback + user context at point in time
  - ✅ Store metadata: date, title, context, feedback
  - ⚠️ Missing: time spent tracking, tools used stats, iteration linking

- ⚠️ **Progress Timeline** (50% Complete)
  - ✅ Visual grid showing all drawings chronologically
  - ✅ Gallery view with thumbnails
  - ❌ Filter by subject, style, technique (need to implement)
  - ❌ "Before/After" comparison views
  - ❌ Highlight improvement metrics

- ❌ **Evolution Analytics** (Not Started)
  - AI-generated progress summaries: "Your line work has improved 40% since last month"
  - Identify patterns: "You draw more when feedback is positive"
  - Skill radar chart: composition, color theory, anatomy, perspective, etc.
  - Weekly/monthly progress reports

- ❌ **Smart Context Resumption** (Not Started)
  - AI remembers your previous drawings and feedback
  - "Last time you struggled with proportions, let's check if you improved"
  - Personalized challenges based on past work
  - Token optimization: summarize old context instead of full history

### Technical Requirements
- ✅ Snapshot data model (Drawing struct with all metadata)
- ✅ Local storage (DrawingStorageManager)
- ⚠️ Cloud sync (infrastructure exists, needs full implementation)
- ❌ Analytics engine to detect improvement patterns
- ❌ AI summarization for long-term memory

### What's Needed Next:
1. Add filters/search to gallery (subject, style, date range)
2. Build "Before/After" comparison UI
3. Implement analytics engine (skill tracking over time)
4. Add AI-powered progress summaries
5. Track drawing session metadata (time spent, tools used)

**Why This Matters:** Retention. Once someone has 20+ snapshots, they're emotionally invested in their journey.

---

## 🤖 Phase 2: Custom AI Art Teachers (Agents)

**Goal:** Personalization + social sharing + viral growth

### Features
- [ ] **Agent Customization**
  - Create custom AI mentors with unique personalities
  - Choose teaching style: harsh critic, encouraging supporter, technical expert, etc.
  - Select expertise: portraiture, landscapes, abstract, comic art, realism
  - Customize feedback format: bullet points, essays, quick tips
  - Give them names and avatars

- [ ] **Agent Personas (Examples)**
  - "Picasso" - encourages breaking rules, abstract thinking
  - "Bob Ross" - ultra-encouraging, focuses on joy of painting
  - "Da Vinci" - technical precision, anatomy, engineering approach
  - "Miyazaki" - storytelling through art, emotional resonance
  - User-created custom agents

- [ ] **Agent Library**
  - Browse community-created agents
  - Try agents before adopting them
  - Rate agents (which ones give best feedback?)
  - Share your agent with friends
  - **Monetization idea:** Premium agents, user-created paid agents

- [ ] **Multi-Agent Feedback**
  - Get feedback from multiple agents on same drawing
  - Compare different perspectives
  - "Your Picasso agent loved it, but your Da Vinci agent wants better anatomy"

### Technical Requirements
- Prompt engineering system for agent personalities
- Agent data model (name, avatar, personality params, expertise areas)
- Agent sharing/discovery system
- Multi-agent orchestration (parallel API calls with different prompts)

**Why This Matters:** Ownership + creativity + shareability. "Check out my custom agent!" is marketing gold.

---

## 👥 Phase 3: Social & Community Features

**Goal:** Turn solo practice into collaborative growth

### Features
- [ ] **Gallery System**
  - Public/private drawing galleries
  - Tag drawings with skills practiced
  - Like/comment on others' work
  - Follow other artists
  - "Study together" mode: draw same prompt, compare results

- [ ] **Referral System**
  - Refer friends → unlock premium brushes/tools
  - Tiered rewards: 3 friends = new brush set, 10 friends = custom agent slots
  - Shareable referral links with custom landing pages
  - Track who you brought in, celebrate their progress

- [ ] **Challenges & Prompts**
  - Daily/weekly drawing challenges
  - Community voting on best submissions
  - AI-generated prompts based on what you need to practice
  - Collaborative challenges (draw with a partner, agent judges)

- [ ] **Study Groups**
  - Form groups with friends
  - Shared progress tracking
  - Group leaderboards (who practiced most this week?)
  - Peer feedback alongside AI feedback

### Technical Requirements
- User authentication system (currently basic, needs full implementation)
- Social graph (followers, friends)
- Cloud storage for public galleries
- Moderation tools
- Real-time features (comments, likes)
- Notification system

**Why This Matters:** Community = retention + virality. People stay for the friends they made.

---

## 🎨 Phase 4: Advanced Drawing Tools

**Goal:** Professional-grade features for serious artists

### Features
- [ ] **Advanced Brushes**
  - Watercolor simulation
  - Oil paint texture
  - Pencil/charcoal effects
  - Custom brush creation
  - Pressure sensitivity refinements

- [ ] **Color Theory Tools**
  - Color palette suggestions
  - Harmony analyzer
  - Reference image color picker
  - Gradient tools

- [ ] **Perspective & Grid Systems**
  - One/two/three-point perspective grids
  - Rule of thirds overlay
  - Golden ratio guides
  - Symmetry tools

- [ ] **Reference Integration**
  - Import reference photos
  - Side-by-side view while drawing
  - AI-suggested references based on what you're drawing

- [ ] **Animation**
  - Frame-by-frame animation
  - Onion skinning
  - Export to video/GIF
  - AI feedback on animation timing and flow

### Technical Requirements
- Metal shader programming for advanced brushes
- Math for perspective grids
- Image import/overlay system
- Frame management for animation

**Why This Matters:** Keeps advanced users engaged, justifies premium pricing.

---

## 💰 Phase 5: Monetization & Premium Features

**Goal:** Sustainable business model

### Freemium Model
- **Free Tier:**
  - 5 AI feedback requests per week
  - 2 layer limit
  - Basic brushes
  - 1 custom agent
  - Public gallery access

- **Premium Tier ($9.99/month):**
  - Unlimited AI feedback
  - Unlimited layers
  - All brushes and tools
  - 5 custom agents
  - Priority AI response times
  - Export high-res images
  - Advanced analytics
  - Ad-free

- **Pro Tier ($19.99/month):**
  - Everything in Premium
  - Unlimited custom agents
  - Early access to new features
  - API access for agent customization
  - White-label agents (sell your agents to others)
  - Video tutorials and courses

### Alternative Revenue Streams
- [ ] Marketplace for custom agents (creators get revenue share)
- [ ] Premium brushes/tool packs
- [ ] Commissioned AI training (train agent on specific artist's style)
- [ ] Educational partnerships (art schools, online courses)
- [ ] B2B licensing (art therapy, corporate team building)

---

## 🔬 Phase 6: Advanced AI Features

**Goal:** Bleeding-edge AI capabilities that competitors can't match

### Features
- [ ] **Style Transfer Learning**
  - AI learns YOUR personal style over time
  - "Draw like you did last month" mode
  - Style consistency scoring
  - Detect when you're experimenting vs. sticking to comfort zone

- [ ] **Generative Assistance**
  - AI suggests next strokes (not autopilot, just hints)
  - "Complete this sketch for me" study mode
  - Background generation
  - AI-powered corrections (show, don't tell)

- [ ] **Multi-Modal Feedback**
  - Voice feedback (listen while drawing)
  - Video feedback (AI narrates over your drawing)
  - AR feedback (point phone at physical drawing)

- [ ] **Collaborative AI Drawing**
  - Draw with AI in real-time
  - "You do the sketch, AI does the shading"
  - Training mode: AI draws, you copy, AI gives feedback

### Technical Requirements
- Fine-tuning AI models on user data
- Real-time AI inference (low latency)
- Multi-modal AI APIs (text, voice, video)
- Privacy/security for user data in training

**Why This Matters:** Defensibility. Hard to copy, proprietary data moat.

---

## 🛠 Infrastructure & Technical Debt

### Must-Fix Before Scale
- [ ] **Authentication System**
  - Currently basic, needs full implementation
  - OAuth (Apple, Google)
  - Email/password flow
  - Account recovery
  - Session management

- [ ] **Data Persistence**
  - Cloud sync for drawings
  - Backup/restore system
  - Offline mode support
  - Conflict resolution

- [ ] **Performance Optimization**
  - Large drawing file handling
  - Memory management for many layers
  - Background rendering
  - Lazy loading for galleries

- [ ] **Code Audit**
  - Security review (especially around API keys, user data)
  - Architecture review (avoid tech debt now)
  - Accessibility compliance
  - App Store guidelines compliance

- [ ] **Analytics & Monitoring**
  - User behavior tracking
  - Crash reporting
  - Performance monitoring
  - A/B testing framework

---

## 🎯 Success Metrics (How We Know It's Working)

### Engagement Metrics
- **Daily Active Users (DAU):** People opening app daily to practice
- **Drawings per user per week:** Core usage metric
- **Feedback requests per user:** Are they using the AI?
- **Retention (D1, D7, D30):** Do they come back?

### Growth Metrics
- **Viral Coefficient:** Referrals per user
- **Agent shares:** How many custom agents shared?
- **Gallery engagement:** Views, likes, comments on public work

### Quality Metrics
- **Feedback quality ratings:** Do users find feedback helpful?
- **Improvement detection:** Can AI measure skill growth over time?
- **NPS (Net Promoter Score):** Would you recommend DrawEvolve?

### Revenue Metrics (Post-Monetization)
- **Conversion rate (free → premium):** What % upgrade?
- **Churn rate:** Do premium users stay?
- **ARPU (Average Revenue Per User):** How much per user?
- **LTV/CAC ratio:** Unit economics

---

## 🚀 Immediate Next Steps (Next Session)

### UI Polish
- [ ] Refine feedback view design
- [ ] Improve toolbar animations
- [ ] Better layer panel UX
- [ ] Loading states for AI feedback
- [ ] Error handling polish

### Branding
- [ ] App name finalization (DrawEvolve?)
- [ ] Logo design
- [ ] Color scheme
- [ ] Onboarding flow design
- [ ] Marketing website copy

### Gallery MVP
- [ ] Local gallery view (see all your past drawings)
- [ ] Drawing metadata (date, time spent, feedback received)
- [ ] Delete/organize drawings
- [ ] Basic search/filter

### Auth MVP
- [ ] Sign in with Apple
- [ ] Basic user profile
- [ ] Cloud save for drawings
- [ ] Account settings

---

## 🤖 Phase 7: Portfolio Analysis Pipeline (Agentic System)

**Goal:** Transform DrawEvolve from reactive feedback tool into proactive long-term mentor

### Core Concept
An autonomous AI system that reviews an artist's portfolio over time, tracks progress, detects patterns, and evolves coaching strategy based on longitudinal data.

### Architecture: Plan → Act → Reflect → Update Loop

**1. Plan Phase (Orchestrator)**
- Define sub-tasks based on available data
- Determine analysis scope (new drawings vs full portfolio)
- Schedule parallel vs sequential operations
- Set quality thresholds and uncertainty flags

**2. Act Phase (Specialized Agents)**
- **Fetch Agent:** Retrieve recent drawings + metadata
- **Compare Agent:** Analyze changes vs last snapshot
- **Style Agent:** Track visual style evolution via embeddings
- **Critique Agent:** Generate personalized feedback referencing past work
- **Metrics Agent:** Calculate quantitative improvement scores

**3. Reflect Phase (Quality Control)**
- Cross-check agent outputs for consistency
- Flag contradictions or insufficient data
- Verify statistical significance of detected trends
- Surface uncertainty to user when appropriate

**4. Update Phase (Persistence)**
- Write new portfolio snapshot to database
- Update user's "artistic profile" (strengths, weaknesses, goals)
- Generate summary for UI display
- Prepare personalized challenges for next session

### Technical Implementation

**Data Model:**
```sql
-- Portfolio snapshots (periodic artist profile)
CREATE TABLE portfolio_snapshots (
  id UUID PRIMARY KEY,
  user_id UUID REFERENCES users(id),
  created_at TIMESTAMP,

  -- Quantitative metrics
  metrics JSONB, -- {anatomy: 7.2, composition: 8.1, color_theory: 6.5, ...}

  -- Qualitative insights
  strengths TEXT[], -- ["improving line confidence", "developing unique style"]
  weaknesses TEXT[], -- ["inconsistent proportions", "limited color palette"]

  -- Progress indicators
  improvement_areas JSONB, -- {anatomy: +1.2, perspective: -0.3, ...}

  -- Summary for display
  summary_text TEXT,

  -- Reference to drawings analyzed
  drawing_ids UUID[]
);

-- Critique history (per-drawing feedback)
CREATE TABLE critique_history (
  id UUID PRIMARY KEY,
  drawing_id UUID REFERENCES drawings(id),
  created_at TIMESTAMP,

  critique_text TEXT,
  focus_areas TEXT[], -- ["anatomy", "composition"]
  ai_model TEXT, -- "gpt-4o-vision"

  -- Link to portfolio snapshot
  snapshot_id UUID REFERENCES portfolio_snapshots(id)
);

-- Drawing embeddings (for style tracking)
CREATE TABLE drawing_embeddings (
  drawing_id UUID PRIMARY KEY REFERENCES drawings(id),
  embedding VECTOR(512), -- CLIP or similar
  created_at TIMESTAMP
);
```

**Agent Prompt Templates:**

*Orchestrator Agent:*
```
You are the Portfolio Analysis Orchestrator. Your job is to coordinate
specialized agents to analyze user {user_id}'s artistic progress.

Available data:
- {num_new_drawings} new drawings since last snapshot
- Last snapshot date: {last_snapshot_date}
- User goals: {user_goals}

Plan the analysis workflow:
1. What sub-tasks are needed?
2. Which agents should run in parallel?
3. What's the minimum data threshold for valid analysis?
4. Should we flag uncertainty if data is insufficient?

Output your plan as JSON.
```

*Compare Agent:*
```
You are the Progress Comparison Agent. Analyze artistic improvement
over time by comparing current work to past snapshots.

Current drawings: {current_drawings}
Last snapshot metrics: {last_snapshot_metrics}
Previous feedback themes: {past_critiques_summary}

For each metric (anatomy, composition, color, etc.):
- Has it improved? By how much?
- What specific changes demonstrate this?
- Are improvements consistent or one-off flukes?

Be statistically honest - say "insufficient data" if sample size is too small.
```

*Reflection Agent:*
```
You are the Quality Control Agent. Review outputs from other agents
and check for consistency, contradictions, and uncertainty.

Inputs:
- Compare Agent: {compare_output}
- Style Agent: {style_output}
- Critique Agent: {critique_output}

Questions to answer:
1. Do all agents agree on key findings?
2. Are there contradictions that need resolution?
3. Is there enough data to support conclusions?
4. Should we flag uncertainty to the user?

Output: APPROVE | REVISE | INSUFFICIENT_DATA
```

### Scheduling & Triggers

**Periodic Analysis:**
- Weekly snapshots for active users (5+ drawings/week)
- Monthly deep dives for all users
- On-demand via "Analyze My Progress" button

**Compute Optimization:**
- Incremental analysis (only new drawings) for weekly runs
- Full portfolio re-analysis monthly or when user requests
- Cache embeddings to avoid re-computing
- Batch processing during off-peak hours

**Cost Management:**
- Use smaller model (GPT-4o-mini) for routine comparisons
- Use GPT-4o only for complex critique generation
- Store summaries, not full context, for long-term memory
- Token optimization: summarize old snapshots instead of full history

### User Experience

**Progress Dashboard:**
```
┌─────────────────────────────────────────┐
│  Your Artistic Journey                  │
├─────────────────────────────────────────┤
│                                         │
│  [Radar Chart: Skill Breakdown]         │
│    Anatomy: ████████░░ 8.2 (+1.5)      │
│    Composition: ██████░░░ 6.8 (+0.3)   │
│    Color Theory: ████████ 7.9 (+2.1)   │
│                                         │
│  Recent Insights:                       │
│  ✅ Your line confidence has improved   │
│     40% since last month!               │
│  ⚠️  Proportions still inconsistent -   │
│     try gesture drawing exercises       │
│                                         │
│  [View Full Report] [Set New Goals]     │
└─────────────────────────────────────────┘
```

**Personalized Coaching:**
- "Last time you struggled with foreshortening. Let's see if you've improved!"
- "Your color harmony has plateaued - ready for a new challenge?"
- "You draw more when feedback is positive - here's extra encouragement!"

### MVP Implementation Path

**Phase 1: Basic Snapshots (Week 1)**
- Add `portfolio_snapshots` table
- Simple weekly job: fetch last 10 drawings, generate summary
- Store as JSON blob (no fancy agents yet)
- UI: "Last Snapshot" view showing progress summary

**Phase 2: Comparison Logic (Week 2)**
- Build "before/after" comparison for specific metrics
- Detect improvement: "Line quality +2 points since last month"
- Store structured metrics (not just text)

**Phase 3: Agentic Orchestrator (Week 3-4)**
- Implement Plan → Act → Reflect → Update loop
- Use LangChain or similar framework
- Deploy reflection layer for quality control
- Test with beta users

**Phase 4: Advanced Features (Ongoing)**
- Style embeddings for visual tracking
- Multi-agent consensus (3 agents vote on critique)
- Personalized learning paths based on trends
- UI visualization (charts, timelines, progress graphs)

### Why This Is a Moat

**Defensibility:**
- Proprietary data: Your users' progress over time
- Network effects: More data = better insights
- Hard to replicate: Requires longitudinal tracking, not just point-in-time feedback

**Retention:**
- Emotional investment: "I have 6 months of progress here!"
- Sunk cost: Users won't want to lose their history
- Gamification: Seeing improvement is addictive

**Differentiation:**
- Competitors offer one-shot feedback
- DrawEvolve offers ongoing mentorship
- "Duolingo for art" - tracks your learning journey

### Open Challenges

**Cold Start:**
- What to show new users with <5 drawings?
- Solution: Focus on snapshot critique until enough data for trends

**Privacy:**
- Some users may not want "AI stalking my progress"
- Solution: Opt-in system, user can delete snapshots

**Accuracy:**
- AI might hallucinate trends from noise
- Solution: Require statistical significance, surface uncertainty

**Compute Cost:**
- Running embeddings + LLMs on entire portfolio = expensive
- Solution: Incremental analysis + monthly deep dives

---

## 💭 Open Questions

1. **Pricing:** What's the right price point for premium? ($4.99? $9.99? $14.99?)
2. **Platform:** iOS first, or expand to iPad/Mac/Android soon?
3. **Target Market:** Hobbyists? Students? Professionals? All three?
4. **Competitive Moat:** What's the ONE thing we do better than everyone else?
   - **Answer candidate:** Portfolio Analysis Pipeline (Phase 7) - nobody else tracks long-term progress with agentic AI
5. **Viral Loop:** What's the single best growth lever? (Referrals? Agent sharing? Gallery?)
6. **AI Costs:** How do we keep OpenAI API costs sustainable at scale?
   - **Answer candidate:** Incremental analysis, smaller models for routine tasks, cached embeddings

---

## 🔥 Why This Works

**You built an MVP in 8 hours.** That's the proof.

- ✅ You ask the right questions (Metal vs. PencilKit saved weeks)
- ✅ You think in systems (Lynk snapshot → DrawEvolve evolution)
- ✅ You focus on the core loop (draw → feedback → improve)
- ✅ You're not afraid to pivot (Vercel → Cloudflare in one session)

**The path forward is clear:**
1. Polish what exists
2. Add snapshots/progress tracking (retention)
3. Add custom agents (personalization)
4. Add social features (virality)
5. Monetize (sustainability)

**This isn't just an app. It's a creative practice platform with a moat.**

Let's build it.
