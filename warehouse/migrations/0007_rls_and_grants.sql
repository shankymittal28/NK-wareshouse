-- 0007  least privilege
-- No client role may write to any table. Every write goes through a function in 0006.
-- Staff see the quantities their work needs. Money belongs to the owner.

revoke all on schema wh from public;
grant usage on schema wh to authenticated, service_role;

do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'wh' loop
    execute format('revoke all on wh.%I from public, anon, authenticated', t);
    execute format('alter table wh.%I enable row level security', t);
    execute format('grant select on wh.%I to authenticated', t);
  end loop;
end $$;

-- Reading requires an activated device bound to an active person.
create or replace function wh.is_bound() returns boolean
language sql stable security definer set search_path = wh, public as $$
  select wh.current_person_id() is not null
$$;

-- catalogue and history: any activated warehouse person
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

-- own devices; the owner sees the fleet
create policy p_read on wh.device for select to authenticated
  using (wh.is_owner() or auth_user_id = auth.uid());

-- a draft is the recorder's own work in progress; the owner sees server-known drafts
create policy p_read on wh.draft for select to authenticated
  using (wh.is_owner() or person_id = wh.current_person_id());

-- activation codes and the audit log are never readable by a client
create policy p_read on wh.activation_code for select to authenticated using (false);
create policy p_read on wh.audit for select to authenticated using (wh.is_owner());

-- Views must run as the caller, or row-level security would be bypassed.
do $$
declare v text;
begin
  for v in select viewname from pg_views where schemaname = 'wh' loop
    execute format('alter view wh.%I set (security_invoker = true)', v);
    execute format('revoke all on wh.%I from public, anon, authenticated', v);
    execute format('grant select on wh.%I to authenticated', v);
  end loop;
end $$;

-- Functions a client may call. Everything else stays internal.
revoke all on all functions in schema wh from public, anon, authenticated;
grant execute on function
  wh.activate_device(text, text),
  wh.create_material(text, jsonb),
  wh.draft_put(uuid, int, jsonb),
  wh.abandon_draft(uuid, text),
  wh.submit_event(jsonb, int),
  wh.correct_line(uuid, text, uuid, numeric, boolean),
  wh.add_line(uuid, uuid, numeric, text),
  wh.correct_event(uuid, text, jsonb),
  wh.record_opening(uuid, numeric, timestamptz),
  wh.supersede_opening(uuid, numeric, timestamptz, text),
  wh.report_count(uuid, numeric, timestamptz, text),
  wh.approve_count(uuid, text),
  wh.resolve_count(uuid, text, text),
  wh.set_rate(uuid, numeric),
  wh.attach_evidence(uuid, text, text, bigint, timestamptz),
  wh.issue_activation_code(uuid, int),
  wh.revoke_device(uuid, text),
  wh.stock_as_of(uuid, timestamptz, timestamptz),
  wh.line_effective_as_of(timestamptz),
  wh.event_effective_as_of(timestamptz),
  wh.line_sign(text),
  wh.norm(text),
  wh.trail(uuid),
  wh.material_name(uuid),
  wh.count_basis_changes(uuid),
  wh.is_owner(),
  wh.is_bound(),
  wh.current_person_id(),
  wh.current_role()
to authenticated;
