# DrawEvolve

**AI-powered drawing app for iOS/iPadOS**

A professional drawing app with Metal-based rendering and real-time AI feedback from GPT-4 Vision. Draw, get personalized critique, improve your art.

---

## 🎯 Current Status

**Last Updated:** 2025-10-10

### ✅ What's Working (MVP Complete!)
- ✅ Metal rendering engine (60fps, smooth)
- ✅ 7 fully functional drawing tools
- ✅ Multi-layer system with thumbnails
- ✅ Undo/redo (unlimited history)
- ✅ **AI feedback working end-to-end!** 🎉
- ✅ Backend deployed to Cloudflare Workers
- ✅ Export to Photos
- ✅ **Drawing persistence (FileManager-based local storage)** 🆕
- ✅ **Gallery view with thumbnail grid** 🆕
- ✅ **Floating feedback panel (draggable, collapsible)** 🆕
- ✅ **Drawing detail view with continue editing** 🆕
- ✅ **Anonymous user system (no auth required)** 🆕

### 🚧 In Progress (Pre-TestFlight)
- 🔧 UI/UX polish (scroll behavior, button placement)
- 🔧 Continue drawing feature (loads but needs UX fixes)

### 📅 Timeline
**Target:** TestFlight launch in 2-3 weeks

See **[FULL_INVENTORY.md](./FULL_INVENTORY.md)** for complete status and TestFlight checklist.

---

## 🏗️ Architecture

### Tech Stack
- **Platform:** iOS/iPadOS native
- **Language:** Swift
- **Rendering:** Metal (GPU-accelerated, custom shaders)
- **UI Framework:** SwiftUI
- **Backend:** Cloudflare Workers (Edge functions)
- **AI:** OpenAI GPT-4o Vision API

### Why Metal?
- 60fps smooth drawing
- Real-time pressure sensitivity
- Layer compositing on GPU
- Undo/redo via texture snapshots
- Professional-grade performance

### Backend Architecture
```
┌─────────────────┐       ┌──────────────────────┐       ┌─────────────┐
│   iOS App       │       │  Cloudflare Worker   │       │   OpenAI    │
│  (Swift/Metal)  │──────▶│  (Edge Function)     │──────▶│   API       │
│                 │       │                      │       │             │
│  No API Key     │       │  Has API Key (env)   │       │ GPT-4 Vision│
└─────────────────┘       └──────────────────────┘       └─────────────┘
```

**Why a backend proxy?**
- iOS apps can be decompiled → API keys in app bundle are insecure
- Backend keeps OpenAI API key secret
- Enables usage tracking and rate limiting for future monetization

**Backend repo:** [DrawEvolve-BACKEND](https://github.com/trevorriggle/DrawEvolve-BACKEND)
**Live endpoint:** `https://drawevolve-backend.trevorriggle.workers.dev`

---

## 📂 Project Structure

```
DrawEvolve/
├── DrawEvolve/
│   ├── DrawEvolve/
│   │   ├── Models/              # Data models
│   │   │   ├── Drawing.swift
│   │   │   ├── DrawingContext.swift
│   │   │   ├── DrawingLayer.swift
│   │   │   └── DrawingTool.swift
│   │   ├── Views/               # SwiftUI views
│   │   │   ├── DrawingCanvasView.swift
│   │   │   ├── MetalCanvasView.swift
│   │   │   ├── LayerPanelView.swift
│   │   │   ├── FeedbackOverlay.swift
│   │   │   └── ...
│   │   ├── Services/            # Business logic
│   │   │   ├── CanvasRenderer.swift      # Metal rendering
│   │   │   ├── OpenAIManager.swift       # AI API calls
│   │   │   ├── HistoryManager.swift      # Undo/redo
│   │   │   ├── DrawingStorageManager.swift
│   │   │   └── ...
│   │   ├── Shaders.metal        # Metal shaders
│   │   └── DrawEvolveApp.swift  # App entry point
│   └── DrawEvolve.xcodeproj
├── FULL_INVENTORY.md            # ⭐ Complete status & roadmap
├── PIPELINE_FEATURES.md         # ⭐ Feature roadmap & vision
├── TOOLS_AUDIT.md               # ⭐ Tools implementation details
├── UX_AUDIT.md                  # ⭐ UI/UX issues & fixes
└── WHERE_WE_LEFT_OFF.md         # Session notes
```

---

## 🎨 Drawing Tools

### ✅ Fully Functional (7 tools)
1. **Brush** - Pressure-sensitive, variable size/opacity/hardness
2. **Eraser** - Same properties as brush
3. **Paint Bucket** - Flood fill with tolerance
4. **Line** - Straight lines with preview
5. **Rectangle** - Outlined rectangles (not filled)
6. **Circle** - Outlined circles (not filled)
7. **Text** - Add text to canvas

### 🎯 Easy Wins (Shaders Ready!)
- **Blur** - Metal compute shader exists, just needs wiring (~2 hours)
- **Sharpen** - Metal compute shader exists, just needs wiring (~2 hours)
- **Eyedropper** - Color picker (~2-3 hours)

See **[TOOLS_AUDIT.md](./TOOLS_AUDIT.md)** for full details.

---

## 🤖 AI Feedback Feature

### How It Works
1. User draws on canvas
2. Taps "Get Feedback"
3. App exports image (composites all visible layers)
4. Sends to backend with context (subject, style, artists, techniques, focus areas)
5. Backend calls OpenAI GPT-4 Vision
6. AI analyzes drawing and returns personalized feedback
7. Feedback displayed to user

### Context Fields
Users provide context for better feedback:
- **Subject:** What are you drawing?
- **Style:** Realism, cartoon, abstract, etc.
- **Artists:** Influences/inspirations
- **Techniques:** What you're practicing
- **Focus Areas:** What to critique
- **Additional Context:** Free-form notes

### Feedback Quality
- Constructive and encouraging
- Specific (not generic)
- Actionable suggestions
- Includes a small joke for personality
- Max 800 tokens (~600 words)

---

## 🚀 Development Workflow

### Environment
- **Primary Development:** GitHub Codespaces (this instance)
- **Testing/Deployment:** Mac Mini (via AnyDesk)
- **Version Control:** Git/GitHub

### Deployment Process
1. Code in Codespaces → commit → push to GitHub
2. AnyDesk to Mac Mini
3. Pull latest from GitHub
4. Build in Xcode
5. Run on device or TestFlight

### Backend Deployment
```bash
cd DrawEvolve-BACKEND
export CLOUDFLARE_API_TOKEN=<your-token>
wrangler deploy
```

---

## 📚 Key Documentation

**Start here if you're new:**
1. **[FULL_INVENTORY.md](./FULL_INVENTORY.md)** - Complete project status
   - What works, what's broken
   - TestFlight requirements
   - Timeline estimates
   - Task list with time estimates

2. **[PIPELINE_FEATURES.md](./PIPELINE_FEATURES.md)** - Product vision
   - Phase 1: Progress tracking (snapshots)
   - Phase 2: Custom AI agents
   - Phase 3: Social features
   - Monetization strategy

3. **[TOOLS_AUDIT.md](./TOOLS_AUDIT.md)** - Drawing tools deep dive
   - Which tools work vs defined
   - Implementation details
   - Code examples for missing tools

4. **[UX_AUDIT.md](./UX_AUDIT.md)** - UI/UX issues & fixes
   - Prioritized issue list (P0/P1/P2)
   - Fix instructions with code examples
   - Testing checklists

---

## 🛠️ Quick Start (For Developers)

### Prerequisites
- Mac with Xcode 15+
- iOS 17+ device or simulator
- Cloudflare account (for backend)
- OpenAI API key

### First Time Setup

1. **Clone the repo:**
```bash
git clone https://github.com/trevorriggle/DrawEvolve.git
cd DrawEvolve/DrawEvolve
```

2. **Open in Xcode:**
```bash
open DrawEvolve.xcodeproj
```

3. **Build and run:**
- Select your device/simulator
- Hit ⌘R to build and run
- App will launch in DEBUG mode (auto-resets auth each launch)

4. **Backend setup (if needed):**
```bash
git clone https://github.com/trevorriggle/DrawEvolve-BACKEND.git
cd DrawEvolve-BACKEND
npm install -g wrangler
wrangler login
wrangler secret put OPENAI_API_KEY
wrangler deploy
```

### File Locations for Common Tasks

**Add a new tool:**
- Define in: `Models/DrawingTool.swift`
- Handle touch: `Views/MetalCanvasView.swift`
- Rendering: `Services/CanvasRenderer.swift`
- Add button: `Views/DrawingCanvasView.swift`

**Modify AI feedback:**
- Request logic: `Services/OpenAIManager.swift`
- UI: `Views/FeedbackOverlay.swift`
- Backend: DrawEvolve-BACKEND repo `index.js`

**Layer management:**
- Model: `Models/DrawingLayer.swift`
- UI: `Views/LayerPanelView.swift`
- Rendering: `Views/MetalCanvasView.swift`

**Metal shaders:**
- All shaders: `Shaders.metal`
- Pipeline setup: `Services/CanvasRenderer.swift:setupPipeline()`

---

## 🧪 Testing

### Manual Testing Checklist
- [ ] Drawing with all 7 tools works
- [ ] Layers (create, delete, hide/show, reorder)
- [ ] Undo/redo
- [ ] AI feedback (draw → get feedback → see results)
- [ ] Export to Photos
- [ ] Brush settings (size, opacity, hardness)
- [ ] Color picker

### Known Issues
See **[UX_AUDIT.md](./UX_AUDIT.md)** for complete list.

**Current:**
- Continue Drawing button requires scrolling to see (UX issue)
- Continue Drawing loads image but may need canvas state fixes
- Some UI elements need better scroll behavior

**Fixed:**
- ~~AI feedback panel overlaps UI~~ → Now draggable floating panel
- ~~No drawing persistence~~ → FileManager-based storage working
- ~~iPad keyboard doesn't appear~~ → Simulator-specific issue

**See docs for full list and fix instructions.**

---

## 📦 Dependencies

### iOS App
- SwiftUI (built-in)
- Metal (built-in)
- Supabase Swift SDK (partially integrated, not critical)

### Backend
- None! Vanilla JavaScript on Cloudflare Workers

### Future Dependencies (Planned)
- StoreKit 2 (in-app purchases)
- CloudKit or Supabase (cloud storage)
- Firebase Crashlytics (crash reporting)

---

## 🎯 Next Steps

### Immediate (This Week)
1. Fix AI feedback panel layout (P0)
2. Implement drawing persistence (P0)
3. Build gallery view (P0)
4. Add confirmations for destructive actions (P0)

### Short-term (Next 2 Weeks)
5. UI/UX polish pass
6. Add easy-win tools (eyedropper, blur, sharpen)
7. Simplify/fix auth
8. TestFlight submission

### Long-term (Post-TestFlight)
- Progress tracking (snapshots)
- Custom AI agents
- Social features
- Monetization

See **[FULL_INVENTORY.md](./FULL_INVENTORY.md)** for detailed task list with estimates.

---

## 🤝 Contributing

This is a solo project by Trevor Riggle, but feedback is welcome!

**If you're reviewing this code:**
- Check **[FULL_INVENTORY.md](./FULL_INVENTORY.md)** for current status
- Check **[UX_AUDIT.md](./UX_AUDIT.md)** for known issues
- Check **[TOOLS_AUDIT.md](./TOOLS_AUDIT.md)** for implementation details

**Areas needing help:**
- Code audit (security review before TestFlight)
- UI/UX design feedback
- Performance optimization (especially flood fill)

---

## 📄 License

TBD (currently private repo)

---

## 🔗 Links

- **Backend Repo:** https://github.com/trevorriggle/DrawEvolve-BACKEND
- **Live Backend:** https://drawevolve-backend.trevorriggle.workers.dev
- **TestFlight:** Coming soon!

---

## 📞 Contact

Trevor Riggle - trevorriggle@gmail.com

---

**Last significant update:** 2025-10-10 - Gallery, persistence, and floating feedback panel completed! 🎉
