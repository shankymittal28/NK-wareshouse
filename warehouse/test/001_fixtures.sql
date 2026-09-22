-- Assertion helper and the small shared world every test builds on.
create schema if not exists t;
grant usage on schema t to authenticated, anon;

create or replace function t.ok(p_cond boolean, p_what text) returns void
language plpgsql as $$
begin
  if p_cond then raise notice 'ok %', p_what;
  else raise notice 'NOT OK %', p_what;
  end if;
end $$;

create or replace function t.eq(p_a anyelement, p_b anyelement, p_what text) returns void
language plpgsql as $$
begin
  if p_a is not distinct from p_b then raise notice 'ok % (%)', p_what, p_a;
  else raise notice 'NOT OK % : expected %, got %', p_what, p_b, p_a;
  end if;
end $$;

-- Asserts that a statement fails, optionally with a message matching a pattern.
create or replace function t.raises(p_sql text, p_pattern text, p_what text) returns void
language plpgsql as $$
begin
  begin
    execute p_sql;
    raise notice 'NOT OK % : expected an error, none raised', p_what;
  exception when others then
    if p_pattern is null or sqlerrm ilike '%'||p_pattern||'%' then
      raise notice 'ok % (%)', p_what, left(sqlerrm, 60);
    else
      raise notice 'NOT OK % : wrong error: %', p_what, sqlerrm;
    end if;
  end;
end $$;

-- Acting as a given phone: exactly what a staff request does, through the real
-- credential path. There is no test-only shortcut into the actor settings.
create or replace function t.act_as(p_token text) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{}', true);   -- not the owner's session
  perform wh.assume_device(p_token);
end $$;

-- The owner arrives differently: a signed Supabase claim, no device credential.
create or replace function t.act_as_owner() returns void
language plpgsql as $$
begin
  -- a session is one identity at a time: arriving as the owner clears any
  -- device credential established earlier in this request
  perform set_config('wh.person_id', '', true);
  perform set_config('wh.device_id', '', true);
  perform set_config('request.jwt.claims',
    json_build_object('email','owner@example.test','role','authenticated')::text, true);
end $$;

create or replace function t.act_as_nobody() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{}', true);
  perform set_config('wh.person_id', '', true);
  perform set_config('wh.device_id', '', true);
end $$;

grant execute on all functions in schema t to authenticated, anon;

-- ---------------------------------------------------------------- the world
insert into wh.category(category_code, name_hi, name_en, unit_code, unit_hi, unit_en, decimals, sort) values
  ('Plywood','प्लाईवुड','Plywood','sheet','शीट','sheets',0,1),
  ('Doors','दरवाज़े','Doors','piece','पीस','pcs',0,2),
  ('Hardware','हार्डवेयर','Hardware','piece','पीस','pcs',0,3),
  ('Glass','कांच','Glass','sqft','वर्ग फुट','sq ft',2,4);

insert into wh.category_attribute(category_code, seq, attr_key, label_hi, label_en) values
  ('Plywood',1,'brand','ब्रांड','Brand'),
  ('Plywood',2,'thickness','मोटाई','Thickness'),
  ('Plywood',3,'size','साइज़','Size'),
  ('Doors',1,'variety','किस्म','Variety'),
  ('Doors',2,'design','डिज़ाइन','Design'),
  ('Doors',3,'size','साइज़','Size'),
  ('Hardware',1,'name','नाम','Name'),
  ('Glass',1,'kind','किस्म','Kind'),
  ('Glass',2,'thickness','मोटाई','Thickness');

insert into wh.person(person_id, display_name, role) values
  ('11111111-1111-1111-1111-111111111111','Shanky','owner'),
  ('22222222-2222-2222-2222-222222222222','राज','staff'),
  ('33333333-3333-3333-3333-333333333333','सुरेश','staff');

-- The owner's identity is his existing Supabase account, named in settings.
update wh.setting set value = '"owner@example.test"'::jsonb where key = 'owner_email';

insert into auth.users(id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001','owner@example.test');

-- Three phones with known credentials. Test-only values: real ones are 256 bits
-- of randomness that nothing but the phone ever sees.
insert into wh.device(device_id, person_id, label, token_hash, token_issued_at) values
  ('dddddddd-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Shanky phone',
     wh.fingerprint_token('tok-owner-1'), now()),
  ('dddddddd-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222','Raj phone 1',
     wh.fingerprint_token('tok-raj-1'), now()),
  ('dddddddd-0000-0000-0000-000000000003','33333333-3333-3333-3333-333333333333','Suresh phone',
     wh.fingerprint_token('tok-suresh-1'), now());

insert into wh.material(material_id, category_code, attrs) values
  ('cccccccc-0000-0000-0000-000000000001','Plywood','{"brand":"Century","thickness":"18mm","size":"8x4"}'),
  ('cccccccc-0000-0000-0000-000000000002','Plywood','{"brand":"Century","thickness":"12mm","size":"8x4"}'),
  ('cccccccc-0000-0000-0000-000000000003','Plywood','{"brand":"Greenply","thickness":"12mm","size":"7x4"}'),
  ('cccccccc-0000-0000-0000-000000000004','Doors','{"variety":"Lamination","design":"KP7098","size":"78x38"}'),
  ('cccccccc-0000-0000-0000-000000000005','Glass','{"kind":"Plain","thickness":"5mm"}');
