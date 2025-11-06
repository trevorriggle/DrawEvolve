# Canvas Rotation Stretching Fix - Second Iteration

## Root Cause
The previous fix (commit b14d599) attempted to solve rotation stretching by adding aspect ratio correction in the shader. However, this was actually **introducing** the stretching problem, not fixing it!

### The Real Issue
The shader was applying aspect ratio correction based on the **viewport (screen) dimensions**, but texture coordinates are already in normalized 0-1 space which is **aspect-ratio neutral**.

When rotating:
- Canvas texture: 2048x2048 (square, aspect ratio 1.0)
- Screen viewport: varies with orientation (e.g., 1024x768 in landscape = 1.33 aspect ratio)
- Shader calculated: `aspectRatio = viewport.width / viewport.height` = 1.33
- Shader scaled Y coords by 1.33 before rotation, then unscaled after
- **Result: Stretched drawings** because we're applying non-square correction to square texture coordinates!

### The Solution
Remove the aspect ratio correction entirely. Texture coordinates in normalized 0-1 space don't need aspect ratio correction when rotating. They're already in a coordinate system that's independent of physical dimensions.

## Changes Made (Shaders.metal:129-156)

**Removed:**
- Aspect ratio calculation: `float aspectRatio = viewport.x / viewport.y`
- Y-axis scaling before rotation: `finalTexCoord.y *= aspectRatio`
- Y-axis unscaling after rotation: `finalTexCoord.y /= aspectRatio`

**Kept:**
- Pan offset conversion to normalized space
- Rotation around center point (0.5, 0.5)
- Zoom in normalized space

The inverse transformation now correctly operates entirely in normalized texture space without any aspect ratio corrections.

## Expected Results
 Circles remain perfectly circular at all rotation angles
 Squares maintain equal sides at all rotation angles
 Line lengths preserved during rotation
 Works identically in portrait and landscape orientations
 Combined zoom+pan+rotate work without artifacts

## Testing
Please test by:
1. Drawing a perfect circle
2. Rotating the canvas in various increments (45°, 90°, arbitrary angles)
3. Verifying the circle remains circular (not elliptical)
4. Testing in both portrait and landscape iPad orientations
5. Testing with combined zoom + rotation
