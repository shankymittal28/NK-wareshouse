-- 0007  least privilege
--
-- No client role holds ANY privilege on ANY warehouse table, view or function.
-- Not select, not execute, not schema usage. Staff and owner alike reach the
-- warehouse only through the wrappers in 0009, which are owned by the confined
-- caretaker and are the entire public surface of this system.
--
-- Row level security is enabled everywhere and policies are written anyway.
-- With no grants they are unreachable and therefore redundant -- which is the
-- point: if a grant is ever added by accident, the policies still hold the line.

revoke all on schema wh from public, anon, authenticated;
grant usage on schema wh to service_role;   -- backups and support tooling only

do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'wh' loop
    execute format('revoke all on wh.%I from public, anon, authenticated', t);
    execute format('alter table wh.%I enable row level security', t);
  end loop;
end $$;

-- Defence in depth. Written against `authenticated` because that is the only
-- client role a grant could plausibly be given to by mistake; staff never hold it.
create policy p_read on wh.category          for select to authenticated using (wh.is_bound());
create policy p_read on wh.category_attribute for select to authenticated using (wh.is_bound());
create policy p_read on wh.attribute_value   for select to authenticated using (wh.is_bound());
create policy p_read on wh.material          for select to authenticated using (wh.is_bound());
create policy p_read on wh.person            for select to authenticated using (wh.is_bound());
create policy p_read on wh.stock_event       for select to authenticated using (wh.is_bound());
create policy p_read on wh.event_line        for select to authenticated using (wh.is_bound());
create policy p_read on wh.line_correction   for select to authenticated using (wh.is_bound());
create policy p_read on wh.event_correction  for select to authenticated using (wh.is_bound());
create policy p_read on wh.opening           for select to authenticated using (wh.is_bound());
create policy p_read on wh.count_report      for select to authenticated using (wh.is_bound());
create policy p_read on wh.evidence          for select to authenticated using (wh.is_bound());
create policy p_read on wh.legacy_line       for select to authenticated using (wh.is_bound());
create policy p_read on wh.legacy_photo      for select to authenticated using (wh.is_bound());
create policy p_read on wh.setting           for select to authenticated using (wh.is_bound());

-- money: owner only
create policy p_read on wh.rate          for select to authenticated using (wh.is_owner());
create policy p_read on wh.rate_history  for select to authenticated using (wh.is_owner());

-- the owner sees the fleet; a device sees itself
create policy p_read on wh.device for select to authenticated
  using (wh.is_owner() or device_id = wh.current_device_id());

-- a draft is the recorder's own work in progress; the owner sees server-known drafts
create policy p_read on wh.draft for select to authenticated
  using (wh.is_owner() or person_id = wh.current_person_id());

-- Credential material is never readable by any client, owner included. The
-- pepper, the code fingerprints and the throttle have no read policy at all.
create policy p_read on wh.activation_code for select to authenticated using (false);
create policy p_read on wh.secret          for select to authenticated using (false);
create policy p_read on wh.auth_throttle   for select to authenticated using (false);
create policy p_read on wh.audit           for select to authenticated using (wh.is_owner());

-- Views must run as the caller, or row level security would be bypassed --
-- the same defect found in public.nkg_door_stock.
do $$
declare v text;
begin
  for v in select viewname from pg_views where schemaname = 'wh' loop
    execute format('alter view wh.%I set (security_invoker = true)', v);
    execute format('revoke all on wh.%I from public, anon, authenticated', v);
  end loop;
end $$;

-- Nothing in wh is callable by a client role. 0009 exposes the API.
revoke all on all functions in schema wh from public, anon, authenticated;
revoke all on all routines  in schema wh from public, anon, authenticated;
