//
//  PoseDetectionSheet.swift
//  DrawEvolve
//
//  Modal sheet for placing a hand-or-body pose reference on the canvas.
//  Pick photo → Vision runs → preview the detected skeleton → "Place on
//  Canvas" hands the skeleton to PoseOverlayManager. Inline help on
//  "no pose detected" per Decision 12. iPhone uses .medium/.large detents
//  matching FloatingFeedbackPanel.
//

import PhotosUI
import SwiftUI

struct PoseDetectionSheet: View {
    let kind: PoseSkeletonKind
    @ObservedObject var poseManager: PoseOverlayManager
    @ObservedObject var canvasState: CanvasStateManager
    @Environment(\.dismiss) private var dismiss

    @State private var photoItem: PhotosPickerItem?
    @State private var pickedImage: UIImage?
    @State private var detectionState: DetectionState = .idle
    /// Canvas-doc rect the detected skeleton occupies. Recomputed each
    /// time a new photo is picked.
    @State private var canvasTargetRect: CGRect = .zero

    private enum DetectionState: Equatable {
        case idle
        case running
        case success(PoseDetectionResult)
        /// `nil` reason means generic failure; otherwise carries a
        /// localized message for the inline error block.
        case failure(reason: String?)
        /// Detection completed but Vision returned zero observations of
        /// the requested kind.
        case empty
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(kind == .hand ? "Add Hand Pose" : "Add Body Pose")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Place on Canvas", action: place)
                            .disabled(!canPlace)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task { await loadAndDetect(item: newItem) }
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                pickerRow
                previewBlock
                statusBlock
            }
            .padding()
        }
    }

    private var pickerRow: some View {
        PhotosPicker(selection: $photoItem, matching: .images) {
            HStack(spacing: 8) {
                Image(systemName: "photo.badge.plus")
                Text(pickedImage == nil ? "Choose Photo" : "Choose Different Photo")
                    .font(.body.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.accentColor.opacity(0.15))
            .foregroundColor(.accentColor)
            .cornerRadius(10)
        }
    }

    @ViewBuilder
    private var previewBlock: some View {
        if let image = pickedImage {
            GeometryReader { proxy in
                let imageRect = aspectFitRect(
                    imageSize: image.size,
                    in: CGRect(origin: .zero, size: proxy.size)
                )
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)

                    if case .success(let result) = detectionState {
                        ForEach(filteredSkeletons(in: result)) { skeleton in
                            PoseSkeletonPreview(
                                skeleton: skeleton,
                                from: canvasTargetRect,
                                to: imageRect
                            )
                        }
                    }

                    if case .running = detectionState {
                        ZStack {
                            Color.black.opacity(0.3)
                            ProgressView("Detecting…")
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .foregroundColor(.white)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(image.size, contentMode: .fit)
            .background(Color.black.opacity(0.05))
            .cornerRadius(10)
        } else {
            placeholderBlock
        }
    }

    private var placeholderBlock: some View {
        VStack(spacing: 12) {
            Image(systemName: kind == .hand ? "hand.raised" : "figure.stand")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(kind == .hand
                 ? "Pick a photo where the hand is clearly visible against a contrasting background."
                 : "Pick a full-body photo. The detector works best when the figure faces the camera.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(10)
    }

    @ViewBuilder
    private var statusBlock: some View {
        switch detectionState {
        case .idle, .running:
            EmptyView()
        case .success(let result):
            if !result.advisories.isEmpty {
                advisoryBlock(result.advisories)
            }
        case .empty:
            inlineHelp(
                title: "No pose detected",
                body: kind == .hand
                    ? "Try a clearer photo of a hand against a contrasting background."
                    : "Try a clearer full-body photo where the figure faces the camera."
            )
        case .failure(let reason):
            inlineHelp(
                title: "Couldn't run detection",
                body: reason ?? "Try a different photo."
            )
        }
    }

    private func advisoryBlock(_ advisories: [PoseAdvisory]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(advisories.enumerated()), id: \.offset) { _, advisory in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(advisoryText(advisory))
                        .font(.footnote)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.yellow.opacity(0.12))
        .cornerRadius(8)
    }

    private func advisoryText(_ advisory: PoseAdvisory) -> String {
        switch advisory.kind {
        case .lowConfidenceJoints(let count):
            return "\(count) joint\(count == 1 ? "" : "s") detected with low confidence — drag to refine after placing."
        case .missingJoints(let count):
            return "\(count) joint\(count == 1 ? "" : "s") missing from detection."
        }
    }

    private func inlineHelp(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(body).font(.footnote).foregroundColor(.secondary)
            Text("Choose Different Photo above to retry.").font(.footnote.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(8)
    }

    // MARK: - Actions

    private var canPlace: Bool {
        if case .success = detectionState { return true }
        return false
    }

    private func place() {
        guard case .success(let result) = detectionState else { return }
        for skeleton in filteredSkeletons(in: result) {
            poseManager.place(skeleton)
        }
        dismiss()
    }

    private func loadAndDetect(item: PhotosPickerItem) async {
        detectionState = .running
        pickedImage = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                detectionState = .failure(reason: "Couldn't read that photo.")
                return
            }
            pickedImage = image
            canvasTargetRect = aspectFitRect(
                imageSize: image.size,
                in: centeredHalfCanvasRect()
            )
            let result = try await VisionPoseService.shared.detect(
                in: image,
                mappingTo: canvasTargetRect,
                detectHands: kind == .hand,
                detectBody: kind == .body
            )
            let filtered = filteredSkeletons(in: result)
            if filtered.isEmpty {
                detectionState = .empty
            } else {
                detectionState = .success(result)
            }
        } catch is CancellationError {
            // Sheet was dismissed mid-detection; nothing to surface.
            return
        } catch {
            detectionState = .failure(reason: nil)
        }
    }

    private func filteredSkeletons(in result: PoseDetectionResult) -> [PoseSkeleton] {
        result.skeletons.filter {
            switch ($0, kind) {
            case (.hand, .hand), (.body, .body): return true
            default: return false
            }
        }
    }

    // MARK: - Geometry helpers

    /// Half-canvas rect, centered, in canvas-doc space. Pose anchors here
    /// so a freshly-placed skeleton lands prominently without occupying
    /// the whole canvas. PR 4's transform handles let the user resize.
    private func centeredHalfCanvasRect() -> CGRect {
        let size = canvasState.documentSize
        let target = CGSize(width: size.width * 0.5, height: size.height * 0.5)
        return CGRect(
            x: (size.width - target.width) / 2,
            y: (size.height - target.height) / 2,
            width: target.width,
            height: target.height
        )
    }

    private func aspectFitRect(imageSize: CGSize, in container: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return container }
        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = container.width / container.height
        let fitSize: CGSize
        if imageAspect > containerAspect {
            fitSize = CGSize(width: container.width, height: container.width / imageAspect)
        } else {
            fitSize = CGSize(width: container.height * imageAspect, height: container.height)
        }
        return CGRect(
            x: container.minX + (container.width - fitSize.width) / 2,
            y: container.minY + (container.height - fitSize.height) / 2,
            width: fitSize.width,
            height: fitSize.height
        )
    }
}

// MARK: - Preview rendering

/// Stripped-down skeleton renderer used inside the detection sheet only.
/// Re-projects joint positions from the canvas-doc target rect into the
/// preview's image rect so the user sees the bones overlaid on the photo.
private struct PoseSkeletonPreview: View {
    let skeleton: PoseSkeleton
    let from: CGRect
    let to: CGRect

    private struct JointDot: Identifiable {
        let id: String
        let position: CGPoint
        let isLow: Bool
    }

    var body: some View {
        ZStack {
            Path { path in
                for (a, b) in connectionPositionPairs {
                    path.move(to: project(a))
                    path.addLine(to: project(b))
                }
            }
            .stroke(Color.accentColor.opacity(0.85), lineWidth: 1.5)
            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

            ForEach(jointDots) { dot in
                Circle()
                    .fill(dot.isLow ? Color.yellow : Color.accentColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1))
                    .position(project(dot.position))
            }
        }
    }

    /// Resolved (start, end) bone endpoints in canvas-doc space — `nil`
    /// endpoints (joint not detected) are filtered here so the body can
    /// stick to a single render loop.
    private var connectionPositionPairs: [(CGPoint, CGPoint)] {
        switch skeleton {
        case .hand(let pose):
            return HandTopology.connections.compactMap { pair in
                guard let a = pose.joints[pair.0]?.position,
                      let b = pose.joints[pair.1]?.position else { return nil }
                return (a, b)
            }
        case .body(let pose):
            return BodyTopology.connections.compactMap { pair in
                guard let a = pose.joints[pair.0]?.position,
                      let b = pose.joints[pair.1]?.position else { return nil }
                return (a, b)
            }
        }
    }

    private var jointDots: [JointDot] {
        switch skeleton {
        case .hand(let pose):
            return pose.joints.map { kv in
                JointDot(
                    id: kv.key.rawValue,
                    position: kv.value.position,
                    isLow: kv.value.confidence < PoseConfidence.lowThreshold
                )
            }
        case .body(let pose):
            return pose.joints.map { kv in
                JointDot(
                    id: kv.key.rawValue,
                    position: kv.value.position,
                    isLow: kv.value.confidence < PoseConfidence.lowThreshold
                )
            }
        }
    }

    private func project(_ point: CGPoint) -> CGPoint {
        guard from.width > 0, from.height > 0 else { return point }
        let nx = (point.x - from.minX) / from.width
        let ny = (point.y - from.minY) / from.height
        return CGPoint(x: to.minX + nx * to.width, y: to.minY + ny * to.height)
    }
}
