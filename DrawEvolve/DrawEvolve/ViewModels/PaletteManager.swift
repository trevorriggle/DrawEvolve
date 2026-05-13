//
//  PaletteManager.swift
//  DrawEvolve
//
//  Phase 3 — Color System Overhaul. @MainActor singleton that owns the
//  user's palettes (cloud-synced via PaletteService), the active palette
//  ID (UserDefaults-backed so it persists across launches), and the
//  recent colors strip (also UserDefaults-backed).
//
//  Sync strategy: optimistic UI updates locally, fire-and-forget to the
//  worker. Last-write-wins on conflict. Local cache (UserDefaults) is a
//  backup for offline launches — the worker is canonical.
//
//  First-launch behavior: bootstrap() fetches from the worker; if the
//  list comes back empty, seed a starter palette named "My palette"
//  populated with the ColorPresets.standard grid. Survives signup →
//  delete → re-signup cleanly without database trigger state.
//

import Foundation
import SwiftUI
import UIKit

@MainActor
final class PaletteManager: ObservableObject {
    static let shared = PaletteManager()

    // MARK: - Published state

    @Published private(set) var palettes: [Palette] = []
    @Published private(set) var recentColors: [UIColor] = []
    @Published private(set) var syncState: SyncState = .idle

    /// The currently-selected palette. When the user opens the color
    /// picker the active palette's swatches show in the palette section.
    /// Persisted in UserDefaults so it survives launches.
    @Published var activePaletteID: UUID? {
        didSet {
            if let id = activePaletteID {
                UserDefaults.standard.set(id.uuidString, forKey: Self.activePaletteIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activePaletteIDKey)
            }
        }
    }

    enum SyncState: Equatable {
        case idle
        case fetching
        case syncing(palettesInFlight: Set<UUID>)
        case failed(message: String)
    }

    // MARK: - UserDefaults keys

    private static let palettesCacheKey = "DrawEvolve.Palettes.v1"
    private static let recentColorsKey = "DrawEvolve.RecentColors.v1"
    private static let activePaletteIDKey = "DrawEvolve.ActivePaletteID.v1"
    private static let bootstrapCompletedKey = "DrawEvolve.PaletteManager.bootstrapped.v1"

    private static let recentColorsCap = 16

    /// Threshold (Euclidean distance in 0-255 sRGB space) below which
    /// two colors collapse into one for the recent-colors strip.
    /// User-approved value: 12. Picking #FF8844 then #FF8845 does not
    /// produce two recent entries; the more recent one wins.
    private static let recentColorTolerance: CGFloat = 12.0

    // MARK: - Lifecycle

    private init() {
        // Load cached state synchronously on init so the picker has
        // something to render at first open even if the network is
        // slow / offline. bootstrap() fetches fresh from the worker
        // asynchronously and replaces the cache.
        self.palettes = Self.loadCachedPalettes()
        self.recentColors = Self.loadRecentColors()
        if let raw = UserDefaults.standard.string(forKey: Self.activePaletteIDKey),
           let id = UUID(uuidString: raw) {
            self.activePaletteID = id
        }
    }

    /// Called from app entry (e.g. ContentView.task) to hydrate from
    /// the worker on every cold launch. Safe to call repeatedly — the
    /// fetch is the source of truth, and the starter-palette seeding
    /// only fires when the server response is empty AND the bootstrap-
    /// completed flag is not set (so a user who deleted all their
    /// palettes intentionally doesn't get an empty-list reseed on the
    /// next launch).
    func bootstrap() async {
        syncState = .fetching
        do {
            let fetched = try await PaletteService.shared.listPalettes()
            self.palettes = fetched
            saveCachedPalettes()

            // Seed "My palette" if this is genuinely first launch
            // (no bootstrap-completed flag AND empty list).
            let hasBootstrapped = UserDefaults.standard.bool(forKey: Self.bootstrapCompletedKey)
            if !hasBootstrapped && fetched.isEmpty {
                await seedStarterPalette()
            }
            UserDefaults.standard.set(true, forKey: Self.bootstrapCompletedKey)

            // Ensure activePaletteID points to something real. If the
            // stored ID was for a palette that no longer exists (deleted
            // on another device), fall back to the most-recently-updated.
            if let active = activePaletteID, !palettes.contains(where: { $0.id == active }) {
                self.activePaletteID = palettes.first?.id
            } else if activePaletteID == nil {
                self.activePaletteID = palettes.first?.id
            }

            syncState = .idle
        } catch let err as PaletteServiceError {
            // Offline / failed: keep the cache state we loaded in init
            // and surface the error for the UI to optionally show.
            syncState = .failed(message: err.errorDescription
                ?? "Couldn't sync palettes.")
        } catch {
            syncState = .failed(message: "Couldn't sync palettes.")
        }
    }

    /// Seed the starter "My palette" on first launch with the existing
    /// ColorPresets.standard 16-swatch grid. Server confirms via
    /// PaletteService.createPalette; if that fails (offline), the
    /// palette still exists locally in memory and gets created on the
    /// next successful sync attempt (caller can retry via bootstrap()).
    private func seedStarterPalette() async {
        let seedColors = ColorPresets.standard
        do {
            let created = try await PaletteService.shared.createPalette(
                name: "My palette",
                colors: seedColors,
            )
            self.palettes = [created] + palettes
            self.activePaletteID = created.id
            saveCachedPalettes()
        } catch {
            // Server creation failed — render an in-memory placeholder
            // so the user still sees a starter. Next bootstrap() retries
            // the server side.
            let placeholder = Palette(
                name: "My palette",
                colors: seedColors.map { CodableColor($0) },
            )
            self.palettes = [placeholder] + palettes
            self.activePaletteID = placeholder.id
            saveCachedPalettes()
        }
    }

    // MARK: - Mutation API (optimistic UI; server sync in background)

    func createPalette(name: String, colors: [UIColor]) async throws {
        // Optimistic local insert first so the UI updates immediately.
        let temp = Palette(name: name, colors: colors.map { CodableColor($0) })
        palettes.insert(temp, at: 0)
        activePaletteID = temp.id
        saveCachedPalettes()

        do {
            let created = try await PaletteService.shared.createPalette(name: name, colors: colors)
            // Replace the temp row with the canonical server row.
            if let i = palettes.firstIndex(where: { $0.id == temp.id }) {
                palettes[i] = created
            } else {
                palettes.insert(created, at: 0)
            }
            activePaletteID = created.id
            saveCachedPalettes()
        } catch {
            // Roll back the optimistic insert.
            palettes.removeAll { $0.id == temp.id }
            saveCachedPalettes()
            throw error
        }
    }

    func renamePalette(id: UUID, to newName: String) async throws {
        guard let i = palettes.firstIndex(where: { $0.id == id }) else { return }
        let original = palettes[i]
        palettes[i].name = newName
        palettes[i].updatedAt = Date()
        saveCachedPalettes()

        do {
            let updated = try await PaletteService.shared.updatePalette(
                id: id, name: newName, colors: nil,
            )
            if let j = palettes.firstIndex(where: { $0.id == id }) {
                palettes[j] = updated
            }
            saveCachedPalettes()
        } catch {
            palettes[i] = original
            saveCachedPalettes()
            throw error
        }
    }

    func setColors(in id: UUID, to newColors: [UIColor]) async throws {
        guard let i = palettes.firstIndex(where: { $0.id == id }) else { return }
        let original = palettes[i]
        palettes[i].colors = newColors.map { CodableColor($0) }
        palettes[i].updatedAt = Date()
        saveCachedPalettes()

        do {
            let updated = try await PaletteService.shared.updatePalette(
                id: id, name: nil, colors: newColors,
            )
            if let j = palettes.firstIndex(where: { $0.id == id }) {
                palettes[j] = updated
            }
            saveCachedPalettes()
        } catch {
            palettes[i] = original
            saveCachedPalettes()
            throw error
        }
    }

    func addColor(_ color: UIColor, toPaletteID id: UUID) async throws {
        guard let palette = palettes.first(where: { $0.id == id }) else { return }
        var next = palette.colors.map { $0.uiColor }
        next.append(color)
        try await setColors(in: id, to: next)
    }

    func removeColor(at index: Int, fromPaletteID id: UUID) async throws {
        guard let palette = palettes.first(where: { $0.id == id }) else { return }
        guard index >= 0 && index < palette.colors.count else { return }
        var next = palette.colors.map { $0.uiColor }
        next.remove(at: index)
        try await setColors(in: id, to: next)
    }

    func reorderColors(in id: UUID, from source: IndexSet, to destination: Int) async throws {
        guard let palette = palettes.first(where: { $0.id == id }) else { return }
        var next = palette.colors.map { $0.uiColor }
        next.move(fromOffsets: source, toOffset: destination)
        try await setColors(in: id, to: next)
    }

    func deletePalette(id: UUID) async throws {
        guard let i = palettes.firstIndex(where: { $0.id == id }) else { return }
        let removed = palettes.remove(at: i)
        // If we just removed the active palette, fall back to the
        // most-recently-updated remaining palette (or nil if empty).
        if activePaletteID == id {
            activePaletteID = palettes.first?.id
        }
        saveCachedPalettes()

        do {
            try await PaletteService.shared.deletePalette(id: id)
        } catch {
            // Restore on failure.
            palettes.insert(removed, at: i)
            activePaletteID = removed.id
            saveCachedPalettes()
            throw error
        }
    }

    // MARK: - Recent colors

    /// Add a color to the recent-colors strip. Called from:
    ///   - Color picker Done / dismissal with a changed color
    ///   - Eyedropper tap (MetalCanvasView.swift, eyedropper path)
    ///   - Tapping a palette swatch
    ///   - Tapping a recent swatch (no-op visually, but bumps it to front)
    ///
    /// Dedupes against existing entries within Euclidean distance 12
    /// (sRGB scale 0-255 — about ±4 per channel). Spec-approved value.
    /// Most-recent-first ordering; capped at 16.
    func addRecentColor(_ color: UIColor) {
        recentColors.removeAll { Self.isWithinTolerance($0, color, threshold: Self.recentColorTolerance) }
        recentColors.insert(color, at: 0)
        if recentColors.count > Self.recentColorsCap {
            recentColors = Array(recentColors.prefix(Self.recentColorsCap))
        }
        saveRecentColors()
    }

    private static func isWithinTolerance(_ a: UIColor, _ b: UIColor, threshold: CGFloat) -> Bool {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let dr = (ar - br) * 255.0
        let dg = (ag - bg) * 255.0
        let db = (ab - bb) * 255.0
        let dist = (dr * dr + dg * dg + db * db).squareRoot()
        return dist < threshold
    }

    // MARK: - Cache persistence

    private static func loadCachedPalettes() -> [Palette] {
        guard let data = UserDefaults.standard.data(forKey: palettesCacheKey) else {
            return []
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode([Palette].self, from: data)) ?? []
    }

    private func saveCachedPalettes() {
        guard let data = try? JSONEncoder().encode(palettes) else { return }
        UserDefaults.standard.set(data, forKey: Self.palettesCacheKey)
    }

    private static func loadRecentColors() -> [UIColor] {
        guard let data = UserDefaults.standard.data(forKey: recentColorsKey) else {
            return []
        }
        let decoder = JSONDecoder()
        let codables = (try? decoder.decode([CodableColor].self, from: data)) ?? []
        return codables.map { $0.uiColor }
    }

    private func saveRecentColors() {
        let codables = recentColors.map { CodableColor($0) }
        guard let data = try? JSONEncoder().encode(codables) else { return }
        UserDefaults.standard.set(data, forKey: Self.recentColorsKey)
    }
}
