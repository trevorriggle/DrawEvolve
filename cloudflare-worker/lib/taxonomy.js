// Critique tag taxonomy. Single source of truth — imported by the classifier
// (which constrains the model's output to this enum) and by the future
// "My Evolution" endpoint (which aggregates tags into trend charts). Do not
// duplicate this list anywhere else; bucket churn must happen in one place.
//
// 'subject_match' is intentionally a separate category from craft buckets:
// SUBJECT VERIFICATION failures are not "the user got anatomy wrong" — they
// are "the canonical subject feature is missing or the stated subject does
// not match what was drawn." Keeping it distinct prevents subject-mismatch
// rows from polluting per-craft trend lines.
//
// 'general' is the catch-all when no craft category fits (conceptual /
// expressive / framing critiques). Keep it sparse — the trend tab is
// useful in proportion to how often a non-general category lands.

export const CRITIQUE_CATEGORIES = [
  'anatomy',
  'composition',
  'value',
  'color',
  'line',
  'perspective',
  'subject_match',
  'general',
];

export const SEVERITY_MIN = 1;
export const SEVERITY_MAX = 5;
