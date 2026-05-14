//
//  ReferenceImageView.swift
//  DrawEvolve
//
//  Pass 3 (2026-05-14): deferred-commit drag + single diagonal resize.
//
//  The "insanely jittery" drag from Pass 2 was caused by per-frame
//  publishes through ReferenceImageManager. Every onChanged event
//  called onUpdate(r), which mutated the @Published references array,
//  which re-rendered DrawingCanvasView's entire body (because it owns
//  the manager via @StateObject). The body is large; re-evaluating it
//  60-120 times per second during a drag drops frames.
//
//  Pass-3 fix: hold the in-flight drag offset and resize delta in
//  local view state (@GestureState / @State). The view's rendered
//  position is `manager.center + dragOffset`; the displayed scale is
//  `manager.scale * inFlightScaleFactor`. Manager mutates ONLY on
//  drag/resize-end. During the gesture, only THIS view re-renders, and
//  its body is small (chrome + image + one handle).
//
//  Single resize handle in the bottom-left. The four corner anchors
//  were drifting out of sync with the reference under Pass 2's
//  startWidth bug (since fixed). User preferred to eliminate the
//  per-corner complexity entirely: one diagonal arrow at bottom-left,
//  drag down-and-left to grow, up-and-right to shrink. Projected onto
//  the diagonal so any drag direction contributes proportionally.
//

import SwiftUI

struct ReferenceImageView: View {
    let reference: ReferenceImage
    let onUpdate: (ReferenceImage) -> Void
    let onDelete: () -> Void
    let onBringToFront: () -> Void
    let onRequestIsolation: () -> Void

    /// In-flight drag offset from the committed center. Auto-resets to
    /// .zero when the gesture ends (or is cancelled). Manager only sees
    /// the new center when onEnded fires — no per-frame publishes.
    @GestureState private var dragOffset: CGSize = .zero

    /// In-flight resize state. nil when no resize is happening; non-nil
    /// during a drag of the resize handle. Holds the scale at gesture-
    /// begin (for stable math) and the outward delta in pixels.
    @State private var resizeStart: ResizeStart? = nil

    private struct ResizeStart {
        let scale: CGFloat
        let outwardDelta: CGFloat
    }

    private let headerHeight: CGFloat = 32
    private let resizeHandleSize: CGFloat = 28

    private var displayImage: UIImage {
        (reference.isIsolated ? reference.isolatedImage : reference.image)
            ?? reference.image
    }

    /// Effective scale: committed scale × in-flight scale factor.
    /// Driven by resizeStart's outwardDelta during an active resize.
    private var effectiveScale: CGFloat {
        guard let r = resizeStart else { return reference.scale }
        let startWidth = reference.image.size.width * r.scale
        let scaleFactor = 1.0 + r.outwardDelta / max(startWidth, 1)
        return max(0.1, r.scale * scaleFactor)
    }

    private var displayedSize: CGSize {
        CGSize(
            width: reference.image.size.width * effectiveScale,
            height: reference.image.size.height * effectiveScale,
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
        .position(
            x: reference.center.x + dragOffset.width,
            y: reference.center.y + dragOffset.height,
        )
    }

    // MARK: - Chrome bar

    private var chromeBar: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(chromeDragGesture)
                .simultaneousGesture(bringToFrontTapGesture)

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
            .allowsHitTesting(!reference.isLocked)
            .gesture(reference.isLocked ? nil : bodyDragGesture)
            .simultaneousGesture(reference.isLocked ? nil : bringToFrontTapGesture)
            .overlay(alignment: .bottomLeading) {
                if !reference.isLocked {
                    resizeHandle.padding(6)
                }
            }
    }

    // MARK: - Resize handle (single, bottom-left)

    private var resizeHandle: some View {
        Image(systemName: "arrow.down.left.and.arrow.up.right")
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .frame(width: resizeHandleSize, height: resizeHandleSize)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .contentShape(Circle())
            .gesture(resizeGesture)
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

    /// Quick-tap-to-front. Fires on touch-release with no significant
    /// movement; runs alongside the drag gestures via simultaneousGesture.
    private var bringToFrontTapGesture: some Gesture {
        TapGesture().onEnded { onBringToFront() }
    }

    /// Body drag — deferred commit. dragOffset is in-flight; the manager
    /// only learns about the new center when onEnded fires. This is the
    /// fix for "insanely jittery" — no per-frame publishes during drag,
    /// no full DrawingCanvasView body re-evaluation per touch event.
    private var bodyDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                var r = reference
                r.center = CGPoint(
                    x: reference.center.x + value.translation.width,
                    y: reference.center.y + value.translation.height,
                )
                onUpdate(r)
                onBringToFront()
            }
    }

    /// Chrome bar empty-space drag. Same deferred-commit pattern as
    /// bodyDragGesture. The controls inside the chrome bar intercept
    /// their own touches before this gesture sees them.
    private var chromeDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                var r = reference
                r.center = CGPoint(
                    x: reference.center.x + value.translation.width,
                    y: reference.center.y + value.translation.height,
                )
                onUpdate(r)
                onBringToFront()
            }
    }

    /// Single diagonal resize. Drag down-and-left = grow; up-and-right
    /// = shrink. Both axes contribute symmetrically (sum, not max).
    ///
    /// In-flight resizeStart drives effectiveScale during the drag; the
    /// manager only learns about the new scale on onEnded. Same deferred-
    /// commit pattern as the drag — no per-frame publish storm.
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let outward = -value.translation.width + value.translation.height
                if resizeStart == nil {
                    resizeStart = ResizeStart(
                        scale: reference.scale,
                        outwardDelta: outward,
                    )
                } else {
                    resizeStart = ResizeStart(
                        scale: resizeStart!.scale,  // immutable start scale
                        outwardDelta: outward,
                    )
                }
            }
            .onEnded { _ in
                guard let start = resizeStart else { return }
                let startWidth = reference.image.size.width * start.scale
                let scaleFactor = 1.0 + start.outwardDelta / max(startWidth, 1)
                let newScale = max(0.1, start.scale * scaleFactor)
                var r = reference
                r.scale = newScale
                onUpdate(r)
                resizeStart = nil
            }
    }
}
