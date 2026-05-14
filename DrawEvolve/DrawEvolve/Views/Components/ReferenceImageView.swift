//
//  ReferenceImageView.swift
//  DrawEvolve
//
//  Phase 1 (2026-05-14): chrome-bar interaction model for a single
//  reference image.
//
//  Layout: 28pt header bar (always visible, hit-testable) + image body
//  (.allowsHitTesting(false), so canvas brush strokes work through it) +
//  four 16pt corner handles for resize.
//
//  Why the chrome bar instead of an invisible-image-with-simultaneousGesture
//  approach: the canvas's MTKView handles touches via
//  touchesBegan/Moved/Ended overrides on the UIView itself, not via
//  UIGestureRecognizer. Once a SwiftUI overlay hosts a hit-testable view
//  at the touch point, the MTKView never sees that touch, regardless of
//  what SwiftUI does with .simultaneousGesture. The chrome bar makes
//  drag-to-move and the control buttons explicit hit targets; the image
//  body itself is fully non-interactive, so brush strokes pass straight
//  through to the canvas underneath.
//

import SwiftUI

struct ReferenceImageView: View {
    let reference: ReferenceImage
    let onUpdate: (ReferenceImage) -> Void
    let onDelete: () -> Void
    let onBringToFront: () -> Void

    @GestureState private var headerDragOffset: CGSize = .zero
    @GestureState private var cornerDragStartScale: CGFloat? = nil

    private let headerHeight: CGFloat = 28
    private let cornerHandleSize: CGFloat = 16

    private var displayedSize: CGSize {
        CGSize(
            width: reference.image.size.width * reference.scale,
            height: reference.image.size.height * reference.scale,
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            imageBody
        }
        .frame(width: displayedSize.width)
        .position(
            x: reference.center.x + headerDragOffset.width,
            y: reference.center.y + headerDragOffset.height,
        )
        .overlay(cornerHandles)
    }

    // MARK: - Header bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.semibold))
                .foregroundColor(.white.opacity(0.85))

            Slider(value: Binding(
                get: { reference.opacity },
                set: { newValue in
                    var r = reference
                    r.opacity = newValue
                    onUpdate(r)
                },
            ), in: 0.0...1.0)
            .controlSize(.mini)
            .tint(.white)

            Button {
                var r = reference
                r.isFlipped.toggle()
                onUpdate(r)
            } label: {
                Image(systemName: "arrow.left.and.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(height: headerHeight)
        .background(Color.black.opacity(0.55))
        .contentShape(Rectangle())
        .gesture(headerDragGesture)
        // Tap fires when the drag gesture fails to recognize (touch
        // released within DragGesture's default 10pt minimum distance).
        // Brings this reference to the front on every header touch.
        .onTapGesture { onBringToFront() }
    }

    // MARK: - Image body

    private var imageBody: some View {
        Image(uiImage: reference.image)
            .resizable()
            .scaledToFit()
            .frame(width: displayedSize.width, height: displayedSize.height)
            .scaleEffect(x: reference.isFlipped ? -1 : 1, y: 1)
            .opacity(reference.opacity)
            // Brush strokes pass through to the canvas underneath. This
            // is the keystone of the chrome-bar model — non-interactive
            // body means no gesture conflict between reference and
            // canvas. Touches only register on the header and corners.
            .allowsHitTesting(false)
    }

    // MARK: - Corner handles

    private var cornerHandles: some View {
        // Total height of the combined header+image rect.
        let w = displayedSize.width
        let h = displayedSize.height + headerHeight
        return ZStack {
            // signX = -1 for left corners, +1 for right. The signed
            // delta makes outward drag grow the reference at every
            // corner — without the sign, leftward drag would shrink
            // because translation.width is negative.
            cornerHandle(at: CGPoint(x: 0, y: 0), signX: -1)
            cornerHandle(at: CGPoint(x: w, y: 0), signX: +1)
            cornerHandle(at: CGPoint(x: 0, y: h), signX: -1)
            cornerHandle(at: CGPoint(x: w, y: h), signX: +1)
        }
        .frame(width: w, height: h, alignment: .topLeading)
    }

    private func cornerHandle(at point: CGPoint, signX: CGFloat) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
            .frame(width: cornerHandleSize, height: cornerHandleSize)
            .position(x: point.x, y: point.y)
            .gesture(cornerDragGesture(startWidth: displayedSize.width, signX: signX))
    }

    // MARK: - Gestures

    private var headerDragGesture: some Gesture {
        DragGesture()
            .updating($headerDragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                var r = reference
                r.center = CGPoint(
                    x: reference.center.x + value.translation.width,
                    y: reference.center.y + value.translation.height,
                )
                onUpdate(r)
            }
    }

    /// Multiplicative scaling: drag distance maps to pixel growth rather
    /// than absolute scale offset. A 60px drag on a 600px-wide reference
    /// adds 10% to its size — matches what the user's hand is doing.
    /// (Additive formula `initial + delta/startWidth` would translate the
    /// same drag into a much larger absolute scale change for small refs.)
    ///
    /// `signX` per corner makes outward drag always grow: leftward drag
    /// (negative delta) on left corners gets flipped positive, so all four
    /// corners feel symmetric.
    private func cornerDragGesture(startWidth: CGFloat, signX: CGFloat) -> some Gesture {
        DragGesture()
            .updating($cornerDragStartScale) { _, state, _ in
                if state == nil { state = reference.scale }
            }
            .onChanged { value in
                let initial = cornerDragStartScale ?? reference.scale
                let signedDelta = signX * value.translation.width
                let scaleFactor = 1.0 + signedDelta / max(startWidth, 1)
                let newScale = max(0.1, initial * scaleFactor)
                var r = reference
                r.scale = newScale
                onUpdate(r)
            }
    }
}
