//
//  CritiqueHistoryView.swift
//  DrawEvolve
//
//  View to display all critique history for a drawing.
//

import SwiftUI

struct CritiqueHistoryView: View {
    let critiqueHistory: [CritiqueEntry]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if critiqueHistory.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)

                        Text("No Critique History")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Request feedback to start building your critique history")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(critiqueHistory.reversed()) { entry in
                        CritiqueHistoryRow(entry: entry)
                    }
                }
            }
            .navigationTitle("Critique History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct CritiqueHistoryRow: View {
    let entry: CritiqueEntry

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: entry.timestamp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with timestamp
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.accentColor)
                    .font(.caption)

                Text(formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if let context = entry.context {
                    VStack(alignment: .trailing, spacing: 2) {
                        if !context.subject.isEmpty {
                            Text(context.subject)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if !context.style.isEmpty {
                            Text(context.style)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Divider()

            // Feedback content
            FormattedMarkdownView(text: entry.feedback)
                .textSelection(.enabled)
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    CritiqueHistoryView(critiqueHistory: [
        CritiqueEntry(
            feedback: """
            Great work on your portrait! Your proportions are well-balanced.

            **Strengths:**
            - Good facial structure
            - Nice shading depth

            **Areas to improve:**
            - Soften shadow transitions
            """,
            timestamp: Date().addingTimeInterval(-86400 * 2),
            context: DrawingContext(subject: "Portrait", style: "Realism")
        ),
        CritiqueEntry(
            feedback: """
            Excellent progress! I can see improvement in your shading technique.

            **What's better:**
            - Smoother transitions
            - Better depth perception

            **Keep working on:**
            - Highlights placement
            """,
            timestamp: Date(),
            context: DrawingContext(subject: "Portrait", style: "Realism")
        )
    ])
}
