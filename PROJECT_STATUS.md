# DrawEvolve - Project Status

## Current Status: Core Features Complete

A professional iPad drawing app with AI-powered feedback, built with SwiftUI + Metal.

## Core Features (Working)

### Drawing & Tools
- **Brush Tool** - Pressure-sensitive drawing with customizable size, opacity, hardness
- **Eraser Tool** - Remove pixels with brush-like control
- **Shape Tools** - Line, Rectangle, Circle/Ellipse, Polygon (tap-to-place points)
- **Fill Tools** - Paint bucket (flood fill), Eyedropper (color picker)
- **Effect Tools** - Blur, Sharpen (whole-canvas effects)
- **Text Tool** - Add text to canvas at any location
- **Selection Tools**:
  - Rectangle Select - Drag to select, delete pixels
  - Lasso - Freehand selection, delete pixels
  - Both show Delete/Cancel UI when active

### Canvas System
- **Metal-Powered Rendering** - GPU-accelerated with 2048x2048 texture layers
- **Layer System** - Multiple layers with opacity, visibility, blend modes
- **Undo/Redo** - Texture snapshot-based history for all operations
- **Pressure Sensitivity** - Apple Pencil support with force detection

### Persistence & Gallery
- **Save to Gallery** - SQLite-backed storage with SwiftData
- **Continue Editing** - Load existing drawings from gallery
- **Drawing Context** - Subject, style, artists, techniques, focus areas
- **Thumbnails** - Auto-generated layer previews

### AI Feedback
- **OpenAI Vision API** - Analyzes drawings with context awareness
- **Floating Feedback Panel** - Markdown-formatted, draggable UI
- **Contextual Prompts** - Uses drawing context for targeted feedback

### UX Polish
- **Collapsible Toolbar** - Floating panel with all tools (2-column grid)
- **Color Picker** - Advanced HSB picker with saved presets
- **Brush Settings Panel** - Size, opacity, hardness, spacing sliders
- **Sticky UI Patterns** - Fixed action buttons, selection overlays
- **Pre-Drawing Questionnaire** - Captures context before starting

## Architecture

See **PIPELINE_FEATURES.md** for detailed Metal rendering pipeline documentation.

```
DrawEvolve/
├── Models/
│   ├── Drawing.swift          # SwiftData model for persistence
│   ├── DrawingContext.swift   # User's drawing intent/context
│   ├── DrawingLayer.swift     # Layer model with Metal textures
│   ├── DrawingTool.swift      # Tool enum + icons
│   └── BrushSettings.swift    # Brush configuration
├── Views/
│   ├── ContentView.swift           # App entry point
│   ├── PromptInputView.swift       # Pre-drawing questionnaire
│   ├── DrawingCanvasView.swift     # Main canvas with toolbar
│   ├── MetalCanvasView.swift       # UIViewRepresentable for Metal
│   ├── GalleryView.swift           # Grid of saved drawings
│   ├── DrawingDetailView.swift     # View/edit saved drawing
│   ├── FloatingFeedbackPanel.swift # AI feedback display
│   ├── LayerPanelView.swift        # Layer management
│   ├── BrushSettingsView.swift     # Brush controls
│   └── AdvancedColorPicker.swift   # HSB color picker
├── Services/
│   ├── CanvasRenderer.swift        # Metal rendering engine
│   ├── DrawingStorageManager.swift # SQLite persistence
│   ├── OpenAIManager.swift         # API client for feedback
│   └── HistoryManager.swift        # Undo/redo system
└── Shaders/
    └── Shaders.metal              # GPU shaders (brush, eraser, effects)
```

## Tech Stack
- **SwiftUI** - Declarative UI framework
- **Metal** - GPU-accelerated rendering
- **SwiftData** - Model persistence
- **UIKit** - Touch handling, image manipulation
- **OpenAI Vision API** - AI feedback (requires API key)

## Recent Session (2025-01-13)

### CRITICAL BUG FIXED
**Brush strokes were jumping 70-100 pixels to the left on release**

Root cause: Coordinate scaling in `CanvasRenderer.swift` was using:
```swift
let uniformScale = Float(texture.width) / Float(max(screenSize.width, screenSize.height))
```

Fixed by using separate X/Y scales:
```swift
let scaleX = Float(texture.width) / Float(screenSize.width)
let scaleY = Float(texture.height) / Float(screenSize.height)
```

### Features Added
- ✅ Markdown rendering in feedback panel
- ✅ Updated documentation files

## Known Issues / Deferred Features

### Zoom/Pan/Rotate (Deferred)
- Gesture recognizers exist in code but disabled
- Touch coordinate transformations were causing the stroke offset bug
- **Decision**: Test and implement with physical iPad in future session

### Untested Features
- ⚠️ Critique history - Implementation complete but needs end-to-end testing

### Unimplemented Tools
- Magic Wand, Smudge, Clone Stamp, Move, Rotate, Scale
- Effect tools (blur/sharpen) apply to whole canvas, not brush-based

## Getting Started

### Requirements
- Xcode 15+
- iOS 17+
- OpenAI API key (for feedback feature)

### Setup
1. Open `DrawEvolve.xcodeproj` in Xcode
2. Add your OpenAI API key to `OpenAIManager.swift` (line ~15)
3. Build and run on simulator or device

### Environment Variables
The app expects an OpenAI API key. Options:
- Hardcode in `OpenAIManager.swift`
- Set `OPENAI_API_KEY` environment variable
- Modify to load from keychain/secrets manager

## API Usage
OpenAI Vision API calls are made when user clicks "Get Feedback":
- Sends: Canvas image + drawing context (subject, style, etc.)
- Receives: Markdown-formatted feedback
- Cost: ~$0.01-0.05 per request (depending on image size)

## Next Session Priorities

### High Priority (Test with Physical iPad)
1. **Verify stroke fix** - Confirm strokes land exactly where drawn
2. **Test critique history** - Get multiple feedbacks, verify history view works
3. **Implement zoom/pan** - With device in hand, properly implement gesture transforms

### Future Features (If Requested)
- Magic Wand selection
- Smudge/Clone tools
- Transform tools (rotate, scale selections)
- Brush presets
- Export options (PNG, JPEG with layers)
- Performance optimization for large canvases

## Key Files
- `MetalCanvasView.swift` - Touch handling and drawing surface
- `CanvasRenderer.swift` - Metal rendering engine (**line 218-220: coordinate fix**)
- `DrawingCanvasView.swift` - Main UI with toolbar and panels
- `CanvasStateManager.swift` - State management (zoom/pan code exists but unused)
- `OpenAIManager.swift` - AI feedback integration
- `FloatingFeedbackPanel.swift` - Feedback display with markdown rendering

---
**Last Updated**: January 13, 2025
**Status**: Core features complete, stroke bug fixed, ready for iPad testing
