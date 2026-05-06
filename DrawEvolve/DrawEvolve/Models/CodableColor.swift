//
//  CodableColor.swift
//  DrawEvolve
//
//  RGBA component wrapper so UIColor can ride through Codable graphs without
//  pulling in NSCoding or sRGB-vs-displayP3 surprises.
//
//  Components are stored in extended-sRGB (UIColor.getRed semantics) —
//  round-tripping through `init(red:green:blue:alpha:)` reproduces the
//  original color faithfully for the colors users pick from
//  AdvancedColorPicker.
//
//  First consumer: TextSettings.color (Codable conformance lands in
//  TextSettings.swift). Second consumer planned: BrushSettings.color when
//  brush settings learn to round-trip. The struct lives on its own file so
//  more UIColor-bearing models can adopt it without growing TextSettings.
//

import Foundation
import UIKit

struct CodableColor: Codable, Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        red = r; green = g; blue = b; alpha = a
    }

    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
