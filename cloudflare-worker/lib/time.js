// Time formatting helpers. Currently just relative-time for the
// cross-drawing registry rows ("3 days ago", "last week", ...). Pulled into
// its own module so the formatter is testable in isolation against a frozen
// `now` and prompt.js stays pure (no clock dependency).

const MS_PER_DAY = 24 * 60 * 60 * 1000;

/**
 * Format the duration between `then` and `now` as a coarse English phrase
 * suitable for the cross-drawing registry block. Buckets — approved
 * verbatim in the PR spec:
 *
 *   0 days        → "today"
 *   1 day         → "yesterday"
 *   2-6 days      → "{N} days ago"
 *   7-13 days     → "last week"
 *   14-29 days    → "{N} weeks ago"    (2, 3, 4)
 *   30-59 days    → "last month"
 *   60-364 days   → "{N} months ago"   (2..11)
 *   365+ days     → "over a year ago"
 *
 * Negative or absent `then` falls back to "recently" so a malformed
 * timestamp never blows up the rendered registry row.
 *
 * `then` accepts an ISO string, an epoch ms number, or a Date.
 */
export function formatRelativeTime(then, now = Date.now()) {
  const thenMs =
      then instanceof Date ? then.getTime()
    : typeof then === 'number' ? then
    : typeof then === 'string' ? Date.parse(then)
    : NaN;

  if (!Number.isFinite(thenMs)) return 'recently';

  const diffMs = now - thenMs;
  if (diffMs < 0) return 'recently';

  const days = Math.floor(diffMs / MS_PER_DAY);

  if (days <= 0) return 'today';
  if (days === 1) return 'yesterday';
  if (days <= 6) return `${days} days ago`;
  if (days <= 13) return 'last week';
  if (days <= 29) return `${Math.floor(days / 7)} weeks ago`;
  if (days <= 59) return 'last month';
  if (days <= 364) return `${Math.floor(days / 30)} months ago`;
  return 'over a year ago';
}
