//
//  DrawingTool.swift
//  DrawEvolve
//
//  Tools for the drawing canvas.
//

import Foundation
import UIKit

/// Drawing tools
enum DrawingTool {
    case brush
    case eraser
    case paintBucket
    case eyeDropper

    // Experimental brush variants (experiment/brush-variety-v1). Each is a
    // stamp-pipeline tool that rides on the same point-sprite vertex shader
    // and `BrushUniforms` as `.brush`/`.eraser`; only the fragment shader
    // and per-tool defaults differ. Snap-to-line and symmetry handle these
    // automatically because they mutate `stroke.points` upstream of the
    // render dispatch.
    case pencil
    case inkPen
    case marker
    case airbrush
    case charcoal

    // Shape tools
    case line
    case rectangle
    case circle

    // Selection tools
    case rectangleSelect
    case lasso

    // Other tools
    case text
    case textOnPath  // Draw a freehand path, then lay text along it.
    case move
    case rotate  // DEPRECATED: Now integrated into selection transform handles
    case scale   // DEPRECATED: Now integrated into selection transform handles

    // Effect tools
    case blur            // Brush-form Gaussian blur — paints blur freeform along stroke.
    case blurAdjustment  // Procreate-style adjustment tool — horizontal drag → sigma, ✓/✕ commit.
    case smudge          // Reserved for PR 2; no toolbar surface in PR 1.

    // Pose reference tools (DrawEvolve v1.1+ pose feature). These tools
    // surface a Vision-detected reference skeleton on the canvas; they
    // do NOT participate in the brush-stroke pipeline. MetalCanvasView's
    // touchesBegan path is gated by `if currentTool == .X` checks, so
    // adding these cases is no-op for the canvas — strokes are not
    // produced when one of these is the current tool.
    case handPose
    case bodyPose

    var icon: String {
        switch self {
        case .brush: return "paintbrush.pointed.fill"
        case .eraser: return "eraser.fill"
        case .paintBucket: return "drop.fill"
        case .eyeDropper: return "eyedropper"
        case .pencil: return "pencil"
        case .inkPen: return "pencil.tip"
        case .marker: return "highlighter"
        case .airbrush: return "wind"
        case .charcoal: return "scribble.variable"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .rectangleSelect: return "rectangle.dashed"
        case .lasso: return "lasso"
        case .text: return "textformat"
        case .textOnPath: return "textformat.abc.dottedunderline"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .rotate: return "rotate.right"
        case .scale: return "arrow.up.left.and.arrow.down.right"
        case .blur: return "drop.halffull"
        case .blurAdjustment: return "camera.filters"
        case .smudge: return "hand.draw.fill"
        case .handPose: return "hand.raised"
        case .bodyPose: return "figure.stand"
        }
    }

    var name: String {
        switch self {
        case .brush: return "Brush"
        case .eraser: return "Eraser"
        case .paintBucket: return "Fill"
        case .eyeDropper: return "Pick Color"
        case .pencil: return "Pencil"
        case .inkPen: return "Ink Pen"
        case .marker: return "Marker"
        case .airbrush: return "Airbrush"
        case .charcoal: return "Charcoal"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .circle: return "Circle"
        case .rectangleSelect: return "Select Rectangle"
        case .lasso: return "Lasso"
        case .text: return "Text"
        case .textOnPath: return "Text on Path"
        case .move: return "Move"
        case .rotate: return "Rotate"
        case .scale: return "Scale"
        case .blur: return "Blur Brush"
        case .blurAdjustment: return "Blur"
        case .smudge: return "Smudge"
        case .handPose: return "Hand Pose"
        case .bodyPose: return "Body Pose"
        }
    }
}

/// Brush settings
struct BrushSettings {
    // Doubled from 5 to preserve the previous on-screen stamp size after
    // the canvas texture bump (2048→4096 on iPad Pro). size is in doc pixels;
    // doubling the doc resolution halves the on-screen thickness at the same
    // numeric size, so we compensate the default.
    var size: CGFloat = 10.0
    var opacity: CGFloat = 1.0
    var hardness: CGFloat = 0.8
    var spacing: CGFloat = 0.1
    var pressureSensitivity: Bool = true
    var color: UIColor = .black

    // Pressure curve adjustments
    var minPressureSize: CGFloat = 0.3
    var maxPressureSize: CGFloat = 1.0

    // Blur brush: mix weight between blurred output and original under each
    // stamp. 0 = no effect, 1 = full replace with blurred sample.
    var blurStrength: Float = 1.0

    // Smudge brush (PR 2): pickup/deposit weight in the patch-update pass.
    var smudgeStrength: Float = 0.5

    // Charcoal grain density (experiment/brush-variety-v1). Multiplied into
    // the procedural `hash(fragCoord)` term inside `charcoalFragmentShader`;
    // 0 = smooth (no grain), 1 = fully speckled. Only surfaced in the
    // settings UI when activeTool is `.charcoal`.
    var grainDensity: Float = 0.5

    /// Calibrated per-brush starting values. Each brush variant has a
    /// distinct design intent (graphite vs ink vs charcoal vs airbrush)
    /// that's only legible at the right size + edge + grain. CanvasState
    /// applies these on tool change so a fresh-out-of-the-tab Charcoal
    /// doesn't look like a default Brush — they actually feel different
    /// immediately. The user can still adjust within session via the
    /// settings panel; the snap-back happens on the next tool switch.
    static func defaults(for tool: DrawingTool) -> BrushSettings? {
        var s = BrushSettings()
        switch tool {
        case .brush:
            s.size = 10
            s.opacity = 1.0
            s.hardness = 0.8
            s.spacing = 0.1
        case .pencil:
            s.size = 5            // graphite is narrow
            s.opacity = 0.55      // strokes build up; not opaque per stamp
            s.hardness = 0.95     // sharp edge
            s.spacing = 0.05      // tight spacing for smooth lines
        case .inkPen:
            s.size = 7            // medium-thin
            s.opacity = 1.0       // confident solid lines
            s.hardness = 1.0      // hard edge (the shader enforces this too)
            s.spacing = 0.04      // very tight spacing — no gaps in a line
        case .marker:
            s.size = 14           // wider than brush
            s.opacity = 0.45      // semi-transparent; overlapping deepens
            s.hardness = 0.6      // soft-ish but flat-topped
            s.spacing = 0.05
        case .airbrush:
            s.size = 65           // big mist
            s.opacity = 0.08      // very light per-stamp
            s.hardness = 0.0      // soft falloff (shader uses quadratic anyway)
            s.spacing = 0.02      // tight overlap for density build
        case .charcoal:
            s.size = 24           // wide charcoal stick
            s.opacity = 0.85      // heavy deposit
            s.hardness = 0.4      // soft-ish edge
            s.spacing = 0.06
            s.grainDensity = 0.9  // very speckled by default
        default:
            return nil            // non-brush tools — caller does nothing
        }
        return s
    }
}

/// Represents a single brush stroke
struct BrushStroke {
    let id = UUID()
    var points: [StrokePoint]
    let settings: BrushSettings
    let tool: DrawingTool
    let layerId: UUID

    struct StrokePoint {
        let location: CGPoint
        let pressure: CGFloat
        let timestamp: TimeInterval
    }
}
