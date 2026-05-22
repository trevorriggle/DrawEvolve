// TileGrid.swift
// DrawEvolve
//
// Sparse tile-grid storage backing a layer's pixels under the tiling
// migration. Phase 1: type only, no callers wired up.

import CoreGraphics
import Metal

/// Sparse tile-based storage for one drawing layer's pixels.
///
/// The grid covers a logical area of `canvasSize` pixels divided into
/// `tileSize × tileSize` cells. Cells are allocated lazily on write
/// (`ensureTile(at:)`) and freed individually (`dropTile(at:)`) — a typical
/// drawing with 5-30% canvas coverage holds 5-30% of the maximum tile count.
///
/// Coordinate model:
/// - `canvasSize` is in layer-local pixels.
/// - `TileKey(x: tx, y: ty)` indexes a tile whose pixel rect is
///   `(tx * tileSize, ty * tileSize, tileSize, tileSize)`.
/// - Valid keys satisfy `0 ≤ tx < gridWidth` and `0 ≤ ty < gridHeight`. The
///   API does not enforce these bounds on `ensureTile`/`tile`/`dropTile`;
///   `tilesIntersecting(_:)` is responsible for clamping. Callers that
///   construct keys directly must clamp themselves.
///
/// Immutability of grid dimensions:
/// `tileSize`, `canvasSize`, `gridWidth`, and `gridHeight` are captured at
/// initialization and never change. This resolves the audit's
/// canvas-size-mutation hazard (Section 6.5 point 1) by contract — a
/// drawing's tile grid is fixed for the drawing's lifetime. Phase 2 will
/// enforce this at the renderer level by re-creating the grid on
/// canvas-size changes rather than mutating it.
///
/// Thread safety: NOT thread-safe. The renderer drives this from a single
/// Metal command queue and SwiftUI updates run on the main actor; callers
/// must serialize access externally.
final class TileGrid {

    /// Side length of each tile in pixels (square tiles).
    let tileSize: Int

    /// Logical pixel size of the layer this grid stores.
    let canvasSize: CGSize

    /// Number of tile columns. `ceil(canvasSize.width / tileSize)`, minimum 1.
    let gridWidth: Int

    /// Number of tile rows. `ceil(canvasSize.height / tileSize)`, minimum 1.
    let gridHeight: Int

    private let device: MTLDevice
    private var tiles: [TileKey: LayerTile] = [:]

    /// Cached `allocatedKeys()` result. Invalidated to nil on every tile
    /// insert/drop; rebuilt lazily on next read. The per-frame composite
    /// loop calls `allocatedKeys()` once per visible layer, and large
    /// drawings can have hundreds of allocated tiles — re-boxing the
    /// dictionary keys into a fresh Array on every read was a measurable
    /// cost on older GPUs. The cache pays the rebuild only when the tile
    /// set actually changes.
    private var cachedAllocatedKeys: [TileKey]? = nil

    /// Creates an empty tile grid.
    ///
    /// - Parameters:
    ///   - canvasSize: Logical layer size in pixels. Values ≤ 0 in either
    ///     dimension still produce a grid with `gridWidth`/`gridHeight ≥ 1`
    ///     so the grid is well-formed but empty (no key intersects).
    ///   - tileSize: Side length of each tile. Defaults to 256 (Phase 1
    ///     decision; see audit Section 4.2). Must be > 0; values ≤ 0 are
    ///     a programmer error and trigger a precondition failure.
    ///   - device: Metal device used to allocate tile textures.
    init(canvasSize: CGSize, tileSize: Int = 256, device: MTLDevice) {
        precondition(tileSize > 0, "TileGrid.tileSize must be positive (got \(tileSize))")
        self.tileSize = tileSize
        self.canvasSize = canvasSize
        let widthCells = Int((canvasSize.width / CGFloat(tileSize)).rounded(.up))
        let heightCells = Int((canvasSize.height / CGFloat(tileSize)).rounded(.up))
        self.gridWidth = max(1, widthCells)
        self.gridHeight = max(1, heightCells)
        self.device = device
    }

    /// Returns the tile at `key` if allocated, `nil` otherwise.
    ///
    /// Does not allocate. Out-of-bounds keys also return `nil`.
    func tile(at key: TileKey) -> LayerTile? {
        tiles[key]
    }

    /// Returns the tile at `key`, allocating it if absent.
    ///
    /// Allocated textures are `.bgra8Unorm` with `storageMode = .private`
    /// and `usage = [.shaderRead, .renderTarget]`. Metal does not guarantee
    /// initial contents for `.private` textures — Phase 2 callers are
    /// responsible for issuing a clear render pass on first use. Calling
    /// this method twice with the same `key` returns the same tile both
    /// times.
    ///
    /// Out-of-bounds keys are still honored — the grid does not enforce
    /// bounds on `ensureTile` because the integer math in
    /// `tilesIntersecting(_:)` already clamps before constructing keys.
    /// Callers that build keys by hand are responsible for their own
    /// bounds checks.
    ///
    /// - Returns: `nil` when `device.makeTexture` fails (out-of-GPU-memory).
    ///   Callers must handle nil gracefully — the prior `fatalError` path
    ///   converted OOM into a crash on memory-pressured devices. Now a
    ///   failed alloc logs via CrashReporter and the caller can skip the
    ///   tile or surface an error to the user.
    func ensureTile(at key: TileKey) -> LayerTile? {
        if let existing = tiles[key] {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: tileSize,
            height: tileSize,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            CrashReporter.shared.logWarning(
                "TileGrid: failed to allocate \(tileSize)x\(tileSize) tile texture at (\(key.x), \(key.y)) — likely OOM",
                context: "TileGrid.ensureTile"
            )
            return nil
        }
        let tile = LayerTile(texture: texture,
                             dirtyVersion: 0,
                             nonTransparentBits: 0,
                             wasCleared: false)
        tiles[key] = tile
        cachedAllocatedKeys = nil
        return tile
    }

    /// Allocate a tile if absent and schedule a transparent-clear render
    /// pass on `commandBuffer` when the tile's `wasCleared` flag is false.
    /// After this returns, the tile is allocated and its `wasCleared`
    /// flag is true.
    ///
    /// **When to call this instead of `ensureTile(at:)`.** The blit-only
    /// dual-write callsites (renderImage / floodFill / flip-edge /
    /// translate-edge) can write to a freshly-allocated `.private` tile
    /// where the blit covers only part of the tile's pixels — Metal
    /// doesn't define what the unblitted region contains. The empty
    /// `loadAction = .clear` render pass scheduled here zeroes the whole
    /// tile before the caller's blit lands; afterwards the blit overwrites
    /// its covered region and the rest stays transparent.
    ///
    /// Render-pass callsites (renderStroke / compositeFloatingTextureInto
    /// Layer) don't need this helper — they already set
    /// `loadAction = .clear` on their own encoder when wasCleared is
    /// false.
    ///
    /// `commandBuffer` is the buffer the caller is about to commit. The
    /// clear render pass is encoded onto it (one no-draw render encoder),
    /// so the clear executes before any subsequent blit on the same
    /// buffer. Metal serialises encoders within a command buffer in
    /// submission order.
    ///
    /// `dirtyVersion` is NOT bumped by this method — the caller's
    /// subsequent `updateTile(at:_:)` handles that. We want one bump per
    /// logical write, not two for "clear + write."
    ///
    /// If render encoder construction fails, this method silently skips
    /// the clear and `wasCleared` stays false. The next call will retry.
    /// This matches Metal's nil-return failure mode and keeps the
    /// signature non-throwing for ergonomics at the call sites.
    func ensureTileWithClearIfNeeded(at key: TileKey,
                                     onCommandBuffer commandBuffer: MTLCommandBuffer) -> LayerTile? {
        let needsClear = (tiles[key]?.wasCleared ?? false) == false
        guard let allocated = ensureTile(at: key) else { return nil }
        if needsClear {
            let desc = MTLRenderPassDescriptor()
            desc.colorAttachments[0].texture = allocated.texture
            desc.colorAttachments[0].loadAction = .clear
            desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            desc.colorAttachments[0].storeAction = .store
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: desc) {
                enc.endEncoding()
                var bumped = allocated
                bumped.wasCleared = true
                tiles[key] = bumped
                return bumped
            }
        }
        return allocated
    }

    /// Runs `body` with the current tile at `key`, then bumps the tile's
    /// metadata (`wasCleared = true`, `dirtyVersion &+= 1`) only if `body`
    /// returns normally.
    ///
    /// **Failure semantics.** If `body` throws (e.g., the caller could not
    /// create a Metal render encoder for the tile), the tile's metadata
    /// stays at its prior state. Pixel-side state may be inconsistent —
    /// the caller's partial render may have touched the tile's texture —
    /// but `dirtyVersion` accurately reflects "this tile was last
    /// successfully written at the prior version." Task 5's verification
    /// harness depends on this contract: a bumped `dirtyVersion` on a
    /// failed render would surface as a spurious mismatch.
    ///
    /// **No-op if `key` is absent.** Callers that want allocate-on-write
    /// semantics should call `ensureTile(at:)` first; this method
    /// deliberately does not allocate.
    ///
    /// **Mutates only `wasCleared` and `dirtyVersion`.** Other fields
    /// (`nonTransparentBits`, the `texture` reference) are not touched.
    /// Phase 6+ optimisations that need to update `nonTransparentBits`
    /// will require a separate API.
    ///
    /// The closure receives the tile by value, so it can read fields like
    /// `wasCleared` (to choose `loadAction`) and the `texture` reference
    /// (to bind as the render target), but it cannot mutate the stored
    /// tile directly — all metadata writes are owned by this method.
    func updateTile(at key: TileKey, _ body: (LayerTile) throws -> Void) rethrows {
        guard let tile = tiles[key] else { return }
        try body(tile)
        var bumped = tile
        bumped.wasCleared = true
        bumped.dirtyVersion &+= 1
        tiles[key] = bumped
    }

    /// Drops the tile at `key` if allocated. No-op if absent.
    ///
    /// Used by full-clear operations and by the eraser path when a stamp
    /// fully covers a tile. After `dropTile(at: k)`, `tile(at: k)` returns
    /// `nil` until the next `ensureTile(at: k)`.
    func dropTile(at key: TileKey) {
        if tiles.removeValue(forKey: key) != nil {
            cachedAllocatedKeys = nil
        }
    }

    /// Returns all tile keys whose pixel rect intersects `docRect`.
    ///
    /// `docRect` is in layer-local pixel space, treated as half-open
    /// `[minX, maxX) × [minY, maxY)`. Result is clamped to the grid bounds.
    ///
    /// Edge cases:
    /// - A zero-size or null rect returns an empty array.
    /// - A rect entirely outside the canvas returns an empty array.
    /// - A rect that partly extends past the canvas clamps to the
    ///   in-bounds intersection; keys outside the grid are not included.
    ///
    /// The returned keys are not guaranteed to be allocated. Callers that
    /// want only allocated tiles should filter with `tile(at:)`.
    func tilesIntersecting(_ docRect: CGRect) -> [TileKey] {
        if docRect.isNull || docRect.isEmpty {
            return []
        }
        let size = CGFloat(tileSize)
        let rawMinX = Int((docRect.minX / size).rounded(.down))
        let rawMinY = Int((docRect.minY / size).rounded(.down))
        let rawMaxX = Int((docRect.maxX / size).rounded(.up)) - 1
        let rawMaxY = Int((docRect.maxY / size).rounded(.up)) - 1
        let minX = max(0, rawMinX)
        let minY = max(0, rawMinY)
        let maxX = min(gridWidth - 1, rawMaxX)
        let maxY = min(gridHeight - 1, rawMaxY)
        if minX > maxX || minY > maxY {
            return []
        }
        var result: [TileKey] = []
        result.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
        for ty in minY...maxY {
            for tx in minX...maxX {
                result.append(TileKey(x: tx, y: ty))
            }
        }
        return result
    }

    /// Snapshot of currently-allocated tile keys. Order is undefined.
    ///
    /// Returns an array (not a lazy sequence) so callers can iterate
    /// without holding a reference to the underlying dictionary; this also
    /// keeps the API simple for v1 per the spec.
    ///
    /// Memoized: the array is built once and reused until the next
    /// `ensureTile` / `dropTile` invalidates it. Callers that hold the
    /// returned array across mutations get the stale snapshot they
    /// implicitly wanted (Array is a value type).
    func allocatedKeys() -> [TileKey] {
        if let cached = cachedAllocatedKeys { return cached }
        let built = Array(tiles.keys)
        cachedAllocatedKeys = built
        return built
    }
}
