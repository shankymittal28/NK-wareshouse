-- Undo 0007: remove policies and grants. Tables and data are untouched.
do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname='wh' loop
    execute format('drop policy if exists p_read on wh.%I', t);
    execute format('alter table wh.%I disable row level security', t);
  end loop;
end $$;
revoke all on all tables in schema wh from authenticated;
revoke all on all functions in schema wh from authenticated;
drop function if exists wh.is_bound();
