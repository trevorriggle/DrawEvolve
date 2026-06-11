//
//  InlineTextEditorView.swift
//  DrawEvolve
//
//  5.1 type-tool rework: the VISIBLE in-place text editor.
//
//  Replaces the invisible 1×1 UITextView (TextEntryOverlay) for PLAIN
//  text editing. While a plain-text session is active, a real UITextView
//  sits at the float's canvas anchor — native caret, tap-to-position,
//  selection handles, magnifier, autocorrect anchored to real glyphs —
//  styled to match the rasterised output (font / color / alignment /
//  leading / tracking scaled through the live canvas transform). The
//  Metal draw loop suppresses the rasterised float preview while this
//  editor is mounted (see DrawFrameSnapshot / CanvasRenderSnapshot), so
//  the editor's glyphs ARE the live preview; when the session ends the
//  rasterised preview takes over at the same position with no visual jump
//  (the editor's textContainerInset mirrors the rasteriser's descender
//  padding).
//
//  Path-bearing floats keep the invisible-host model (glyphs on a curve
//  can't be a native text view) — see TextEntryOverlay.
//
//  Geometry: position/rotation derive from documentToScreen, which
//  includes the transient keyboard-avoidance pan, so the editor rides
//  the canvas as it shifts for the keyboard. Canvas flip (mirror) is the
//  one transform the native editor can't reproduce — under flip the
//  editor renders unmirrored at the correct rect, matching how other
//  apps treat text editing on a mirrored canvas.
//
//  Keyboard input flows through `setFloatingTextContent` per keystroke,
//  exactly like the old invisible host, so the rasterise pipeline keeps
//  the float's bounds fresh for transform handles and commit.
//

import SwiftUI
import UIKit

// MARK: - Shared text-style math

/// Builders shared by the visible editor and its measurement pass. All
/// "scale" parameters are the doc→screen point scale (fit-scale × zoom),
/// measured by projecting through documentToScreen so it stays correct
/// for any fit/zoom combination.
enum InlineTextStyle {

    /// Screen-point font matching the rasterised glyphs at `scale`.
    static func screenFont(settings: TextSettings, scale: CGFloat) -> UIFont {
        let size = max(1, settings.size * scale)
        var font = UIFont(name: settings.fontFace, size: size)
            ?? UIFont(name: settings.fontFamily, size: size)
            ?? UIFont.systemFont(ofSize: size, weight: .regular)
        if settings.italic,
           !font.fontDescriptor.symbolicTraits.contains(.traitItalic),
           let desc = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: desc, size: size)
        }
        return font
    }

    /// NSAttributedString attributes mirroring
    /// `CanvasRenderer.rasterizeFloatingText`'s attribute construction,
    /// with every doc-space metric multiplied by `scale` instead of the
    /// rasteriser's textureScale.
    static func attributes(settings: TextSettings, scale: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = settings.alignment.nsTextAlignment
        paragraph.lineSpacing = settings.leading * scale

        var attrs: [NSAttributedString.Key: Any] = [
            .font: screenFont(settings: settings, scale: scale),
            .foregroundColor: settings.color,
            .paragraphStyle: paragraph,
        ]
        if settings.tracking != 0 {
            attrs[.tracking] = settings.tracking * scale
        }
        switch settings.kerning {
        case .auto:
            break
        case .none:
            attrs[.kern] = 0
        case .manual(let v):
            attrs[.kern] = v * scale
        }
        return attrs
    }

    /// The rasteriser pads its image by ceil(renderSize × 0.25) on every
    /// side for descenders/shear; the editor mirrors that as a
    /// textContainerInset so its glyph origin lands where the rasterised
    /// glyphs will land after commit.
    static func inset(settings: TextSettings, scale: CGFloat) -> CGFloat {
        (settings.size * scale * 0.25).rounded(.up)
    }

    /// Editor frame size for `content` (screen points), insets included.
    /// Mirrors the rasteriser's unconstrained layout: no wrapping, lines
    /// come from explicit newlines.
    static func measure(content: String, settings: TextSettings, scale: CGFloat) -> CGSize {
        let pad = inset(settings: settings, scale: scale)
        let font = screenFont(settings: settings, scale: scale)
        guard !content.isEmpty else {
            // Caret-only box: one line tall, enough width for the caret.
            return CGSize(width: 24 + pad * 2,
                          height: font.lineHeight.rounded(.up) + pad * 2)
        }
        let attrStr = NSAttributedString(
            string: content,
            attributes: attributes(settings: settings, scale: scale)
        )
        let bound = attrStr.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude,
                         height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        // +2pt fudge keeps the trailing caret inside the frame; the text
        // view doesn't scroll, so a slightly generous frame is harmless.
        return CGSize(width: bound.width.rounded(.up) + pad * 2 + 2,
                      height: bound.height.rounded(.up) + pad * 2)
    }
}

// MARK: - Visible in-place editor

struct InlineTextEditorView: View {
    @ObservedObject var canvasState: CanvasStateManager

    /// Checkmark on the keyboard-docked Type Bar — "done typing".
    let onCheckmark: () -> Void

    var body: some View {
        if let ft = canvasState.floatingText,
           ft.path == nil,
           canvasState.isTextEditorSessionActive {
            let scale = docToScreenScale * ft.scale.width
            let size = InlineTextEditorView.clampedSize(
                InlineTextStyle.measure(content: ft.content,
                                        settings: ft.settings,
                                        scale: scale)
            )
            let totalVisualCCW = ft.rotation.radians + canvasState.canvasRotation.radians
            let center = editorCenter(for: ft, size: size, totalVisualCCW: totalVisualCCW)

            ZStack {
                InlineTextEditorTextView(
                    canvasState: canvasState,
                    settings: ft.settings,
                    scale: scale,
                    onCheckmark: onCheckmark
                )
                .frame(width: size.width, height: size.height)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .rotationEffect(.radians(-totalVisualCCW))
                .position(center)

                TextKeyboardAvoidanceDriver(canvasState: canvasState)
            }
            .ignoresSafeArea()
        }
    }

    /// Doc→screen point scale, measured through documentToScreen so any
    /// fit-size/zoom combination is honoured. Rotation preserves length,
    /// so projecting a horizontal doc segment is sufficient.
    private var docToScreenScale: CGFloat {
        let a = canvasState.documentToScreen(CGPoint(x: 0, y: 0))
        let b = canvasState.documentToScreen(CGPoint(x: 100, y: 0))
        let s = hypot(b.x - a.x, b.y - a.y) / 100
        return (s.isFinite && s > 0.0001) ? s : 1
    }

    /// Keep degenerate measurements from collapsing the editor (or a
    /// 500pt-font multi-line paste from producing an absurd frame —
    /// SwiftUI tolerates oversize frames, but cap NaN/inf defensively).
    private static func clampedSize(_ s: CGSize) -> CGSize {
        CGSize(width: s.width.isFinite ? max(24, min(s.width, 8192)) : 24,
               height: s.height.isFinite ? max(24, min(s.height, 8192)) : 24)
    }

    /// Screen-space center for `.position(...)`. The float's anchor is the
    /// TOP-LEFT of its unrotated displayed rect; float rotation pivots
    /// around the rect center. Project the rotated top-left corner, then
    /// step to the editor's center along the rotated local axes using the
    /// editor's own measured size (pins the top-left while typing so text
    /// grows rightward/downward like the rasterised layout, instead of
    /// jiggling around a stale center).
    private func editorCenter(for ft: FloatingText,
                              size: CGSize,
                              totalVisualCCW: CGFloat) -> CGPoint {
        let rect = ft.displayedRect
        let cx = rect.midX, cy = rect.midY
        let phi = ft.rotation.radians
        // Rotate (minX,minY) around center by phi — visual CCW in Y-down:
        // x' = dx·cosφ + dy·sinφ ; y' = −dx·sinφ + dy·cosφ
        let dx = rect.minX - cx
        let dy = rect.minY - cy
        let cosP = cos(phi), sinP = sin(phi)
        let topLeftDoc = CGPoint(x: cx + dx * cosP + dy * sinP,
                                 y: cy - dx * sinP + dy * cosP)
        let topLeftScreen = canvasState.documentToScreen(topLeftDoc)

        // Half-diagonal of the editor frame, rotated into screen space by
        // the total visual rotation (same matrix form).
        let hx = size.width / 2, hy = size.height / 2
        let cosA = cos(totalVisualCCW), sinA = sin(totalVisualCCW)
        return CGPoint(x: topLeftScreen.x + hx * cosA + hy * sinA,
                       y: topLeftScreen.y - hx * sinA + hy * cosA)
    }
}

// MARK: - UITextView host

private struct InlineTextEditorTextView: UIViewRepresentable {
    let canvasState: CanvasStateManager
    let settings: TextSettings
    let scale: CGFloat
    let onCheckmark: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.textContainer.lineFragmentPadding = 0
        tv.keyboardType = .default
        tv.returnKeyType = .default
        tv.autocapitalizationType = .sentences
        tv.autocorrectionType = .default
        tv.delegate = context.coordinator

        // Dock the Type Bar above the keyboard. Must precede the
        // becomeFirstResponder below or the accessory won't attach.
        tv.inputAccessoryView = makeTypeBarAccessoryView(
            canvasState: canvasState,
            onCheckmark: onCheckmark
        )

        applyStyle(to: tv, context: context)
        tv.text = canvasState.floatingText?.content ?? ""
        restyleExistingText(tv)

        // Defer to the next runloop so SwiftUI's mount transaction
        // completes first (same race the old TextEntryOverlay defended
        // against); place the caret at the end for resume-typing.
        DispatchQueue.main.async {
            tv.becomeFirstResponder()
            tv.selectedRange = NSRange(location: (tv.text as NSString).length, length: 0)
        }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // Restyle only when style inputs actually changed — rebuilding
        // attributedText on every canvasState tick would reset marked
        // text (IME composition) and fight the user.
        let key = styleKey
        if context.coordinator.lastStyleKey != key {
            context.coordinator.lastStyleKey = key
            applyStyle(to: tv, context: context)
            restyleExistingText(tv)
        }

        // External content change (e.g. session resumed on a float typed
        // earlier). Never rewrite while the editor itself is the source —
        // textViewDidChange already synced the model.
        let model = canvasState.floatingText?.content ?? ""
        if tv.text != model, !context.coordinator.isEditingFromTextView {
            let sel = tv.selectedRange
            tv.text = model
            restyleExistingText(tv)
            let len = (model as NSString).length
            tv.selectedRange = NSRange(location: min(sel.location, len), length: 0)
        }
    }

    static func dismantleUIView(_ tv: UITextView, coordinator: Coordinator) {
        if tv.isFirstResponder {
            tv.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(canvasState: canvasState, styleKey: styleKey)
    }

    private var styleKey: String {
        "\(settings.fontFace)|\(settings.fontFamily)|\(settings.size)|\(settings.leading)|\(settings.tracking)|\(settings.kerning)|\(settings.italic)|\(settings.alignment)|\(settings.color.hash)|\(scale)"
    }

    private func applyStyle(to tv: UITextView, context: Context) {
        let attrs = InlineTextStyle.attributes(settings: settings, scale: scale)
        tv.typingAttributes = attrs
        tv.font = attrs[.font] as? UIFont
        tv.textColor = settings.color
        tv.tintColor = .systemBlue
        tv.textAlignment = settings.alignment.nsTextAlignment
        let pad = InlineTextStyle.inset(settings: settings, scale: scale)
        tv.textContainerInset = UIEdgeInsets(top: pad, left: pad, bottom: pad, right: pad)
    }

    private func restyleExistingText(_ tv: UITextView) {
        guard !tv.text.isEmpty else { return }
        let sel = tv.selectedRange
        tv.attributedText = NSAttributedString(
            string: tv.text,
            attributes: InlineTextStyle.attributes(settings: settings, scale: scale)
        )
        let len = (tv.text as NSString).length
        tv.selectedRange = NSRange(location: min(sel.location, len),
                                   length: min(sel.length, max(0, len - sel.location)))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        weak var canvasState: CanvasStateManager?
        var lastStyleKey: String
        /// True for the duration of a textViewDidChange→model sync, so
        /// updateUIView can tell self-inflicted model changes from
        /// external ones.
        var isEditingFromTextView = false

        init(canvasState: CanvasStateManager, styleKey: String) {
            self.canvasState = canvasState
            self.lastStyleKey = styleKey
            super.init()
        }

        func textViewDidChange(_ textView: UITextView) {
            isEditingFromTextView = true
            canvasState?.setFloatingTextContent(textView.text)
            isEditingFromTextView = false
        }
    }
}

// MARK: - Keyboard-avoidance driver

/// Watches the soft keyboard and pans the canvas (via the transient
/// `keyboardAvoidancePan`) just enough that the active float stays
/// visible above it — the standard drawing-app behaviour. Mounted by
/// whichever editor owns the session (visible inline editor for plain
/// text, invisible host for path text); the two are mutually exclusive.
///
/// The desired pan is computed from "raw" (un-shifted) screen positions —
/// current projection plus the pan already applied — so the computation
/// is a stable fixed point rather than a feedback loop.
struct TextKeyboardAvoidanceDriver: View {
    @ObservedObject var canvasState: CanvasStateManager

    /// Screen-Y of the keyboard top (frameEnd.minY). nil = keyboard down
    /// or hardware keyboard (height 0 / off-screen frame).
    @State private var keyboardTopY: CGFloat? = nil
    @State private var animDuration: Double = 0.25

    /// Don't let the float's top ride under the top toolbar cluster.
    private let topClearance: CGFloat = 90
    /// Breathing room between the float's bottom and the keyboard top
    /// (the docked Type Bar is part of the keyboard frame already).
    private let bottomMargin: CGFloat = 24

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillChangeFrameNotification
            )) { handleKeyboardFrame($0) }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification
            )) { note in
                animDuration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
                keyboardTopY = nil
            }
            .onChange(of: desiredPan) { target in
                canvasState.setKeyboardAvoidancePan(target, duration: animDuration)
            }
            .onDisappear {
                canvasState.setKeyboardAvoidancePan(0, duration: 0.25)
            }
    }

    private func handleKeyboardFrame(_ note: Notification) {
        guard let info = note.userInfo,
              let frameValue = info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else {
            return
        }
        animDuration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let frame = frameValue.cgRectValue
        let screenH = UIScreen.main.bounds.height
        // Hardware keyboard / dismissed: zero height or frame fully
        // below the screen.
        if frame.height <= 0 || frame.minY >= screenH - 1 {
            keyboardTopY = nil
        } else {
            keyboardTopY = frame.minY
        }
    }

    /// Recomputed on every canvasState change (ObservedObject re-evals
    /// body); onChange(of:) fires setKeyboardAvoidancePan only when the
    /// rounded target actually moves.
    private var desiredPan: CGFloat {
        guard let kbTop = keyboardTopY,
              canvasState.isTextEditorSessionActive,
              let ft = canvasState.floatingText else { return 0 }

        var rect = ft.displayedRect
        // Empty/degenerate floats (no rasterised bounds yet): reserve at
        // least one line of height so the caret box clears the keyboard.
        if rect.height < ft.settings.size { rect.size.height = ft.settings.size }
        if rect.width < 1 { rect.size.width = 1 }

        // Rotated corners → screen, then strip the pan already applied to
        // recover keyboard-independent "raw" positions.
        let cx = rect.midX, cy = rect.midY
        let phi = ft.rotation.radians
        let cosP = cos(phi), sinP = sin(phi)
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
        ].map { p -> CGPoint in
            let dx = p.x - cx, dy = p.y - cy
            return CGPoint(x: cx + dx * cosP + dy * sinP,
                           y: cy - dx * sinP + dy * cosP)
        }
        let ys = corners.map { canvasState.documentToScreen($0).y }
        guard let minY = ys.min(), let maxY = ys.max() else { return 0 }
        let applied = canvasState.keyboardAvoidancePan
        let rawMaxY = maxY + applied
        let rawMinY = minY + applied

        let needed = rawMaxY - (kbTop - bottomMargin)
        let maxAllowed = max(0, rawMinY - topClearance)
        return max(0, min(needed, maxAllowed)).rounded()
    }
}
