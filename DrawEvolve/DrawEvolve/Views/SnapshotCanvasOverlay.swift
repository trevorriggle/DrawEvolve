//
//  SnapshotCanvasOverlay.swift
//  DrawEvolve
//
//  Phase 2 in-canvas time-machine view. Renders the historical snapshot
//  composite at fit-canvas (centered, scaled to fit screen). Static —
//  no gestures, no transform inheritance from canvasState.
//
//  Per approved 2026-05-21 UX revision: tapping an old critique shows
//  the drawing exactly as it was, full and centered, nothing else. If
//  the user wants to zoom in on a detail, they exit snapshot mode first
//  (pick the latest entry, collapse the panel, or dismiss it).
//
//  Loads composite via CloudDrawingStorageManager.loadSnapshotComposite
//  with a read-through cache, so flipping between historical entries is
//  instant after first fetch.
//

import SwiftUI

struct SnapshotCanvasOverlay: View {
    let viewing: CanvasStateManager.SnapshotViewingState

    @State private var image: UIImage?
    @State private var loadError: String?

    var body: some View {
        ZStack {
            // Dim backdrop covers the live canvas while loading so the
            // user doesn't see in-progress work flash through on first
            // paint. Cache hits skip the void entirely (instant render).
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            content
        }
        // contentShape extends hit testing across the full overlay area
        // even where the Image hasn't drawn yet (e.g. while loading).
        // Combined with .allowsHitTesting(true) at the call site, this
        // ensures no touch leaks to MetalCanvasView underneath.
        .contentShape(Rectangle())
        .task(id: viewing.cacheKey) { await loadImage() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            // .scaledToFit() handles centering + letterboxing; the image
            // appears at fit-canvas scale regardless of the user's
            // current canvas viewport. The thinMaterial chip in
            // DrawingCanvasView sits in the same ZStack at top-leading
            // and visually floats over the image's top edge — by design.
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding(.top, 60)        // breathing room under the chip
                .padding(.bottom, 20)
                .padding(.horizontal, 16)
                .accessibilityLabel("Historical snapshot of drawing")
        } else if let loadError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.white.opacity(0.7))
                Text(loadError)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding()
        } else {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        }
    }

    @MainActor
    private func loadImage() async {
        // Cache hit first — instant when the user flips back to an entry
        // they've already viewed this session.
        if let cached = CloudDrawingStorageManager.shared.cachedSnapshotComposite(at: viewing.snapshot.compositePath) {
            image = cached
            return
        }
        do {
            let fetched = try await CloudDrawingStorageManager.shared
                .loadSnapshotComposite(at: viewing.snapshot.compositePath)
            image = fetched
        } catch {
            print("[SnapshotCanvasOverlay] load failed for \(viewing.snapshot.compositePath): \(error.localizedDescription)")
            loadError = "Couldn't load snapshot"
        }
    }
}

#Preview("Loading state") {
    SnapshotCanvasOverlay(
        viewing: CanvasStateManager.SnapshotViewingState(
            snapshot: SnapshotPointer(
                manifestPath: "u/d/snapshots/1/manifest.json",
                compositePath: "u/d/snapshots/1/composite.jpg",
                thumbPath:     "u/d/snapshots/1/thumb.jpg",
                formatVersion: 1,
                layerCount: 3,
                totalBytes: 5_242_880
            ),
            timestamp: Date().addingTimeInterval(-3600 * 26)
        )
    )
}
