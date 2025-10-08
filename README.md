# DrawEvolve

iOS drawing app with AI-powered feedback.

## Architecture

- **Platform**: iOS/iPadOS native app
- **Language**: Swift
- **Rendering**: Metal (GPU-accelerated)
- **UI**: SwiftUI
- **Features**: Multi-layer drawing system, pressure-sensitive tools, AI feedback

## Tech Stack

- Metal rendering engine with custom shaders
- Layer system with opacity, blend modes, thumbnails
- Undo/redo with texture snapshots
- 9 drawing tools: brush, eraser, shapes, text, paint bucket, eyedropper
- OpenAI GPT-4 Vision API for drawing analysis
- Supabase for auth and storage

## Workflow

1. **Development**: GitHub Codespaces (this instance)
2. **Deployment**: AnyDesk → Mac Mini → pull from GitHub → Xcode build
3. **Distribution**: TestFlight

## Backend Proxy

The app uses a backend proxy (Vercel) to hide OpenAI API keys from the client.

**Why**: iOS apps can be decompiled, so API keys in the app bundle are not secure.

**Architecture**:
```
iOS App → Vercel Edge Function → OpenAI API
         (no secrets)         (has API key)
```

**Backend location**: `/backend` directory

## Project Structure

```
DrawEvolve/
├── DrawEvolve/
│   ├── Models/          # Data models (DrawingLayer, BrushSettings, etc.)
│   ├── Views/           # SwiftUI views
│   ├── Services/        # Metal renderer, OpenAI manager, storage
│   └── Shaders/         # Metal shaders (.metal files)
├── backend/             # Vercel Edge Functions
└── DrawEvolve.xcodeproj
```

## Current Status

The app has a working Metal rendering engine with layers, undo/redo, and drawing tools. AI feedback integration is in progress.

See git commit history for latest changes.
