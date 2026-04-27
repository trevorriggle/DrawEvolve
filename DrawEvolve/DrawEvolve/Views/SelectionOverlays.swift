//
//  SelectionOverlays.swift
//  DrawEvolve
//
//  Selection overlay views including marching ants and transform handles
//

import SwiftUI
import UIKit

// MARK: - Marching Ants Selection Views

/// Animated marching ants border for rectangular selections
struct MarchingAntsRectangle: View {
    let rect: CGRect
    @State private var dashPhase: CGFloat = 0

    var body: some View {
        Rectangle()
            .path(in: rect)
            .stroke(style: StrokeStyle(
                lineWidth: 2,
                lineCap: .round,
                lineJoin: .round,
                dash: [8, 4],
                dashPhase: dashPhase
            ))
            .foregroundColor(.white)
            .overlay(
                Rectangle()
                    .path(in: rect)
                    .stroke(style: StrokeStyle(
                        lineWidth: 2,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: [8, 4],
                        dashPhase: dashPhase - 6 // Offset for double-line effect
                    ))
                    .foregroundColor(.black)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    dashPhase = -12 // Full cycle of dash pattern
                }
            }
    }
}

/// Animated marching ants border for lasso/path selections
struct MarchingAntsPath: View {
    let path: [CGPoint]
    @State private var dashPhase: CGFloat = 0

    var body: some View {
        Path { p in
            guard !path.isEmpty else { return }
            p.move(to: path[0])
            for point in path.dropFirst() {
                p.addLine(to: point)
            }
            // Close the path
            if let first = path.first {
                p.addLine(to: first)
            }
        }
        .stroke(style: StrokeStyle(
            lineWidth: 2,
            lineCap: .round,
            lineJoin: .round,
            dash: [8, 4],
            dashPhase: dashPhase
        ))
        .foregroundColor(.white)
        .overlay(
            Path { p in
                guard !path.isEmpty else { return }
                p.move(to: path[0])
                for point in path.dropFirst() {
                    p.addLine(to: point)
                }
                if let first = path.first {
                    p.addLine(to: first)
                }
            }
            .stroke(style: StrokeStyle(
                lineWidth: 2,
                lineCap: .round,
                lineJoin: .round,
                dash: [8, 4],
                dashPhase: dashPhase - 6
            ))
            .foregroundColor(.black)
        )
        .onAppear {
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                dashPhase = -12
            }
        }
    }
}

// MARK: - Transform Handles Overlay
//
// Free-transform-style handles for the active floating selection (move-tool
// drag of the whole layer skips this since "scaling the whole layer" isn't a
// meaningful operation; rect/lasso/import all show the handles).
//
// Conventions:
//   • selectionScale is per-axis (CGSize). Identity is (1, 1).
//   • selectionRotation positive = visual CCW (matches canvasRotation).
//   • Doc-space rotation matrix is R(-θ) for visual CCW; the inverse is R(+θ).
//
// Layout: 4 corner handles (uniform scale, anchor on opposite corner),
// 4 edge handles (one-axis scale, anchor on opposite edge), 1 rotation
// handle on a stem above the rotated top-center.
//
// All handle positions are computed by:
//   1. Build local-frame corners/edges from the displayed rect's half-extents.
//   2. Apply selectionRotation in doc space (the same R(-θ) the shader uses).
//   3. Translate by displayed-rect center.
//   4. documentToScreen() for the final SwiftUI position.
// Per the user's explicit rule, rotation is applied to handle positions
// BEFORE the screen conversion — never as a post-render .rotationEffect on
// the overlay (which would put the handles in the wrong place once
// canvasRotation is also active).

private enum TransformHandle: Equatable {
    case corner(Int)   // 0=TL, 1=TR, 2=BR, 3=BL
    case edge(Int)     // 0=top, 1=right, 2=bottom, 3=left
    case rotation
}

private struct TransformDragSession {
    let handle: TransformHandle
    let startScale: CGSize
    let startOffset: CGPoint
    let startRotation: CGFloat       // radians, visual CCW positive
    let originalRect: CGRect
    // Captured at gesture start so the anchor stays fixed in doc space
    // through the drag — these are the doc-space positions of the geometry
    // the user is NOT moving.
    let anchorDoc: CGPoint           // opposite corner / edge midpoint
    let centerDocAtStart: CGPoint    // displayed-rect center in doc space
    let originalDiagonalDoc: CGPoint // anchor → corner vector at gesture start (corner only)
    let fingerStartDoc: CGPoint
    let initialAngleAtCenter: CGFloat // for rotation handle: atan2 angle of finger from center
}

struct TransformHandlesOverlay: View {
    @ObservedObject var canvasState: CanvasStateManager
    @State private var session: TransformDragSession?

    var body: some View {
        Group {
            if canvasState.floatingSelectionTexture != nil,
               let originalRect = canvasState.selectionOriginalRect {
                content(originalRect: originalRect)
            }
        }
    }

    @ViewBuilder
    private func content(originalRect: CGRect) -> some View {
        let displayedW = originalRect.width  * canvasState.selectionScale.width
        let displayedH = originalRect.height * canvasState.selectionScale.height
        let centerDoc = CGPoint(
            x: originalRect.origin.x + canvasState.selectionOffset.x + displayedW / 2,
            y: originalRect.origin.y + canvasState.selectionOffset.y + displayedH / 2
        )
        let halfW = displayedW / 2
        let halfH = displayedH / 2
        let theta = canvasState.selectionRotation.radians

        // Local positions relative to displayed-rect center, Y-down.
        let cornerLocals: [CGPoint] = [
            CGPoint(x: -halfW, y: -halfH),  // 0 TL
            CGPoint(x:  halfW, y: -halfH),  // 1 TR
            CGPoint(x:  halfW, y:  halfH),  // 2 BR
            CGPoint(x: -halfW, y:  halfH),  // 3 BL
        ]
        let edgeLocals: [CGPoint] = [
            CGPoint(x: 0,      y: -halfH),  // 0 top
            CGPoint(x: halfW,  y: 0),       // 1 right
            CGPoint(x: 0,      y:  halfH),  // 2 bottom
            CGPoint(x: -halfW, y: 0),       // 3 left
        ]

        // Apply selectionRotation (R(-θ) in Y-down doc) and translate.
        let cornerDocs = cornerLocals.map { rotateLocalToDoc($0, theta: theta).offset(by: centerDoc) }
        let edgeDocs = edgeLocals.map { rotateLocalToDoc($0, theta: theta).offset(by: centerDoc) }

        // documentToScreen accounts for canvas zoom/pan/rotation; the
        // selectionRotation we already baked in upstream, so the rendered
        // handle ends up at the same screen point the renderer is drawing
        // the corresponding corner of the floating texture at.
        let cornerScreens = cornerDocs.map { canvasState.documentToScreen($0) }
        let edgeScreens = edgeDocs.map { canvasState.documentToScreen($0) }
        let centerScreen = canvasState.documentToScreen(centerDoc)
        let topCenterScreen = edgeScreens[0]

        // Rotation handle: 30 screen-pt past the rotated top-center along the
        // outward normal of the (rotated) top edge. Computing this in screen
        // space — rather than in doc and then converting — gives a constant
        // 30pt visual offset regardless of zoom.
        let outward = normalized(topCenterScreen - centerScreen)
        let rotationHandleScreen = topCenterScreen + outward * 30

        ZStack {
            // Bounding-box outline + rotation stem.
            Path { p in
                p.move(to: cornerScreens[0])
                p.addLine(to: cornerScreens[1])
                p.addLine(to: cornerScreens[2])
                p.addLine(to: cornerScreens[3])
                p.closeSubpath()
                p.move(to: topCenterScreen)
                p.addLine(to: rotationHandleScreen)
            }
            .stroke(Color.blue.opacity(0.85), lineWidth: 1.5)
            .allowsHitTesting(false)

            ForEach(0..<4, id: \.self) { i in
                handleDot(filled: true)
                    .position(cornerScreens[i])
                    .gesture(scaleDrag(handle: .corner(i)))
            }
            ForEach(0..<4, id: \.self) { i in
                handleDot(filled: false)
                    .position(edgeScreens[i])
                    .gesture(scaleDrag(handle: .edge(i)))
            }
            handleDot(filled: true, stroke: .green)
                .position(rotationHandleScreen)
                .gesture(rotationDrag())
        }
        .ignoresSafeArea()
    }

    private func handleDot(filled: Bool, stroke: Color = .blue) -> some View {
        // 16pt visual, 44pt hit target — Apple's recommended minimum.
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

    private func scaleDrag(handle: TransformHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if session == nil {
                    session = makeSession(for: handle, fingerScreen: value.startLocation)
                }
                guard let s = session else { return }
                applyScaleDrag(session: s, handle: handle, fingerScreen: value.location)
            }
            .onEnded { _ in
                session = nil
                // Resample from the original full-res source on a background
                // thread; the bilinear-scaled texture stays in place until
                // the swap completes.
                canvasState.scheduleFloatingTextureResampleFromSource()
            }
    }

    private func rotationDrag() -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if session == nil {
                    session = makeSession(for: .rotation, fingerScreen: value.startLocation)
                }
                guard let s = session else { return }
                applyRotationDrag(session: s, fingerScreen: value.location)
            }
            .onEnded { _ in
                session = nil
                // No resample — rotation doesn't change pixel density.
            }
    }

    // MARK: - Session setup

    private func makeSession(for handle: TransformHandle, fingerScreen: CGPoint) -> TransformDragSession? {
        guard let originalRect = canvasState.selectionOriginalRect else { return nil }
        let theta = canvasState.selectionRotation.radians
        let startScale = canvasState.selectionScale
        let startOffset = canvasState.selectionOffset

        let displayedW = originalRect.width  * startScale.width
        let displayedH = originalRect.height * startScale.height
        let center = CGPoint(
            x: originalRect.origin.x + startOffset.x + displayedW / 2,
            y: originalRect.origin.y + startOffset.y + displayedH / 2
        )

        // Anchor in local frame: opposite corner / opposite edge midpoint /
        // (rotation has no anchor — the center stays put).
        let halfW = displayedW / 2, halfH = displayedH / 2
        let anchorLocal: CGPoint = {
            switch handle {
            case .corner(let i): return [
                CGPoint(x:  halfW, y:  halfH), // TL → BR
                CGPoint(x: -halfW, y:  halfH), // TR → BL
                CGPoint(x: -halfW, y: -halfH), // BR → TL
                CGPoint(x:  halfW, y: -halfH), // BL → TR
            ][i]
            case .edge(let i): return [
                CGPoint(x: 0,       y:  halfH), // top    → bottom
                CGPoint(x: -halfW,  y: 0),      // right  → left
                CGPoint(x: 0,       y: -halfH), // bottom → top
                CGPoint(x:  halfW,  y: 0),      // left   → right
            ][i]
            case .rotation: return .zero
            }
        }()
        let cornerLocal: CGPoint = {
            switch handle {
            case .corner(let i): return [
                CGPoint(x: -halfW, y: -halfH), // TL
                CGPoint(x:  halfW, y: -halfH), // TR
                CGPoint(x:  halfW, y:  halfH), // BR
                CGPoint(x: -halfW, y:  halfH), // BL
            ][i]
            case .edge(let i): return [
                CGPoint(x: 0,      y: -halfH), // top
                CGPoint(x: halfW,  y: 0),       // right
                CGPoint(x: 0,      y:  halfH), // bottom
                CGPoint(x: -halfW, y: 0),       // left
            ][i]
            case .rotation: return .zero
            }
        }()

        let anchorDoc  = rotateLocalToDoc(anchorLocal, theta: theta).offset(by: center)
        let cornerDoc  = rotateLocalToDoc(cornerLocal, theta: theta).offset(by: center)
        let fingerDoc  = canvasState.screenToDocument(fingerScreen)

        let initialAngle: CGFloat = {
            let dx = fingerDoc.x - center.x
            let dy = fingerDoc.y - center.y
            return atan2(dy, dx)
        }()

        return TransformDragSession(
            handle: handle,
            startScale: startScale,
            startOffset: startOffset,
            startRotation: theta,
            originalRect: originalRect,
            anchorDoc: anchorDoc,
            centerDocAtStart: center,
            originalDiagonalDoc: CGPoint(x: cornerDoc.x - anchorDoc.x, y: cornerDoc.y - anchorDoc.y),
            fingerStartDoc: fingerDoc,
            initialAngleAtCenter: initialAngle
        )
    }

    // MARK: - Apply scale drag

    private func applyScaleDrag(session s: TransformDragSession, handle: TransformHandle, fingerScreen: CGPoint) {
        let fingerDoc = canvasState.screenToDocument(fingerScreen)
        let fromAnchorDoc = CGPoint(x: fingerDoc.x - s.anchorDoc.x, y: fingerDoc.y - s.anchorDoc.y)
        // Inverse-rotate to local frame so we can split the displacement
        // into the two axes the box was originally aligned with.
        let inLocal = rotateDocToLocal(fromAnchorDoc, theta: s.startRotation)

        // Original (pre-this-gesture) diagonal in local for this corner/edge.
        // For a corner: this is (sign * displayedW, sign * displayedH) at
        // start. For an edge: only one axis is non-zero at start.
        let origInLocal = rotateDocToLocal(s.originalDiagonalDoc, theta: s.startRotation)

        var newScale = s.startScale
        switch handle {
        case .corner:
            // Uniform: project finger displacement onto the original-diagonal
            // direction; the scale factor is the projected length divided by
            // the original-diagonal length (signed, so dragging "inward" past
            // the anchor inverts the scale — clamped to a small positive
            // floor to avoid degenerate zero-area rects).
            let len2 = origInLocal.x * origInLocal.x + origInLocal.y * origInLocal.y
            guard len2 > 0 else { return }
            let dot = inLocal.x * origInLocal.x + inLocal.y * origInLocal.y
            let factor = max(0.05, dot / len2)
            newScale = CGSize(
                width:  s.startScale.width  * factor,
                height: s.startScale.height * factor
            )
        case .edge(let i):
            // One axis only. For top/bottom, scale .height; for left/right,
            // scale .width. The other axis stays at the start value.
            let isVerticalAxis = (i == 0 || i == 2)  // top or bottom
            if isVerticalAxis {
                let origAxis = origInLocal.y
                guard abs(origAxis) > 0.001 else { return }
                let factor = max(0.05, inLocal.y / origAxis)
                newScale = CGSize(width: s.startScale.width, height: s.startScale.height * factor)
            } else {
                let origAxis = origInLocal.x
                guard abs(origAxis) > 0.001 else { return }
                let factor = max(0.05, inLocal.x / origAxis)
                newScale = CGSize(width: s.startScale.width * factor, height: s.startScale.height)
            }
        case .rotation:
            return
        }

        // Solve for the new offset that keeps the anchor pinned in doc space.
        // Notation:
        //   center = origin + offset + (originalRect.size .* newScale) / 2
        //   anchor = center + R(-θ) * (anchorLocalSign .* (originalRect.size .* newScale) / 2)
        //                          ^^^ unchanged: anchor is at the same local *sign* as before
        // Solving for offset such that anchor == s.anchorDoc:
        let newDisplayedSize = CGSize(
            width:  s.originalRect.width  * newScale.width,
            height: s.originalRect.height * newScale.height
        )
        let anchorLocalSign = anchorSign(for: handle)
        let anchorLocalNew = CGPoint(
            x: anchorLocalSign.x * newDisplayedSize.width  / 2,
            y: anchorLocalSign.y * newDisplayedSize.height / 2
        )
        let anchorOffsetFromCenter = rotateLocalToDoc(anchorLocalNew, theta: s.startRotation)
        let newCenter = CGPoint(
            x: s.anchorDoc.x - anchorOffsetFromCenter.x,
            y: s.anchorDoc.y - anchorOffsetFromCenter.y
        )
        let newOffset = CGPoint(
            x: newCenter.x - s.originalRect.origin.x - newDisplayedSize.width  / 2,
            y: newCenter.y - s.originalRect.origin.y - newDisplayedSize.height / 2
        )

        canvasState.selectionScale = newScale
        canvasState.selectionOffset = newOffset
    }

    private func anchorSign(for handle: TransformHandle) -> CGPoint {
        switch handle {
        case .corner(let i):
            return [
                CGPoint(x:  1, y:  1), // TL → anchor at +,+
                CGPoint(x: -1, y:  1), // TR → anchor at -,+
                CGPoint(x: -1, y: -1), // BR → anchor at -,-
                CGPoint(x:  1, y: -1), // BL → anchor at +,-
            ][i]
        case .edge(let i):
            return [
                CGPoint(x: 0, y:  1), // top    → anchor on bottom edge
                CGPoint(x: -1, y: 0), // right  → anchor on left edge
                CGPoint(x: 0, y: -1), // bottom → anchor on top edge
                CGPoint(x:  1, y: 0), // left   → anchor on right edge
            ][i]
        case .rotation:
            return .zero
        }
    }

    // MARK: - Apply rotation drag

    private func applyRotationDrag(session s: TransformDragSession, fingerScreen: CGPoint) {
        let fingerDoc = canvasState.screenToDocument(fingerScreen)
        let dx = fingerDoc.x - s.centerDocAtStart.x
        let dy = fingerDoc.y - s.centerDocAtStart.y
        let currentAngle = atan2(dy, dx)
        // atan2 increases CW visually in Y-down (because positive y is down).
        // selectionRotation positive = visual CCW. Hence the negation:
        // visual CCW delta = -(atan2 delta).
        let delta = -(currentAngle - s.initialAngleAtCenter)
        canvasState.selectionRotation = .radians(s.startRotation + delta)
    }

    // MARK: - Math helpers

    /// Doc-space rotation that takes a local-frame vector to the rotated
    /// doc-space vector. For visual CCW by θ in Y-down, the matrix is R(-θ):
    ///   x' =  x cosθ + y sinθ
    ///   y' = -x sinθ + y cosθ
    private func rotateLocalToDoc(_ p: CGPoint, theta: CGFloat) -> CGPoint {
        if theta == 0 { return p }
        let c = cos(theta), s = sin(theta)
        return CGPoint(x: p.x * c + p.y * s, y: -p.x * s + p.y * c)
    }

    /// Inverse of rotateLocalToDoc — R(+θ) applied to a Y-down vector.
    private func rotateDocToLocal(_ p: CGPoint, theta: CGFloat) -> CGPoint {
        if theta == 0 { return p }
        let c = cos(theta), s = sin(theta)
        return CGPoint(x: p.x * c - p.y * s, y: p.x * s + p.y * c)
    }

    private func normalized(_ v: CGPoint) -> CGPoint {
        let len = sqrt(v.x * v.x + v.y * v.y)
        guard len > 0.0001 else { return CGPoint(x: 0, y: -1) } // fallback: pretend the box is upright
        return CGPoint(x: v.x / len, y: v.y / len)
    }
}

private extension CGPoint {
    func offset(by other: CGPoint) -> CGPoint {
        CGPoint(x: x + other.x, y: y + other.y)
    }
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }
    static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
        CGPoint(x: lhs.x * rhs, y: lhs.y * rhs)
    }
}

// MARK: - Cancel pill

/// Small floating Cancel-only pill that appears whenever a floating selection
/// (rect/lasso/import) is active. Tap-outside-the-bounds + tool-change both
/// commit (handled in CanvasStateManager); Cancel reverts the entire transform
/// session in one shot.
struct TransformCancelPill: View {
    @ObservedObject var canvasState: CanvasStateManager

    var body: some View {
        if canvasState.floatingSelectionTexture != nil {
            Button(action: { canvasState.cancelSelection() }) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                    Text("Cancel")
                }
                .font(.subheadline.weight(.medium))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.75))
                .clipShape(Capsule())
                .shadow(radius: 3)
            }
        }
    }
}
