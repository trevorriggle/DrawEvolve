//
//  VisionPoseService.swift
//  DrawEvolve
//
//  Hand-pose and body-pose detection on top of `VisionService`.
//
//  Coordinate space contract:
//  • Vision returns normalized [0, 1] points with origin at the bottom-left
//    of the upright (orientation-corrected) image.
//  • The detection sheet asks this service to map results into a *target rect*
//    expressed in canvas-document space (top-left origin, pixel units).
//    That rect is the letterboxed-fit of the source photo onto the canvas.
//  • This service does the y-flip + rect transform so callers receive
//    skeletons whose joints are ready to render directly in canvas-doc space.
//

import CoreGraphics
import UIKit
import Vision

@MainActor
final class VisionPoseService {
    static let shared = VisionPoseService()

    private let service: VisionService
    init(service: VisionService = .shared) {
        self.service = service
    }

    /// Detect hands and (optionally) a body in `image`, returning skeletons in
    /// canvas-document space.
    ///
    /// `targetRect` is the rectangle inside canvas-document space that the
    /// source photo should be considered to occupy (typically a letterboxed
    /// fit at ~50% of the canvas). Joints are positioned within that rect.
    func detect(
        in image: UIImage,
        mappingTo targetRect: CGRect,
        detectHands: Bool = true,
        detectBody: Bool = true
    ) async throws -> PoseDetectionResult {
        guard detectHands || detectBody else { return .empty }
        guard let visionImage = VisionImage.make(from: image) else {
            throw VisionServiceError.imageEncodingFailed
        }

        var requests: [VNRequest] = []
        let handRequest: VNDetectHumanHandPoseRequest? = detectHands ? {
            let r = VNDetectHumanHandPoseRequest()
            r.maximumHandCount = 2
            return r
        }() : nil
        let bodyRequest: VNDetectHumanBodyPoseRequest? = detectBody
            ? VNDetectHumanBodyPoseRequest()
            : nil
        if let handRequest { requests.append(handRequest) }
        if let bodyRequest { requests.append(bodyRequest) }

        _ = try await service.perform(requests, on: visionImage)

        var skeletons: [PoseSkeleton] = []
        var advisories: [PoseAdvisory] = []

        if let observations = handRequest?.results {
            for obs in observations.prefix(2) {
                if let (pose, advisory) = makeHandPose(from: obs, in: targetRect) {
                    skeletons.append(.hand(pose))
                    if let advisory { advisories.append(advisory) }
                }
            }
        }

        if let observations = bodyRequest?.results, let firstBody = observations.first {
            if let (pose, advisory) = makeBodyPose(from: firstBody, in: targetRect) {
                skeletons.append(.body(pose))
                if let advisory { advisories.append(advisory) }
            }
        }

        return PoseDetectionResult(skeletons: skeletons, advisories: advisories)
    }

    // MARK: - Hand mapping

    private func makeHandPose(
        from observation: VNHumanHandPoseObservation,
        in rect: CGRect
    ) -> (HandPose, PoseAdvisory?)? {
        let points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]
        do {
            points = try observation.recognizedPoints(.all)
        } catch {
            return nil
        }

        var joints: [HandJoint: PoseJointPoint<HandJoint>] = [:]
        var lowConfidenceCount = 0
        var missingCount = 0

        for handJoint in HandJoint.allCases {
            guard let visionName = visionHandJointName(for: handJoint) else { continue }
            if let point = points[visionName], point.confidence > 0 {
                let docPoint = mapToDocSpace(point.location, in: rect)
                joints[handJoint] = PoseJointPoint(
                    id: handJoint,
                    position: docPoint,
                    confidence: point.confidence
                )
                if point.confidence < PoseConfidence.lowThreshold {
                    lowConfidenceCount += 1
                }
            } else {
                missingCount += 1
            }
        }

        guard !joints.isEmpty else { return nil }

        let chirality: HandChirality
        switch observation.chirality {
        case .left: chirality = .left
        case .right: chirality = .right
        case .unknown: chirality = .unknown
        @unknown default: chirality = .unknown
        }

        let pose = HandPose(chirality: chirality, joints: joints)
        let advisory = pickAdvisory(
            skeletonID: pose.id,
            lowConfidence: lowConfidenceCount,
            missing: missingCount
        )
        return (pose, advisory)
    }

    // MARK: - Body mapping

    private func makeBodyPose(
        from observation: VNHumanBodyPoseObservation,
        in rect: CGRect
    ) -> (BodyPose, PoseAdvisory?)? {
        let points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]
        do {
            points = try observation.recognizedPoints(.all)
        } catch {
            return nil
        }

        var joints: [BodyJoint: PoseJointPoint<BodyJoint>] = [:]
        var lowConfidenceCount = 0
        var missingCount = 0

        for bodyJoint in BodyJoint.allCases {
            guard let visionName = visionBodyJointName(for: bodyJoint) else { continue }
            if let point = points[visionName], point.confidence > 0 {
                let docPoint = mapToDocSpace(point.location, in: rect)
                joints[bodyJoint] = PoseJointPoint(
                    id: bodyJoint,
                    position: docPoint,
                    confidence: point.confidence
                )
                if point.confidence < PoseConfidence.lowThreshold {
                    lowConfidenceCount += 1
                }
            } else {
                missingCount += 1
            }
        }

        guard !joints.isEmpty else { return nil }

        let pose = BodyPose(joints: joints)
        let advisory = pickAdvisory(
            skeletonID: pose.id,
            lowConfidence: lowConfidenceCount,
            missing: missingCount
        )
        return (pose, advisory)
    }

    // MARK: - Coordinate space conversion

    /// Vision: bottom-left origin, normalized [0, 1].
    /// Canvas-doc: top-left origin, pixel units. Y flips, x/y scale into
    /// the letterboxed target rect.
    private func mapToDocSpace(_ visionPoint: CGPoint, in rect: CGRect) -> CGPoint {
        let x = rect.minX + visionPoint.x * rect.width
        let y = rect.maxY - visionPoint.y * rect.height
        return CGPoint(x: x, y: y)
    }

    private func pickAdvisory(skeletonID: UUID, lowConfidence: Int, missing: Int) -> PoseAdvisory? {
        if missing > 0 {
            return PoseAdvisory(skeletonID: skeletonID, kind: .missingJoints(count: missing))
        }
        if lowConfidence > 0 {
            return PoseAdvisory(skeletonID: skeletonID, kind: .lowConfidenceJoints(count: lowConfidence))
        }
        return nil
    }
}

// MARK: - Joint name bridges

/// Map our `HandJoint` to Vision's `JointName`. Single source of truth so the
/// rest of the app never imports `Vision`.
private func visionHandJointName(for joint: HandJoint) -> VNHumanHandPoseObservation.JointName? {
    switch joint {
    case .wrist: return .wrist
    case .thumbCMC: return .thumbCMC
    case .thumbMP: return .thumbMP
    case .thumbIP: return .thumbIP
    case .thumbTip: return .thumbTip
    case .indexMCP: return .indexMCP
    case .indexPIP: return .indexPIP
    case .indexDIP: return .indexDIP
    case .indexTip: return .indexTip
    case .middleMCP: return .middleMCP
    case .middlePIP: return .middlePIP
    case .middleDIP: return .middleDIP
    case .middleTip: return .middleTip
    case .ringMCP: return .ringMCP
    case .ringPIP: return .ringPIP
    case .ringDIP: return .ringDIP
    case .ringTip: return .ringTip
    case .littleMCP: return .littleMCP
    case .littlePIP: return .littlePIP
    case .littleDIP: return .littleDIP
    case .littleTip: return .littleTip
    }
}

private func visionBodyJointName(for joint: BodyJoint) -> VNHumanBodyPoseObservation.JointName? {
    switch joint {
    case .nose: return .nose
    case .leftEye: return .leftEye
    case .rightEye: return .rightEye
    case .leftEar: return .leftEar
    case .rightEar: return .rightEar
    case .neck: return .neck
    case .leftShoulder: return .leftShoulder
    case .rightShoulder: return .rightShoulder
    case .leftElbow: return .leftElbow
    case .rightElbow: return .rightElbow
    case .leftWrist: return .leftWrist
    case .rightWrist: return .rightWrist
    case .root: return .root
    case .leftHip: return .leftHip
    case .rightHip: return .rightHip
    case .leftKnee: return .leftKnee
    case .rightKnee: return .rightKnee
    case .leftAnkle: return .leftAnkle
    case .rightAnkle: return .rightAnkle
    }
}
