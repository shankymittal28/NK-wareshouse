-- 0002  person and device identity, activation, audit
-- Person is who history refers to. Device is a phone that may be revoked on its own.

create table wh.person (
  person_id    uuid primary key default gen_random_uuid(),
  display_name text not null,
  role         text not null check (role in ('owner','head','staff')),
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);
create unique index person_name_uidx on wh.person(lower(display_name)) where active;

create table wh.device (
  device_id     uuid primary key default gen_random_uuid(),
  auth_user_id  uuid not null unique,     -- one auth identity per phone
  person_id     uuid not null references wh.person(person_id),
  label         text not null,
  activated_at  timestamptz not null default now(),
  last_seen_at  timestamptz,
  revoked_at    timestamptz,
  revoked_by_person_id uuid references wh.person(person_id),
  revoked_reason text
);
create index device_person_idx on wh.device(person_id) where revoked_at is null;
comment on table wh.device is
  'Many devices may belong to one person. Revoking a device never alters history, which references person_id.';

-- Activation codes are issued by the owner, stored salted-hashed, single use, expiring.
create table wh.activation_code (
  code_id      uuid primary key default gen_random_uuid(),
  person_id    uuid not null references wh.person(person_id),
  salt         text not null,
  code_hash    text not null,
  issued_at    timestamptz not null default now(),
  issued_by_person_id uuid references wh.person(person_id),
  expires_at   timestamptz not null,
  attempts     smallint not null default 0,
  used_at      timestamptz,
  used_by_device_id uuid references wh.device(device_id),
  void_at      timestamptz
);
create index activation_code_open_idx on wh.activation_code(person_id) where used_at is null and void_at is null;

create or replace function wh.hash_code(p_code text, p_salt text) returns text
language sql immutable strict as $$
  select encode(sha256(convert_to(p_salt || ':' || upper(btrim(p_code)), 'utf8')), 'hex')
$$;

-- ---------------------------------------------------------------- audit
create table wh.audit (
  audit_id      bigserial primary key,
  at            timestamptz not null default now(),
  actor_person_id uuid,
  actor_device_id uuid,
  action        text not null,
  subject_type  text not null,
  subject_id    uuid,
  reason        text,
  detail        jsonb
);
create index audit_subject_idx on wh.audit(subject_type, subject_id, audit_id);

create or replace function wh.log(p_action text, p_subject_type text, p_subject_id uuid,
                                  p_reason text default null, p_detail jsonb default null)
returns void language plpgsql security definer set search_path = wh, public as $$
declare d wh.device%rowtype;
begin
  select * into d from wh.device where auth_user_id = auth.uid() and revoked_at is null;
  insert into wh.audit(actor_person_id, actor_device_id, action, subject_type, subject_id, reason, detail)
  values (d.person_id, d.device_id, p_action, p_subject_type, p_subject_id, p_reason, p_detail);
end $$;

-- ---------------------------------------------------------------- actor resolution
-- Every write resolves the acting person from the credential. A payload can never supply it.
create or replace function wh.current_device() returns wh.device
language sql stable security definer set search_path = wh, public as $$
  select d.* from wh.device d
   where d.auth_user_id = auth.uid()
     and d.revoked_at is null
$$;

create or replace function wh.current_person_id() returns uuid
language sql stable security definer set search_path = wh, public as $$
  select p.person_id
    from wh.device d
    join wh.person p on p.person_id = d.person_id
   where d.auth_user_id = auth.uid()
     and d.revoked_at is null
     and p.active
$$;

create or replace function wh.current_role() returns text
language sql stable security definer set search_path = wh, public as $$
  select p.role
    from wh.device d
    join wh.person p on p.person_id = d.person_id
   where d.auth_user_id = auth.uid()
     and d.revoked_at is null
     and p.active
$$;

create or replace function wh.is_owner() returns boolean
language sql stable security definer set search_path = wh, public as $$
  select coalesce(wh.current_role() = 'owner', false)
$$;

create or replace function wh.require_actor() returns wh.device
language plpgsql stable security definer set search_path = wh, public as $$
declare d wh.device%rowtype;
begin
  select * into d from wh.device
   where auth_user_id = auth.uid() and revoked_at is null;
  if not found then
    raise exception 'this device is not activated for the warehouse' using errcode='42501';
  end if;
  if not exists (select 1 from wh.person where person_id = d.person_id and active) then
    raise exception 'this person is no longer active' using errcode='42501';
  end if;
  return d;
end $$;

create or replace function wh.require_owner() returns wh.device
language plpgsql stable security definer set search_path = wh, public as $$
declare d wh.device%rowtype;
begin
  d := wh.require_actor();
  if not wh.is_owner() then
    raise exception 'only the owner may do this' using errcode='42501';
  end if;
  return d;
end $$;

-- ---------------------------------------------------------------- activation
create or replace function wh.issue_activation_code(p_person_id uuid, p_hours int default 24)
returns text language plpgsql security definer set search_path = wh, public as $$
declare v_code text; v_salt text;
begin
  perform wh.require_owner();
  -- 8 characters, no 0/O/1/I. Randomness comes from gen_random_uuid(), a builtin,
  -- so this needs no extension. 256 is a whole multiple of 32, so the mapping is unbiased.
  select string_agg(substr('23456789ABCDEFGHJKLMNPQRSTUVWXYZ', 1 + (get_byte(b, i) % 32), 1), '')
    into v_code
    from (select uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid()) as b) r,
         generate_series(0, 7) as i;
  v_salt := encode(uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid()), 'hex');
  update wh.activation_code set void_at = now()
   where person_id = p_person_id and used_at is null and void_at is null;
  insert into wh.activation_code(person_id, salt, code_hash, expires_at, issued_by_person_id)
  values (p_person_id, v_salt, wh.hash_code(v_code, v_salt),
          now() + make_interval(hours => p_hours), wh.current_person_id());
  perform wh.log('activation_code.issue', 'person', p_person_id);
  return v_code;
end $$;

create or replace function wh.activate_device(p_code text, p_label text)
returns jsonb language plpgsql security definer set search_path = wh, public as $$
declare c wh.activation_code%rowtype; v_uid uuid; v_device_id uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'sign in first' using errcode='42501';
  end if;
  if exists (select 1 from wh.device where auth_user_id = v_uid and revoked_at is null) then
    raise exception 'this device is already activated' using errcode='23505';
  end if;

  select * into c from wh.activation_code
   where code_hash = wh.hash_code(p_code, salt)
     and used_at is null and void_at is null
   limit 1;

  if not found then
    update wh.activation_code set attempts = attempts + 1
     where used_at is null and void_at is null and expires_at > now();
    update wh.activation_code set void_at = now()
     where used_at is null and void_at is null and attempts >= 5;
    raise exception 'that code is not valid' using errcode='42501';
  end if;
  if c.expires_at <= now() then
    raise exception 'that code has expired' using errcode='42501';
  end if;

  insert into wh.device(auth_user_id, person_id, label)
  values (v_uid, c.person_id, p_label)
  returning device_id into v_device_id;

  update wh.activation_code
     set used_at = now(), used_by_device_id = v_device_id
   where code_id = c.code_id;

  insert into wh.audit(actor_person_id, actor_device_id, action, subject_type, subject_id, detail)
  values (c.person_id, v_device_id, 'device.activate', 'device', v_device_id,
          jsonb_build_object('label', p_label));

  return jsonb_build_object('device_id', v_device_id, 'person_id', c.person_id,
                            'person', (select display_name from wh.person where person_id = c.person_id),
                            'role', (select role from wh.person where person_id = c.person_id));
end $$;

create or replace function wh.revoke_device(p_device_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = wh, public as $$
begin
  perform wh.require_owner();
  update wh.device
     set revoked_at = now(), revoked_by_person_id = wh.current_person_id(), revoked_reason = p_reason
   where device_id = p_device_id and revoked_at is null;
  if not found then
    raise exception 'no such active device' using errcode='23503';
  end if;
  perform wh.log('device.revoke', 'device', p_device_id, p_reason);
end $$;

create or replace function wh.touch_device(p_device_id uuid) returns void
language sql security definer set search_path = wh, public as $$
  update wh.device set last_seen_at = now()
   where device_id = p_device_id
     and (last_seen_at is null or last_seen_at < now() - interval '10 minutes')
$$;
