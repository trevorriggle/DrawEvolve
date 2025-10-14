//
//  FloatingFeedbackPanel.swift
//  DrawEvolve
//
//  Draggable, collapsible feedback panel that floats over the canvas.
//

import SwiftUI

struct FloatingFeedbackPanel: View {
    let feedback: String?
    let critiqueHistory: [CritiqueEntry]
    @Binding var isPresented: Bool
    @State private var isExpanded = true
    @State private var position: CGPoint = CGPoint(x: UIScreen.main.bounds.width - 200, y: 100)
    @State private var dragOffset: CGSize = .zero
    @State private var showHistory = false

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
                            VStack(spacing: 16) {
                                FormattedMarkdownView(text: feedbackText)
                                    .textSelection(.enabled)

                                // History button if there are multiple critiques
                                if critiqueHistory.count > 1 {
                                    Button(action: { showHistory = true }) {
                                        HStack {
                                            Image(systemName: "clock.arrow.circlepath")
                                            Text("View History (\(critiqueHistory.count))")
                                                .font(.subheadline)
                                        }
                                        .padding(.vertical, 10)
                                        .padding(.horizontal, 16)
                                        .background(Color.accentColor.opacity(0.1))
                                        .foregroundColor(.accentColor)
                                        .cornerRadius(8)
                                    }
                                }
                            }
                            .padding()
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
                x: position.x,
                y: position.y
            )
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Update position in real-time WITHOUT animation for immediate response
                        position.x = value.location.x
                        position.y = value.location.y
                    }
                    .onEnded { value in
                        // Constrain to screen bounds with safe margins (WITH animation for snap effect)
                        withAnimation(.spring(response: 0.3)) {
                            let currentSize = isExpanded ? expandedSize : collapsedSize

                            // Ensure the collapse button is always visible (70pt from top minimum)
                            let minY = max(currentSize.height / 2, 70)
                            let maxY = geometry.size.height - currentSize.height / 2
                            let minX = currentSize.width / 2
                            let maxX = geometry.size.width - currentSize.width / 2

                            position.x = min(max(position.x, minX), maxX)
                            position.y = min(max(position.y, minY), maxY)
                        }
                    }
            )
            .onChange(of: isExpanded) { _, newValue in
                // Re-constrain when expanding/collapsing
                withAnimation(.spring(response: 0.3)) {
                    let currentSize = newValue ? expandedSize : collapsedSize
                    let minY = max(currentSize.height / 2, 70)
                    let maxY = geometry.size.height - currentSize.height / 2
                    let minX = currentSize.width / 2
                    let maxX = geometry.size.width - currentSize.width / 2

                    position.x = min(max(position.x, minX), maxX)
                    position.y = min(max(position.y, minY), maxY)
                }
            }
            .onAppear {
                // Position in top-right corner initially, with safe margin from top
                let initialX = geometry.size.width - expandedSize.width / 2 - 20
                let initialY = max(expandedSize.height / 2 + 20, 70)
                position = CGPoint(x: initialX, y: initialY)
            }
        }
        .sheet(isPresented: $showHistory) {
            CritiqueHistoryView(critiqueHistory: critiqueHistory)
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
            critiqueHistory: [
                CritiqueEntry(feedback: "First critique", timestamp: Date().addingTimeInterval(-86400)),
                CritiqueEntry(feedback: "Second critique", timestamp: Date())
            ],
            isPresented: .constant(true)
        )
    }
}
