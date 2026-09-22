-- =====================================================================
-- HOTFIX 2026-09-22 — public.nkg_door_stock: read-only for client roles
--
-- WHY
--   nkg_door_stock is a view over nkg_stock, owned by `postgres`, created
--   without `security_invoker`. A view like that runs with its OWNER's
--   authority, and `postgres` is the table owner, so row level security on
--   nkg_stock does not apply to anything that goes through the view.
--
--   The view is also auto-updatable (pg_relation_is_updatable = 28 =
--   UPDATE|INSERT|DELETE), and `anon` held INSERT/UPDATE/DELETE on it.
--   Net effect, confirmed on production by query plan only, no row touched:
--
--     as anon:  DELETE FROM nkg_stock            -> refused by the policy
--     as anon:  DELETE FROM nkg_door_stock       -> Delete on nkg_stock
--                                                   Index Scan ...
--                                                   Filter: (category = 'Door')
--                                                   ^ no policy qualifier at all
--
--   So the public key could edit or delete any door row, and the 30-minute
--   nkg_stock_anon_undo window did not bind it.
--
-- WHAT THIS CHANGES
--   Privileges only. The view definition, the data, nkg_stock's policies and
--   every other object are untouched.
--     anon           : SELECT only   (the Door Stock screen reads the view)
--     authenticated  : SELECT only   (the owner reads the same screen; every
--                                     owner write goes to nkg_stock directly)
--     service_role   : unchanged     (server-side key, not a client role)
--
--   Customer assignment keeps working: the app writes through
--   rpc/set_door_customer, which is SECURITY DEFINER and unaffected.
--
-- ROLLBACK: down.sql in this directory restores the exact prior grants.
-- =====================================================================

revoke insert, update, delete, truncate, references, trigger
    on public.nkg_door_stock from anon;
revoke insert, update, delete, truncate, references, trigger
    on public.nkg_door_stock from authenticated;

-- MAINTAIN is PostgreSQL 17+; revoke it only where the server knows it.
do $$
begin
  if current_setting('server_version_num')::int >= 170000 then
    execute 'revoke maintain on public.nkg_door_stock from anon';
    execute 'revoke maintain on public.nkg_door_stock from authenticated';
  end if;
end $$;

-- the read the Door Stock screen needs, stated explicitly rather than assumed
grant select on public.nkg_door_stock to anon, authenticated;

-- ---- assertions: fail the migration rather than leave it half applied ----
do $$
declare bad text;
begin
  select string_agg(r || ':' || p, ', ') into bad from (
    select r, p from unnest(array['anon','authenticated']) r
      cross join unnest(array['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p
     where has_table_privilege(r, 'public.nkg_door_stock', p)
  ) x;
  if bad is not null then
    raise exception 'hotfix incomplete, write privilege remains: %', bad;
  end if;
  if not (has_table_privilege('anon','public.nkg_door_stock','SELECT')
      and has_table_privilege('authenticated','public.nkg_door_stock','SELECT')) then
    raise exception 'hotfix broke the Door Stock read';
  end if;
  raise notice 'nkg_door_stock: client roles are SELECT-only';
end $$;
