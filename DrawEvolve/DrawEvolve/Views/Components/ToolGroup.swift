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

/// One option inside a grouped tool slot. Most variants map to a
/// `DrawingTool`; the Text group also exposes a "settings opener" entry
/// which activates `.text` AND opens the text-settings sheet on
/// selection (semantics confirmed for both popover-pick and slot-tap).
enum ToolVariant: Hashable {
    case tool(DrawingTool)
    case textSettings

    var icon: String {
        switch self {
        case .tool(let t): return t.icon
        case .textSettings: return "textformat.size"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .tool(let t): return t.name
        case .textSettings: return "Text Settings"
        }
    }

    /// Stable string for `@AppStorage` round-trips. Don't rename the
    /// strings without a migration — they survive across launches.
    var storageString: String {
        switch self {
        case .tool(let t): return "tool:" + t.storageKey
        case .textSettings: return "textSettings"
        }
    }

    init?(storageString: String) {
        if storageString == "textSettings" {
            self = .textSettings
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
        variants: [.tool(.text), .textSettings, .tool(.textOnPath)],
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
