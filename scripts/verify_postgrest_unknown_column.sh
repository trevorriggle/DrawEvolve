#!/usr/bin/env bash
#
# verify_postgrest_unknown_column.sh
#
# Pre-M3 gate: confirms how PostgREST responds when you PATCH a column
# that doesn't exist in the schema cache. The result locks the M3
# deployment ordering:
#
#   - HTTP 400 with PGRST204 (or PGRST116, depending on version)
#     → migration MUST run before iOS code that sends `intent_marker`
#       ships. Sequence: SQL Editor → wait for schema cache reload →
#       deploy iOS.
#
#   - HTTP 200/204 with the row updated (no error)
#     → PostgREST is silently ignoring unknown columns. Ordering is
#       flexible. (Unexpected on modern PostgREST/Supabase; verify by
#       reading the returned row.)
#
# Usage:
#   export SUPABASE_URL='https://YOUR-PROJECT.supabase.co'
#   export SUPABASE_ANON_KEY='eyJ...'         # public anon JWT
#   export USER_ACCESS_TOKEN='eyJ...'          # the user's session JWT
#                                              # (DevTools → Supabase auth)
#   export DRAWING_ID='aaaaaaaa-bbbb-...'      # any drawing owned by user
#   bash scripts/verify_postgrest_unknown_column.sh
#
# Expects USER_ACCESS_TOKEN to belong to the user that owns DRAWING_ID
# so RLS doesn't deny first.

set -u

if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_ANON_KEY:-}" || -z "${USER_ACCESS_TOKEN:-}" || -z "${DRAWING_ID:-}" ]]; then
  echo "Missing env vars. Set SUPABASE_URL, SUPABASE_ANON_KEY, USER_ACCESS_TOKEN, DRAWING_ID first." >&2
  exit 1
fi

URL="${SUPABASE_URL%/}/rest/v1/drawings?id=eq.${DRAWING_ID}"
# Deliberately fake column name — must not exist in public.drawings.
PAYLOAD='{"definitely_not_a_real_column_eye_test_probe": {"x": 0.5, "y": 0.5}}'

echo "→ PATCH ${URL}"
echo "→ payload: ${PAYLOAD}"
echo

HTTP_CODE=$(
  curl -sS -o /tmp/pgrst_probe_body.txt -w "%{http_code}" \
    -X PATCH "${URL}" \
    -H "apikey: ${SUPABASE_ANON_KEY}" \
    -H "Authorization: Bearer ${USER_ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=representation" \
    --data "${PAYLOAD}"
)

echo "← HTTP ${HTTP_CODE}"
echo "← body:"
cat /tmp/pgrst_probe_body.txt
echo
echo

case "${HTTP_CODE}" in
  200|204)
    echo "RESULT: PostgREST appears to be silently ignoring the unknown column."
    echo "       (Read the body — if the row is returned without the fake field,"
    echo "        that confirms silent-ignore. M3 ordering becomes flexible.)"
    ;;
  400)
    echo "RESULT: PostgREST rejected the unknown column (HTTP 400)."
    echo "       M3 ordering is migration-first, hard."
    ;;
  401|403)
    echo "RESULT: Auth / RLS rejected the request. Re-check USER_ACCESS_TOKEN"
    echo "       and that the user owns DRAWING_ID."
    ;;
  *)
    echo "RESULT: Unexpected HTTP ${HTTP_CODE}. Inspect body above and re-run."
    ;;
esac
