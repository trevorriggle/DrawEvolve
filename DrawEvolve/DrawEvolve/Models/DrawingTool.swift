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

    var icon: String {
        switch self {
        case .brush: return "paintbrush.pointed.fill"
        case .eraser: return "eraser.fill"
        case .paintBucket: return "drop.fill"
        case .eyeDropper: return "eyedropper"
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
        }
    }

    var name: String {
        switch self {
        case .brush: return "Brush"
        case .eraser: return "Eraser"
        case .paintBucket: return "Fill"
        case .eyeDropper: return "Pick Color"
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
