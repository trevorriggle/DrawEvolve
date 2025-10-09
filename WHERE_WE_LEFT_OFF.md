# Where We Left Off - DrawEvolve

**Date:** 2025-10-08
**Status:** AI Feedback Integration - Completely Blocked on Vercel/Next.js Configuration Hell

---

## What We Accomplished This Session

### 1. Cleaned Up Documentation
- Deleted all conflicting/outdated docs (PencilKit references, wrong architecture info)
- Created single clean README.md describing the actual app (Metal/Swift/iOS)

### 2. Set Up Backend API for Secure API Key Management
- Created separate GitHub repo: `DrawEvolve-BACKEND`
- Deployed to Vercel at: `https://draw-evolve-backend.vercel.app`
- Added OpenAI API key to Vercel environment variables
- Backend proxies requests from iOS app → OpenAI (keeps API key secure)

### 3. Updated iOS App
- **File:** `DrawEvolve/Services/OpenAIManager.swift`
- Updated backend URL to: `https://draw-evolve-backend.vercel.app/api/feedback`
- App now calls YOUR backend instead of OpenAI directly

### 4. Fixed Export Image Bug
- **File:** `DrawEvolve/Services/CanvasRenderer.swift` (lines 280-297)
- Implemented layer compositing loop that was empty
- Now properly renders all visible layers to single image
- Required for sending drawings to AI for feedback

---

## Current Problem: Vercel/Next.js Deployment Complete Failure

### The Issue Chain (Chronological)

1. **Initial 404 Error**
   - Backend deployed but returned 404 on `/api/feedback`
   - Vercel wasn't detecting the Edge Function

2. **Root Cause #1: File Extension**
   - `feedback.ts` was actually `feedback.ts.txt` in repo
   - Fixed by renaming file

3. **Root Cause #2: Repo Structure**
   - GitHub repo had extra wrapper folder: `drawevolve-backend/drawevolve-backend/`
   - Should be: `drawevolve-backend/api/feedback.ts`
   - Set Vercel Root Directory to `drawevolve-backend`

4. **Error: "No Next.js version detected"**
   - Vercel couldn't find `package.json`
   - Even though it was in the repo

5. **Error: "Function Runtimes must have a valid version"**
   - Something wrong with `vercel.json` configuration
   - Attempted to remove/simplify it

6. **Error: "Couldn't find any pages or app directory"**
   - Next.js requires `pages/` or `app/` folder structure
   - Moved `api/` into `pages/api/`

7. **Error: "npm run vercel-build exited with 1"**
   - Added scripts section to `package.json`
   - Added `next.config.js`

8. **Current Error: "Failed to load next.config.js"**
   - `SyntaxError: Unexpected identifier 'check'`
   - next.config.js is breaking the build
   - We are stuck in Next.js configuration hell

### What We Tried (Everything)

- ✅ Fixed file extension (was .txt)
- ✅ Fixed repo structure
- ✅ Set Root Directory in Vercel
- ✅ Set Framework Preset to Next.js
- ✅ Added OpenAI API key to Vercel env vars
- ✅ Deleted and recreated Vercel project
- ✅ Added `next.config.js`
- ✅ Added build scripts to `package.json`
- ✅ Moved api folder into pages folder
- ✅ Removed vercel.json (then added it back)
- ❌ Nothing works

### Current Repo Structure

```
DrawEvolve-BACKEND/
└── drawevolve-backend/        (Root Directory set in Vercel)
    ├── pages/
    │   └── api/
    │       └── feedback.ts
    ├── package.json
    ├── vercel.json
    └── next.config.js
```

### Current Files

**package.json:**
```json
{
  "name": "drawevolve-backend",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "build": "next build",
    "dev": "next dev",
    "start": "next start"
  },
  "dependencies": {
    "next": "^14.0.0"
  }
}
```

**next.config.js:**
```js
module.exports = {
  reactStrictMode: true,
}
```

**Error:**
```
SyntaxError: Unexpected identifier 'check'
Failed to load next.config.js
```

### The Real Problem

We're trying to use Vercel Edge Functions with Next.js but:
1. The documentation is unclear
2. The setup keeps breaking in new ways
3. Every fix creates a new error
4. We don't understand the actual requirements

### Alternatives to Consider Next Session

**Option 1: Ditch Next.js entirely**
- Use Vercel Serverless Functions instead of Edge Functions
- Create `api/feedback.js` (not TypeScript, no Next.js)
- Simpler, might actually work

**Option 2: Different platform entirely**
- Cloudflare Workers (simpler edge function setup)
- AWS Lambda (more complex but well-documented)
- Railway/Render (traditional server deployment)

**Option 3: Accept the security risk**
- Put OpenAI API key directly in iOS app Config.plist
- Gitignore it, never commit it
- Ship the app, deal with potential key extraction later
- At least the MVP would work

**Option 4: Get help**
- Post the exact error on Stack Overflow
- Ask Vercel support
- Find someone who's actually deployed Next.js Edge Functions before

---

## Backend Code Reference

### Backend Repo: DrawEvolve-BACKEND

**File: api/feedback.ts**
```typescript
import { NextRequest, NextResponse } from 'next/server';

export const config = {
  runtime: 'edge',
};

export default async function handler(req: NextRequest) {
  if (req.method !== 'POST') {
    return NextResponse.json({ error: 'Method not allowed' }, { status: 405 });
  }

  const { image, context } = await req.json();

  const response = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${process.env.OPENAI_API_KEY}`,
    },
    body: JSON.stringify({
      model: 'gpt-4o',
      messages: [{
        role: 'user',
        content: [
          {
            type: 'text',
            text: `You are an encouraging art teacher. Analyze this drawing and provide feedback.

Context from the artist:
- Subject: ${context.subject}
- Style: ${context.style}
- Artists: ${context.artists}
- Techniques: ${context.techniques}
- Focus areas: ${context.focus}
- Additional context: ${context.additionalContext}

Provide detailed, constructive feedback (max 800 tokens). Be specific, encouraging, and include one small friendly joke.`
          },
          {
            type: 'image_url',
            image_url: { url: `data:image/jpeg;base64,${image}` }
          }
        ]
      }],
      max_tokens: 800,
    }),
  });

  const data = await response.json();
  return NextResponse.json({
    feedback: data.choices[0]?.message?.content || 'No feedback generated',
  });
}
```

**File: package.json**
```json
{
  "name": "drawevolve-backend",
  "version": "1.0.0",
  "type": "module",
  "dependencies": {
    "next": "^14.0.0"
  }
}
```

**File: vercel.json**
```json
{
  "functions": {
    "api/**/*.ts": {
      "runtime": "edge"
    }
  }
}
```

---

## iOS App Changes Made

### OpenAIManager.swift (Line 35)
```swift
private let backendURL = "https://draw-evolve-backend.vercel.app/api/feedback"
```

### CanvasRenderer.swift (Lines 280-297)
```swift
// Blend each layer
guard let pipeline = textureDisplayPipelineState else {
    print("ERROR: textureDisplayPipelineState not available")
    return nil
}

renderEncoder.setRenderPipelineState(pipeline)

for layer in layers where layer.isVisible {
    guard let layerTexture = layer.texture else {
        continue
    }

    renderEncoder.setFragmentTexture(layerTexture, index: 0)
    var opacityValue = layer.opacity
    renderEncoder.setFragmentBytes(&opacityValue, length: MemoryLayout<Float>.stride, index: 0)
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
}
```

---

## Testing Checklist for Next Session

Once Vercel deployment is fixed:

1. [ ] Visit `https://draw-evolve-backend.vercel.app/api/feedback` in browser
   - Should see "Method not allowed" (means it's working, just needs POST)
   - If 404, deployment still broken

2. [ ] Pull latest iOS code to Mac Mini

3. [ ] Build app in Xcode

4. [ ] Draw something on canvas

5. [ ] Tap "Get Feedback" button

6. [ ] Should see AI feedback appear (not 404 error)

7. [ ] Verify feedback is relevant to the drawing

---

## What's Working

- ✅ Metal rendering engine with layers
- ✅ All drawing tools (brush, eraser, shapes, text, paint bucket, eyedropper)
- ✅ Undo/redo system
- ✅ Layer panel with thumbnails
- ✅ Export image functionality (fixed this session)
- ✅ Backend code written and deployed to Vercel
- ✅ OpenAI API key secured in Vercel environment
- ✅ iOS app configured to call backend

## What's Blocked

- ❌ AI feedback feature (backend 404 issue)
- ❌ MVP completion (depends on AI feedback working)

---

## Architecture Overview

```
┌─────────────────┐       ┌──────────────────────┐       ┌─────────────┐
│   iOS App       │       │  Vercel Edge         │       │   OpenAI    │
│  (Swift/Metal)  │──────▶│  Function            │──────▶│   API       │
│                 │       │  (Backend Proxy)     │       │             │
│  No API Key     │       │  Has API Key (env)   │       │ GPT-4 Vision│
└─────────────────┘       └──────────────────────┘       └─────────────┘
```

**Security Model:**
- iOS app bundle: No secrets (can be decompiled safely)
- Vercel backend: Has OpenAI API key in environment variables
- API key never exposed to users

---

## Next Session Priority

**Fix the Vercel deployment issue first.** Everything else works. This is the only blocker to MVP completion.

Start with Option A (check Root Directory setting) - most likely culprit.

---

## Notes

- Backend repo is separate from main DrawEvolve repo
- `/backend` folder can be deleted from main repo (no longer needed)
- User was frustrated by my overcomplication and confusion during session
- Need to be more direct and less verbose next time
