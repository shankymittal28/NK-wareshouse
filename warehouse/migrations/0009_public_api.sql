-- 0009  the entire public surface of the warehouse
--
-- PostgREST serves the `public` schema. `wh` is private and stays private, so
-- every call from a phone lands on one of the functions below and nowhere else.
--
-- Each one:
--   * is owned by the confined caretaker, so it borrows only wh's authority;
--   * pins `search_path = ''` and names every object in full;
--   * builds no SQL from client text;
--   * resolves device -> person from the credential, never from the payload;
--   * has EXECUTE revoked from PUBLIC before it is granted to one role.
--
-- That last step is not optional on Supabase: this project's default
-- privileges grant EXECUTE on every new function in `public` to anon,
-- authenticated and service_role. A function created here is callable by the
-- world until we say otherwise. 0010 asserts the final list by name and count.
--
-- Staff functions take the device credential as their first argument. It
-- travels in the POST body, never in a URL, so it cannot reach an access log.
-- Owner functions take no credential: they read the signed Supabase claim the
-- owner already signs in with for NK.

-- ---------------------------------------------------------------- staff API
create or replace function public.wh_activate(p_code text, p_label text)
returns jsonb language sql security definer set search_path = '' as $$
  select wh.activate_device(p_code, p_label)
$$;
comment on function public.wh_activate(text, text) is
  'Exchange a one-time owner-issued code for this phone''s device credential.';

create or replace function public.wh_ping(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare d wh.device%rowtype;
begin
  d := wh.assume_device(p_token);
  return jsonb_build_object(
    'ok', true,
    'person', (select display_name from wh.person where person_id = d.person_id),
    'role',   (select role from wh.person where person_id = d.person_id),
    'device_label', d.label);
exception when insufficient_privilege then
  return jsonb_build_object('ok', false, 'error', 'unauthorised');
end $$;
comment on function public.wh_ping(text) is
  'Is this phone still authorised? Lets the app tell "revoked" from "no signal".';

-- The whole catalogue, small enough to cache on the phone, so searching works
-- with no signal. Quantities and names only: no rate, no value, ever.
create or replace function public.wh_catalogue(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform wh.assume_device(p_token);
  return jsonb_build_object(
    'categories', (select coalesce(jsonb_agg(to_jsonb(c) order by c.sort), '[]'::jsonb) from wh.category c),
    'attributes', (select coalesce(jsonb_agg(to_jsonb(a) order by a.category_code, a.seq), '[]'::jsonb)
                     from wh.category_attribute a),
    'values',     (select coalesce(jsonb_agg(to_jsonb(v)), '[]'::jsonb) from wh.attribute_value v),
    'materials',  (select coalesce(jsonb_agg(jsonb_build_object(
                             'material_id', m.material_id, 'category_code', m.category_code,
                             'attrs', m.attrs, 'unit_code', m.unit_code,
                             'decimals', m.decimals, 'step', m.step,
                             'identity_incomplete', m.identity_incomplete)), '[]'::jsonb)
                     from wh.material m));
end $$;

create or replace function public.wh_stock_for_staff(p_token text, p_material_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform wh.assume_device(p_token);
  return jsonb_build_object(
    'material_id', p_material_id,
    'name', wh.material_name(p_material_id),
    'qty',  wh.stock_as_of(p_material_id));   -- quantity only; money is not reachable here
end $$;

create or replace function public.wh_draft_put(p_token text, p_draft_id uuid,
                                               p_client_rev integer, p_doc jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform wh.assume_device(p_token);
  return wh.draft_put(p_draft_id, p_client_rev, p_doc);
end $$;

create or replace function public.wh_abandon_draft(p_token text, p_draft_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform wh.assume_device(p_token);
  perform wh.abandon_draft(p_draft_id, p_reason);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.wh_submit_event(p_token text, p_doc jsonb, p_client_rev integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform wh.assume_device(p_token);
  return wh.submit_event(p_doc, p_client_rev);
end $$;

create or replace function public.wh_report_count(p_token text, p_material_id uuid,
                                                  p_counted numeric, p_counted_at timestamptz, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform wh.assume_device(p_token);
  return wh.report_count(p_material_id, p_counted, p_counted_at, p_note);
end $$;

create or replace function public.wh_attach_evidence(p_token text, p_event_id uuid,
                                                     p_bucket_path text, p_sha256 text,
                                                     p_bytes bigint, p_taken_at timestamptz)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform wh.assume_device(p_token);
  return wh.attach_evidence(p_event_id, p_bucket_path, p_sha256, p_bytes, p_taken_at);
end $$;

-- ---------------------------------------------------------------- owner API
-- No credential argument: the owner is whoever holds the signed Supabase claim
-- that wh.jwt_is_owner() recognises. One owner identity, the existing one.
create or replace function public.wh_owner_issue_code(p_person_id uuid, p_minutes integer, p_mode text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return jsonb_build_object('ok', true,
    'code', wh.issue_activation_code(p_person_id, coalesce(p_minutes, 15), coalesce(p_mode, 'add')));
end $$;

create or replace function public.wh_owner_revoke_device(p_device_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform wh.revoke_device(p_device_id, p_reason);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.wh_owner_devices()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform wh.require_owner();
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'device_id', d.device_id, 'person', p.display_name, 'label', d.label,
            'activated_at', d.activated_at, 'last_seen_at', d.last_seen_at,
            'revoked_at', d.revoked_at, 'revoked_reason', d.revoked_reason)
            order by d.activated_at desc), '[]'::jsonb)
            from wh.device d join wh.person p on p.person_id = d.person_id);
end $$;
comment on function public.wh_owner_devices() is
  'The phone list. Carries no credential material -- token_hash is not selected.';

create or replace function public.wh_owner_add_person(p_display_name text, p_role text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return wh.add_person(p_display_name, p_role);
end $$;

create or replace function public.wh_owner_set_person_active(p_person_id uuid, p_active boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return wh.set_person_active(p_person_id, p_active, p_reason);
end $$;

create or replace function public.wh_owner_people()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform wh.require_owner();
  return (select coalesce(jsonb_agg(to_jsonb(p) order by p.display_name), '[]'::jsonb) from wh.person p);
end $$;

create or replace function public.wh_owner_stock()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform wh.require_owner();
  return (select coalesce(jsonb_agg(to_jsonb(v)), '[]'::jsonb) from wh.material_value v);
end $$;

create or replace function public.wh_owner_trail(p_material_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform wh.require_owner();
  return (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from wh.trail(p_material_id) t);
end $$;

create or replace function public.wh_owner_create_material(p_category_code text, p_attrs jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform wh.require_owner();
  return wh.create_material(p_category_code, p_attrs);
end $$;

create or replace function public.wh_owner_set_rate(p_material_id uuid, p_rate numeric)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return wh.set_rate(p_material_id, p_rate);
end $$;

create or replace function public.wh_owner_record_opening(p_material_id uuid, p_counted numeric,
                                                          p_effective_at timestamptz)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return wh.record_opening(p_material_id, p_counted, p_effective_at);
end $$;

create or replace function public.wh_owner_supersede_opening(p_material_id uuid, p_counted numeric,
                                                             p_effective_at timestamptz, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return wh.supersede_opening(p_material_id, p_counted, p_effective_at, p_reason);
end $$;

create or replace function public.wh_owner_approve_count(p_count_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return wh.approve_count(p_count_id, p_reason);
end $$;

create or replace function public.wh_owner_resolve_count(p_count_id uuid, p_status text, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return wh.resolve_count(p_count_id, p_status, p_reason);
end $$;

create or replace function public.wh_owner_count_basis_changes(p_count_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform wh.require_owner();
  return wh.count_basis_changes(p_count_id);
end $$;

create or replace function public.wh_owner_correct_line(p_line_id uuid, p_reason text,
                                                        p_new_material_id uuid, p_new_qty numeric, p_void boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return wh.correct_line(p_line_id, p_reason, p_new_material_id, p_new_qty, p_void);
end $$;

create or replace function public.wh_owner_add_line(p_event_id uuid, p_material_id uuid,
                                                    p_qty numeric, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return wh.add_line(p_event_id, p_material_id, p_qty, p_reason);
end $$;

create or replace function public.wh_owner_correct_event(p_event_id uuid, p_reason text, p_fields jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return wh.correct_event(p_event_id, p_reason, p_fields);
end $$;

create or replace function public.wh_owner_review()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform wh.require_owner();
  return jsonb_build_object(
    'possible_same_material', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from wh.possible_same_material x),
    'incomplete_identity',    (select coalesce(jsonb_agg(to_jsonb(y)), '[]'::jsonb) from wh.incomplete_identity y),
    'valuation_coverage',     (select coalesce(jsonb_agg(to_jsonb(z)), '[]'::jsonb) from wh.valuation_coverage z));
end $$;

-- ---------------------------------------------------------------- grants
-- Close the door, then open exactly the intended ones. Staff hold the anon key.
-- The owner holds a signed-in session.
--
-- ORDER MATTERS, and getting it wrong fails silently. These statements run
-- BEFORE ownership moves to the caretaker, because REVOKE and GRANT on an
-- object you do not own raise a WARNING, not an ERROR -- the migration would
-- report success while changing nothing. A function whose ACL was never
-- touched carries PostgreSQL's built-in default for functions: EXECUTE to
-- PUBLIC. So a silent failure here does not leave the API closed; it leaves
-- every warehouse function callable by anyone holding the public key.
--
-- This was not theoretical. It happened on the real project, and
-- t_85_boundary.sql caught it.
do $$
declare r record;
begin
  for r in select format('%I.%I(%s)', n.nspname, p.proname,
                         pg_get_function_identity_arguments(p.oid)) as ident
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'wh\_%'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.ident);
  end loop;
end $$;

grant execute on function
  public.wh_activate(text, text),
  public.wh_ping(text),
  public.wh_catalogue(text),
  public.wh_stock_for_staff(text, uuid),
  public.wh_draft_put(text, uuid, integer, jsonb),
  public.wh_abandon_draft(text, uuid, text),
  public.wh_submit_event(text, jsonb, integer),
  public.wh_report_count(text, uuid, numeric, timestamptz, text),
  public.wh_attach_evidence(text, uuid, text, text, bigint, timestamptz)
to anon;

-- The owner's own phone is a device too, so he can also record. Granting the
-- staff API to `authenticated` would NOT widen anything -- every one of those
-- functions still demands a valid device credential.
grant execute on function
  public.wh_owner_issue_code(uuid, integer, text),
  public.wh_owner_revoke_device(uuid, text),
  public.wh_owner_devices(),
  public.wh_owner_add_person(text, text),
  public.wh_owner_set_person_active(uuid, boolean, text),
  public.wh_owner_people(),
  public.wh_owner_stock(),
  public.wh_owner_trail(uuid),
  public.wh_owner_create_material(text, jsonb),
  public.wh_owner_set_rate(uuid, numeric),
  public.wh_owner_record_opening(uuid, numeric, timestamptz),
  public.wh_owner_supersede_opening(uuid, numeric, timestamptz, text),
  public.wh_owner_approve_count(uuid, text),
  public.wh_owner_resolve_count(uuid, text, text),
  public.wh_owner_count_basis_changes(uuid),
  public.wh_owner_correct_line(uuid, text, uuid, numeric, boolean),
  public.wh_owner_add_line(uuid, uuid, numeric, text),
  public.wh_owner_correct_event(uuid, text, jsonb),
  public.wh_owner_review()
to authenticated;

-- ---------------------------------------------------------------- ownership
-- CREATE on public is lent to the caretaker only long enough to take ownership,
-- then taken straight back. Verified on the real project: ownership survives
-- the revoke, and afterwards the caretaker cannot create anything new here.
-- Ownership moves LAST, after the grants above are already in place; an owner
-- change carries the ACL with it.
do $$
declare r record;
begin
  execute 'grant create on schema public to wh_owner';
  for r in select format('%I.%I(%s)', n.nspname, p.proname,
                         pg_get_function_identity_arguments(p.oid)) as ident
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'wh\_%'
  loop
    execute format('alter function %s owner to wh_owner', r.ident);
  end loop;
  execute 'revoke create on schema public from wh_owner';
end $$;

-- ---------------------------------------------------------------- self-check
-- REVOKE and GRANT warn rather than fail when the running role does not own the
-- object, so this migration must prove its own outcome or abort. Without this,
-- a reordering mistake reports success and leaves every warehouse function
-- callable by anyone holding the public key.
do $$
declare bad text; n int;
begin
  select string_agg(p.proname, ', ' order by p.proname) into bad
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname like 'wh\_%'
     and (has_function_privilege('public', p.oid, 'EXECUTE')
          or (has_function_privilege('anon', p.oid, 'EXECUTE')
              and p.proname like 'wh\_owner\_%'));
  if bad is not null then
    raise exception 'the warehouse API is over-exposed: %', bad;
  end if;

  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname like 'wh\_%'
     and has_function_privilege('anon', p.oid, 'EXECUTE');
  if n <> 9 then
    raise exception '% functions are callable with the public key, expected 9', n;
  end if;
  raise notice 'public API: 9 functions for a phone, the rest for the owner';
end $$;

