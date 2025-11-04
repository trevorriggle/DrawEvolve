# Canvas Transform Implementation Guide
## Zoom & Rotation for DrawEvolve

> **Purpose:** This guide provides a comprehensive, bug-free approach to implementing canvas zoom and rotation in DrawEvolve, avoiding common pitfalls and ensuring professional-grade behavior like Procreate.

---

## Table of Contents
1. [Critical Concepts](#critical-concepts)
2. [Current State Analysis](#current-state-analysis)
3. [Coordinate Space Architecture](#coordinate-space-architecture)
4. [Zoom Implementation](#zoom-implementation)
5. [Rotation Implementation](#rotation-implementation)
6. [Critical Bug Fixes Required](#critical-bug-fixes-required)
7. [Testing & Validation](#testing--validation)
8. [Performance Considerations](#performance-considerations)

---

## Critical Concepts

### The Golden Rule: Separation of Display and Data

**Drawing data must NEVER be affected by canvas transforms.**

```
USER TOUCHES SCREEN → Transform to Document Space → Store/Draw in Document Space
                                                            ↓
DISPLAY TO USER ← Apply Zoom/Pan/Rotation ← Read from Document Space
```

### Three Coordinate Spaces

1. **Screen Space**: Touch input, UI overlays (0,0 = top-left of device screen)
2. **Document Space**: Stored drawing data (0,0 = top-left of virtual 2048x2048 canvas)
3. **Texture Space**: Metal texture pixels (0,0 = top-left of 2048x2048 texture)

### Why This Matters

If you store strokes in screen space:
- ❌ Zooming in → strokes appear stretched
- ❌ Rotating canvas → stored drawing rotates permanently
- ❌ Panning → drawing moves relative to canvas
- ❌ Different screen sizes → drawing scales incorrectly

If you store strokes in document space:
- ✅ Zoom/pan/rotate affects display only
- ✅ Source drawing remains pristine
- ✅ Works on any screen size
- ✅ Undo/redo works correctly

---

## Current State Analysis

### What Already Exists ✅

**CanvasStateManager.swift** already has:
```swift
@Published var zoomScale: CGFloat = 1.0
@Published var panOffset: CGPoint = .zero
let minZoom: CGFloat = 0.1
let maxZoom: CGFloat = 10.0

func screenToDocument(_ point: CGPoint) -> CGPoint
func documentToScreen(_ point: CGPoint) -> CGPoint
func zoom(scale: CGFloat, centerPoint: CGPoint)
func pan(delta: CGPoint)
func resetZoomAndPan()
```

**MetalCanvasView.swift** already has:
```swift
UIPinchGestureRecognizer  // Two-finger pinch for zoom
UIPanGestureRecognizer    // Two-finger pan (minimumNumberOfTouches = 2)
```

**Shaders.metal** already has:
```metal
vertex VertexOut quadVertexShaderWithTransform(
    constant float4 *transform [[buffer(0)]],  // [zoom, panX, panY, unused]
    // ...applies zoom and pan to vertex positions
)
```

**CanvasRenderer.swift** already has:
```swift
func renderTextureToScreen(
    _ texture: MTLTexture,
    opacity: Float,
    zoomScale: Float,
    panOffset: SIMD2<Float>,
    viewportSize: SIMD2<Float>
)
```

### Critical Bugs 🐛

**BUG #1: Touch coordinates not transformed**
```swift
// MetalCanvasView.Coordinator, lines 256-279
override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first else { return }
    let location = touch.location(in: view)  // ❌ SCREEN SPACE!
    // This location is used directly without transformation
}
```

**Impact:** Drawing while zoomed/panned draws at wrong location!

**BUG #2: Preview stroke not transformed**
```swift
// MetalCanvasView.Coordinator, lines 232-234
if let preview = currentStroke {
    renderer?.renderPreviewStroke(preview, to: renderEncoder)
    // ❌ Preview drawn in screen space, not accounting for zoom/pan
}
```

**Impact:** Preview stroke appears at wrong position while drawing!

**BUG #3: Selection overlays not transformed**
```swift
// DrawingCanvasView.swift, selection overlays are SwiftUI views
// They use screen coordinates directly without accounting for canvas transform
```

**Impact:** Marching ants and transform handles appear at wrong positions!

---

## Coordinate Space Architecture

### The Transform Chain

```
Screen Space → Document Space → Texture Space
     ↓              ↓                ↓
  Touches      Stored Data      Metal Rendering
  Gestures     Calculations     GPU Operations
  UI Overlays  Hit Testing
```

### Implementation in CanvasStateManager

#### Current Implementation (Zoom + Pan Only)
```swift
func screenToDocument(_ point: CGPoint) -> CGPoint {
    let adjustedX = (point.x - panOffset.x) / zoomScale
    let adjustedY = (point.y - panOffset.y) / zoomScale
    return CGPoint(x: adjustedX, y: adjustedY)
}

func documentToScreen(_ point: CGPoint) -> CGPoint {
    let scaledX = point.x * zoomScale
    let scaledY = point.y * zoomScale
    return CGPoint(x: scaledX + panOffset.x, y: scaledY + panOffset.y)
}
```

#### Future Implementation (Zoom + Pan + Rotation)
```swift
@Published var canvasRotation: Angle = .zero  // Add this property

func screenToDocument(_ point: CGPoint) -> CGPoint {
    // Step 1: Translate to origin (remove pan)
    var pt = CGPoint(
        x: point.x - panOffset.x,
        y: point.y - panOffset.y
    )

    // Step 2: Get viewport center for rotation pivot
    guard let viewportSize = viewportSize else { return point }
    let centerX = viewportSize.width / 2
    let centerY = viewportSize.height / 2

    // Step 3: Translate to rotation origin
    pt.x -= centerX
    pt.y -= centerY

    // Step 4: Apply inverse rotation
    let angle = -canvasRotation.radians  // Negative for inverse
    let rotatedX = pt.x * cos(angle) - pt.y * sin(angle)
    let rotatedY = pt.x * sin(angle) + pt.y * cos(angle)

    // Step 5: Translate back from rotation origin
    pt.x = rotatedX + centerX
    pt.y = rotatedY + centerY

    // Step 6: Apply inverse zoom
    pt.x /= zoomScale
    pt.y /= zoomScale

    return pt
}

func documentToScreen(_ point: CGPoint) -> CGPoint {
    guard let viewportSize = viewportSize else { return point }
    let centerX = viewportSize.width / 2
    let centerY = viewportSize.height / 2

    // Step 1: Apply zoom
    var pt = CGPoint(
        x: point.x * zoomScale,
        y: point.y * zoomScale
    )

    // Step 2: Translate to rotation origin
    pt.x -= centerX
    pt.y -= centerY

    // Step 3: Apply rotation
    let angle = canvasRotation.radians
    let rotatedX = pt.x * cos(angle) - pt.y * sin(angle)
    let rotatedY = pt.x * sin(angle) + pt.y * cos(angle)

    // Step 4: Translate back and apply pan
    pt.x = rotatedX + centerX + panOffset.x
    pt.y = rotatedY + centerY + panOffset.y

    return pt
}
```

### Order of Operations Matters!

**Wrong Order:**
```
Rotate → Pan → Zoom  ❌ Canvas rotates around wrong point
```

**Correct Order (Inverse Transform):**
```
Remove Pan → Translate to Origin → Rotate → Scale → Translate Back
```

**Correct Order (Forward Transform):**
```
Translate to Origin → Scale → Rotate → Translate Back → Add Pan
```

---

## Zoom Implementation

### Step 1: Add Viewport Size Tracking

**CanvasStateManager.swift:**
```swift
@Published var viewportSize: CGSize?  // Add this property

// Call this from MetalCanvasView when view size changes
func updateViewportSize(_ size: CGSize) {
    viewportSize = size
}
```

**MetalCanvasView.Coordinator:**
```swift
override func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    Task { @MainActor in
        canvasState?.updateViewportSize(size)
    }
}
```

### Step 2: Fix Touch Coordinate Transformation

**MetalCanvasView.Coordinator - Replace ALL touch handlers:**

```swift
override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first,
          let canvasState = canvasState else { return }

    // ✅ CORRECT: Transform to document space
    let screenLocation = touch.location(in: view)
    let documentLocation = canvasState.screenToDocument(screenLocation)

    // Use documentLocation for all drawing operations
    switch canvasState.selectedTool {
    case .brush, .eraser:
        let pressure = touch.force > 0 ? touch.force / touch.maximumPossibleForce : 1.0
        let point = StrokePoint(
            location: documentLocation,  // ✅ Document space
            pressure: pressure,
            timestamp: touch.timestamp
        )
        currentStroke = BrushStroke(/* ... */)
        currentStroke?.points.append(point)

    case .rectangleSelect, .lassoSelect:
        // Use documentLocation for selection start
        // ...
    }
}

override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first,
          let canvasState = canvasState else { return }

    let screenLocation = touch.location(in: view)
    let documentLocation = canvasState.screenToDocument(screenLocation)

    // Add to stroke or update selection
    if var stroke = currentStroke {
        let pressure = touch.force > 0 ? touch.force / touch.maximumPossibleForce : 1.0
        stroke.points.append(StrokePoint(
            location: documentLocation,  // ✅ Document space
            pressure: pressure,
            timestamp: touch.timestamp
        ))
        currentStroke = stroke
    }
}
```

### Step 3: Fix Preview Stroke Rendering

**CanvasRenderer.swift - Update renderPreviewStroke:**

```swift
func renderPreviewStroke(
    _ stroke: BrushStroke,
    to renderEncoder: MTLRenderCommandEncoder,
    zoomScale: Float = 1.0,
    panOffset: SIMD2<Float> = SIMD2<Float>(0, 0),
    canvasRotation: Float = 0.0,  // Radians
    viewportSize: SIMD2<Float>
) {
    guard !stroke.points.isEmpty else { return }

    // Transform document space points to screen space for display
    var screenPoints: [SIMD2<Float>] = []

    for point in stroke.points {
        // Document → Screen transformation
        var pt = SIMD2<Float>(Float(point.location.x), Float(point.location.y))

        // Apply zoom
        pt *= zoomScale

        // Rotate around viewport center
        let center = viewportSize / 2.0
        pt -= center
        let cosAngle = cos(canvasRotation)
        let sinAngle = sin(canvasRotation)
        let rotatedX = pt.x * cosAngle - pt.y * sinAngle
        let rotatedY = pt.x * sinAngle + pt.y * cosAngle
        pt = SIMD2<Float>(rotatedX, rotatedY)
        pt += center

        // Add pan
        pt += panOffset

        screenPoints.append(pt)
    }

    // Render screenPoints with existing pipeline
    // ...
}
```

**MetalCanvasView.Coordinator - Update preview rendering call:**

```swift
// In draw(in view:) method
if let preview = currentStroke {
    let zoomScale = MainActor.assumeIsolated { canvasState?.zoomScale ?? 1.0 }
    let panOffset = MainActor.assumeIsolated { canvasState?.panOffset ?? .zero }
    let rotation = MainActor.assumeIsolated { canvasState?.canvasRotation.radians ?? 0.0 }

    renderer?.renderPreviewStroke(
        preview,
        to: renderEncoder,
        zoomScale: Float(zoomScale),
        panOffset: SIMD2<Float>(Float(panOffset.x), Float(panOffset.y)),
        canvasRotation: Float(rotation),
        viewportSize: SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height))
    )
}
```

### Step 4: Ensure Smooth Zoom Gesture

**MetalCanvasView.swift - Pinch gesture is already implemented:**

```swift
@objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
    guard let canvasState = canvasState else { return }

    switch gesture.state {
    case .began, .changed:
        let location = gesture.location(in: self)
        let newScale = canvasState.zoomScale * gesture.scale

        Task { @MainActor in
            canvasState.zoom(scale: newScale, centerPoint: location)
        }

        gesture.scale = 1.0  // Reset for next delta

    default:
        break
    }
}
```

**This already works correctly!** The zoom method anchors to the pinch point.

### Step 5: Add Zoom UI Indicators (Optional)

**Add to DrawingCanvasView.swift:**

```swift
// Overlay zoom level indicator
.overlay(alignment: .topTrailing) {
    if canvasState.zoomScale != 1.0 {
        Text("\(Int(canvasState.zoomScale * 100))%")
            .font(.caption)
            .padding(8)
            .background(.ultraThinMaterial)
            .cornerRadius(8)
            .padding()
            .transition(.opacity)
    }
}
```

---

## Rotation Implementation

### Step 1: Add Rotation State

**CanvasStateManager.swift:**

```swift
@Published var canvasRotation: Angle = .zero
let rotationSnappingInterval: Angle = .degrees(15)  // Snap to 15° increments
var enableRotationSnapping: Bool = true

func rotate(by angle: Angle, snapToGrid: Bool = true) {
    var newRotation = canvasRotation + angle

    // Normalize to 0-360°
    while newRotation.degrees >= 360 {
        newRotation = .degrees(newRotation.degrees - 360)
    }
    while newRotation.degrees < 0 {
        newRotation = .degrees(newRotation.degrees + 360)
    }

    // Snap to grid if enabled
    if snapToGrid && enableRotationSnapping {
        let snappedDegrees = round(newRotation.degrees / rotationSnappingInterval.degrees) * rotationSnappingInterval.degrees
        newRotation = .degrees(snappedDegrees)
    }

    canvasRotation = newRotation
}

func resetRotation() {
    canvasRotation = .zero
}

func resetAllTransforms() {
    resetZoomAndPan()
    resetRotation()
}
```

### Step 2: Add Rotation Gesture Recognizer

**MetalCanvasView.swift:**

```swift
// In makeUIView, add rotation gesture:
let rotationGesture = UIRotationGestureRecognizer(
    target: context.coordinator,
    action: #selector(Coordinator.handleRotation(_:))
)
rotationGesture.delegate = context.coordinator
mtkView.addGestureRecognizer(rotationGesture)

// In Coordinator class:
@objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
    guard let canvasState = canvasState else { return }

    switch gesture.state {
    case .began, .changed:
        let rotationAngle = Angle(radians: gesture.rotation)

        Task { @MainActor in
            // Disable snapping if user holds down option key (on iPad with keyboard)
            let snapToGrid = !gesture.modifierFlags.contains(.alternate)
            canvasState.rotate(by: rotationAngle, snapToGrid: snapToGrid)
        }

        gesture.rotation = 0  // Reset for next delta

    case .ended:
        // Optionally snap to nearest 90° on release
        let currentDegrees = canvasState.canvasRotation.degrees
        let nearest90 = round(currentDegrees / 90) * 90

        if abs(currentDegrees - nearest90) < 5 {  // Within 5° of 90° increment
            Task { @MainActor in
                canvasState.canvasRotation = .degrees(nearest90)
            }
        }

    default:
        break
    }
}

// Update gestureRecognizer delegate to allow simultaneous rotation + pinch:
func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
) -> Bool {
    // Allow rotation + pinch + pan to work together
    return true
}
```

### Step 3: Update Metal Shader for Rotation

**Shaders.metal - Update quadVertexShaderWithTransform:**

```metal
vertex VertexOut quadVertexShaderWithTransform(
    uint vertexID [[vertex_id]],
    constant float4 *transform [[buffer(0)]],     // [zoom, panX, panY, rotation]
    constant float2 *viewportSize [[buffer(1)]]
) {
    // Unpack transform parameters
    float zoom = transform[0][0];
    float2 pan = float2(transform[0][1], transform[0][2]);
    float rotation = transform[0][3];  // Radians

    // Quad vertices (full screen)
    const float2 positions[6] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1, 1), float2(1, -1), float2(1, 1)
    };

    const float2 texCoords[6] = {
        float2(0, 1), float2(1, 1), float2(0, 0),
        float2(0, 0), float2(1, 1), float2(1, 0)
    };

    float2 position = positions[vertexID];
    float2 texCoord = texCoords[vertexID];

    // Convert normalized device coordinates to screen space
    float2 viewport = *viewportSize;
    float2 screenPos = (position * 0.5 + 0.5) * viewport;

    // Transform: Zoom → Rotate → Pan
    // Step 1: Apply zoom (scale around viewport center)
    float2 center = viewport * 0.5;
    screenPos = (screenPos - center) * zoom + center;

    // Step 2: Apply rotation (rotate around viewport center)
    float2 rotated = screenPos - center;
    float cosAngle = cos(rotation);
    float sinAngle = sin(rotation);
    screenPos.x = rotated.x * cosAngle - rotated.y * sinAngle + center.x;
    screenPos.y = rotated.x * sinAngle + rotated.y * cosAngle + center.y;

    // Step 3: Apply pan
    screenPos += pan;

    // Convert back to normalized device coordinates
    float2 finalPos = (screenPos / viewport) * 2.0 - 1.0;

    // Transform texture coordinates inversely
    float2 finalTexCoord = texCoord;

    // Inverse pan
    float2 texScreenPos = finalTexCoord * viewport;
    texScreenPos -= pan;

    // Inverse rotation
    float2 texRotated = texScreenPos - center;
    finalTexCoord.x = (texRotated.x * cosAngle + texRotated.y * sinAngle + center.x) / viewport.x;
    finalTexCoord.y = (texRotated.y * cosAngle - texRotated.x * sinAngle + center.y) / viewport.y;

    // Inverse zoom
    finalTexCoord = (finalTexCoord - 0.5) / zoom + 0.5;

    VertexOut out;
    out.position = float4(finalPos, 0.0, 1.0);
    out.texCoord = finalTexCoord;
    return out;
}
```

### Step 4: Update Renderer to Pass Rotation

**CanvasRenderer.swift - Update renderTextureToScreen:**

```swift
func renderTextureToScreen(
    _ texture: MTLTexture,
    to renderEncoder: MTLRenderCommandEncoder,
    opacity: Float = 1.0,
    zoomScale: Float = 1.0,
    panOffset: SIMD2<Float> = SIMD2<Float>(0, 0),
    canvasRotation: Float = 0.0,  // Add rotation parameter (radians)
    viewportSize: SIMD2<Float> = SIMD2<Float>(0, 0)
) {
    renderEncoder.setRenderPipelineState(texturePipelineState)
    renderEncoder.setFragmentTexture(texture, index: 0)

    // Pack transform: [zoom, panX, panY, rotation]
    var transform = SIMD4<Float>(zoomScale, panOffset.x, panOffset.y, canvasRotation)
    renderEncoder.setVertexBytes(&transform, length: MemoryLayout<SIMD4<Float>>.size, index: 0)

    var viewport = viewportSize
    renderEncoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)

    var opacityUniform = opacity
    renderEncoder.setFragmentBytes(&opacityUniform, length: MemoryLayout<Float>.size, index: 0)

    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
}
```

### Step 5: Update Draw Loop

**MetalCanvasView.Coordinator - Update draw(in view:):**

```swift
// Get all transform parameters
let zoomScale = MainActor.assumeIsolated { canvasState?.zoomScale ?? 1.0 }
let panOffset = MainActor.assumeIsolated { canvasState?.panOffset ?? .zero }
let rotation = MainActor.assumeIsolated { canvasState?.canvasRotation.radians ?? 0.0 }

// Render each layer with full transform
for layer in layers where layer.isVisible {
    if let texture = layer.texture {
        renderer?.renderTextureToScreen(
            texture,
            to: renderEncoder,
            opacity: layer.opacity,
            zoomScale: Float(zoomScale),
            panOffset: SIMD2<Float>(Float(panOffset.x), Float(panOffset.y)),
            canvasRotation: Float(rotation),
            viewportSize: SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height))
        )
    }
}
```

### Step 6: Add Rotation UI Controls

**Add to DrawingCanvasView.swift toolbar:**

```swift
// Rotation controls
Button {
    canvasState.rotate(by: .degrees(-90))
} label: {
    Image(systemName: "rotate.left")
}

Button {
    canvasState.rotate(by: .degrees(90))
} label: {
    Image(systemName: "rotate.right")
}

Button {
    canvasState.resetAllTransforms()
} label: {
    Image(systemName: "arrow.counterclockwise")
}
.help("Reset zoom, pan, and rotation")
```

---

## Critical Bug Fixes Required

### Bug Fix #1: Transform All Touch Input

**Every touch handler must use screenToDocument():**

```swift
// ❌ WRONG:
let location = touch.location(in: view)
doSomethingWith(location)

// ✅ CORRECT:
let screenLocation = touch.location(in: view)
let documentLocation = canvasState.screenToDocument(screenLocation)
doSomethingWith(documentLocation)
```

**Locations to fix in MetalCanvasView.Coordinator:**
- `touchesBegan` (line ~256)
- `touchesMoved` (line ~287)
- `touchesEnded` (line ~329)
- Any selection tool code
- Any shape tool code

### Bug Fix #2: Transform Selection Overlays

**Selection overlays are currently SwiftUI views in screen space.**

**Option A: Keep as SwiftUI, transform bounds**

```swift
// In DrawingCanvasView.swift
if let selection = canvasState.activeSelection {
    // Convert document space selection to screen space
    let topLeft = canvasState.documentToScreen(selection.origin)
    let bottomRight = canvasState.documentToScreen(
        CGPoint(x: selection.maxX, y: selection.maxY)
    )

    let screenRect = CGRect(
        x: topLeft.x,
        y: topLeft.y,
        width: bottomRight.x - topLeft.x,
        height: bottomRight.y - topLeft.y
    )

    MarchingAntsView(rect: screenRect)
    TransformHandlesView(rect: screenRect)
}
```

**Option B: Render in Metal (better performance)**

Move selection rendering to Metal so it respects zoom/pan/rotation automatically.

### Bug Fix #3: Fix Stroke Rendering Pipeline

**Ensure document→texture scaling is correct:**

```swift
// In CanvasRenderer, when rendering strokes to texture:
func renderStrokeToTexture(
    _ stroke: BrushStroke,
    texture: MTLTexture
) {
    // Stroke points are in document space (0-screenSize range)
    // Texture is fixed 2048x2048

    let documentSize = viewportSize ?? CGSize(width: 2048, height: 2048)
    let scaleX = Float(texture.width) / Float(documentSize.width)
    let scaleY = Float(texture.height) / Float(documentSize.height)

    for i in 0..<stroke.points.count - 1 {
        let p0 = stroke.points[i]
        let p1 = stroke.points[i + 1]

        // Scale document coordinates to texture coordinates
        let tp0 = SIMD2<Float>(
            Float(p0.location.x) * scaleX,
            Float(p0.location.y) * scaleY
        )
        let tp1 = SIMD2<Float>(
            Float(p1.location.x) * scaleX,
            Float(p1.location.y) * scaleY
        )

        // Render line segment at texture coordinates
        // ...
    }
}
```

### Bug Fix #4: Handle Edge Cases

**Prevent gimbal lock and numeric instability:**

```swift
// In CanvasStateManager
func zoom(scale: CGFloat, centerPoint: CGPoint) {
    // Clamp zoom to prevent floating point errors
    let newScale = min(max(scale, minZoom), maxZoom)

    // Prevent zoom if change is negligible
    guard abs(newScale - zoomScale) > 0.001 else { return }

    let docPoint = screenToDocument(centerPoint)
    zoomScale = newScale

    // Recalculate pan to keep point under finger
    let newScreenPoint = CGPoint(x: docPoint.x * zoomScale, y: docPoint.y * zoomScale)
    panOffset.x += centerPoint.x - newScreenPoint.x
    panOffset.y += centerPoint.y - newScreenPoint.y
}

func rotate(by angle: Angle, snapToGrid: Bool = true) {
    // Prevent rotation if change is negligible
    guard abs(angle.degrees) > 0.1 else { return }

    var newRotation = canvasRotation + angle

    // Normalize to 0-360° to prevent overflow
    newRotation = .degrees(newRotation.degrees.truncatingRemainder(dividingBy: 360))
    if newRotation.degrees < 0 {
        newRotation = .degrees(newRotation.degrees + 360)
    }

    canvasRotation = newRotation
}
```

**Prevent pan from going too far:**

```swift
func pan(delta: CGPoint) {
    // Optional: Limit pan to prevent canvas from going off-screen entirely
    let maxPan: CGFloat = 5000  // Arbitrary large number

    panOffset.x = min(max(panOffset.x + delta.x, -maxPan), maxPan)
    panOffset.y = min(max(panOffset.y + delta.y, -maxPan), maxPan)
}
```

### Bug Fix #5: Disable Transform Gestures During Drawing

**Prevent accidental zoom/pan/rotate while drawing:**

```swift
// In MetalCanvasView.Coordinator
func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    // Disable transform gestures while actively drawing
    if currentStroke != nil {
        return false
    }
    return true
}
```

---

## Testing & Validation

### Test Case 1: Draw → Zoom → Verify Position

```
1. Draw a small circle in center of canvas
2. Pinch zoom to 2x
3. Expected: Circle appears larger but stays in center
4. Expected: Touch coordinates still align with drawing
5. Draw another circle next to first
6. Expected: Circles maintain relative positions
```

### Test Case 2: Draw → Rotate → Verify Integrity

```
1. Draw horizontal line across canvas
2. Rotate canvas 45°
3. Expected: Line appears rotated on screen
4. Expected: Line is still perfectly horizontal in document space
5. Export canvas → line should be horizontal in export
6. Undo rotation → line returns to horizontal on screen
```

### Test Case 3: Zoom + Rotate + Pan Combo

```
1. Draw grid pattern
2. Zoom to 3x
3. Rotate 30°
4. Pan to top-left corner
5. Draw new strokes
6. Reset all transforms
7. Expected: All strokes align perfectly in document space
```

### Test Case 4: Selection with Transforms

```
1. Draw multiple strokes
2. Zoom 2x and pan
3. Select strokes with rectangle select
4. Expected: Selection marquee aligns with visible strokes
5. Move selection
6. Expected: Strokes move correctly relative to canvas
```

### Test Case 5: Undo/Redo with Transforms

```
1. Draw stroke
2. Zoom 2x
3. Draw another stroke
4. Undo
5. Expected: Second stroke disappears, first remains
6. Rotate 45°
7. Redo
8. Expected: Second stroke reappears in correct position
```

### Test Case 6: Multi-Touch Edge Cases

```
1. Start drawing with one finger
2. While drawing, try to pinch with other fingers
3. Expected: Pinch blocked while drawing
4. Release drawing finger, then pinch
5. Expected: Zoom works normally
```

### Test Case 7: Performance Under Load

```
1. Zoom to 0.1x (view entire canvas)
2. Draw complex stroke with 1000+ points
3. Zoom to 10x on part of stroke
4. Expected: 60 FPS maintained
5. Expected: No visible lag or stuttering
```

### Validation Checklist

- [ ] Touch coordinates transform correctly at all zoom levels
- [ ] Drawing at 0.1x zoom matches position at 10x zoom
- [ ] Rotation doesn't affect stored stroke data
- [ ] Preview stroke appears at correct position while drawing
- [ ] Selection overlays align with selected pixels
- [ ] Transform handles are grabbable and work correctly
- [ ] Undo/redo preserves canvas state correctly
- [ ] Export generates unmodified canvas (no rotation/zoom baked in)
- [ ] Gestures don't interfere with drawing
- [ ] No floating point drift after many transforms
- [ ] Performance remains smooth (60 FPS) during transforms
- [ ] Two-finger gestures work simultaneously (pinch + rotate)

---

## Performance Considerations

### Optimization 1: Minimize State Updates

```swift
// ❌ BAD: Updates every frame during gesture
@objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
    canvasState.zoomScale *= gesture.scale
    gesture.scale = 1.0
}

// ✅ GOOD: Batched calculation
@objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
    let newScale = canvasState.zoomScale * gesture.scale
    canvasState.zoom(scale: newScale, centerPoint: gesture.location(in: self))
    gesture.scale = 1.0
}
```

### Optimization 2: Cache Transformed Coordinates

**For preview strokes with many points:**

```swift
// In CanvasRenderer
private var previewTransformCache: (
    points: [SIMD2<Float>],
    zoom: Float,
    pan: SIMD2<Float>,
    rotation: Float
)?

func renderPreviewStroke(...) {
    // Check if transform changed
    let cacheValid = previewTransformCache?.zoom == zoomScale &&
                     previewTransformCache?.pan == panOffset &&
                     previewTransformCache?.rotation == canvasRotation

    if !cacheValid {
        // Recompute transformed points
        previewTransformCache = (
            points: transformPoints(stroke.points),
            zoom: zoomScale,
            pan: panOffset,
            rotation: canvasRotation
        )
    }

    // Use cached points
    renderLines(previewTransformCache!.points)
}
```

### Optimization 3: Metal Shader Efficiency

**Already optimized:** Transforms happen in vertex shader (GPU), not CPU.

**Why this is fast:**
- Vertex shader runs once per vertex (6 vertices for full-screen quad)
- Texture sampling happens in fragment shader with hardware interpolation
- No CPU-side coordinate transformation for pixel data

### Optimization 4: Avoid Unnecessary Redraws

```swift
// In MetalCanvasView.Coordinator
private var lastTransform: (zoom: CGFloat, pan: CGPoint, rotation: Angle)?

func draw(in view: MTKView) {
    let currentTransform = (
        canvasState?.zoomScale ?? 1.0,
        canvasState?.panOffset ?? .zero,
        canvasState?.canvasRotation ?? .zero
    )

    // Only mark view as needing display if transform actually changed
    let transformChanged = lastTransform?.zoom != currentTransform.0 ||
                          lastTransform?.pan != currentTransform.1 ||
                          lastTransform?.rotation != currentTransform.2

    lastTransform = currentTransform

    // Metal already redraws every frame, but this pattern is useful
    // for SwiftUI overlays that shouldn't redraw unnecessarily
}
```

### Optimization 5: Gesture Recognizer Efficiency

```swift
// Reduce gesture callback frequency
let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
panGesture.minimumNumberOfTouches = 2
panGesture.maximumNumberOfTouches = 2  // Only 2 fingers, not 3+

let rotationGesture = UIRotationGestureRecognizer(...)
rotationGesture.allowableMovement = 10  // Degrees before recognizing
```

### Performance Targets

| Metric | Target | Critical Threshold |
|--------|--------|-------------------|
| Frame Rate | 60 FPS | 30 FPS |
| Gesture Response | < 16ms | < 33ms |
| Transform Update | < 5ms | < 10ms |
| Preview Stroke Render | < 8ms | < 16ms |
| Memory Usage | < 200MB | < 500MB |

### Memory Management

```swift
// Ensure textures are released when zooming out
func optimizeMemoryForZoom() {
    if zoomScale < 0.5 {
        // Consider reducing texture resolution for distant view
        // Or enable texture compression
    }
}
```

---

## Summary: Implementation Checklist

### Phase 1: Fix Existing Zoom (Critical Bugs)
- [ ] Add `viewportSize` tracking to CanvasStateManager
- [ ] Transform all touch input through `screenToDocument()`
- [ ] Fix preview stroke rendering with transform
- [ ] Fix selection overlay positioning
- [ ] Add gesture blocking during active drawing
- [ ] Test: Draw at 1x, zoom to 5x, verify alignment

### Phase 2: Add Rotation
- [ ] Add `canvasRotation` property to CanvasStateManager
- [ ] Implement rotation gesture recognizer
- [ ] Update `screenToDocument()` / `documentToScreen()` for rotation
- [ ] Update Metal shader to apply rotation matrix
- [ ] Update renderer to pass rotation parameter
- [ ] Add rotation UI controls (rotate left/right/reset)
- [ ] Test: Draw, rotate, verify source data unchanged

### Phase 3: Polish & Optimization
- [ ] Add zoom level indicator UI
- [ ] Implement rotation snapping (15° increments)
- [ ] Add haptic feedback for snap points
- [ ] Optimize transform calculations (cache where possible)
- [ ] Add "reset all transforms" button
- [ ] Performance test: Verify 60 FPS during gestures
- [ ] Test all edge cases (see Testing section)

### Phase 4: Professional Features (Optional)
- [ ] Two-finger tap to reset zoom
- [ ] Three-finger tap to undo (like Procreate)
- [ ] Quick zoom gesture (double-tap and drag)
- [ ] Rotation angle indicator during rotation
- [ ] Smooth animation when resetting transforms
- [ ] Keyboard shortcuts (0 = reset, +/- = zoom)

---

## Common Pitfalls to Avoid

### Pitfall 1: Storing Screen Coordinates
**Never store screen space coordinates in BrushStroke data.**

```swift
// ❌ WRONG:
let location = touch.location(in: view)
stroke.points.append(StrokePoint(location: location, ...))

// ✅ CORRECT:
let documentLocation = canvasState.screenToDocument(touch.location(in: view))
stroke.points.append(StrokePoint(location: documentLocation, ...))
```

### Pitfall 2: Transform Order
**Order matters for composite transforms.**

```swift
// ❌ WRONG: Zoom after rotation (rotates around wrong pivot)
apply(rotation)
apply(zoom)

// ✅ CORRECT: Zoom before rotation
apply(zoom)
apply(rotation)
```

### Pitfall 3: Forgetting Inverse Transform
**Screen→Document requires inverse of Document→Screen.**

```swift
// Document → Screen: Scale × Rotate × Translate
// Screen → Document: Inverse(Translate) × Inverse(Rotate) × Inverse(Scale)
```

### Pitfall 4: Ignoring Viewport Center
**Rotation and zoom should pivot around viewport center, not origin.**

```swift
// ✅ Translate to origin before rotating
pt -= viewportCenter
pt = rotate(pt, angle)
pt += viewportCenter
```

### Pitfall 5: Modifying Published Properties Off Main Thread
```swift
// ❌ WRONG: May crash
DispatchQueue.global().async {
    canvasState.zoomScale = 2.0  // Published property!
}

// ✅ CORRECT:
Task { @MainActor in
    canvasState.zoomScale = 2.0
}
```

---

## Conclusion

This guide provides a complete roadmap for implementing professional-grade zoom and rotation in DrawEvolve. The key principles:

1. **Separate display transforms from data storage**
2. **Always use document space for stored coordinates**
3. **Transform touch input immediately**
4. **Apply display transforms in Metal shaders (GPU)**
5. **Test thoroughly with edge cases**

By following this guide, you'll achieve the same smooth, bug-free experience as Procreate and other professional drawing apps.

---

**Next Steps:**
1. Start with Phase 1 (fixing existing zoom bugs)
2. Validate with Test Cases 1-3
3. Proceed to Phase 2 (rotation) only after zoom is solid
4. Polish in Phase 3

**Remember:** The infrastructure is 80% complete. The main work is connecting touch input to the existing transform system and ensuring all rendering respects the canvas transform state.
