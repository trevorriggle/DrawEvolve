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
    @State private var position: CGPoint = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var showHistory = false
    @State private var showHistoryMenu = false
    @State private var selectedHistoryIndex = 0
    @State private var screenSize: CGSize = .zero

    private let collapsedSize: CGSize = CGSize(width: 60, height: 60)
    private let expandedSize: CGSize = CGSize(width: 525, height: 500)
    private let historyMenuWidth: CGFloat = 200

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isExpanded, feedback != nil {
                    // Expanded panel
                    VStack(spacing: 0) {
                        // Header with drag handle and controls
                        HStack {
                            Button(action: {
                                withAnimation(.spring(response: 0.25)) {
                                    showHistoryMenu.toggle()
                                }
                            }) {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundColor(showHistoryMenu ? .accentColor : .secondary)
                                    .font(.title3)
                            }
                            .disabled(critiqueHistory.isEmpty)

                            Spacer()

                            Text("AI Feedback")
                                .font(.headline)

                            Spacer()

                            HStack(spacing: 12) {
                                // Reset position button
                                Button(action: { resetPosition() }) {
                                    Image(systemName: "arrow.counterclockwise.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .help("Reset panel position")

                                Button(action: {
                                    withAnimation(.spring(response: 0.3)) {
                                        // Adjust position so top-left stays in same place
                                        let offsetX = (expandedSize.width - collapsedSize.width) / 2
                                        let offsetY = (expandedSize.height - collapsedSize.height) / 2
                                        var newX = position.x - offsetX
                                        var newY = position.y - offsetY

                                        // Apply strict boundaries for collapsed state
                                        let minX = collapsedSize.width / 2
                                        let maxX = screenSize.width - collapsedSize.width / 2
                                        let minY = collapsedSize.height / 2
                                        let maxY = screenSize.height - collapsedSize.height / 2

                                        newX = min(max(newX, minX), maxX)
                                        newY = min(max(newY, minY), maxY)

                                        position = CGPoint(x: newX, y: newY)
                                        isExpanded = false
                                    }
                                }) {
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
                                // Show timestamp of current feedback
                                if !critiqueHistory.isEmpty && selectedHistoryIndex < critiqueHistory.count {
                                    HStack {
                                        Image(systemName: "clock")
                                            .foregroundColor(.secondary)
                                            .font(.caption)
                                        Text(formatTimestamp(critiqueHistory[selectedHistoryIndex].timestamp))
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Text("\(selectedHistoryIndex + 1) of \(critiqueHistory.count)")
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                    }
                                    .padding(.horizontal, 4)
                                }

                                FormattedMarkdownView(text: displayedFeedback)
                                    .textSelection(.enabled)
                            }
                            .padding()
                        }
                        .background(Color(uiColor: .systemBackground))
                    }
                    .frame(width: expandedSize.width, height: expandedSize.height)
                    .background(Color(uiColor: .systemBackground))
                    .cornerRadius(16)
                    .shadow(radius: 10)
                    .overlay(alignment: .leading) {
                        // History menu overlay - appears to the left
                        if showHistoryMenu && !critiqueHistory.isEmpty {
                            VStack(spacing: 0) {
                                // History menu header
                                HStack {
                                    Text("History")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color(uiColor: .secondarySystemBackground))

                                Divider()

                                // History list (most recent first)
                                ScrollView {
                                    VStack(spacing: 0) {
                                        ForEach(Array(critiqueHistory.enumerated().reversed()), id: \.element.id) { index, entry in
                                            Button(action: {
                                                selectedHistoryIndex = index
                                                withAnimation(.spring(response: 0.25)) {
                                                    showHistoryMenu = false
                                                }
                                            }) {
                                                HStack(spacing: 8) {
                                                    VStack(alignment: .leading, spacing: 4) {
                                                        Text(formatTimestamp(entry.timestamp))
                                                            .font(.subheadline)
                                                            .fontWeight(.medium)
                                                            .foregroundColor(.primary)

                                                        Text(entry.feedback.prefix(50) + (entry.feedback.count > 50 ? "..." : ""))
                                                            .font(.caption)
                                                            .foregroundColor(.primary)
                                                            .lineLimit(2)
                                                    }
                                                    Spacer()

                                                    if index == selectedHistoryIndex {
                                                        Image(systemName: "checkmark")
                                                            .foregroundColor(.accentColor)
                                                            .font(.caption)
                                                    }
                                                }
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 10)
                                                .background(index == selectedHistoryIndex ? Color.accentColor.opacity(0.1) : Color.clear)
                                            }

                                            // Show divider except after the last item
                                            if index > 0 {
                                                Divider()
                                                    .padding(.leading, 12)
                                            }
                                        }
                                    }
                                }
                            }
                            .frame(width: historyMenuWidth, height: expandedSize.height)
                            .background(Color(uiColor: .systemBackground))
                            .cornerRadius(12)
                            .shadow(radius: 8)
                            .offset(x: -historyMenuWidth - 8)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                    }
                } else {
                    // Collapsed icon
                    ZStack {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: collapsedSize.width, height: collapsedSize.height)
                            .shadow(radius: 5)

                        Image(systemName: "pencil.tip.crop.circle")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                    }
                    .onTapGesture {
                        // Tap to expand (doesn't interfere with drag)
                        withAnimation(.spring(response: 0.3)) {
                            // Adjust position so top-left stays in same place
                            let offsetX = (expandedSize.width - collapsedSize.width) / 2
                            let offsetY = (expandedSize.height - collapsedSize.height) / 2
                            var newX = position.x + offsetX
                            var newY = position.y + offsetY

                            // Apply strict boundaries for expanded state
                            let minX = expandedSize.width / 2
                            let maxX = screenSize.width - expandedSize.width / 2
                            let minY = expandedSize.height / 2
                            let maxY = screenSize.height - expandedSize.height / 2

                            newX = min(max(newX, minX), maxX)
                            newY = min(max(newY, minY), maxY)

                            position = CGPoint(x: newX, y: newY)
                            isExpanded = true
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
                        // Constrain drag offset in real-time to prevent going off-screen
                        let currentWidth = isExpanded ? expandedSize.width : collapsedSize.width
                        let currentHeight = isExpanded ? expandedSize.height : collapsedSize.height

                        // Calculate what the new position would be with this drag
                        let potentialX = position.x + value.translation.width
                        let potentialY = position.y + value.translation.height

                        // Strict boundaries - keep entire panel on screen
                        // If history menu is showing, account for it on the left side
                        let leftExtension = showHistoryMenu ? (historyMenuWidth + 8) : 0
                        let minX = currentWidth / 2 + leftExtension
                        let maxX = geometry.size.width - currentWidth / 2
                        let minY = currentHeight / 2
                        let maxY = geometry.size.height - currentHeight / 2

                        // Constrain the drag offset
                        let constrainedX = min(max(potentialX, minX), maxX)
                        let constrainedY = min(max(potentialY, minY), maxY)

                        dragOffset = CGSize(
                            width: constrainedX - position.x,
                            height: constrainedY - position.y
                        )
                    }
                    .onEnded { value in
                        // Apply drag to position and reset drag offset
                        let currentWidth = isExpanded ? expandedSize.width : collapsedSize.width
                        let currentHeight = isExpanded ? expandedSize.height : collapsedSize.height

                        // Calculate new position
                        var newX = position.x + dragOffset.width
                        var newY = position.y + dragOffset.height

                        // Strict boundaries - keep entire panel on screen
                        // If history menu is showing, account for it on the left side
                        let leftExtension = showHistoryMenu ? (historyMenuWidth + 8) : 0
                        let minX = currentWidth / 2 + leftExtension
                        let maxX = geometry.size.width - currentWidth / 2
                        let minY = currentHeight / 2
                        let maxY = geometry.size.height - currentHeight / 2

                        newX = min(max(newX, minX), maxX)
                        newY = min(max(newY, minY), maxY)

                        withAnimation(.spring(response: 0.3)) {
                            position = CGPoint(x: newX, y: newY)
                            dragOffset = .zero
                        }
                    }
            )
            .onAppear {
                // Store screen size for reset function
                screenSize = geometry.size

                // Position in top-left corner initially, ensuring it stays on screen
                let currentWidth = isExpanded ? expandedSize.width : collapsedSize.width
                let currentHeight = isExpanded ? expandedSize.height : collapsedSize.height

                // Calculate safe position from screen edges (top-left)
                let padding: CGFloat = 20

                // Position using absolute coordinates (top-left corner)
                var x = currentWidth / 2 + padding
                var y = currentHeight / 2 + padding

                // Apply strict boundaries
                let minX = currentWidth / 2
                let maxX = geometry.size.width - currentWidth / 2
                let minY = currentHeight / 2
                let maxY = geometry.size.height - currentHeight / 2

                x = min(max(x, minX), maxX)
                y = min(max(y, minY), maxY)

                position = CGPoint(x: x, y: y)
                dragOffset = .zero
            }
        }
        .sheet(isPresented: $showHistory) {
            CritiqueHistoryView(critiqueHistory: critiqueHistory)
        }
    }

    private var displayedFeedback: String {
        if !critiqueHistory.isEmpty && selectedHistoryIndex < critiqueHistory.count {
            return critiqueHistory[selectedHistoryIndex].feedback
        }
        return feedback ?? ""
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: date, relativeTo: Date())

        // Also show absolute time for clarity
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .short
        timeFormatter.timeStyle = .short

        return "\(relative) • \(timeFormatter.string(from: date))"
    }

    private func resetPosition() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            // Reset to default top-left position
            let currentWidth = isExpanded ? expandedSize.width : collapsedSize.width
            let currentHeight = isExpanded ? expandedSize.height : collapsedSize.height

            let padding: CGFloat = 20

            var x = currentWidth / 2 + padding
            var y = currentHeight / 2 + padding

            // Apply strict boundaries
            let minX = currentWidth / 2
            let maxX = screenSize.width - currentWidth / 2
            let minY = currentHeight / 2
            let maxY = screenSize.height - currentHeight / 2

            x = min(max(x, minX), maxX)
            y = min(max(y, minY), maxY)

            position = CGPoint(x: x, y: y)
            dragOffset = .zero
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
