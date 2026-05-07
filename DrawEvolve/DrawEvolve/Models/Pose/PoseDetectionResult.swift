//
//  PoseDetectionResult.swift
//  DrawEvolve
//
//  Output type returned by VisionPoseService. Carries detected skeletons plus
//  per-pose advisories the detection sheet surfaces to the user.
//

import Foundation

/// Per-skeleton advisory — surfaces in PoseLowConfidenceBanner / detection sheet.
struct PoseAdvisory: Hashable {
    /// Identifies the skeleton this advisory applies to.
    let skeletonID: UUID

    enum Kind: Hashable {
        /// One or more joints below `PoseConfidence.lowThreshold`. Ask the user to drag them.
        case lowConfidenceJoints(count: Int)
        /// One or more joints were not returned by Vision at all (full occlusion).
        /// The skeleton was filled with default-pose positions for the missing joints.
        case missingJoints(count: Int)
    }

    let kind: Kind
}

/// Full result of a single pose-detection invocation.
///
/// A successful run can still carry advisories (low-confidence/missing joints).
/// `skeletons` may be empty — that case is handled by the detection sheet's
/// inline "no pose detected" UX, not by throwing.
struct PoseDetectionResult: Hashable {
    let skeletons: [PoseSkeleton]
    let advisories: [PoseAdvisory]

    static let empty = PoseDetectionResult(skeletons: [], advisories: [])

    var isEmpty: Bool { skeletons.isEmpty }
}
