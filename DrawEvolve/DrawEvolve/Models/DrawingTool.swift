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
    case marker
    case airbrush
    case charcoal
    case watercolor  // 5.4: juicy water-based marker — ragged streaky bands

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
        case .marker: return "highlighter"
        case .airbrush: return "wind"
        case .charcoal: return "scribble.variable"
        case .watercolor: return "paintbrush.fill"
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

    /// Whether the active tool's fragment shader actually reads
    /// `uniforms.hardness`. UI hides the hardness slider for tools that
    /// ignore it — surfaces honest control to the user instead of an
    /// inert slider that does nothing.
    ///
    /// Brush + eraser + charcoal + blur use hardness directly. For blur
    /// it shapes the stamp's edge falloff (how sharply the blur-vs-
    /// original mix ramps down at the perimeter), not the Gaussian
    /// kernel width — kernel width is driven by `size`. Pencil USES
    /// the uniform but floors it at 0.85 (so the slider is effectively
    /// a no-op across most of its range — we hide it to avoid lying
    /// about responsiveness). Marker and airbrush have fixed disc
    /// profiles and ignore the uniform entirely.
    var usesHardness: Bool {
        switch self {
        case .brush, .eraser, .charcoal, .blur:
            return true
        default:
            return false
        }
    }

    var name: String {
        switch self {
        case .brush: return "Brush"
        case .eraser: return "Eraser"
        case .paintBucket: return "Fill"
        case .eyeDropper: return "Pick Color"
        case .pencil: return "Pencil"
        case .marker: return "Marker"
        case .airbrush: return "Airbrush"
        case .charcoal: return "Charcoal"
        case .watercolor: return "Watercolor"
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
///
/// Codable conformance (Phase 3 of the color system overhaul, 2026-05-13)
/// persists the entire brush state across app launches — color, size,
/// opacity, hardness, grain, the lot. Pattern mirrors TextSettings'
/// existing Codable conformance: `color` rides through as a CodableColor
/// (CodableColor.swift). All other fields are Codable-native primitives.
///
/// Restored from UserDefaults in CanvasStateManager.init, persisted on
/// every mutation via the @Published didSet hook there. UI bindings are
/// unaffected — @Published semantics work the same whether the type is
/// Codable or not.
struct BrushSettings: Codable {
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

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case size, opacity, hardness, spacing, pressureSensitivity
        case color
        case minPressureSize, maxPressureSize
        case blurStrength, smudgeStrength, grainDensity
    }

    init() {}

    init(from decoder: Decoder) throws {
        // Decode-with-defaults: every field is optional in the stored
        // representation so future schema additions don't break old
        // payloads on launch. Same shape TextSettings uses.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.size = try c.decodeIfPresent(CGFloat.self, forKey: .size) ?? 10.0
        self.opacity = try c.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 1.0
        self.hardness = try c.decodeIfPresent(CGFloat.self, forKey: .hardness) ?? 0.8
        self.spacing = try c.decodeIfPresent(CGFloat.self, forKey: .spacing) ?? 0.1
        self.pressureSensitivity = try c.decodeIfPresent(Bool.self, forKey: .pressureSensitivity) ?? true
        let codableColor = try c.decodeIfPresent(CodableColor.self, forKey: .color)
        self.color = codableColor?.uiColor ?? .black
        self.minPressureSize = try c.decodeIfPresent(CGFloat.self, forKey: .minPressureSize) ?? 0.3
        self.maxPressureSize = try c.decodeIfPresent(CGFloat.self, forKey: .maxPressureSize) ?? 1.0
        self.blurStrength = try c.decodeIfPresent(Float.self, forKey: .blurStrength) ?? 1.0
        self.smudgeStrength = try c.decodeIfPresent(Float.self, forKey: .smudgeStrength) ?? 0.5
        self.grainDensity = try c.decodeIfPresent(Float.self, forKey: .grainDensity) ?? 0.5
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(size, forKey: .size)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(hardness, forKey: .hardness)
        try c.encode(spacing, forKey: .spacing)
        try c.encode(pressureSensitivity, forKey: .pressureSensitivity)
        try c.encode(CodableColor(color), forKey: .color)
        try c.encode(minPressureSize, forKey: .minPressureSize)
        try c.encode(maxPressureSize, forKey: .maxPressureSize)
        try c.encode(blurStrength, forKey: .blurStrength)
        try c.encode(smudgeStrength, forKey: .smudgeStrength)
        try c.encode(grainDensity, forKey: .grainDensity)
    }

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
            s.opacity = 0.85      // a hard stroke reads as dark graphite, not gray
            s.hardness = 0.95     // sharp edge
            s.spacing = 0.08      // looser overlap so grain gaps aren't saturated out
        case .marker:
            s.size = 14           // wider than brush
            s.opacity = 0.65      // saturated color with paper subtly visible — chisel-tip marker, not Sharpie
            s.hardness = 0.6      // soft-ish but flat-topped
            s.spacing = 0.05
        case .airbrush:
            s.size = 65           // big mist
            s.opacity = 0.4       // per-stamp cap. Was 0.08 pre-wet-ink (density built
                                  // through hundreds of overlapping stamps via .sourceAlpha
                                  // accumulation). Under wet-ink's .max/.max deposit, the
                                  // per-stroke cap = slider × per-stamp opacity, and 0.08
                                  // left most of the airbrush disc visually invisible
                                  // (quartic falloff × 0.08 ≈ 0 across most of the stamp).
                                  // 0.4 gives the falloff enough alpha to show through
                                  // while keeping airbrush distinctly softer than brush.
            s.hardness = 0.0      // soft falloff (shader uses quadratic anyway)
            s.spacing = 0.02      // tight overlap for density build
        case .charcoal:
            s.size = 24           // wide charcoal stick
            s.opacity = 0.85      // heavy deposit
            s.hardness = 0.4      // soft-ish edge
            s.spacing = 0.09      // looser overlap so density varies along the stroke
            s.grainDensity = 1.0  // paper pixels deposit nothing — real gaps under overlap
        case .watercolor:
            s.size = 30           // wide wash band
            s.opacity = 0.55      // watercolor translucency — separate strokes
                                  // overlap-deepen at commit, like layered washes
            s.hardness = 0.0      // unused (shader has its own ragged edge)
            s.spacing = 0.03      // tight overlap so the band reads continuous
                                  // under the .max deposit despite the ragged edge
        case .blur:
            s.hardness = 0.4      // soft disc — hard-edged blur leaves visible stamp rings
            s.spacing = 0.04      // tight overlap so blurred deposits read as a continuous smear
        case .smudge:
            s.spacing = 0.05      // tight stamping so the carry stays coherent along the drag
            s.smudgeStrength = 0.75 // higher pickup so paint travels several brush-widths before fading
        default:
            return nil            // non-brush tools — caller does nothing
        }
        return s
    }
}

/// Represents a single brush stroke
struct BrushStroke {
    let id: UUID
    var points: [StrokePoint]
    let settings: BrushSettings
    let tool: DrawingTool
    let layerId: UUID

    init(
        id: UUID = UUID(),
        points: [StrokePoint],
        settings: BrushSettings,
        tool: DrawingTool,
        layerId: UUID
    ) {
        self.id = id
        self.points = points
        self.settings = settings
        self.tool = tool
        self.layerId = layerId
    }

    enum InputType: String {
        case direct
        case indirect
        case indirectPointer
        case pencil
        case unknown

        var diagnosticName: String {
            switch self {
            case .direct: return "direct/finger-mouse"
            case .indirect: return "indirect"
            case .indirectPointer: return "indirectPointer"
            case .pencil: return "pencil"
            case .unknown: return "unknown"
            }
        }
    }

    struct StrokePoint {
        let location: CGPoint
        // SIZE pressure — drives `uniforms.pressure` → vertex shader
        // `pointSize = size * pressure`. Reflects "press harder = bigger
        // stamp." For Pencil this varies with applied force; for finger /
        // mouse / simulator it's the fixed 0.75 size-fudge so finger
        // strokes feel size-comparable to Pencil at the same brush size.
        let pressure: CGFloat
        // ALPHA pressure — drives `uniforms.pressureAlpha` → fragment
        // shader `alpha *= opacity * pressureAlpha`. Reflects "press
        // harder = darker stamp." Decoupled from `pressure` so the
        // finger-fudge size scale (0.75) doesn't also silently cap the
        // first stamp's alpha at 75% on non-Pencil input. Pencil
        // returns the same value for both fields; finger returns 1.0
        // here and 0.75 for size.
        let pressureAlpha: CGFloat
        let inputType: InputType
        // Raw UITouch.force / maximumPossibleForce captured at the
        // sample site. Diagnostic-only: lets the per-stamp log
        // distinguish "Apple fed us variable force" from "our pressure
        // pipeline corrupted a constant input." 0/0 for derived points
        // (mirrors, shape-generated stamps, snap-line stamps).
        let rawTouchForce: CGFloat
        let rawTouchMaxForce: CGFloat
        let timestamp: TimeInterval

        // Back-compat init: callers that don't differentiate (shape /
        // symmetry / mirror copy sites that just propagate an existing
        // point's pressure value) pass only `pressure` and `pressureAlpha`
        // defaults to mirror it. Touch handlers that originate pressure
        // from `computePressure(for:)` pass both explicitly because the
        // tuple's two fields diverge for non-Pencil input.
        init(location: CGPoint,
             pressure: CGFloat,
             pressureAlpha: CGFloat? = nil,
             inputType: InputType = .unknown,
             rawTouchForce: CGFloat = 0,
             rawTouchMaxForce: CGFloat = 0,
             timestamp: TimeInterval) {
            self.location = location
            self.pressure = pressure
            self.pressureAlpha = pressureAlpha ?? pressure
            self.inputType = inputType
            self.rawTouchForce = rawTouchForce
            self.rawTouchMaxForce = rawTouchMaxForce
            self.timestamp = timestamp
        }
    }
}
