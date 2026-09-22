-- Undo 0009. Removes the entire public surface of the warehouse. After this
-- no phone and no browser can reach wh at all; the data is untouched.
do $$
declare r record;
begin
  for r in select format('%I.%I(%s)', n.nspname, p.proname,
                         pg_get_function_identity_arguments(p.oid)) as ident
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'wh\_%'
  loop
    execute format('drop function if exists %s', r.ident);
  end loop;
end $$;
