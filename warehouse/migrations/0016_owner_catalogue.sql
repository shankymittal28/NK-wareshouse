-- 0016  wh_owner_catalogue: the read-only owner preview of the imported warehouse
--
-- The catalogue preview needs each material's legacy expectation, its rate, its
-- opening status and an indicative value together. wh_owner_stock (material_value)
-- is empty by design until a real opening count exists, so this is a separate
-- read-only owner function. It writes nothing, and is owned by the confined
-- caretaker like the rest of the API.
--
-- Honesty is enforced in the shape of the data, not just the UI:
--   * recorded_qty stays whatever material_stock says -- NULL until a real
--     opening count exists, so "current stock" cannot be fabricated here;
--   * legacy_expected_qty is the old system's net, labelled as such by the caller;
--   * indicative_value is computed ONLY when there is a positive legacy
--     expectation AND a rate -- never a bare number that could pass for truth.
create or replace function public.wh_owner_catalogue()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform wh.require_owner();
  return jsonb_build_object(
    'materials', (
      select coalesce(jsonb_agg(jsonb_build_object(
          'material_id',         ms.material_id,
          'category_code',       ms.category_code,
          'name',                ms.material_name,
          'unit_code',           ms.unit_code,
          'decimals',            ms.decimals,
          'origin',              ms.origin,
          'identity_incomplete', m.identity_incomplete,
          'legacy_expected_qty', ms.legacy_expected_qty,
          'has_opening',         ms.has_opening,
          'recorded_qty',        ms.recorded_qty,   -- NULL until a real count
          'rate',                r.rate,
          'indicative_value',
            case when ms.legacy_expected_qty is not null and ms.legacy_expected_qty > 0
                      and r.rate is not null
                 then round(ms.legacy_expected_qty * r.rate, 2) end)
          order by ms.category_code, ms.material_name), '[]'::jsonb)
        from wh.material_stock ms
        join wh.material m on m.material_id = ms.material_id
        left join wh.rate r on r.material_id = ms.material_id),
    'coverage', (select coalesce(to_jsonb(z), '{}'::jsonb) from wh.valuation_coverage z),
    'totals', jsonb_build_object(
        'materials',    (select count(*) from wh.material),
        'rated',        (select count(*) from wh.rate),
        'with_opening', (select count(*) from wh.opening where status = 'active'),
        'categories',   (select count(*) from wh.category))
  );
end $$;

-- grant before the ownership handover (a grant on an object you do not own only warns)
revoke all on function public.wh_owner_catalogue() from public, anon, authenticated, service_role;
grant execute on function public.wh_owner_catalogue() to authenticated;
do $$
begin
  execute 'grant create on schema public to wh_owner';
  execute 'alter function public.wh_owner_catalogue() owner to wh_owner';
  execute 'revoke create on schema public from wh_owner';
end $$;

do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='public' and p.proname like 'wh\_%' and has_function_privilege('anon',p.oid,'EXECUTE');
  if n <> 9 then raise exception 'anon-callable count changed to %, expected 9', n; end if;
  if has_function_privilege('anon','public.wh_owner_catalogue()','EXECUTE')
     or has_function_privilege('public','public.wh_owner_catalogue()','EXECUTE') then
    raise exception 'wh_owner_catalogue must not be anon/PUBLIC callable';
  end if;
end $$;
