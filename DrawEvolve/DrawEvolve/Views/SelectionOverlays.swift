//
//  SelectionOverlays.swift
//  DrawEvolve
//
//  Selection overlay views including marching ants and transform handles
//

import SwiftUI

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

// MARK: - Selection Transform Handles

struct SelectionTransformHandles: View {
    let rect: CGRect
    @ObservedObject var canvasState: CanvasStateManager

    private let handleSize: CGFloat = 24
    private let rotationHandleOffset: CGFloat = 40

    var body: some View {
        ZStack {
            // Corner handles for scaling
            ForEach(0..<4) { index in
                HandleView(type: .corner)
                    .position(cornerPosition(index))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                handleCornerDrag(index: index, location: value.location)
                            }
                            .onEnded { _ in
                                canvasState.isTransformingSelection = false
                            }
                    )
            }

            // Rotation handle above selection
            HandleView(type: .rotation)
                .position(x: rect.midX, y: rect.minY - rotationHandleOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            handleRotationDrag(location: value.location)
                        }
                        .onEnded { _ in
                            canvasState.isTransformingSelection = false
                        }
                )
        }
    }

    private func cornerPosition(_ index: Int) -> CGPoint {
        switch index {
        case 0: return CGPoint(x: rect.minX, y: rect.minY) // Top-left
        case 1: return CGPoint(x: rect.maxX, y: rect.minY) // Top-right
        case 2: return CGPoint(x: rect.minX, y: rect.maxY) // Bottom-left
        case 3: return CGPoint(x: rect.maxX, y: rect.maxY) // Bottom-right
        default: return .zero
        }
    }

    private func handleCornerDrag(index: Int, location: CGPoint) {
        canvasState.isTransformingSelection = true

        // Calculate scale based on corner being dragged
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let originalDistance = hypot(
            cornerPosition(index).x - center.x,
            cornerPosition(index).y - center.y
        )
        let newDistance = hypot(location.x - center.x, location.y - center.y)

        let newScale = newDistance / originalDistance
        canvasState.selectionScale = max(0.1, min(5.0, newScale)) // Clamp between 0.1x and 5x
    }

    private func handleRotationDrag(location: CGPoint) {
        canvasState.isTransformingSelection = true

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let angle = atan2(location.y - center.y, location.x - center.x)
        canvasState.selectionRotation = Angle(radians: Double(angle) + .pi / 2)
    }
}

struct HandleView: View {
    enum HandleType {
        case corner
        case rotation
    }

    let type: HandleType

    var body: some View {
        Group {
            switch type {
            case .corner:
                Circle()
                    .fill(Color.white)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(Color.blue, lineWidth: 2))
                    .shadow(radius: 2)
            case .rotation:
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().stroke(Color.green, lineWidth: 2))
                        .shadow(radius: 2)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundColor(.green)
                        .font(.system(size: 14))
                }
            }
        }
    }
}
