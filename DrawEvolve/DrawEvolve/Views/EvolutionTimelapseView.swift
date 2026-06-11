//
//  EvolutionTimelapseView.swift
//  DrawEvolve
//
//  "Watch It Evolve" — a time-lapse of a drawing across its critique
//  history. Plays the per-critique snapshots (version-history phase 1/2
//  already persists a composite JPEG per critique) as a crossfade
//  sequence ending on the live canvas, and exports the same sequence as
//  a square H.264 video for the share sheet.
//
//  Data flow:
//    • Frames = critiqueHistory entries with a non-nil SnapshotPointer
//      (oldest → newest), fetched via the existing
//      loadSnapshotComposite(at:) path (NSCache-backed, 200 MB), plus
//      the live canvas image captured by the caller at present time.
//    • No new storage, no worker involvement — pure assembly of data
//      the version-history feature already persists.
//
//  Export:
//    • 1080×1080 H.264 .mp4, 30 fps. Each stage holds ~1.1 s, 0.5 s
//      crossfade between stages, 2 s hold on the final (live) frame.
//    • Stage label ("Stage N of M · date") is burned into the frames
//      bottom-trailing — v1 design call: clean crossfade, no critique
//      text captions.
//    • Written to a temp file; shared via UIActivityViewController.
//

import SwiftUI
import UIKit
import AVFoundation

// MARK: - Player sheet

struct EvolutionTimelapseView: View {
    /// Critique history for the drawing, oldest-first (the storage
    /// order). Entries without a snapshot pointer are skipped.
    let critiqueHistory: [CritiqueEntry]
    /// The live canvas, captured by the presenter at sheet-present time.
    /// nil (export failed / empty canvas) ⇒ the timelapse ends on the
    /// newest snapshot instead.
    let currentCanvasImage: UIImage?

    @Environment(\.dismiss) private var dismiss

    private struct Frame {
        let image: UIImage
        let label: String
    }

    private enum LoadState {
        case loading(done: Int, total: Int)
        case loaded([Frame])
        case failed(String)
    }

    @State private var loadState: LoadState = .loading(done: 0, total: 0)
    @State private var frameIndex: Int = 0
    @State private var isPlaying = true
    @State private var playbackTask: Task<Void, Never>? = nil

    @State private var isExporting = false
    @State private var exportedURL: URL? = nil
    @State private var showShareSheet = false
    @State private var exportError: String? = nil

    /// Stage hold + crossfade pacing for the on-screen player. The
    /// exporter mirrors these so the shared video feels like the preview.
    private let stageHold: Duration = .milliseconds(1_400)
    private let endHold: Duration = .milliseconds(2_600)

    var body: some View {
        NavigationStack {
            Group {
                switch loadState {
                case .loading(let done, let total):
                    VStack(spacing: 14) {
                        ProgressView()
                        Text(total > 0 ? "Loading stage \(min(done + 1, total)) of \(total)…"
                                       : "Loading…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                case .loaded(let frames):
                    player(frames: frames)
                }
            }
            .navigationTitle("Watch It Evolve")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if case .loaded(let frames) = loadState, frames.count >= 2 {
                        if isExporting {
                            ProgressView()
                        } else {
                            Button {
                                exportVideo(frames: frames)
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel("Share time-lapse video")
                        }
                    }
                }
            }
        }
        .task { await loadFrames() }
        .onDisappear { playbackTask?.cancel() }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportedURL {
                ActivityShareSheet(items: [url])
            }
        }
        .alert("Couldn't Export", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "Something went wrong. Please try again.")
        }
    }

    // MARK: Player

    @ViewBuilder
    private func player(frames: [Frame]) -> some View {
        VStack(spacing: 16) {
            ZStack {
                // Crossfade: every frame is mounted; only the active one
                // is opaque. SwiftUI animates the opacity flips, and with
                // images already decoded there's no mid-fade hitch.
                ForEach(frames.indices, id: \.self) { i in
                    Image(uiImage: frames[i].image)
                        .resizable()
                        .scaledToFit()
                        .opacity(i == frameIndex ? 1 : 0)
                }
            }
            .animation(.easeInOut(duration: 0.5), value: frameIndex)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)

            Text(frames[min(frameIndex, frames.count - 1)].label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            HStack(spacing: 18) {
                // Stage dots — tap to scrub.
                HStack(spacing: 6) {
                    ForEach(frames.indices, id: \.self) { i in
                        Circle()
                            .fill(i == frameIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .contentShape(Circle().scale(2.5))
                            .onTapGesture {
                                playbackTask?.cancel()
                                isPlaying = false
                                frameIndex = i
                            }
                    }
                }

                Button {
                    if isPlaying {
                        playbackTask?.cancel()
                        isPlaying = false
                    } else {
                        isPlaying = true
                        startPlayback(frameCount: frames.count)
                    }
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                }
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
            }
            .padding(.bottom, 20)
        }
        .onAppear { startPlayback(frameCount: frames.count) }
    }

    private func startPlayback(frameCount: Int) {
        playbackTask?.cancel()
        guard frameCount > 1 else { return }
        playbackTask = Task { @MainActor in
            while !Task.isCancelled {
                let atEnd = frameIndex == frameCount - 1
                try? await Task.sleep(for: atEnd ? endHold : stageHold)
                guard !Task.isCancelled else { return }
                frameIndex = atEnd ? 0 : frameIndex + 1
            }
        }
    }

    // MARK: Frame loading

    @MainActor
    private func loadFrames() async {
        let snapshotEntries = critiqueHistory.filter { $0.snapshot != nil }
        let total = snapshotEntries.count
        guard total > 0 || currentCanvasImage != nil else {
            loadState = .failed("No snapshots yet — get a critique or two and the evolution will build itself.")
            return
        }
        loadState = .loading(done: 0, total: total)

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none

        var frames: [Frame] = []
        let stageTotal = total + (currentCanvasImage != nil ? 1 : 0)
        for (i, entry) in snapshotEntries.enumerated() {
            guard let pointer = entry.snapshot else { continue }
            do {
                let image = try await CloudDrawingStorageManager.shared
                    .loadSnapshotComposite(at: pointer.compositePath)
                frames.append(Frame(
                    image: image,
                    label: "Stage \(i + 1) of \(stageTotal) · \(dateFormatter.string(from: entry.timestamp))"
                ))
            } catch {
                // A missing/unfetchable snapshot skips its stage rather
                // than sinking the whole timelapse — degraded > dead.
                print("⚠️ Timelapse: failed to load snapshot \(pointer.compositePath): \(error)")
            }
            loadState = .loading(done: i + 1, total: total)
        }

        if let live = currentCanvasImage {
            frames.append(Frame(image: live, label: "Today"))
        }

        guard frames.count >= 1 else {
            loadState = .failed("Couldn't load the snapshots — check your connection and try again.")
            return
        }
        loadState = .loaded(frames)
    }

    // MARK: Export

    private func exportVideo(frames: [Frame]) {
        isExporting = true
        let inputs = frames.map { (image: $0.image, label: $0.label) }
        Task.detached(priority: .userInitiated) {
            do {
                let url = try TimelapseVideoExporter.export(frames: inputs)
                await MainActor.run {
                    isExporting = false
                    exportedURL = url
                    showShareSheet = true
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    exportError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Video exporter

/// Renders a frame sequence to a square H.264 .mp4. Pure CoreGraphics +
/// AVAssetWriter — no canvas/Metal involvement. Pacing mirrors the
/// on-screen player: ~1.1 s hold per stage, 0.5 s crossfade, 2 s final
/// hold.
enum TimelapseVideoExporter {
    private static let outputSide = 1080
    private static let fps: Int32 = 30
    private static let holdFrames = 33      // ~1.1 s
    private static let fadeFrames = 15      // 0.5 s
    private static let finalHoldFrames = 60 // 2 s

    enum ExportError: LocalizedError {
        case writerSetupFailed
        case bufferCreationFailed
        case tooFewFrames

        var errorDescription: String? {
            switch self {
            case .writerSetupFailed:    return "Couldn't set up the video writer."
            case .bufferCreationFailed: return "Couldn't allocate video frames."
            case .tooFewFrames:         return "Not enough stages to export yet."
            }
        }
    }

    /// Synchronous; call off-main. Returns the temp-file URL of the
    /// finished video.
    static func export(frames: [(image: UIImage, label: String)]) throws -> URL {
        guard frames.count >= 2 else { throw ExportError.tooFewFrames }

        // Pre-render each stage once at output size with its label burned
        // in; the per-frame loop then only blends two CGImages.
        let stages: [CGImage] = frames.compactMap { renderStage(image: $0.image, label: $0.label) }
        guard stages.count == frames.count else { throw ExportError.bufferCreationFailed }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DrawEvolve-Evolution-\(UUID().uuidString.prefix(8)).mp4")
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputSide,
            AVVideoHeightKey: outputSide,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: outputSide,
                kCVPixelBufferHeightKey as String: outputSide,
            ]
        )
        guard writer.canAdd(input) else { throw ExportError.writerSetupFailed }
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.writerSetupFailed }
        writer.startSession(atSourceTime: .zero)

        var frameCount: Int64 = 0
        func append(_ draw: (CGContext) -> Void) throws {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard let pool = adaptor.pixelBufferPool else { throw ExportError.bufferCreationFailed }
            var bufferOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &bufferOut)
            guard let buffer = bufferOut else { throw ExportError.bufferCreationFailed }

            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: outputSide, height: outputSide,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            ) else { throw ExportError.bufferCreationFailed }

            draw(context)

            let time = CMTime(value: frameCount, timescale: fps)
            adaptor.append(buffer, withPresentationTime: time)
            frameCount += 1
        }

        let fullRect = CGRect(x: 0, y: 0, width: outputSide, height: outputSide)
        for (i, stage) in stages.enumerated() {
            let isLast = i == stages.count - 1
            // Hold.
            for _ in 0..<(isLast ? finalHoldFrames : holdFrames) {
                try append { ctx in
                    ctx.draw(stage, in: fullRect)
                }
            }
            // Crossfade into the next stage.
            if !isLast {
                let next = stages[i + 1]
                for f in 1...fadeFrames {
                    let t = CGFloat(f) / CGFloat(fadeFrames)
                    try append { ctx in
                        ctx.draw(stage, in: fullRect)
                        ctx.setAlpha(t)
                        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                        ctx.draw(next, in: fullRect)
                        ctx.endTransparencyLayer()
                        ctx.setAlpha(1)
                    }
                }
            }
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else { throw ExportError.writerSetupFailed }
        return url
    }

    /// Aspect-fit the stage image on white at output size and burn the
    /// stage label into the bottom-trailing corner.
    private static func renderStage(image: UIImage, label: String) -> CGImage? {
        let side = CGFloat(outputSide)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let rendered = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))

            let imageSize = image.size
            guard imageSize.width > 0, imageSize.height > 0 else { return }
            let scale = min(side / imageSize.width, side / imageSize.height)
            let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let origin = CGPoint(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2)
            image.draw(in: CGRect(origin: origin, size: drawSize))

            // Label chip, bottom-trailing.
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let text = NSAttributedString(string: label, attributes: attributes)
            let textSize = text.size()
            let pad: CGFloat = 18
            let chipRect = CGRect(
                x: side - textSize.width - pad * 2 - 24,
                y: side - textSize.height - pad * 2 - 24,
                width: textSize.width + pad * 2,
                height: textSize.height + pad * 2
            )
            let chip = UIBezierPath(roundedRect: chipRect, cornerRadius: chipRect.height / 2)
            UIColor.black.withAlphaComponent(0.55).setFill()
            chip.fill()
            text.draw(at: CGPoint(x: chipRect.minX + pad, y: chipRect.minY + pad))
        }
        return rendered.cgImage
    }
}

// MARK: - Share sheet wrapper

/// Minimal UIActivityViewController bridge — the app has no existing
/// share-sheet infrastructure, and ShareLink wants its item up-front
/// while our video URL only exists after the async export.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
