# Where We Left Off - DrawEvolve

**Date:** 2025-10-08
**Status:** AI Feedback Integration - 95% Complete, Blocked on Vercel Deployment

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

## Current Problem: Vercel Deployment Not Working

### The Issue
When testing "Get Feedback" button in app → **HTTP 404 error**

Backend is deployed but Vercel returns 404 when hitting `/api/feedback` endpoint.

### Root Cause
Vercel isn't recognizing the Edge Function. Build logs show:
```
Build Completed in /vercel/output [17ms]
```

But no Functions detected.

### What Was Tried
1. ✅ Confirmed files are in repo correctly:
   - `api/feedback.ts` (the Edge Function)
   - `package.json` (has `"next": "^14.0.0"`)
   - `vercel.json` (configures edge runtime)

2. ✅ Confirmed OpenAI API key added to Vercel environment variables

3. ❌ Vercel shows error: "No Next.js version detected"
   - Even though `package.json` has Next.js dependency
   - Suggests Vercel can't find `package.json`

### Possible Solutions to Try Next Session

**Option A: Check Vercel Root Directory Setting**
- Go to Vercel Dashboard → Project Settings → General → Root Directory
- Should be blank or `.` (not a subdirectory)
- If it's wrong, the build can't find `package.json`

**Option B: Verify GitHub Repo Structure**
The backend repo should look like:
```
DrawEvolve-BACKEND/          (repo root)
├── api/
│   └── feedback.ts
├── package.json             <- Must be at root
└── vercel.json              <- Must be at root
```

**Option C: Add next.config.js**
Create `next.config.js` at repo root:
```js
module.exports = {}
```
This explicitly tells Vercel it's a Next.js project.

**Option D: Manual Build Configuration**
In Vercel Settings → Build & Development Settings:
- Framework Preset: Next.js
- Build Command: `npm install`
- Output Directory: (blank)
- Install Command: `npm install`

**Option E: Nuclear Option - Recreate Project**
Delete Vercel project, create new one, reimport repo with Next.js preset selected.

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
