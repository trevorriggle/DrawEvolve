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

// MARK: - Default-pose factories (PR 6 manually-place fallback)

extension HandPose {
    /// Build a default open-palm hand skeleton fitted into `rect`. Joints
    /// are positioned in normalized [0,1] space and then scaled into the
    /// target rect. Confidence is 1.0 (not low-confidence) because these
    /// positions are user-authored, not detector-output. `isManuallyMoved`
    /// stays false — the user hasn't dragged anything yet.
    static func defaultPose(in rect: CGRect) -> HandPose {
        let positions: [HandJoint: CGPoint] = [
            .wrist:      CGPoint(x: 0.50, y: 0.95),

            .thumbCMC:   CGPoint(x: 0.30, y: 0.85),
            .thumbMP:    CGPoint(x: 0.20, y: 0.70),
            .thumbIP:    CGPoint(x: 0.13, y: 0.55),
            .thumbTip:   CGPoint(x: 0.08, y: 0.42),

            .indexMCP:   CGPoint(x: 0.36, y: 0.65),
            .indexPIP:   CGPoint(x: 0.34, y: 0.45),
            .indexDIP:   CGPoint(x: 0.33, y: 0.28),
            .indexTip:   CGPoint(x: 0.32, y: 0.10),

            .middleMCP:  CGPoint(x: 0.50, y: 0.62),
            .middlePIP:  CGPoint(x: 0.50, y: 0.40),
            .middleDIP:  CGPoint(x: 0.50, y: 0.22),
            .middleTip:  CGPoint(x: 0.50, y: 0.05),

            .ringMCP:    CGPoint(x: 0.64, y: 0.65),
            .ringPIP:    CGPoint(x: 0.66, y: 0.45),
            .ringDIP:    CGPoint(x: 0.67, y: 0.28),
            .ringTip:    CGPoint(x: 0.68, y: 0.10),

            .littleMCP:  CGPoint(x: 0.76, y: 0.72),
            .littlePIP:  CGPoint(x: 0.80, y: 0.55),
            .littleDIP:  CGPoint(x: 0.83, y: 0.40),
            .littleTip:  CGPoint(x: 0.86, y: 0.25),
        ]
        var joints: [HandJoint: PoseJointPoint<HandJoint>] = [:]
        for (id, p) in positions {
            let docPoint = CGPoint(
                x: rect.minX + p.x * rect.width,
                y: rect.minY + p.y * rect.height
            )
            joints[id] = PoseJointPoint(id: id, position: docPoint, confidence: 1.0)
        }
        return HandPose(chirality: .unknown, joints: joints)
    }
}

extension BodyPose {
    /// Build a default A-pose body skeleton fitted into `rect`. Same
    /// rules as `HandPose.defaultPose(in:)` — full confidence, not
    /// manually-moved.
    static func defaultPose(in rect: CGRect) -> BodyPose {
        let positions: [BodyJoint: CGPoint] = [
            .nose:          CGPoint(x: 0.50, y: 0.06),

            .leftEye:       CGPoint(x: 0.46, y: 0.05),
            .rightEye:      CGPoint(x: 0.54, y: 0.05),
            .leftEar:       CGPoint(x: 0.43, y: 0.06),
            .rightEar:      CGPoint(x: 0.57, y: 0.06),

            .neck:          CGPoint(x: 0.50, y: 0.14),

            .leftShoulder:  CGPoint(x: 0.38, y: 0.18),
            .rightShoulder: CGPoint(x: 0.62, y: 0.18),

            .leftElbow:     CGPoint(x: 0.28, y: 0.32),
            .rightElbow:    CGPoint(x: 0.72, y: 0.32),

            .leftWrist:     CGPoint(x: 0.20, y: 0.46),
            .rightWrist:    CGPoint(x: 0.80, y: 0.46),

            .root:          CGPoint(x: 0.50, y: 0.50),

            .leftHip:       CGPoint(x: 0.43, y: 0.52),
            .rightHip:      CGPoint(x: 0.57, y: 0.52),

            .leftKnee:      CGPoint(x: 0.42, y: 0.74),
            .rightKnee:     CGPoint(x: 0.58, y: 0.74),

            .leftAnkle:     CGPoint(x: 0.41, y: 0.96),
            .rightAnkle:    CGPoint(x: 0.59, y: 0.96),
        ]
        var joints: [BodyJoint: PoseJointPoint<BodyJoint>] = [:]
        for (id, p) in positions {
            let docPoint = CGPoint(
                x: rect.minX + p.x * rect.width,
                y: rect.minY + p.y * rect.height
            )
            joints[id] = PoseJointPoint(id: id, position: docPoint, confidence: 1.0)
        }
        return BodyPose(joints: joints)
    }
}

// MARK: - Skeleton helpers (PR 6)

extension PoseSkeleton {
    /// Number of joints whose detection confidence is below the
    /// low-confidence threshold AND haven't been manually moved yet.
    /// Drives the low-confidence banner's count text.
    var lowConfidenceUnmovedCount: Int {
        switch self {
        case .hand(let pose):
            return pose.joints.values
                .filter { !$0.isManuallyMoved && $0.confidence < PoseConfidence.lowThreshold }
                .count
        case .body(let pose):
            return pose.joints.values
                .filter { !$0.isManuallyMoved && $0.confidence < PoseConfidence.lowThreshold }
                .count
        }
    }
}
