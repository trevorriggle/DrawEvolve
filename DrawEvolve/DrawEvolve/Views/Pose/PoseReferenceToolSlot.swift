//
//  PoseReferenceToolSlot.swift
//  DrawEvolve
//
//  Wrappers that adapt the shared `GroupedToolButton` (iPad) and plain
//  `ToolButton` styling (iPhone) to the pose-reference tap cycle from
//  Decision 7. All pose-specific behavior lives here so the underlying
//  shared toolbar primitives stay free of pose concerns.
//
//  iPad: PoseReferenceSlot wraps GroupedToolButton, observes the slot's
//  `@AppStorage`-backed currentVariant directly to render an
//  outline-only "skeleton hidden" overlay on top of the slot.
//
//  iPhone: PoseReferenceTile renders a single ToolButton-styled tile per
//  variant (handPose / bodyPose). The same tap-cycle handler is used.
//

import SwiftUI

// MARK: - iPad

struct PoseReferenceSlot: View {
    @ObservedObject var poseManager: PoseOverlayManager
    /// Called when a tap resolves into "open detection sheet for this kind".
    let onRequestDetection: (PoseSkeletonKind) -> Void

    @AppStorage(ToolGroup.poseReference.storageKey) private var currentVariantString: String = ToolGroup.poseReference.defaultVariant.storageString

    private var currentTool: DrawingTool {
        if case .tool(let t) = ToolVariant(storageString: currentVariantString) ?? ToolGroup.poseReference.defaultVariant {
            return t
        }
        return .handPose
    }

    private var currentKind: PoseSkeletonKind {
        PoseSkeletonKind(tool: currentTool) ?? .hand
    }

    private var slotState: PoseOverlayManager.SlotState {
        poseManager.state(for: currentKind)
    }

    var body: some View {
        GroupedToolButton(
            group: .poseReference,
            isSelected: { variant in
                guard case .tool(let tool) = variant,
                      let kind = PoseSkeletonKind(tool: tool) else { return false }
                return poseManager.state(for: kind).isVisible
            },
            onActivate: { variant in
                guard case .tool(let tool) = variant else { return }
                handleTap(for: tool)
            }
        )
        .overlay(alignment: .topLeading) {
            if case .activeHidden = slotState {
                hiddenOverlay
            }
        }
    }

    /// 2pt accent stroke around the slot tile when the skeleton for the
    /// current variant exists but is hidden. Sized + positioned to match
    /// `GroupedToolButton`'s 44×44 / 8pt-radius tile (see slotTile in
    /// `GroupedToolButton.swift`).
    private var hiddenOverlay: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(Color.accentColor, lineWidth: 2)
            .frame(width: 44, height: 44)
            .opacity(0.85)
            .allowsHitTesting(false)
    }

    private func handleTap(for tool: DrawingTool) {
        guard let outcome = poseManager.handleSlotTap(forTool: tool) else { return }
        if case .requestDetection(let kind) = outcome {
            onRequestDetection(kind)
        }
    }
}

// MARK: - iPhone

struct PoseReferenceTile: View {
    let tool: DrawingTool
    @ObservedObject var poseManager: PoseOverlayManager
    let onRequestDetection: (PoseSkeletonKind) -> Void
    /// Called after a tap regardless of outcome, so the iPhone tool panel
    /// can collapse the same way the rest of its tiles do.
    let onTapCompleted: () -> Void

    private var kind: PoseSkeletonKind? { PoseSkeletonKind(tool: tool) }

    private var slotState: PoseOverlayManager.SlotState {
        kind.map { poseManager.state(for: $0) } ?? .none
    }

    private var isVisible: Bool { slotState.isVisible }
    private var isHidden: Bool {
        if case .activeHidden = slotState { return true }
        return false
    }

    var body: some View {
        Button(action: tap) {
            Image(systemName: tool.icon)
                .font(.system(size: 22))
                .foregroundColor(isVisible ? .white : .primary)
                .frame(width: 44, height: 44)
                .background(isVisible ? Color.accentColor : Color.clear)
                .cornerRadius(8)
                .overlay(alignment: .topLeading) {
                    if isHidden {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .frame(width: 44, height: 44)
                            .opacity(0.85)
                            .allowsHitTesting(false)
                    }
                }
        }
        .accessibilityLabel(tool.name)
    }

    private func tap() {
        guard let outcome = poseManager.handleSlotTap(forTool: tool) else {
            onTapCompleted()
            return
        }
        if case .requestDetection(let kind) = outcome {
            onRequestDetection(kind)
        }
        onTapCompleted()
    }
}
