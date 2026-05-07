//
//  PoseOverlayView.swift
//  DrawEvolve
//
//  SwiftUI overlay rendering active pose skeletons. Sibling to
//  TransformHandlesOverlay in DrawingCanvasView's canvas ZStack —
//  positioned in screen space via `canvasState.documentToScreen`, so the
//  skeleton zooms / pans / rotates / flips with the canvas for free.
//
//  PR 2: read-only. PR 3 attaches per-joint DragGesture in the same view.
//  Whole-skeleton transform handles arrive in PR 4 as a separate sibling
//  overlay so this file stays focused on bone+joint rendering.
//

import SwiftUI

struct PoseOverlayView: View {
    @ObservedObject var poseManager: PoseOverlayManager
    @ObservedObject var canvasState: CanvasStateManager

    var body: some View {
        // Touches outside joints/bones fall through to MTKView so the user
        // can still draw under the skeleton with a paint tool selected.
        ZStack {
            ForEach(poseManager.renderableSkeletons) { skeleton in
                PoseSkeletonView(skeleton: skeleton, canvasState: canvasState)
            }
        }
        .allowsHitTesting(false)  // PR 3 swaps to per-joint gestures
    }
}

private struct PoseSkeletonView: View {
    let skeleton: PoseSkeleton
    @ObservedObject var canvasState: CanvasStateManager

    var body: some View {
        switch skeleton {
        case .hand(let pose):
            HandSkeletonView(pose: pose, canvasState: canvasState)
        case .body(let pose):
            BodySkeletonView(pose: pose, canvasState: canvasState)
        }
    }
}

// MARK: - Hand

private struct HandSkeletonView: View {
    let pose: HandPose
    @ObservedObject var canvasState: CanvasStateManager

    var body: some View {
        ZStack {
            // Bones — single Path so all 20 strokes share one shadow pass
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

            // Joints
            ForEach(HandJoint.allCases, id: \.self) { joint in
                if let sample = pose.joints[joint] {
                    PoseJointDot(
                        position: canvasState.documentToScreen(sample.position),
                        confidence: sample.confidence,
                        isManuallyMoved: sample.isManuallyMoved
                    )
                }
            }
        }
    }
}

// MARK: - Body

private struct BodySkeletonView: View {
    let pose: BodyPose
    @ObservedObject var canvasState: CanvasStateManager

    var body: some View {
        ZStack {
            // Primary bones — full opacity
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

            // Face decoration — half opacity (still snaps to skeleton
            // movement; rendered as a separate path so the dim tint can
            // diverge from the primary skeleton color).
            Path { path in
                for (a, b) in BodyTopology.faceConnections {
                    guard let pa = pose.joints[a]?.position,
                          let pb = pose.joints[b]?.position else { continue }
                    path.move(to: canvasState.documentToScreen(pa))
                    path.addLine(to: canvasState.documentToScreen(pb))
                }
            }
            .stroke(PoseStyle.faceColor, style: PoseStyle.faceStroke)

            ForEach(BodyJoint.allCases, id: \.self) { joint in
                if let sample = pose.joints[joint] {
                    PoseJointDot(
                        position: canvasState.documentToScreen(sample.position),
                        confidence: sample.confidence,
                        isManuallyMoved: sample.isManuallyMoved
                    )
                }
            }
        }
    }
}

// MARK: - Joint dot

/// 12pt accent-fill dot with a 1pt white stroke. Low-confidence joints
/// pulse yellow until manually moved (Decision 8). Hit target widens to
/// 44pt in PR 3 when DragGesture is attached.
private struct PoseJointDot: View {
    let position: CGPoint
    let confidence: Float
    let isManuallyMoved: Bool

    @State private var pulse: Bool = false

    private var isLowConfidence: Bool {
        !isManuallyMoved && confidence < PoseConfidence.lowThreshold
    }

    var body: some View {
        Circle()
            .fill(isLowConfidence ? Color.yellow : Color.accentColor)
            .frame(width: 12, height: 12)
            .overlay(
                Circle().stroke(Color.white, lineWidth: 1)
            )
            .opacity(isLowConfidence ? (pulse ? 1.0 : 0.6) : 1.0)
            .position(position)
            .onAppear {
                guard isLowConfidence else { return }
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                    pulse = true
                }
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
