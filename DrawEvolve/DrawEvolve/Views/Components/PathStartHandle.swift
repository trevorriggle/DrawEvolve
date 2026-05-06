//
//  PathStartHandle.swift
//  DrawEvolve
//
//  SwiftUI handle that sits on the floating text's path at the current
//  pathStartOffset. Dragging the handle updates the offset (and therefore
//  where text begins along the path); CanvasStateManager clamps to
//  [0, arcLength] for open paths and wraps mod arcLength for closed paths.
//
//  Visually mirrors TransformHandlesOverlay's rotation handle (filled
//  circle, blue stroke, 16pt visual / 44pt hit target). Only renders when
//  the active FloatingText has a path — plain text doesn't get one.
//

import SwiftUI
import UIKit

struct PathStartHandle: View {
    @ObservedObject var canvasState: CanvasStateManager
    @State private var dragStartOffset: CGFloat?

    var body: some View {
        Group {
            if let ft = canvasState.floatingText,
               let lut = ft.pathLUT,
               !lut.isEmpty,
               let look = PathSmoothing.point(at: ft.pathStartOffset, in: lut, isClosed: ft.isClosed) {
                let screenPoint = canvasState.documentToScreen(look.point)
                handleDot()
                    .position(screenPoint)
                    .gesture(dragGesture(currentOffset: ft.pathStartOffset, lut: lut, isClosed: ft.isClosed))
            }
        }
    }

    private func handleDot() -> some View {
        let visual = Circle()
            .fill(Color.white)
            .frame(width: 16, height: 16)
            .overlay(Circle().stroke(Color.blue, lineWidth: 2))
        return ZStack {
            // 44pt hit target (Apple's recommended minimum).
            Color.clear
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            visual
        }
    }

    /// Track total drag delta in arc-length units. Compute the delta by
    /// projecting the finger's screen-space displacement onto the local
    /// path tangent at the start of the drag — straight Euclidean distance
    /// between successive lookups would diverge on tight curves.
    private func dragGesture(currentOffset: CGFloat,
                             lut: [PathArcLengthSample],
                             isClosed: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if dragStartOffset == nil {
                    dragStartOffset = currentOffset
                }
                guard let startOffset = dragStartOffset else { return }
                let startScreen = value.startLocation
                let currentScreen = value.location
                let startDoc = canvasState.screenToDocument(startScreen)
                let currentDoc = canvasState.screenToDocument(currentScreen)
                // Project the finger displacement onto the path's tangent
                // at the start point. This is a coarse approximation —
                // for long drags around tight curves it will under- or
                // over-shoot, but the user gets an immediate visual on
                // every frame so they self-correct.
                guard let lookup = PathSmoothing.point(at: startOffset, in: lut, isClosed: isClosed) else { return }
                let dx = currentDoc.x - startDoc.x
                let dy = currentDoc.y - startDoc.y
                let tx = cos(lookup.tangent)
                let ty = sin(lookup.tangent)
                let distanceDelta = dx * tx + dy * ty
                canvasState.setPathStartOffset(startOffset + distanceDelta)
            }
            .onEnded { _ in
                dragStartOffset = nil
            }
    }
}
