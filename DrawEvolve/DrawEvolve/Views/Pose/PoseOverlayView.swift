//
//  PoseOverlayView.swift
//  DrawEvolve
//
//  SwiftUI overlay rendering active pose skeletons. Sibling to
//  TransformHandlesOverlay in DrawingCanvasView's canvas ZStack —
//  positioned in screen space via `canvasState.documentToScreen`, so the
//  skeleton zooms / pans / rotates / flips with the canvas for free.
//
//  PR 2: read-only.
//  PR 3 (this file): per-joint editing on iPad. Bones stay non-interactive
//  here; bone-drag and inside-bbox-pan land in PR 4 alongside the
//  whole-skeleton transform handles. iPhone stays read-only per
//  Decision 10 (21+19 joints in close proximity won't hit-test reliably
//  at thumb size).
//

import SwiftUI

struct PoseOverlayView: View {
    @ObservedObject var poseManager: PoseOverlayManager
    @ObservedObject var canvasState: CanvasStateManager

    var body: some View {
        ZStack {
            ForEach(poseManager.renderableSkeletons) { skeleton in
                PoseSkeletonView(
                    skeleton: skeleton,
                    poseManager: poseManager,
                    canvasState: canvasState,
                    interactive: DeviceIdiom.isPad
                )
                // Smooth in/out as skeletons appear (place / show) and
                // disappear (hide / discard / commit). PR 6 polish.
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: poseManager.renderableSkeletons.map(\.id))
        // No top-level allowsHitTesting modifier — interactivity is
        // gated per-joint inside PoseJointDot. Bones are explicitly
        // non-interactive (allowsHitTesting(false) on the Path), and
        // bbox-interior space contains no SwiftUI views, so paint
        // touches in those regions fall through to MetalCanvasView.
    }
}

private struct PoseSkeletonView: View {
    let skeleton: PoseSkeleton
    @ObservedObject var poseManager: PoseOverlayManager
    @ObservedObject var canvasState: CanvasStateManager
    let interactive: Bool

    var body: some View {
        switch skeleton {
        case .hand(let pose):
            HandSkeletonView(
                pose: pose,
                poseManager: poseManager,
                canvasState: canvasState,
                interactive: interactive
            )
        case .body(let pose):
            BodySkeletonView(
                pose: pose,
                poseManager: poseManager,
                canvasState: canvasState,
                interactive: interactive
            )
        }
    }
}

// MARK: - Hand

private struct HandSkeletonView: View {
    let pose: HandPose
    @ObservedObject var poseManager: PoseOverlayManager
    @ObservedObject var canvasState: CanvasStateManager
    let interactive: Bool

    var body: some View {
        ZStack {
            // Bones — single Path so all 20 strokes share one shadow pass.
            // Explicitly non-interactive: bone-drag is a PR 4 deliverable,
            // and a stroked Path's default contentShape would otherwise
            // intercept touches that should land on joint dots layered
            // above it.
            Path { path in
                for (a, b) in HandTopology.connections {
                    guard let pa = pose.joints[a]?.position,
                          let pb = pose.joints[b]?.position else { continue }
                    path.move(to: canvasState.documentToScreen(pa))
                    path.addLine(to: canvasState.documentToScreen(pb))
                }
            }
            .stroke(PoseStyle.boneColor, style: PoseStyle.boneStroke)
            .shadow(color: PoseStyle.boneShadow, radius: 2, x: 0, y: 1)
            .allowsHitTesting(false)

            // Joints — each its own SwiftUI sibling with its own gesture.
            ForEach(HandJoint.allCases, id: \.self) { joint in
                if let sample = pose.joints[joint] {
                    PoseJointDot(
                        position: canvasState.documentToScreen(sample.position),
                        confidence: sample.confidence,
                        isManuallyMoved: sample.isManuallyMoved,
                        interactive: interactive,
                        onDragChanged: { screenPoint in
                            let docPoint = canvasState.screenToDocument(screenPoint)
                            poseManager.updateHandJoint(
                                skeletonID: pose.id,
                                joint: joint,
                                to: docPoint
                            )
                            // Refresh the 4s bbox-active timer so the
                            // transform handles stay armed while the
                            // user is mid-edit (audit §6.3).
                            poseManager.activate(skeletonID: pose.id)
                        }
                    )
                }
            }
        }
    }
}

// MARK: - Body

private struct BodySkeletonView: View {
    let pose: BodyPose
    @ObservedObject var poseManager: PoseOverlayManager
    @ObservedObject var canvasState: CanvasStateManager
    let interactive: Bool

    var body: some View {
        ZStack {
            // Primary bones — full opacity, non-interactive.
            Path { path in
                for (a, b) in BodyTopology.primaryConnections {
                    guard let pa = pose.joints[a]?.position,
                          let pb = pose.joints[b]?.position else { continue }
                    path.move(to: canvasState.documentToScreen(pa))
                    path.addLine(to: canvasState.documentToScreen(pb))
                }
            }
            .stroke(PoseStyle.boneColor, style: PoseStyle.boneStroke)
            .shadow(color: PoseStyle.boneShadow, radius: 2, x: 0, y: 1)
            .allowsHitTesting(false)

            // Face decoration — half opacity, non-interactive.
            Path { path in
                for (a, b) in BodyTopology.faceConnections {
                    guard let pa = pose.joints[a]?.position,
                          let pb = pose.joints[b]?.position else { continue }
                    path.move(to: canvasState.documentToScreen(pa))
                    path.addLine(to: canvasState.documentToScreen(pb))
                }
            }
            .stroke(PoseStyle.faceColor, style: PoseStyle.faceStroke)
            .allowsHitTesting(false)

            ForEach(BodyJoint.allCases, id: \.self) { joint in
                if let sample = pose.joints[joint] {
                    PoseJointDot(
                        position: canvasState.documentToScreen(sample.position),
                        confidence: sample.confidence,
                        isManuallyMoved: sample.isManuallyMoved,
                        interactive: interactive,
                        onDragChanged: { screenPoint in
                            let docPoint = canvasState.screenToDocument(screenPoint)
                            poseManager.updateBodyJoint(
                                skeletonID: pose.id,
                                joint: joint,
                                to: docPoint
                            )
                            poseManager.activate(skeletonID: pose.id)
                        }
                    )
                }
            }
        }
    }
}

// MARK: - Joint dot

/// 12pt accent-fill dot with a 1pt white stroke. Wraps a 44pt invisible
/// hit zone when interactive (per-joint editing on iPad — Decision 10).
/// Low-confidence joints pulse yellow until manually moved (Decision 8).
private struct PoseJointDot: View {
    let position: CGPoint
    let confidence: Float
    let isManuallyMoved: Bool
    let interactive: Bool
    /// Screen-space drag delivery. Convert with
    /// `canvasState.screenToDocument` at the call site.
    let onDragChanged: (CGPoint) -> Void

    @State private var pulse: Bool = false
    @State private var isDragging: Bool = false

    private var isLowConfidence: Bool {
        !isManuallyMoved && confidence < PoseConfidence.lowThreshold
    }

    var body: some View {
        let visual = Circle()
            .fill(isLowConfidence ? Color.yellow : Color.accentColor)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(Color.white, lineWidth: 1))
            .scaleEffect(isDragging ? 1.2 : 1.0)
            .opacity(isLowConfidence ? (pulse ? 1.0 : 0.6) : 1.0)
            .animation(.easeOut(duration: 0.12), value: isDragging)

        Group {
            if interactive {
                ZStack {
                    // 44pt invisible hit zone — Apple's recommended
                    // minimum touch target. Same pattern as
                    // SelectionOverlays.handleDot() (lines 244–256).
                    Color.clear
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                    visual
                }
                .position(position)
                .highPriorityGesture(jointDrag)
            } else {
                visual
                    .position(position)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            guard isLowConfidence else { return }
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    /// Per-joint drag.
    ///
    /// **Pose-overlay gesture priority chain** (audit §6.4 — applies
    /// to the entire pose feature). Last reviewed end of PR 4.
    ///
    ///   1. **Two-finger pinch / rotate on the bbox** (PR 4) — attached
    ///      to the transparent bbox-pan rectangle in
    ///      `PoseTransformHandlesView`. Distinct gesture *type* from the
    ///      single-finger drags below, so SwiftUI's gesture engine
    ///      routes two-finger sequences to it without conflicting with
    ///      joint / handle / bbox-pan single-finger drags.
    ///   2. **Joint dot** — `.highPriorityGesture` claims the touch as
    ///      soon as it lands inside the 44pt hit zone. ← THIS HANDLER.
    ///      Highest single-finger priority because the joint dot is
    ///      the smallest, most-specific target.
    ///   3. **Transform handle** (PR 4) — corner / edge / rotation
    ///      handles in `PoseTransformHandlesView`. Lower priority than
    ///      joints because corner-handle hit zones at the bbox extents
    ///      can sit close to extremity joints (wrist, fingertips,
    ///      ankles); we want the joint to win when their hit zones
    ///      overlap. The bbox is padded outward to widen the gap.
    ///   4. **Bone segment** (DEFERRED past PR 4) — would attach
    ///      `.highPriorityGesture` on a hit-test capsule along the
    ///      bone to drag both endpoint joints together. Not shipping
    ///      in v1 of the pose feature; if added later, slot here.
    ///   5. **Inside-bbox-pan** (PR 4) — `.gesture` (regular priority)
    ///      on the transparent rectangle covering the skeleton's
    ///      bounding box, gated on bbox-active. Catches single-finger
    ///      drags that miss every joint and handle — translates the
    ///      whole skeleton.
    ///   6. **Fall-through to canvas** — touches that miss every
    ///      pose-owned view land on `MetalCanvasView` underneath. This
    ///      level requires no code: bones set `.allowsHitTesting(false)`
    ///      and the bbox interior is non-hit-testing once the 4-second
    ///      auto-deselect timer fires.
    ///
    /// **Why no flag-based cooperation.** A `@State var isDraggingJoint`
    /// gate that the handle-drag handler reads would race on touch-up:
    /// the joint's `onEnded` and the handle's `onChanged` can interleave
    /// across run-loop boundaries, and the bug only reproduces on real
    /// hardware (where touch events come from the digitizer at a
    /// different cadence than synthetic simulator events). The
    /// `.highPriorityGesture` modifier resolves this in SwiftUI's
    /// gesture engine — once a high-priority gesture begins, it owns
    /// the touch until ended/cancelled. Don't replace this with flags.
    private var jointDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                isDragging = true
                onDragChanged(value.location)
            }
            .onEnded { _ in
                isDragging = false
            }
    }
}

// MARK: - Style constants

private enum PoseStyle {
    static let boneColor = Color.accentColor.opacity(0.85)
    static let boneStroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
    static let boneShadow = Color.black.opacity(0.3)

    static let faceColor = Color.accentColor.opacity(0.5)
    static let faceStroke = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
}
