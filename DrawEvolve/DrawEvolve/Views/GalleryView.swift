//
//  GalleryView.swift
//  DrawEvolve
//
//  Gallery view displaying user's saved drawings.
//

import SwiftUI

struct GalleryView: View {
    @ObservedObject private var storageManager = DrawingStorageManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showNewDrawing = false
    @State private var showPromptFirst = false
    @State private var selectedDrawing: Drawing?
    @State private var showDeleteAlert = false
    @State private var drawingToDelete: Drawing?
    @State private var drawingContext = DrawingContext()
    @State private var canvasID = UUID() // Force new canvas instance

    // Debug: Clear all drawings
    @State private var showClearAllAlert = false

    let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                if storageManager.isLoading && storageManager.drawings.isEmpty {
                    ProgressView("Loading your drawings...")
                } else if storageManager.drawings.isEmpty {
                    emptyStateView
                } else {
                    drawingsGridView
                }
            }
            .navigationTitle("My Drawings")
            .navigationBarTitleDisplayMode(.large)
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
                    .foregroundColor(.secondary)
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
                    DrawingCard(drawing: drawing) {
                        drawingToDelete = drawing
                        showDeleteAlert = true
                    }
                    .onTapGesture {
                        selectedDrawing = drawing
                    }
                }
            }
            .padding()
        }
        .sheet(item: $selectedDrawing) { drawing in
            DrawingDetailView(drawing: drawing)
        }
    }
}

// MARK: - Drawing Card

struct DrawingCard: View {
    let drawing: Drawing
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Drawing thumbnail
            ZStack(alignment: .topTrailing) {
                if let uiImage = UIImage(data: drawing.imageData) {
                    GeometryReader { geometry in
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: 200)
                            .clipped()
                    }
                    .frame(height: 200)
                    .background(Color.white) // White background for dark mode
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.2), lineWidth: 2)
                    )
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 200)
                        .cornerRadius(12)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                        )
                }

                // Feedback badge
                if drawing.feedback != nil {
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
                    .padding(8)
                }
            }

            // Title and metadata
            VStack(alignment: .leading, spacing: 4) {
                Text(drawing.title)
                    .font(.headline)
                    .lineLimit(1)

                Text(drawing.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

#Preview {
    GalleryView()
}
