//
//  PoseSkeletonChip.swift
//  DrawEvolve
//
//  Floating chip rendered above each visible skeleton's bounding box.
//
//  PR 2 stub: Hide + Discard buttons.
//  PR 5: added Commit button (paintbrush) ahead of Hide.
//  PR 6 (this revision): replaced the icon row with a single labeled
//  chevron button → SwiftUI Menu with the full action set:
//    Replace Photo, Commit to Trace, Hide / Show, Manually Place,
//    Discard.
//
//  Style mirrors `TransformCancelPill` (SelectionOverlays.swift:766):
//  black ~75% opacity capsule, white text/icons, soft shadow.
//

import SwiftUI

struct PoseSkeletonChipsOverlay: View {
    @ObservedObject var poseManager: PoseOverlayManager
    @ObservedObject var canvasState: CanvasStateManager
    /// Re-open the detection sheet for the given kind. Wired up in
    /// DrawingCanvasView; the sheet itself is mounted there. PR 6.
    let onRequestReplace: (PoseSkeletonKind) -> Void
    /// Build a default skeleton at canvas center for the given kind.
    /// Same trigger surface as the detection sheet's "Use default
    /// skeleton" CTA — both call into PoseOverlayManager.placeDefault.
    let onRequestManualPlace: (PoseSkeletonKind) -> Void

    @State private var pendingDiscard: PoseSkeletonKind?
    @State private var pendingCommit: PoseSkeletonKind?
    @State private var commitOpacity: CGFloat = 0.5
    @State private var commitFailureMessage: String?

    var body: some View {
        ZStack {
            ForEach(poseManager.renderableSkeletons) { skeleton in
                PoseSkeletonChip(
                    skeleton: skeleton,
                    canvasState: canvasState,
                    isHidden: false, // chip only renders for visible skeletons
                    onReplacePhoto: {
                        let kind = PoseSkeletonKind(skeleton: skeleton)
                        onRequestReplace(kind)
                    },
                    onCommit: {
                        let kind = PoseSkeletonKind(skeleton: skeleton)
                        commitOpacity = 0.5
                        pendingCommit = kind
                    },
                    onToggleVisibility: {
                        let kind = PoseSkeletonKind(skeleton: skeleton)
                        let visible = poseManager.state(for: kind).isVisible
                        poseManager.setVisible(!visible, for: kind)
                    },
                    onManuallyPlace: {
                        let kind = PoseSkeletonKind(skeleton: skeleton)
                        onRequestManualPlace(kind)
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
                            commitFailureMessage = "Select an unlocked layer first, then try again."
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
}

// MARK: - Chip (chevron + Menu)

private struct PoseSkeletonChip: View {
    let skeleton: PoseSkeleton
    @ObservedObject var canvasState: CanvasStateManager
    let isHidden: Bool
    let onReplacePhoto: () -> Void
    let onCommit: () -> Void
    let onToggleVisibility: () -> Void
    let onManuallyPlace: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        let anchor = chipAnchorScreen()
        Menu {
            Button {
                onReplacePhoto()
            } label: {
                Label("Replace Photo", systemImage: "photo.badge.plus")
            }
            Button {
                onCommit()
            } label: {
                Label("Commit to Trace", systemImage: "paintbrush.pointed")
            }
            Button {
                onToggleVisibility()
            } label: {
                Label(
                    isHidden ? "Show Skeleton" : "Hide Skeleton",
                    systemImage: isHidden ? "eye" : "eye.slash"
                )
            }
            Button {
                onManuallyPlace()
            } label: {
                Label("Manually Place", systemImage: "hand.draw")
            }
            Divider()
            Button(role: .destructive) {
                onDiscard()
            } label: {
                Label("Discard", systemImage: "trash")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: skeleton.iconName)
                    .font(.callout)
                Text(skeleton.shortLabel)
                    .font(.subheadline.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.78))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)
        }
        .accessibilityLabel("\(skeleton.shortLabel) actions")
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

private extension PoseSkeleton {
    var iconName: String {
        switch self {
        case .hand: return "hand.raised"
        case .body: return "figure.stand"
        }
    }

    var shortLabel: String {
        switch self {
        case .hand: return "Hand"
        case .body: return "Body"
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
