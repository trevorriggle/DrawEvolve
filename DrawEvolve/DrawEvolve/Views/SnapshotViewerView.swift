//
//  SnapshotViewerView.swift
//  DrawEvolve
//
//  Phase 2 of drawing version history — the read-only time-machine view.
//
//  Tapping a critique entry in EvolutionStudioWallView presents this as a
//  .fullScreenCover. Renders the snapshot's composite JPEG via a signed URL
//  with native SwiftUI pinch + pan; no MetalCanvasView, no layer hydration,
//  no read-only flag plumbing. Phase 3+ (fork) will use the full layered
//  manifest; for "see what my drawing looked like at this critique," a flat
//  composite is enough.
//
//  Why JPEG-only (not Metal hydration): see proposal §4 / Area 4. The
//  trade-off is no per-layer inspection in time-machine view (acceptable
//  for v2; fork in phase 3 will hydrate fully).
//

import SwiftUI

struct SnapshotViewerView: View {
    let snapshot: SnapshotPointer
    let critiqueTimestamp: Date
    let onDismiss: () -> Void

    @State private var compositeImage: UIImage?
    @State private var loadError: String?

    // Pinch: committed scale after gesture end + live magnification during.
    @State private var committedScale: CGFloat = 1.0
    @GestureState private var liveMagnification: CGFloat = 1.0

    // Pan: committed offset after gesture end + live translation during.
    @State private var committedOffset: CGSize = .zero
    @GestureState private var liveTranslation: CGSize = .zero

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 6.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack {
                banner
                Spacer()
            }
        }
        .task { await loadComposite() }
    }

    // MARK: - Content (image / loading / error)

    @ViewBuilder
    private var content: some View {
        if let image = compositeImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(committedScale * liveMagnification)
                .offset(
                    x: committedOffset.width + liveTranslation.width,
                    y: committedOffset.height + liveTranslation.height
                )
                .gesture(SimultaneousGesture(magnificationGesture, dragGesture))
                .onTapGesture(count: 2) { resetTransform() }
                .accessibilityLabel("Snapshot of drawing")
        } else if let loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(loadError)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
        } else {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        }
    }

    // MARK: - Banner

    private var banner: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(critiqueTimestamp, format: .dateTime.month().day().hour().minute())
                    .font(.subheadline.weight(.semibold))
                Text("Snapshot · editing disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Return to current", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: - Gestures

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .updating($liveMagnification) { value, state, _ in
                state = value
            }
            .onEnded { value in
                let next = (committedScale * value).clamped(to: minScale...maxScale)
                committedScale = next
                if next == minScale {
                    // Snap pan back to center when fully zoomed out.
                    committedOffset = .zero
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .updating($liveTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                // Only commit pan when zoomed in — at 1× the image is
                // already scaledToFit, so panning doesn't reveal anything.
                guard committedScale > minScale else { return }
                committedOffset.width += value.translation.width
                committedOffset.height += value.translation.height
            }
    }

    private func resetTransform() {
        withAnimation(.easeOut(duration: 0.18)) {
            committedScale = 1.0
            committedOffset = .zero
        }
    }

    // MARK: - Load

    private func loadComposite() async {
        do {
            guard let client = SupabaseManager.shared.client else {
                await MainActor.run { loadError = "Couldn't authenticate" }
                return
            }
            let signed = try await client.storage
                .from("drawings")
                .createSignedURL(path: snapshot.compositePath, expiresIn: 3600)
            let (data, _) = try await URLSession.shared.data(from: signed)
            guard let image = UIImage(data: data) else {
                await MainActor.run { loadError = "Couldn't decode snapshot" }
                return
            }
            await MainActor.run { compositeImage = image }
        } catch {
            print("[SnapshotViewerView] load failed: \(error.localizedDescription)")
            await MainActor.run { loadError = "Couldn't load snapshot" }
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

#Preview("Loaded state") {
    SnapshotViewerView(
        snapshot: SnapshotPointer(
            manifestPath: "user/drawing/snapshots/1/manifest.json",
            compositePath: "user/drawing/snapshots/1/composite.jpg",
            thumbPath: "user/drawing/snapshots/1/thumb.jpg",
            formatVersion: 1,
            layerCount: 4,
            totalBytes: 8_388_608
        ),
        critiqueTimestamp: Date().addingTimeInterval(-3600 * 26),
        onDismiss: {}
    )
}
