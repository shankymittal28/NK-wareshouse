-- Rollback for HOTFIX 2026-09-22 — restores the grants exactly as captured
-- from production before the change:
--   {postgres=arwdDxtm/postgres, anon=arwdDxtm/postgres,
--    authenticated=arwdDxtm/postgres, service_role=arwdDxtm/postgres}
-- (a=INSERT r=SELECT w=UPDATE d=DELETE D=TRUNCATE x=REFERENCES t=TRIGGER m=MAINTAIN)
--
-- This re-opens the escalation described in up.sql. Run it only to restore
-- service if the Door Stock screen proves to depend on a write path that
-- was not found in the application code.

grant select, insert, update, delete, truncate, references, trigger
   on public.nkg_door_stock to anon, authenticated;

do $$
begin
  if current_setting('server_version_num')::int >= 170000 then
    execute 'grant maintain on public.nkg_door_stock to anon, authenticated';
  end if;
end $$;
