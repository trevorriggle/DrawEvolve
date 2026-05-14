//
//  ReferenceImageView.swift
//  DrawEvolve
//
//  Pass 2 (2026-05-14): chrome-bar interaction model with the Pass-1
//  bugs fixed plus lock + body-drag + subject isolation + visual refresh.
//
//  Key architectural decisions:
//
//  Two scoped drag gestures, not one whole-frame drag.
//    The Pass-1 spec called for a single drag gesture on the entire
//    frame, but that conflicts with the slider thumb inside the chrome
//    bar — both would fire when the user drags the slider sideways.
//    Pass-2 splits the drag into two: one on the image body (when
//    unlocked), one on the chrome bar's empty background space. The
//    controls (lock, slider, isolation, flip, delete) intercept their
//    own touches before the chrome's drag can see them.
//
//  Bring-to-front is a separate TapGesture.
//    DragGesture(minimumDistance: 4) doesn't fire onEnded for quick
//    taps below the threshold, so we can't piggy-back the bring-to-
//    front on the drag. A simultaneousGesture(TapGesture()) fires on
//    quick taps; the drag fires on actual drags; bring-to-front lives
//    on the tap.
//
//  Lock toggle controls hit-testing.
//    Unlocked (default on add): body is hit-testable, drag/resize work
//    on the whole body. Locked: body has .allowsHitTesting(false),
//    brush strokes pass through to the canvas. Chrome and corner
//    handles still work for the explicit controls.
//
//  Bug fixes:
//    A) Corner-handle drift — startWidth used to be captured on each
//       view render (so it tracked the live scale during the drag,
//       breaking the math). Now both startScale and startWidth are
//       captured in a single @GestureState at gesture-begin.
//    B) Header drag snap-back / jitter — the Pass-1 two-phase pattern
//       (offset during drag, commit on end) could leave the reference
//       stuck in a half-state on gesture cancellation. Pass-2 mutates
//       reference.center continuously in onChanged; no deferred state.
//

import SwiftUI

struct ReferenceImageView: View {
    let reference: ReferenceImage
    let onUpdate: (ReferenceImage) -> Void
    let onDelete: () -> Void
    let onBringToFront: () -> Void
    let onRequestIsolation: () -> Void

    @GestureState private var dragStart: CGPoint? = nil
    @GestureState private var resizeStart: ResizeStart? = nil

    private struct ResizeStart {
        let scale: CGFloat
        let width: CGFloat
    }

    private let headerHeight: CGFloat = 32
    private let cornerHandleSize: CGFloat = 18

    /// Single source of truth for the rendered image — original or isolated.
    private var displayImage: UIImage {
        (reference.isIsolated ? reference.isolatedImage : reference.image)
            ?? reference.image
    }

    private var displayedSize: CGSize {
        CGSize(
            width: reference.image.size.width * reference.scale,
            height: reference.image.size.height * reference.scale,
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            chromeBar
            imageBody
        }
        .frame(width: displayedSize.width, height: displayedSize.height + headerHeight)
        .background(frameBackground)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .position(x: reference.center.x, y: reference.center.y)
        .overlay(cornerHandles)
    }

    // MARK: - Chrome bar

    private var chromeBar: some View {
        ZStack {
            // Bottom layer: drag-detecting empty space. Touches on
            // controls (top layer) intercept first; touches on empty
            // space fall through to this drag gesture.
            Color.clear
                .contentShape(Rectangle())
                .gesture(chromeDragGesture)
                .simultaneousGesture(bringToFrontTapGesture)

            // Top layer: controls.
            HStack(spacing: 12) {
                lockButton
                opacitySlider
                isolationButton
                flipButton
                deleteButton
            }
            .padding(.horizontal, 10)
        }
        .frame(height: headerHeight)
        .background(chromeBackground)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 8,
                topTrailingRadius: 8,
            )
        )
    }

    private var chromeBackground: some View {
        LinearGradient(
            colors: [Color.black.opacity(0.72), Color.black.opacity(0.55)],
            startPoint: .top,
            endPoint: .bottom,
        )
    }

    private var lockButton: some View {
        Button {
            var r = reference
            r.isLocked.toggle()
            onUpdate(r)
        } label: {
            Image(systemName: reference.isLocked ? "lock.fill" : "lock.open")
                .font(.caption.weight(.semibold))
                .foregroundColor(reference.isLocked ? .yellow : .white.opacity(0.9))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var opacitySlider: some View {
        Slider(
            value: Binding(
                get: { reference.opacity },
                set: { newValue in
                    var r = reference
                    r.opacity = newValue
                    onUpdate(r)
                },
            ),
            in: 0.0...1.0,
        )
        .controlSize(.mini)
        .tint(.white)
    }

    private var isolationButton: some View {
        Button(action: onRequestIsolation) {
            ZStack(alignment: .topTrailing) {
                if reference.isIsolating {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: reference.isIsolated
                          ? "person.crop.rectangle.badge.checkmark"
                          : "person.crop.rectangle.stack")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                }

                // Subtle failure indicator — Vision returned no
                // foreground last time. Cleared on next attempt.
                if reference.lastIsolationFailed && !reference.isIsolating {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .offset(x: 4, y: -4)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reference.isIsolating)
    }

    private var flipButton: some View {
        Button {
            var r = reference
            r.isFlipped.toggle()
            onUpdate(r)
        } label: {
            Image(systemName: "arrow.left.and.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Image body

    private var imageBody: some View {
        Image(uiImage: displayImage)
            .resizable()
            .scaledToFit()
            .frame(width: displayedSize.width, height: displayedSize.height)
            .scaleEffect(x: reference.isFlipped ? -1 : 1, y: 1)
            .opacity(reference.opacity)
            .contentShape(Rectangle())
            // Locked = brush strokes pass through. Unlocked = body
            // accepts touches for drag/tap-to-front.
            .allowsHitTesting(!reference.isLocked)
            .gesture(reference.isLocked ? nil : bodyDragGesture)
            .simultaneousGesture(reference.isLocked ? nil : bringToFrontTapGesture)
    }

    // MARK: - Corner handles

    /// Corner handles only render when unlocked. Locked = drawing mode,
    /// handles would just clutter the canvas.
    @ViewBuilder
    private var cornerHandles: some View {
        if !reference.isLocked {
            let w = displayedSize.width
            let h = displayedSize.height + headerHeight
            ZStack {
                cornerHandle(at: CGPoint(x: 0, y: 0), signX: -1)
                cornerHandle(at: CGPoint(x: w, y: 0), signX: +1)
                cornerHandle(at: CGPoint(x: 0, y: h), signX: -1)
                cornerHandle(at: CGPoint(x: w, y: h), signX: +1)
            }
            .frame(width: w, height: h, alignment: .topLeading)
        }
    }

    private func cornerHandle(at point: CGPoint, signX: CGFloat) -> some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .frame(width: cornerHandleSize, height: cornerHandleSize)
            .position(x: point.x, y: point.y)
            .gesture(resizeGesture(signX: signX))
    }

    // MARK: - Frame background

    private var frameBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(
                reference.isLocked
                    ? Color.white.opacity(0.25)
                    : Color.accentColor.opacity(0.85),
                lineWidth: 1.5,
            )
    }

    // MARK: - Gestures

    /// Quick tap → bring this reference to the front of z-order.
    /// Used as .simultaneousGesture alongside the drag gestures so quick
    /// taps register even when the drag has minimumDistance > 0.
    private var bringToFrontTapGesture: some Gesture {
        TapGesture().onEnded { onBringToFront() }
    }

    /// Drag on the image body. Continuous-center mutation — no deferred
    /// offset state, so cancellation doesn't snap back. Also brings the
    /// reference to the front on drag-end (so dragging a back reference
    /// surfaces it).
    private var bodyDragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragStart) { _, state, _ in
                if state == nil { state = reference.center }
            }
            .onChanged { value in
                guard let start = dragStart else { return }
                var r = reference
                r.center = CGPoint(
                    x: start.x + value.translation.width,
                    y: start.y + value.translation.height,
                )
                onUpdate(r)
            }
            .onEnded { _ in onBringToFront() }
    }

    /// Drag on the chrome bar's empty background. Same continuous-
    /// center pattern as bodyDragGesture. The controls (lock, slider,
    /// isolation, flip, delete) intercept their own touches before
    /// this gesture sees them, so slider drags don't move the reference.
    private var chromeDragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragStart) { _, state, _ in
                if state == nil { state = reference.center }
            }
            .onChanged { value in
                guard let start = dragStart else { return }
                var r = reference
                r.center = CGPoint(
                    x: start.x + value.translation.width,
                    y: start.y + value.translation.height,
                )
                onUpdate(r)
            }
            .onEnded { _ in onBringToFront() }
    }

    /// Resize from a corner. Captures BOTH startScale AND startWidth
    /// in the same @GestureState snapshot — fixes the Pass-1 drift
    /// where startWidth was recomputed on each render with the live
    /// scale, breaking the math.
    private func resizeGesture(signX: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($resizeStart) { _, state, _ in
                if state == nil {
                    state = ResizeStart(
                        scale: reference.scale,
                        width: reference.image.size.width * reference.scale,
                    )
                }
            }
            .onChanged { value in
                guard let begin = resizeStart else { return }
                let signedDelta = signX * value.translation.width
                let scaleFactor = 1.0 + signedDelta / max(begin.width, 1)
                let newScale = max(0.1, begin.scale * scaleFactor)
                var r = reference
                r.scale = newScale
                onUpdate(r)
            }
    }
}
