# DrawingCanvasView.swift Refactoring Guide

**Current Size:** 1,506 lines (MASSIVE)
**Target Size:** ~600-700 lines per file

**Problem:** DrawingCanvasView.swift is doing too much - it contains the view, state manager, and UI components all in one file.

---

## Refactoring Plan

### Step 1: Extract CanvasStateManager
**File:** `DrawEvolve/DrawEvolve/ViewModels/CanvasStateManager.swift`
**Lines to move:** 719-1297 (~580 lines)

**What to extract:**
- Entire `CanvasStateManager` class
- All its methods (undo, redo, selection management, zoom/pan, etc.)

**Important:**
- Keep all imports at top (SwiftUI, UIKit, Foundation)
- This is an `@MainActor class` and `ObservableObject`
- References: `DrawingLayer`, `BrushSettings`, `DrawingTool`, `HistoryManager`, `CanvasRenderer`, `DrawingContext`, `OpenAIManager`

**After extraction:**
- Add `import Foundation` to new file
- Add `import SwiftUI` (for CGPoint, CGSize, CGRect, Angle)
- Add `import UIKit` (for UIImage, UIGraphicsBeginImageContextWithOptions)
- DrawingCanvasView.swift will import this file automatically

---

### Step 2: Extract Selection Overlay Views
**File:** `DrawEvolve/DrawEvolve/Views/SelectionOverlays.swift`
**Lines to move:** 1299-1495 (~200 lines)

**What to extract:**
- `MarchingAntsRectangle` struct
- `MarchingAntsPath` struct
- `SelectionTransformHandles` struct
- `HandleView` struct

**Important:**
- These are all SwiftUI View structs
- `SelectionTransformHandles` takes `@ObservedObject var canvasState: CanvasStateManager`
- Need imports: SwiftUI

**After extraction:**
- Add `import SwiftUI` at top
- DrawingCanvasView.swift will use these views

---

### Step 3: Extract ToolButton
**File:** `DrawEvolve/DrawEvolve/Views/Components/ToolButton.swift`
**Lines to move:** 700-715 (~15 lines)

**What to extract:**
- `ToolButton` struct

**Important:**
- Simple SwiftUI component
- Takes action closure and icon string

**After extraction:**
- Add `import SwiftUI` at top
- Create `Components` folder if needed

---

### Step 4: Update DrawingCanvasView.swift
After all extractions, the file should contain:
- `DrawingCanvasView` struct only
- All the UI layout code
- References to extracted components

**No changes needed to imports** - SwiftUI files auto-import peer files in same target

---

## Verification Checklist

After refactoring:
- [ ] Build succeeds (no compilation errors)
- [ ] All imports are correct
- [ ] CanvasStateManager is accessible from DrawingCanvasView
- [ ] Selection overlays render correctly
- [ ] Transform handles still work
- [ ] No duplicate code between files
- [ ] File sizes are reasonable (<800 lines each)

---

## File Structure After Refactoring

```
DrawEvolve/DrawEvolve/
├── Views/
│   ├── DrawingCanvasView.swift          (~700 lines - main canvas view)
│   ├── SelectionOverlays.swift          (~200 lines - marching ants + handles)
│   ├── Components/
│   │   └── ToolButton.swift             (~15 lines - toolbar button)
│   └── ... (other views)
├── ViewModels/
│   ├── CanvasStateManager.swift         (~580 lines - NEW)
│   └── ... (other view models)
└── ... (other folders)
```

---

## Notes for Future Claude

- Do this refactoring when you have 100k+ tokens available
- Do all 4 steps in sequence without interruption
- Test build after Step 2 and Step 4
- Commit after successful build with message: "Refactor: Extract CanvasStateManager and selection views"
- If build fails, check imports first
- CanvasStateManager needs to be in ViewModels folder (create if doesn't exist)
