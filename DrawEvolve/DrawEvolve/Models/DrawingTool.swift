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

    var icon: String {
        switch self {
        case .brush: return "paintbrush.pointed.fill"
        case .eraser: return "eraser.fill"
        case .paintBucket: return "paintpalette.fill"
        case .eyeDropper: return "eyedropper"
        }
    }

    var name: String {
        switch self {
        case .brush: return "Brush"
        case .eraser: return "Eraser"
        case .paintBucket: return "Fill"
        case .eyeDropper: return "Pick Color"
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
