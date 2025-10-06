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
    case polygon

    // Selection tools
    case rectangleSelect
    case lasso
    case magicWand

    // Effect tools
    case smudge
    case blur
    case sharpen
    case cloneStamp

    // Other tools
    case text
    case move
    case rotate
    case scale

    var icon: String {
        switch self {
        case .brush: return "paintbrush.pointed.fill"
        case .eraser: return "eraser.fill"
        case .paintBucket: return "paintpalette.fill"
        case .eyeDropper: return "eyedropper"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .polygon: return "pentagon"
        case .rectangleSelect: return "rectangle.dashed"
        case .lasso: return "lasso"
        case .magicWand: return "wand.and.stars"
        case .smudge: return "hand.draw.fill"
        case .blur: return "aqi.medium"
        case .sharpen: return "triangle.fill"
        case .cloneStamp: return "doc.on.doc.fill"
        case .text: return "textformat"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .rotate: return "rotate.right"
        case .scale: return "arrow.up.left.and.arrow.down.right"
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
        case .polygon: return "Polygon"
        case .rectangleSelect: return "Select Rectangle"
        case .lasso: return "Lasso"
        case .magicWand: return "Magic Wand"
        case .smudge: return "Smudge"
        case .blur: return "Blur"
        case .sharpen: return "Sharpen"
        case .cloneStamp: return "Clone Stamp"
        case .text: return "Text"
        case .move: return "Move"
        case .rotate: return "Rotate"
        case .scale: return "Scale"
        }
    }
}

/// Brush settings
struct BrushSettings {
    var size: CGFloat = 5.0
    var opacity: CGFloat = 1.0
    var hardness: CGFloat = 0.8
    var spacing: CGFloat = 0.1
    var pressureSensitivity: Bool = true
    var color: UIColor = .black

    // Pressure curve adjustments
    var minPressureSize: CGFloat = 0.3
    var maxPressureSize: CGFloat = 1.0
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
