//
//  TypeBarView.swift
//  DrawEvolve
//
//  Floating, movable Type Bar — the controller for the Type tool session.
//
//  Tier-1.4 slimdown: alignment picker, More button, collapse chevron, and
//  collapsed-pill state are gone; leading slider is gone (replaced by size
//  in row 2). Bar is now: row 1 = grab handle + font pill (wider) + color
//  swatch + checkmark; row 2 = size slider + tracking slider. The deeper
//  inspector half-sheet (italic, kerning kind, manual kern, on-path
//  toggles) is no longer reachable from the bar — those settings can come
//  back via a different surface in a future tier if/when they're needed.
//
//  Lifecycle:
//    • Appears when `.text` is selected, OR when `.textOnPath` is selected
//      AND the user has finished drawing the path (a path-bearing
//      FloatingText exists).
//    • Hides when the user taps the checkmark — the float stays alive so
//      the user can drag / scale / rotate it via the existing transform
//      handles. Subsequent tap-outside in .text commits to the layer.
//    • Also hides on a real tool change.
//
//  Position:
//    • First launch: bottom-center, above safe area.
//    • Subsequent launches: last user-placed position from UserDefaults.
//    • Drag handle on the left edge — slider/checkmark hits don't trigger
//      drag.
//    • Constrained to canvas bounds.
//    • Soft keyboard: bar slides up to sit above the keyboard via
//      keyboardWillShow/Hide notifications. Hardware keyboard: no-op.
//

import SwiftUI
import UIKit

struct TypeBarView: View {
    @Binding var settings: TextSettings

    @ObservedObject var canvasState: CanvasStateManager

    /// Canvas size in screen-points, used to clamp drag and compute the
    /// default first-launch position. Parent supplies via a GeometryReader
    /// so the bar follows reflow on rotation or inspector mount.
    let canvasSize: CGSize

    /// Tapped when the user is done with the typing portion of the Type
    /// session. Parent decides what that means — Tier-1.4 keeps the float
    /// alive with transform handles, so this fires "stop typing" rather
    /// than "commit pixels."
    let onCheckmark: () -> Void

    // MARK: - Persisted position

    @AppStorage("typeBarPosition.x") private var storedX: Double = -1
    @AppStorage("typeBarPosition.y") private var storedY: Double = -1

    // MARK: - UI state

    @State private var position: CGPoint?
    @State private var keyboardAvoidanceOffset: CGFloat = 0
    @State private var keyboardAnimationDuration: Double = 0.25

    @State private var showFontPickerPopover = false
    @State private var showColorPickerPopover = false

    private let families: [String] = UIFont.familyNames.sorted()

    // MARK: - Layout constants

    private let barWidth: CGFloat = 340
    private let barHeight: CGFloat = 92
    private let edgeMargin: CGFloat = 12
    private let keyboardClearance: CGFloat = 8

    var body: some View {
        let size = CGSize(width: barWidth, height: barHeight)
        let pos = effectivePosition(for: size)

        VStack(spacing: 6) {
            row1
            row2
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: size.width, height: size.height)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .position(x: pos.x, y: pos.y - keyboardAvoidanceOffset)
        .onAppear { ensureInitialPosition(for: size) }
        .onChange(of: canvasSize) { _ in
            if var p = position {
                p = clampPosition(p, size: size)
                position = p
                storedX = p.x
                storedY = p.y
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillShowNotification
        )) { handleKeyboardShow($0, barPosition: pos, size: size) }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification
        )) { handleKeyboardHide($0) }
    }

    // MARK: - Rows

    private var row1: some View {
        HStack(spacing: 8) {
            grabHandle
            fontPill
            colorSwatch
            checkmarkButton
        }
    }

    private var row2: some View {
        HStack(spacing: 14) {
            sliderSnippet(label: "Size",
                          value: $settings.size,
                          range: 1...500,
                          fmt: "%.0f",
                          unit: "pt",
                          labelWidth: 28,
                          valueWidth: 38)
            sliderSnippet(label: "Track",
                          value: $settings.tracking,
                          range: -10...50,
                          fmt: "%.1f",
                          unit: nil,
                          labelWidth: 32,
                          valueWidth: 30)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Components

    private var grabHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 13))
            .foregroundColor(.secondary)
            .frame(width: 16, height: 32)
            .contentShape(Rectangle())
            .gesture(dragGesture)
    }

    private var fontPill: some View {
        Button { showFontPickerPopover = true } label: {
            HStack(spacing: 6) {
                Text(settings.fontFamily)
                    .font(.custom(settings.fontFamily, size: 14))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
        .popover(isPresented: $showFontPickerPopover) {
            fontPickerPopover
        }
    }

    private var colorSwatch: some View {
        Button { showColorPickerPopover = true } label: {
            Circle()
                .fill(Color(uiColor: settings.color))
                .frame(width: 26, height: 26)
                .overlay(Circle().stroke(Color.gray.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showColorPickerPopover) {
            AdvancedColorPicker(selectedColor: $settings.color)
                .frame(minWidth: 320, minHeight: 360)
                .padding()
                .presentationCompactAdaptation(.none)
        }
    }

    private var checkmarkButton: some View {
        Button(action: onCheckmark) {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 30, height: 28)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func sliderSnippet(label: String,
                               value: Binding<CGFloat>,
                               range: ClosedRange<CGFloat>,
                               fmt: String,
                               unit: String?,
                               labelWidth: CGFloat,
                               valueWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            Slider(value: value, in: range)
                .layoutPriority(1)
            Text(unit.map { String(format: "\(fmt) \($0)", value.wrappedValue) }
                  ?? String(format: fmt, value.wrappedValue))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }

    // MARK: - Font picker popover

    private var fontPickerPopover: some View {
        Form {
            Section("Family") {
                Picker("Family", selection: $settings.fontFamily) {
                    ForEach(families, id: \.self) { family in
                        Text(family)
                            .font(.custom(family, size: 16))
                            .tag(family)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChange(of: settings.fontFamily) { newFamily in
                    let faces = UIFont.fontNames(forFamilyName: newFamily)
                    if !faces.contains(settings.fontFace) {
                        settings.fontFace = faces.first ?? newFamily
                    }
                }
            }
            let faces = UIFont.fontNames(forFamilyName: settings.fontFamily)
            if !faces.isEmpty {
                Section("Face") {
                    Picker("Face", selection: $settings.fontFace) {
                        ForEach(faces, id: \.self) { face in
                            Text(face)
                                .font(.custom(face, size: 14))
                                .tag(face)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 340, minHeight: 420, idealHeight: 480)
        .presentationCompactAdaptation(.none)
    }

    // MARK: - Position

    private func ensureInitialPosition(for size: CGSize) {
        guard position == nil else { return }
        if storedX >= 0, storedY >= 0 {
            position = clampPosition(CGPoint(x: storedX, y: storedY), size: size)
        } else {
            position = CGPoint(
                x: canvasSize.width / 2,
                y: canvasSize.height - size.height / 2 - 60 - edgeMargin
            )
        }
    }

    private func effectivePosition(for size: CGSize) -> CGPoint {
        if let p = position {
            return clampPosition(p, size: size)
        }
        return CGPoint(
            x: canvasSize.width / 2,
            y: canvasSize.height - size.height / 2 - 60 - edgeMargin
        )
    }

    private func clampPosition(_ p: CGPoint, size: CGSize) -> CGPoint {
        let halfW = size.width / 2
        let halfH = size.height / 2
        let minX = halfW + edgeMargin
        let maxX = max(minX, canvasSize.width - halfW - edgeMargin)
        let minY = halfH + edgeMargin
        let maxY = max(minY, canvasSize.height - halfH - edgeMargin)
        return CGPoint(
            x: min(max(p.x, minX), maxX),
            y: min(max(p.y, minY), maxY)
        )
    }

    // MARK: - Drag

    private var dragGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                guard let current = position else { return }
                let size = CGSize(width: barWidth, height: barHeight)
                let new = CGPoint(
                    x: current.x + value.translation.width,
                    y: current.y + value.translation.height
                )
                position = clampPosition(new, size: size)
            }
            .onEnded { value in
                guard let current = position else { return }
                let size = CGSize(width: barWidth, height: barHeight)
                let new = CGPoint(
                    x: current.x + value.translation.width,
                    y: current.y + value.translation.height
                )
                let clamped = clampPosition(new, size: size)
                position = clamped
                storedX = clamped.x
                storedY = clamped.y
            }
    }

    // MARK: - Keyboard avoidance

    private func handleKeyboardShow(_ note: Notification,
                                    barPosition: CGPoint,
                                    size: CGSize) {
        guard let info = note.userInfo,
              let frameValue = info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue,
              let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else {
            return
        }
        keyboardAnimationDuration = duration
        let kbFrame = frameValue.cgRectValue

        // Hardware-keyboard attached: iOS reports a keyboard frame whose
        // top is at or below the screen bottom (height 0 or off-screen).
        // Treat that as "no keyboard, don't move."
        guard kbFrame.height > 0,
              kbFrame.minY < canvasSize.height - 1 else {
            return
        }

        let barBottom = barPosition.y + size.height / 2
        let kbTop = kbFrame.minY
        if barBottom > kbTop {
            let needed = barBottom - kbTop + keyboardClearance
            withAnimation(.easeInOut(duration: duration)) {
                keyboardAvoidanceOffset = needed
            }
        }
    }

    private func handleKeyboardHide(_ note: Notification) {
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double)
            ?? 0.25
        withAnimation(.easeInOut(duration: duration)) {
            keyboardAvoidanceOffset = 0
        }
    }
}
