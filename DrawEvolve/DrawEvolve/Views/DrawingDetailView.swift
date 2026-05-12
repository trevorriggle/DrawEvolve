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
    /// Critique IDs that the user has tapped "Read full critique" on.
    /// Per-entry so multiple critiques can be expanded independently.
    @State private var expandedCritiqueIDs: Set<UUID> = []
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
                            .onSubmit { commitTitleChange() }
                            // Intentionally NO focus-loss commit. The
                            // earlier version fired commitTitleChange()
                            // from .onChange(of: titleFocused) when the
                            // field lost focus — but iOS dismisses the
                            // keyboard on any tap outside the field,
                            // including a tap on the Continue Drawing
                            // button. That dismissal triggered a commit
                            // Task whose subsequent storage mutation
                            // raced the fullScreenCover presentation and
                            // caused the canvas to flash open and
                            // immediately collapse back to the detail
                            // view. Done on the keyboard is now the only
                            // commit trigger. If you dismiss the keyboard
                            // without tapping Done, the typed text stays
                            // in the field but doesn't persist — that's
                            // the correct semantics: you didn't confirm.

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

                        // AI Feedback Summary — bulleted recap per critique
                        // instead of the full wall of text. The full body
                        // stays one tap away behind "Read full critique."
                        // Full text still lives in the floating critique
                        // panel; this view is the at-a-glance recap.
                        if !drawing.critiqueHistory.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                Label("AI Feedback Summary", systemImage: "sparkles")
                                    .font(.headline)
                                    .foregroundColor(.accentColor)

                                // Newest first
                                ForEach(drawing.critiqueHistory.reversed()) { entry in
                                    critiqueSummaryCard(for: entry)
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

    /// One card per critique in the summary panel. Renders the
    /// bulleted summary block extracted by `CritiqueSummary.parse`,
    /// or a first-paragraph fallback for critiques generated before
    /// the worker started emitting the block. A "Read full critique"
    /// button reveals the full body inline (with the summary block
    /// itself stripped, since the bullets above already cover it).
    @ViewBuilder
    private func critiqueSummaryCard(for entry: CritiqueEntry) -> some View {
        let parsed = CritiqueSummary.parse(entry.feedback)
        let isExpanded = expandedCritiqueIDs.contains(entry.id)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundColor(.primary)
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.primary)
            }

            Divider()

            if parsed.hasExplicitSummary {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(parsed.bullets.enumerated()), id: \.offset) { _, bullet in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .foregroundColor(.accentColor)
                                .fontWeight(.bold)
                            Text(bullet)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                // Older critique without the explicit summary block —
                // fall back to a first-paragraph excerpt so the card
                // still gives the user something at-a-glance.
                Text(CritiqueSummary.fallbackExcerpt(from: parsed.body))
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Full-critique expansion. Renders below the bullets when
            // the user taps "Read full critique." Each entry tracks
            // its own state via `expandedCritiqueIDs` so multiple
            // critiques can be open at once.
            if isExpanded {
                Divider()
                FormattedMarkdownView(text: parsed.body)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedCritiqueIDs.remove(entry.id)
                    } else {
                        expandedCritiqueIDs.insert(entry.id)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                    Text(isExpanded ? "Hide full critique" : "Read full critique")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(12)
    }

    /// Saves the edited title to the cloud. No-ops if the title is
    /// empty, unchanged, or a previous commit is already in flight.
    /// Called from `.onSubmit` (Done on the keyboard) AND from
    /// `.onChange(of: titleFocused)` when the field loses focus.
    /// Tapping Done dismisses the keyboard which ALSO triggers
    /// the focus-loss path, so both modifiers can fire in quick
    /// succession — the `isSavingTitle` guard collapses the
    /// duplicate into one upload.
    private func commitTitleChange() {
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty input — revert to the original title since a blank
        // name would render the gallery row as a void.
        if trimmed.isEmpty {
            editedTitle = drawing.title
            return
        }
        // Unchanged from the originally-loaded title — nothing to do.
        if trimmed == drawing.title { return }
        // Re-entrance guard. Without this, .onSubmit + .onChange
        // (focus loss when Done dismisses the keyboard) fire two
        // commits in succession that race in the storage manager.
        if isSavingTitle { return }

        print("🖊  Title rename: '\(drawing.title)' → '\(trimmed)' (id=\(drawing.id))")
        isSavingTitle = true
        Task { @MainActor in
            defer { isSavingTitle = false }
            do {
                try await storageManager.updateDrawing(id: drawing.id, title: trimmed)
                print("✅ Title rename committed locally + queued for cloud upload")
                // Keep `editedTitle` as the user typed it on success.
                // Do not reset to anything else here — the prior version
                // reset to `drawing.title` on error, which was the source
                // of the "Done reverts what I typed" bug when the
                // storage manager threw transiently.
            } catch {
                // Cloud write failed. DON'T revert the field — the user's
                // intent stays in the binding so they can hit Done again
                // (or the storage manager's retry queue picks it up on
                // network recovery). Reverting was actively confusing:
                // the user saw their typed text disappear and assumed
                // the rename feature was broken.
                print("⚠️ Title rename failed (kept local edit): \(type(of: error)) — \(error)")
            }
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
