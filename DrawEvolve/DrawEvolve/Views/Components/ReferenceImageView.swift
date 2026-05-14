//
//  ReferenceImageView.swift
//  DrawEvolve
//
//  Pass 5 (2026-05-14): adds "Move & Scale with canvas" mode.
//  When followsCanvas is true, the reference's center is in DOC-space
//  and the canvas's pan/zoom/rotation transform is applied at render
//  time — the reference visually pans / zooms / rotates with the canvas
//  like a real layer. When false (default), reference is screen-fixed.
//
//  Toggling between modes preserves the visible state at the moment of
//  the flip via a smooth coordinate conversion. Special-cased for the
//  "uncheck while canvas is rotated" path the user requested: the
//  reference keeps its visible size and stays at the same screen
//  position, but un-rotates to upright.
//
//  Architecturally: this view stays a SwiftUI overlay above the Metal
//  canvas. Front-mode follow-canvas refs render entirely in SwiftUI via
//  .position + .rotationEffect + sized .frame. Back-mode follow-canvas
//  refs are rendered by the Metal pass in MetalCanvasView's Coordinator;
//  this SwiftUI view keeps its image at opacity 0 but renders its chrome
//  (controls) at the same screen position so the user can still interact.
//
//  Drag/resize math: drag deltas are in screen-space (coordinateSpace:
//  .global). When following, drag-end converts the new screen position
//  back to doc-space. Resize uses screen-pixel width as the denominator
//  so the 1:1 finger-tracking feel works regardless of zoom.
//

import SwiftUI

struct ReferenceImageView: View {
    let reference: ReferenceImage
    @ObservedObject var canvasState: CanvasStateManager
    let onUpdate: (ReferenceImage) -> Void
    let onDelete: () -> Void
    let onBringToFront: () -> Void
    let onRequestIsolation: () -> Void

    @GestureState private var dragOffset: CGSize = .zero
    @State private var resizeStart: ResizeStart? = nil
    @State private var showProperties: Bool = false

    private struct ResizeStart {
        let scale: CGFloat
        let outwardDelta: CGFloat
        /// Width of the reference IN SCREEN PIXELS at gesture-begin.
        /// In follow mode this includes the canvas's zoom factor so the
        /// 1:1 finger-tracking math works correctly.
        let screenWidth: CGFloat
    }

    private let cornerHandleSize: CGFloat = 28
    private let chromeIconSize: CGFloat = 28

    private var displayImage: UIImage {
        (reference.isIsolated ? reference.isolatedImage : reference.image)
            ?? reference.image
    }

    /// Effective screen-space center of the reference. Doc→screen
    /// transform when following the canvas; identity otherwise.
    private var effectiveScreenCenter: CGPoint {
        reference.followsCanvas
            ? canvasState.documentToScreen(reference.center)
            : reference.center
    }

    /// Base scale (without canvas zoom). Applies in-flight resize delta.
    private var effectiveBaseScale: CGFloat {
        guard let r = resizeStart else { return reference.scale }
        let scaleFactor = 1.0 + r.outwardDelta / max(r.screenWidth, 1)
        return max(0.1, r.scale * scaleFactor)
    }

    /// Displayed scale on screen — base scale × canvas zoom when following.
    private var effectiveScreenScale: CGFloat {
        let base = effectiveBaseScale
        return reference.followsCanvas ? base * canvasState.zoomScale : base
    }

    /// Rotation applied to the rendered view. Follows canvas rotation
    /// when in follow mode; zero otherwise.
    ///
    /// Negated because SwiftUI's `.rotationEffect(+angle)` rotates CW
    /// visually, but `canvasState.canvasRotation` already had its sign
    /// inverted at gesture-handler time (MetalCanvasView:3144) so that
    /// the canvas's main shader (R(θ) in Y-up = CCW for positive) lines
    /// up with user-CW gestures. The net effect of those two inversions
    /// is that we need to negate here to make the SwiftUI rotation
    /// agree with the canvas content's visual rotation.
    private var effectiveRotation: Angle {
        reference.followsCanvas ? -canvasState.canvasRotation : .zero
    }

    private var displayedSize: CGSize {
        CGSize(
            width: reference.image.size.width * effectiveScreenScale,
            height: reference.image.size.height * effectiveScreenScale,
        )
    }

    var body: some View {
        imageBody
            .frame(width: displayedSize.width, height: displayedSize.height)
            .overlay(frameBorder)
            .overlay(alignment: .topTrailing) {
                if !reference.isLocked { deleteButton.padding(8) }
            }
            .overlay(alignment: .bottomLeading) {
                lowerLeftStack.padding(8)
            }
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            .rotationEffect(effectiveRotation)
            .position(
                x: effectiveScreenCenter.x + dragOffset.width,
                y: effectiveScreenCenter.y + dragOffset.height,
            )
    }

    // MARK: - Image body

    /// In back-canvas mode the visible image comes from a Metal pass
    /// rendered behind the layer composite — the SwiftUI image goes
    /// opacity 0 to stay out of the way, while the controls overlay
    /// keeps its chrome visible so the user can still interact.
    private var imageBody: some View {
        Image(uiImage: displayImage)
            .resizable()
            .scaledToFit()
            .scaleEffect(
                x: reference.isFlipped ? -1 : 1,
                y: reference.isFlippedY ? -1 : 1,
            )
            .opacity(reference.isBehindCanvas ? 0 : reference.opacity)
            .contentShape(Rectangle())
            .allowsHitTesting(!reference.isLocked)
            .gesture(reference.isLocked ? nil : bodyDragGesture)
    }

    // MARK: - Frame border

    private var frameBorder: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(
                reference.isLocked
                    ? Color.white.opacity(0.25)
                    : Color.accentColor.opacity(0.85),
                lineWidth: 1.5,
            )
    }

    // MARK: - Top-right delete button

    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .frame(width: chromeIconSize, height: chromeIconSize)
                .background(Circle().fill(Color.black.opacity(0.7)))
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Lower-left stack: lock + properties + resize

    private var lowerLeftStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer(minLength: 0)
            lockButton
            if !reference.isLocked {
                propertiesButton
                resizeHandle
            }
        }
    }

    private var lockButton: some View {
        Button {
            var r = reference
            r.isLocked.toggle()
            onUpdate(r)
        } label: {
            Image(systemName: reference.isLocked ? "lock.fill" : "lock.open")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(width: chromeIconSize, height: chromeIconSize)
                .background(Circle().fill(reference.isLocked ? Color.yellow.opacity(0.85) : Color.accentColor))
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var propertiesButton: some View {
        Button { showProperties = true } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(width: chromeIconSize, height: chromeIconSize)
                .background(Circle().fill(Color.accentColor))
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showProperties, arrowEdge: .leading) {
            ReferencePropertiesPopover(
                reference: reference,
                canvasState: canvasState,
                onUpdate: onUpdate,
                onRequestIsolation: onRequestIsolation,
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.down.left.and.arrow.up.right")
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .frame(width: cornerHandleSize, height: cornerHandleSize)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .contentShape(Circle())
            .gesture(resizeGesture)
    }

    // MARK: - Gestures

    /// Body drag — deferred commit. dragOffset is in-flight screen-space
    /// delta. On end, the new screen position is converted back to doc
    /// space if the reference follows the canvas, otherwise stored as-is.
    private var bodyDragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                var r = reference
                let newScreenCenter = CGPoint(
                    x: effectiveScreenCenter.x + value.translation.width,
                    y: effectiveScreenCenter.y + value.translation.height,
                )
                if reference.followsCanvas {
                    r.center = canvasState.screenToDocument(newScreenCenter)
                } else {
                    r.center = newScreenCenter
                }
                onUpdate(r)
                onBringToFront()
            }
    }

    /// Single diagonal resize. Drag down-and-left = grow; up-and-right =
    /// shrink. screenWidth captured at gesture-begin includes the canvas
    /// zoom factor when following, so the 1:1 finger-tracking feel works
    /// regardless of mode.
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let outward = -value.translation.width + value.translation.height
                if resizeStart == nil {
                    let screenWidth = reference.image.size.width * reference.scale
                        * (reference.followsCanvas ? canvasState.zoomScale : 1.0)
                    resizeStart = ResizeStart(
                        scale: reference.scale,
                        outwardDelta: outward,
                        screenWidth: screenWidth,
                    )
                } else {
                    resizeStart = ResizeStart(
                        scale: resizeStart!.scale,
                        outwardDelta: outward,
                        screenWidth: resizeStart!.screenWidth,
                    )
                }
            }
            .onEnded { _ in
                guard let start = resizeStart else { return }
                let scaleFactor = 1.0 + start.outwardDelta / max(start.screenWidth, 1)
                let newScale = max(0.1, start.scale * scaleFactor)
                var r = reference
                r.scale = newScale
                onUpdate(r)
                resizeStart = nil
            }
    }
}

// MARK: - Properties popover

private struct ReferencePropertiesPopover: View {
    let reference: ReferenceImage
    @ObservedObject var canvasState: CanvasStateManager
    let onUpdate: (ReferenceImage) -> Void
    let onRequestIsolation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            opacityRow
            sendToBackToggle
            followsCanvasToggle
            isolationToggle
            flipRow
        }
        .padding(16)
        .frame(width: 280)
    }

    private var opacityRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Opacity").font(.subheadline)
                Spacer()
                Text("\(Int(reference.opacity * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: Binding(
                get: { reference.opacity },
                set: { newValue in
                    var r = reference
                    r.opacity = newValue
                    onUpdate(r)
                },
            ), in: 0.0...1.0)
        }
    }

    private var sendToBackToggle: some View {
        Button {
            var r = reference
            r.isBehindCanvas.toggle()
            onUpdate(r)
        } label: {
            HStack {
                Image(systemName: reference.isBehindCanvas
                      ? "rectangle.stack.badge.plus"
                      : "rectangle.stack.badge.minus")
                    .frame(width: 22)
                Text(reference.isBehindCanvas
                     ? "Send to front"
                     : "Send to back of canvas")
                    .font(.subheadline)
                Spacer()
            }
            .foregroundColor(.primary)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Move & Scale with canvas" toggle. Switching between modes
    /// preserves the visible state at the moment of the flip:
    ///   ON  (fixed → follow): screen center → doc center, scale /= zoom.
    ///       Canvas rotation now applies — if the canvas is rotated, the
    ///       reference will visually rotate to match (this is the
    ///       inevitable cost of "following" a rotated canvas).
    ///   OFF (follow → fixed): doc center → screen center, scale *= zoom.
    ///       Canvas rotation no longer applies — the reference becomes
    ///       upright at its current screen position with current visible
    ///       size. This is the user-requested behavior.
    private var followsCanvasToggle: some View {
        Button {
            var r = reference
            let zoom = canvasState.zoomScale
            if r.followsCanvas {
                // Bake current displayed state, then un-follow.
                r.center = canvasState.documentToScreen(r.center)
                r.scale = r.scale * zoom
                r.followsCanvas = false
            } else {
                r.center = canvasState.screenToDocument(r.center)
                r.scale = r.scale / max(zoom, 0.001)
                r.followsCanvas = true
            }
            onUpdate(r)
        } label: {
            HStack {
                Image(systemName: reference.followsCanvas
                      ? "lock.rotation"
                      : "arrow.up.and.down.and.arrow.left.and.right")
                    .frame(width: 22)
                Text("Move & Scale with canvas")
                    .font(.subheadline)
                Spacer()
                Image(systemName: reference.followsCanvas
                      ? "checkmark.circle.fill"
                      : "circle")
                    .foregroundColor(reference.followsCanvas ? .accentColor : .secondary)
            }
            .foregroundColor(.primary)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var isolationToggle: some View {
        Button(action: onRequestIsolation) {
            HStack {
                if reference.isIsolating {
                    ProgressView().controlSize(.mini).frame(width: 22)
                } else {
                    Image(systemName: reference.isIsolated
                          ? "person.crop.rectangle.badge.checkmark"
                          : "person.crop.rectangle.stack")
                        .frame(width: 22)
                }
                Text(reference.isIsolated
                     ? "Show original"
                     : (reference.isIsolating ? "Isolating subject…" : "Isolate subject"))
                    .font(.subheadline)
                Spacer()
                if reference.lastIsolationFailed && !reference.isIsolating {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                }
            }
            .foregroundColor(.primary)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reference.isIsolating)
    }

    private var flipRow: some View {
        HStack(spacing: 10) {
            Button {
                var r = reference
                r.isFlipped.toggle()
                onUpdate(r)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.and.right")
                    Text("Flip H").font(.subheadline)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                var r = reference
                r.isFlippedY.toggle()
                onUpdate(r)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.and.down")
                    Text("Flip V").font(.subheadline)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}
