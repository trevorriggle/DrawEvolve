# DrawEvolve - iOS Drawing App

## Current Status: MVP Complete

A professional iOS drawing app with AI feedback, built with SwiftUI + Metal.

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

## Recently Completed
- ✅ Polygon tool (multi-tap shape creation) - tap points, tap near first to close
- ✅ Eraser preview fix (no longer shows ghost overlay)
- ✅ Circle tool now draws ellipses/ovals
- ✅ Continue drawing feature from gallery
- ✅ Delete button in detail view
- ✅ Full-screen canvas with floating UI

## Partially Implemented (Needs Rework)
- ⚠️ **Rectangle Select & Lasso**: Currently implemented as "select-to-delete" tools, NOT proper selection tools
  - **What they do now**: Drag to select area → Delete button appears → removes pixels
  - **What they SHOULD do**: Drag to select → show marching ants → drag selection to move pixels
  - **Missing**: Marching ants preview, pixel extraction/movement, recompositing
  - **Status**: Basic selection detection works, but wrong UX paradigm
  - **Files**: MetalCanvasView.swift:469-602 (selection), DrawingCanvasView.swift:229-285 (UI)
  - **To fix**: Need to extract selected pixels to temporary texture, allow dragging, composite back on release

## Known Limitations
- **Unimplemented Tools**: Magic Wand, Smudge, Clone Stamp, Move, Rotate, Scale
- **Effect Tools**: Blur/Sharpen apply to whole canvas (not brush-based)
- **No Preview**: Polygon points don't show visual feedback while building
- **No Multi-Select**: Can't select multiple tools or combine selections

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

## Next Steps (If Continuing Development)
1. **Magic Wand** - Color-based selection (similar to flood fill algorithm)
2. **Move Tool** - Drag selected pixels to new location
3. **Transform Tools** - Rotate, scale selected areas
4. **Smudge/Clone** - Require custom Metal shaders
5. **Export Options** - PNG, JPEG, PSD with layers
6. **Cloud Sync** - iCloud/Cloudflare integration
7. **Brush Presets** - Save/load custom brushes
8. **Performance** - Optimize for larger canvases/more layers

## File Notes
- `MetalCanvasView.swift:403-467` - Polygon tool implementation
- `MetalCanvasView.swift:469-492` - Selection tool handlers
- `CanvasRenderer.swift:916-1079` - Selection pixel deletion (clearRect, clearPath)
- `DrawingCanvasView.swift:229-285` - Selection UI overlay
- All tools use screen-to-texture coordinate scaling for proper rendering

## Testing
Run on device for best performance (Metal rendering is faster on hardware).
Test Apple Pencil pressure sensitivity on iPad.

---
**Last Updated**: October 10, 2025
**MVP Status**: Feature complete, ready for user testing
