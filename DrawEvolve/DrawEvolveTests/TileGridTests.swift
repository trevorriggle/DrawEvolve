// TileGridTests.swift
// DrawEvolveTests
//
// Unit tests for TileGrid / LayerTile / TileKey (Phase 1 of the tiling
// migration).
//
// IMPORTANT — UNREGISTERED FILE:
// This file is checked in but is NOT registered in DrawEvolve.xcodeproj
// because the project currently has no test target. CLAUDE.md confirms
// "No XCTest suite for the iOS app. Manual testing on device/simulator."
//
// When a test target is added (e.g., `DrawEvolveTests`), include this file
// in its Compile Sources phase, link the target against the `DrawEvolve`
// app module (with `@testable import` access), and enable iOS Simulator
// destinations. Each test uses MTLCreateSystemDefaultDevice() which on the
// simulator returns the host Metal device — no special configuration
// needed beyond a target that links Metal.framework (XCTest test bundles
// already do by default).
//
// Until then, these tests do not run in CI or in Xcode's test action.
// They are written to compile cleanly the moment a target picks them up.

import XCTest
import Metal
import CoreGraphics
@testable import DrawEvolve

final class TileGridTests: XCTestCase {

    // MARK: - Device

    /// Real Metal device for tile-texture allocation. The simulator
    /// supports MTLCreateSystemDefaultDevice on macOS hosts with GPU
    /// support; on hosts without it the device is nil and these tests are
    /// skipped via XCTSkipIf.
    private func makeDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No default Metal device available on this host.")
        }
        return device
    }

    // MARK: - Initialization & grid dimensions

    func testInit_4096Square_produces16x16Grid() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 4096, height: 4096), device: device)
        XCTAssertEqual(grid.tileSize, 256)
        XCTAssertEqual(grid.gridWidth, 16)
        XCTAssertEqual(grid.gridHeight, 16)
    }

    func testInit_2048Square_produces8x8Grid() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 2048, height: 2048), device: device)
        XCTAssertEqual(grid.gridWidth, 8)
        XCTAssertEqual(grid.gridHeight, 8)
    }

    func testInit_1024Square_produces4x4Grid() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 1024, height: 1024), device: device)
        XCTAssertEqual(grid.gridWidth, 4)
        XCTAssertEqual(grid.gridHeight, 4)
    }

    func testInit_nonSquare_producesIndependentDimensions() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 1024, height: 512), device: device)
        XCTAssertEqual(grid.gridWidth, 4)
        XCTAssertEqual(grid.gridHeight, 2)
    }

    func testInit_subTileSize_clampsTo1x1() throws {
        let device = try makeDevice()
        // 255x255 canvas with tileSize=256: ceil(255/256) = 1 in each dim.
        let grid = TileGrid(canvasSize: CGSize(width: 255, height: 255), device: device)
        XCTAssertEqual(grid.gridWidth, 1)
        XCTAssertEqual(grid.gridHeight, 1)
    }

    func testInit_nonDivisible_roundsUp() throws {
        let device = try makeDevice()
        // 300x500 with tileSize=256: ceil(300/256)=2, ceil(500/256)=2.
        let grid = TileGrid(canvasSize: CGSize(width: 300, height: 500), device: device)
        XCTAssertEqual(grid.gridWidth, 2)
        XCTAssertEqual(grid.gridHeight, 2)
    }

    func testInit_zeroSize_clampsTo1x1() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: .zero, device: device)
        XCTAssertEqual(grid.gridWidth, 1)
        XCTAssertEqual(grid.gridHeight, 1)
    }

    func testInit_customTileSize_isHonored() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 1024, height: 1024),
                            tileSize: 512,
                            device: device)
        XCTAssertEqual(grid.tileSize, 512)
        XCTAssertEqual(grid.gridWidth, 2)
        XCTAssertEqual(grid.gridHeight, 2)
    }

    // MARK: - tilesIntersecting

    func testTilesIntersecting_rectInsideOneTile_returnsOneKey() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 4096, height: 4096), device: device)
        let keys = grid.tilesIntersecting(CGRect(x: 10, y: 10, width: 50, height: 50))
        XCTAssertEqual(keys, [TileKey(x: 0, y: 0)])
    }

    func testTilesIntersecting_rectSpansTwoHorizontalTiles_returnsTwoKeys() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 4096, height: 4096), device: device)
        // Spans pixel x=200..300 -> tiles 0 and 1, both at row 0.
        let keys = grid.tilesIntersecting(CGRect(x: 200, y: 10, width: 100, height: 50))
        XCTAssertEqual(Set(keys), Set([TileKey(x: 0, y: 0), TileKey(x: 1, y: 0)]))
    }

    func testTilesIntersecting_rectSpansFourTilesAtCorner_returnsFourKeys() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 4096, height: 4096), device: device)
        // Centered on (256, 256) - the boundary of tiles (0,0)/(1,0)/(0,1)/(1,1).
        let keys = grid.tilesIntersecting(CGRect(x: 200, y: 200, width: 100, height: 100))
        let expected: Set<TileKey> = [
            TileKey(x: 0, y: 0), TileKey(x: 1, y: 0),
            TileKey(x: 0, y: 1), TileKey(x: 1, y: 1)
        ]
        XCTAssertEqual(Set(keys), expected)
    }

    func testTilesIntersecting_rectAtTileBoundary_isHalfOpen() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 4096, height: 4096), device: device)
        // CGRect (0, 0, 256, 256) covers half-open [0,256) x [0,256) which is exactly tile (0,0).
        let keys = grid.tilesIntersecting(CGRect(x: 0, y: 0, width: 256, height: 256))
        XCTAssertEqual(keys, [TileKey(x: 0, y: 0)])
    }

    func testTilesIntersecting_rectExtendingPastCanvas_clampsToGrid() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 512, height: 512), device: device)
        // Grid is 2x2. Rect extends past canvas bounds.
        let keys = grid.tilesIntersecting(CGRect(x: 100, y: 100, width: 10_000, height: 10_000))
        let expected: Set<TileKey> = [
            TileKey(x: 0, y: 0), TileKey(x: 1, y: 0),
            TileKey(x: 0, y: 1), TileKey(x: 1, y: 1)
        ]
        XCTAssertEqual(Set(keys), expected)
    }

    func testTilesIntersecting_rectEntirelyOutsideCanvas_returnsEmpty() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 512, height: 512), device: device)
        // Rect is fully right of the canvas.
        let keys = grid.tilesIntersecting(CGRect(x: 1000, y: 100, width: 100, height: 100))
        XCTAssertTrue(keys.isEmpty)
    }

    /// Documented choice: zero-size rect returns empty (matches
    /// CGRect.isEmpty semantics).
    func testTilesIntersecting_zeroSizeRect_returnsEmpty() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 4096, height: 4096), device: device)
        let keys = grid.tilesIntersecting(CGRect(x: 100, y: 100, width: 0, height: 0))
        XCTAssertTrue(keys.isEmpty)
    }

    func testTilesIntersecting_nullRect_returnsEmpty() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 4096, height: 4096), device: device)
        let keys = grid.tilesIntersecting(.null)
        XCTAssertTrue(keys.isEmpty)
    }

    // MARK: - ensureTile / tile / dropTile

    func testEnsureTile_allocatesWhenAbsent() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 4096, height: 4096), device: device)
        let key = TileKey(x: 3, y: 5)
        XCTAssertNil(grid.tile(at: key))
        let tile = grid.ensureTile(at: key)
        XCTAssertEqual(tile.texture.width, 256)
        XCTAssertEqual(tile.texture.height, 256)
        XCTAssertEqual(tile.texture.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(tile.texture.storageMode, .private)
        XCTAssertNotNil(grid.tile(at: key))
    }

    func testEnsureTile_returnsSameTileOnRepeatCall() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 4096, height: 4096), device: device)
        let key = TileKey(x: 1, y: 1)
        let first = grid.ensureTile(at: key)
        let second = grid.ensureTile(at: key)
        // Same MTLTexture instance is the strong guarantee.
        XCTAssertTrue(first.texture === second.texture)
    }

    func testTileInitialMetadata_dirtyAndOccupancyZero() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 4096, height: 4096), device: device)
        let tile = grid.ensureTile(at: TileKey(x: 0, y: 0))
        XCTAssertEqual(tile.dirtyVersion, 0)
        XCTAssertEqual(tile.nonTransparentBits, 0)
    }

    func testDropTile_removesFromAllocatedSet() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 4096, height: 4096), device: device)
        let key = TileKey(x: 2, y: 2)
        _ = grid.ensureTile(at: key)
        XCTAssertNotNil(grid.tile(at: key))
        grid.dropTile(at: key)
        XCTAssertNil(grid.tile(at: key))
    }

    func testDropTile_onAbsentKey_isNoOp() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 4096, height: 4096), device: device)
        grid.dropTile(at: TileKey(x: 5, y: 5)) // never allocated
        XCTAssertTrue(grid.allocatedKeys().isEmpty)
    }

    // MARK: - allocatedKeys

    func testAllocatedKeys_initiallyEmpty() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 4096, height: 4096), device: device)
        XCTAssertTrue(grid.allocatedKeys().isEmpty)
    }

    func testAllocatedKeys_reflectsEnsureAndDrop() throws {
        let device = try makeDevice()
        let grid = TileGrid(canvasSize: CGSize(width: 4096, height: 4096), device: device)
        let a = TileKey(x: 0, y: 0)
        let b = TileKey(x: 1, y: 0)
        let c = TileKey(x: 2, y: 0)
        _ = grid.ensureTile(at: a)
        _ = grid.ensureTile(at: b)
        _ = grid.ensureTile(at: c)
        XCTAssertEqual(Set(grid.allocatedKeys()), Set([a, b, c]))
        grid.dropTile(at: b)
        XCTAssertEqual(Set(grid.allocatedKeys()), Set([a, c]))
    }
}
