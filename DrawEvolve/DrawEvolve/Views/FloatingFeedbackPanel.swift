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
    @State private var isDragging = false
    @State private var showHistory = false
    @State private var showHistoryMenu = false
    @State private var selectedHistoryIndex = 0

    private let collapsedSize: CGSize = CGSize(width: 60, height: 60)
    private let expandedSize: CGSize = CGSize(width: 350, height: 500)
    private let historyMenuWidth: CGFloat = 200

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isExpanded, let feedbackText = feedback {
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
                                // Show timestamp of current feedback
                                if !critiqueHistory.isEmpty && selectedHistoryIndex < critiqueHistory.count {
                                    HStack {
                                        Image(systemName: "clock")
                                            .foregroundColor(.secondary)
                                            .font(.caption)
                                        Text(formatTimestamp(critiqueHistory[selectedHistoryIndex].timestamp))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text("\(selectedHistoryIndex + 1) of \(critiqueHistory.count)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
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
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color(uiColor: .secondarySystemBackground))

                                Divider()

                                // History list
                                ScrollView {
                                    VStack(spacing: 0) {
                                        ForEach(Array(critiqueHistory.enumerated()), id: \.element.id) { index, entry in
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
                                                            .foregroundColor(.secondary)
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

                                            if index < critiqueHistory.count - 1 {
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
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        // Update position in real-time WITHOUT animation for immediate response
                        // Use translation from start location to track drag
                        if !isDragging {
                            isDragging = true
                        }
                        position = value.location
                    }
                    .onEnded { value in
                        isDragging = false
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
