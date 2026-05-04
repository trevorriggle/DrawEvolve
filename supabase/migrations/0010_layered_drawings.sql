-- DrawEvolve schema — layered drawing storage
-- =========================================================================
-- How to apply:
--   1. Open the Supabase dashboard for project `jkjfcjptzvieaonrmkzd`.
--   2. SQL Editor → + New query.
--   3. Paste the entire contents of this file.
--   4. Click "Run".
--   5. Re-runnable safely (every statement is idempotent or guarded).
--
-- What it does:
--   - Adds the manifest pointer + ancillary columns to public.drawings so a
--     row can describe a multi-layer drawing (manifest.json + per-layer PNGs)
--     instead of only a flattened JPEG. See ONLINELAYERSTORE.md §5.2.
--   - Drops the NOT NULL on storage_path so a fresh layered drawing can land
--     manifest-only; adds a CHECK so a row can never reference *neither*
--     a flat composite nor a manifest.
--   - Adds a `version` integer for optimistic concurrency (ONLINELAYERSTORE
--     §9.1) with a before-update trigger that bumps it on every change.
--     Conflict-detection UI is out of scope for this migration; the column
--     and trigger are landed now so the next sprint can wire conditional
--     upserts without a follow-up schema change.
--
-- RLS: unchanged. The existing `users (read|insert|update|delete) own drawings`
-- policies key off user_id, which is unaffected. Storage object policies key
-- off `(storage.foldername(name))[1]` — the user_id segment — and stay valid
-- whether the path is `<user>/<id>.jpg` (legacy) or `<user>/<id>/manifest.json`
-- (layered).
-- =========================================================================


-- =========================================================================
-- 1. New columns on public.drawings
-- =========================================================================

alter table public.drawings
    add column if not exists manifest_path  text,
    add column if not exists format_version int,
    add column if not exists layer_count    int,
    add column if not exists total_bytes    bigint,
    add column if not exists version        int not null default 1;


-- =========================================================================
-- 2. Make storage_path nullable + require at least one path
-- =========================================================================
-- Legacy rows keep storage_path (the flat JPEG). New layered rows can either
-- carry both (storage_path → composite.jpg, manifest_path → manifest.json)
-- or just manifest_path. Pure-legacy rows untouched by this migration keep
-- storage_path, manifest_path = null.

alter table public.drawings
    alter column storage_path drop not null;

-- A drawing must point at *something* viewable.
alter table public.drawings
    drop constraint if exists drawings_path_present;

alter table public.drawings
    add constraint drawings_path_present
    check (storage_path is not null or manifest_path is not null);


-- =========================================================================
-- 3. Optimistic-concurrency version trigger
-- =========================================================================
-- Bumps `version` on every UPDATE unless the client passed an explicit new
-- value (e.g. for an idempotent retry of a known-version save). Distinct
-- trigger from drawings_touch_updated_at so each one stays focused; both fire
-- BEFORE UPDATE and touch independent columns, so order doesn't matter.

create or replace function public.bump_drawing_version()
returns trigger
language plpgsql
as $$
begin
    if NEW.version is not distinct from OLD.version then
        NEW.version := OLD.version + 1;
    end if;
    return NEW;
end;
$$;

drop trigger if exists drawings_bump_version on public.drawings;
create trigger drawings_bump_version
    before update on public.drawings
    for each row
    execute function public.bump_drawing_version();
