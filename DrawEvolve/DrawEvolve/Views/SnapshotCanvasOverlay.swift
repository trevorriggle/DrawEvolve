//
//  SnapshotCanvasOverlay.swift
//  DrawEvolve
//
//  Drawing version history phase 2 — the in-canvas overlay that swaps
//  the live drawing for a historical snapshot composite when the user
//  picks an older critique entry in the floating feedback panel.
//
//  Replaces the (now-deleted in commit 13) SnapshotViewerView fullscreen
//  modal. Same job — display a snapshot composite with pinch + pan — but
//  rendered inline over MetalCanvasView in the DrawingCanvasView body
//  rather than as a separate screen.
//
//  The overlay sits above MetalCanvasView in the ZStack and uses
//  .allowsHitTesting(true) to block touches from reaching the Metal
//  canvas underneath — so brush/eraser/selection gestures can't mutate
//  the live drawing while the user is inspecting a historical state.
//  Pinch + pan are honored locally and written through to
//  canvasState.zoomScale / panOffset, so transforms persist on exit
//  (per proposal — trust the user even when they end up zoomed into
//  empty space).
//
//  Not yet wired into DrawingCanvasView — commit 12 places it in the
//  body. This file ships in isolation; verifiable via SwiftUI #Preview.
//

import SwiftUI

struct SnapshotCanvasOverlay: View {
    let viewing: CanvasStateManager.SnapshotViewingState
    @ObservedObject var canvasState: CanvasStateManager

    @State private var image: UIImage?
    @State private var loadError: String?

    // Live gesture state — committed back to canvasState on .onEnded.
    @GestureState private var liveMagnification: CGFloat = 1.0
    @GestureState private var liveTranslation: CGSize = .zero

    private let minScale: CGFloat = 0.25
    private let maxScale: CGFloat = 10.0

    var body: some View {
        ZStack {
            // Dim backdrop covers the live canvas while loading so the
            // user doesn't see their in-progress work flash through.
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
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(
                    x: canvasState.flipHorizontal ? -1 : 1,
                    y: canvasState.flipVertical ? -1 : 1
                )
                .rotationEffect(canvasState.canvasRotation)
                .scaleEffect(canvasState.zoomScale * liveMagnification)
                .offset(
                    x: canvasState.panOffset.x + liveTranslation.width,
                    y: canvasState.panOffset.y + liveTranslation.height
                )
                .gesture(magnificationGesture)
                .gesture(dragGesture)
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

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .updating($liveMagnification) { value, state, _ in
                state = value
            }
            .onEnded { value in
                let next = (canvasState.zoomScale * value).clamped(to: minScale...maxScale)
                canvasState.zoomScale = next
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .updating($liveTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                canvasState.panOffset.x += value.translation.width
                canvasState.panOffset.y += value.translation.height
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

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
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
        ),
        canvasState: CanvasStateManager()
    )
}
