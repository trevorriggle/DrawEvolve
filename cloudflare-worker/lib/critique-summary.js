// Parse the trailing summary block from a critique's raw markdown.
//
// The worker's SHARED_SYSTEM_RULES instructs the model to append a block
// in the form:
//
//   <!--summary-->
//   - First takeaway
//   - Second takeaway
//   - Third takeaway
//   <!--/summary-->
//
// to the end of every critique. The block is invisible in rendered
// markdown (it's HTML comments + content). Eve's coaching context block
// pulls these bullets so she can reference what was covered in past
// critiques without burning tokens on the full critique body.
//
// Mirrors the three-tier matching strategy from iOS's CritiqueSummary
// (Models/CritiqueSummary.swift):
//   Tier 1: Closed HTML comment block (the canonical, prompt-mandated shape).
//   Tier 2: Open HTML comment with no close — assume completion got
//           truncated by max_completion_tokens; take everything from the
//           opener to end-of-text.
//   Tier 3: `## Summary` or `**Summary**` header at the end, followed by
//           bullet lines, no HTML comments — covers the case where the
//           model ignored the delimiter directive but produced a usable
//           markdown summary anyway.
//
// Returns string[] of bullet contents (the text after `- ` or `* `).
// Returns [] for legacy critiques without any summary block, malformed
// blocks with no bullets, or non-string input. Never throws.

/**
 * Extract bullet texts from the summary block in a critique's markdown.
 * Defensive against missing / non-string input.
 */
export function parseCritiqueSummary(content) {
  if (typeof content !== 'string' || content.length === 0) return [];

  // Tier 1: closed comment block. `s` flag = dotall, `i` flag = case-
  // insensitive. Non-greedy on the content so a critique with two
  // accidental blocks yields the LAST one (last-wins, matches iOS).
  const closed = lastMatch(content, /<!--\s*summary\s*-->([\s\S]*?)<!--\s*\/\s*summary\s*-->/gi);
  if (closed) return extractBullets(closed);

  // Tier 2: open comment, no close. Treat as truncation — content runs
  // from the opener to end-of-text.
  const openIndex = lastOpenSummaryIndex(content);
  if (openIndex !== -1) {
    const after = content.slice(openIndex);
    // Strip the opener tag itself so extractBullets only sees content.
    const stripped = after.replace(/^<!--\s*summary\s*-->/i, '');
    return extractBullets(stripped);
  }

  // Tier 3: markdown header at the end, followed by bullets. Two header
  // styles; both must appear at end-of-text with their bullets immediately
  // after. The `$` anchor catches "end of text" since we use the `m`
  // flag and the trailing whitespace tolerance.
  const headerPatterns = [
    /(?:^|\n)\s*##\s+summary\s*:?\s*\n((?:\s*[-*]\s+.+\n?)+)\s*$/i,
    /(?:^|\n)\s*\*\*\s*summary\s*:?\s*\*\*\s*\n((?:\s*[-*]\s+.+\n?)+)\s*$/i,
  ];
  for (const re of headerPatterns) {
    const m = content.match(re);
    if (m && m[1]) {
      const bullets = extractBullets(m[1]);
      if (bullets.length > 0) return bullets;
    }
  }

  return [];
}

// Find the index of the LAST `<!--summary-->` opener in the string, OR
// -1 if none. Used by Tier 2 when there's an opener but no closer.
function lastOpenSummaryIndex(text) {
  const re = /<!--\s*summary\s*-->/gi;
  let last = -1;
  let m;
  while ((m = re.exec(text)) !== null) {
    last = m.index;
    if (m.index === re.lastIndex) re.lastIndex += 1; // zero-width safety
  }
  return last;
}

// Run a regex with `g` flag and return the LAST match's first capture
// group, or null if no matches.
function lastMatch(text, re) {
  let last = null;
  let m;
  while ((m = re.exec(text)) !== null) {
    last = m[1] ?? null;
    if (m.index === re.lastIndex) re.lastIndex += 1;
  }
  return last;
}

// Pull `- ` or `* ` bullets out of a block. Tolerates non-bullet lines
// inside the block (they get skipped, same shape as iOS). Trims each
// bullet's leading marker + whitespace and skips empties.
function extractBullets(block) {
  return block
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.startsWith('- ') || line.startsWith('* '))
    .map((line) => line.slice(2).trim())
    .filter((line) => line.length > 0);
}
