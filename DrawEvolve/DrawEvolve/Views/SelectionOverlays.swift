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

