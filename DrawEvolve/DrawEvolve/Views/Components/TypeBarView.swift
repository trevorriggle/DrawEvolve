//
//  TypeBarView.swift
//  DrawEvolve
//
//  Floating, movable, collapsible Type Bar that's the controller for the
//  Type tool session. Replaces the auto-opening inspector behavior shipped
//  in PR #52 — the inspector becomes opt-in via the bar's More button.
//
//  Lifecycle:
//    • Appears when `.text` is selected, OR when `.textOnPath` is selected
//      AND the user has finished drawing the path (i.e., a path-bearing
//      FloatingText exists).
//    • Persists for the entire Type session — does NOT auto-dismiss when a
//      float commits or when the user is between texts.
//    • Dismisses ONLY when the user taps the checkmark or selects another
//      tool (commit-on-tool-change is the existing CanvasStateManager
//      behavior).
//
//  Position:
//    • First launch: bottom-center, above safe area.
//    • Subsequent launches: last user-placed position from UserDefaults.
//    • Drag handle on the left edge — slider/button hits don't trigger drag.
//    • Constrained to canvas bounds during drag.
//    • Soft keyboard: bar slides up to sit just above the keyboard via
//      keyboardWillShow/Hide notifications. On hide, bar returns to placed
//      position. Hardware keyboard attached: no soft keyboard rises, bar
//      stays put.
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

    /// Tapped when the user wants the half-sheet inspector with the deeper
    /// controls (italic, kerning kind, manual kern, on-path toggles).
    let onMore: () -> Void

    /// Tapped when the user is done with the Type session. Parent handles
    /// commit-or-cancel of the active float and switches `currentTool`
    /// back to the previous non-Type tool.
    let onCheckmark: () -> Void

    // MARK: - Persisted position

    @AppStorage("typeBarPosition.x") private var storedX: Double = -1
    @AppStorage("typeBarPosition.y") private var storedY: Double = -1

    // MARK: - UI state

    @State private var position: CGPoint?
    @State private var keyboardAvoidanceOffset: CGFloat = 0
    @State private var keyboardAnimationDuration: Double = 0.25

    @State private var isCollapsed = false
    @State private var showFontPickerPopover = false
    @State private var showColorPickerPopover = false

    private let families: [String] = UIFont.familyNames.sorted()

    // MARK: - Layout constants

    private let expandedWidth: CGFloat = 388
    private let collapsedWidth: CGFloat = 132
    private let expandedHeight: CGFloat = 88
    private let collapsedHeight: CGFloat = 44
    private let edgeMargin: CGFloat = 12
    private let keyboardClearance: CGFloat = 8

    var body: some View {
        let size = currentSize
        let pos = effectivePosition(for: size)

        Group {
            if isCollapsed {
                collapsedContent
            } else {
                expandedContent
            }
        }
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
            // Re-clamp position whenever the canvas reshapes (rotation,
            // side-column mount). Keep the user's intended location but
            // never let it sit off-screen.
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

    // MARK: - Content

    private var expandedContent: some View {
        VStack(spacing: 4) {
            row1
            row2
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var collapsedContent: some View {
        HStack(spacing: 6) {
            grabHandle
            Button { isCollapsed = false } label: {
                Text("Aa")
                    .font(.custom(settings.fontFamily, size: 18).weight(.semibold))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            checkmarkButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var row1: some View {
        HStack(spacing: 6) {
            grabHandle
            fontPill
            sizeControl
            colorSwatch
            alignmentPicker
            moreButton
            collapseButton
            checkmarkButton
        }
    }

    private var row2: some View {
        HStack(spacing: 12) {
            sliderSnippet(label: "Lead",
                          value: $settings.leading,
                          range: -20...80,
                          fmt: "%.0f")
            sliderSnippet(label: "Track",
                          value: $settings.tracking,
                          range: -10...50,
                          fmt: "%.1f")
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
            HStack(spacing: 4) {
                Text(settings.fontFamily)
                    .font(.custom(settings.fontFamily, size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 56, idealWidth: 90, maxWidth: 110)
        .layoutPriority(1)
        .popover(isPresented: $showFontPickerPopover) {
            fontPickerPopover
        }
    }

    private var sizeControl: some View {
        HStack(spacing: 4) {
            Slider(value: $settings.size, in: 1...500)
                .frame(minWidth: 50, idealWidth: 80)
                .layoutPriority(1)
            Text(String(format: "%.0f pt", settings.size))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var colorSwatch: some View {
        Button { showColorPickerPopover = true } label: {
            Circle()
                .fill(Color(uiColor: settings.color))
                .frame(width: 24, height: 24)
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

    private var alignmentPicker: some View {
        Picker("Alignment", selection: $settings.alignment) {
            Image(systemName: "text.alignleft").tag(TextSettings.Alignment.leading)
            Image(systemName: "text.aligncenter").tag(TextSettings.Alignment.center)
            Image(systemName: "text.alignright").tag(TextSettings.Alignment.trailing)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 92)
    }

    private var moreButton: some View {
        Button(action: onMore) {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17))
                .foregroundColor(.primary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }

    private var collapseButton: some View {
        Button { isCollapsed = true } label: {
            Image(systemName: "chevron.compact.down")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
                .frame(width: 24, height: 28)
        }
        .buttonStyle(.plain)
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
                               fmt: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 32, alignment: .leading)
            Slider(value: value, in: range)
                .layoutPriority(1)
            Text(String(format: fmt, value.wrappedValue))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 30, alignment: .trailing)
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

    private var currentSize: CGSize {
        isCollapsed
            ? CGSize(width: collapsedWidth, height: collapsedHeight)
            : CGSize(width: expandedWidth, height: expandedHeight)
    }

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
                let size = currentSize
                let new = CGPoint(
                    x: current.x + value.translation.width,
                    y: current.y + value.translation.height
                )
                let clamped = clampPosition(new, size: size)
                position = clamped
            }
            .onEnded { value in
                guard let current = position else { return }
                let size = currentSize
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
        // top is below the screen bottom. Treat that as "no keyboard,
        // don't move."
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
