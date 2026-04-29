-- Phase 5d — atomic jsonb-array append for drawings.critique_history.
--
-- Service-role-only RPC called by the Worker after a successful OpenAI
-- response. Bypasses the read-modify-write race that a naive SELECT+UPDATE
-- pattern would have under concurrent writes for the same drawing.
--
-- The Worker is the sole writer to critique_history after Phase 5d. iOS
-- reads it on hydrate via Phase 3 cloud sync but never round-trips it
-- on update — see the contract note in DrawingStorageManager.swift.

create or replace function public.append_critique(
  p_drawing_id uuid,
  p_entry jsonb
) returns void
language sql
security definer
set search_path = public
as $$
  update public.drawings
  set critique_history = critique_history || jsonb_build_array(p_entry),
      updated_at = now()
  where id = p_drawing_id;
$$;

revoke all on function public.append_critique(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.append_critique(uuid, jsonb) to service_role;
