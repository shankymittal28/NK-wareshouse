-- 0006  the only way anything is written
-- No client role holds insert, update or delete on any table (see 0007).
-- Every function below resolves the acting person from the credential, never from the payload.

create table wh.setting (
  key   text primary key,
  value jsonb not null,
  note  text
);
insert into wh.setting(key, value, note) values
  ('effective_future_tolerance_minutes','120','Clock skew allowed on a device-supplied physical time'),
  ('effective_backdate_free_days','7','Older than this needs a stated reason'),
  ('effective_backdate_max_days','400','Refused beyond this'),
  ('near_duplicate_warn','true','Warn when a new identity normalises like an existing one');

create or replace function wh.setting_num(p_key text, p_default numeric) returns numeric
language sql stable as $$
  select coalesce((select value::text::numeric from wh.setting where key = p_key), p_default)
$$;

-- ---------------------------------------------------------------- materials
create or replace function wh.create_material(p_category_code text, p_attrs jsonb)
returns jsonb language plpgsql security definer set search_path = wh, public as $$
declare d wh.device%rowtype; m wh.material%rowtype; v_norm text; v_look jsonb;
begin
  d := wh.require_actor();
  -- Idempotent: the same exact tuple returns the material that already exists.
  insert into wh.material(category_code, attrs, created_by_person_id)
  values (p_category_code, p_attrs, d.person_id)
  on conflict (category_code, identity_key) do nothing;

  select * into m from wh.material
   where category_code = p_category_code
     and identity_key = wh.exact_join((select array_agg(btrim(coalesce(p_attrs ->> ca.attr_key,'')) order by ca.seq)
                                         from wh.category_attribute ca where ca.category_code = p_category_code));
  if not found then
    raise exception 'could not resolve material identity' using errcode='23514';
  end if;

  -- Look-alikes are reported, never merged. Two identities that merely normalise alike
  -- stay separate until a person says they are the same physical material.
  select coalesce(jsonb_agg(jsonb_build_object('material_id', x.material_id,
                                               'name', wh.material_name(x.material_id))), '[]'::jsonb)
    into v_look
    from wh.material x
   where x.category_code = m.category_code
     and x.norm_key = m.norm_key
     and x.material_id <> m.material_id;

  perform wh.log('material.create', 'material', m.material_id, null,
                 jsonb_build_object('name', wh.material_name(m.material_id), 'look_alikes', v_look));
  return jsonb_build_object('material_id', m.material_id,
                            'name', wh.material_name(m.material_id),
                            'unit_code', m.unit_code, 'decimals', m.decimals,
                            'look_alikes', v_look);
end $$;

-- ---------------------------------------------------------------- drafts
-- One JSON document per movement in progress. A revision that is not newer is a no-op,
-- so a replay or an out-of-order delivery cannot damage anything.
create or replace function wh.draft_put(p_draft_id uuid, p_client_rev int, p_doc jsonb)
returns jsonb language plpgsql security definer set search_path = wh, public as $$
declare d wh.device%rowtype; cur wh.draft%rowtype;
begin
  d := wh.require_actor();
  select * into cur from wh.draft where draft_id = p_draft_id for update;

  if not found then
    insert into wh.draft(draft_id, person_id, device_id, client_rev, doc)
    values (p_draft_id, d.person_id, d.device_id, p_client_rev, p_doc);
    perform wh.touch_device(d.device_id);
    return jsonb_build_object('draft_id', p_draft_id, 'client_rev', p_client_rev,
                              'status', 'open', 'applied', true);
  end if;

  if cur.person_id <> d.person_id then
    raise exception 'this draft belongs to someone else' using errcode='42501';
  end if;
  if cur.status <> 'open' then
    return jsonb_build_object('draft_id', p_draft_id, 'client_rev', cur.client_rev,
                              'status', cur.status, 'applied', false, 'reason', 'not_open');
  end if;
  if p_client_rev <= cur.client_rev then
    return jsonb_build_object('draft_id', p_draft_id, 'client_rev', cur.client_rev,
                              'status', cur.status, 'applied', false, 'reason', 'stale_rev');
  end if;

  update wh.draft
     set client_rev = p_client_rev, doc = p_doc, device_id = d.device_id,
         updated_at = now(), server_received_at = now()
   where draft_id = p_draft_id;
  perform wh.touch_device(d.device_id);
  return jsonb_build_object('draft_id', p_draft_id, 'client_rev', p_client_rev,
                            'status', 'open', 'applied', true);
end $$;

create or replace function wh.abandon_draft(p_draft_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = wh, public as $$
declare d wh.device%rowtype;
begin
  d := wh.require_actor();
  update wh.draft set status = 'abandoned', updated_at = now()
   where draft_id = p_draft_id and status = 'open'
     and (person_id = d.person_id or wh.is_owner());
  perform wh.log('draft.abandon', 'draft', p_draft_id, p_reason);
end $$;

-- ---------------------------------------------------------------- confirm a movement
-- Atomic, and idempotent by the device-minted identity: a retry returns the same event
-- and has no second stock effect.
create or replace function wh.submit_event(p_doc jsonb, p_client_rev int default 0)
returns jsonb language plpgsql security definer set search_path = wh, public as $$
declare
  d wh.device%rowtype;
  cur wh.draft%rowtype;
  v_event_id uuid := (p_doc ->> 'draft_id')::uuid;
  v_type text := upper(coalesce(p_doc ->> 'event_type',''));
  v_eff  timestamptz := (p_doc ->> 'effective_at')::timestamptz;
  v_conf timestamptz := coalesce((p_doc ->> 'confirmed_at')::timestamptz, now());
  v_reason text := nullif(btrim(coalesce(p_doc ->> 'backdated_reason','')), '');
  v_line jsonb; v_no int := 0; v_mat uuid; v_qty numeric; v_stock numeric;
  v_free_days numeric; v_max_days numeric; v_skew numeric;
  v_lines int := 0; v_had_draft boolean := false;
begin
  d := wh.require_actor();
  if v_event_id is null then raise exception 'draft_id is required' using errcode='23514'; end if;

  -- already accepted: say so and change nothing
  if exists (select 1 from wh.stock_event where event_id = v_event_id) then
    return jsonb_build_object('event_id', v_event_id, 'already', true,
                              'lines', (select count(*) from wh.event_line where event_id = v_event_id));
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_event_id::text, 0));
  if exists (select 1 from wh.stock_event where event_id = v_event_id) then
    return jsonb_build_object('event_id', v_event_id, 'already', true,
                              'lines', (select count(*) from wh.event_line where event_id = v_event_id));
  end if;

  -- the exact draft the person reviewed
  select * into cur from wh.draft where draft_id = v_event_id for update;
  v_had_draft := found;
  if v_had_draft then
    if cur.person_id <> d.person_id and not wh.is_owner() then
      raise exception 'this draft belongs to someone else' using errcode='42501';
    end if;
    if cur.status = 'confirmed' then
      return jsonb_build_object('event_id', v_event_id, 'already', true);
    end if;
    if cur.client_rev > p_client_rev then
      raise exception 'rev_mismatch: this draft has changed since you reviewed it (server rev %, you sent %)',
        cur.client_rev, p_client_rev using errcode='40001';
    end if;
  end if;

  if v_type not in ('IN','OUT') then
    raise exception 'a movement must be IN or OUT; adjustments come from an approved count'
      using errcode='23514';
  end if;
  if v_eff is null then raise exception 'effective_at is required' using errcode='23514'; end if;

  v_skew      := wh.setting_num('effective_future_tolerance_minutes', 120);
  v_free_days := wh.setting_num('effective_backdate_free_days', 7);
  v_max_days  := wh.setting_num('effective_backdate_max_days', 400);
  if v_eff > now() + make_interval(mins => v_skew::int) then
    raise exception 'the physical time is in the future' using errcode='23514';
  end if;
  if v_eff < now() - make_interval(days => v_max_days::int) then
    raise exception 'the physical time is too far in the past to record here' using errcode='23514';
  end if;
  if v_eff < now() - make_interval(days => v_free_days::int) and v_reason is null then
    raise exception 'back-dating beyond % days needs a stated reason', v_free_days using errcode='23514';
  end if;

  insert into wh.stock_event(event_id, event_type, effective_at, confirmed_at,
      device_claimed_at, backdated_reason, recorder_person_id, handler_person_id, device_id,
      counterparty, kind, vehicle, ref_type, ref_number, ref_date, no_paper, notes,
      created_from_draft_rev)
  values (v_event_id, v_type, v_eff, v_conf,
      (p_doc ->> 'device_claimed_at')::timestamptz, v_reason,
      d.person_id,                                    -- recorder is the credential, never the payload
      nullif(p_doc ->> 'handler_person_id','')::uuid, d.device_id,
      nullif(btrim(coalesce(p_doc ->> 'counterparty','')), ''),
      nullif(btrim(coalesce(p_doc ->> 'kind','')), ''),
      nullif(btrim(coalesce(p_doc ->> 'vehicle','')), ''),
      nullif(btrim(coalesce(p_doc ->> 'ref_type','')), ''),
      nullif(btrim(coalesce(p_doc ->> 'ref_number','')), ''),
      nullif(p_doc ->> 'ref_date','')::date,
      coalesce((p_doc ->> 'no_paper')::boolean, false),
      nullif(btrim(coalesce(p_doc ->> 'notes','')), ''),
      p_client_rev);

  for v_line in select * from jsonb_array_elements(coalesce(p_doc -> 'lines', '[]'::jsonb)) loop
    v_no := v_no + 1;
    v_mat := (v_line ->> 'material_id')::uuid;
    v_qty := (v_line ->> 'qty')::numeric;
    perform wh.check_quantity(v_mat, v_qty);          -- precision belongs to the material
    if v_qty <= 0 then
      raise exception 'line % must be a positive quantity', v_no using errcode='23514';
    end if;
    if v_type = 'OUT' then
      v_stock := wh.stock_as_of(v_mat);
      if v_stock is not null and v_qty > v_stock
         and not coalesce((v_line ->> 'over_ack')::boolean, false) then
        raise exception 'line % gives out % but only % is recorded; needs a deliberate acknowledgement',
          v_no, v_qty, v_stock using errcode='23514';
      end if;
    end if;
    insert into wh.event_line(line_id, event_id, line_no, material_id, qty, over_ack, intentional_duplicate)
    values (coalesce(nullif(v_line ->> 'line_id','')::uuid, gen_random_uuid()),
            v_event_id, v_no, v_mat, v_qty,
            coalesce((v_line ->> 'over_ack')::boolean, false),
            coalesce((v_line ->> 'intentional_duplicate')::boolean, false));
    v_lines := v_lines + 1;
  end loop;

  if v_lines = 0 then
    raise exception 'a movement needs at least one line' using errcode='23514';
  end if;

  if v_had_draft then
    update wh.draft set status = 'confirmed', updated_at = now() where draft_id = v_event_id;
  end if;
  perform wh.touch_device(d.device_id);
  perform wh.log('event.confirm', 'event', v_event_id, null,
                 jsonb_build_object('type', v_type, 'lines', v_lines, 'effective_at', v_eff));
  return jsonb_build_object('event_id', v_event_id, 'already', false, 'lines', v_lines);
exception when unique_violation then
  -- Only the event identity may lose a race. Anything else is a real fault and must surface.
  if exists (select 1 from wh.stock_event where event_id = v_event_id) then
    return jsonb_build_object('event_id', v_event_id, 'already', true, 'raced', true);
  end if;
  raise;
end $$;

-- ---------------------------------------------------------------- corrections
-- The confirmed rows are never touched. A correction appends the fields it changes.
create or replace function wh.assert_may_correct(p_event_id uuid) returns wh.device
language plpgsql stable security definer set search_path = wh, public as $$
declare d wh.device%rowtype; v_recorder uuid;
begin
  d := wh.require_actor();
  select recorder_person_id into v_recorder from wh.stock_event where event_id = p_event_id;
  if v_recorder is null then raise exception 'no such event' using errcode='23503'; end if;
  if not wh.is_owner() and v_recorder <> d.person_id then
    raise exception 'only the person who recorded this, or the owner, may correct it' using errcode='42501';
  end if;
  return d;
end $$;

-- Moving a line to another material reverses one and applies the other in the same fact,
-- because stock reads the line's effective material rather than a stored balance.
create or replace function wh.correct_line(p_line_id uuid, p_reason text,
                                           p_new_material_id uuid default null,
                                           p_new_qty numeric default null,
                                           p_void boolean default null)
returns jsonb language plpgsql security definer set search_path = wh, public as $$
declare d wh.device%rowtype; l wh.event_line%rowtype; v_eff_mat uuid; v_cid uuid;
begin
  select * into l from wh.event_line where line_id = p_line_id;
  if not found then raise exception 'no such line' using errcode='23503'; end if;
  d := wh.assert_may_correct(l.event_id);
  if coalesce(btrim(p_reason),'') = '' then
    raise exception 'a correction needs a reason' using errcode='23514';
  end if;
  if p_new_material_id is null and p_new_qty is null and p_void is null then
    raise exception 'nothing to correct' using errcode='23514';
  end if;

  select material_id into v_eff_mat from wh.line_effective where line_id = p_line_id;
  if p_new_qty is not null then
    perform wh.check_quantity(coalesce(p_new_material_id, v_eff_mat), p_new_qty);
    if p_new_qty <= 0 and (select event_type from wh.event_effective where event_id = l.event_id) in ('IN','OUT') then
      raise exception 'a corrected movement quantity must stay positive; void the line instead'
        using errcode='23514';
    end if;
  end if;

  insert into wh.line_correction(line_id, new_material_id, new_qty, new_voided,
                                 reason, by_person_id, by_device_id)
  values (p_line_id, p_new_material_id, p_new_qty, p_void, p_reason, d.person_id, d.device_id)
  returning correction_id into v_cid;

  perform wh.log('line.correct', 'line', p_line_id, p_reason,
                 jsonb_build_object('from_material', v_eff_mat, 'to_material', p_new_material_id,
                                    'new_qty', p_new_qty, 'voided', p_void));
  return jsonb_build_object('correction_id', v_cid, 'line_id', p_line_id,
                            'effective', (select to_jsonb(x) from wh.line_effective x where x.line_id = p_line_id));
end $$;

-- A line noticed afterwards belongs to the same physical movement, added visibly.
create or replace function wh.add_line(p_event_id uuid, p_material_id uuid, p_qty numeric, p_reason text)
returns jsonb language plpgsql security definer set search_path = wh, public as $$
declare d wh.device%rowtype; v_no int; v_line uuid;
begin
  d := wh.assert_may_correct(p_event_id);
  if coalesce(btrim(p_reason),'') = '' then
    raise exception 'an added line needs a reason' using errcode='23514';
  end if;
  perform wh.check_quantity(p_material_id, p_qty);
  if p_qty <= 0 then raise exception 'quantity must be positive' using errcode='23514'; end if;
  select coalesce(max(line_no),0) + 1 into v_no from wh.event_line where event_id = p_event_id;
  insert into wh.event_line(line_id, event_id, line_no, material_id, qty,
                            added_at, added_by_person_id, added_reason)
  values (gen_random_uuid(), p_event_id, v_no, p_material_id, p_qty, now(), d.person_id, p_reason)
  returning line_id into v_line;
  perform wh.log('line.add', 'event', p_event_id, p_reason,
                 jsonb_build_object('line_id', v_line, 'qty', p_qty));
  return jsonb_build_object('line_id', v_line, 'line_no', v_no);
end $$;

create or replace function wh.correct_event(p_event_id uuid, p_reason text, p_fields jsonb)
returns jsonb language plpgsql security definer set search_path = wh, public as $$
declare d wh.device%rowtype; v_new_type text := upper(nullif(p_fields ->> 'event_type','')); v_cid uuid;
begin
  d := wh.assert_may_correct(p_event_id);
  if coalesce(btrim(p_reason),'') = '' then
    raise exception 'a correction needs a reason' using errcode='23514';
  end if;
  -- Reversing a direction moves every line of the event at once, so only the owner may do it.
  if v_new_type is not null and not wh.is_owner() then
    raise exception 'only the owner may change the direction of a recorded movement' using errcode='42501';
  end if;
  if v_new_type is not null and v_new_type not in ('IN','OUT') then
    raise exception 'direction must be IN or OUT' using errcode='23514';
  end if;

  insert into wh.event_correction(event_id, new_event_type, new_effective_at, new_handler_person_id,
      new_counterparty, new_kind, new_vehicle, new_ref_type, new_ref_number, new_ref_date,
      new_no_paper, new_notes, reason, by_person_id, by_device_id)
  values (p_event_id, v_new_type,
      (nullif(p_fields ->> 'effective_at',''))::timestamptz,
      (nullif(p_fields ->> 'handler_person_id',''))::uuid,
      nullif(p_fields ->> 'counterparty',''), nullif(p_fields ->> 'kind',''),
      nullif(p_fields ->> 'vehicle',''), nullif(p_fields ->> 'ref_type',''),
      nullif(p_fields ->> 'ref_number',''), (nullif(p_fields ->> 'ref_date',''))::date,
      (nullif(p_fields ->> 'no_paper',''))::boolean, nullif(p_fields ->> 'notes',''),
      p_reason, d.person_id, d.device_id)
  returning correction_id into v_cid;

  perform wh.log('event.correct', 'event', p_event_id, p_reason, p_fields);
  return jsonb_build_object('correction_id', v_cid,
                            'effective', (select to_jsonb(x) from wh.event_effective x where x.event_id = p_event_id));
end $$;

-- ---------------------------------------------------------------- opening and counts
create or replace function wh.record_opening(p_material_id uuid, p_counted numeric,
                                             p_effective_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path = wh, public as $$
declare d wh.device%rowtype; v_id uuid; v_expected numeric;
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

create or replace function wh.supersede_opening(p_material_id uuid, p_counted numeric,
                                                p_effective_at timestamptz, p_reason text)
returns jsonb language plpgsql security definer set search_path = wh, public as $$
declare d wh.device%rowtype; v_old uuid; v_new uuid;
begin
  d := wh.require_owner();
  if coalesce(btrim(p_reason),'') = '' then
    raise exception 'replacing a baseline needs a reason' using errcode='23514';
  end if;
  perform wh.check_quantity(p_material_id, p_counted, true);
  select opening_id into v_old from wh.opening where material_id = p_material_id and status = 'active';
  if v_old is null then raise exception 'there is no baseline to replace' using errcode='23503'; end if;
  -- retire the old baseline first: only one may be active at a time
  update wh.opening set status = 'superseded', superseded_at = now(), superseded_reason = p_reason
   where opening_id = v_old;
  insert into wh.opening(material_id, counted, effective_at, by_person_id, by_device_id)
  values (p_material_id, p_counted, p_effective_at, d.person_id, d.device_id)
  returning opening_id into v_new;
  update wh.opening set superseded_by_opening_id = v_new where opening_id = v_old;
  perform wh.log('opening.supersede', 'material', p_material_id, p_reason,
                 jsonb_build_object('old', v_old, 'new', v_new));
  return jsonb_build_object('opening_id', v_new, 'superseded', v_old);
end $$;

create or replace function wh.report_count(p_material_id uuid, p_counted numeric,
                                           p_counted_at timestamptz default now(),
                                           p_note text default null)
returns jsonb language plpgsql security definer set search_path = wh, public as $$
declare d wh.device%rowtype; v_basis numeric; v_id uuid; v_status text;
begin
  d := wh.require_actor();
  perform wh.check_quantity(p_material_id, p_counted, true);
  if p_counted < 0 then raise exception 'a count cannot be negative' using errcode='23514'; end if;
  if p_counted_at > now() then raise exception 'a count cannot be in the future' using errcode='23514'; end if;
  if not exists (select 1 from wh.opening where material_id = p_material_id and status = 'active') then
    raise exception 'no_opening: the first count of a material is its opening baseline'
      using errcode='23503';
  end if;

  -- The basis is the stock at the moment of counting, using only what NK knew by then.
  v_basis := wh.stock_as_of(p_material_id, p_counted_at, now());
  if v_basis is null then
    raise exception 'this count is earlier than the material''s baseline' using errcode='23514';
  end if;
  v_status := case when p_counted = v_basis then 'approved' else 'pending' end;

  insert into wh.count_report(material_id, counted, counted_at, recorded_at_count,
                              by_person_id, by_device_id, note, status,
                              resolved_at, resolved_by_person_id)
  values (p_material_id, p_counted, p_counted_at, v_basis, d.person_id, d.device_id, p_note, v_status,
          case when v_status = 'approved' then now() end,
          case when v_status = 'approved' then d.person_id end)
  returning count_id into v_id;

  perform wh.log('count.report', 'material', p_material_id, p_note,
                 jsonb_build_object('counted', p_counted, 'basis', v_basis, 'status', v_status));
  return jsonb_build_object('count_id', v_id, 'recorded_at_count', v_basis,
                            'difference', p_counted - v_basis, 'status', v_status);
end $$;

-- What changed in the history at or before the count, after the count was reported.
create or replace function wh.count_basis_changes(p_count_id uuid) returns jsonb
language sql stable as $$
  with c as (select * from wh.count_report where count_id = p_count_id)
  select jsonb_build_object(
    'late_events', coalesce((
      select jsonb_agg(jsonb_build_object('event_id', e.event_id, 'effective_at', e.effective_at,
                                          'received_at', e.server_received_at))
        from c, wh.event_effective e
        join wh.line_effective le on le.event_id = e.event_id
       where le.material_id = c.material_id
         and e.effective_at <= c.counted_at
         and e.server_received_at > c.reported_at), '[]'::jsonb),
    'late_corrections', coalesce((
      select jsonb_agg(jsonb_build_object('line_id', lc.line_id, 'at', lc.at, 'reason', lc.reason))
        from c, wh.line_correction lc
        join wh.event_line l on l.line_id = lc.line_id
        join wh.stock_event e on e.event_id = l.event_id
       where lc.at > c.reported_at
         and e.effective_at <= c.counted_at
         and (l.material_id = c.material_id or lc.new_material_id = c.material_id)), '[]'::jsonb)
  )
$$;

create or replace function wh.approve_count(p_count_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = wh, public as $$
declare d wh.device%rowtype; c wh.count_report%rowtype; v_now_basis numeric;
        v_delta numeric; v_event uuid;
begin
  d := wh.require_owner();
  select * into c from wh.count_report where count_id = p_count_id for update;
  if not found then raise exception 'no such count' using errcode='23503'; end if;
  if c.status not in ('pending','needs_review') then
    raise exception 'this count is already %', c.status using errcode='23514';
  end if;

  -- Recompute the same instant with everything now known. If the basis moved, the
  -- difference cannot be applied as it stands.
  v_now_basis := wh.stock_as_of(c.material_id, c.counted_at, now());
  if v_now_basis is distinct from c.recorded_at_count then
    update wh.count_report set status = 'needs_review', resolution_reason =
      'the recorded history before this count changed after the count was taken'
     where count_id = p_count_id;
    perform wh.log('count.needs_review', 'material', c.material_id, null,
                   jsonb_build_object('basis_at_report', c.recorded_at_count, 'basis_now', v_now_basis));
    return jsonb_build_object('status', 'needs_review',
                              'basis_at_report', c.recorded_at_count, 'basis_now', v_now_basis,
                              'changes', wh.count_basis_changes(p_count_id));
  end if;

  v_delta := c.counted - c.recorded_at_count;
  if v_delta = 0 then
    update wh.count_report set status = 'approved', resolved_at = now(),
           resolved_by_person_id = d.person_id, resolution_reason = p_reason
     where count_id = p_count_id;
    return jsonb_build_object('status', 'approved', 'delta', 0);
  end if;

  -- The adjustment happened at the moment of the count, so movements after it stand.
  v_event := gen_random_uuid();
  insert into wh.stock_event(event_id, event_type, effective_at, confirmed_at,
      recorder_person_id, device_id, notes, adjustment_of_count_id)
  values (v_event, 'ADJUSTMENT', c.counted_at, now(), d.person_id, d.device_id, p_reason, p_count_id);
  insert into wh.event_line(line_id, event_id, line_no, material_id, qty)
  values (gen_random_uuid(), v_event, 1, c.material_id, v_delta);

  update wh.count_report set status = 'approved', resolved_at = now(),
         resolved_by_person_id = d.person_id, resolution_reason = p_reason,
         adjustment_event_id = v_event
   where count_id = p_count_id;

  perform wh.log('count.approve', 'material', c.material_id, p_reason,
                 jsonb_build_object('delta', v_delta, 'event_id', v_event));
  return jsonb_build_object('status', 'approved', 'delta', v_delta, 'event_id', v_event,
                            'stock_now', wh.stock_as_of(c.material_id));
end $$;

create or replace function wh.resolve_count(p_count_id uuid, p_status text, p_reason text)
returns jsonb language plpgsql security definer set search_path = wh, public as $$
declare d wh.device%rowtype;
begin
  d := wh.require_owner();
  if p_status not in ('rejected','recount') then
    raise exception 'use approve_count to approve' using errcode='23514';
  end if;
  update wh.count_report set status = p_status, resolved_at = now(),
         resolved_by_person_id = d.person_id, resolution_reason = p_reason
   where count_id = p_count_id and status in ('pending','needs_review');
  if not found then raise exception 'no open count to resolve' using errcode='23503'; end if;
  perform wh.log('count.' || p_status, 'count', p_count_id, p_reason);
  return jsonb_build_object('status', p_status);
end $$;

-- ---------------------------------------------------------------- valuation and evidence
create or replace function wh.set_rate(p_material_id uuid, p_rate numeric)
returns jsonb language plpgsql security definer set search_path = wh, public as $$
declare d wh.device%rowtype;
begin
  d := wh.require_owner();
  if p_rate is null or p_rate <= 0 then raise exception 'a rate must be positive' using errcode='23514'; end if;
  insert into wh.rate(material_id, rate, set_by_person_id)
  values (p_material_id, round(p_rate,4), d.person_id)
  on conflict (material_id) do update set rate = excluded.rate, set_at = now(),
                                          set_by_person_id = excluded.set_by_person_id;
  insert into wh.rate_history(material_id, rate, set_by_person_id) values (p_material_id, round(p_rate,4), d.person_id);
  perform wh.log('rate.set', 'material', p_material_id, null, jsonb_build_object('rate', p_rate));
  return jsonb_build_object('material_id', p_material_id, 'rate', round(p_rate,4));
end $$;

create or replace function wh.attach_evidence(p_event_id uuid, p_bucket_path text,
                                              p_sha256 text default null, p_bytes bigint default null,
                                              p_taken_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = wh, public as $$
declare d wh.device%rowtype; v_id uuid;
begin
  d := wh.require_actor();
  if not exists (select 1 from wh.stock_event where event_id = p_event_id) then
    raise exception 'no such event' using errcode='23503';
  end if;
  insert into wh.evidence(event_id, bucket_path, sha256, bytes, taken_at, by_person_id)
  values (p_event_id, p_bucket_path, p_sha256, p_bytes, p_taken_at, d.person_id)
  on conflict (bucket_path) do nothing
  returning evidence_id into v_id;
  return jsonb_build_object('evidence_id',
    coalesce(v_id, (select evidence_id from wh.evidence where bucket_path = p_bucket_path)),
    'already', v_id is null);
end $$;

-- ---------------------------------------------------------------- first owner
-- The dedicated warehouse project has its own auth realm, so the owner's existing login
-- elsewhere cannot sign him in here and his password is never copied or read. The deployer,
-- holding the service key, seeds the owner person and one activation code. The owner then
-- creates his own password in this project, signs in, and redeems the code once from his
-- phone. From then on he issues codes for everybody else through the normal path.
create or replace function wh.bootstrap_owner(p_display_name text, p_hours int default 72)
returns text language plpgsql security definer set search_path = wh, public as $$
declare v_person uuid; v_code text; v_salt text;
begin
  if exists (select 1 from wh.device d join wh.person p on p.person_id = d.person_id
              where p.role = 'owner' and d.revoked_at is null) then
    raise exception 'an owner device already exists; use issue_activation_code' using errcode='23505';
  end if;
  select person_id into v_person from wh.person where role = 'owner' and active order by created_at limit 1;
  if v_person is null then
    insert into wh.person(display_name, role) values (p_display_name, 'owner') returning person_id into v_person;
  end if;
  select string_agg(substr('23456789ABCDEFGHJKLMNPQRSTUVWXYZ', 1 + (get_byte(b, i) % 32), 1), '')
    into v_code
    from (select uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid()) as b) r,
         generate_series(0, 7) as i;
  v_salt := encode(uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid()), 'hex');
  update wh.activation_code set void_at = now() where person_id = v_person and used_at is null and void_at is null;
  insert into wh.activation_code(person_id, salt, code_hash, expires_at)
  values (v_person, v_salt, wh.hash_code(v_code, v_salt), now() + make_interval(hours => p_hours));
  insert into wh.audit(action, subject_type, subject_id, detail)
  values ('owner.bootstrap', 'person', v_person, jsonb_build_object('name', p_display_name));
  return v_code;
end $$;
revoke all on function wh.bootstrap_owner(text,int) from public, anon, authenticated;
