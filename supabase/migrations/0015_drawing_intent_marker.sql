-- 0015_drawing_intent_marker.sql
--
-- Adds the per-drawing intent marker for the Composition / "Eye Test"
-- feature (M3 of the Eye Test build plan).
--
-- The intent marker is a single normalized point (x, y in [0, 1] of
-- the document, top-left origin) indicating where the user *intended*
-- the focal point of the drawing to be. The panel compares this to
-- Vision's saliency hotspots and surfaces the gap. Optional — many
-- drawings will never have one.
--
-- Stored as jsonb so future extensions (multiple ranked intent points
-- in v2, per-stroke intent zones) don't require a schema change.
-- iOS encodes / decodes as `{"x": Double, "y": Double}`. Future v2
-- shape would be `[{"x":..., "y":..., "rank": 1}, ...]` — readers
-- should accept both.
--
-- Idempotent.

alter table public.drawings
    add column if not exists intent_marker jsonb;

comment on column public.drawings.intent_marker is
    'Composition Eye Test intent marker. Normalized document coords '
    '(top-left origin). v1 shape: {"x": double, "y": double}. nil/null '
    'when the user has not marked intent. See Models/CompositionAnalysis.swift '
    'IntentMarker struct.';

-- NOTE on deployment ordering: per the pre-M3 PostgREST probe
-- (scripts/verify_postgrest_unknown_column.sh), if PGRST204 is
-- returned for unknown columns on PATCH, the iOS code that sends
-- `intent_marker` MUST be deployed AFTER this migration runs and the
-- schema cache reloads. Sequence:
--
--   1. Apply this migration via the Supabase SQL Editor.
--   2. Confirm PostgREST sees the new column. NOTIFY pgrst, 'reload
--      schema' typically fires automatically on DDL; verify via a
--      quick read of public.feature_flags.flag_name = 'eye_test_panel'
--      followed by an OPTIONS request on /rest/v1/drawings (the
--      response includes the column list).
--   3. Deploy the iOS build that sends intent_marker.
--
-- If PostgREST silent-ignores instead, the ordering is flexible —
-- iOS can ship first and the field will just be ignored until the
-- column exists.
