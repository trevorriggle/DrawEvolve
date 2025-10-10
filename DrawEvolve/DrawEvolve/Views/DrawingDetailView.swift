//
//  DrawingDetailView.swift
//  DrawEvolve
//
//  Detail view showing a drawing with its AI feedback and context.
//

import SwiftUI

struct DrawingDetailView: View {
    let drawing: Drawing
    @Environment(\.dismiss) private var dismiss
    @State private var showCanvas = false
    @State private var drawingContext: DrawingContext
    @State private var showDeleteAlert = false
    @ObservedObject private var storageManager = DrawingStorageManager.shared

    init(drawing: Drawing) {
        self.drawing = drawing
        _drawingContext = State(initialValue: drawing.context ?? DrawingContext())
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Drawing image
                    if let uiImage = UIImage(data: drawing.imageData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .cornerRadius(12)
                            .shadow(radius: 2)
                    }

                    // Action buttons
                    HStack(spacing: 12) {
                        // Continue Drawing button
                        Button(action: {
                            showCanvas = true
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: "paintbrush.pointed.fill")
                                    .font(.system(size: 20))
                                Text("Continue Drawing")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                            .shadow(radius: 4)
                        }

                        // Delete button
                        Button(action: {
                            showDeleteAlert = true
                        }) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                                .frame(width: 56, height: 56)
                                .background(Color.red)
                                .cornerRadius(12)
                                .shadow(radius: 4)
                        }
                    }

                    // Drawing context (if available)
                    if let context = drawing.context {
                        VStack(alignment: .leading, spacing: 16) {
                            Label("Drawing Context", systemImage: "paintbrush.pointed.fill")
                                .font(.headline)
                                .foregroundColor(.accentColor)

                            VStack(alignment: .leading, spacing: 8) {
                                if !context.subject.isEmpty {
                                    InfoRow(label: "Subject", value: context.subject)
                                }
                                if !context.style.isEmpty {
                                    InfoRow(label: "Style", value: context.style)
                                }
                                if !context.artists.isEmpty {
                                    InfoRow(label: "Artists", value: context.artists)
                                }
                                if !context.techniques.isEmpty {
                                    InfoRow(label: "Techniques", value: context.techniques)
                                }
                                if !context.focus.isEmpty {
                                    InfoRow(label: "Focus", value: context.focus)
                                }
                            }
                            .padding()
                            .background(Color(uiColor: .secondarySystemBackground))
                            .cornerRadius(12)
                        }
                    }

                    // AI Feedback (if available)
                    if let feedback = drawing.feedback {
                        VStack(alignment: .leading, spacing: 16) {
                            Label("AI Feedback", systemImage: "sparkles")
                                .font(.headline)
                                .foregroundColor(.accentColor)

                            FormattedMarkdownView(text: feedback)
                                .padding()
                                .background(Color(uiColor: .secondarySystemBackground))
                                .cornerRadius(12)
                        }
                    } else {
                        // No feedback available
                        VStack(spacing: 12) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)

                            Text("No AI feedback yet")
                                .font(.headline)
                                .foregroundColor(.secondary)

                            Text("Request feedback while working on this drawing to see it here")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(uiColor: .secondarySystemBackground))
                        .cornerRadius(12)
                    }
                }
                .padding()
            }
            .navigationTitle(drawing.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showCanvas) {
            DrawingCanvasView(context: $drawingContext, existingDrawing: drawing)
        }
        .alert("Delete Drawing", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    try? await storageManager.deleteDrawing(id: drawing.id)
                    dismiss()
                }
            }
        } message: {
            Text("Are you sure you want to delete '\(drawing.title)'? This cannot be undone.")
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            Text(value)
                .font(.body)
        }
    }
}

#Preview {
    DrawingDetailView(
        drawing: Drawing(
            id: UUID(),
            userId: UUID(),
            title: "Portrait Study",
            imageData: Data(),
            createdAt: Date(),
            updatedAt: Date(),
            feedback: """
            Great work on your portrait! Your proportions are well-balanced.

            **Strengths:**
            - Good facial structure
            - Nice shading depth

            **Areas to improve:**
            - Soften shadow transitions
            - Adjust ear positioning
            """,
            context: DrawingContext(
                subject: "Portrait",
                style: "Realism",
                artists: "Rembrandt",
                techniques: "Chiaroscuro",
                focus: "Light and shadow"
            )
        )
    )
}
