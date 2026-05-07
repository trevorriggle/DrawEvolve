//
//  PoseTopology.swift
//  DrawEvolve
//
//  Static bone-connection tables for hand and body skeletons.
//  Pure data — no logic, no I/O, no Vision imports.
//

import Foundation

// MARK: - Hand topology

/// 20 hand bones — 4 per finger × 5 fingers, anchored at the wrist.
/// Order is wrist→tip per finger so live preview can stroke a continuous path.
enum HandTopology {
    /// Ordered finger chains, each starting at the wrist.
    /// Useful for rendering each finger as a single connected path.
    static let fingerChains: [[HandJoint]] = [
        [.wrist, .thumbCMC,  .thumbMP,   .thumbIP,   .thumbTip],
        [.wrist, .indexMCP,  .indexPIP,  .indexDIP,  .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP,   .ringPIP,   .ringDIP,   .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip],
    ]

    /// Flat list of (start, end) bone pairs derived from the finger chains.
    /// 20 bones total.
    static let connections: [(HandJoint, HandJoint)] = {
        var pairs: [(HandJoint, HandJoint)] = []
        for chain in fingerChains {
            for i in 0..<(chain.count - 1) {
                pairs.append((chain[i], chain[i + 1]))
            }
        }
        return pairs
    }()
}

// MARK: - Body topology

/// 18 body bones built from the 19 keypoints. Face connections (nose–eye–ear)
/// are decorative and rendered at lower opacity by the overlay.
enum BodyTopology {
    /// Primary skeleton bones — torso and limbs.
    static let primaryConnections: [(BodyJoint, BodyJoint)] = [
        // Spine + head
        (.nose, .neck),
        (.neck, .root),

        // Left arm
        (.neck, .leftShoulder),
        (.leftShoulder, .leftElbow),
        (.leftElbow, .leftWrist),

        // Right arm
        (.neck, .rightShoulder),
        (.rightShoulder, .rightElbow),
        (.rightElbow, .rightWrist),

        // Left leg
        (.root, .leftHip),
        (.leftHip, .leftKnee),
        (.leftKnee, .leftAnkle),

        // Right leg
        (.root, .rightHip),
        (.rightHip, .rightKnee),
        (.rightKnee, .rightAnkle),
    ]

    /// Optional face decoration. Rendered at reduced opacity in PR 6.
    static let faceConnections: [(BodyJoint, BodyJoint)] = [
        (.nose, .leftEye),
        (.leftEye, .leftEar),
        (.nose, .rightEye),
        (.rightEye, .rightEar),
    ]

    /// All bones (14 primary + 4 face = 18).
    static let connections: [(BodyJoint, BodyJoint)] = primaryConnections + faceConnections
}
