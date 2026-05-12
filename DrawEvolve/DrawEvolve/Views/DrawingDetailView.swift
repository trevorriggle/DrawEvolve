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
    @State private var fullImageData: Data?
    @State private var isLoadingImage = true
    /// Editable copy of the drawing's title. Bound to the title text
    /// field at the top of the view; commits to the cloud on Done /
    /// focus-loss via `commitTitleChange()`.
    @State private var editedTitle: String
    @State private var isSavingTitle = false
    @FocusState private var titleFocused: Bool
    @ObservedObject private var storageManager = CloudDrawingStorageManager.shared

    init(drawing: Drawing) {
        self.drawing = drawing
        _drawingContext = State(initialValue: drawing.context ?? DrawingContext())
        _editedTitle = State(initialValue: drawing.title)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Scrollable content area
                ScrollView {
                    VStack(spacing: 24) {
                        // Editable title bar at the top of the scroll. Tapping
                        // inside puts the field into edit mode; the keyboard's
                        // Done button (or losing focus) commits the new name to
                        // the database. SwiftUI's keyboard avoidance keeps the
                        // field visible above the keyboard since it's at the
                        // top of the scroll content.
                        TextField("Drawing name", text: $editedTitle)
                            .font(.title2.weight(.semibold))
                            .textFieldStyle(.plain)
                            .submitLabel(.done)
                            .focused($titleFocused)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .cornerRadius(12)
                            .overlay(alignment: .trailing) {
                                if isSavingTitle {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .padding(.trailing, 14)
                                }
                            }
                            .onSubmit { Task { await commitTitleChange() } }
                            .onChange(of: titleFocused) { focused in
                                // Commit on blur too, so a user who taps
                                // away from the field without hitting Done
                                // still saves their rename.
                                if !focused { Task { await commitTitleChange() } }
                            }

                        // Drawing image — bytes live in cloud Storage now; the
                        // storage manager checks the disk cache, then falls back
                        // to a signed-URL download.
                        Group {
                            if let data = fullImageData, let uiImage = UIImage(data: data) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                    .background(Color(uiColor: .secondarySystemBackground))
                                    .cornerRadius(12)
                                    .shadow(radius: 2)
                            } else if isLoadingImage {
                                ProgressView()
                                    .frame(maxWidth: .infinity, minHeight: 240)
                                    .background(Color(uiColor: .secondarySystemBackground))
                                    .cornerRadius(12)
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "photo")
                                        .font(.largeTitle)
                                        .foregroundColor(.secondary)
                                    Text("Image unavailable offline")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 240)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .cornerRadius(12)
                            }
                        }

                        // AI Feedback History
                        if !drawing.critiqueHistory.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                Label("AI Feedback History", systemImage: "sparkles")
                                    .font(.headline)
                                    .foregroundColor(.accentColor)

                                // Show all critiques in reverse chronological order (newest first)
                                ForEach(drawing.critiqueHistory.reversed()) { entry in
                                    VStack(alignment: .leading, spacing: 12) {
                                        // Timestamp
                                        HStack {
                                            Image(systemName: "clock")
                                                .font(.caption)
                                                .foregroundColor(.primary)
                                            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption)
                                                .foregroundColor(.primary)
                                        }

                                        Divider()

                                        // Feedback content
                                        FormattedMarkdownView(text: entry.feedback)
                                    }
                                    .padding()
                                    .background(Color(uiColor: .secondarySystemBackground))
                                    .cornerRadius(12)
                                }
                            }
                        } else {
                            // No feedback available
                            VStack(spacing: 12) {
                                Image(systemName: "sparkles.rectangle.stack")
                                    .font(.system(size: 40))
                                    .foregroundColor(.primary)

                                Text("No AI feedback yet")
                                    .font(.headline)
                                    .foregroundColor(.primary)

                                Text("Request feedback while working on this drawing to see it here")
                                    .font(.caption)
                                    .foregroundColor(.primary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(uiColor: .secondarySystemBackground))
                            .cornerRadius(12)
                        }
                    }
                    .padding()
                    .padding(.bottom, 90) // Space for sticky buttons
                }

                // Sticky action buttons at bottom
                VStack(spacing: 0) {
                    Divider()

                    HStack(spacing: 12) {
                        // Continue Drawing button
                        Button(action: {
                            showCanvas = true
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: "paintbrush.pointed.fill")
                                    .font(.system(size: 18))
                                Text("Continue Drawing")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }

                        // Delete button
                        Button(action: {
                            showDeleteAlert = true
                        }) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.white)
                                .frame(width: 56, height: 56)
                                .background(Color.red)
                                .cornerRadius(12)
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                }
            }
            // No navigationTitle — the editable text field at the top
            // of the scroll content IS the title. Keeping the inline
            // bar empty also leaves the toolbar's trailing Close button
            // legible against the chrome.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            isLoadingImage = true
            fullImageData = try? await storageManager.loadFullImage(for: drawing.id)
            isLoadingImage = false
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

    /// Saves the edited title to the cloud. No-ops if the title is
    /// empty or unchanged. Called from `.onSubmit` (Done on the
    /// keyboard) AND from `.onChange(of: titleFocused)` when the
    /// field loses focus (so a tap-elsewhere also saves the rename).
    /// Idempotent — repeated calls with the same value are cheap and
    /// just exit early.
    @MainActor
    private func commitTitleChange() async {
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Empty title — revert and bail. Don't push an empty
            // string to the database; it'd leave the row in an odd
            // state and the gallery row would render blank.
            editedTitle = drawing.title
            return
        }
        guard trimmed != drawing.title else { return }

        isSavingTitle = true
        defer { isSavingTitle = false }
        do {
            try await storageManager.updateDrawing(id: drawing.id, title: trimmed)
        } catch {
            // Cloud save failed — revert the local field so the user
            // doesn't think it stuck. The storage manager's NWPathMonitor
            // retry queue handles transient network drops; surfacing a
            // hard error here means something else went wrong (drawing
            // missing in memory, etc).
            print("⚠️ Title rename failed: \(error)")
            editedTitle = drawing.title
        }
    }
}

#Preview {
    DrawingDetailView(
        drawing: Drawing(
            id: UUID(),
            userId: UUID(),
            title: "Portrait Study",
            storagePath: "preview/portrait.jpg",
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
