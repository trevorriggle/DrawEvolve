//
//  PoseSkeleton.swift
//  DrawEvolve
//
//  Session-only data model for hand and body pose reference overlays.
//  Coordinates live in canvas-document space (top-left origin, pixel units).
//

import CoreGraphics
import Foundation

// MARK: - Joint identifiers

/// 21 hand keypoints returned by VNDetectHumanHandPoseRequest.
/// Naming matches `VNHumanHandPoseObservation.JointName` (iOS 14+, stable through iOS 17).
enum HandJoint: String, CaseIterable, Hashable, Codable {
    case wrist

    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

/// 19 body keypoints returned by VNDetectHumanBodyPoseRequest.
/// All cases are present on iOS 14+ and verified on the iOS 17 deployment target.
enum BodyJoint: String, CaseIterable, Hashable, Codable {
    case nose
    case leftEye, rightEye
    case leftEar, rightEar
    case neck
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case root
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle
}

// MARK: - Joint sample

/// A single joint sample inside a pose skeleton.
///
/// `position` is in canvas-document space (top-left origin, pixel units), already
/// converted from Vision's bottom-left-normalized output and from the resampled
/// detection rect into the active canvas's coordinate frame.
///
/// `confidence` is Vision's raw confidence in [0, 1]. Joints below
/// `PoseConfidence.lowThreshold` are surfaced to the user for manual correction.
///
/// `isManuallyMoved` flips to `true` once the user drags the joint, so the UI
/// stops flagging it as low-confidence and `commit-to-trace` confirmation
/// can show how much of the skeleton has been hand-tuned.
struct PoseJointPoint<JointID: Hashable & Codable>: Hashable, Codable {
    let id: JointID
    var position: CGPoint
    var confidence: Float
    var isManuallyMoved: Bool

    init(id: JointID, position: CGPoint, confidence: Float, isManuallyMoved: Bool = false) {
        self.id = id
        self.position = position
        self.confidence = confidence
        self.isManuallyMoved = isManuallyMoved
    }
}

// MARK: - Hand pose

/// Vision returns left/right/unknown via `VNHumanHandPoseObservation.chirality`.
enum HandChirality: String, Hashable, Codable {
    case left, right, unknown
}

struct HandPose: Identifiable, Hashable {
    let id: UUID
    var chirality: HandChirality
    /// Keyed by joint name for O(1) lookup during rendering and editing.
    /// A joint may legitimately be missing (occluded; Vision returned no point).
    var joints: [HandJoint: PoseJointPoint<HandJoint>]

    init(id: UUID = UUID(), chirality: HandChirality = .unknown, joints: [HandJoint: PoseJointPoint<HandJoint>]) {
        self.id = id
        self.chirality = chirality
        self.joints = joints
    }
}

// MARK: - Body pose

struct BodyPose: Identifiable, Hashable {
    let id: UUID
    var joints: [BodyJoint: PoseJointPoint<BodyJoint>]

    init(id: UUID = UUID(), joints: [BodyJoint: PoseJointPoint<BodyJoint>]) {
        self.id = id
        self.joints = joints
    }
}

// MARK: - Skeleton enum

/// Discriminated union over the two pose kinds.
/// Enum (not a `kind` discriminator on a single struct) keeps `switch`
/// exhaustivity on joint counts (21 vs 19) and topology lookups type-safe.
enum PoseSkeleton: Identifiable, Hashable {
    case hand(HandPose)
    case body(BodyPose)

    var id: UUID {
        switch self {
        case .hand(let pose): return pose.id
        case .body(let pose): return pose.id
        }
    }

    var displayName: String {
        switch self {
        case .hand: return "Hand Pose"
        case .body: return "Body Pose"
        }
    }
}

// MARK: - Confidence policy

enum PoseConfidence {
    /// Joints below this threshold are flagged as low-confidence in the UI
    /// (yellow pulsing dot, surfaced in the low-confidence banner).
    /// Apple does not publish a hard cutoff; 0.3 is the audit-recommended default
    /// and is tuned against real photos in PR 2.
    static let lowThreshold: Float = 0.3
}
