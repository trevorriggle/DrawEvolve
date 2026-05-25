//
//  LayerCompositeCache.swift
//  DrawEvolve
//
//  Per-layer cached composite intermediates with LRU pooling.
//

import Foundation
import Metal
import CoreGraphics

/// Pool of cached per-layer composite intermediates. The per-frame
/// draw loop normally re-runs the per-layer tile composite for every
/// visible layer; this cache lets it skip that work when a layer's
/// content hasn't changed since the prior cached snapshot.
///
/// **Invalidation signal:** `TileGrid.compositeVersion`. Cache entries
/// are keyed on `(layerId, compositeVersion)` — if either differs from
/// the cached entry, it's a miss and the caller composes into a fresh
/// (or LRU-evicted-and-reused) texture.
///
/// **Viewport independence by design.** The cached intermediate stores
/// the FULL un-culled composite of the layer's tile content in
/// canvas-pixel space. Viewport transform (zoom/pan/rotation/flip) is
/// applied at the drawable display draw step downstream — it does NOT
/// affect what gets cached. This means viewport changes (pan/zoom
/// gestures) DON'T invalidate the cache; only content changes do.
/// (For the analysis behind this choice over a viewport-keyed cache,
/// see tile-rendering-audit.md Tier B item 6 design discussion.)
///
/// **Active wet-ink layer bypass.** Callers should bypass this cache
/// for the layer holding the active wet-ink stroke, because:
///   1. The wet-ink scratch composite is hardcoded to write onto the
///      renderer's `tileDisplayIntermediate`.
///   2. Every touch event bumps `compositeVersion` on the active
///      layer's grid — cache would miss every frame anyway, wasting
///      lookup + alloc.
/// The bypass uses the existing `tileDisplayIntermediate` path with
/// slice-4 viewport cull intact.
///
/// **Cold-start cost.** First `draw(in:)` after canvas open hits the
/// cache for every visible layer — all miss → all do full uncached
/// composes in one frame. For an 8-layer ~25% coverage 2048² doc this
/// is ~6-10 ms of extra frame time on frame 1 only. Subsequent frames
/// settle into the cache hit pattern. Don't be alarmed if Instruments
/// shows a spike on the first frame; it's not a bug.
///
/// **Pool sizing.** Default `maxSize = 6` covers the typical
/// DrawEvolve doc (4-6 active layers) with no eviction. Larger docs
/// see LRU thrash on the cold layers — still a win vs no cache. At
/// 2048² canvas, 6 entries = 96 MB. iPad mini 6 (~256 MB renderer
/// budget) hits the edge; the memory-warning handler should call
/// `evictDownTo(_:)` to drop to 3 entries (48 MB) under pressure.
///
/// **Failure mode.** `reserve(forKey:)` returns nil if Metal can't
/// allocate the texture (rare; out-of-GPU-memory). Callers fall back
/// to the existing `tileDisplayIntermediate` path — identical to
/// pre-cache behaviour.
///
/// Not thread-safe. The renderer drives this from the main thread
/// (where `draw(in:)` runs) and SwiftUI lifecycle is also main; the
/// cache is implicitly main-actor-bound by usage.
final class LayerCompositeCache {

    /// Hashable identity for a cached composite. Two entries with the
    /// same `(layerId, compositeVersion)` represent bit-identical
    /// composites of the same layer's tile content.
    struct Key: Hashable {
        let layerId: UUID
        let compositeVersion: UInt64
    }

    /// One entry in the cache. The texture is canvas-sized
    /// `.bgra8Unorm` `.private`, sized to the canvas at allocation
    /// time. `lastAccessTick` drives LRU eviction.
    private struct Entry {
        var key: Key
        let texture: MTLTexture
        var lastAccessTick: UInt64
    }

    private let device: MTLDevice
    private(set) var canvasSize: CGSize
    private(set) var maxSize: Int
    private var entries: [UUID: Entry] = [:]
    private var accessTick: UInt64 = 0

    /// Initialise empty. `canvasSize` is captured for the texture
    /// descriptors; if canvas size changes, the renderer should call
    /// `clear()` and let the cache lazily rebuild at the new size.
    init(device: MTLDevice, canvasSize: CGSize, maxSize: Int = 6) {
        precondition(maxSize > 0, "LayerCompositeCache.maxSize must be positive")
        self.device = device
        self.canvasSize = canvasSize
        self.maxSize = maxSize
    }

    /// Look up a cached composite by exact key. Bumps `lastAccessTick`
    /// on hit so LRU eviction prefers cold layers. Returns nil if the
    /// layer isn't in the pool, OR if the stored entry's
    /// `compositeVersion` differs from `key.compositeVersion` (content
    /// changed since the cached snapshot).
    func cached(forKey key: Key) -> MTLTexture? {
        guard var entry = entries[key.layerId], entry.key == key else {
            return nil
        }
        accessTick &+= 1
        entry.lastAccessTick = accessTick
        entries[key.layerId] = entry
        return entry.texture
    }

    /// Reserve a texture to compose into for `key`. The returned
    /// texture is either freshly allocated, an evicted entry's texture
    /// being reused (under LRU pressure), or the same layer's previous
    /// texture (its `compositeVersion` advanced — reuse the slot).
    ///
    /// After the caller composes into the returned texture, future
    /// `cached(forKey:)` lookups with the same key will hit. The
    /// caller MUST treat the returned texture as the cache's storage —
    /// don't mutate it after the compose is complete.
    ///
    /// Returns nil if Metal allocation fails under memory pressure.
    /// Callers should fall back to composing into a non-cached
    /// intermediate (the renderer's existing `tileDisplayIntermediate`).
    func reserve(forKey key: Key) -> MTLTexture? {
        accessTick &+= 1

        // Case 1: layer already has a slot. Reuse the texture, update
        // the key to the new compositeVersion. No alloc.
        if var existing = entries[key.layerId] {
            existing.key = key
            existing.lastAccessTick = accessTick
            entries[key.layerId] = existing
            return existing.texture
        }

        // Case 2: pool has room. Allocate a new texture.
        if entries.count < maxSize {
            guard let texture = makeIntermediateTexture() else { return nil }
            entries[key.layerId] = Entry(key: key,
                                         texture: texture,
                                         lastAccessTick: accessTick)
            return texture
        }

        // Case 3: pool full + no slot for this layer. Evict the
        // least-recently-accessed entry and reuse its texture.
        guard let evictKey = entries.min(by: {
            $0.value.lastAccessTick < $1.value.lastAccessTick
        })?.key else {
            return nil
        }
        guard let evicted = entries.removeValue(forKey: evictKey) else {
            return nil
        }
        entries[key.layerId] = Entry(key: key,
                                     texture: evicted.texture,
                                     lastAccessTick: accessTick)
        return evicted.texture
    }

    /// Drop entries until the pool holds at most `targetSize`. Called
    /// from the memory-warning observer to release texture memory
    /// under pressure. Evicts LRU first. `targetSize` is also installed
    /// as the new `maxSize` ceiling so subsequent allocations stay
    /// under the lower budget until the cap is bumped again.
    func evictDownTo(_ targetSize: Int) {
        let clamped = max(0, targetSize)
        maxSize = clamped
        while entries.count > clamped {
            guard let evictKey = entries.min(by: {
                $0.value.lastAccessTick < $1.value.lastAccessTick
            })?.key else { break }
            entries.removeValue(forKey: evictKey)
        }
    }

    /// Drop every entry. Used on canvas-size change (cached intermediates
    /// are sized to the old canvas; new entries will allocate at the new
    /// size). Also called on renderer teardown to release GPU memory
    /// promptly.
    func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    /// Update the canvas size used for future allocations and clear
    /// existing entries (they're sized to the old canvas). Idempotent
    /// when called with the current size — no-op.
    func updateCanvasSize(_ newSize: CGSize) {
        guard newSize != canvasSize else { return }
        canvasSize = newSize
        clear()
    }

    /// Current pool occupancy. Surface for diagnostics / tests.
    var count: Int { entries.count }

    // MARK: - Private

    private func makeIntermediateTexture() -> MTLTexture? {
        let targetW = Int(canvasSize.width)
        let targetH = Int(canvasSize.height)
        guard targetW > 0, targetH > 0 else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: targetW,
            height: targetH,
            mipmapped: false
        )
        desc.storageMode = .private
        desc.usage = [.renderTarget, .shaderRead]
        return device.makeTexture(descriptor: desc)
    }
}
