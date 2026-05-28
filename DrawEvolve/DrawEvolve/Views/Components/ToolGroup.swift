//
//  ToolGroup.swift
//  DrawEvolve
//
//  Models for the iPad toolbar's 8-slot grouped layout. Five of the eight
//  slots are grouped (multi-variant with long-press picker); the other
//  three (Brush, Eraser, Move) stay as plain `ToolButton`s at the call
//  site and don't need a group descriptor.
//

import Foundation

/// One option inside a grouped tool slot. Currently all variants are
/// `DrawingTool` cases — the `.textSettings` opener that used to live
/// here was retired in the Tier-1 type-tools overhaul (the modal sheet
/// became an inline inspector that auto-presents whenever a floating
/// text is active, so a separate opener variant is unnecessary).
enum ToolVariant: Hashable {
    case tool(DrawingTool)

    var icon: String {
        switch self {
        case .tool(let t): return t.icon
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .tool(let t): return t.name
        }
    }

    /// Stable string for `@AppStorage` round-trips. Don't rename the
    /// strings without a migration — they survive across launches.
    var storageString: String {
        switch self {
        case .tool(let t): return "tool:" + t.storageKey
        }
    }

    init?(storageString: String) {
        // Legacy migration: older builds persisted "textSettings" as the
        // last-selected variant of the Text group (it opened the modal
        // settings sheet). The sheet is gone; map any persisted value
        // onto `.tool(.text)` so launches with stale storage don't crash.
        if storageString == "textSettings" {
            self = .tool(.text)
            return
        }
        let prefix = "tool:"
        if storageString.hasPrefix(prefix),
           let tool = DrawingTool(storageKey: String(storageString.dropFirst(prefix.count))) {
            self = .tool(tool)
            return
        }
        return nil
    }
}

extension DrawingTool {
    /// Stable identifier used by `ToolVariant.storageString`. Independent
    /// from the SF Symbol name so the icon can change without breaking
    /// saved per-group selections.
    var storageKey: String {
        switch self {
        case .brush: return "brush"
        case .eraser: return "eraser"
        case .paintBucket: return "paintBucket"
        case .eyeDropper: return "eyeDropper"
        case .pencil: return "pencil"
        case .marker: return "marker"
        case .airbrush: return "airbrush"
        case .charcoal: return "charcoal"
        case .line: return "line"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .rectangleSelect: return "rectangleSelect"
        case .lasso: return "lasso"
        case .text: return "text"
        case .textOnPath: return "textOnPath"
        case .move: return "move"
        case .rotate: return "rotate"
        case .scale: return "scale"
        case .blur: return "blur"
        case .blurAdjustment: return "blurAdjustment"
        case .smudge: return "smudge"
        case .handPose: return "handPose"
        case .bodyPose: return "bodyPose"
        }
    }

    init?(storageKey: String) {
        switch storageKey {
        case "brush": self = .brush
        case "eraser": self = .eraser
        case "paintBucket": self = .paintBucket
        case "eyeDropper": self = .eyeDropper
        case "pencil": self = .pencil
        case "marker": self = .marker
        case "airbrush": self = .airbrush
        case "charcoal": self = .charcoal
        case "line": self = .line
        case "rectangle": self = .rectangle
        case "circle": self = .circle
        case "rectangleSelect": self = .rectangleSelect
        case "lasso": self = .lasso
        case "text": self = .text
        case "textOnPath": self = .textOnPath
        case "move": self = .move
        case "rotate": self = .rotate
        case "scale": self = .scale
        case "blur": self = .blur
        case "blurAdjustment": self = .blurAdjustment
        case "smudge": self = .smudge
        case "handPose": self = .handPose
        case "bodyPose": self = .bodyPose
        default: return nil
        }
    }
}

/// Static descriptor for one of the five grouped tool slots in the
/// iPad toolbar. Defaults match the spec's "first variant in each group
/// on first launch" rule.
struct ToolGroup {
    let name: String
    let variants: [ToolVariant]
    let storageKey: String
    let defaultVariant: ToolVariant

    /// Brush category — five paint variants behind a long-press popover.
    /// Default `.brush` preserves first-launch muscle memory; users who
    /// settled on a different variant get their last selection back via
    /// `storageKey`. Eraser stays a separate top-level slot (audit §6).
    static let brushes = ToolGroup(
        name: "Brushes",
        variants: [
            .tool(.pencil),
            .tool(.brush),
            .tool(.marker),
            .tool(.airbrush),
            .tool(.charcoal),
        ],
        storageKey: "toolGroup.brushes.lastSelected",
        defaultVariant: .tool(.brush)
    )

    static let effects = ToolGroup(
        name: "Effects",
        variants: [.tool(.smudge), .tool(.blur), .tool(.blurAdjustment)],
        storageKey: "toolGroup.effects.lastSelected",
        defaultVariant: .tool(.smudge)
    )

    static let sample = ToolGroup(
        name: "Sample",
        variants: [.tool(.eyeDropper), .tool(.paintBucket)],
        storageKey: "toolGroup.sample.lastSelected",
        defaultVariant: .tool(.eyeDropper)
    )

    static let shapes = ToolGroup(
        name: "Shapes",
        variants: [.tool(.line), .tool(.rectangle), .tool(.circle)],
        storageKey: "toolGroup.shapes.lastSelected",
        defaultVariant: .tool(.line)
    )

    static let select = ToolGroup(
        name: "Select",
        variants: [.tool(.rectangleSelect), .tool(.lasso)],
        storageKey: "toolGroup.select.lastSelected",
        defaultVariant: .tool(.rectangleSelect)
    )

    static let text = ToolGroup(
        name: "Text",
        variants: [.tool(.text), .tool(.textOnPath)],
        storageKey: "toolGroup.text.lastSelected",
        defaultVariant: .tool(.text)
    )

    /// Pose Reference category — hand and body skeleton overlays. The slot
    /// is consumed by `PoseReferenceToolSlot` (a thin wrapper around
    /// `GroupedToolButton`); the wrapper interprets tap as the Decision-7
    /// state cycle (no skeleton → detection sheet, visible ↔ hidden) so
    /// `GroupedToolButton` itself stays free of pose-specific behavior.
    static let poseReference = ToolGroup(
        name: "Pose Reference",
        variants: [.tool(.handPose), .tool(.bodyPose)],
        storageKey: "toolGroup.poseReference.lastSelected",
        defaultVariant: .tool(.handPose)
    )
}
