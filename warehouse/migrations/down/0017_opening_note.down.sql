-- Reverse 0017: restore the three-argument opening recording and drop the note.
-- Role-aware for Supabase portability (see the up migration's header).
set role wh_owner;

drop function if exists wh.record_opening(uuid, numeric, timestamptz, text);
create or replace function wh.record_opening(p_material_id uuid, p_counted numeric,
                                             p_effective_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path = '' as $$
declare d wh.actor; v_id uuid; v_expected numeric;
begin
  d := wh.require_actor();
  perform wh.check_quantity(p_material_id, p_counted, true);
  if p_counted < 0 then raise exception 'a count cannot be negative' using errcode='23514'; end if;
  if p_effective_at > now() then
    raise exception 'a baseline cannot be in the future' using errcode='23514';
  end if;
  if exists (select 1 from wh.opening where material_id = p_material_id and status = 'active') then
    raise exception 'opening_exists: this material already has a baseline; record a physical count instead'
      using errcode='23505';
  end if;
  select expected_qty into v_expected from wh.legacy_expected where material_id = p_material_id;
  insert into wh.opening(material_id, counted, legacy_expected, effective_at, by_person_id, by_device_id)
  values (p_material_id, p_counted, v_expected, p_effective_at, d.person_id, d.device_id)
  returning opening_id into v_id;
  perform wh.log('opening.record', 'material', p_material_id, null,
                 jsonb_build_object('counted', p_counted, 'legacy_expected', v_expected));
  return jsonb_build_object('opening_id', v_id, 'counted', p_counted, 'legacy_expected', v_expected);
end $$;
revoke all on function wh.record_opening(uuid, numeric, timestamptz)
  from public, anon, authenticated, service_role;

drop function if exists public.wh_owner_record_opening(uuid, numeric, timestamptz, text);
alter table wh.opening drop column if exists note;
reset role;

create or replace function public.wh_owner_record_opening(p_material_id uuid, p_counted numeric,
                                                          p_effective_at timestamptz)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return wh.record_opening(p_material_id, p_counted, p_effective_at);
end $$;
revoke all on function public.wh_owner_record_opening(uuid, numeric, timestamptz)
  from public, anon, authenticated, service_role;
grant execute on function public.wh_owner_record_opening(uuid, numeric, timestamptz) to authenticated;
do $$
begin
  execute 'grant create on schema public to wh_owner';
  execute 'alter function public.wh_owner_record_opening(uuid, numeric, timestamptz) owner to wh_owner';
  execute 'revoke create on schema public from wh_owner';
end $$;
-- Note: wh.trail keeps its (harmless) 'note' key; the up migration re-adds the column.
