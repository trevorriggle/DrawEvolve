//
//  FloatingFeedbackPanel.swift
//  DrawEvolve
//
//  Draggable, collapsible feedback panel that floats over the canvas.
//

import SwiftUI

struct FloatingFeedbackPanel: View {
    let feedback: String?
    @Binding var isPresented: Bool
    @State private var isExpanded = true
    @State private var position: CGPoint = CGPoint(x: UIScreen.main.bounds.width - 200, y: 100)
    @State private var dragOffset: CGSize = .zero

    private let collapsedSize: CGSize = CGSize(width: 60, height: 60)
    private let expandedSize: CGSize = CGSize(width: 350, height: 500)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isExpanded, let feedbackText = feedback {
                    // Expanded panel
                    VStack(spacing: 0) {
                        // Header with drag handle and controls
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .foregroundColor(.secondary)

                            Spacer()

                            Text("AI Feedback")
                                .font(.headline)

                            Spacer()

                            HStack(spacing: 12) {
                                Button(action: { withAnimation(.spring(response: 0.3)) { isExpanded = false } }) {
                                    Image(systemName: "chevron.down.circle.fill")
                                        .foregroundColor(.secondary)
                                }

                                Button(action: { isPresented = false }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding()
                        .background(Color(uiColor: .systemBackground))

                        Divider()

                        // Feedback content
                        ScrollView {
                            Text(feedbackText)
                                .font(.body)
                                .padding()
                                .textSelection(.enabled)
                        }
                        .background(Color(uiColor: .systemBackground))
                    }
                    .frame(width: expandedSize.width, height: expandedSize.height)
                    .background(Color(uiColor: .systemBackground))
                    .cornerRadius(16)
                    .shadow(radius: 10)
                } else {
                    // Collapsed icon
                    Button(action: { withAnimation(.spring(response: 0.3)) { isExpanded = true } }) {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: collapsedSize.width, height: collapsedSize.height)
                                .shadow(radius: 5)

                            Image(systemName: "pencil.tip.crop.circle")
                                .font(.system(size: 30))
                                .foregroundColor(.white)
                        }
                    }
                }
            }
            .position(
                x: position.x + dragOffset.width,
                y: position.y + dragOffset.height
            )
            .gesture(
                DragGesture()
                    .onChanged { value in
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        // Update final position
                        position.x += value.translation.x
                        position.y += value.translation.y

                        // Constrain to screen bounds
                        let maxX = geometry.size.width - (isExpanded ? expandedSize.width / 2 : collapsedSize.width / 2)
                        let maxY = geometry.size.height - (isExpanded ? expandedSize.height / 2 : collapsedSize.height / 2)
                        let minX = isExpanded ? expandedSize.width / 2 : collapsedSize.width / 2
                        let minY = isExpanded ? expandedSize.height / 2 : collapsedSize.height / 2

                        position.x = min(max(position.x, minX), maxX)
                        position.y = min(max(position.y, minY), maxY)

                        dragOffset = .zero
                    }
            )
            .onAppear {
                // Position in top-right corner initially
                let initialX = geometry.size.width - expandedSize.width / 2 - 20
                let initialY = expandedSize.height / 2 + 60
                position = CGPoint(x: initialX, y: initialY)
            }
        }
    }
}

#Preview {
    ZStack {
        Color.gray.ignoresSafeArea()

        FloatingFeedbackPanel(
            feedback: """
            Great work on your portrait! Your proportions are well-balanced.

            **Strengths:**
            - Good facial structure
            - Nice shading depth

            **Areas to improve:**
            - Soften shadow transitions
            - Adjust ear positioning
            """,
            isPresented: .constant(true)
        )
    }
}
