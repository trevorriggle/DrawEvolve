//
//  PoseOverlayManager.swift
//  DrawEvolve
//
//  State owner for the pose-reference feature. Reads from CanvasStateManager
//  for canvas geometry; never writes to it (one exception: PR 5's
//  commit-to-trace will write to the active layer's MTLTexture, but that's
//  out of scope here).
//
//  Each pose tool (handPose / bodyPose) maintains its own independent state
//  so the user can reference a body and a hand simultaneously.
//

import Foundation
import SwiftUI

@MainActor
final class PoseOverlayManager: ObservableObject {

    /// Per-tool state. `.none` means "no skeleton placed for this tool".
    /// `activeVisible` and `activeHidden` carry the placed skeleton; the
    /// distinction drives the toolbar slot's tri-state visual and the
    /// tap-cycle described in Decision 7.
    enum SlotState: Equatable {
        case none
        case activeVisible(PoseSkeleton)
        case activeHidden(PoseSkeleton)

        var skeleton: PoseSkeleton? {
            switch self {
            case .none: return nil
            case .activeVisible(let s), .activeHidden(let s): return s
            }
        }

        var isActive: Bool {
            if case .none = self { return false }
            return true
        }

        var isVisible: Bool {
            if case .activeVisible = self { return true }
            return false
        }
    }

    /// What the slot wrapper / iPhone tile asks the manager to do next.
    enum TapOutcome: Equatable {
        case requestDetection(PoseSkeletonKind)
        case visibilityToggled
    }

    @Published private(set) var handState: SlotState = .none
    @Published private(set) var bodyState: SlotState = .none

    /// Joints the user has manually moved since detection. Keys are
    /// `"<skeletonID>:<jointRawValue>"`. Used by the dismiss-confirmation
    /// gate on the ghost row's X icon — if any entry exists for the
    /// dismissed skeleton, prompt for confirmation.
    @Published private(set) var manuallyEditedJointKeys: Set<String> = []

    init() {}

    // MARK: - Reads

    func state(for kind: PoseSkeletonKind) -> SlotState {
        switch kind {
        case .hand: return handState
        case .body: return bodyState
        }
    }

    func state(forTool tool: DrawingTool) -> SlotState {
        guard let kind = PoseSkeletonKind(tool: tool) else { return .none }
        return state(for: kind)
    }

    /// Skeletons currently active and visible, in render order (body first
    /// so it sits behind the hand on overlap).
    var renderableSkeletons: [PoseSkeleton] {
        var out: [PoseSkeleton] = []
        if case .activeVisible(let s) = bodyState { out.append(s) }
        if case .activeVisible(let s) = handState { out.append(s) }
        return out
    }

    /// Active skeletons, regardless of visibility — used by the Layer
    /// Panel ghost row, which lists hidden skeletons too.
    var activeSkeletons: [(kind: PoseSkeletonKind, state: SlotState)] {
        var out: [(PoseSkeletonKind, SlotState)] = []
        if bodyState.isActive { out.append((.body, bodyState)) }
        if handState.isActive { out.append((.hand, handState)) }
        return out
    }

    var anyActive: Bool {
        handState.isActive || bodyState.isActive
    }

    func hasManualEdits(for kind: PoseSkeletonKind) -> Bool {
        guard let id = state(for: kind).skeleton?.id else { return false }
        let prefix = "\(id.uuidString):"
        return manuallyEditedJointKeys.contains(where: { $0.hasPrefix(prefix) })
    }

    // MARK: - Mutations

    /// Place a freshly-detected skeleton. Replaces any existing skeleton
    /// of the same kind (audit §4.4 "Replace Photo" path).
    func place(_ skeleton: PoseSkeleton) {
        clearManualEdits(for: PoseSkeletonKind(skeleton: skeleton))
        switch skeleton {
        case .hand: handState = .activeVisible(skeleton)
        case .body: bodyState = .activeVisible(skeleton)
        }
    }

    func setVisible(_ visible: Bool, for kind: PoseSkeletonKind) {
        switch kind {
        case .hand:
            handState = updateVisibility(handState, visible: visible)
        case .body:
            bodyState = updateVisibility(bodyState, visible: visible)
        }
    }

    private func updateVisibility(_ state: SlotState, visible: Bool) -> SlotState {
        switch state {
        case .none: return .none
        case .activeVisible(let s), .activeHidden(let s):
            return visible ? .activeVisible(s) : .activeHidden(s)
        }
    }

    func discard(_ kind: PoseSkeletonKind) {
        clearManualEdits(for: kind)
        switch kind {
        case .hand: handState = .none
        case .body: bodyState = .none
        }
    }

    func discardAll() {
        manuallyEditedJointKeys.removeAll()
        handState = .none
        bodyState = .none
    }

    private func clearManualEdits(for kind: PoseSkeletonKind) {
        guard let id = state(for: kind).skeleton?.id else { return }
        let prefix = "\(id.uuidString):"
        manuallyEditedJointKeys = manuallyEditedJointKeys.filter { !$0.hasPrefix(prefix) }
    }

    // MARK: - Tap cycle (Decision 7)

    /// Resolve a slot tap into a high-level outcome. The toolbar wrapper
    /// translates `requestDetection` into a sheet trigger; visibility
    /// toggles are applied here.
    @discardableResult
    func handleSlotTap(forTool tool: DrawingTool) -> TapOutcome? {
        guard let kind = PoseSkeletonKind(tool: tool) else { return nil }
        switch state(for: kind) {
        case .none:
            return .requestDetection(kind)
        case .activeVisible:
            setVisible(false, for: kind)
            return .visibilityToggled
        case .activeHidden:
            setVisible(true, for: kind)
            return .visibilityToggled
        }
    }
}

// MARK: - PoseSkeletonKind

/// Bridges between `DrawingTool` (toolbar) and `PoseSkeleton` (model).
/// Lives here, not in the model layer, because the bridge only exists
/// for the manager; PoseSkeleton itself is intentionally tool-agnostic.
enum PoseSkeletonKind: Hashable, Identifiable {
    case hand
    case body

    var id: Self { self }

    init?(tool: DrawingTool) {
        switch tool {
        case .handPose: self = .hand
        case .bodyPose: self = .body
        default: return nil
        }
    }

    init(skeleton: PoseSkeleton) {
        switch skeleton {
        case .hand: self = .hand
        case .body: self = .body
        }
    }

    var tool: DrawingTool {
        switch self {
        case .hand: return .handPose
        case .body: return .bodyPose
        }
    }

    var displayLabel: String {
        switch self {
        case .hand: return "Reference: Hand Pose"
        case .body: return "Reference: Body Pose"
        }
    }

    var icon: String { tool.icon }
}
