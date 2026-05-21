//
//  DrawingStorageManager.swift
//  DrawEvolve
//
//  Phase 3 of authandratelimitingandsecurity.md — cloud sync, local-first.
//
//  This file holds `CloudDrawingStorageManager`, the replacement for the
//  earlier all-local `DrawingStorageManager`. The filename is intentionally
//  unchanged so the Xcode project doesn't need a pbxproj edit; the type
//  rename signals "this is the cloud-aware version" at every call site.
//
//  Save flow (local-first, cloud best-effort):
//    1. Encode the canvas image to JPEG (q=0.9) and a 256px thumbnail JPEG (q=0.8).
//       JPEG is a one-way lossy conversion from the canvas's native PNG export.
//       Future "PNG storage" feature (post-TestFlight) is on file as a follow-up
//       for users who care about lossless round-trips; right now everything
//       in the cloud is JPEG to keep storage cost + signed-URL bandwidth bounded.
//    2. Write image, thumbnail, metadata JSON to local cache.
//    3. Insert/update in-memory `drawings` array — UI is consistent immediately.
//    4. Write a pending-upload entry to disk and kick off an async upload task.
//       saveDrawing/updateDrawing return as soon as local persist is durable;
//       cloud sync is fire-and-forget after that (with NWPathMonitor-driven retry).
//
//  Load flow:
//    1. fetchDrawings queries the `drawings` table for the current user (RLS
//       scopes the result). Hydrates metadata + downloads any missing thumbnails.
//    2. If the cloud query fails (offline / no session), falls back to enumerating
//       the local cache.
//    3. Full-size images are loaded on demand by views via loadFullImage(for:),
//       which checks the disk cache first and falls back to a signed-URL download.
//
//  DEBUG SKIP-AUTH bypass:
//    The bypass user has the sentinel UUID DEADBEEF-... and no matching
//    auth.users row. Every cloud operation for that user is skipped at the top
//    of the upload path — no pending entries accumulate, no spurious RLS errors.
//    Local save/load still works so the canvas can be exercised offline.
//

import Combine
import CryptoKit
import Foundation
import Network
import Supabase
import UIKit

/// Output of `CloudDrawingStorageManager.encodeForSave`. Pre-encoded JPEG bytes
/// for full image + (optional) thumbnail, produced off-main so the slow
/// UIImage decode + re-encode doesn't stall the @MainActor during save.
fileprivate struct EncodedSaveArtifacts: Sendable {
    let fullJPEG: Data
    let thumbnailJPEG: Data?
}

@MainActor
final class CloudDrawingStorageManager: ObservableObject {
    static let shared = CloudDrawingStorageManager()

    // MARK: - Public surface (signatures preserved from the old DrawingStorageManager)

    @Published var drawings: [Drawing] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var pendingUploadCount: Int = 0

    // MARK: - Internals

    private let fileManager = FileManager.default
    private let storageBucketID = "drawings"
    private let signedURLTTLSeconds = 3600     // 1 hour per Phase 3 spec
    private let thumbnailMaxDimension: CGFloat = 512
    private let fullImageJPEGQuality: CGFloat = 0.9
    private let thumbnailJPEGQuality: CGFloat = 0.8

    /// In-memory thumbnail cache keyed by drawing id, populated by fetchDrawings().
    /// Sync access for gallery cells. ~10-30KB per entry; for very large galleries
    /// (1000s of drawings) this should move to NSCache + lazy loading.
    ///
    /// `@Published` so SwiftUI re-renders gallery cells when async thumbnail
    /// downloads complete after the initial fetch. The setter is private —
    /// observers see the change via the synchronous `thumbnailData(for:)` API.
    @Published private var thumbnailCache: [UUID: Data] = [:]

    /// In-memory cache of historical snapshot composite JPEGs, keyed by
    /// the snapshot's compositePath (unique per critique). The phase 2
    /// canvas-overlay flow needs flipping between historical entries in
    /// the floating feedback panel to feel instant; first fetch hits the
    /// network, subsequent reads come from here. Invalidated alongside
    /// thumbnailCache on user change. NOT disk-persisted — composite
    /// JPEGs are ~100-300 KB and we'd rather rehydrate on next launch
    /// than carry stale bytes across sessions.
    private var snapshotCompositeCache: [String: UIImage] = [:]

    /// In-memory backoff schedule for retries: drawing id → next eligible retry time.
    /// Not persisted; a fresh app launch resets backoff (which is the right default —
    /// the network is probably in a different state than when the last attempt failed).
    private var nextRetryAt: [UUID: Date] = [:]

    /// Tracks active upload tasks so deleteDrawing can cancel a pending upload.
    private var activeUploadTasks: [UUID: Task<Void, Never>] = [:]

    /// Set on auth state change so retry / fetch logic can short-circuit when the
    /// active user changes mid-flight.
    private var lastObservedUserID: UUID?

    private var authObservation: AnyCancellable?
    #if DEBUG
    private var debugBypassObservation: AnyCancellable?
    #endif
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "drawevolve.cloudstorage.pathmonitor")

    private var cacheRoot: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("DrawEvolveCache", isDirectory: true)
    }
    private var metadataDir:   URL { cacheRoot.appendingPathComponent("metadata",   isDirectory: true) }
    private var thumbnailsDir: URL { cacheRoot.appendingPathComponent("thumbnails", isDirectory: true) }
    private var imagesDir:     URL { cacheRoot.appendingPathComponent("images",     isDirectory: true) }
    private var pendingDir:    URL { cacheRoot.appendingPathComponent("pending",    isDirectory: true) }
    /// Per-drawing layered artifact root (ONLINELAYERSTORE.md §4). One subdir
    /// per drawing: `layers/<drawing_id>/{manifest.json, layer-N.png, composite.jpg}`.
    /// This directory backs both upload-resumability (the upload retry reads
    /// bytes from here) and on-device offline reads. The next-sprint canvas
    /// reload path (loadLayered) will read the same files.
    private var layersDir:     URL { cacheRoot.appendingPathComponent("layers",     isDirectory: true) }

    private init() {
        for dir in [metadataDir, thumbnailsDir, imagesDir, pendingDir, layersDir] {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        setupAuthObservation()
        setupNetworkObserver()
        Task { await onLaunchRecovery() }
    }

    deinit {
        pathMonitor.cancel()
    }

    // MARK: - Auth + network observation

    private func setupAuthObservation() {
        // AuthManager is @MainActor so its publishers fire on the main actor.
        authObservation = AuthManager.shared.$state
            .sink { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleAuthStateChange(state)
                }
            }
        #if DEBUG
        // Bypass toggle should also reset state — entering bypass mid-session
        // should clear the cloud-loaded gallery so the user sees their local-only
        // bypass-mode list.
        debugBypassObservation = AuthManager.shared.$isDebugBypassed
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.resetForUserChange()
                }
            }
        #endif
    }

    private func handleAuthStateChange(_ state: AuthManager.State) {
        let newUserID: UUID? = {
            if case .signedIn(let user) = state { return user.id }
            return nil
        }()
        if newUserID != lastObservedUserID {
            resetForUserChange()
            lastObservedUserID = newUserID
        }
    }

    /// Drops in-memory state when the active user changes. Pending-upload entries
    /// on disk are NOT deleted — they belong to whoever wrote them and will retry
    /// the next time that user signs back in. Filtered out of pendingUploadCount
    /// here because they're not the current user's responsibility to surface.
    private func resetForUserChange() {
        drawings.removeAll()
        thumbnailCache.removeAll()
        snapshotCompositeCache.removeAll()
        nextRetryAt.removeAll()
        for (_, task) in activeUploadTasks { task.cancel() }
        activeUploadTasks.removeAll()
        pendingUploadCount = countPendingEntriesForCurrentUser()
        errorMessage = nil
    }

    private func setupNetworkObserver() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                await self?.retryPendingUploads()
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func onLaunchRecovery() async {
        pendingUploadCount = countPendingEntriesForCurrentUser()
        await retryPendingUploads()
    }

    // MARK: - Fetch

    func fetchDrawings() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard let activeUserID = currentEffectiveUserID() else {
            // No user at all (signed out, no bypass) — surface empty gallery.
            drawings = []
            thumbnailCache.removeAll()
            return
        }

        #if DEBUG
        if AuthManager.shared.isDebugBypassed {
            // Bypass user has no cloud session — local-only.
            await hydrateFromLocalCache(for: activeUserID)
            return
        }
        #endif

        guard let client = SupabaseManager.shared.client else {
            errorMessage = "Supabase not configured"
            await hydrateFromLocalCache(for: activeUserID)
            return
        }

        do {
            let data = try await client
                .from("drawings")
                .select()
                .order("updated_at", ascending: false)
                .execute()
                .data

            let decoded = try Self.makeDecoder().decode([Drawing].self, from: data)
            drawings = decoded

            // Mirror remote rows into the local metadata cache so offline mode
            // has something to fall back on.
            for drawing in decoded {
                writeMetadataToCache(drawing)
            }
            await hydrateThumbnails(for: decoded)
        } catch {
            // Surface the underlying DecodingError detail (.keyNotFound, etc.)
            // so future decode bugs are diagnosable from the Xcode console
            // instead of just "data couldn't be read".
            let detail = Self.describeDecodeFailure(error)
            print("☁️ fetchDrawings cloud query failed: \(detail) — falling back to local cache")
            error.log(context: "CloudDrawingStorageManager.fetchDrawings: \(detail)")
            errorMessage = "Couldn't reach the cloud — showing cached drawings"
            await hydrateFromLocalCache(for: activeUserID)
        }
    }

    private func hydrateFromLocalCache(for userID: UUID) async {
        let urls = (try? fileManager.contentsOfDirectory(at: metadataDir, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Drawing] = []
        let decoder = Self.makeDecoder()
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let drawing = try decoder.decode(Drawing.self, from: data)
                // Filter out other users' cached metadata so a different account
                // can't see them after sign-out.
                guard drawing.userId == userID else { continue }
                loaded.append(drawing)
            } catch {
                print("⚠️ Local cache decode failed for \(url.lastPathComponent): \(Self.describeDecodeFailure(error))")
            }
        }
        drawings = loaded.sorted { $0.updatedAt > $1.updatedAt }
        await hydrateThumbnails(for: drawings)
    }

    private func hydrateThumbnails(for drawings: [Drawing]) async {
        let activeUserID = currentEffectiveUserID()
        for drawing in drawings {
            let url = thumbnailsDir.appendingPathComponent("\(drawing.id.uuidString).jpg")
            if let data = try? Data(contentsOf: url) {
                thumbnailCache[drawing.id] = data
                continue
            }
            // Missing locally — try to pull it from cloud. Skip for bypass user
            // (no session) or when the drawing belongs to a different user.
            #if DEBUG
            if AuthManager.shared.isDebugBypassed { continue }
            #endif
            guard drawing.userId == activeUserID,
                  let client = SupabaseManager.shared.client else { continue }

            let thumbPath = thumbnailStoragePath(for: drawing)
            do {
                let bytes = try await client.storage
                    .from(storageBucketID)
                    .download(path: thumbPath)
                try? bytes.write(to: url)
                thumbnailCache[drawing.id] = bytes
            } catch {
                // Non-fatal — gallery cell will fall back to placeholder.
            }
        }
    }

    // MARK: - Save

    func saveDrawing(
        title: String,
        imageData: Data,
        feedback: String? = nil,
        context: DrawingContext? = nil,
        critiqueHistory: [CritiqueEntry] = []
    ) async throws -> Drawing {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        guard let userID = AuthManager.shared.currentUserID else {
            throw DrawingStorageError.notAuthenticated
        }

        let drawingID = UUID()
        // RLS compares the storage object's first path segment against
        // auth.uid()::text (lowercase). Swift's UUID.uuidString is uppercase,
        // so use the .lowercaseUUIDString accessor to match.
        let storagePath = "\(userID.lowercaseUUIDString)/\(drawingID.lowercaseUUIDString).jpg"
        let now = Date()

        let drawing = Drawing(
            id: drawingID,
            userId: userID,
            title: title,
            storagePath: storagePath,
            createdAt: now,
            updatedAt: now,
            feedback: feedback,
            context: context,
            critiqueHistory: critiqueHistory
        )

        // Off-main encode (Fix 1.5): JPEG re-encode + thumbnail resize moved
        // to a detached Task so the @MainActor doesn't stall ~200-500ms on a
        // 4096² canvas. The fast file-write hop back here is via
        // persistArtifactsLocally.
        let fullQ = fullImageJPEGQuality
        let thumbMax = thumbnailMaxDimension
        let thumbQ = thumbnailJPEGQuality
        let sourceData = imageData
        let artifacts = await Task.detached(priority: .userInitiated) {
            CloudDrawingStorageManager.encodeForSave(
                sourceData: sourceData,
                fullQuality: fullQ,
                thumbMaxDimension: thumbMax,
                thumbQuality: thumbQ,
            )
        }.value
        try persistArtifactsLocally(drawing: drawing, artifacts: artifacts)
        drawings.insert(drawing, at: 0)
        print("💾 Saved drawing locally: \(drawing.id) '\(title)' (\(critiqueHistory.count) critiques)")

        enqueueUpload(for: drawing)
        return drawing
    }

    // MARK: - Update

    /// Title-only rename for any drawing (flat OR layered). Updates
    /// the local cache and patches the `drawings` row directly via
    /// PostgREST; does NOT touch Storage bytes and does NOT route
    /// through the upload queue.
    ///
    /// WHY THIS EXISTS:
    ///
    /// `updateDrawing` queues a flat-upload pending entry. The flat
    /// upload path (attemptFlatUpload) bails immediately if the
    /// drawing has no `storagePath` — which is exactly the case for
    /// every layered drawing. Result: title renames on layered
    /// drawings silently never reached the cloud. Local cache showed
    /// the new name; a fetchDrawings round-trip returned the old
    /// one.
    ///
    /// This method sidesteps the queue entirely. The PATCH is small
    /// (~hundreds of bytes), idempotent, and finishes in one
    /// network round-trip — appropriate for a metadata-only edit.
    /// If the user is offline the call throws; caller decides how
    /// to surface that (DrawingDetailView keeps the typed text in
    /// the field so the user can hit Done again on reconnect).
    @MainActor
    func renameDrawing(id: UUID, title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DrawingStorageError.saveFailed }
        guard let index = drawings.firstIndex(where: { $0.id == id }) else {
            throw DrawingStorageError.drawingNotFound
        }

        // Local cache first. Order matters: in-memory + on-disk are
        // updated synchronously so callers (and any concurrent UI
        // read) see the new title immediately. If the network leg
        // below fails, the local state is still correct; the user
        // can retry. The retry queue intentionally doesn't pick
        // this up — renames are cheap to retry manually and we
        // don't want a stale rename to stomp a later legitimate
        // PATCH that won the race.
        var drawing = drawings[index]
        drawing.title = trimmed
        drawing.updatedAt = Date()
        try persistLocally(drawing: drawing, imageData: nil)
        drawings[index] = drawing
        print("💾 Renamed drawing locally: \(id) → '\(trimmed)'")

        guard let client = SupabaseManager.shared.client else {
            throw DrawingStorageError.saveFailed
        }

        // Direct PostgREST PATCH. Only the title + updated_at
        // columns are touched, so this CANNOT clobber
        // `critique_history` (Worker is sole writer per CLAUDE.md)
        // or any Storage pointer.
        struct TitlePatch: Encodable {
            let title: String
            let updated_at: String
        }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let patch = TitlePatch(
            title: trimmed,
            updated_at: isoFormatter.string(from: drawing.updatedAt)
        )
        try await client
            .from("drawings")
            .update(patch)
            .eq("id", value: id.uuidString.lowercased())
            .execute()
        print("☁️ Renamed drawing on cloud: \(id) → '\(trimmed)'")
    }

    /// Set or clear the Composition / "Eye Test" intent marker on a
    /// drawing (M3). Same shape as renameDrawing: in-memory + local
    /// cache update synchronously, then a direct PostgREST PATCH that
    /// touches only `intent_marker` + `updated_at`. critique_history
    /// is untouched (Worker is the sole writer per CLAUDE.md).
    ///
    /// Pass `marker = nil` to clear an existing marker. No retry queue
    /// — like rename, this is cheap to redo manually and we don't want
    /// a stale set to stomp a later legitimate PATCH that won the race.
    ///
    /// Requires migration 0015 to have run. If the column is missing,
    /// PostgREST returns 400 (PGRST204) and this throws. See
    /// `scripts/verify_postgrest_unknown_column.sh`.
    func setIntentMarker(id: UUID, marker: IntentMarker?) async throws {
        guard let index = drawings.firstIndex(where: { $0.id == id }) else {
            throw DrawingStorageError.drawingNotFound
        }

        var drawing = drawings[index]
        drawing.intentMarker = marker
        drawing.updatedAt = Date()
        try persistLocally(drawing: drawing, imageData: nil)
        drawings[index] = drawing
        print("💾 Updated intent marker locally: \(id) → \(marker.map { "(\($0.x), \($0.y))" } ?? "nil")")

        guard let client = SupabaseManager.shared.client else {
            throw DrawingStorageError.saveFailed
        }

        struct IntentPatch: Encodable {
            let intent_marker: IntentMarker?
            let updated_at: String

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(intent_marker, forKey: .intent_marker)
                try container.encode(updated_at, forKey: .updated_at)
            }
            enum CodingKeys: String, CodingKey {
                case intent_marker
                case updated_at
            }
        }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let patch = IntentPatch(
            intent_marker: marker,
            updated_at: isoFormatter.string(from: drawing.updatedAt)
        )
        try await client
            .from("drawings")
            .update(patch)
            .eq("id", value: id.uuidString.lowercased())
            .execute()
        print("☁️ Updated intent marker on cloud: \(id)")
    }

    func updateDrawing(
        id: UUID,
        title: String? = nil,
        imageData: Data? = nil,
        feedback: String? = nil,
        context: DrawingContext? = nil,
        critiqueHistory: [CritiqueEntry]? = nil
    ) async throws {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        guard let index = drawings.firstIndex(where: { $0.id == id }) else {
            // The in-memory `drawings` array can be replaced wholesale by
            // fetchDrawings() in narrow timing windows (e.g. gallery refresh
            // races an in-flight cloud upload). Surfacing an explicit error
            // lets the caller decide how to recover instead of silently
            // dropping the save.
            print("❌ updateDrawing: drawing \(id) not in memory")
            throw DrawingStorageError.drawingNotFound
        }

        var drawing = drawings[index]
        if let title { drawing.title = title }
        if let feedback { drawing.feedback = feedback }
        if let context { drawing.context = context }
        if let critiqueHistory { drawing.critiqueHistory = critiqueHistory }
        drawing.updatedAt = Date()

        // Off-main encode (Fix 1.5) when imageData is present; metadata-only
        // updates fall through to the synchronous path (no encode work
        // happens anyway when imageData is nil).
        if let sourceData = imageData {
            let fullQ = fullImageJPEGQuality
            let thumbMax = thumbnailMaxDimension
            let thumbQ = thumbnailJPEGQuality
            let artifacts = await Task.detached(priority: .userInitiated) {
                CloudDrawingStorageManager.encodeForSave(
                    sourceData: sourceData,
                    fullQuality: fullQ,
                    thumbMaxDimension: thumbMax,
                    thumbQuality: thumbQ,
                )
            }.value
            try persistArtifactsLocally(drawing: drawing, artifacts: artifacts)
        } else {
            try persistLocally(drawing: drawing, imageData: nil)
        }
        drawings[index] = drawing
        print("💾 Updated drawing locally: \(id) '\(drawing.title)'")

        enqueueUpload(for: drawing)
    }

    // MARK: - Layered save / update / load (ONLINELAYERSTORE.md)

    /// Persist a brand-new layered drawing locally and queue a layered cloud
    /// upload (manifest + per-layer PNGs + composite + thumb). Mirrors the
    /// shape of `saveDrawing` but takes a `LayeredDrawingPayload` produced by
    /// the canvas (next sprint) rather than a single flattened JPEG.
    ///
    /// Resumability: bytes are persisted under
    /// `Documents/DrawEvolveCache/layers/<id>/` before the upload task is
    /// kicked off, so a mid-upload app death simply replays from the same
    /// bytes the next launch.
    func saveLayeredDrawing(
        title: String,
        payload: LayeredDrawingPayload,
        feedback: String? = nil,
        context: DrawingContext? = nil,
        critiqueHistory: [CritiqueEntry] = []
    ) async throws -> Drawing {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        guard let userID = AuthManager.shared.currentUserID else {
            throw DrawingStorageError.notAuthenticated
        }

        let drawingID = UUID()
        let normalized = normalizeManifestForUpload(
            payload: payload,
            drawingID: drawingID,
            userID: userID
        )

        let manifestPath = layeredManifestStoragePath(userID: userID, drawingID: drawingID)
        let compositePath = normalized.compositeJPEG != nil
            ? layeredCompositeStoragePath(userID: userID, drawingID: drawingID)
            : nil
        let now = Date()

        let drawing = Drawing(
            id: drawingID,
            userId: userID,
            title: title,
            // Preserve a flat-style storage_path pointing at the composite when
            // present so legacy readers (and the Worker AI-feedback flow)
            // continue to find a flat image without knowing about manifests.
            storagePath: compositePath,
            createdAt: now,
            updatedAt: now,
            feedback: feedback,
            context: context,
            critiqueHistory: critiqueHistory,
            manifestPath: manifestPath,
            formatVersion: normalized.manifest.formatVersion,
            layerCount: normalized.layerPNGs.count,
            totalBytes: layeredTotalBytes(normalized),
            version: 1
        )

        try writeLayeredArtifactsLocally(drawingID: drawingID, payload: normalized)
        try writeLayeredThumbnailLocally(drawingID: drawingID, jpeg: normalized.thumbnailJPEG)
        writeMetadataToCache(drawing)
        drawings.insert(drawing, at: 0)
        print("💾 Saved layered drawing locally: \(drawingID) '\(title)' (\(normalized.layerPNGs.count) layers)")

        enqueueLayeredUpload(for: drawing, payload: normalized, legacy: nil)
        return drawing
    }

    /// Update an existing drawing with a new layered payload. If the existing
    /// row is legacy (flat-only), this is the legacy → layered upgrade path
    /// described in ONLINELAYERSTORE.md §8.2: storage_path is rewritten to the
    /// new composite location and the old flat objects are best-effort
    /// deleted on successful upload.
    func updateLayeredDrawing(
        id: UUID,
        title: String? = nil,
        payload: LayeredDrawingPayload,
        feedback: String? = nil,
        context: DrawingContext? = nil,
        critiqueHistory: [CritiqueEntry]? = nil
    ) async throws {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        guard let index = drawings.firstIndex(where: { $0.id == id }) else {
            print("❌ updateLayeredDrawing: drawing \(id) not in memory")
            throw DrawingStorageError.drawingNotFound
        }

        var drawing = drawings[index]
        let wasLegacy = !drawing.isLayered
        let userID = drawing.userId
        let normalized = normalizeManifestForUpload(
            payload: payload,
            drawingID: drawing.id,
            userID: userID
        )

        let manifestPath = layeredManifestStoragePath(userID: userID, drawingID: drawing.id)
        let compositePath = normalized.compositeJPEG != nil
            ? layeredCompositeStoragePath(userID: userID, drawingID: drawing.id)
            : nil

        // Capture legacy paths *before* mutating drawing.storagePath so the
        // upload pipeline can clean them up after the row upsert succeeds.
        let legacyComposite = wasLegacy ? drawing.storagePath : nil
        let legacyThumbnail = wasLegacy
            ? legacyThumbnailStoragePath(userID: userID, drawingID: drawing.id)
            : nil
        let legacyCleanup: LayeredLegacyCleanup? = (legacyComposite != nil || legacyThumbnail != nil)
            ? LayeredLegacyCleanup(compositePath: legacyComposite, thumbnailPath: legacyThumbnail)
            : nil

        if let title { drawing.title = title }
        if let feedback { drawing.feedback = feedback }
        if let context { drawing.context = context }
        if let critiqueHistory { drawing.critiqueHistory = critiqueHistory }
        drawing.storagePath = compositePath
        drawing.manifestPath = manifestPath
        drawing.formatVersion = normalized.manifest.formatVersion
        drawing.layerCount = normalized.layerPNGs.count
        drawing.totalBytes = layeredTotalBytes(normalized)
        drawing.updatedAt = Date()

        try writeLayeredArtifactsLocally(drawingID: drawing.id, payload: normalized)
        try writeLayeredThumbnailLocally(drawingID: drawing.id, jpeg: normalized.thumbnailJPEG)
        writeMetadataToCache(drawing)

        // If we just upgraded from legacy → layered, drop the legacy local
        // composite copy (the layered subdir's composite.jpg supersedes it).
        // The cloud-side legacy objects are deleted by the upload pipeline
        // after row_upserted = true so a failed upload leaves them reachable.
        if wasLegacy {
            let legacyImageURL = imagesDir.appendingPathComponent("\(id.uuidString).jpg")
            try? fileManager.removeItem(at: legacyImageURL)
        }

        drawings[index] = drawing
        print("💾 Updated layered drawing locally: \(id) '\(drawing.title)' (\(normalized.layerPNGs.count) layers)")

        enqueueLayeredUpload(for: drawing, payload: normalized, legacy: legacyCleanup)
    }

    /// Returns nil when the drawing is legacy / has no manifest. Caller falls
    /// back to `loadFullImage(for:)` to render the flat composite.
    ///
    /// Hits the local layered cache first (per-drawing subdir under
    /// `layers/<id>/`), then signed-URL downloads any missing pieces and
    /// caches them. Per-layer SHA256 is verified against the manifest; a
    /// mismatch surfaces as `DrawingStorageError.layerIntegrity` for v1 —
    /// the next-sprint canvas reload path can soften this to "swap in an
    /// empty layer" UX (see ONLINELAYERSTORE.md §6.3).
    func loadLayeredDrawing(for id: UUID) async throws -> LayeredDrawingPayload? {
        guard let drawing = drawings.first(where: { $0.id == id }) else { return nil }
        guard drawing.isLayered else { return nil }

        let userID = drawing.userId
        let drawingID = drawing.id
        let layerCount = drawing.layerCount ?? 0
        let layerDir = localLayersDir(forDrawingID: drawingID)

        // Try local cache first. If everything reads cleanly the network
        // never wakes up — important for offline editing.
        if let local = readLayeredArtifactsLocally(drawingID: drawingID, expectedLayerCount: layerCount) {
            return local
        }

        #if DEBUG
        if AuthManager.shared.isDebugBypassed {
            // Bypass user has no cloud session; if it's not on disk, it's gone.
            return nil
        }
        #endif

        guard let client = SupabaseManager.shared.client else { return nil }

        // Pull manifest from cloud, then layers in parallel.
        let manifestPath = drawing.manifestPath
            ?? layeredManifestStoragePath(userID: userID, drawingID: drawingID)
        let manifestData: Data
        do {
            let signed = try await client.storage
                .from(storageBucketID)
                .createSignedURL(path: manifestPath, expiresIn: signedURLTTLSeconds)
            let (data, _) = try await URLSession.shared.data(from: signed)
            manifestData = data
        } catch {
            print("☁️ loadLayeredDrawing manifest fetch failed for \(drawingID): \(error.localizedDescription)")
            return nil
        }

        let manifest: LayeredDrawingManifest
        do {
            manifest = try JSONDecoder().decode(LayeredDrawingManifest.self, from: manifestData)
        } catch {
            // A decode failure may signal a format-version bump older clients
            // can't read; surface as nil so the canvas can show the
            // "please update" UX (sprint 2 wires the messaging).
            print("☁️ loadLayeredDrawing manifest decode failed for \(drawingID): \(error.localizedDescription)")
            return nil
        }

        try? fileManager.createDirectory(at: layerDir, withIntermediateDirectories: true)
        let manifestURL = layerDir.appendingPathComponent(LayeredDrawingFilenames.manifest)
        try? manifestData.write(to: manifestURL)

        // Download layers in parallel. Maintain ordinal ordering on the
        // result array so the caller can index by ordinal.
        let bucketID = self.storageBucketID
        let ttl = self.signedURLTTLSeconds
        let rootPath = layeredRootStoragePath(userID: userID, drawingID: drawingID)
        var layerData: [Data?] = Array(repeating: nil, count: manifest.layers.count)
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for (idx, layer) in manifest.layers.enumerated() {
                let layerCloudPath = "\(rootPath)/\(layer.asset)"
                group.addTask {
                    let signed = try await client.storage
                        .from(bucketID)
                        .createSignedURL(path: layerCloudPath, expiresIn: ttl)
                    let (data, _) = try await URLSession.shared.data(from: signed)
                    return (idx, data)
                }
            }
            for try await (idx, data) in group {
                layerData[idx] = data
            }
        }

        for (idx, layer) in manifest.layers.enumerated() {
            guard let bytes = layerData[idx] else {
                throw DrawingStorageError.layerIntegrity
            }
            let actualHash = sha256Hex(bytes)
            if !layer.assetSha256.isEmpty, actualHash != layer.assetSha256.lowercased() {
                throw DrawingStorageError.layerIntegrity
            }
            try? bytes.write(to: layerDir.appendingPathComponent(layer.asset))
        }

        return LayeredDrawingPayload(
            manifest: manifest,
            layerPNGs: layerData.compactMap { $0 },
            compositeJPEG: nil,
            thumbnailJPEG: nil
        )
    }

    // MARK: - Delete

    func deleteDrawing(id: UUID) async throws {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        // Cancel any in-flight upload for this drawing first.
        activeUploadTasks[id]?.cancel()
        activeUploadTasks[id] = nil

        let drawing = drawings.first(where: { $0.id == id })
        drawings.removeAll { $0.id == id }
        thumbnailCache[id] = nil

        // Always wipe local cache + pending entry.
        removeLocalArtifacts(forDrawingID: id)
        pendingUploadCount = countPendingEntriesForCurrentUser()

        // Best-effort cloud delete. Skip for bypass user. Failures are logged
        // but not surfaced — the row will remain orphaned in cloud, which is
        // acceptable for a delete that the user already saw succeed locally.
        #if DEBUG
        if AuthManager.shared.isDebugBypassed { return }
        #endif

        guard let drawing,
              let client = SupabaseManager.shared.client else { return }

        do {
            try await client
                .from("drawings")
                .delete()
                .eq("id", value: drawing.id.lowercaseUUIDString)
                .execute()
            _ = try? await client.storage
                .from(storageBucketID)
                .remove(paths: cloudObjectPaths(for: drawing))
        } catch {
            print("☁️ deleteDrawing cloud delete failed (kept local delete): \(error.localizedDescription)")
        }
    }

    /// Every Storage object that belongs to `drawing`. Used by deletes (and by
    /// the legacy → layered re-save flow when wiping the old flat objects).
    /// Includes both the legacy flat paths and any layered siblings; passing
    /// extra paths is harmless — Supabase Storage's remove ignores misses.
    private func cloudObjectPaths(for drawing: Drawing) -> [String] {
        var paths: [String] = []
        if let storagePath = drawing.storagePath { paths.append(storagePath) }
        paths.append(thumbnailStoragePath(for: drawing))
        if drawing.isLayered {
            // Manifest + per-layer PNGs.
            paths.append(layeredManifestStoragePath(userID: drawing.userId, drawingID: drawing.id))
            let layerCount = drawing.layerCount ?? 0
            for ordinal in 0..<layerCount {
                paths.append(layeredLayerStoragePath(
                    userID: drawing.userId,
                    drawingID: drawing.id,
                    ordinal: ordinal
                ))
            }
        }
        return paths
    }

    // MARK: - Local cache wipe (Phase 6 — sign out / post-delete)

    /// Wipes the local-only state without touching cloud / Storage. Used by
    /// sign-out (cloud data preserved so a future sign-in re-hydrates) and
    /// by the post-delete-account cleanup (cloud data is already gone, this
    /// just clears the bytes still on disk).
    ///
    /// Distinct from `clearAllDrawings()` (which hits cloud too — DEBUG only).
    func clearLocalCache() async {
        for (_, task) in activeUploadTasks { task.cancel() }
        activeUploadTasks.removeAll()
        nextRetryAt.removeAll()

        drawings.removeAll()
        thumbnailCache.removeAll()
        snapshotCompositeCache.removeAll()
        pendingUploadCount = 0

        // Wipe contents of the cache subdirs but leave the directories
        // in place — they're recreated lazily on first use otherwise.
        for dir in [metadataDir, thumbnailsDir, imagesDir, pendingDir, layersDir] {
            let urls = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in urls { try? fileManager.removeItem(at: url) }
        }
    }

    // MARK: - Clear all (DEBUG)

    func clearAllDrawings() async throws {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        print("🗑️ Clearing all drawings (local + cloud)")

        for (_, task) in activeUploadTasks { task.cancel() }
        activeUploadTasks.removeAll()

        let snapshot = drawings
        drawings.removeAll()
        thumbnailCache.removeAll()
        snapshotCompositeCache.removeAll()

        // Wipe local cache contents (but keep the directories).
        for dir in [metadataDir, thumbnailsDir, imagesDir, pendingDir, layersDir] {
            let urls = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in urls { try? fileManager.removeItem(at: url) }
        }
        pendingUploadCount = 0

        #if DEBUG
        if AuthManager.shared.isDebugBypassed { return }
        #endif

        guard let client = SupabaseManager.shared.client else { return }
        for drawing in snapshot {
            do {
                try await client
                    .from("drawings")
                    .delete()
                    .eq("id", value: drawing.id.lowercaseUUIDString)
                    .execute()
                _ = try? await client.storage
                    .from(storageBucketID)
                    .remove(paths: cloudObjectPaths(for: drawing))
            } catch {
                print("☁️ clearAllDrawings cloud delete failed for \(drawing.id): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Image accessors for views

    /// Synchronous thumbnail accessor for gallery cells. Returns nil while the
    /// thumbnail is still being hydrated; the cell should fall back to a placeholder.
    func thumbnailData(for id: UUID) -> Data? {
        if let cached = thumbnailCache[id] { return cached }
        // Last-ditch: try disk on the calling thread. Cheap (< 30KB).
        let url = thumbnailsDir.appendingPathComponent("\(id.uuidString).jpg")
        if let data = try? Data(contentsOf: url) {
            thumbnailCache[id] = data
            return data
        }
        return nil
    }

    /// Synchronous lookup for the in-memory `Drawing` keyed by id. Used by
    /// the studio-wall → canvas navigation path (commit 13) to resolve a
    /// `TaggedCritique.drawingId` to the full Drawing record before
    /// presenting `DrawingCanvasView`. Returns nil if local state hasn't
    /// hydrated this drawing yet — caller should refuse the navigation or
    /// trigger a refresh.
    func drawing(for id: UUID) -> Drawing? {
        drawings.first { $0.id == id }
    }

    /// Synchronous accessor for a previously-fetched snapshot composite.
    /// Returns nil if the composite hasn't been loaded in this session.
    /// The phase 2 canvas-overlay flow checks this first to avoid a
    /// network round-trip when the user flips back to an entry they've
    /// already viewed.
    func cachedSnapshotComposite(at path: String) -> UIImage? {
        snapshotCompositeCache[path]
    }

    /// Fetch a snapshot composite JPEG by its storage path (typically
    /// `<user>/<drawing>/snapshots/<sequence>/composite.jpg`). Returns
    /// the decoded UIImage. Caches the result so flipping between
    /// historical entries in the floating feedback panel is instant
    /// after the first load.
    ///
    /// Throws `notAuthenticated` if Supabase client isn't available,
    /// `fetchFailed` if the signed URL fetch returns no bytes, or
    /// rethrows the underlying URL/Supabase error.
    func loadSnapshotComposite(at path: String) async throws -> UIImage {
        if let cached = snapshotCompositeCache[path] { return cached }
        guard let client = SupabaseManager.shared.client else {
            throw DrawingStorageError.notAuthenticated
        }
        let signed = try await client.storage
            .from(storageBucketID)
            .createSignedURL(path: path, expiresIn: signedURLTTLSeconds)
        let (data, _) = try await URLSession.shared.data(from: signed)
        guard let image = UIImage(data: data) else {
            throw DrawingStorageError.fetchFailed
        }
        snapshotCompositeCache[path] = image
        return image
    }

    /// Block until the in-flight upload for `id` finishes (success or failure).
    /// Throws `DrawingStorageError.cloudSyncFailed` if the pending entry is
    /// still on disk after the upload task completes — meaning the upload
    /// errored out and is now in backoff.
    ///
    /// This exists for the Phase 5b auto-save-before-feedback path: the
    /// Worker's ownership check requires the drawing's row to exist in
    /// Postgres, so the caller must wait for cloud persist before requesting
    /// feedback. Normal saves remain local-first / fire-and-forget; only this
    /// caller pays the latency.
    func awaitCloudSync(for id: UUID) async throws {
        if let task = activeUploadTasks[id] {
            await task.value
        }
        let pendingURL = pendingDir.appendingPathComponent("\(id.uuidString).json")
        if fileManager.fileExists(atPath: pendingURL.path) {
            throw DrawingStorageError.cloudSyncFailed
        }
    }

    /// Loads the full-size image: disk cache first, then signed URL from Storage.
    /// Returns nil if the image truly can't be located (bypass user with no local
    /// copy, or offline + cache miss).
    ///
    /// For layered drawings the "full image" is the composite.jpg sibling — the
    /// flat fallback used by AI feedback and any view that doesn't yet know
    /// how to render layers. Per-layer reads go through `loadLayeredDrawing`.
    func loadFullImage(for id: UUID) async throws -> Data? {
        // Layered drawings cache composite.jpg under the layered subdir.
        let layeredCompositeURL = localLayersDir(forDrawingID: id)
            .appendingPathComponent(LayeredDrawingFilenames.composite)
        if let cached = try? Data(contentsOf: layeredCompositeURL) {
            return cached
        }

        let url = imagesDir.appendingPathComponent("\(id.uuidString).jpg")
        if let cached = try? Data(contentsOf: url) {
            return cached
        }

        guard let drawing = drawings.first(where: { $0.id == id }) else { return nil }

        #if DEBUG
        if AuthManager.shared.isDebugBypassed {
            // Bypass user can't reach cloud; if it's not on disk, it's gone.
            return nil
        }
        #endif

        guard let client = SupabaseManager.shared.client else { return nil }
        guard let storagePath = drawing.storagePath else {
            // Manifest-only drawing without a composite. loadLayeredDrawing is
            // the right entrypoint; no flat fallback exists.
            return nil
        }

        do {
            let signed = try await client.storage
                .from(storageBucketID)
                .createSignedURL(path: storagePath, expiresIn: signedURLTTLSeconds)
            let (data, _) = try await URLSession.shared.data(from: signed)
            // Cache to whichever directory matches the drawing's representation.
            let cacheURL = drawing.isLayered ? layeredCompositeURL : url
            try? fileManager.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: cacheURL)
            return data
        } catch {
            print("☁️ loadFullImage failed for \(id): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Local persistence helpers

    private func persistLocally(drawing: Drawing, imageData: Data?) throws {
        if let imageData {
            // Normalize to JPEG (q=0.9). The canvas exports PNG; converting here
            // keeps the cloud-side format consistent and shrinks the on-disk
            // footprint. Lossy — see the file header for the PNG-storage follow-up.
            //
            // Hot-path callers (saveDrawing, updateDrawing-with-image) prefer
            // `persistArtifactsLocally` below — it takes pre-encoded bytes from
            // an off-main `encodeForSave` task so the @MainActor doesn't stall
            // for ~200-500ms on a 4096² canvas. This synchronous path remains
            // for the metadata-only callers (rename) where imageData is nil and
            // the encode work is skipped anyway.
            let jpegFull = jpegData(from: imageData, quality: fullImageJPEGQuality) ?? imageData
            let imageURL = imagesDir.appendingPathComponent("\(drawing.id.uuidString).jpg")
            try jpegFull.write(to: imageURL)

            if let thumbData = makeThumbnail(from: imageData) {
                let thumbURL = thumbnailsDir.appendingPathComponent("\(drawing.id.uuidString).jpg")
                try thumbData.write(to: thumbURL)
                thumbnailCache[drawing.id] = thumbData
            }
        }
        writeMetadataToCache(drawing)
    }

    /// Fast main-thread file write of pre-encoded bytes produced by the
    /// off-main `encodeForSave` task. Splits the slow part (JPEG encode +
    /// thumbnail resize) from the fast part (file I/O + metadata write).
    /// See Fix 1.5 of the perf-quick-wins PR.
    private func persistArtifactsLocally(drawing: Drawing, artifacts: EncodedSaveArtifacts) throws {
        let imageURL = imagesDir.appendingPathComponent("\(drawing.id.uuidString).jpg")
        try artifacts.fullJPEG.write(to: imageURL)

        if let thumbData = artifacts.thumbnailJPEG {
            let thumbURL = thumbnailsDir.appendingPathComponent("\(drawing.id.uuidString).jpg")
            try thumbData.write(to: thumbURL)
            thumbnailCache[drawing.id] = thumbData
        }
        writeMetadataToCache(drawing)
    }

    /// Off-main encoder. `nonisolated` + pure (no instance state read) so it
    /// can be invoked safely from `Task.detached`. Returns pre-encoded full +
    /// thumbnail JPEG bytes for `persistArtifactsLocally`. UIImage decode and
    /// UIGraphicsImageRenderer are documented thread-safe for the operations
    /// performed here (decode, draw-to-context, encode).
    nonisolated fileprivate static func encodeForSave(
        sourceData: Data,
        fullQuality: CGFloat,
        thumbMaxDimension: CGFloat,
        thumbQuality: CGFloat,
    ) -> EncodedSaveArtifacts {
        let fullJPEG: Data = {
            guard let img = UIImage(data: sourceData) else { return sourceData }
            return img.jpegData(compressionQuality: fullQuality) ?? sourceData
        }()

        let thumbnailJPEG: Data? = {
            guard let img = UIImage(data: sourceData),
                  img.size.width > 0, img.size.height > 0 else { return nil }
            let scale = min(thumbMaxDimension / img.size.width,
                            thumbMaxDimension / img.size.height,
                            1.0)
            let newSize = CGSize(width: img.size.width * scale,
                                 height: img.size.height * scale)
            let format = UIGraphicsImageRendererFormat.default()
            format.opaque = true
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
            let scaled = renderer.image { _ in
                img.draw(in: CGRect(origin: .zero, size: newSize))
            }
            return scaled.jpegData(compressionQuality: thumbQuality)
        }()

        return EncodedSaveArtifacts(fullJPEG: fullJPEG, thumbnailJPEG: thumbnailJPEG)
    }

    private func writeMetadataToCache(_ drawing: Drawing) {
        let url = metadataDir.appendingPathComponent("\(drawing.id.uuidString).json")
        do {
            let data = try Self.makeEncoder().encode(drawing)
            try data.write(to: url)
        } catch {
            print("⚠️ Failed to write metadata cache for \(drawing.id): \(error)")
        }
    }

    private func removeLocalArtifacts(forDrawingID id: UUID) {
        let idStr = id.uuidString
        for dir in [metadataDir, pendingDir] {
            try? fileManager.removeItem(at: dir.appendingPathComponent("\(idStr).json"))
        }
        for dir in [thumbnailsDir, imagesDir] {
            try? fileManager.removeItem(at: dir.appendingPathComponent("\(idStr).jpg"))
        }
        // Layered per-drawing subdirectory holds manifest + layer PNGs +
        // composite cache; one removeItem on the directory cleans them all.
        try? fileManager.removeItem(at: localLayersDir(forDrawingID: id))
    }

    private func jpegData(from imageData: Data, quality: CGFloat) -> Data? {
        guard let image = UIImage(data: imageData) else { return nil }
        return image.jpegData(compressionQuality: quality)
    }

    private func makeThumbnail(from imageData: Data) -> Data? {
        guard let image = UIImage(data: imageData) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = min(thumbnailMaxDimension / size.width, thumbnailMaxDimension / size.height, 1.0)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return scaled.jpegData(compressionQuality: thumbnailJPEGQuality)
    }

    // MARK: - Cloud upload + retry

    private func enqueueUpload(for drawing: Drawing) {
        #if DEBUG
        // Bypass user has no Supabase session — short-circuit before writing
        // a pending entry so the queue stays clean.
        if drawing.userId == AuthManager.debugBypassUserID {
            return
        }
        #endif

        let entry = PendingUpload(
            drawingID: drawing.id,
            userID: drawing.userId,
            storagePath: drawing.storagePath,
            createdAt: Date()
        )
        writePendingEntry(entry)
        pendingUploadCount = countPendingEntriesForCurrentUser()

        // Cancel any prior in-flight task for this drawing — newer save wins.
        activeUploadTasks[drawing.id]?.cancel()
        activeUploadTasks[drawing.id] = Task { [weak self] in
            await self?.attemptUpload(forDrawingID: drawing.id)
        }
    }

    private func attemptUpload(forDrawingID id: UUID) async {
        if Task.isCancelled { return }
        if let next = nextRetryAt[id], next > Date() {
            let delay = next.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        if Task.isCancelled { return }

        // Dispatch on the pending entry's kind. Entries written before the
        // layered-storage feature have no `kind` field and decode as .flat,
        // which preserves the existing behavior for in-flight retries
        // crossing the upgrade boundary.
        let entry = readPendingEntry(id: id)
        switch entry?.kind ?? .flat {
        case .flat:
            await attemptFlatUpload(forDrawingID: id)
        case .layered:
            await attemptLayeredUpload(forDrawingID: id)
        }
    }

    private func attemptFlatUpload(forDrawingID id: UUID) async {
        guard let drawing = drawings.first(where: { $0.id == id }) else {
            // Local copy gone (deleted) — cancel any pending entry too.
            removePendingEntry(id: id)
            pendingUploadCount = countPendingEntriesForCurrentUser()
            activeUploadTasks[id] = nil
            return
        }

        guard let client = SupabaseManager.shared.client else {
            scheduleBackoff(for: id, attempts: 1)
            return
        }

        guard let storagePath = drawing.storagePath else {
            // A flat-mode pending entry against a drawing that lost its flat
            // path is unrecoverable. Drop the entry; the layered path (if any)
            // will be retried via its own pending entry.
            removePendingEntry(id: id)
            pendingUploadCount = countPendingEntriesForCurrentUser()
            activeUploadTasks[id] = nil
            return
        }

        let imageURL = imagesDir.appendingPathComponent("\(id.uuidString).jpg")
        let thumbURL = thumbnailsDir.appendingPathComponent("\(id.uuidString).jpg")
        guard let imageData = try? Data(contentsOf: imageURL) else {
            // No local image bytes — nothing to upload. Drop the pending entry.
            removePendingEntry(id: id)
            pendingUploadCount = countPendingEntriesForCurrentUser()
            activeUploadTasks[id] = nil
            return
        }
        let thumbData = (try? Data(contentsOf: thumbURL)) ?? Data()

        do {
            try await client.storage
                .from(storageBucketID)
                .upload(
                    path: storagePath,
                    file: imageData,
                    options: FileOptions(contentType: "image/jpeg", upsert: true)
                )
            if !thumbData.isEmpty {
                try await client.storage
                    .from(storageBucketID)
                    .upload(
                        path: thumbnailStoragePath(for: drawing),
                        file: thumbData,
                        options: FileOptions(contentType: "image/jpeg", upsert: true)
                    )
            }
            // Phase 5d: upsert via DrawingUpsertPayload, NOT the raw Drawing.
            // The payload omits `critique_history` because the Worker is the
            // sole writer to that column. See DrawingUpsertPayload doc comment.
            try await client
                .from("drawings")
                .upsert(DrawingUpsertPayload(drawing: drawing))
                .execute()

            removePendingEntry(id: id)
            nextRetryAt[id] = nil
            activeUploadTasks[id] = nil
            pendingUploadCount = countPendingEntriesForCurrentUser()
            print("☁️ Uploaded \(drawing.id) '\(drawing.title)'")
        } catch {
            print("☁️ Upload failed for \(drawing.id) — keeping pending: \(error.localizedDescription)")
            let attempts = (incrementPendingAttempts(id: id) ?? 1)
            scheduleBackoff(for: id, attempts: attempts)
            activeUploadTasks[id] = nil
        }
    }

    // MARK: - Layered upload pipeline

    /// Captures the legacy (pre-layered) Storage paths to clean up after a
    /// successful upgrade upload. Persisted into the pending entry so a
    /// retry across launches still knows what to delete.
    private struct LayeredLegacyCleanup {
        let compositePath: String?
        let thumbnailPath: String?
    }

    private func enqueueLayeredUpload(
        for drawing: Drawing,
        payload: LayeredDrawingPayload,
        legacy: LayeredLegacyCleanup?
    ) {
        #if DEBUG
        if drawing.userId == AuthManager.debugBypassUserID { return }
        #endif

        let userID = drawing.userId
        let manifestPath = drawing.manifestPath
            ?? layeredManifestStoragePath(userID: userID, drawingID: drawing.id)
        let compositePath = payload.compositeJPEG != nil
            ? layeredCompositeStoragePath(userID: userID, drawingID: drawing.id)
            : nil
        let thumbPath = layeredThumbnailStoragePath(userID: userID, drawingID: drawing.id)

        let entry = PendingUpload(
            drawingID: drawing.id,
            userID: userID,
            storagePath: nil,
            createdAt: Date(),
            attemptCount: 0,
            lastAttemptAt: nil,
            kind: .layered,
            layerCount: payload.layerPNGs.count,
            uploadedLayers: [],
            uploadedComposite: false,
            uploadedThumb: false,
            uploadedManifest: false,
            rowUpserted: false,
            manifestPath: manifestPath,
            compositePath: compositePath,
            thumbPath: thumbPath,
            legacyCompositePath: legacy?.compositePath,
            legacyThumbnailPath: legacy?.thumbnailPath
        )
        writePendingEntry(entry)
        pendingUploadCount = countPendingEntriesForCurrentUser()

        activeUploadTasks[drawing.id]?.cancel()
        activeUploadTasks[drawing.id] = Task { [weak self] in
            await self?.attemptUpload(forDrawingID: drawing.id)
        }
    }

    private func attemptLayeredUpload(forDrawingID id: UUID) async {
        guard var entry = readPendingEntry(id: id), entry.kind == .layered else {
            // Disappeared or was rewritten as flat — nothing to do here.
            activeUploadTasks[id] = nil
            return
        }
        guard let drawing = drawings.first(where: { $0.id == id }) else {
            removePendingEntry(id: id)
            pendingUploadCount = countPendingEntriesForCurrentUser()
            activeUploadTasks[id] = nil
            return
        }

        guard let client = SupabaseManager.shared.client else {
            scheduleBackoff(for: id, attempts: 1)
            return
        }

        let layerDir = localLayersDir(forDrawingID: id)
        let manifestURL = layerDir.appendingPathComponent(LayeredDrawingFilenames.manifest)
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            // Local manifest missing — we can't upload without it. Drop the
            // pending entry so the queue doesn't spin forever.
            removePendingEntry(id: id)
            pendingUploadCount = countPendingEntriesForCurrentUser()
            activeUploadTasks[id] = nil
            return
        }

        let layerCount = entry.layerCount ?? 0
        var uploadedLayers = Set(entry.uploadedLayers ?? [])
        let bucketID = self.storageBucketID

        do {
            // Step 1: layers in parallel, skipping ordinals already done.
            try await withThrowingTaskGroup(of: Int.self) { group in
                for ordinal in 0..<layerCount where !uploadedLayers.contains(ordinal) {
                    let cloudPath = layeredLayerStoragePath(
                        userID: drawing.userId,
                        drawingID: id,
                        ordinal: ordinal
                    )
                    let fileURL = layerDir.appendingPathComponent(LayeredDrawingFilenames.layer(ordinal: ordinal))
                    guard let bytes = try? Data(contentsOf: fileURL) else {
                        // Local PNG missing — abort; without bytes there's
                        // nothing to retry. Caller surfaces the failure.
                        throw DrawingStorageError.saveFailed
                    }
                    group.addTask {
                        try await client.storage
                            .from(bucketID)
                            .upload(
                                path: cloudPath,
                                file: bytes,
                                options: FileOptions(contentType: "image/png", upsert: true)
                            )
                        return ordinal
                    }
                }
                for try await ordinal in group {
                    uploadedLayers.insert(ordinal)
                }
            }
            entry.uploadedLayers = Array(uploadedLayers).sorted()
            updatePendingEntry(entry)

            // Step 2: composite + thumb in parallel.
            try await withThrowingTaskGroup(of: String.self) { group in
                if entry.uploadedComposite != true, let compositePath = entry.compositePath {
                    let url = layerDir.appendingPathComponent(LayeredDrawingFilenames.composite)
                    if let bytes = try? Data(contentsOf: url) {
                        group.addTask {
                            try await client.storage
                                .from(bucketID)
                                .upload(
                                    path: compositePath,
                                    file: bytes,
                                    options: FileOptions(contentType: "image/jpeg", upsert: true)
                                )
                            return "composite"
                        }
                    } else {
                        // No local composite to upload; mark the step done so
                        // the pipeline can advance — the manifest's composite
                        // pointer will end up dangling but the row is still
                        // valid (composite is optional per §5.5).
                        entry.uploadedComposite = true
                    }
                }
                if entry.uploadedThumb != true, let thumbPath = entry.thumbPath {
                    let url = thumbnailsDir.appendingPathComponent("\(id.uuidString).jpg")
                    if let bytes = try? Data(contentsOf: url) {
                        group.addTask {
                            try await client.storage
                                .from(bucketID)
                                .upload(
                                    path: thumbPath,
                                    file: bytes,
                                    options: FileOptions(contentType: "image/jpeg", upsert: true)
                                )
                            return "thumb"
                        }
                    } else {
                        entry.uploadedThumb = true
                    }
                }
                for try await step in group {
                    switch step {
                    case "composite": entry.uploadedComposite = true
                    case "thumb":     entry.uploadedThumb = true
                    default: break
                    }
                }
            }
            updatePendingEntry(entry)

            // Step 3: manifest LAST, so a partial upload can never publish a
            // pointer to layers the cloud doesn't have yet.
            if entry.uploadedManifest != true, let manifestPath = entry.manifestPath {
                try await client.storage
                    .from(bucketID)
                    .upload(
                        path: manifestPath,
                        file: manifestData,
                        options: FileOptions(contentType: "application/json", upsert: true)
                    )
                entry.uploadedManifest = true
                updatePendingEntry(entry)
            }

            // Step 4: row upsert. Same omit-critique-history payload as the
            // flat path; the new manifest_path / format_version / layer_count
            // / total_bytes columns get included automatically.
            if entry.rowUpserted != true {
                try await client
                    .from("drawings")
                    .upsert(DrawingUpsertPayload(drawing: drawing))
                    .execute()
                entry.rowUpserted = true
                updatePendingEntry(entry)
            }

            // Step 5: best-effort legacy cleanup. After this point the row +
            // all layered objects are durable; the legacy flat objects are
            // safe to delete. Failures here are logged and ignored — leaving
            // an orphan in storage is far better than re-uploading on retry.
            var legacyPaths: [String] = []
            if let p = entry.legacyCompositePath { legacyPaths.append(p) }
            if let p = entry.legacyThumbnailPath { legacyPaths.append(p) }
            if !legacyPaths.isEmpty {
                _ = try? await client.storage
                    .from(bucketID)
                    .remove(paths: legacyPaths)
            }

            removePendingEntry(id: id)
            nextRetryAt[id] = nil
            activeUploadTasks[id] = nil
            pendingUploadCount = countPendingEntriesForCurrentUser()
            print("☁️ Uploaded layered \(drawing.id) '\(drawing.title)' (\(layerCount) layers)")
        } catch {
            // Persist whatever we got done so the next retry resumes correctly.
            updatePendingEntry(entry)
            print("☁️ Layered upload failed for \(drawing.id) — keeping pending: \(error.localizedDescription)")
            let attempts = (incrementPendingAttempts(id: id) ?? 1)
            scheduleBackoff(for: id, attempts: attempts)
            activeUploadTasks[id] = nil
        }
    }

    // MARK: - Snapshot capture (drawing version history)

    /// Uploads a layered drawing bundle to a non-live path under the
    /// drawing's storage root, used by the snapshot-capture flow at
    /// critique-submit time. Writes the same artifact shape as a live
    /// save (manifest + composite + thumb + per-layer PNGs), just under
    /// `<user>/<drawing>/<pathPrefix>/` instead of `<user>/<drawing>/`.
    ///
    /// Direct upload — does not enqueue a PendingUpload. Snapshots don't
    /// need drawing-save-grade retry vigor: on failure, the caller's
    /// graceful-degradation path sets the resulting CritiqueEntry's
    /// snapshot field to nil, and the orphan _pending bundle is GC'd by
    /// the worker cron in a later phase.
    ///
    /// The manifest is uploaded LAST. Its presence at the destination is
    /// the worker promote step's signal that the bundle is complete; a
    /// half-uploaded bundle never carries a manifest, so the worker won't
    /// promote it.
    public func uploadSnapshotBundle(
        userID: UUID,
        drawingID: UUID,
        payload: LayeredDrawingPayload,
        pathPrefix: String
    ) async throws {
        guard let client = SupabaseManager.shared.client else {
            throw DrawingStorageError.notAuthenticated
        }
        guard let composite = payload.compositeJPEG,
              let thumb = payload.thumbnailJPEG else {
            // A snapshot needs both — without them the time-machine view
            // has nothing to render. Surface as saveFailed rather than
            // shipping a half-bundle the worker would silently skip.
            throw DrawingStorageError.saveFailed
        }

        let bucketID = self.storageBucketID
        let normalized = normalizeManifestForUpload(
            payload: payload,
            drawingID: drawingID,
            userID: userID
        )

        // Step 1: per-layer PNGs in parallel.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (ordinal, png) in normalized.layerPNGs.enumerated() {
                let cloudPath = layeredLayerStoragePath(
                    userID: userID,
                    drawingID: drawingID,
                    ordinal: ordinal,
                    pathPrefix: pathPrefix
                )
                group.addTask {
                    try await client.storage
                        .from(bucketID)
                        .upload(
                            path: cloudPath,
                            file: png,
                            options: FileOptions(contentType: "image/png", upsert: true)
                        )
                }
            }
            try await group.waitForAll()
        }

        // Step 2: composite + thumb in parallel.
        let compositePath = layeredCompositeStoragePath(
            userID: userID,
            drawingID: drawingID,
            pathPrefix: pathPrefix
        )
        let thumbPath = layeredThumbnailStoragePath(
            userID: userID,
            drawingID: drawingID,
            pathPrefix: pathPrefix
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await client.storage
                    .from(bucketID)
                    .upload(
                        path: compositePath,
                        file: composite,
                        options: FileOptions(contentType: "image/jpeg", upsert: true)
                    )
            }
            group.addTask {
                try await client.storage
                    .from(bucketID)
                    .upload(
                        path: thumbPath,
                        file: thumb,
                        options: FileOptions(contentType: "image/jpeg", upsert: true)
                    )
            }
            try await group.waitForAll()
        }

        // Step 3: manifest LAST — sentinel for the worker promote.
        let manifestData = try JSONEncoder().encode(normalized.manifest)
        let manifestPath = layeredManifestStoragePath(
            userID: userID,
            drawingID: drawingID,
            pathPrefix: pathPrefix
        )
        try await client.storage
            .from(bucketID)
            .upload(
                path: manifestPath,
                file: manifestData,
                options: FileOptions(contentType: "application/json", upsert: true)
            )
    }

    // MARK: - Layered local cache helpers

    /// Build a manifest with deterministic asset names and sha256 hashes from
    /// the caller's inputs. The caller doesn't have to compute those — this
    /// is the canonical place where wire-format manifest fields are filled.
    private func normalizeManifestForUpload(
        payload: LayeredDrawingPayload,
        drawingID: UUID,
        userID: UUID
    ) -> LayeredDrawingPayload {
        var manifest = payload.manifest
        manifest.formatVersion = max(manifest.formatVersion, 1)
        manifest.drawingId = drawingID.uuidString.lowercased()
        manifest.thumbnail = LayeredDrawingFilenames.thumbnail
        manifest.composite = payload.compositeJPEG != nil ? LayeredDrawingFilenames.composite : nil

        // Re-key layers by ordinal so the cloud filenames + manifest agree.
        var rewritten: [LayeredDrawingManifest.Layer] = []
        for (idx, var layer) in manifest.layers.enumerated() {
            layer.ordinal = idx
            layer.asset = LayeredDrawingFilenames.layer(ordinal: idx)
            // Recompute hash from the actual bytes — caller-provided hashes
            // are advisory and may be stale across edits.
            if idx < payload.layerPNGs.count {
                layer.assetSha256 = sha256Hex(payload.layerPNGs[idx])
            } else {
                layer.assetSha256 = ""
            }
            rewritten.append(layer)
        }
        manifest.layers = rewritten
        return LayeredDrawingPayload(
            manifest: manifest,
            layerPNGs: payload.layerPNGs,
            compositeJPEG: payload.compositeJPEG,
            thumbnailJPEG: payload.thumbnailJPEG
        )
    }

    private func writeLayeredArtifactsLocally(drawingID: UUID, payload: LayeredDrawingPayload) throws {
        let dir = localLayersDir(forDrawingID: drawingID)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        for (idx, png) in payload.layerPNGs.enumerated() {
            let url = dir.appendingPathComponent(LayeredDrawingFilenames.layer(ordinal: idx))
            try png.write(to: url)
        }
        if let composite = payload.compositeJPEG {
            try composite.write(to: dir.appendingPathComponent(LayeredDrawingFilenames.composite))
        }
        let manifestData = try JSONEncoder().encode(payload.manifest)
        try manifestData.write(to: dir.appendingPathComponent(LayeredDrawingFilenames.manifest))
    }

    /// Persist the thumbnail at the same `thumbnails/<id>.jpg` path the
    /// gallery already reads from (ONLINELAYERSTORE.md §4 — gallery code
    /// does not change).
    private func writeLayeredThumbnailLocally(drawingID: UUID, jpeg: Data?) throws {
        guard let jpeg else { return }
        let url = thumbnailsDir.appendingPathComponent("\(drawingID.uuidString).jpg")
        try jpeg.write(to: url)
        thumbnailCache[drawingID] = jpeg
    }

    private func readLayeredArtifactsLocally(drawingID: UUID, expectedLayerCount: Int) -> LayeredDrawingPayload? {
        let dir = localLayersDir(forDrawingID: drawingID)
        let manifestURL = dir.appendingPathComponent(LayeredDrawingFilenames.manifest)
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(LayeredDrawingManifest.self, from: manifestData),
              manifest.layers.count == expectedLayerCount || expectedLayerCount == 0 else {
            return nil
        }

        var layerPNGs: [Data] = []
        for layer in manifest.layers {
            let url = dir.appendingPathComponent(layer.asset)
            guard let bytes = try? Data(contentsOf: url) else { return nil }
            if !layer.assetSha256.isEmpty {
                let actual = sha256Hex(bytes)
                if actual != layer.assetSha256.lowercased() { return nil }
            }
            layerPNGs.append(bytes)
        }

        let compositeURL = dir.appendingPathComponent(LayeredDrawingFilenames.composite)
        let compositeBytes = try? Data(contentsOf: compositeURL)

        let thumbURL = thumbnailsDir.appendingPathComponent("\(drawingID.uuidString).jpg")
        let thumbBytes = try? Data(contentsOf: thumbURL)

        return LayeredDrawingPayload(
            manifest: manifest,
            layerPNGs: layerPNGs,
            compositeJPEG: compositeBytes,
            thumbnailJPEG: thumbBytes
        )
    }

    private func layeredTotalBytes(_ payload: LayeredDrawingPayload) -> Int64 {
        var total: Int64 = 0
        for png in payload.layerPNGs { total += Int64(png.count) }
        if let composite = payload.compositeJPEG { total += Int64(composite.count) }
        if let thumb = payload.thumbnailJPEG { total += Int64(thumb.count) }
        return total
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func retryPendingUploads() async {
        let entries = readPendingEntries()
        let activeUserID = currentEffectiveUserID()
        for entry in entries {
            // Only retry uploads belonging to the active user — entries from
            // other accounts wait for that user to sign back in.
            guard entry.userID == activeUserID else { continue }
            if activeUploadTasks[entry.drawingID] != nil { continue }
            activeUploadTasks[entry.drawingID] = Task { [weak self] in
                await self?.attemptUpload(forDrawingID: entry.drawingID)
            }
        }
    }

    private func scheduleBackoff(for id: UUID, attempts: Int) {
        let exp = min(pow(2.0, Double(attempts)), 60)   // cap at 60s
        let jitter = Double.random(in: 0...0.5)
        nextRetryAt[id] = Date().addingTimeInterval(exp + jitter)
    }

    // MARK: - Pending queue persistence

    private func writePendingEntry(_ entry: PendingUpload) {
        let url = pendingDir.appendingPathComponent("\(entry.drawingID.uuidString).json")
        do {
            let data = try Self.makeEncoder().encode(entry)
            try data.write(to: url)
        } catch {
            print("⚠️ Failed to write pending entry for \(entry.drawingID): \(error)")
        }
    }

    private func removePendingEntry(id: UUID) {
        let url = pendingDir.appendingPathComponent("\(id.uuidString).json")
        try? fileManager.removeItem(at: url)
    }

    private func readPendingEntries() -> [PendingUpload] {
        let urls = (try? fileManager.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)) ?? []
        let decoder = Self.makeDecoder()
        return urls.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(PendingUpload.self, from: data)
        }
    }

    private func incrementPendingAttempts(id: UUID) -> Int? {
        let url = pendingDir.appendingPathComponent("\(id.uuidString).json")
        let decoder = Self.makeDecoder()
        guard let data = try? Data(contentsOf: url),
              var entry = try? decoder.decode(PendingUpload.self, from: data) else { return nil }
        entry.attemptCount += 1
        entry.lastAttemptAt = Date()
        if let encoded = try? Self.makeEncoder().encode(entry) {
            try? encoded.write(to: url)
        }
        return entry.attemptCount
    }

    private func readPendingEntry(id: UUID) -> PendingUpload? {
        let url = pendingDir.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.makeDecoder().decode(PendingUpload.self, from: data)
    }

    /// Persist a mutated pending entry — used by the layered upload pipeline
    /// to record progress between resumable steps. The flat upload path uses
    /// `incrementPendingAttempts` instead and never calls this.
    private func updatePendingEntry(_ entry: PendingUpload) {
        writePendingEntry(entry)
    }

    private func countPendingEntriesForCurrentUser() -> Int {
        guard let activeUserID = currentEffectiveUserID() else { return 0 }
        return readPendingEntries().filter { $0.userID == activeUserID }.count
    }

    // MARK: - Helpers

    private func currentEffectiveUserID() -> UUID? {
        AuthManager.shared.currentUserID
    }

    private func thumbnailStoragePath(for drawing: Drawing) -> String {
        // Lowercase to match auth.uid()::text in RLS — see the UUID extension below.
        // Layered drawings store the thumbnail inside the per-drawing subdir
        // (`<user>/<id>/thumb.jpg`); legacy/flat drawings keep the original
        // `<user>/<id>_thumb.jpg` so existing rows stay reachable without a
        // bucket migration.
        if drawing.isLayered {
            return layeredThumbnailStoragePath(userID: drawing.userId, drawingID: drawing.id)
        }
        return "\(drawing.userId.lowercaseUUIDString)/\(drawing.id.lowercaseUUIDString)_thumb.jpg"
    }

    private func legacyThumbnailStoragePath(userID: UUID, drawingID: UUID) -> String {
        "\(userID.lowercaseUUIDString)/\(drawingID.lowercaseUUIDString)_thumb.jpg"
    }

    private func legacyCompositeStoragePath(userID: UUID, drawingID: UUID) -> String {
        "\(userID.lowercaseUUIDString)/\(drawingID.lowercaseUUIDString).jpg"
    }

    private func layeredRootStoragePath(userID: UUID, drawingID: UUID, pathPrefix: String = "") -> String {
        let base = "\(userID.lowercaseUUIDString)/\(drawingID.lowercaseUUIDString)"
        return pathPrefix.isEmpty ? base : "\(base)/\(pathPrefix)"
    }

    private func layeredManifestStoragePath(userID: UUID, drawingID: UUID, pathPrefix: String = "") -> String {
        "\(layeredRootStoragePath(userID: userID, drawingID: drawingID, pathPrefix: pathPrefix))/\(LayeredDrawingFilenames.manifest)"
    }

    private func layeredCompositeStoragePath(userID: UUID, drawingID: UUID, pathPrefix: String = "") -> String {
        "\(layeredRootStoragePath(userID: userID, drawingID: drawingID, pathPrefix: pathPrefix))/\(LayeredDrawingFilenames.composite)"
    }

    private func layeredThumbnailStoragePath(userID: UUID, drawingID: UUID, pathPrefix: String = "") -> String {
        "\(layeredRootStoragePath(userID: userID, drawingID: drawingID, pathPrefix: pathPrefix))/\(LayeredDrawingFilenames.thumbnail)"
    }

    private func layeredLayerStoragePath(userID: UUID, drawingID: UUID, ordinal: Int, pathPrefix: String = "") -> String {
        "\(layeredRootStoragePath(userID: userID, drawingID: drawingID, pathPrefix: pathPrefix))/\(LayeredDrawingFilenames.layer(ordinal: ordinal))"
    }

    private func localLayersDir(forDrawingID id: UUID) -> URL {
        layersDir.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    // MARK: - Codable helpers

    /// Decoder configured for the date formats Supabase / Postgres actually
    /// returns. PostgREST emits timestamptz columns as e.g.
    /// `"2026-04-29T13:43:57.339+00:00"` (fractional seconds, explicit
    /// `+00:00` offset, often 3 digits but sometimes 6). Date values stored
    /// inside jsonb columns (e.g. `critique_history[].timestamp`) come back
    /// in whatever format the original encoder used — typically ISO8601
    /// with `Z`. The custom strategy below tries multiple parsers in order
    /// so all observed shapes round-trip cleanly.
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = parseFlexibleDate(str) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date string: '\(str)'"
            )
        }
        return decoder
    }

    /// Tries every known shape Supabase / Postgres might emit for a Date.
    /// Order matters: ISO8601DateFormatter is faster than DateFormatter and
    /// covers the common cases; the explicit format strings below are the
    /// long-tail fallbacks (variable fractional digit counts, `+00:00` vs
    /// `Z`, etc.) that ISO8601DateFormatter has historically been picky about.
    private static func parseFlexibleDate(_ str: String) -> Date? {
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFractional.date(from: str) { return d }

        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        if let d = isoPlain.date(from: str) { return d }

        // Postgres timestamptz can come back with 6 fractional digits ("microseconds")
        // and either an explicit ±HH:MM offset (xxx) or "Z" (XXX). Cover both.
        //
        // The "naked" formats at the bottom (no timezone suffix at all) are for
        // dates the supabase-swift PostgrestEncoder writes into jsonb payloads
        // — e.g. CritiqueEntry.timestamp ends up stored as
        // "2026-04-29T13:43:30.253" with no Z and no offset. Top-level
        // timestamptz columns don't have this problem because PostgREST
        // formats those itself with an explicit offset. Naked datetimes are
        // interpreted as UTC because the formatter's timeZone is set below.
        let fallbackFormats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxx",
            "yyyy-MM-dd'T'HH:mm:ss.SSSxxx",
            "yyyy-MM-dd'T'HH:mm:ssxxx",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for fmt in fallbackFormats {
            formatter.dateFormat = fmt
            if let d = formatter.date(from: str) { return d }
        }
        return nil
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    /// Renders a DecodingError with the coding path, the failing value's
    /// type/key, and the underlying description. Falls back to
    /// localizedDescription for non-decode errors. Used by the catch in
    /// fetchDrawings so the Xcode console actually points at the broken field.
    static func describeDecodeFailure(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        func path(_ context: DecodingError.Context) -> String {
            let parts = context.codingPath.map { $0.stringValue }
            return parts.isEmpty ? "<root>" : parts.joined(separator: ".")
        }
        switch decodingError {
        case .keyNotFound(let key, let ctx):
            return "DecodingError.keyNotFound: '\(key.stringValue)' at '\(path(ctx))' — \(ctx.debugDescription)"
        case .typeMismatch(let type, let ctx):
            return "DecodingError.typeMismatch: expected \(type) at '\(path(ctx))' — \(ctx.debugDescription)"
        case .valueNotFound(let type, let ctx):
            return "DecodingError.valueNotFound: \(type) at '\(path(ctx))' — \(ctx.debugDescription)"
        case .dataCorrupted(let ctx):
            let underlying = ctx.underlyingError.map { " (underlying: \($0))" } ?? ""
            return "DecodingError.dataCorrupted at '\(path(ctx))' — \(ctx.debugDescription)\(underlying)"
        @unknown default:
            return "DecodingError (unrecognized variant): \(decodingError)"
        }
    }
}

// MARK: - UUID lowercasing for cloud / RLS

extension UUID {
    /// Lowercase UUID string for any value that participates in a Supabase
    /// Storage path or a PostgREST text comparison against `auth.uid()::text`.
    /// Swift's default `uuidString` is uppercase; Postgres' `auth.uid()::text`
    /// returns lowercase. RLS policies were temporarily patched with `lower()`
    /// wrappers to absorb the mismatch — once every iOS call site uses this
    /// accessor, the `lower()` wrappers in RLS become redundant and can be
    /// removed (a cleanup task tracked in authandratelimitingandsecurity.md).
    var lowercaseUUIDString: String { uuidString.lowercased() }
}

// MARK: - Pending upload entry

/// Single struct, two modes (flat vs. layered). The discriminator is `kind`,
/// which defaults to .flat when absent so pending entries written before the
/// layered-storage feature decode + retry through the existing flat path.
///
/// The layered fields all default to nil / sensible empties so a flat entry
/// round-trips losslessly and so we can extend the schema later without yet
/// another version field.
private struct PendingUpload: Codable {
    enum Kind: String, Codable {
        case flat
        case layered
    }

    let drawingID: UUID
    let userID: UUID
    let createdAt: Date
    var attemptCount: Int = 0
    var lastAttemptAt: Date?

    /// nil ≡ .flat (pre-layered entries on disk).
    var kind: Kind?

    // ---- Flat-mode fields ----
    /// Cloud path of the JPEG. Required for flat uploads, ignored for layered.
    var storagePath: String?

    // ---- Layered-mode fields (ONLINELAYERSTORE.md §5.4) ----
    /// Total layer count for this drawing. Used to know which ordinals still
    /// need uploading.
    var layerCount: Int?
    /// Ordinals already uploaded successfully (so the retry skips them).
    var uploadedLayers: [Int]?
    var uploadedComposite: Bool?
    var uploadedThumb: Bool?
    var uploadedManifest: Bool?
    var rowUpserted: Bool?
    /// Cloud paths the layered upload pipeline targets. Captured in the
    /// pending entry so the retry doesn't re-derive them and risk drift if
    /// the path-builders change underneath it.
    var manifestPath: String?
    var compositePath: String?
    var thumbPath: String?
    /// Legacy (pre-layered) Storage objects to delete after a successful
    /// upgrade upload. nil for fresh layered drawings.
    var legacyCompositePath: String?
    var legacyThumbnailPath: String?

    enum CodingKeys: String, CodingKey {
        case drawingID = "drawing_id"
        case userID = "user_id"
        case storagePath = "storage_path"
        case createdAt = "created_at"
        case attemptCount = "attempt_count"
        case lastAttemptAt = "last_attempt_at"
        case kind
        case layerCount = "layer_count"
        case uploadedLayers = "uploaded_layers"
        case uploadedComposite = "uploaded_composite"
        case uploadedThumb = "uploaded_thumb"
        case uploadedManifest = "uploaded_manifest"
        case rowUpserted = "row_upserted"
        case manifestPath = "manifest_path"
        case compositePath = "composite_path"
        case thumbPath = "thumb_path"
        case legacyCompositePath = "legacy_composite_path"
        case legacyThumbnailPath = "legacy_thumbnail_path"
    }

    init(
        drawingID: UUID,
        userID: UUID,
        storagePath: String?,
        createdAt: Date,
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil,
        kind: Kind? = nil,
        layerCount: Int? = nil,
        uploadedLayers: [Int]? = nil,
        uploadedComposite: Bool? = nil,
        uploadedThumb: Bool? = nil,
        uploadedManifest: Bool? = nil,
        rowUpserted: Bool? = nil,
        manifestPath: String? = nil,
        compositePath: String? = nil,
        thumbPath: String? = nil,
        legacyCompositePath: String? = nil,
        legacyThumbnailPath: String? = nil
    ) {
        self.drawingID = drawingID
        self.userID = userID
        self.storagePath = storagePath
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.kind = kind
        self.layerCount = layerCount
        self.uploadedLayers = uploadedLayers
        self.uploadedComposite = uploadedComposite
        self.uploadedThumb = uploadedThumb
        self.uploadedManifest = uploadedManifest
        self.rowUpserted = rowUpserted
        self.manifestPath = manifestPath
        self.compositePath = compositePath
        self.thumbPath = thumbPath
        self.legacyCompositePath = legacyCompositePath
        self.legacyThumbnailPath = legacyThumbnailPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        drawingID = try container.decode(UUID.self, forKey: .drawingID)
        userID = try container.decode(UUID.self, forKey: .userID)
        // Normalize on read — see the matching note in Drawing.init(from:).
        // Pending entries written by pre-fix builds carry uppercase paths;
        // lowercasing here means retry attempts use the RLS-compatible form.
        storagePath = try container.decodeIfPresent(String.self, forKey: .storagePath)?.lowercased()
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        attemptCount = try container.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind)
        layerCount = try container.decodeIfPresent(Int.self, forKey: .layerCount)
        uploadedLayers = try container.decodeIfPresent([Int].self, forKey: .uploadedLayers)
        uploadedComposite = try container.decodeIfPresent(Bool.self, forKey: .uploadedComposite)
        uploadedThumb = try container.decodeIfPresent(Bool.self, forKey: .uploadedThumb)
        uploadedManifest = try container.decodeIfPresent(Bool.self, forKey: .uploadedManifest)
        rowUpserted = try container.decodeIfPresent(Bool.self, forKey: .rowUpserted)
        manifestPath = try container.decodeIfPresent(String.self, forKey: .manifestPath)?.lowercased()
        compositePath = try container.decodeIfPresent(String.self, forKey: .compositePath)?.lowercased()
        thumbPath = try container.decodeIfPresent(String.self, forKey: .thumbPath)?.lowercased()
        legacyCompositePath = try container.decodeIfPresent(String.self, forKey: .legacyCompositePath)?.lowercased()
        legacyThumbnailPath = try container.decodeIfPresent(String.self, forKey: .legacyThumbnailPath)?.lowercased()
    }
}

// MARK: - Errors

enum DrawingStorageError: LocalizedError {
    case notAuthenticated
    case saveFailed
    case fetchFailed
    case cloudSyncFailed
    case drawingNotFound
    case layerIntegrity

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You must be logged in to save drawings"
        case .saveFailed:
            return "Failed to save drawing"
        case .fetchFailed:
            return "Failed to fetch drawings"
        case .cloudSyncFailed:
            return "Couldn't sync drawing to cloud — try again in a moment"
        case .drawingNotFound:
            return "Couldn't find that drawing to update — try refreshing the gallery"
        case .layerIntegrity:
            return "Couldn't verify a layer's contents — try opening the drawing again"
        }
    }
}
