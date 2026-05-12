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
                        // Continue Drawing button — AWAITS the rename
                        // commit before presenting the canvas. Without
                        // the await, the storageManager.drawings
                        // mutation that renameDrawing publishes after
                        // its PATCH lands DURING the canvas mount,
                        // which causes DrawingDetailView to re-render
                        // and the .fullScreenCover content to
                        // re-evaluate. SwiftUI isn't preserving
                        // DrawingCanvasView identity across that
                        // re-evaluation, so the canvas gets torn down
                        // and re-mounted (logs show 4× Coordinator
                        // init / MTKView create on a single button
                        // tap). Awaiting lets the cascade settle
                        // before showCanvas flips, so the canvas
                        // mounts exactly once.
                        Button(action: {
                            Task { @MainActor in
                                await performCommitTitleChange()
                                showCanvas = true
                            }
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
            // .id(drawing.id) anchors the canvas's SwiftUI identity to
            // the stable drawing UUID. Without this, every re-render
            // of DrawingDetailView (from @FocusState toggles, async
            // state mutations rippling up through loadExistingDrawing,
            // storageManager publishes, etc.) caused SwiftUI to treat
            // the canvas as a "new" view and tear it down + re-mount.
            // The logs showed 2–4 successive `Coordinator: Initialized`
            // / `MetalCanvasView: Creating MTKView` rounds on a single
            // Continue Drawing tap, and the visible symptom was the
            // canvas appearing briefly and bouncing back to the detail
            // view. Forcing identity = drawing.id (constant for this
            // view's lifetime) makes SwiftUI keep the canvas mounted
            // across all parent re-renders.
            DrawingCanvasView(context: $drawingContext, existingDrawing: drawing)
                .id(drawing.id)
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

    /// Fire-and-forget commit, called from `.onSubmit` (Done on the
    /// keyboard). Wraps `performCommitTitleChange` in a Task so the
    /// synchronous SwiftUI callback returns immediately. Continue
    /// Drawing awaits `performCommitTitleChange` directly instead so
    /// it can ordering-guarantee the storage cascade settles before
    /// presenting the canvas (otherwise the cover re-mounts the
    /// canvas repeatedly as the storage publishes ripple through
    /// DrawingDetailView).
    private func commitTitleChange() {
        Task { @MainActor in await performCommitTitleChange() }
    }

    /// The actual commit. No-ops if empty / unchanged / already in
    /// flight. Awaits the renameDrawing PATCH so the local cache
    /// AND the cloud row are in sync by the time this returns.
    @MainActor
    private func performCommitTitleChange() async {
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty input — revert to the original title since a blank
        // name would render the gallery row as a void.
        if trimmed.isEmpty {
            editedTitle = drawing.title
            return
        }
        // Unchanged from the originally-loaded title — nothing to do.
        if trimmed == drawing.title { return }
        // Re-entrance guard against rapid double-fires (e.g. Done
        // followed immediately by Continue Drawing).
        if isSavingTitle { return }

        print("🖊  Title rename: '\(drawing.title)' → '\(trimmed)' (id=\(drawing.id))")
        isSavingTitle = true
        defer { isSavingTitle = false }
        do {
            // Direct PATCH on the drawings row. The legacy
            // updateDrawing flow queues a flat-upload pending entry
            // and silently drops it for layered drawings (no
            // storagePath). renameDrawing does a single PostgREST
            // PATCH on title + updated_at — no Storage churn, no
            // upload queue.
            try await storageManager.renameDrawing(id: drawing.id, title: trimmed)
            print("✅ Title rename committed locally + cloud")
        } catch {
            // Cloud write failed. DON'T revert the field — the user's
            // intent stays in the binding so they can hit Done again
            // (or tap Continue Drawing, which awaits this method).
            print("⚠️ Title rename failed (kept local edit): \(type(of: error)) — \(error)")
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
