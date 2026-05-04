//
//  PhotoLibrarySaver.swift
//  DrawEvolve
//
//  Saves a UIImage to the user's Photos library. Uses .addOnly authorization
//  so we never request read access to the rest of their photos — we only need
//  to write one file.
//

import Photos
import UIKit

enum PhotoLibrarySaverError: LocalizedError {
    case permissionDenied
    case saveFailed(Error)
    case unknown

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "DrawEvolve needs permission to save to Photos. Enable it in Settings > Privacy & Security > Photos > DrawEvolve."
        case .saveFailed(let err):
            return "Couldn't save to Photos: \(err.localizedDescription)"
        case .unknown:
            return "Couldn't save to Photos."
        }
    }
}

enum PhotoLibrarySaver {
    static func save(_ image: UIImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PhotoLibrarySaverError.permissionDenied
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.creationRequestForAsset(from: image)
            }, completionHandler: { success, error in
                if let error = error {
                    continuation.resume(throwing: PhotoLibrarySaverError.saveFailed(error))
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoLibrarySaverError.unknown)
                }
            })
        }
    }
}
