\set QUIET on
-- =====================================================================
-- THE BOUNDARY. This file is the security contract of the warehouse,
-- written so a machine can check it. It depends on nothing but the
-- catalogue, so the SAME file runs in CI and against the real project:
--     psql "$WH_DB_URL" -f warehouse/test/t_85_boundary.sql
-- Any line that reports NOT OK fails the build.
--
-- The contract in one sentence: the warehouse's caretaker owns nothing
-- outside wh, and exactly nine functions are callable with the public key.
-- =====================================================================
do $b$
declare
  n int; bad text; v boolean;
  fails int := 0;
  -- the deliberate API. Changing either list is a security decision, and
  -- must be made here, in the open, not by a stray grant somewhere.
  anon_api text[] := array[
    'wh_activate','wh_ping','wh_catalogue','wh_stock_for_staff','wh_draft_put',
    'wh_abandon_draft','wh_submit_event','wh_report_count','wh_attach_evidence'];
  owner_api text[] := array[
    'wh_owner_issue_code','wh_owner_revoke_device','wh_owner_devices','wh_owner_people',
    'wh_owner_add_person','wh_owner_set_person_active',
    'wh_owner_stock','wh_owner_trail','wh_owner_create_material','wh_owner_set_rate',
    'wh_owner_record_opening','wh_owner_supersede_opening','wh_owner_approve_count',
    'wh_owner_resolve_count','wh_owner_count_basis_changes','wh_owner_correct_line',
    'wh_owner_add_line','wh_owner_correct_event','wh_owner_review'];

  procedure_check text;
begin
  -- helper as a closure would be nicer; plpgsql has none, so: a local macro.
  -- ok(cond, label)
  <<checks>>
  declare
  begin
    -- ============ 1. the caretaker ============
    select count(*) into n from pg_roles where rolname = 'wh_owner';
    if n = 1 then raise notice 'ok  1.1 the confined caretaker role exists';
    else raise notice 'NOT OK  1.1 the confined caretaker role exists'; fails := fails + 1; end if;

    select not (rolsuper or rolcreatedb or rolcreaterole or rolbypassrls
                or rolreplication or rolcanlogin or rolinherit)
      into v from pg_roles where rolname = 'wh_owner';
    if coalesce(v,false) then raise notice 'ok  1.2 caretaker cannot log in, bypass RLS, create roles or inherit anything';
    else raise notice 'NOT OK  1.2 caretaker has an attribute it must not have'; fails := fails + 1; end if;

    select count(*) into n from pg_auth_members m join pg_roles r on r.oid = m.member
     where r.rolname = 'wh_owner';
    if n = 0 then raise notice 'ok  1.3 caretaker is a member of no other role, so it borrows nothing';
    else raise notice 'NOT OK  1.3 caretaker belongs to % other role(s)', n; fails := fails + 1; end if;

    -- wh_import is the one-time legacy mapping, kept as evidence. It is the
    -- caretaker's own schema, reachable by no client role. Nothing else is
    -- allowed, and the import's temporary reach into the old NK tables is
    -- taken away by the same migration that used it.
    select string_agg(distinct table_schema || '.' || table_name, ', ') into bad
      from information_schema.table_privileges
     where grantee = 'wh_owner' and table_schema not in ('wh','wh_import');
    if bad is null then raise notice 'ok  1.4 caretaker holds no table privilege outside its own schemas';
    else raise notice 'NOT OK  1.4 caretaker can reach: %', left(bad, 120); fails := fails + 1; end if;

    -- only meaningful where the legacy NK tables exist, i.e. the shared project
    if to_regclass('public.nkg_stock') is null then
      raise notice 'ok  1.4b (no legacy NK tables in this database)';
    elsif not has_table_privilege('wh_owner','public.nkg_stock','SELECT') then
      raise notice 'ok  1.4b and specifically cannot read the legacy NK tables';
    else raise notice 'NOT OK  1.4b caretaker can still read public.nkg_stock'; fails := fails + 1; end if;

    if not has_schema_privilege('wh_owner','public','CREATE')
    then raise notice 'ok  1.5 caretaker cannot create anything in public';
    else raise notice 'NOT OK  1.5 caretaker can create objects in public'; fails := fails + 1; end if;

    -- ============ 2. ownership ============
    if (select pg_get_userbyid(nspowner) from pg_namespace where nspname='wh') = 'wh_owner'
    then raise notice 'ok  2.1 the caretaker owns schema wh';
    else raise notice 'NOT OK  2.1 schema wh is owned by someone else'; fails := fails + 1; end if;

    select string_agg(c.relname, ', ') into bad
      from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
     where ns.nspname = 'wh' and c.relkind in ('r','v','S')
       and pg_get_userbyid(c.relowner) <> 'wh_owner';
    if bad is null then raise notice 'ok  2.2 every table, view and sequence in wh is owned by the caretaker';
    else raise notice 'NOT OK  2.2 not owned by the caretaker: %', left(bad,120); fails := fails + 1; end if;

    select string_agg(p.proname, ', ') into bad
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'wh' and pg_get_userbyid(p.proowner) <> 'wh_owner';
    if bad is null then raise notice 'ok  2.3 every function in wh is owned by the caretaker';
    else raise notice 'NOT OK  2.3 not owned by the caretaker: %', left(bad,120); fails := fails + 1; end if;

    select string_agg(p.proname, ', ') into bad
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and p.proname like 'wh\_%'
       and pg_get_userbyid(p.proowner) <> 'wh_owner';
    if bad is null then raise notice 'ok  2.4 every warehouse wrapper in public is owned by the caretaker';
    else raise notice 'NOT OK  2.4 wrapper owned by an overpowered role: %', left(bad,120); fails := fails + 1; end if;

    -- ============ 3. nothing in wh is reachable by a client ============
    if not has_schema_privilege('anon','wh','USAGE') and not has_schema_privilege('authenticated','wh','USAGE')
    then raise notice 'ok  3.1 no client role may even enter schema wh';
    else raise notice 'NOT OK  3.1 a client role has USAGE on wh'; fails := fails + 1; end if;

    select string_agg(distinct table_name || ' to ' || grantee, ', ') into bad
      from information_schema.table_privileges
     where table_schema = 'wh' and grantee in ('anon','authenticated','PUBLIC');
    if bad is null then raise notice 'ok  3.2 no client role holds any privilege on any wh table or view';
    else raise notice 'NOT OK  3.2 granted: %', left(bad,120); fails := fails + 1; end if;

    select string_agg(p.proname, ', ') into bad
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'wh'
       and (has_function_privilege('anon', p.oid, 'EXECUTE')
         or has_function_privilege('authenticated', p.oid, 'EXECUTE'));
    if bad is null then raise notice 'ok  3.3 no internal warehouse function is callable by a client role';
    else raise notice 'NOT OK  3.3 callable: %', left(bad,120); fails := fails + 1; end if;

    select string_agg(tablename, ', ') into bad from pg_tables
     where schemaname = 'wh' and not rowsecurity;
    if bad is null then raise notice 'ok  3.4 row level security is enabled on every wh table';
    else raise notice 'NOT OK  3.4 RLS off on: %', left(bad,120); fails := fails + 1; end if;

    select string_agg(c.relname, ', ') into bad
      from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
     where ns.nspname = 'wh' and c.relkind = 'v'
       and not coalesce((select option_value = 'true' from pg_options_to_table(c.reloptions)
                          where option_name = 'security_invoker'), false);
    if bad is null then raise notice 'ok  3.5 every wh view runs as its caller (the nkg_door_stock defect cannot recur here)';
    else raise notice 'NOT OK  3.5 definer view: %', left(bad,120); fails := fails + 1; end if;

    -- ============ 4. the exposed surface, by name ============
    select string_agg(p.proname, ', ' order by p.proname) into bad
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE')
       and p.proname like 'wh\_%' and not (p.proname = any(anon_api));
    if bad is null then raise notice 'ok  4.1 the public key can call nothing beyond the nine agreed functions';
    else raise notice 'NOT OK  4.1 unexpected anon-callable: %', left(bad,160); fails := fails + 1; end if;

    select string_agg(x, ', ') into bad from unnest(anon_api) x
     where not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                        where ns.nspname='public' and p.proname = x
                          and has_function_privilege('anon', p.oid, 'EXECUTE'));
    if bad is null then raise notice 'ok  4.2 and it can call all nine of them';
    else raise notice 'NOT OK  4.2 missing from the anon API: %', left(bad,160); fails := fails + 1; end if;

    select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname='public' and p.proname like 'wh\_%'
       and has_function_privilege('anon', p.oid, 'EXECUTE');
    if n = array_length(anon_api,1)
    then raise notice 'ok  4.3 exactly % functions are anon-callable', n;
    else raise notice 'NOT OK  4.3 % anon-callable, expected %', n, array_length(anon_api,1); fails := fails + 1; end if;

    select string_agg(p.proname, ', ' order by p.proname) into bad
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'EXECUTE')
       and p.proname like 'wh\_%'
       and not (p.proname = any(owner_api)) and not (p.proname = any(anon_api));
    if bad is null then raise notice 'ok  4.4 a signed-in session can call nothing beyond the agreed owner API';
    else raise notice 'NOT OK  4.4 unexpected authenticated-callable: %', left(bad,160); fails := fails + 1; end if;

    -- PUBLIC must never hold EXECUTE: this project grants it by default
    select string_agg(p.proname, ', ') into bad
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname='public' and p.proname like 'wh\_%'
       and has_function_privilege('public', p.oid, 'EXECUTE')
       and not (p.proname = any(anon_api));
    if bad is null then raise notice 'ok  4.5 PUBLIC holds EXECUTE on nothing it was not meant to';
    else raise notice 'NOT OK  4.5 PUBLIC can call: %', left(bad,160); fails := fails + 1; end if;

    -- ============ 5. how the exposed functions are written ============
    select string_agg(p.proname, ', ') into bad
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and p.proname like 'wh\_%'
       and not coalesce(p.proconfig,'{}') @> array['search_path=""'];
    if bad is null then raise notice 'ok  5.1 every warehouse wrapper pins an empty search_path';
    else raise notice 'NOT OK  5.1 unpinned: %', left(bad,160); fails := fails + 1; end if;

    select string_agg(p.proname, ', ') into bad
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'wh'
       and not coalesce(p.proconfig,'{}') @> array['search_path=""'];
    if bad is null then raise notice 'ok  5.2 and so does every function inside wh';
    else raise notice 'NOT OK  5.2 unpinned in wh: %', left(bad,160); fails := fails + 1; end if;

    select string_agg(p.proname, ', ') into bad
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and p.proname like 'wh\_%'
       and p.prosrc ~* '(execute\s+format|execute\s+''|execute\s+.*\|\|)';
    if bad is null then raise notice 'ok  5.3 no exposed warehouse function builds SQL out of client text';
    else raise notice 'NOT OK  5.3 dynamic SQL in: %', left(bad,160); fails := fails + 1; end if;

    select string_agg(p.proname, ', ') into bad
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and p.proname like 'wh\_%' and not p.prosecdef;
    if bad is null then raise notice 'ok  5.4 every wrapper runs as the caretaker, never as its caller';
    else raise notice 'NOT OK  5.4 not security definer: %', left(bad,160); fails := fails + 1; end if;

    -- every staff function must take the credential first and resolve it itself
    select string_agg(x, ', ') into bad from unnest(anon_api) x
     where x <> 'wh_activate'
       and not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                        where ns.nspname='public' and p.proname = x
                          and p.prosrc like '%wh.assume_device(p_token)%');
    if bad is null then raise notice 'ok  5.5 every staff function resolves the device from the credential itself';
    else raise notice 'NOT OK  5.5 does not authenticate: %', left(bad,160); fails := fails + 1; end if;

    -- ============ 6. secrets ============
    select string_agg(c.relname || '.' || a.attname, ', ') into bad
      from pg_attribute a
      join pg_class c on c.oid = a.attrelid
      join pg_namespace ns on ns.oid = c.relnamespace
     where ns.nspname='wh' and c.relkind='r' and a.attnum > 0 and not a.attisdropped
       and a.attname in ('token','code','secret','password','plaintext');
    if bad is null then raise notice 'ok  6.1 no warehouse table has a column that could hold a credential in the clear';
    else raise notice 'NOT OK  6.1 suspicious column: %', left(bad,160); fails := fails + 1; end if;

    select string_agg(p.proname, ', ') into bad
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname='public' and p.proname like 'wh\_%'
       and p.prosrc ~* '(token_hash|wh\.secret|pepper\(\))'
       and p.proname <> 'wh_activate';
    if bad is null then raise notice 'ok  6.2 no exposed function touches a fingerprint or the pepper';
    else raise notice 'NOT OK  6.2 touches credential material: %', left(bad,160); fails := fails + 1; end if;

    if not has_table_privilege('anon','wh.secret','SELECT')
       and not has_table_privilege('authenticated','wh.secret','SELECT')
    then raise notice 'ok  6.3 the pepper is unreadable by every client role';
    else raise notice 'NOT OK  6.3 the pepper is readable'; fails := fails + 1; end if;
  end checks;

  if fails > 0 then
    raise exception 'BOUNDARY VIOLATED: % assertion(s) failed', fails;
  end if;
  raise notice 'ok  boundary intact';
end $b$;
