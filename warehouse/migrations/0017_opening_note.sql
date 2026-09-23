-- 0017  opening.note + owner-only recording of a trusted opening count
--
-- Stage 1C turns "old records suggest" into a physically verified baseline. The
-- opening model already carries counted, legacy_expected, effective_at, who and
-- when; this adds an optional note as a first-class, immutable attribute of the
-- opening (e.g. "3 sheets water-damaged, excluded") and shows it in the trail.
--
-- It also states, at the boundary, what was only implied before: recording an
-- opening is the OWNER's act. wh.record_opening resolves any actor; the public
-- entry point now demands the owner explicitly, so the guarantee does not rest
-- on who happens to hold a session.
--
-- Nothing about legacy lines, existing openings, valuation or stock arithmetic
-- changes. The old three-argument forms are dropped so exactly one signature
-- remains (PostgREST resolves overloads by argument name, and an ambiguous pair
-- would break the call).

-- Portability: on Supabase the migrating role is only a NOINHERIT *member* of
-- wh_owner, not a superuser, so it cannot ALTER a wh_owner-owned table or replace
-- a wh_owner-owned function directly. SET ROLE wh_owner does the schema-wh work as
-- the caretaker itself (allowed for a member and for a superuser alike); the
-- schema-public grant dance below runs back as the migrating role. Locally, where
-- the migrator is a superuser, both halves work unchanged.
set role wh_owner;

alter table wh.opening add column if not exists note text;

-- ---------------------------------------------------------------- wh.record_opening (+ note)
drop function if exists wh.record_opening(uuid, numeric, timestamptz);
create or replace function wh.record_opening(p_material_id uuid, p_counted numeric,
                                             p_effective_at timestamptz default now(),
                                             p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare d wh.actor; v_id uuid; v_expected numeric; v_note text;
begin
  d := wh.require_actor();
  v_note := nullif(btrim(p_note), '');
  perform wh.check_quantity(p_material_id, p_counted, true);   -- allow_zero: a real count may be 0
  if p_counted < 0 then raise exception 'a count cannot be negative' using errcode='23514'; end if;
  if p_effective_at > now() then
    raise exception 'a baseline cannot be in the future' using errcode='23514';
  end if;
  if exists (select 1 from wh.opening where material_id = p_material_id and status = 'active') then
    raise exception 'opening_exists: this material already has a baseline; record a physical count instead'
      using errcode='23505';
  end if;
  select expected_qty into v_expected from wh.legacy_expected where material_id = p_material_id;
  insert into wh.opening(material_id, counted, legacy_expected, effective_at, note, by_person_id, by_device_id)
  values (p_material_id, p_counted, v_expected, p_effective_at, v_note, d.person_id, d.device_id)
  returning opening_id into v_id;
  perform wh.log('opening.record', 'material', p_material_id, v_note,
                 jsonb_build_object('counted', p_counted, 'legacy_expected', v_expected, 'note', v_note));
  return jsonb_build_object('opening_id', v_id, 'counted', p_counted,
                            'legacy_expected', v_expected, 'note', v_note);
end $$;
-- Created as wh_owner, so it is already caretaker-owned. A freshly created
-- function still carries PostgreSQL's default EXECUTE-to-PUBLIC, and no internal
-- wh function may be callable by a client role (boundary 3.3), so close it.
revoke all on function wh.record_opening(uuid, numeric, timestamptz, text)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------- wh.trail (show the note on the opening row)
create or replace function wh.trail(p_material_id uuid)
returns table(kind text, at timestamptz, delta numeric, running numeric,
              label text, detail jsonb, event_id uuid, counts boolean)
language sql stable set search_path = '' as $$
  with o as (select * from wh.opening where material_id = p_material_id and status = 'active'),
  legacy as (
    select 'legacy'::text as kind, l.occurred_at as at,
           (case l.direction when 'in' then l.qty else -l.qty end) as delta,
           coalesce(l.counterparty,'') as label,
           jsonb_build_object('recorded_by_name', l.recorded_by_name,
                              'photos', (select count(*) from wh.legacy_photo p where p.legacy_id = l.legacy_id),
                              'suspect_duplicate', l.suspect_duplicate_of is not null) as detail,
           null::uuid as event_id, false as counts
      from wh.legacy_line l where l.material_id = p_material_id
  ),
  opening as (
    select 'opening'::text, o.effective_at, o.counted, 'opening count'::text,
           jsonb_build_object('by', p.display_name, 'legacy_expected', o.legacy_expected, 'note', o.note),
           null::uuid, true
      from o join wh.person p on p.person_id = o.by_person_id
  ),
  moves as (
    select case e.event_type when 'ADJUSTMENT' then 'adjustment' else lower(e.event_type) end,
           e.effective_at,
           wh.line_sign(e.event_type) * le.qty,
           coalesce(e.counterparty, '') ,
           jsonb_build_object(
             'ref', nullif(concat_ws(' ', e.ref_type, e.ref_number), ''),
             'handler', (select display_name from wh.person where person_id = e.handler_person_id),
             'recorder', (select display_name from wh.person where person_id = e.recorder_person_id),
             'received_by_nk', e.server_received_at,
             'photos', (select count(*) from wh.evidence v where v.event_id = e.event_id),
             'corrections', (select coalesce(jsonb_agg(jsonb_build_object(
                                 'from_qty', c.new_qty is not null,
                                 'reason', c.reason,
                                 'at', c.at) order by c.seq), '[]'::jsonb)
                               from wh.line_correction c where c.line_id = le.line_id),
             'moved_here_by_correction',
               exists (select 1 from wh.line_correction c
                        where c.line_id = le.line_id and c.new_material_id = p_material_id),
             'late_pre_baseline', (o.effective_at is not null and e.effective_at <= o.effective_at)
           ),
           e.event_id, (o.effective_at is not null and e.effective_at > o.effective_at)
      from wh.line_effective le
      join wh.event_effective e on e.event_id = le.event_id
      left join o on true
     where le.material_id = p_material_id and not le.voided
  ),
  all_rows as (
    select * from legacy union all select * from opening union all select * from moves
  )
  select kind, at, delta,
         sum(case when counts then delta else 0 end) over (order by at, kind rows unbounded preceding) as running,
         label, detail, event_id, counts
    from all_rows
   order by at, kind
$$;
-- create-or-replace keeps the caretaker's ownership; assert it below just in case.

-- ---------------------------------------------------------------- public.wh_owner_record_opening (owner-only, + note)
-- Drop the old wrapper while still the caretaker (it owns the wrapper), then hand
-- control back to the migrating role, which owns schema public, to recreate it.
drop function if exists public.wh_owner_record_opening(uuid, numeric, timestamptz);
reset role;

create or replace function public.wh_owner_record_opening(p_material_id uuid, p_counted numeric,
                                                          p_effective_at timestamptz, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform wh.require_owner();   -- the owner establishes the trusted baseline, stated here
  return wh.record_opening(p_material_id, p_counted, p_effective_at, p_note);
end $$;

-- Grant BEFORE the ownership handover: a grant on an object you do not own only warns.
revoke all on function public.wh_owner_record_opening(uuid, numeric, timestamptz, text)
  from public, anon, authenticated, service_role;
grant execute on function public.wh_owner_record_opening(uuid, numeric, timestamptz, text) to authenticated;
do $$
begin
  execute 'grant create on schema public to wh_owner';
  execute 'alter function public.wh_owner_record_opening(uuid, numeric, timestamptz, text) owner to wh_owner';
  execute 'revoke create on schema public from wh_owner';
end $$;

-- ---------------------------------------------------------------- assertions (the boundary must still hold)
do $$
declare n int;
begin
  -- exactly one wh_owner_record_opening, and it is the four-argument form
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='public' and p.proname='wh_owner_record_opening';
  if n <> 1 then raise exception 'expected exactly one wh_owner_record_opening, found %', n; end if;

  -- owner-owned wrapper, security definer, pinned search_path
  if (select pg_get_userbyid(proowner) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
       where ns.nspname='public' and p.proname='wh_owner_record_opening') <> 'wh_owner' then
    raise exception 'wh_owner_record_opening must be owned by the caretaker';
  end if;

  -- the recreated wh functions are owned by the caretaker
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='wh' and p.proname in ('record_opening','trail')
     and pg_get_userbyid(p.proowner) <> 'wh_owner';
  if n <> 0 then raise exception '% wh function(s) not owned by the caretaker', n; end if;

  -- not reachable by the public key, still exactly nine anon-callable wrappers
  if has_function_privilege('anon','public.wh_owner_record_opening(uuid,numeric,timestamptz,text)','EXECUTE')
     or has_function_privilege('public','public.wh_owner_record_opening(uuid,numeric,timestamptz,text)','EXECUTE') then
    raise exception 'wh_owner_record_opening must not be anon/PUBLIC callable';
  end if;
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='public' and p.proname like 'wh\_%' and has_function_privilege('anon',p.oid,'EXECUTE');
  if n <> 9 then raise exception 'anon-callable count changed to %, expected 9', n; end if;
end $$;
