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
            }
        }
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
    /// to the entire pose feature, not just this handler):
    ///
    ///   1. **Joint dot** — `.highPriorityGesture` claims the touch as
    ///      soon as it lands inside the 44pt hit zone. ← THIS HANDLER.
    ///      Highest priority because the joint dot is the smallest,
    ///      most-specific target; missing it should have low cost.
    ///   2. **Bone segment** (PR 4) — will attach `.highPriorityGesture`
    ///      on a hit-test capsule along the bone. Lower priority than
    ///      joints because bone capsules pass over joint centers; we
    ///      want the joint to win when both could match.
    ///   3. **Inside-bbox-pan** (PR 4) — will attach `.gesture` (regular
    ///      priority) on a transparent rectangle covering the
    ///      skeleton's bounding box. Catches drags that miss both
    ///      joints and bones — translates the whole skeleton.
    ///   4. **Fall-through to canvas** — touches that miss every
    ///      pose-owned view land on `MetalCanvasView` underneath, where
    ///      the user's current paint tool runs. This level requires
    ///      no code: SwiftUI passes touches through any region that
    ///      contains no hit-testing view (`Path` bones above set
    ///      `.allowsHitTesting(false)`; the bbox interior is empty
    ///      SwiftUI space until PR 4).
    ///
    /// **Why no flag-based cooperation.** A `@State var isDraggingJoint`
    /// gate that the bone-drag handler reads would race on touch-up:
    /// the joint's `onEnded` and the bone's `onChanged` can interleave
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
