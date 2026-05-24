//
//  CritiqueSnapshotThumbnail.swift
//  DrawEvolve
//
//  Shared thumbnail view for a CritiqueEntry's historical snapshot — the
//  drawing's state at the time that critique was generated. Signed-URL
//  fetch against the `drawings` bucket via CritiqueEntry.snapshot.thumbPath
//  with a 3600s TTL.
//
//  Three-state placeholder:
//    • snapshot present + bytes loaded → render UIImage
//    • snapshot present + still loading → ProgressView
//    • snapshot == nil                  → muted Image("photo")
//
//  No fallback to a live-drawing thumbnail when snapshot is nil — the
//  feature's whole promise is "what the drawing looked like AT critique
//  time," and a live-thumb fallback would silently defeat that.
//
//  Per-instance @State requires this to be its own View (inline @State
//  inside a ForEach closure doesn't work). `.task(id: entry.id)` keeps
//  the fetch scoped to entry identity, so re-renders that don't change
//  the entry don't redownload.
//

import SwiftUI
import UIKit

struct CritiqueSnapshotThumbnail: View {
    let entry: CritiqueEntry
    let size: CGFloat

    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(uiColor: .tertiarySystemBackground))
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if entry.snapshot != nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundStyle(.tertiary.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .task(id: entry.id) { await loadThumbnail() }
    }

    @MainActor
    private func loadThumbnail() async {
        guard let snapshot = entry.snapshot else { return }
        guard let client = SupabaseManager.shared.client else { return }
        do {
            let signed = try await client.storage
                .from("drawings")
                .createSignedURL(path: snapshot.thumbPath, expiresIn: 3600)
            let (data, _) = try await URLSession.shared.data(from: signed)
            if let img = UIImage(data: data) {
                self.thumbnail = img
            }
        } catch {
            print("[CritiqueSnapshotThumbnail] snapshot thumb fetch failed: \(error.localizedDescription)")
        }
    }
}
