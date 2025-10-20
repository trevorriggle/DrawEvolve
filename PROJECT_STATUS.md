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

## Recent Sessions

### Session 2025-01-20

#### CRITICAL BUG FIXED: Apple Pencil Not Working
**Problem:** Apple Pencil and touch input completely stopped responding
**Root Cause:** SwiftUI overlays blocking hit testing even when empty
**Solution:** Added `Color.clear.allowsHitTesting(false)` to empty overlay branches in ContentView.swift

#### Delete Selection Bug Fixed
**Problem:** Delete selection was "slightly busted" - pixels weren't clearing properly
**Root Cause:** `clearSelection()` only cleared activeSelection and selectionPath but not selectionPixels, selectionOriginalRect, or selectionOffset
**Solution:** Updated `clearSelection()` to comprehensively clear all selection-related state (lines 1002-1010)

#### Feedback Panel UX Improvements
- ✅ Fixed offscreen spawning - rewrote positioning logic with absolute coordinates
- ✅ Added reset position button (counterclockwise arrow icon)
- ✅ Fixed collapsed icon drag - replaced Button with .onTapGesture
- ✅ Added AI feedback toolbar button (sparkles icon) to reopen panel
- ✅ Reversed critique history order (newest first)
- ✅ Updated paint bucket icon to "drop.fill"

**Files Modified:** ContentView.swift, FloatingFeedbackPanel.swift, DrawingCanvasView.swift, DrawingTool.swift

### Session 2025-01-13

#### CRITICAL BUG FIXED: Stroke Offset
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

#### Features Added
- ✅ Markdown rendering in feedback panel
- ✅ Selection tool preview strokes
- ✅ Critique history navigation
- ✅ Updated documentation files

## Known Issues / Deferred Features

### Zoom/Pan/Rotate (Deferred)
- Gesture recognizers exist in code but disabled
- Touch coordinate transformations were causing the stroke offset bug
- **Decision**: Test and implement with physical iPad in future session

### Untested Features
- ⚠️ Selection pixel moving - Extract and drag functionality implemented but needs testing

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
1. **Verify all fixes** - Confirm Apple Pencil input, delete selection, feedback panel positioning all work
2. **Test selection pixel moving** - Verify extract and drag functionality works
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
- `DrawingCanvasView.swift` - Main UI with toolbar, panels, selection management (**lines 1002-1010: clearSelection fix**)
- `ContentView.swift` - App entry point (**lines 26-54: overlay hit testing fix**)
- `FloatingFeedbackPanel.swift` - Feedback display with positioning, history navigation
- `CanvasStateManager.swift` - State management (zoom/pan code exists but unused)
- `OpenAIManager.swift` - AI feedback integration

---
**Last Updated**: January 20, 2025
**Status**: Core features complete, critical bugs fixed (Apple Pencil, selection deletion), ready for iPad testing
