//
//  VisionService.swift
//  DrawEvolve
//
//  Shared wrapper around Apple's Vision framework. Owns a serial background
//  queue, threading model, cancellation, and lifecycle for every feature that
//  needs Vision (pose, future background-removal, saliency, smart-select).
//
//  Rules for consumers:
//  • Never instantiate `VNImageRequestHandler` directly outside this directory.
//  • Always go through `VisionService.shared.perform(...)`.
//  • Vision results are returned on the calling Task's actor; deliver to
//    `@MainActor` UI via the standard `await MainActor.run { ... }` hop.
//

import CoreGraphics
import ImageIO
import UIKit
import Vision

/// Errors surfaced from `VisionService`. Distinct from `VNError` so callers
/// can switch on cancellation vs. preflight failures without importing Vision
/// internals.
enum VisionServiceError: Error {
    /// Underlying `UIImage` could not be converted to a `CGImage` (rare —
    /// happens for some symbol/render UIImages). Caller should reject input.
    case imageEncodingFailed
    /// Vision threw during `perform(_:)`. Original error attached for logging.
    case requestFailed(underlying: Error)
    /// Caller's Task was cancelled before the request completed.
    case cancelled
}

/// Source image plus the orientation Vision should treat it under.
/// Vision normalizes coordinates against the *upright* image; passing an
/// orientation lets us skip rotating the bytes ourselves.
struct VisionImage {
    let cgImage: CGImage
    let orientation: CGImagePropertyOrientation

    /// Maximum long edge passed to Vision. Resampling above this caps Vision's
    /// peak allocation around ~25 MB on a 2048 × 2048 RGBA image and yields
    /// detection quality indistinguishable from full-res in practice.
    static let recommendedMaxLongEdge: CGFloat = 2048
}

extension VisionImage {
    /// Build a `VisionImage` from a `UIImage`, optionally resampling to a max
    /// long-edge to bound Vision's peak memory.
    ///
    /// Resampling bakes in `imageOrientation`, so the returned `orientation`
    /// is always `.up` — Vision sees an upright bitmap. If the caller skips
    /// resampling, we forward the EXIF-equivalent orientation instead.
    static func make(from image: UIImage, maxLongEdge: CGFloat? = recommendedMaxLongEdge) -> VisionImage? {
        guard let sourceCG = image.cgImage else { return nil }

        if let cap = maxLongEdge {
            let pixelWidth = CGFloat(sourceCG.width)
            let pixelHeight = CGFloat(sourceCG.height)
            let longEdge = max(pixelWidth, pixelHeight)
            if longEdge > cap {
                let scale = cap / longEdge
                let targetSize = CGSize(width: pixelWidth * scale, height: pixelHeight * scale)
                if let resampled = resample(image: image, to: targetSize) {
                    return VisionImage(cgImage: resampled, orientation: .up)
                }
            }
        }

        return VisionImage(cgImage: sourceCG, orientation: image.imageOrientation.cgOrientation)
    }

    private static func resample(image: UIImage, to size: CGSize) -> CGImage? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let drawn = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return drawn.cgImage
    }
}

private extension UIImage.Orientation {
    var cgOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

/// Shared Vision wrapper.
///
/// Threading: requests are dispatched onto a single serial background queue.
/// Two concurrent callers see their requests run back-to-back, not in
/// parallel — Vision's Neural Engine path is serialized at the hardware
/// level anyway, and serial dispatch caps peak memory predictably.
///
/// To run multiple requests against the *same* image (e.g. hand + body in
/// one shot), pass them all to a single `perform(_:on:)` call. Vision's
/// `VNImageRequestHandler.perform([...])` shares image-decode work across
/// the batch.
final class VisionService: @unchecked Sendable {
    static let shared = VisionService()

    private let queue = DispatchQueue(
        label: "com.drawevolve.vision-service",
        qos: .userInitiated
    )

    /// Underlying `VNRequest` instances currently scheduled or in-flight.
    /// Tracked so `cancelAll()` (e.g. canvas teardown) can short-circuit
    /// long-running Vision work without waiting for it to finish.
    private let lock = NSLock()
    private var inFlight: [UUID: VNRequest] = [:]

    private init() {}

    // MARK: - Public API

    /// Run one or more Vision requests against `image`. Returns the same
    /// array of requests with `.results` populated.
    ///
    /// Cancellation: if the calling Task is cancelled, the in-flight
    /// `VNRequest`s are `.cancel()`-ed and the call throws
    /// `VisionServiceError.cancelled`.
    @discardableResult
    func perform<R: VNRequest>(_ requests: [R], on image: VisionImage) async throws -> [R] {
        try Task.checkCancellation()
        let token = UUID()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[R], Error>) in
                queue.async { [weak self] in
                    guard let self else {
                        cont.resume(throwing: VisionServiceError.cancelled)
                        return
                    }

                    self.register(token: token, requests: requests)
                    defer { self.unregister(token: token) }

                    if Task.isCancelled {
                        cont.resume(throwing: VisionServiceError.cancelled)
                        return
                    }

                    let handler = VNImageRequestHandler(
                        cgImage: image.cgImage,
                        orientation: image.orientation,
                        options: [:]
                    )

                    do {
                        try handler.perform(requests)
                        if Task.isCancelled {
                            cont.resume(throwing: VisionServiceError.cancelled)
                        } else {
                            cont.resume(returning: requests)
                        }
                    } catch {
                        cont.resume(throwing: VisionServiceError.requestFailed(underlying: error))
                    }
                }
            }
        } onCancel: { [weak self] in
            self?.cancel(token: token)
        }
    }

    /// Cancel every Vision request currently scheduled or in flight.
    /// Invoked from canvas teardown / app background to prevent leaked
    /// neural-engine work after the user has navigated away.
    func cancelAll() {
        lock.lock()
        let snapshot = Array(inFlight.values)
        inFlight.removeAll()
        lock.unlock()
        for req in snapshot { req.cancel() }
    }

    // MARK: - Internal bookkeeping

    private func register<R: VNRequest>(token: UUID, requests: [R]) {
        lock.lock()
        defer { lock.unlock() }
        // Track the first request as the proxy for the batch — they share
        // a handler invocation, so cancelling any one tears the batch down.
        if let first = requests.first {
            inFlight[token] = first
        }
    }

    private func unregister(token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        inFlight.removeValue(forKey: token)
    }

    private func cancel(token: UUID) {
        lock.lock()
        let req = inFlight.removeValue(forKey: token)
        lock.unlock()
        req?.cancel()
    }
}
