//
//  GalleryView.swift
//  DrawEvolve
//
//  Gallery view displaying user's saved drawings.
//

import SwiftUI

// MARK: - Preset Voice Picker (data)

/// One row in the My Prompts list. ID strings MUST match the worker's
/// VALID_PRESET_IDS set (cloudflare-worker/index.js) — sending an unknown
/// ID gets the request rejected with 400. Display copy is iOS-only.
private struct PresetVoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
}

private let presetVoiceOptions: [PresetVoiceOption] = [
    .init(id: "studio_mentor",
          name: "Studio Mentor",
          description: "Honest, balanced critique grounded in elements and principles of art."),
    .init(id: "the_crit",
          name: "The Crit",
          description: "MFA-style peer review. Direct, probing, no padded reassurance."),
    .init(id: "fundamentals_coach",
          name: "Fundamentals Coach",
          description: "Drills proportion, value, perspective, and craft mechanics first."),
    .init(id: "renaissance_master",
          name: "Renaissance Master",
          description: "A Florentine workshop master, somewhere around 1503."),
]

struct GalleryView: View {
    /// Top-level sections of the gallery. `.drawings` is fully wired today;
    /// `.prompts` is the preset-voice picker (Commit C of the preset voices
    /// feature); `.evolution` is placeholder scaffolding for an upcoming
    /// feature.
    private enum Tab: Hashable { case drawings, prompts, evolution }

    @ObservedObject private var storageManager = CloudDrawingStorageManager.shared
    @ObservedObject private var customPromptManager = CustomPromptManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Sheet trigger for the bounded-knobs prompt editor. Used by the
    /// inline "Saved Prompts" section in myPromptsView so the user can
    /// author + save without descending into a sub-navigation.
    @State private var showPromptEditor = false
    @State private var editingPrompt: CustomPrompt?

    // iPhone-only prompt-editor state. Lives separately from
    // `editingPrompt` / `showPromptEditor` so the iPad path stays
    // bytes-identical. iPhone's `.sheet(isPresented:)` flow had a
    // SwiftUI closure-capture issue: the `editing:` argument was
    // captured stale, so tapping Edit on an existing prompt opened
    // the editor with empty fields (effectively creating a new
    // prompt). `.sheet(item:)` passes the value through the closure
    // parameter directly, sidestepping the capture problem.
    @State private var iPhoneEditingPrompt: CustomPrompt?
    @State private var iPhoneShowNewPrompt = false

    @State private var selectedTab: Tab = .drawings
    @State private var showNewDrawing = false
    @State private var showPromptFirst = false
    @State private var selectedDrawing: Drawing?
    @State private var showDeleteAlert = false
    @State private var drawingToDelete: Drawing?
    @State private var drawingContext = DrawingContext()
    @State private var canvasID = UUID() // Force new canvas instance

    // Debug: Clear all drawings
    @State private var showClearAllAlert = false

    // Persisted across launches via UserDefaults. OpenAIManager reads the same
    // key directly when assembling each request, so the worker sees the user's
    // current selection without view-layer state propagation.
    @AppStorage("selectedPresetID") private var selectedPresetID: String = "studio_mentor"

    let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if DeviceIdiom.isPhone {
                    phoneTabStrip
                } else {
                    padTabStrip
                }
                Group {
                    switch selectedTab {
                    case .drawings:
                        ZStack {
                            if storageManager.isLoading && storageManager.drawings.isEmpty {
                                ProgressView("Loading your drawings...")
                            } else if storageManager.drawings.isEmpty {
                                emptyStateView
                            } else {
                                drawingsGridView
                            }
                        }
                    case .prompts:
                        myPromptsView
                    case .evolution:
                        EvolutionView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // No .navigationTitle: the tab strip is the identifier. Toolbar
            // items (Close, +, debug Clear All) remain the only nav-bar
            // content.
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showPromptFirst = true
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                }

                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }

                // DEBUG ONLY: Clear all drawings button
                #if DEBUG
                ToolbarItem(placement: .bottomBar) {
                    Button(action: {
                        showClearAllAlert = true
                    }) {
                        Label("Clear All", systemImage: "trash.fill")
                            .foregroundColor(.red)
                    }
                }
                #endif
            }
            .task {
                await storageManager.fetchDrawings()
            }
            .refreshable {
                await storageManager.fetchDrawings()
            }
            .fullScreenCover(isPresented: $showPromptFirst) {
                PromptInputView(context: $drawingContext, isPresented: $showPromptFirst)
            }
            .fullScreenCover(isPresented: $showNewDrawing) {
                DrawingCanvasView(context: $drawingContext, existingDrawing: nil)
                    .id(canvasID) // Force completely new canvas instance
            }
            .onChange(of: showPromptFirst) { _, newValue in
                if !newValue && drawingContext.isComplete {
                    showNewDrawing = true
                }
            }
            .onChange(of: showNewDrawing) { _, newValue in
                // Reset everything for next drawing
                if !newValue {
                    drawingContext = DrawingContext()
                    canvasID = UUID() // Create fresh canvas next time
                }
            }
            .alert("Delete Drawing", isPresented: $showDeleteAlert, presenting: drawingToDelete) { drawing in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task {
                        try? await storageManager.deleteDrawing(id: drawing.id)
                    }
                }
            } message: { drawing in
                Text("Are you sure you want to delete '\(drawing.title)'?")
            }
            .alert("Clear All Drawings", isPresented: $showClearAllAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Clear All", role: .destructive) {
                    Task {
                        try? await storageManager.clearAllDrawings()
                    }
                }
            } message: {
                Text("This will permanently delete ALL drawings. This cannot be undone.")
            }
        }
    }

    // MARK: - Tab Strip — iPad
    //
    // Three large-title labels side-by-side, styled to match the original
    // .navigationTitle(.large) treatment that this strip replaced. Selection
    // is communicated by text color only — no pills, no backgrounds, no
    // borders. Selected = Color.accentColor (the app's blue), unselected =
    // .primary (the dark/black of a normal nav title).

    private var padTabStrip: some View {
        // Fixed 28pt inline gap (≈ one em at .largeTitle bold) between labels
        // and left-aligned within the available width — mirrors the original
        // .navigationTitle's leading anchor rather than centering across the
        // bar.
        HStack(alignment: .firstTextBaseline, spacing: 28) {
            tabButton(.drawings, label: "My Drawings")
            tabButton(.prompts, label: "My Prompts")
            tabButton(.evolution, label: "My Evolution")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Tab Strip — iPhone
    //
    // Segmented Picker. Three large-title labels would overflow / truncate
    // aggressively on a 375pt viewport, and the iPad strip's leading-anchor
    // .largeTitle treatment doesn't translate to the iPhone aesthetic
    // anyway. Short labels ("Drawings" / "Prompts" / "Evolution") on iPhone
    // — the "My ..." prefix is brand voice that earns its place at large
    // size on iPad but reads as redundant inside a segmented control.
    // iPad strip stays untouched in padTabStrip above.

    private var phoneTabStrip: some View {
        Picker("Section", selection: $selectedTab) {
            Text("Drawings").tag(Tab.drawings)
            Text("Prompts").tag(Tab.prompts)
            Text("Evolution").tag(Tab.evolution)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func tabButton(_ tab: Tab, label: String) -> some View {
        let isSelected = selectedTab == tab
        return Button(action: { selectedTab = tab }) {
            Text(label)
                .font(.largeTitle.weight(.bold))
                .foregroundColor(isSelected ? .accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Coming Soon Placeholder

    private func comingSoonView(icon: String, title: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 80))
                .foregroundColor(.secondary.opacity(0.5))

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Coming soon")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    // MARK: - My Prompts (preset voice picker)

    private var myPromptsView: some View {
        List {
            Section {
                ForEach(presetVoiceOptions) { preset in
                    Button {
                        selectedPresetID = preset.id
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.name)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(preset.description)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if selectedPresetID == preset.id {
                                Image(systemName: "checkmark")
                                    .font(.headline)
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("AI Critique Voice")
            } footer: {
                Text("This voice is used for every Get Feedback request. You can switch any time.")
            }

            // Bounded-knobs custom prompts — inlined into the My Prompts
            // tab so saved prompts show up directly here without
            // descending into a sub-navigation. Empty state surfaces a
            // "New Prompt" CTA; populated state lists each row with the
            // standard preset-selection check + swipe-to-edit/delete
            // affordances.
            Section {
                if customPromptManager.prompts.isEmpty {
                    Button {
                        if DeviceIdiom.isPhone {
                            iPhoneShowNewPrompt = true
                        } else {
                            editingPrompt = nil
                            showPromptEditor = true
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("New saved prompt")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text("Tune focus, tone, depth, and techniques")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    ForEach(customPromptManager.prompts) { prompt in
                        Button {
                            selectedPresetID = "custom:\(prompt.id.uuidString.lowercased())"
                        } label: {
                            savedPromptRow(prompt)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task {
                                    try? await customPromptManager.delete(id: prompt.id)
                                    if selectedPresetID == "custom:\(prompt.id.uuidString.lowercased())" {
                                        selectedPresetID = "studio_mentor"
                                    }
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                if DeviceIdiom.isPhone {
                                    iPhoneEditingPrompt = prompt
                                } else {
                                    editingPrompt = prompt
                                    showPromptEditor = true
                                }
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                    Button {
                        if DeviceIdiom.isPhone {
                            iPhoneShowNewPrompt = true
                        } else {
                            editingPrompt = nil
                            showPromptEditor = true
                        }
                    } label: {
                        Label("New saved prompt", systemImage: "plus.circle.fill")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("Your Saved Prompts")
            } footer: {
                if let err = customPromptManager.lastError {
                    Text(err).foregroundColor(.red)
                } else {
                    Text("Custom voices are synced across your devices via Supabase.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .task { await customPromptManager.refresh() }
        .refreshable { await customPromptManager.refresh() }
        .sheet(isPresented: $showPromptEditor) {
            // PromptEditView wraps itself in NavigationStack — nesting
            // it inside another one here produced overlapping toolbars
            // (Cancel + Save tap targets fired simultaneously, and
            // dismiss() raced the in-flight save Task → "prompts
            // weren't saving" symptom).
            PromptEditView(editing: editingPrompt)
        }
        // iPhone-only: edit flow uses .sheet(item:) so the prompt
        // value is passed through the closure parameter directly,
        // not captured from @State. The .sheet(isPresented:) +
        // captured-state pattern above was reading a stale
        // `editingPrompt` on iPhone — the closure ran before the
        // state update propagated, so tapping Edit opened the
        // editor with empty fields (`editing: nil`) and a Save
        // would create a duplicate prompt instead of patching the
        // existing one. iPad's path is unchanged.
        .sheet(item: $iPhoneEditingPrompt) { prompt in
            PromptEditView(editing: prompt)
        }
        .sheet(isPresented: $iPhoneShowNewPrompt) {
            PromptEditView(editing: nil)
        }
    }

    /// Compact row for a saved bounded-knobs prompt — name + a one-line
    /// summary of the set knobs, with a checkmark when this row is the
    /// currently-selected preset.
    private func savedPromptRow(_ prompt: CustomPrompt) -> some View {
        let presetID = "custom:\(prompt.id.uuidString.lowercased())"
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(prompt.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(savedPromptSummary(prompt.parameters))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if selectedPresetID == presetID {
                Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    private func savedPromptSummary(_ p: PromptParameters) -> String {
        var parts: [String] = []
        if let f = p.focus { parts.append(f.displayName) }
        if let t = p.tone, t != .balanced { parts.append(t.displayName) }
        if let d = p.depth, d != .standard { parts.append(d.displayName) }
        if let techniques = p.techniques, !techniques.isEmpty {
            parts.append("\(techniques.count) technique\(techniques.count == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "Default settings" : parts.joined(separator: " · ")
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 80))
                .foregroundColor(.secondary.opacity(0.5))

            VStack(spacing: 8) {
                Text("No Drawings Yet")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Tap the + button to create your first drawing")
                    .font(.body)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
            }

            Button(action: {
                showPromptFirst = true
            }) {
                Label("Create Drawing", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
        .padding()
    }

    // MARK: - Drawings Grid

    private var drawingsGridView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(storageManager.drawings) { drawing in
                    Button(action: {
                        selectedDrawing = drawing
                    }) {
                        DrawingCard(
                            drawing: drawing,
                            thumbnail: storageManager.thumbnailData(for: drawing.id)
                        ) {
                            drawingToDelete = drawing
                            showDeleteAlert = true
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding()
        }
        .fullScreenCover(item: $selectedDrawing) { drawing in
            // .id(drawing.id) anchors DrawingDetailView's SwiftUI
            // identity to the stable drawing UUID. GalleryView observes
            // storageManager and re-renders on every @Published mutation
            // (saves, renames, fetches, isLoading toggles). Each
            // re-render re-evaluates this content closure. Without
            // .id, SwiftUI was rebuilding DrawingDetailView from
            // scratch on those re-renders — fresh @State, so the
            // user's typed-but-not-yet-committed title got reset to
            // drawing.title (the snapshot from view init). Visible
            // symptom: type a name, hit Done, name vanishes back to
            // the original. With .id pinned to the immutable UUID,
            // SwiftUI preserves the view's identity across gallery
            // re-renders so @State (editedTitle, showCanvas, etc.)
            // survives.
            DrawingDetailView(drawing: drawing)
                .id(drawing.id)
        }
    }
}

// MARK: - Drawing Card

struct DrawingCard: View {
    let drawing: Drawing
    let thumbnail: Data?
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Drawing thumbnail — always square, fills the grid cell width.
            //
            // Previous layout used a `GeometryReader` with fixed 200pt height and
            // `.aspectRatio(.fill)` which silently cropped the image horizontally
            // whenever the grid cell was wider than 200pt (i.e. always on iPad
            // landscape). Saved images are square 2048² so a 1:1 aspect with
            // `.scaledToFill` on a square container produces no cropping at all.
            ZStack(alignment: .topTrailing) {
                Color.white
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(
                        Group {
                            if let thumbnail, let uiImage = UIImage(data: thumbnail) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Color.secondary.opacity(0.2)
                                    .overlay(
                                        Image(systemName: "photo")
                                            .font(.largeTitle)
                                            .foregroundColor(.primary)
                                    )
                            }
                        }
                    )
                    .clipped()
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.2), lineWidth: 2)
                    )

                // Overlay badges and buttons in a VStack at top-right
                VStack(alignment: .trailing, spacing: 8) {
                    // Delete button
                    Button(action: onDelete) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.red)
                            .clipShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())

                    // Feedback badge - show if there's any feedback or critique history
                    if drawing.feedback != nil || !drawing.critiqueHistory.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12))
                            Text("AI")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor)
                        .cornerRadius(8)
                    }
                }
                .padding(8)
            }

            // Title and metadata
            VStack(alignment: .leading, spacing: 4) {
                Text(drawing.title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundColor(.primary)

                Text(drawing.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.primary)
            }
        }
    }
}

#Preview {
    GalleryView()
}
