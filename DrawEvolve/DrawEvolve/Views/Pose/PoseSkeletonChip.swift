//
//  PoseSkeletonChip.swift
//  DrawEvolve
//
//  Floating chip rendered above each visible skeleton's bounding box.
//  PR 2 stub — surfaces only Hide and Discard actions per the locked-in
//  scope. PR 6 expands to the full menu (Replace Photo, Commit to Trace,
//  Discard, Manually Place) with a chevron-driven popover.
//
//  Style mirrors `TransformCancelPill` (SelectionOverlays.swift:766):
//  black 75% opacity capsule, white text/icons, soft shadow.
//

import SwiftUI

struct PoseSkeletonChipsOverlay: View {
    @ObservedObject var poseManager: PoseOverlayManager
    @ObservedObject var canvasState: CanvasStateManager
    @State private var pendingDiscard: PoseSkeletonKind?

    var body: some View {
        ZStack {
            ForEach(poseManager.renderableSkeletons) { skeleton in
                PoseSkeletonChip(
                    skeleton: skeleton,
                    canvasState: canvasState,
                    onHide: {
                        let kind = PoseSkeletonKind(skeleton: skeleton)
                        poseManager.setVisible(false, for: kind)
                    },
                    onDiscard: {
                        let kind = PoseSkeletonKind(skeleton: skeleton)
                        if poseManager.hasManualEdits(for: kind) {
                            pendingDiscard = kind
                        } else {
                            poseManager.discard(kind)
                        }
                    }
                )
            }
        }
        .alert(
            "Discard pose reference?",
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            presenting: pendingDiscard
        ) { kind in
            Button("Discard", role: .destructive) {
                poseManager.discard(kind)
                pendingDiscard = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDiscard = nil
            }
        } message: { _ in
            Text("You've manually moved joints. Discarding can't be undone.")
        }
    }
}

private struct PoseSkeletonChip: View {
    let skeleton: PoseSkeleton
    @ObservedObject var canvasState: CanvasStateManager
    let onHide: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        let anchor = chipAnchorScreen()
        HStack(spacing: 10) {
            Button(action: onHide) {
                Image(systemName: "eye.slash")
                    .font(.callout)
                    .foregroundColor(.white)
            }
            .accessibilityLabel("Hide pose reference")

            Divider()
                .frame(height: 16)
                .background(Color.white.opacity(0.4))

            Button(action: onDiscard) {
                Image(systemName: "xmark")
                    .font(.callout)
                    .foregroundColor(.white)
            }
            .accessibilityLabel("Discard pose reference")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.75))
        .clipShape(Capsule())
        .shadow(radius: 3)
        .position(anchor)
    }

    /// Project the skeleton's joint bbox into screen space and anchor the
    /// chip ~24pt above the top edge.
    private func chipAnchorScreen() -> CGPoint {
        let docPositions = jointPositions
        guard !docPositions.isEmpty else { return .zero }
        let minX = docPositions.map(\.x).min() ?? 0
        let maxX = docPositions.map(\.x).max() ?? 0
        let minY = docPositions.map(\.y).min() ?? 0
        let centerDoc = CGPoint(x: (minX + maxX) / 2, y: minY)
        let centerScreen = canvasState.documentToScreen(centerDoc)
        return CGPoint(x: centerScreen.x, y: centerScreen.y - 24)
    }

    private var jointPositions: [CGPoint] {
        switch skeleton {
        case .hand(let pose): return pose.joints.values.map(\.position)
        case .body(let pose): return pose.joints.values.map(\.position)
        }
    }
}
