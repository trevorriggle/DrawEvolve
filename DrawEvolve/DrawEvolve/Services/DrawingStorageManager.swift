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
import Foundation
import Network
import Supabase
import UIKit

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
    private let thumbnailMaxDimension: CGFloat = 256
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

    private init() {
        for dir in [metadataDir, thumbnailsDir, imagesDir, pendingDir] {
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

        try persistLocally(drawing: drawing, imageData: imageData)
        drawings.insert(drawing, at: 0)
        print("💾 Saved drawing locally: \(drawing.id) '\(title)' (\(critiqueHistory.count) critiques)")

        enqueueUpload(for: drawing)
        return drawing
    }

    // MARK: - Update

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
            print("❌ updateDrawing: drawing \(id) not in memory")
            return
        }

        var drawing = drawings[index]
        if let title { drawing.title = title }
        if let feedback { drawing.feedback = feedback }
        if let context { drawing.context = context }
        if let critiqueHistory { drawing.critiqueHistory = critiqueHistory }
        drawing.updatedAt = Date()

        try persistLocally(drawing: drawing, imageData: imageData)
        drawings[index] = drawing
        print("💾 Updated drawing locally: \(id) '\(drawing.title)'")

        enqueueUpload(for: drawing)
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
                .remove(paths: [drawing.storagePath, thumbnailStoragePath(for: drawing)])
        } catch {
            print("☁️ deleteDrawing cloud delete failed (kept local delete): \(error.localizedDescription)")
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

        // Wipe local cache contents (but keep the directories).
        for dir in [metadataDir, thumbnailsDir, imagesDir, pendingDir] {
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
                    .remove(paths: [drawing.storagePath, thumbnailStoragePath(for: drawing)])
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
    func loadFullImage(for id: UUID) async throws -> Data? {
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

        do {
            let signed = try await client.storage
                .from(storageBucketID)
                .createSignedURL(path: drawing.storagePath, expiresIn: signedURLTTLSeconds)
            let (data, _) = try await URLSession.shared.data(from: signed)
            try? data.write(to: url)
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
                    path: drawing.storagePath,
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
        "\(drawing.userId.lowercaseUUIDString)/\(drawing.id.lowercaseUUIDString)_thumb.jpg"
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

private struct PendingUpload: Codable {
    let drawingID: UUID
    let userID: UUID
    let storagePath: String
    let createdAt: Date
    var attemptCount: Int = 0
    var lastAttemptAt: Date?

    enum CodingKeys: String, CodingKey {
        case drawingID = "drawing_id"
        case userID = "user_id"
        case storagePath = "storage_path"
        case createdAt = "created_at"
        case attemptCount = "attempt_count"
        case lastAttemptAt = "last_attempt_at"
    }

    init(
        drawingID: UUID,
        userID: UUID,
        storagePath: String,
        createdAt: Date,
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil
    ) {
        self.drawingID = drawingID
        self.userID = userID
        self.storagePath = storagePath
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        drawingID = try container.decode(UUID.self, forKey: .drawingID)
        userID = try container.decode(UUID.self, forKey: .userID)
        // Normalize on read — see the matching note in Drawing.init(from:).
        // Pending entries written by pre-fix builds carry uppercase paths;
        // lowercasing here means retry attempts use the RLS-compatible form.
        storagePath = try container.decode(String.self, forKey: .storagePath).lowercased()
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        attemptCount = try container.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
    }
}

// MARK: - Errors

enum DrawingStorageError: LocalizedError {
    case notAuthenticated
    case saveFailed
    case fetchFailed
    case cloudSyncFailed

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
        }
    }
}
