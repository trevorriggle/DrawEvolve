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
    /// Called when the user taps Continue Drawing. The CANVAS COVER
    /// IS NOT HOSTED HERE — it's at GalleryView. Reason: this view
    /// gets rebuilt every time a storage publish ripples through
    /// GalleryView, and when a SwiftUI view is rebuilt, any cover
    /// modifiers attached TO it are torn down. The canvas cover
    /// would die mid-rename. By having GalleryView own the cover
    /// (its own state, its own modifier), the canvas survives any
    /// number of detail-view rebuilds. This view just signals
    /// intent; the gallery handles presentation.
    let onContinueDrawing: () -> Void
    @State private var drawingContext: DrawingContext
    @State private var showDeleteAlert = false
    @State private var fullImageData: Data?
    @State private var isLoadingImage = true
    /// Editable copy of the drawing's title. INTENTIONALLY a @Binding
    /// owned by GalleryView, not @State here. Reason: every storage
    /// publish (rename PATCH, auto-save in canvas, fetch) re-renders
    /// GalleryView, which re-evaluates the .fullScreenCover content
    /// closure, which rebuilds this view. With @State the
    /// State(initialValue: drawing.title) in init would reset the
    /// typed text back to the snapshot title on every rebuild —
    /// visible symptom: Done wipes the user's typed name. With
    /// @Binding to a parent @State that doesn't get rebuilt, the
    /// typed text survives.
    @Binding var editedTitle: String
    @State private var isSavingTitle = false
    @FocusState private var titleFocused: Bool
    /// Critique IDs that the user has tapped "Read full critique" on.
    /// Per-entry so multiple critiques can be expanded independently.
    @State private var expandedCritiqueIDs: Set<UUID> = []
    // INTENTIONALLY NOT @ObservedObject. CloudDrawingStorageManager is a
    // global singleton whose @Published mutations (drawings array,
    // isLoading flag, pendingUploadCount, etc.) fire constantly:
    //   • Whenever the auto-save timer in DrawingCanvasView ticks
    //     a successful save while the canvas cover is presenting,
    //     drawings publishes, the detail view re-renders, the
    //     .fullScreenCover content closure re-evaluates, and
    //     SwiftUI fails to preserve DrawingCanvasView's identity
    //     even with .id(drawing.id). Net visible effect: canvas
    //     appears, immediately bounces back to the detail view.
    //   • Same story for renameDrawing's own publish — the rename
    //     cascade fed itself back into a re-render loop.
    //   • storage manager's `isLoading` toggling during the
    //     loadFullImage round-trip caused two extra re-renders on
    //     view appear alone.
    //
    // The detail view's body reads ZERO storage-manager state
    // (it only CALLS methods on the manager — loadFullImage,
    // renameDrawing, deleteDrawing). So observing the publisher
    // is purely a re-render churn source with no UI value.
    // Holding a plain `let` reference still lets us call methods;
    // SwiftUI no longer redraws when the singleton publishes.
    private let storageManager = CloudDrawingStorageManager.shared

    init(drawing: Drawing, editedTitle: Binding<String>, onContinueDrawing: @escaping () -> Void) {
        self.drawing = drawing
        self._editedTitle = editedTitle
        self.onContinueDrawing = onContinueDrawing
        _drawingContext = State(initialValue: drawing.context ?? DrawingContext())
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
                            // submitLabel(.return) — the keyboard's
                            // primary key shows "return" and just
                            // collapses the keyboard. NO .onSubmit
                            // handler. The reason: a Done/.onSubmit
                            // committing the rename was the source of
                            // every race we hit in this view. Done
                            // dismisses the keyboard, which fires a
                            // focus-state change, which kicks off
                            // SwiftUI re-renders, which collide with
                            // the async storage mutation kicked off
                            // by the commit. Decoupling those is the
                            // whole game: typing edits the local
                            // binding live; committing only happens
                            // on explicit user action (Save and Close
                            // in the toolbar, or Continue Drawing
                            // below).
                            .submitLabel(.return)
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
                            // Await the rename commit so the storage
                            // cascade settles while the detail cover
                            // is still on screen. Then signal the
                            // gallery to take over and present the
                            // canvas cover from there. Doing the
                            // canvas presentation from this view's
                            // own .fullScreenCover would tie the
                            // cover's lifetime to this view, and
                            // this view gets rebuilt on every
                            // storage publish. Letting GalleryView
                            // own the canvas cover puts it on a
                            // stable host that survives detail-view
                            // rebuilds.
                            Task { @MainActor in
                                await performCommitTitleChange()
                                onContinueDrawing()
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
                    // Save and Close is the canonical "I'm done with
                    // this drawing" action. It awaits the rename
                    // commit (no-op if the title is unchanged), then
                    // dismisses the view. Dismiss happens AFTER the
                    // commit completes, so the storage cascade that
                    // a successful rename publishes lands while the
                    // cover is still presenting (no canvas to remount,
                    // no fullScreenCover ripple). By the time the
                    // cover dismisses, everything is settled.
                    Button("Save and Close") {
                        Task { @MainActor in
                            await performCommitTitleChange()
                            dismiss()
                        }
                    }
                }
            }
        }
        .task {
            isLoadingImage = true
            fullImageData = try? await storageManager.loadFullImage(for: drawing.id)
            isLoadingImage = false
        }
        // NO .fullScreenCover for canvas here. The canvas cover is
        // hosted by GalleryView (.fullScreenCover(item: $canvasDrawing))
        // because detail view rebuilds on every storage publish and
        // would take any modifiers attached to it down on each rebuild.
        // See onContinueDrawing in init.
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

        HStack(alignment: .top, spacing: 12) {
            // Thumbnail of the drawing's state at the time this critique
            // was generated. Sits across from the bullets so a user can
            // scan a finding while seeing the visual context that prompted
            // it. Muted placeholder for pre-snapshot legacy entries and
            // any row whose worker promote step failed.
            CritiqueSnapshotThumbnail(entry: entry, size: 72)

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
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(12)
    }

    /// Commit the rename to local cache + cloud. No-ops if the title
    /// is empty / unchanged / already in flight. Called only from
    /// explicit user actions (Save and Close in the toolbar,
    /// Continue Drawing below) — never from .onSubmit or focus-loss,
    /// because both of those fired during keyboard-dismiss transitions
    /// and raced the SwiftUI re-render cycle. Awaitable so callers
    /// can ordering-guarantee the storage cascade settles before
    /// doing anything else (presenting canvas, dismissing the view).
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
        ),
        editedTitle: .constant("Portrait Study"),
        onContinueDrawing: {}
    )
}
