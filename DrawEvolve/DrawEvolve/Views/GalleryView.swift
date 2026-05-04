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
    @Environment(\.dismiss) private var dismiss

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
                tabStripView
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
                        // TODO: Implement My Evolution. Placeholder for visual scaffolding.
                        comingSoonView(icon: "chart.line.uptrend.xyaxis", title: "My Evolution")
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

    // MARK: - Tab Strip
    //
    // Three large-title labels side-by-side, styled to match the original
    // .navigationTitle(.large) treatment that this strip replaced. Selection
    // is communicated by text color only — no pills, no backgrounds, no
    // borders. Selected = Color.accentColor (the app's blue), unselected =
    // .primary (the dark/black of a normal nav title).

    private var tabStripView: some View {
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

            // Bounded-knobs custom prompts. Tapping the row pushes
            // PromptListView, which is the authoring surface for
            // focus/tone/depth/technique knobs (CUSTOMPROMPTSPLAN.md).
            Section {
                NavigationLink {
                    PromptListView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "wand.and.stars")
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Saved prompts")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text("Tune focus, tone, depth, and techniques")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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
            DrawingDetailView(drawing: drawing)
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
