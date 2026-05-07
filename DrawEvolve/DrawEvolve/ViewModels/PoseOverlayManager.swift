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

    /// IDs of skeletons whose transform-handle bbox is currently armed —
    /// PoseTransformHandlesView reads this to decide whether to render
    /// handles + the dashed outline. A skeleton enters the set when it
    /// is freshly placed or any of its joints / handles is touched, and
    /// leaves the set after `bboxActiveTimeout` seconds of inactivity
    /// (audit §6.3).
    @Published private(set) var activeBboxSkeletons: Set<UUID> = []

    /// Auto-deselect timeout for the bbox handles. Audit §10 Risk 2's
    /// mitigation: gestures inside the bbox interior should fall through
    /// to the canvas after this timeout so the user can paint without
    /// having to manually hide the skeleton first.
    static let bboxActiveTimeout: Duration = .seconds(4)

    /// Pending deactivation timers per skeleton id. Restarted on every
    /// `activate(_:)` call.
    private var deactivationTasks: [UUID: Task<Void, Never>] = [:]

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
    /// of the same kind (audit §4.4 "Replace Photo" path). Also arms the
    /// bbox handles so the user can immediately scale / rotate the
    /// fresh skeleton without having to tap to wake.
    func place(_ skeleton: PoseSkeleton) {
        clearManualEdits(for: PoseSkeletonKind(skeleton: skeleton))
        switch skeleton {
        case .hand: handState = .activeVisible(skeleton)
        case .body: bodyState = .activeVisible(skeleton)
        }
        activate(skeletonID: skeleton.id)
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
        if let id = state(for: kind).skeleton?.id {
            cancelDeactivation(for: id)
            activeBboxSkeletons.remove(id)
        }
        clearManualEdits(for: kind)
        switch kind {
        case .hand: handState = .none
        case .body: bodyState = .none
        }
    }

    func discardAll() {
        for task in deactivationTasks.values { task.cancel() }
        deactivationTasks.removeAll()
        activeBboxSkeletons.removeAll()
        manuallyEditedJointKeys.removeAll()
        handState = .none
        bodyState = .none
    }

    private func clearManualEdits(for kind: PoseSkeletonKind) {
        guard let id = state(for: kind).skeleton?.id else { return }
        let prefix = "\(id.uuidString):"
        manuallyEditedJointKeys = manuallyEditedJointKeys.filter { !$0.hasPrefix(prefix) }
    }

    // MARK: - Joint mutation (PR 3)

    /// Reposition a single hand joint and mark it as manually moved.
    /// `position` is in canvas-document space. No-op if the active hand
    /// skeleton's id doesn't match — guards against stale gesture
    /// callbacks that arrive after the user has discarded / replaced
    /// the skeleton.
    func updateHandJoint(skeletonID: UUID, joint: HandJoint, to position: CGPoint) {
        guard case .activeVisible(let skeleton) = handState,
              case .hand(var pose) = skeleton,
              pose.id == skeletonID else { return }
        guard var sample = pose.joints[joint] else { return }
        sample.position = position
        sample.isManuallyMoved = true
        pose.joints[joint] = sample
        handState = .activeVisible(.hand(pose))
        manuallyEditedJointKeys.insert("\(skeletonID.uuidString):\(joint.rawValue)")
    }

    /// Reposition a single body joint and mark it as manually moved.
    /// Same staleness gate as `updateHandJoint`.
    func updateBodyJoint(skeletonID: UUID, joint: BodyJoint, to position: CGPoint) {
        guard case .activeVisible(let skeleton) = bodyState,
              case .body(var pose) = skeleton,
              pose.id == skeletonID else { return }
        guard var sample = pose.joints[joint] else { return }
        sample.position = position
        sample.isManuallyMoved = true
        pose.joints[joint] = sample
        bodyState = .activeVisible(.body(pose))
        manuallyEditedJointKeys.insert("\(skeletonID.uuidString):\(joint.rawValue)")
    }

    // MARK: - Whole-skeleton transform (PR 4)

    /// Bulk-set every joint of the active hand skeleton. Used by
    /// PoseTransformHandlesView for translate / scale / rotate, where
    /// the caller has already computed each joint's target position
    /// from a captured snapshot. Does NOT flip `isManuallyMoved` —
    /// transforms aren't "manual edits" in the audit-§4.5 sense
    /// (commit-to-trace's confirmation looks at per-joint manual moves,
    /// not whole-skeleton transforms).
    func setHandJointPositions(skeletonID: UUID, positions: [HandJoint: CGPoint]) {
        guard case .activeVisible(let skeleton) = handState,
              case .hand(var pose) = skeleton,
              pose.id == skeletonID else { return }
        for (joint, position) in positions {
            guard var sample = pose.joints[joint] else { continue }
            sample.position = position
            pose.joints[joint] = sample
        }
        handState = .activeVisible(.hand(pose))
    }

    func setBodyJointPositions(skeletonID: UUID, positions: [BodyJoint: CGPoint]) {
        guard case .activeVisible(let skeleton) = bodyState,
              case .body(var pose) = skeleton,
              pose.id == skeletonID else { return }
        for (joint, position) in positions {
            guard var sample = pose.joints[joint] else { continue }
            sample.position = position
            pose.joints[joint] = sample
        }
        bodyState = .activeVisible(.body(pose))
    }

    // MARK: - Commit to trace (PR 5)

    /// Bake the active skeleton of the given kind into the active layer's
    /// texture via `CanvasStateManager.commitPoseToTrace`. On success,
    /// discards the skeleton — overlay clears, ghost row goes away — so
    /// the user can immediately start tracing without dismissing extra
    /// UI. On failure (no layer / layer locked / no skeleton), the
    /// skeleton is left in place.
    @discardableResult
    func commitToTrace(
        kind: PoseSkeletonKind,
        opacity: CGFloat,
        canvasState: CanvasStateManager
    ) -> Bool {
        guard case .activeVisible(let skeleton) = state(for: kind) else { return false }
        let committed = canvasState.commitPoseToTrace(skeleton: skeleton, opacity: opacity)
        guard committed else { return false }
        discard(kind)
        return true
    }

    // MARK: - Bbox active state (PR 4)

    /// Mark a skeleton's transform bbox as active and (re)start the 4-second
    /// auto-deselect timer. Called on detection-place, on joint-drag tick,
    /// on transform-handle drag tick, and on bbox-pan tick. Idempotent —
    /// repeated activation calls just refresh the timer.
    func activate(skeletonID: UUID) {
        activeBboxSkeletons.insert(skeletonID)
        cancelDeactivation(for: skeletonID)
        let task = Task { [weak self] in
            try? await Task.sleep(for: Self.bboxActiveTimeout)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.activeBboxSkeletons.remove(skeletonID)
                self.deactivationTasks[skeletonID] = nil
            }
        }
        deactivationTasks[skeletonID] = task
    }

    /// Cancel any pending auto-deactivate for a skeleton id without
    /// changing its `activeBboxSkeletons` membership. Call before
    /// removing the skeleton to avoid a stale callback firing later.
    private func cancelDeactivation(for skeletonID: UUID) {
        deactivationTasks[skeletonID]?.cancel()
        deactivationTasks[skeletonID] = nil
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
