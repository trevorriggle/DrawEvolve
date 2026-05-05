//
//  SymmetryConfig.swift
//  DrawEvolve
//
//  Global symmetry / mirror state for the canvas. Lives outside
//  CanvasStateManager because (a) symmetry is a workflow preference more
//  than per-drawing state and (b) keeping it isolated lets us serialize
//  and persist it via UserDefaults without coupling to the
//  CanvasStateManager surface.
//
//  Persists to UserDefaults — same storage backing @AppStorage uses, just
//  driven from inside the ObservableObject so the API stays clean. Mode
//  changes are written on every set; settings restore on next launch.
//
//  v1 NOTES:
//  - Radial center is fixed at canvas center (documentSize / 2). No
//    `center` field; future radial-drag work lives in a follow-up.
//  - Lock toggle is intentionally absent; with the center fixed, "lock"
//    has nothing to gate. Only `guideHidden` is exposed.
//  - Mirroring math (mirroredPoints, etc.) is NOT in this commit. This
//    commit ships state + persistence + the sub-nav UI scaffold only.
//

import Foundation
import SwiftUI

@MainActor
final class SymmetryConfig: ObservableObject {

    // MARK: - Public types

    enum Mode: Equatable {
        case off
        case axis(AxisConfig)
        case radial(sections: Int)
    }

    /// Which mirror axes are active in `.axis` mode. Both can be true
    /// simultaneously ("Both axes" mode in the picker), producing a
    /// 4-way mirror across the canvas center.
    struct AxisConfig: Equatable {
        /// Mirror across the Y axis (vertical line through canvas center).
        /// Reflection in doc space: (x, y) → (W − x, y).
        /// Picker label: "Y-axis".
        var yAxis: Bool

        /// Mirror across the X axis (horizontal line through canvas center).
        /// Reflection in doc space: (x, y) → (x, H − y).
        /// Picker label: "X-axis".
        var xAxis: Bool
    }

    /// Locked range for radial section count. Spec calls for 2-16.
    static let radialSectionRange: ClosedRange<Int> = 2...16

    /// Default radial section count when the user first picks Radial mode.
    static let defaultRadialSections: Int = 8

    // MARK: - Published state

    @Published var mode: Mode {
        didSet { Self.write(mode: mode, to: defaults) }
    }

    /// When true, the symmetry axes are still enforced on stroke input but
    /// the dashed guide overlay does NOT render. Useful when the user wants
    /// the effect without the visual clutter.
    @Published var guideHidden: Bool {
        didSet { defaults.set(guideHidden, forKey: Keys.guideHidden) }
    }

    // MARK: - Init / persistence

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.mode = Self.readMode(from: defaults)
        self.guideHidden = defaults.bool(forKey: Keys.guideHidden)
    }

    private enum Keys {
        // String discriminator: "off" | "axisY" | "axisX" | "axisBoth" | "radial".
        // Kept as a simple primitive so the @AppStorage-style persistence
        // contract (one UserDefaults key = one primitive value) stays intact.
        static let modeKind = "symmetryModeKind"
        static let radialSections = "symmetryRadialSections"
        static let guideHidden = "symmetryGuideHidden"
    }

    private static func readMode(from defaults: UserDefaults) -> Mode {
        let kind = defaults.string(forKey: Keys.modeKind) ?? "off"
        switch kind {
        case "axisY":
            return .axis(AxisConfig(yAxis: true, xAxis: false))
        case "axisX":
            return .axis(AxisConfig(yAxis: false, xAxis: true))
        case "axisBoth":
            return .axis(AxisConfig(yAxis: true, xAxis: true))
        case "radial":
            let raw = defaults.integer(forKey: Keys.radialSections)
            // `integer(forKey:)` returns 0 when absent; clamp to the valid
            // range and fall back to the default if so.
            let n = raw == 0
                ? defaultRadialSections
                : max(radialSectionRange.lowerBound, min(radialSectionRange.upperBound, raw))
            return .radial(sections: n)
        default:
            return .off
        }
    }

    private static func write(mode: Mode, to defaults: UserDefaults) {
        switch mode {
        case .off:
            defaults.set("off", forKey: Keys.modeKind)
        case .axis(let cfg):
            // Both axes false collapses to .off — picker can't reach this
            // state but a programmatic set could. Persist as off to keep
            // hydrate-on-launch consistent.
            switch (cfg.yAxis, cfg.xAxis) {
            case (true, false):  defaults.set("axisY", forKey: Keys.modeKind)
            case (false, true):  defaults.set("axisX", forKey: Keys.modeKind)
            case (true, true):   defaults.set("axisBoth", forKey: Keys.modeKind)
            case (false, false): defaults.set("off", forKey: Keys.modeKind)
            }
        case .radial(let n):
            defaults.set("radial", forKey: Keys.modeKind)
            defaults.set(n, forKey: Keys.radialSections)
        }
    }
}

// MARK: - Picker option enum
//
// Flat enum used by SymmetrySettingsView's mode Picker. Mode (with its
// associated values) is the source of truth on SymmetryConfig; this is
// the projection the picker binding round-trips through.

enum SymmetryPickerOption: String, CaseIterable, Identifiable {
    case off
    case yAxis
    case xAxis
    case bothAxes
    case radial

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .yAxis: return "Y-axis"
        case .xAxis: return "X-axis"
        case .bothAxes: return "Both axes"
        case .radial: return "Radial"
        }
    }

    /// Project a Mode onto the picker option set. `.radial` collapses any
    /// section count down to the same picker case (sections live in their
    /// own stepper).
    static func from(_ mode: SymmetryConfig.Mode) -> SymmetryPickerOption {
        switch mode {
        case .off: return .off
        case .axis(let cfg):
            switch (cfg.yAxis, cfg.xAxis) {
            case (true, false):  return .yAxis
            case (false, true):  return .xAxis
            case (true, true):   return .bothAxes
            case (false, false): return .off
            }
        case .radial: return .radial
        }
    }
}
