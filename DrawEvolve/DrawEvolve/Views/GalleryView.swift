//
//  GalleryView.swift
//  DrawEvolve
//
//  Gallery view displaying user's saved drawings.
//
//  ARCHITECTURE NOTE — DO NOT COLLAPSE BACK INTO ONE STRUCT
//
//  This file is split intentionally:
//
//    • `GalleryView` is a THIN SHELL that owns the `@State` for the
//      .fullScreenCover triggers (selectedDrawing, canvasDrawing,
//      showPromptFirst, showNewDrawing) and the cover modifiers
//      themselves. It does NOT observe `CloudDrawingStorageManager`
//      or any other publisher.
//
//    • `GalleryContent` is the body of the gallery — tabs, grid,
//      prompts list, toolbar, alerts. It observes storageManager and
//      re-renders on every @Published mutation.
//
//  Why the split is non-negotiable: any time the gallery's body
//  re-rendered (which it did on every storage publish — saves,
//  renames, auto-save ticks, fetches), the .fullScreenCover content
//  closures re-evaluated, and SwiftUI's identity tracking for views
//  inside modifier closures isn't reliable enough to preserve the
//  underlying UIView. The detail view's @State reset on rebuild
//  (wiping the user's typed rename), and DrawingCanvasView's
//  MTKView got torn down mid-load ("renderer not initialized" error
//  spam). Hosting the covers on a shell that only re-renders on
//  its own @State eliminates the re-evaluation cycle entirely — the
//  covers' content is stable for the lifetime of the presented
//  drawing.
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

// MARK: - GalleryView (shell)

struct GalleryView: View {
    // Cover-related state lives here — on a view that doesn't
    // observe any publisher. The shell only re-renders when one of
    // these @States changes, which only happens on user action
    // (tap a card, tap +, etc.) or on programmatic transition.
    @State private var selectedDrawing: Drawing?
    @State private var canvasDrawing: Drawing?
    @State private var detailEditedTitle: String = ""
    @State private var showNewDrawing = false
    @State private var showPromptFirst = false
    @State private var canvasID = UUID()
    @State private var drawingContext = DrawingContext()

    var body: some View {
        GalleryContent(
            selectedDrawing: $selectedDrawing,
            detailEditedTitle: $detailEditedTitle,
            showPromptFirst: $showPromptFirst
        )
        .fullScreenCover(item: $selectedDrawing) { drawing in
            DrawingDetailView(
                drawing: drawing,
                editedTitle: $detailEditedTitle,
                onContinueDrawing: {
                    // Dismiss the detail cover, then hand off to the
                    // canvas cover on this same shell. Sequential
                    // (not nested) — the 350ms pause lets the detail
                    // dismiss animation complete so SwiftUI doesn't
                    // trip over two covers transitioning at once.
                    let drawingToOpen = drawing
                    selectedDrawing = nil
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        canvasDrawing = drawingToOpen
                    }
                }
            )
            .id(drawing.id)
        }
        .fullScreenCover(item: $canvasDrawing) { drawing in
            DrawingCanvasView(context: $drawingContext, existingDrawing: drawing)
                .id(drawing.id)
        }
        .fullScreenCover(isPresented: $showPromptFirst) {
            PromptInputView(context: $drawingContext, isPresented: $showPromptFirst)
        }
        .fullScreenCover(isPresented: $showNewDrawing) {
            DrawingCanvasView(context: $drawingContext, existingDrawing: nil)
                .id(canvasID)
        }
        .onChange(of: showPromptFirst) { _, newValue in
            if !newValue && drawingContext.isComplete {
                showNewDrawing = true
            }
        }
        .onChange(of: showNewDrawing) { _, newValue in
            if !newValue {
                drawingContext = DrawingContext()
                canvasID = UUID()
            }
        }
    }
}

// MARK: - GalleryContent (the actual body)

/// Holds everything that re-renders on storage publishes — the grid,
/// tabs, prompts list, toolbar, alerts. Separated from `GalleryView`
/// so the cover modifiers up there stay stable across re-renders here.
/// See the file header for the full rationale.
private struct GalleryContent: View {
    private enum Tab: Hashable { case drawings, prompts, evolution }

    @ObservedObject private var storageManager = CloudDrawingStorageManager.shared
    @ObservedObject private var customPromptManager = CustomPromptManager.shared
    @Environment(\.dismiss) private var dismiss

    // Bindings up to the shell — these are how the content view
    // triggers cover presentations. Setting selectedDrawing /
    // showPromptFirst here flips a value that the shell's
    // .fullScreenCover modifier picks up.
    @Binding var selectedDrawing: Drawing?
    @Binding var detailEditedTitle: String
    @Binding var showPromptFirst: Bool

    // State internal to the content view — sheets, alerts, tab
    // selection. Nothing here triggers a cover at the shell level.
    @State private var showPromptEditor = false
    @State private var editingPrompt: CustomPrompt?
    /// iPhone-only prompt-editor state. Lives separately from the
    /// iPad path because `.sheet(isPresented:)` with a captured
    /// @State reads stale on iPhone — see commit b862687.
    @State private var iPhoneEditingPrompt: CustomPrompt?
    @State private var iPhoneShowNewPrompt = false

    @State private var selectedTab: Tab = .drawings
    @State private var showDeleteAlert = false
    @State private var drawingToDelete: Drawing?
    @State private var showClearAllAlert = false

    // Persisted across launches via UserDefaults. OpenAIManager reads
    // the same key directly when assembling each request, so the
    // worker sees the user's current selection without view-layer
    // state propagation.
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

    private var padTabStrip: some View {
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
            PromptEditView(editing: editingPrompt)
        }
        .sheet(item: $iPhoneEditingPrompt) { prompt in
            PromptEditView(editing: prompt)
        }
        .sheet(isPresented: $iPhoneShowNewPrompt) {
            PromptEditView(editing: nil)
        }
    }

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
    //
    // NO .fullScreenCover here. The detail / canvas covers are
    // hosted by GalleryView (the shell). This grid just sets
    // `selectedDrawing` via the binding when a card is tapped; the
    // shell's modifier picks that up and presents the cover.

    private var drawingsGridView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(storageManager.drawings) { drawing in
                    Button(action: {
                        detailEditedTitle = drawing.title
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
