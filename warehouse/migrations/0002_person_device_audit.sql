-- 0002  person, device credential, activation, owner identity, audit
--
-- Person is who history refers to. Device is one phone, revocable on its own.
-- Credential is the secret that phone holds. The three are kept apart so that
-- revoking a phone never rewrites what a person did.
--
-- Warehouse staff are NOT Supabase users. They never hold the `authenticated`
-- role. Their phones present a warehouse-specific 256-bit secret, which the
-- warehouse resolves: credential -> device -> person -> role.
--
-- The owner is different: he keeps the Supabase identity he already uses for
-- NK. There is no second owner auth realm.

create table wh.person (
  person_id    uuid primary key default gen_random_uuid(),
  display_name text not null,
  role         text not null check (role in ('owner','head','staff')),
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);
create unique index person_name_uidx on wh.person(lower(display_name)) where active;

-- One row per phone. `token_hash` is the fingerprint of a 256-bit secret that
-- exists in plain form only on that phone. Nothing here can reconstruct it.
create table wh.device (
  device_id     uuid primary key default gen_random_uuid(),
  person_id     uuid not null references wh.person(person_id),
  label         text not null,
  token_hash    bytea unique,                       -- sha256(pepper || token)
  token_issued_at timestamptz,
  activated_at  timestamptz not null default now(),
  last_seen_at  timestamptz,
  revoked_at    timestamptz,
  revoked_by_person_id uuid references wh.person(person_id),
  revoked_reason text,
  constraint device_live_has_token check (revoked_at is not null or token_hash is not null)
);
create index device_person_idx on wh.device(person_id) where revoked_at is null;
comment on table wh.device is
  'Many devices may belong to one person. Revoking a device never alters history, which references person_id.';
comment on column wh.device.token_hash is
  'Fingerprint only. The device secret is 256 bits of randomness, returned to the phone once and never stored.';

-- Activation codes are issued by the owner: short, typed by hand, and therefore
-- the one credential in this system that is brute-forceable in principle. They
-- are defended by being short-lived, single use, attempt-capped and throttled.
create table wh.activation_code (
  code_id      uuid primary key default gen_random_uuid(),
  person_id    uuid not null references wh.person(person_id),
  code_hash    bytea not null unique,               -- sha256(pepper || code)
  mode         text not null default 'add' check (mode in ('add','replace')),
  issued_at    timestamptz not null default now(),
  issued_by_person_id uuid references wh.person(person_id),
  expires_at   timestamptz not null,
  attempts     smallint not null default 0,
  used_at      timestamptz,
  used_by_device_id uuid references wh.device(device_id),
  void_at      timestamptz
);
create index activation_code_open_idx on wh.activation_code(person_id) where used_at is null and void_at is null;
comment on column wh.activation_code.mode is
  '''add'' enrols another phone for this person; ''replace'' supersedes their live phones.';

-- Durable brute-force throttle. It must be a table, not a counter in memory,
-- because there is no application server between the phone and the database.
create table wh.auth_throttle (
  k            text primary key,
  window_start timestamptz not null default now(),
  n            integer not null default 0
);

-- ---------------------------------------------------------------- secrets
-- The pepper is a per-installation value kept in a table no client role can
-- reach. Be honest about what it buys: for the 256-bit device token it adds
-- nothing that matters -- the entropy alone puts the token beyond guessing,
-- and anyone who can read wh.device can read wh.secret too. It is here for the
-- short activation code, where it means a stray leak of one table is not
-- immediately a crackable code, and it costs nothing.
create table wh.secret (
  k     text primary key,
  v     bytea not null,
  set_at timestamptz not null default now()
);

create or replace function wh.pepper() returns bytea
language sql stable security definer set search_path = '' as $$
  select v from wh.secret where k = 'pepper'
$$;

-- 256 bits of randomness from the server's own generator, base64url so it is
-- safe in a JSON body. No extension required.
create or replace function wh.mint_secret() returns text
language sql volatile set search_path = '' as $$
  select translate(
           pg_catalog.encode(
             pg_catalog.uuid_send(pg_catalog.gen_random_uuid()) ||
             pg_catalog.uuid_send(pg_catalog.gen_random_uuid()), 'base64'),
           '+/=', '-_')
$$;

-- A 10-symbol code over a 32-symbol alphabet with 0/O and 1/I removed: 50 bits.
-- 256 is a whole multiple of 32, so the mapping draws without bias.
create or replace function wh.mint_code() returns text
language plpgsql volatile set search_path = '' as $$
declare b bytea := pg_catalog.uuid_send(pg_catalog.gen_random_uuid())
                || pg_catalog.uuid_send(pg_catalog.gen_random_uuid());
        a text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'; s text := ''; i int;
begin
  for i in 0..9 loop
    s := s || pg_catalog.substr(a, 1 + (pg_catalog.get_byte(b, i) % 32), 1);
  end loop;
  return s;
end $$;

create or replace function wh.fingerprint(p_secret text) returns bytea
language sql stable security definer set search_path = '' as $$
  select pg_catalog.sha256(wh.pepper() || pg_catalog.convert_to(pg_catalog.upper(pg_catalog.btrim(coalesce(p_secret,''))), 'utf8'))
$$;

-- The device token is case-sensitive; the typed code is not. Two functions,
-- so neither is ever applied to the wrong kind of secret.
create or replace function wh.fingerprint_token(p_token text) returns bytea
language sql stable security definer set search_path = '' as $$
  select pg_catalog.sha256(wh.pepper() || pg_catalog.convert_to(coalesce(p_token,''), 'utf8'))
$$;

-- ---------------------------------------------------------------- throttle
create or replace function wh.throttle_ok(p_key text, p_limit int, p_window interval)
returns boolean language plpgsql security definer set search_path = '' as $$
declare r wh.auth_throttle%rowtype;
begin
  insert into wh.auth_throttle(k) values (p_key) on conflict (k) do nothing;
  select * into r from wh.auth_throttle where k = p_key for update;
  if r.window_start < pg_catalog.now() - p_window then
    update wh.auth_throttle set window_start = pg_catalog.now(), n = 1 where k = p_key;
    return true;
  end if;
  if r.n >= p_limit then return false; end if;
  update wh.auth_throttle set n = n + 1 where k = p_key;
  return true;
end $$;

-- ---------------------------------------------------------------- audit
create table wh.audit (
  audit_id      bigserial primary key,
  at            timestamptz not null default clock_timestamp(),
  actor_person_id uuid,
  actor_device_id uuid,
  action        text not null,
  subject_type  text not null,
  subject_id    uuid,
  reason        text,
  detail        jsonb
);
create index audit_subject_idx on wh.audit(subject_type, subject_id, audit_id);
comment on table wh.audit is
  'Records the device, never the credential. No secret is ever written here.';

create or replace function wh.log(p_action text, p_subject_type text, p_subject_id uuid,
                                  p_reason text default null, p_detail jsonb default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into wh.audit(actor_person_id, actor_device_id, action, subject_type, subject_id, reason, detail)
  values (wh.current_person_id(), wh.current_device_id(),
          p_action, p_subject_type, p_subject_id, p_reason, p_detail);
end $$;

-- ---------------------------------------------------------------- actor resolution
-- The acting person is established ONCE per request, by wh.assume_device()
-- from the credential, or by the owner's signed Supabase claim. It is held in
-- transaction-local settings, so it cannot outlive the request and cannot be
-- carried between pooled connections. A payload can never supply it.

create or replace function wh.assume_device(p_token text) returns wh.device
language plpgsql security definer set search_path = '' as $$
declare d wh.device%rowtype;
begin
  select dv.* into d from wh.device dv
    join wh.person p on p.person_id = dv.person_id
   where dv.token_hash = wh.fingerprint_token(p_token)
     and dv.revoked_at is null
     and p.active;
  if not found then
    raise exception 'unauthorised' using errcode='42501';
  end if;
  perform pg_catalog.set_config('wh.person_id', d.person_id::text, true);
  perform pg_catalog.set_config('wh.device_id', d.device_id::text, true);
  -- touched at most every ten minutes, so an idle phone does not write on every call
  update wh.device set last_seen_at = pg_catalog.now()
   where device_id = d.device_id
     and (last_seen_at is null or last_seen_at < pg_catalog.now() - interval '10 minutes');
  return d;
end $$;

-- The owner's identity comes from the Supabase JWT he already signs in with for
-- NK -- the same claim public.is_owner() reads. The email is configuration, not
-- a secret, and is seeded at deploy rather than written into the repository.
create or replace function wh.owner_email() returns text
language sql stable security definer set search_path = '' as $$
  select nullif(pg_catalog.lower(pg_catalog.btrim(value #>> '{}')), '')
    from wh.setting where key = 'owner_email'
$$;

create or replace function wh.jwt_is_owner() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(
    pg_catalog.lower(coalesce(
      nullif(pg_catalog.current_setting('request.jwt.claims', true), '')::jsonb ->> 'email', ''))
    = wh.owner_email(), false)
   and wh.owner_email() is not null
$$;

create or replace function wh.owner_person_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select person_id from wh.person where role = 'owner' and active order by created_at limit 1
$$;

create or replace function wh.current_person_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select coalesce(
    nullif(pg_catalog.current_setting('wh.person_id', true), '')::uuid,
    case when wh.jwt_is_owner() then wh.owner_person_id() end)
$$;

create or replace function wh.current_device_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select nullif(pg_catalog.current_setting('wh.device_id', true), '')::uuid
$$;

create or replace function wh.current_device() returns wh.device
language sql stable security definer set search_path = '' as $$
  select d.* from wh.device d where d.device_id = wh.current_device_id()
$$;

create or replace function wh.current_role() returns text
language sql stable security definer set search_path = '' as $$
  select p.role from wh.person p where p.person_id = wh.current_person_id() and p.active
$$;

create or replace function wh.is_owner() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(wh.current_role() = 'owner', false)
$$;

create or replace function wh.is_bound() returns boolean
language sql stable security definer set search_path = '' as $$
  select wh.current_person_id() is not null
$$;

create type wh.actor as (person_id uuid, device_id uuid);
comment on type wh.actor is
  'Who is acting, and from which phone. device_id is null when the owner acts through his Supabase session rather than a warehouse device.';

create or replace function wh.require_actor() returns wh.actor
language plpgsql stable security definer set search_path = '' as $$
declare a wh.actor;
begin
  a.person_id := wh.current_person_id();
  if a.person_id is null then
    raise exception 'this device is not activated for the warehouse' using errcode='42501';
  end if;
  if not exists (select 1 from wh.person where person_id = a.person_id and active) then
    raise exception 'this person is no longer active' using errcode='42501';
  end if;
  a.device_id := wh.current_device_id();
  return a;
end $$;

create or replace function wh.require_owner() returns wh.actor
language plpgsql stable security definer set search_path = '' as $$
declare a wh.actor;
begin
  a := wh.require_actor();
  if not wh.is_owner() then
    raise exception 'only the owner may do this' using errcode='42501';
  end if;
  return a;
end $$;

-- Kept so the write path can mark a phone as seen without knowing how.
create or replace function wh.touch_device(p_device_id uuid) returns void
language sql security definer set search_path = '' as $$
  update wh.device set last_seen_at = pg_catalog.now()
   where device_id = p_device_id
     and (last_seen_at is null or last_seen_at < pg_catalog.now() - interval '10 minutes')
$$;

-- ---------------------------------------------------------------- activation
create or replace function wh.issue_activation_code(p_person_id uuid, p_minutes int default 15,
                                                    p_mode text default 'add')
returns text language plpgsql security definer set search_path = '' as $$
declare v_code text;
begin
  perform wh.require_owner();
  if p_mode not in ('add','replace') then
    raise exception 'mode must be add or replace' using errcode='22023';
  end if;
  v_code := wh.mint_code();
  update wh.activation_code set void_at = pg_catalog.now()
   where person_id = p_person_id and used_at is null and void_at is null;
  insert into wh.activation_code(person_id, code_hash, mode, expires_at, issued_by_person_id)
  values (p_person_id, wh.fingerprint(v_code), p_mode,
          pg_catalog.now() + pg_catalog.make_interval(mins => p_minutes), wh.current_person_id());
  perform wh.log('activation_code.issue', 'person', p_person_id, p_mode);
  return v_code;   -- shown to the owner once; only its fingerprint is stored
end $$;

-- The one door a phone comes through. It RETURNS a refusal rather than raising,
-- so the attempt counter and the throttle commit even when the code is wrong.
-- Every refusal looks the same from outside.
create or replace function wh.activate_device(p_code text, p_label text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c wh.activation_code%rowtype; v_token text; v_device_id uuid; v_superseded int := 0;
begin
  if not wh.throttle_ok('activate', 20, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'unauthorised');
  end if;
  perform pg_catalog.pg_advisory_xact_lock(74211);   -- activations are serialised

  select * into c from wh.activation_code
   where code_hash = wh.fingerprint(p_code) for update;

  if not found then
    -- one wrong guess counts against every code still open; there are only ever a few
    update wh.activation_code set attempts = attempts + 1
     where used_at is null and void_at is null and expires_at > pg_catalog.now();
    update wh.activation_code set void_at = pg_catalog.now()
     where used_at is null and void_at is null and attempts >= 5;
    return jsonb_build_object('ok', false, 'error', 'unauthorised');
  end if;
  if c.used_at is not null or c.void_at is not null
     or c.attempts >= 5 or c.expires_at <= pg_catalog.now()
     or not exists (select 1 from wh.person where person_id = c.person_id and active) then
    return jsonb_build_object('ok', false, 'error', 'unauthorised');
  end if;

  if c.mode = 'replace' then
    update wh.device set revoked_at = pg_catalog.now(), revoked_reason = 'superseded by a new phone'
     where person_id = c.person_id and revoked_at is null;
    get diagnostics v_superseded = row_count;
  end if;

  v_token := wh.mint_secret();
  insert into wh.device(person_id, label, token_hash, token_issued_at)
  values (c.person_id, left(coalesce(p_label,'phone'), 80), wh.fingerprint_token(v_token), pg_catalog.now())
  returning device_id into v_device_id;

  update wh.activation_code
     set used_at = pg_catalog.now(), used_by_device_id = v_device_id, attempts = 0
   where code_id = c.code_id;

  insert into wh.audit(actor_person_id, actor_device_id, action, subject_type, subject_id, detail)
  values (c.person_id, v_device_id, 'device.activate', 'device', v_device_id,
          jsonb_build_object('label', p_label, 'mode', c.mode, 'superseded', v_superseded));

  return jsonb_build_object(
    'ok', true,
    'token', v_token,                                  -- handed over once, never stored
    'person', (select display_name from wh.person where person_id = c.person_id),
    'role',   (select role         from wh.person where person_id = c.person_id),
    'superseded', v_superseded);
end $$;

create or replace function wh.revoke_device(p_device_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform wh.require_owner();
  update wh.device
     set revoked_at = pg_catalog.now(), revoked_by_person_id = wh.current_person_id(),
         revoked_reason = p_reason, token_hash = null
   where device_id = p_device_id and revoked_at is null;
  if not found then
    raise exception 'no such active device' using errcode='23503';
  end if;
  perform wh.log('device.revoke', 'device', p_device_id, p_reason);
end $$;

-- A phone unused for 90 days loses access by itself.
create or replace function wh.expire_idle_devices(p_days int default 90)
returns integer language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update wh.device
     set revoked_at = pg_catalog.now(), revoked_reason = 'unused for ' || p_days || ' days', token_hash = null
   where revoked_at is null
     and coalesce(last_seen_at, activated_at) < pg_catalog.now() - pg_catalog.make_interval(days => p_days);
  get diagnostics n = row_count;
  return n;
end $$;
