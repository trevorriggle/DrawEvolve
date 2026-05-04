//
//  LayeredDrawingPayload.swift
//  DrawEvolve
//
//  Wire shape for the layered drawing save/load round-trip
//  (ONLINELAYERSTORE.md §3).
//
//  A `LayeredDrawingPayload` bundles the parsed `manifest.json` with the raw
//  PNG bytes for each layer plus the optional composite + thumbnail JPEGs.
//  Same type flows in both directions:
//
//    - Save: canvas code (next sprint) builds a payload from the in-session
//      DrawingLayer stack and hands it to CloudDrawingStorageManager
//      .saveLayeredDrawing(...). The manager computes per-layer sha256,
//      assigns asset filenames by ordinal, and serializes the manifest.
//      Callers may leave `assetSha256` empty / `asset` as a placeholder —
//      the manager recomputes both at upload time.
//
//    - Load: CloudDrawingStorageManager.loadLayeredDrawing(for:) returns a
//      payload with manifest parsed from disk-or-cloud and per-layer PNG
//      bytes downloaded into `layerPNGs` indexed by ordinal. Returns nil
//      for a legacy (manifest-less) drawing — caller falls back to
//      loadFullImage.
//
//  bbox is reserved per §7.1 — declared so the manifest schema is forward
//  compatible, but no callsite computes it in v1.
//

import Foundation

struct LayeredDrawingManifest: Codable, Equatable {
    var formatVersion: Int
    var drawingId: String          // lowercase uuid string
    var document: Document
    var layers: [Layer]
    var thumbnail: String          // sibling object key, e.g. "thumb.jpg"
    var composite: String?         // sibling object key, e.g. "composite.jpg"; nil if not saved

    struct Document: Codable, Equatable {
        var width: Int
        var height: Int
        var colorSpace: String     // "srgb"
        var pixelFormat: String    // "rgba8_premultiplied"

        enum CodingKeys: String, CodingKey {
            case width, height
            case colorSpace = "color_space"
            case pixelFormat = "pixel_format"
        }
    }

    struct Layer: Codable, Equatable {
        var ordinal: Int           // bottom-up; renderer iterates in order
        var id: String             // stable lowercase uuid for round-tripping
        var name: String
        var opacity: Float
        var visible: Bool
        var locked: Bool
        var blendMode: String      // BlendMode.rawValue
        var asset: String          // sibling object key, e.g. "layer-0.png"
        var assetSha256: String    // hex sha256 of the PNG bytes
        var bbox: Bbox?            // §7.1, deferred — leave nil

        enum CodingKeys: String, CodingKey {
            case ordinal, id, name, opacity, visible, locked
            case blendMode = "blend_mode"
            case asset
            case assetSha256 = "asset_sha256"
            case bbox
        }
    }

    struct Bbox: Codable, Equatable {
        var x: Int
        var y: Int
        var w: Int
        var h: Int
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case drawingId = "drawing_id"
        case document, layers, thumbnail, composite
    }
}

struct LayeredDrawingPayload {
    var manifest: LayeredDrawingManifest
    /// PNG bytes per layer, indexed by `manifest.layers[i].ordinal`.
    /// On save: caller provides bytes; storage manager computes sha256 + writes manifest.
    /// On load: bytes are populated from disk cache or signed-URL download; sha256
    /// has already been verified against the manifest entry.
    var layerPNGs: [Data]
    var compositeJPEG: Data?
    var thumbnailJPEG: Data?
}

/// Filename helpers — the on-storage layout is a hard contract, not just a
/// suggestion, because the loader path-builds from these and the migration's
/// `manifest_path` row column points at a literal "manifest.json" sibling.
enum LayeredDrawingFilenames {
    static let manifest  = "manifest.json"
    static let thumbnail = "thumb.jpg"
    static let composite = "composite.jpg"

    static func layer(ordinal: Int) -> String { "layer-\(ordinal).png" }
}
