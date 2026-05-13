//
//  PaletteGenerator.swift
//  DrawEvolve
//
//  Phase 3 — on-device dominant-color extraction for "Generate from
//  canvas". Histogram-based: downsample → bucket-bin → sort by count →
//  return top N centroids, deduplicated against each other.
//
//  Why not CIPosterize: posterize quantizes EACH channel to N levels
//  (so the output uses up to N^3 colors). It doesn't tell us which
//  colors are dominant — it just paints the source image with a
//  reduced palette. Extracting "what are the top 8 colors here?" still
//  needs a histogram on the posterized output. Doing histogram
//  directly skips the posterize step entirely.
//
//  Performance: 128×128 downsample = 16,384 pixels. Pure-Swift histogram
//  over 4096 bins (16 levels per channel) finishes well under 50ms on
//  any iPad device. vImage_Histogram is available in Accelerate and
//  would be faster, but the pure-Swift path is fast enough for v1 and
//  has zero framework dependencies.
//

import Foundation
import UIKit
import CoreGraphics

enum PaletteGeneratorError: LocalizedError {
    case emptyCanvas
    case rasterizationFailed
    case pixelReadFailed

    var errorDescription: String? {
        switch self {
        case .emptyCanvas:
            return "Draw something first — generation needs content to analyze."
        case .rasterizationFailed:
            return "Couldn't rasterize the canvas for analysis."
        case .pixelReadFailed:
            return "Couldn't read pixel data from the canvas."
        }
    }
}

struct PaletteGenerator {

    /// Tunables — exposed as constants rather than parameters so the
    /// generator has a single canonical behavior across callers. Bump
    /// any of these only with a deliberate decision; downstream UX
    /// assumes consistency.
    static let thumbnailEdge: CGFloat = 128
    static let levelsPerChannel: Int = 16
    static let maxOutputColors: Int = 8

    /// Tolerance for deduping near-identical extracted colors (out of
    /// 255 sRGB per channel). Higher than recent-color dedupe because
    /// we're extracting from clusters — adjacent histogram bins often
    /// describe the same visual color.
    static let dedupeTolerance: CGFloat = 24.0

    /// Generate a palette from the given composite image. Throws
    /// .emptyCanvas if the result would be entirely white pixels (a
    /// blank canvas). Otherwise returns up to maxOutputColors distinct
    /// dominant colors, ordered by frequency (most common first).
    static func generate(from image: UIImage) throws -> [UIColor] {
        let thumb = try downsample(image, to: CGSize(width: thumbnailEdge, height: thumbnailEdge))
        let pixels = try readRGBA(thumb)

        // Bucket-bin every pixel into a coarse RGB grid. levels^3 bins
        // total (16^3 = 4096). Each bin has a count + accumulated
        // RGB totals so we can compute a centroid color rather than
        // returning the bin's geometric center.
        let levels = levelsPerChannel
        let scale = 256 / levels  // 16 per channel = 16 bins per channel

        var binCount = [Int](repeating: 0, count: levels * levels * levels)
        var binSumR = [Int](repeating: 0, count: levels * levels * levels)
        var binSumG = [Int](repeating: 0, count: levels * levels * levels)
        var binSumB = [Int](repeating: 0, count: levels * levels * levels)

        // Skip near-white pixels (canvas background) so a mostly-blank
        // drawing doesn't return [white, white, white, ...]. Threshold
        // chosen to forgive faint paper-color variations.
        let nearWhiteThreshold = 245

        var sampleCount = 0
        let count = pixels.count / 4
        for i in 0..<count {
            let r = Int(pixels[i * 4])
            let g = Int(pixels[i * 4 + 1])
            let b = Int(pixels[i * 4 + 2])
            let a = Int(pixels[i * 4 + 3])
            // Skip fully transparent pixels too.
            if a < 8 { continue }
            // Skip near-white (canvas background).
            if r >= nearWhiteThreshold && g >= nearWhiteThreshold && b >= nearWhiteThreshold {
                continue
            }

            let bx = min(levels - 1, r / scale)
            let by = min(levels - 1, g / scale)
            let bz = min(levels - 1, b / scale)
            let idx = bx * levels * levels + by * levels + bz

            binCount[idx] += 1
            binSumR[idx] += r
            binSumG[idx] += g
            binSumB[idx] += b
            sampleCount += 1
        }

        // Empty canvas: every pixel was near-white.
        if sampleCount == 0 {
            throw PaletteGeneratorError.emptyCanvas
        }

        // Sort bins by count descending. Take more than we need so the
        // dedupe step has room to drop near-duplicates. Pulled apart
        // into discrete steps because chaining map/filter/sorted/prefix
        // in one expression makes the type-checker time out.
        var nonEmpty: [(idx: Int, count: Int)] = []
        nonEmpty.reserveCapacity(binCount.count / 16)
        for i in 0..<binCount.count where binCount[i] > 0 {
            nonEmpty.append((idx: i, count: binCount[i]))
        }
        nonEmpty.sort { $0.count > $1.count }
        let take = min(nonEmpty.count, maxOutputColors * 3)
        let candidates: [(idx: Int, count: Int)] = Array(nonEmpty.prefix(take))

        var picked: [UIColor] = []
        for entry in candidates {
            let n = binCount[entry.idx]
            guard n > 0 else { continue }
            let rAvg = CGFloat(binSumR[entry.idx]) / CGFloat(n) / 255.0
            let gAvg = CGFloat(binSumG[entry.idx]) / CGFloat(n) / 255.0
            let bAvg = CGFloat(binSumB[entry.idx]) / CGFloat(n) / 255.0
            let candidate = UIColor(red: rAvg, green: gAvg, blue: bAvg, alpha: 1.0)

            if picked.contains(where: { isWithinTolerance($0, candidate, threshold: dedupeTolerance) }) {
                continue
            }
            picked.append(candidate)
            if picked.count >= maxOutputColors { break }
        }

        return picked
    }

    // MARK: - Internals

    /// Downsample a UIImage to the given target size using a fast
    /// CGContext render. Aspect-fit; the smaller dimension is the
    /// target edge, the larger one is scaled to fit.
    private static func downsample(_ image: UIImage, to size: CGSize) throws -> CGImage {
        guard let cgImage = image.cgImage else {
            throw PaletteGeneratorError.rasterizationFailed
        }
        let originalSize = CGSize(width: cgImage.width, height: cgImage.height)
        let aspect = originalSize.width / originalSize.height
        let target: CGSize
        if aspect >= 1 {
            target = CGSize(width: size.width, height: size.height / aspect)
        } else {
            target = CGSize(width: size.width * aspect, height: size.height)
        }
        let w = max(1, Int(target.width.rounded()))
        let h = max(1, Int(target.height.rounded()))

        guard let cs = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PaletteGeneratorError.rasterizationFailed
        }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: bitmapInfo,
        ) else {
            throw PaletteGeneratorError.rasterizationFailed
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else {
            throw PaletteGeneratorError.rasterizationFailed
        }
        return out
    }

    /// Read RGBA bytes from a CGImage into a flat [UInt8] array.
    /// Forces 8-bit-per-component premultipliedLast layout so the
    /// caller can index by 4*pixel + channel without surprises.
    private static func readRGBA(_ cgImage: CGImage) throws -> [UInt8] {
        let w = cgImage.width
        let h = cgImage.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PaletteGeneratorError.pixelReadFailed
        }
        guard let ctx = CGContext(
            data: &bytes, width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: bitmapInfo,
        ) else {
            throw PaletteGeneratorError.pixelReadFailed
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return bytes
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
}
