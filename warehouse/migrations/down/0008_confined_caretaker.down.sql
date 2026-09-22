-- Undo 0008. Hands the warehouse back to the role running the migration and
-- removes the caretaker. Everything else about wh is untouched.
do $$
declare r record; me text := current_user;
begin
  if not exists (select 1 from pg_roles where rolname='wh_owner') then return; end if;
  execute format('alter schema wh owner to %I', me);
  for r in select 'table' as kind, format('%I.%I', schemaname, tablename) as ident
             from pg_tables where schemaname='wh'
           union all select 'view', format('%I.%I', schemaname, viewname)
             from pg_views where schemaname='wh'
  loop execute format('alter %s %s owner to %I', r.kind, r.ident, me); end loop;
  for r in select format('%I.%I(%s)', n.nspname, p.proname,
                         pg_get_function_identity_arguments(p.oid)) as ident
             from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='wh'
  loop execute format('alter function %s owner to %I', r.ident, me); end loop;
  for r in select format('%I.%I', sequence_schema, sequence_name) as ident
             from information_schema.sequences where sequence_schema='wh'
  loop execute format('alter sequence %s owner to %I', r.ident, me); end loop;
end $$;
-- The caretaker is a cluster-wide role. Dropping it is only correct when it
-- owns nothing anywhere -- in another database it may still be the warehouse's
-- owner. Best effort, and say so plainly when it cannot go.
do $$
begin
  execute 'drop role if exists wh_owner';
  raise notice 'wh_owner dropped';
exception when dependent_objects_still_exist then
  raise notice 'wh_owner still owns objects in another database; role left in place';
end $$;
