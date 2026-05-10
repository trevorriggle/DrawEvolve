//
//  PoseTransformHandlesView.swift
//  DrawEvolve
//
//  Whole-skeleton transform UI for active pose references. Renders a
//  dashed bbox outline + corner / edge / rotation handles when the
//  skeleton's bbox is "armed" (`PoseOverlayManager.activeBboxSkeletons`),
//  plus a transparent bbox-pan area for single-finger translate and a
//  combined two-finger pinch + rotate gesture.
//
//  Mirrors the structure of `TransformHandlesOverlay`
//  (SelectionOverlays.swift:149) but with two simplifications:
//
//   1. The pose bbox is ALWAYS axis-aligned in canvas-doc space — pose
//      joints are independent points, not a rotated rectangle. After a
//      rotation, the bbox simply recomputes to the new axis-aligned
//      extent of the rotated joints. No anchor-pinning math.
//   2. There is no per-skeleton stored offset / scale / rotation. The
//      handles read joint positions and write joint positions; the
//      transform exists only as a delta applied during a single drag
//      session, never persisted as a separate transform field.
//
//  Available on iPad and iPhone (Decision 10): the per-joint editing
//  surface from PR 3 is iPad-only, but whole-skeleton transform works
//  on both. iPhone users typically scale + rotate + translate without
//  ever per-joint editing.
//

import SwiftUI

struct PoseTransformHandlesView: View {
    @ObservedObject var poseManager: PoseOverlayManager
    @ObservedObject var canvasState: CanvasStateManager
    @State private var session: PoseTransformSession?

    var body: some View {
        ZStack {
            ForEach(activeSkeletons) { skeleton in
                content(for: skeleton)
            }
        }
    }

    /// Snapshot of skeletons whose transform bbox is currently armed.
    /// Reads `activeBboxSkeletons` (publishes from PoseOverlayManager).
    /// Locked skeletons drop out — when the user has flipped the chip's
    /// lock toggle, the skeleton is reference-only and the handles
    /// should not render at all (no visual clutter, no hit-testable
    /// surface near the canvas).
    private var activeSkeletons: [PoseSkeleton] {
        poseManager.renderableSkeletons.filter {
            poseManager.activeBboxSkeletons.contains($0.id)
                && !poseManager.isLocked(PoseSkeletonKind(skeleton: $0))
        }
    }

    @ViewBuilder
    private func content(for skeleton: PoseSkeleton) -> some View {
        let docPositions = jointDocPositions(in: skeleton)
        if let bboxDoc = paddedAxisAlignedBbox(of: docPositions) {
            handles(for: skeleton, bboxDoc: bboxDoc)
        }
    }

    @ViewBuilder
    private func handles(for skeleton: PoseSkeleton, bboxDoc: CGRect) -> some View {
        // Doc-space corners + edge midpoints, then projected through
        // canvas zoom / pan / rotation / flip via documentToScreen so
        // handles track the canvas exactly.
        let cornerDocs: [CGPoint] = [
            CGPoint(x: bboxDoc.minX, y: bboxDoc.minY),  // 0 TL
            CGPoint(x: bboxDoc.maxX, y: bboxDoc.minY),  // 1 TR
            CGPoint(x: bboxDoc.maxX, y: bboxDoc.maxY),  // 2 BR
            CGPoint(x: bboxDoc.minX, y: bboxDoc.maxY),  // 3 BL
        ]
        let edgeDocs: [CGPoint] = [
            CGPoint(x: bboxDoc.midX, y: bboxDoc.minY),  // 0 top
            CGPoint(x: bboxDoc.maxX, y: bboxDoc.midY),  // 1 right
            CGPoint(x: bboxDoc.midX, y: bboxDoc.maxY),  // 2 bottom
            CGPoint(x: bboxDoc.minX, y: bboxDoc.midY),  // 3 left
        ]
        let centerDoc = CGPoint(x: bboxDoc.midX, y: bboxDoc.midY)

        let cornerScreens = cornerDocs.map { canvasState.documentToScreen($0) }
        let edgeScreens = edgeDocs.map { canvasState.documentToScreen($0) }
        let centerScreen = canvasState.documentToScreen(centerDoc)
        let topCenterScreen = edgeScreens[0]

        // Rotation handle 30 screen-pt past the rotated top-center along
        // the outward normal of the rotated top edge. Computed in screen
        // space so the visual offset stays constant under canvas zoom.
        let outward = normalized(topCenterScreen - centerScreen)
        let rotationHandleScreen = topCenterScreen + outward * 30

        // Bbox-pan rect in screen coordinates. We use TL→BR span of
        // the corner-screens, which already reflects canvas rotation /
        // flip; if the canvas is rotated, this rect shears in screen
        // space and that's fine — our `.position(...)` + bbox-pan
        // gesture only need a finite hit area roughly covering the
        // skeleton interior.
        let bboxPanWidth = abs(cornerScreens[2].x - cornerScreens[0].x)
        let bboxPanHeight = abs(cornerScreens[2].y - cornerScreens[0].y)
        let bboxPanCenter = CGPoint(
            x: (cornerScreens[0].x + cornerScreens[2].x) / 2,
            y: (cornerScreens[0].y + cornerScreens[2].y) / 2
        )

        ZStack {
            // Bbox-pan area — sits BELOW the dashed outline + handles in
            // Z-order so a tap on a handle wins. Combines a single-finger
            // drag (translate) and a two-finger pinch+rotate via
            // simultaneousGesture so both gesture types arm together
            // without flag-based cooperation.
            //
            // Gesture priority position #1 (pinch/rotate, two-finger) and
            // #5 (bbox-pan, single-finger) per the chain documented on
            // PoseOverlayView.jointDrag. Joints + handles use
            // .highPriorityGesture so they win over this view when their
            // hit zones overlap.
            Rectangle()
                .fill(Color.clear)
                .frame(width: bboxPanWidth, height: bboxPanHeight)
                .contentShape(Rectangle())
                .position(bboxPanCenter)
                .gesture(translateDrag(skeletonID: skeleton.id))
                .simultaneousGesture(pinchRotateGesture(skeletonID: skeleton.id))

            // Dashed bounding-box outline + rotation stem.
            Path { p in
                p.move(to: cornerScreens[0])
                p.addLine(to: cornerScreens[1])
                p.addLine(to: cornerScreens[2])
                p.addLine(to: cornerScreens[3])
                p.closeSubpath()
                p.move(to: topCenterScreen)
                p.addLine(to: rotationHandleScreen)
            }
            .stroke(
                Color.accentColor.opacity(0.55),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
            .allowsHitTesting(false)

            // Corner handles — uniform scale.
            ForEach(0..<4, id: \.self) { i in
                handleDot(filled: true)
                    .position(cornerScreens[i])
                    .highPriorityGesture(scaleDrag(skeletonID: skeleton.id, anchor: cornerDocs[(i + 2) % 4], handle: .corner))
            }
            // Edge handles — single-axis scale.
            ForEach(0..<4, id: \.self) { i in
                handleDot(filled: false)
                    .position(edgeScreens[i])
                    .highPriorityGesture(
                        scaleDrag(
                            skeletonID: skeleton.id,
                            anchor: edgeDocs[(i + 2) % 4],
                            handle: .edge(axis: i % 2 == 0 ? .vertical : .horizontal)
                        )
                    )
            }
            // Rotation handle.
            handleDot(filled: true, stroke: Color.green)
                .position(rotationHandleScreen)
                .highPriorityGesture(rotationDrag(skeletonID: skeleton.id, centerDoc: centerDoc))
        }
    }

    private func handleDot(filled: Bool, stroke: Color = .accentColor) -> some View {
        // 16pt visual, 44pt hit target — same pattern as
        // SelectionOverlays.handleDot (lines 244–256).
        let visual = Circle()
            .fill(filled ? Color.white : Color.white.opacity(0.85))
            .frame(width: 16, height: 16)
            .overlay(Circle().stroke(stroke, lineWidth: 2))
        return ZStack {
            Color.clear
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            visual
        }
    }

    // MARK: - Gestures

    private func translateDrag(skeletonID: UUID) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if session == nil || session?.skeletonID != skeletonID {
                    session = makeSession(skeletonID: skeletonID, mode: .translate, fingerScreen: value.startLocation)
                }
                guard let s = session else { return }
                applyTranslate(session: s, fingerScreen: value.location)
                poseManager.activate(skeletonID: skeletonID)
            }
            .onEnded { _ in
                session = nil
            }
    }

    private func scaleDrag(skeletonID: UUID, anchor anchorDoc: CGPoint, handle: ScaleHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if session == nil || session?.skeletonID != skeletonID {
                    session = makeSession(
                        skeletonID: skeletonID,
                        mode: .scale(handle: handle, anchorDoc: anchorDoc),
                        fingerScreen: value.startLocation
                    )
                }
                guard let s = session else { return }
                applyScale(session: s, fingerScreen: value.location)
                poseManager.activate(skeletonID: skeletonID)
            }
            .onEnded { _ in
                session = nil
            }
    }

    private func rotationDrag(skeletonID: UUID, centerDoc: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if session == nil || session?.skeletonID != skeletonID {
                    session = makeSession(
                        skeletonID: skeletonID,
                        mode: .rotate(centerDoc: centerDoc),
                        fingerScreen: value.startLocation
                    )
                }
                guard let s = session else { return }
                applyRotation(session: s, fingerScreen: value.location)
                poseManager.activate(skeletonID: skeletonID)
            }
            .onEnded { _ in
                session = nil
            }
    }

    private func pinchRotateGesture(skeletonID: UUID) -> some Gesture {
        // Two-finger pinch + rotate combined via SimultaneousGesture so
        // SwiftUI's recognizer can resolve them together. Both update
        // a single transform around the centroid captured at start.
        SimultaneousGesture(MagnifyGesture(), RotateGesture())
            .onChanged { value in
                if session == nil || session?.skeletonID != skeletonID {
                    let centroid = centroidDoc(skeletonID: skeletonID) ?? .zero
                    session = makeSession(
                        skeletonID: skeletonID,
                        mode: .pinchRotate(centroidDoc: centroid),
                        fingerScreen: .zero  // unused for two-finger
                    )
                }
                guard let s = session else { return }
                let scale = value.first?.magnification ?? 1.0
                let angle = value.second?.rotation ?? .zero
                applyPinchRotate(session: s, scale: scale, rotation: angle)
                poseManager.activate(skeletonID: skeletonID)
            }
            .onEnded { _ in
                session = nil
            }
    }

    // MARK: - Apply transforms

    private func applyTranslate(session s: PoseTransformSession, fingerScreen: CGPoint) {
        let fingerDoc = canvasState.screenToDocument(fingerScreen)
        let delta = CGPoint(
            x: fingerDoc.x - s.fingerStartDoc.x,
            y: fingerDoc.y - s.fingerStartDoc.y
        )
        applyToOriginal(session: s) { _, original in
            CGPoint(x: original.x + delta.x, y: original.y + delta.y)
        }
    }

    private func applyScale(session s: PoseTransformSession, fingerScreen: CGPoint) {
        guard case .scale(let handle, let anchorDoc) = s.mode else { return }
        let fingerDoc = canvasState.screenToDocument(fingerScreen)

        let factorX: CGFloat
        let factorY: CGFloat
        switch handle {
        case .corner:
            // Uniform scale based on the larger displacement axis from
            // the anchor. Use the diagonal vector's projection to keep
            // the scaling intuitive when finger drift is mostly along
            // one axis.
            let origDx = s.fingerStartDoc.x - anchorDoc.x
            let origDy = s.fingerStartDoc.y - anchorDoc.y
            let curDx = fingerDoc.x - anchorDoc.x
            let curDy = fingerDoc.y - anchorDoc.y
            let len2 = origDx * origDx + origDy * origDy
            guard len2 > 0.001 else { return }
            let dot = curDx * origDx + curDy * origDy
            let factor = max(0.05, dot / len2)
            factorX = factor
            factorY = factor
        case .edge(let axis):
            switch axis {
            case .horizontal:
                let origDx = s.fingerStartDoc.x - anchorDoc.x
                guard abs(origDx) > 0.001 else { return }
                let curDx = fingerDoc.x - anchorDoc.x
                factorX = max(0.05, curDx / origDx)
                factorY = 1.0
            case .vertical:
                let origDy = s.fingerStartDoc.y - anchorDoc.y
                guard abs(origDy) > 0.001 else { return }
                let curDy = fingerDoc.y - anchorDoc.y
                factorX = 1.0
                factorY = max(0.05, curDy / origDy)
            }
        }

        applyToOriginal(session: s) { _, original in
            CGPoint(
                x: anchorDoc.x + (original.x - anchorDoc.x) * factorX,
                y: anchorDoc.y + (original.y - anchorDoc.y) * factorY
            )
        }
    }

    private func applyRotation(session s: PoseTransformSession, fingerScreen: CGPoint) {
        guard case .rotate(let centerDoc) = s.mode else { return }
        let fingerDoc = canvasState.screenToDocument(fingerScreen)
        let initialAngle = atan2(s.fingerStartDoc.y - centerDoc.y, s.fingerStartDoc.x - centerDoc.x)
        let currentAngle = atan2(fingerDoc.y - centerDoc.y, fingerDoc.x - centerDoc.x)
        let delta = currentAngle - initialAngle
        let cosA = cos(delta), sinA = sin(delta)
        applyToOriginal(session: s) { _, original in
            let dx = original.x - centerDoc.x
            let dy = original.y - centerDoc.y
            return CGPoint(
                x: centerDoc.x + dx * cosA - dy * sinA,
                y: centerDoc.y + dx * sinA + dy * cosA
            )
        }
    }

    private func applyPinchRotate(session s: PoseTransformSession, scale: CGFloat, rotation: Angle) {
        guard case .pinchRotate(let centroidDoc) = s.mode else { return }
        let factor = max(0.05, scale)
        let theta = rotation.radians
        let cosA = cos(theta), sinA = sin(theta)
        applyToOriginal(session: s) { _, original in
            // Translate to centroid → rotate → scale → translate back.
            let dx = original.x - centroidDoc.x
            let dy = original.y - centroidDoc.y
            let rx = dx * cosA - dy * sinA
            let ry = dx * sinA + dy * cosA
            return CGPoint(
                x: centroidDoc.x + rx * factor,
                y: centroidDoc.y + ry * factor
            )
        }
    }

    /// Apply a position transform to every joint of the active skeleton,
    /// reading from the snapshot captured at gesture start so the
    /// transform composes correctly across many `onChanged` ticks.
    private func applyToOriginal(
        session s: PoseTransformSession,
        transform: (_ jointKey: String, _ original: CGPoint) -> CGPoint
    ) {
        if let snapshot = s.handSnapshot {
            var positions: [HandJoint: CGPoint] = [:]
            for (joint, original) in snapshot {
                positions[joint] = transform(joint.rawValue, original)
            }
            poseManager.setHandJointPositions(skeletonID: s.skeletonID, positions: positions)
        }
        if let snapshot = s.bodySnapshot {
            var positions: [BodyJoint: CGPoint] = [:]
            for (joint, original) in snapshot {
                positions[joint] = transform(joint.rawValue, original)
            }
            poseManager.setBodyJointPositions(skeletonID: s.skeletonID, positions: positions)
        }
    }

    // MARK: - Session

    private func makeSession(skeletonID: UUID, mode: PoseTransformSession.Mode, fingerScreen: CGPoint) -> PoseTransformSession? {
        guard let skeleton = poseManager.renderableSkeletons.first(where: { $0.id == skeletonID }) else { return nil }
        let fingerStartDoc = canvasState.screenToDocument(fingerScreen)
        switch skeleton {
        case .hand(let pose):
            let snapshot = pose.joints.mapValues(\.position)
            return PoseTransformSession(
                skeletonID: skeletonID,
                mode: mode,
                handSnapshot: snapshot,
                bodySnapshot: nil,
                fingerStartDoc: fingerStartDoc
            )
        case .body(let pose):
            let snapshot = pose.joints.mapValues(\.position)
            return PoseTransformSession(
                skeletonID: skeletonID,
                mode: mode,
                handSnapshot: nil,
                bodySnapshot: snapshot,
                fingerStartDoc: fingerStartDoc
            )
        }
    }

    // MARK: - Geometry helpers

    private func jointDocPositions(in skeleton: PoseSkeleton) -> [CGPoint] {
        switch skeleton {
        case .hand(let pose): return pose.joints.values.map(\.position)
        case .body(let pose): return pose.joints.values.map(\.position)
        }
    }

    private func centroidDoc(skeletonID: UUID) -> CGPoint? {
        guard let skeleton = poseManager.renderableSkeletons.first(where: { $0.id == skeletonID }) else { return nil }
        let positions = jointDocPositions(in: skeleton)
        guard !positions.isEmpty else { return nil }
        let sumX = positions.map(\.x).reduce(0, +)
        let sumY = positions.map(\.y).reduce(0, +)
        return CGPoint(x: sumX / CGFloat(positions.count), y: sumY / CGFloat(positions.count))
    }

    /// Axis-aligned bbox of joint positions, padded outward by
    /// `bboxPaddingDoc` so corner / edge handles don't sit directly on
    /// extremity joints (e.g. fingertips, wrists) where their hit
    /// zones would compete with the per-joint drag handlers.
    private func paddedAxisAlignedBbox(of positions: [CGPoint]) -> CGRect? {
        guard !positions.isEmpty else { return nil }
        let xs = positions.map(\.x)
        let ys = positions.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        let pad = bboxPaddingDoc
        return CGRect(
            x: minX - pad,
            y: minY - pad,
            width:  max(2 * pad, maxX - minX + 2 * pad),
            height: max(2 * pad, maxY - minY + 2 * pad)
        )
    }

    /// Padding in canvas-doc units. 24pt at 1× zoom; canvas zoom scales
    /// the visual gap larger when zoomed in, smaller when zoomed out —
    /// acceptable trade-off vs. computing a constant screen-space pad
    /// (which would force a screen-space-first bbox computation).
    private var bboxPaddingDoc: CGFloat { 24 }

    private func normalized(_ v: CGPoint) -> CGPoint {
        let len = sqrt(v.x * v.x + v.y * v.y)
        guard len > 0.0001 else { return CGPoint(x: 0, y: -1) }
        return CGPoint(x: v.x / len, y: v.y / len)
    }
}

// MARK: - Session model

private struct PoseTransformSession {
    let skeletonID: UUID
    let mode: Mode

    enum Mode {
        case translate
        case scale(handle: ScaleHandle, anchorDoc: CGPoint)
        case rotate(centerDoc: CGPoint)
        case pinchRotate(centroidDoc: CGPoint)
    }

    /// One of these is non-nil based on the skeleton kind. Captured at
    /// gesture start so each `onChanged` tick recomputes from the
    /// original positions, avoiding floating-point drift across frames.
    let handSnapshot: [HandJoint: CGPoint]?
    let bodySnapshot: [BodyJoint: CGPoint]?
    let fingerStartDoc: CGPoint
}

private enum ScaleHandle {
    case corner
    case edge(axis: EdgeAxis)
}

private enum EdgeAxis {
    case horizontal  // left/right edges → scale on X only
    case vertical    // top/bottom edges → scale on Y only
}

// MARK: - CGPoint operators

private func -(lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
}

private func +(lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}

private func *(lhs: CGPoint, rhs: CGFloat) -> CGPoint {
    CGPoint(x: lhs.x * rhs, y: lhs.y * rhs)
}
