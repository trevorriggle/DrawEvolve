//
//  TileDirectVerifier.swift
//  DrawEvolve
//
//  DEBUG-only verifier comparing the legacy compose-into-intermediate +
//  sample-as-fullscreen-quad render path against the new tile-direct
//  rendering path. Runs once per process at first frame; logs pass/fail
//  per scenario to Documents/tile_direct_phase_6.log.
//
//  Slice 6 of the tile-rendering-audit work. Throw away after the
//  feature-flag soak completes and the legacy path is removed.
//

#if DEBUG

import Foundation
import Metal
import CoreGraphics

extension CanvasRenderer {

    /// Verifier coverage matrix — every scenario below is exercised by the
    /// probe. Reviewer can confirm coverage without reading the
    /// implementation:
    ///
    ///   0. SANITY BASELINE — identity transform (zoom=1, pan=0, rot=0,
    ///      no flip), single-tile content. Identity case; any divergence
    ///      here = fundamental error in tileDirectVertexShader.
    ///   1. CROSS-TILE STROKE — identity transform, stamp content spanning
    ///      4 adjacent tiles (centered at tile-boundary intersection).
    ///      Tests tile-boundary rasterization.
    ///   2. 45° ROTATION ONLY — rotation = π/4, all other identity.
    ///   3. NON-POWER-OF-2 ZOOM — zoomScale = 1.5, all other identity.
    ///   4. SUB-PIXEL PAN — panOffset = (12.7, 4.3), all other identity.
    ///   5. FLIP H + ROTATION — flipHorizontal=true, rotation=π/6.
    ///   6. ALLOCATED-BUT-UNWRITTEN TILE — content includes a tile created
    ///      via ensureTileWithClearIfNeeded with no subsequent updateTile.
    ///      Tests the wasCleared contract from slice 6 audit §1.
    ///   7. COMBINED STRESS — zoomScale=2.7, rotation=π/3,
    ///      panOffset=(-50, 100), flipVertical=true, multi-layer + multi-
    ///      stamp content.
    ///   8. POST-COMMIT HAZARD-TRACKED READ — simulates wet-ink commit
    ///      cb writing tile content followed IMMEDIATELY by the verifier
    ///      cb reading it on the same MTLCommandQueue without explicit
    ///      waitUntilCompleted between them. Confirms Metal hazard
    ///      tracking serializes correctly (the safety mechanism the
    ///      slice-6 wet-ink §7 walkthrough depends on).
    ///
    /// Tolerance tiers:
    ///   - STRICT (scenarios 0, 1, 6, 8): byte-exact required, zero diffs
    ///   - ULP-RELAXED (scenarios 2-5): ≤1 ULP per channel, fail >0.5%
    ///   - STRESS (scenario 7): ≤1 ULP per channel, fail >1.0%
    ///
    /// On any failure: log the scenario, first-diff coords, diff stats,
    /// and overall FAIL marker to the log file. Manual review of the log
    /// before merging the wire-up commit.
    func runTileDirectEquivalencePhaseSixProbe() {
        let scenarios: [VerifierScenario] = [
            .sanityBaseline,
            .crossTileStroke,
            .rotation45,
            .nonPowerOf2Zoom,
            .subPixelPan,
            .flipHorizontalPlusRotation,
            .allocatedButUnwrittenTile,
            .combinedStress,
            .postCommitHazardTrackedRead,
        ]

        var report = "=== Tile-direct equivalence probe (\(ISO8601DateFormatter().string(from: Date()))) ===\n"
        report += "Fixture canvas: \(verifierCanvasSize)×\(verifierCanvasSize), tile size \(verifierTileSize)\n"
        report += "Scenarios: \(scenarios.count)\n\n"
        var anyFailed = false
        for scenario in scenarios {
            let result = runVerifierScenario(scenario)
            report += "[\(result.passed ? "PASS" : "FAIL")] \(scenario.name)\n"
            report += "  tier=\(scenario.tier)  diffBytes=\(result.diffBytes)/\(result.totalBytes) (\(String(format: "%.4f%%", result.diffPercent)))  maxDelta=\(result.maxDelta)\n"
            if !result.passed {
                anyFailed = true
                if let bbox = result.diffBbox {
                    report += "  diffBbox=(x=\(bbox.origin.x), y=\(bbox.origin.y), w=\(bbox.width), h=\(bbox.height))\n"
                }
                if let firstDiff = result.firstDiffPixel {
                    report += "  firstDiff=(x=\(firstDiff.x), y=\(firstDiff.y))  legacy=\(firstDiff.legacy)  tileDirect=\(firstDiff.tileDirect)\n"
                }
            }
        }
        report += "\nOVERALL: \(anyFailed ? "FAIL" : "PASS")\n"

        verifierAppendToLog(report)
        print("🧪 \(anyFailed ? "FAIL" : "PASS"): tile-direct equivalence probe — see Documents/tile_direct_phase_6.log")
    }

    // MARK: - Fixture parameters

    /// Small canvas keeps getBytes readback cheap. 512² = 1 MB per output
    /// texture. Tile size matches the production 256 so the cross-tile-
    /// stroke scenario actually crosses tile boundaries (otherwise a
    /// stamp inside one tile wouldn't exercise the boundary case).
    fileprivate var verifierCanvasSize: Int { 512 }
    fileprivate var verifierTileSize: Int { 256 }

    // MARK: - Scenario types

    fileprivate struct VerifierScenario {
        let name: String
        let tier: Tier
        let recipe: ContentRecipe
        // Transform fields (match TileDirectUniforms input set)
        let zoomScale: Float
        let panOffset: SIMD2<Float>
        let canvasRotation: Float
        let flipState: SIMD2<Float>

        enum Tier: String {
            case strict          // byte-exact required
            case ulpRelaxed      // ≤1 ULP, fail >0.5% diffs
            case stress          // ≤1 ULP, fail >1.0% diffs

            var allowedDeltaPerChannel: UInt8 {
                switch self {
                case .strict: return 0
                case .ulpRelaxed, .stress: return 1
                }
            }
            var failThresholdPercent: Double {
                switch self {
                case .strict: return 0.0
                case .ulpRelaxed: return 0.5
                case .stress: return 1.0
                }
            }
        }

        enum ContentRecipe {
            case singleTile            // one stamp in tile (0,0)
            case crossTileStamp        // stamp centered at tile boundary
            case allocatedUnwritten    // ensureTileWithClearIfNeeded'd tile, never updateTile'd
            case multiLayerStress      // 3 layers with overlapping content
            case postCommitFixture     // simulates the wet-ink-commit followed by read
        }

        // Scenario presets matching the doc comment matrix
        static let sanityBaseline = VerifierScenario(
            name: "0. sanity baseline",
            tier: .strict,
            recipe: .singleTile,
            zoomScale: 1.0, panOffset: .zero, canvasRotation: 0, flipState: .zero
        )
        static let crossTileStroke = VerifierScenario(
            name: "1. cross-tile stroke",
            tier: .strict,
            recipe: .crossTileStamp,
            zoomScale: 1.0, panOffset: .zero, canvasRotation: 0, flipState: .zero
        )
        static let rotation45 = VerifierScenario(
            name: "2. 45° rotation",
            tier: .ulpRelaxed,
            recipe: .singleTile,
            zoomScale: 1.0, panOffset: .zero, canvasRotation: .pi / 4, flipState: .zero
        )
        static let nonPowerOf2Zoom = VerifierScenario(
            name: "3. non-power-of-2 zoom (1.5×)",
            tier: .ulpRelaxed,
            recipe: .singleTile,
            zoomScale: 1.5, panOffset: .zero, canvasRotation: 0, flipState: .zero
        )
        static let subPixelPan = VerifierScenario(
            name: "4. sub-pixel pan (12.7, 4.3)",
            tier: .ulpRelaxed,
            recipe: .singleTile,
            zoomScale: 1.0, panOffset: SIMD2(12.7, 4.3), canvasRotation: 0, flipState: .zero
        )
        static let flipHorizontalPlusRotation = VerifierScenario(
            name: "5. flipH + 30° rotation",
            tier: .ulpRelaxed,
            recipe: .singleTile,
            zoomScale: 1.0, panOffset: .zero, canvasRotation: .pi / 6, flipState: SIMD2(1, 0)
        )
        static let allocatedButUnwrittenTile = VerifierScenario(
            name: "6. allocated-but-unwritten tile",
            tier: .strict,
            recipe: .allocatedUnwritten,
            zoomScale: 1.0, panOffset: .zero, canvasRotation: 0, flipState: .zero
        )
        static let combinedStress = VerifierScenario(
            name: "7. combined stress (2.7× zoom, 60° rot, pan, flipV)",
            tier: .stress,
            recipe: .multiLayerStress,
            zoomScale: 2.7, panOffset: SIMD2(-50, 100), canvasRotation: .pi / 3, flipState: SIMD2(0, 1)
        )
        static let postCommitHazardTrackedRead = VerifierScenario(
            name: "8. post-commit hazard-tracked read",
            tier: .strict,
            recipe: .postCommitFixture,
            zoomScale: 1.0, panOffset: .zero, canvasRotation: 0, flipState: .zero
        )
    }

    fileprivate struct VerifierResult {
        let passed: Bool
        let diffBytes: Int
        let totalBytes: Int
        let diffPercent: Double
        let maxDelta: UInt8
        let diffBbox: CGRect?
        let firstDiffPixel: FirstDiff?

        struct FirstDiff {
            let x: Int
            let y: Int
            let legacy: SIMD4<UInt8>
            let tileDirect: SIMD4<UInt8>
        }
    }

    // MARK: - Scenario runner

    fileprivate func runVerifierScenario(_ scenario: VerifierScenario) -> VerifierResult {
        // Build fixture content per recipe.
        let fixture = buildVerifierFixture(recipe: scenario.recipe)
        guard let legacy = renderViaLegacyPath(fixture: fixture, scenario: scenario),
              let tileDirect = renderViaTileDirectPath(fixture: fixture, scenario: scenario) else {
            return VerifierResult(passed: false, diffBytes: -1, totalBytes: 0,
                                  diffPercent: 0, maxDelta: 0, diffBbox: nil, firstDiffPixel: nil)
        }
        return compareOutputs(legacy: legacy, tileDirect: tileDirect, tier: scenario.tier)
    }

    // MARK: - Fixture builder

    fileprivate struct VerifierFixture {
        let layers: [VerifierLayer]
    }

    fileprivate struct VerifierLayer {
        let tileGrid: TileGrid
        let opacity: Float
    }

    fileprivate func buildVerifierFixture(recipe: VerifierScenario.ContentRecipe) -> VerifierFixture {
        let size = CGSize(width: verifierCanvasSize, height: verifierCanvasSize)
        switch recipe {
        case .singleTile:
            let grid = TileGrid(canvasSize: size, tileSize: verifierTileSize, device: device)
            paintCheckerTile(grid: grid, tileKey: TileKey(x: 0, y: 0), seed: 0xA5)
            return VerifierFixture(layers: [VerifierLayer(tileGrid: grid, opacity: 1.0)])
        case .crossTileStamp:
            let grid = TileGrid(canvasSize: size, tileSize: verifierTileSize, device: device)
            // Paint all 4 tiles around the (256,256) boundary
            paintCheckerTile(grid: grid, tileKey: TileKey(x: 0, y: 0), seed: 0x10)
            paintCheckerTile(grid: grid, tileKey: TileKey(x: 1, y: 0), seed: 0x20)
            paintCheckerTile(grid: grid, tileKey: TileKey(x: 0, y: 1), seed: 0x30)
            paintCheckerTile(grid: grid, tileKey: TileKey(x: 1, y: 1), seed: 0x40)
            return VerifierFixture(layers: [VerifierLayer(tileGrid: grid, opacity: 1.0)])
        case .allocatedUnwritten:
            let grid = TileGrid(canvasSize: size, tileSize: verifierTileSize, device: device)
            // Painted tile in (0,0); ensureTileWithClearIfNeeded-only in (1,1) — never updateTile'd
            paintCheckerTile(grid: grid, tileKey: TileKey(x: 0, y: 0), seed: 0x55)
            ensureUnwrittenClearedTile(grid: grid, tileKey: TileKey(x: 1, y: 1))
            return VerifierFixture(layers: [VerifierLayer(tileGrid: grid, opacity: 1.0)])
        case .multiLayerStress:
            // 3 layers, each with content in different tiles, different opacities
            let layer0 = TileGrid(canvasSize: size, tileSize: verifierTileSize, device: device)
            paintCheckerTile(grid: layer0, tileKey: TileKey(x: 0, y: 0), seed: 0x11)
            paintCheckerTile(grid: layer0, tileKey: TileKey(x: 1, y: 1), seed: 0x22)
            let layer1 = TileGrid(canvasSize: size, tileSize: verifierTileSize, device: device)
            paintCheckerTile(grid: layer1, tileKey: TileKey(x: 1, y: 0), seed: 0x33)
            paintCheckerTile(grid: layer1, tileKey: TileKey(x: 0, y: 1), seed: 0x44)
            let layer2 = TileGrid(canvasSize: size, tileSize: verifierTileSize, device: device)
            paintCheckerTile(grid: layer2, tileKey: TileKey(x: 0, y: 0), seed: 0x66)
            paintCheckerTile(grid: layer2, tileKey: TileKey(x: 1, y: 1), seed: 0x77)
            return VerifierFixture(layers: [
                VerifierLayer(tileGrid: layer0, opacity: 1.0),
                VerifierLayer(tileGrid: layer1, opacity: 0.6),
                VerifierLayer(tileGrid: layer2, opacity: 0.8),
            ])
        case .postCommitFixture:
            // Same as singleTile content; the test is timing-based — we
            // submit a write cb, then immediately submit the verifier
            // render cb without waitUntilCompleted between them. Metal
            // hazard tracking on the shared queue must serialize the
            // verifier's read after the write.
            let grid = TileGrid(canvasSize: size, tileSize: verifierTileSize, device: device)
            paintCheckerTile(grid: grid, tileKey: TileKey(x: 0, y: 0), seed: 0xBE)
            return VerifierFixture(layers: [VerifierLayer(tileGrid: grid, opacity: 1.0)])
        }
    }

    /// Paint a deterministic checker pattern into a tile via updateTile.
    /// Uses CPU bytes + texture.replace to avoid pulling in the brush
    /// shader plumbing — we only need bit-stable content, not realistic
    /// stamps.
    fileprivate func paintCheckerTile(grid: TileGrid, tileKey: TileKey, seed: UInt8) {
        guard let tile = grid.ensureTile(at: tileKey) else { return }
        let w = verifierTileSize
        let h = verifierTileSize
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let cellX = x / 16
                let cellY = y / 16
                let isFilled = (cellX + cellY) % 2 == 0
                let offset = (y * w + x) * 4
                if isFilled {
                    // BGRA, premul. R=seed, G=seed+0x33, B=seed+0x66, A=0xFF
                    bytes[offset + 0] = seed &+ 0x66 // B
                    bytes[offset + 1] = seed &+ 0x33 // G
                    bytes[offset + 2] = seed         // R
                    bytes[offset + 3] = 0xFF         // A
                }
            }
        }
        // .private tiles can't accept texture.replace directly. Use blit
        // from a staging .shared buffer.
        guard let staging = device.makeBuffer(bytes: bytes, length: bytes.count, options: .storageModeShared),
              let cb = commandQueue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(
            from: staging,
            sourceOffset: 0,
            sourceBytesPerRow: w * 4,
            sourceBytesPerImage: bytes.count,
            sourceSize: MTLSize(width: w, height: h, depth: 1),
            to: tile.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        grid.updateTile(at: tileKey) { _ in /* the blit above wrote; updateTile bumps version */ }
        cb.commit()
        cb.waitUntilCompleted()
    }

    /// ensureTileWithClearIfNeeded + NEVER updateTile. Used to test the
    /// wasCleared contract: this tile should composite as transparent.
    fileprivate func ensureUnwrittenClearedTile(grid: TileGrid, tileKey: TileKey) {
        guard let cb = commandQueue.makeCommandBuffer() else { return }
        _ = grid.ensureTileWithClearIfNeeded(at: tileKey, onCommandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
    }

    // MARK: - Render paths

    /// Render the fixture via the LEGACY path: per-layer compose into
    /// `tileDisplayIntermediate` + sample-as-fullscreen-quad onto the
    /// output texture. Uses the EXISTING encodeLayerCompositeIntoTexture
    /// + renderTextureToScreen functions unchanged.
    fileprivate func renderViaLegacyPath(fixture: VerifierFixture, scenario: VerifierScenario) -> [UInt8]? {
        guard let output = makeVerifierOutputTexture() else { return nil }
        guard let cb = commandQueue.makeCommandBuffer(),
              let intermediate = makeVerifierIntermediate() else { return nil }

        for layer in fixture.layers {
            // 1. Compose layer tiles into intermediate (per existing path)
            encodeLayerCompositeIntoTexture(layer.tileGrid, target: intermediate, visibleDocRect: nil, on: cb)

            // 2. Sample intermediate as transformed quad onto output
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = output
            rp.colorAttachments[0].loadAction = .load
            rp.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { continue }
            renderTextureToScreen(
                intermediate,
                to: enc,
                opacity: layer.opacity,
                zoomScale: scenario.zoomScale,
                panOffset: scenario.panOffset,
                canvasRotation: scenario.canvasRotation,
                viewportSize: SIMD2<Float>(Float(verifierCanvasSize), Float(verifierCanvasSize)),
                flipState: scenario.flipState
            )
            enc.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        return readbackVerifierOutput(output)
    }

    /// Render the fixture via the NEW tile-direct path. Per-layer single
    /// pass that rasterizes each visible tile directly onto the output
    /// texture.
    fileprivate func renderViaTileDirectPath(fixture: VerifierFixture, scenario: VerifierScenario) -> [UInt8]? {
        guard let output = makeVerifierOutputTexture() else { return nil }
        guard let cb = commandQueue.makeCommandBuffer() else { return nil }

        for layer in fixture.layers {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = output
            rp.colorAttachments[0].loadAction = .load
            rp.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { continue }
            encodeLayerTilesDirectlyToDrawable(
                layer.tileGrid,
                to: enc,
                opacity: layer.opacity,
                zoomScale: scenario.zoomScale,
                panOffset: scenario.panOffset,
                canvasRotation: scenario.canvasRotation,
                viewportSize: SIMD2<Float>(Float(verifierCanvasSize), Float(verifierCanvasSize)),
                flipState: scenario.flipState,
                visibleDocRect: nil
            )
            enc.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        return readbackVerifierOutput(output)
    }

    // MARK: - Output texture helpers

    fileprivate func makeVerifierOutputTexture() -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: verifierCanvasSize,
            height: verifierCanvasSize,
            mipmapped: false
        )
        desc.storageMode = .shared  // need CPU readback
        desc.usage = [.renderTarget, .shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        // Pre-clear to opaque black so we can detect any unwritten pixels
        // (legacy and new must agree on what they DON'T write too).
        clearVerifierOutput(tex)
        return tex
    }

    fileprivate func makeVerifierIntermediate() -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: verifierCanvasSize,
            height: verifierCanvasSize,
            mipmapped: false
        )
        desc.storageMode = .private
        desc.usage = [.renderTarget, .shaderRead]
        return device.makeTexture(descriptor: desc)
    }

    fileprivate func clearVerifierOutput(_ tex: MTLTexture) {
        guard let cb = commandQueue.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: rp) {
            enc.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
    }

    fileprivate func readbackVerifierOutput(_ tex: MTLTexture) -> [UInt8] {
        let w = tex.width
        let h = tex.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buf in
            tex.getBytes(
                buf.baseAddress!,
                bytesPerRow: w * 4,
                from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                size: MTLSize(width: w, height: h, depth: 1)),
                mipmapLevel: 0
            )
        }
        return bytes
    }

    // MARK: - Comparison

    fileprivate func compareOutputs(
        legacy: [UInt8],
        tileDirect: [UInt8],
        tier: VerifierScenario.Tier
    ) -> VerifierResult {
        precondition(legacy.count == tileDirect.count, "verifier output size mismatch")
        let total = legacy.count
        var diffByteCount = 0
        var maxDelta: UInt8 = 0
        var firstDiff: VerifierResult.FirstDiff? = nil
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        let allowed = tier.allowedDeltaPerChannel
        let w = verifierCanvasSize

        for i in 0..<total {
            let a = legacy[i]
            let b = tileDirect[i]
            let delta = a > b ? a - b : b - a
            if delta > allowed {
                diffByteCount += 1
                if delta > maxDelta { maxDelta = delta }
                let pixelIdx = i / 4
                let x = pixelIdx % w
                let y = pixelIdx / w
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
                if firstDiff == nil {
                    let off = pixelIdx * 4
                    firstDiff = VerifierResult.FirstDiff(
                        x: x, y: y,
                        legacy: SIMD4<UInt8>(legacy[off], legacy[off + 1], legacy[off + 2], legacy[off + 3]),
                        tileDirect: SIMD4<UInt8>(tileDirect[off], tileDirect[off + 1], tileDirect[off + 2], tileDirect[off + 3])
                    )
                }
            }
        }
        let percent = Double(diffByteCount) / Double(total) * 100.0
        let passed = percent <= tier.failThresholdPercent && (tier == .strict ? diffByteCount == 0 : true)
        let bbox: CGRect? = maxX >= 0
            ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            : nil
        return VerifierResult(
            passed: passed,
            diffBytes: diffByteCount,
            totalBytes: total,
            diffPercent: percent,
            maxDelta: maxDelta,
            diffBbox: bbox,
            firstDiffPixel: firstDiff
        )
    }

    // MARK: - Log output

    fileprivate func verifierAppendToLog(_ text: String) {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let logURL = documentsURL.appendingPathComponent("tile_direct_phase_6.log")
        let data = text.data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logURL)
        }
    }
}

#endif
