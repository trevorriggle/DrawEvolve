//
//  PoseSkeletonChip.swift
//  DrawEvolve
//
//  Floating chip rendered above each visible skeleton's bounding box.
//  PR 5: ships Commit + Hide + Discard. PR 6 reorganizes into a chevron
//  popover with the full menu (Replace Photo, Commit, Hide, Manually
//  Place, Discard).
//
//  Style mirrors `TransformCancelPill` (SelectionOverlays.swift:766):
//  black 75% opacity capsule, white text/icons, soft shadow.
//

import SwiftUI

struct PoseSkeletonChipsOverlay: View {
    @ObservedObject var poseManager: PoseOverlayManager
    @ObservedObject var canvasState: CanvasStateManager
    @State private var pendingDiscard: PoseSkeletonKind?
    @State private var pendingCommit: PoseSkeletonKind?
    @State private var commitOpacity: CGFloat = 0.5
    /// User-facing failure note when commit-to-trace can't run (e.g.
    /// no selected layer / locked layer). Cleared on next commit
    /// attempt.
    @State private var commitFailureMessage: String?

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
                    onCommit: {
                        let kind = PoseSkeletonKind(skeleton: skeleton)
                        // Reset slider to default each time the dialog opens
                        // so prior commits don't bleed forward.
                        commitOpacity = 0.5
                        pendingCommit = kind
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
            Button("Cancel", role: .cancel) { pendingDiscard = nil }
        } message: { _ in
            Text("You've manually moved joints. Discarding can't be undone.")
        }
        // Commit-to-trace confirmation. iOS's .confirmationDialog can't
        // host a Slider, so we use a sheet with a small dedicated view.
        // .medium detent + drag indicator matches the pose-detection
        // sheet's pattern from PR 2.
        .sheet(isPresented: Binding(
            get: { pendingCommit != nil },
            set: { if !$0 { pendingCommit = nil } }
        )) {
            if let kind = pendingCommit {
                CommitToTraceSheet(
                    kind: kind,
                    opacity: $commitOpacity,
                    onConfirm: {
                        let success = poseManager.commitToTrace(
                            kind: kind,
                            opacity: commitOpacity,
                            canvasState: canvasState
                        )
                        if !success {
                            commitFailureMessage = commitFailureCopy(kind: kind)
                        }
                        pendingCommit = nil
                    },
                    onCancel: { pendingCommit = nil }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
        .alert(
            "Couldn't commit pose",
            isPresented: Binding(
                get: { commitFailureMessage != nil },
                set: { if !$0 { commitFailureMessage = nil } }
            ),
            presenting: commitFailureMessage
        ) { _ in
            Button("OK", role: .cancel) { commitFailureMessage = nil }
        } message: { msg in
            Text(msg)
        }
    }

    private func commitFailureCopy(kind: PoseSkeletonKind) -> String {
        // CanvasStateManager.commitPoseToTrace fails when there is no
        // selected layer or the active layer is locked. Surface a single
        // copy line that covers both — the user fixes either by picking
        // an unlocked layer in the Layer Panel.
        _ = kind
        return "Select an unlocked layer first, then try again."
    }
}

// MARK: - Chip

private struct PoseSkeletonChip: View {
    let skeleton: PoseSkeleton
    @ObservedObject var canvasState: CanvasStateManager
    let onHide: () -> Void
    let onCommit: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        let anchor = chipAnchorScreen()
        HStack(spacing: 10) {
            Button(action: onCommit) {
                Image(systemName: "paintbrush.pointed")
                    .font(.callout)
                    .foregroundColor(.white)
            }
            .accessibilityLabel("Commit pose to active layer")

            Divider()
                .frame(height: 16)
                .background(Color.white.opacity(0.4))

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

// MARK: - Commit-to-trace confirmation sheet

private struct CommitToTraceSheet: View {
    let kind: PoseSkeletonKind
    @Binding var opacity: CGFloat
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Bake the \(kind == .hand ? "hand" : "body") skeleton into the active layer at the chosen opacity. The skeleton overlay will clear after committing; the strokes can be undone.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Opacity")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(Int(opacity * 100))%")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    Slider(value: $opacity, in: 0.05...1.0)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Commit to Trace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Commit", action: onConfirm)
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
