//
//  CritiqueSummary.swift
//  DrawEvolve
//
//  Extracts the trailing summary block from a critique's raw markdown.
//
//  The worker's SHARED_SYSTEM_RULES instructs the model to append a block
//  in the form:
//
//      <!--summary-->
//      - First takeaway
//      - Second takeaway
//      - Third takeaway
//      <!--/summary-->
//
//  to the end of every critique. The block is invisible in standard
//  markdown renderers (it's HTML comments + content) but our renderer
//  (FormattedMarkdownView) treats unknown lines as paragraphs and would
//  render the comments as literal text. We strip the block client-side
//  before rendering anywhere except the per-drawing summary panel.
//
//  Backwards compatibility: critiques written before the worker change
//  shipped don't have the block. `parse` returns `bullets: []` for those;
//  callers can fall back to a heuristic excerpt (first paragraph of the
//  body) so old critiques still get a readable summary.
//

import Foundation

struct CritiqueSummary {
    /// Bullets extracted from the summary block. Empty if the block
    /// wasn't present (older critiques or the model ignored the
    /// directive).
    let bullets: [String]

    /// The critique text with the summary block removed. Trailing
    /// whitespace and horizontal-rule separators that often precede
    /// the block are also stripped so the rendered body doesn't end
    /// in a dangling `---`.
    let body: String

    /// True when the parser found at least one bullet in a well-formed
    /// summary block.
    var hasExplicitSummary: Bool { !bullets.isEmpty }

    /// Parse both pieces from a raw critique string. Safe to call on
    /// any input — returns the original text as `body` and an empty
    /// `bullets` array when no block is found.
    static func parse(_ text: String) -> CritiqueSummary {
        guard let range = findSummaryBlockRange(in: text) else {
            return CritiqueSummary(bullets: [], body: text)
        }

        let blockText = String(text[range.contentRange])
        let bullets = parseBullets(blockText)

        // Strip the block AND any whitespace + horizontal-rule line
        // immediately preceding it. The system prompt doesn't require
        // the model to add `---` before the block, but in practice
        // models often do — we don't want the rendered body to end
        // in a lonely separator.
        var bodyRange = text.startIndex..<range.outerStart
        if let trimmedEnd = trimmingTrailingSeparator(text[bodyRange]) {
            bodyRange = text.startIndex..<trimmedEnd
        }
        let body = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)

        return CritiqueSummary(bullets: bullets, body: body)
    }

    /// Convenience fallback for surfaces that need *some* preview when
    /// no explicit summary block was generated. Returns the first
    /// paragraph of the body, capped at `maxChars` characters with an
    /// ellipsis if it had to truncate. Empty input → empty string.
    static func fallbackExcerpt(from body: String, maxChars: Int = 220) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let firstParagraph = trimmed
            .components(separatedBy: "\n\n")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
        if firstParagraph.count <= maxChars { return firstParagraph }
        let idx = firstParagraph.index(firstParagraph.startIndex, offsetBy: maxChars)
        return String(firstParagraph[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    // MARK: - Internals

    /// Locate the last well-formed `<!--summary-->...<!--/summary-->`
    /// pair in `text`. Returns nil if no balanced pair is present.
    /// Picks the *last* pair so a model that mistakenly opens a block,
    /// reconsiders, and writes a second one only yields the final
    /// intended one.
    private static func findSummaryBlockRange(in text: String) -> (outerStart: String.Index, contentRange: Range<String.Index>)? {
        let openTag = "<!--summary-->"
        let closeTag = "<!--/summary-->"

        var searchStart = text.startIndex
        var lastMatch: (outer: String.Index, content: Range<String.Index>)? = nil

        while let openRange = text.range(of: openTag, range: searchStart..<text.endIndex) {
            guard let closeRange = text.range(of: closeTag, range: openRange.upperBound..<text.endIndex) else {
                break
            }
            lastMatch = (openRange.lowerBound, openRange.upperBound..<closeRange.lowerBound)
            searchStart = closeRange.upperBound
        }
        guard let lastMatch else { return nil }
        return (lastMatch.outer, lastMatch.content)
    }

    /// Pull bullets out of the block. Accepts both `- ` and `* `
    /// markdown bullet prefixes. Non-bullet lines inside the block
    /// are tolerated — they just get skipped.
    private static func parseBullets(_ block: String) -> [String] {
        block.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return nil }
            let withoutBullet = String(trimmed.dropFirst(2))
                .trimmingCharacters(in: .whitespaces)
            return withoutBullet.isEmpty ? nil : withoutBullet
        }
    }

    /// If the text up to the summary block ends with a horizontal-rule
    /// line (`---`, `***`, `___`), trim that line + any trailing
    /// whitespace. Returns the new end index or nil if no separator
    /// needed trimming.
    private static func trimmingTrailingSeparator(_ slice: Substring) -> String.Index? {
        let stripped = slice.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = stripped.components(separatedBy: "\n")
        guard let last = lines.last else { return nil }
        let lastTrimmed = last.trimmingCharacters(in: .whitespaces)
        let separators: Set<String> = ["---", "***", "___"]
        guard separators.contains(lastTrimmed) else { return nil }
        // Find the position of the start of the last line in the
        // original slice so we can return an index that points to it.
        let withoutLast = lines.dropLast().joined(separator: "\n")
        return slice.range(of: withoutLast)?.upperBound
    }
}
