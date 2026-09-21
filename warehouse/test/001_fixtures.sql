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

-- Acting as a given device, exactly as PostgREST would present a JWT.
create or replace function t.act_as(p_auth_user uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_auth_user, 'role', 'authenticated')::text, false);
end $$;

create or replace function t.act_as_nobody() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{}', false);
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

insert into auth.users(id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001','owner@example.test'),
  ('aaaaaaaa-0000-0000-0000-000000000002',null),
  ('aaaaaaaa-0000-0000-0000-000000000003',null),
  ('aaaaaaaa-0000-0000-0000-000000000004',null),
  ('aaaaaaaa-0000-0000-0000-000000000009',null);

-- owner phone, Raj's first phone, Suresh's phone. 0004 stays unbound for negative tests.
insert into wh.device(device_id, auth_user_id, person_id, label) values
  ('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Shanky phone'),
  ('dddddddd-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222','Raj phone 1'),
  ('dddddddd-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000003','33333333-3333-3333-3333-333333333333','Suresh phone');

insert into wh.material(material_id, category_code, attrs) values
  ('cccccccc-0000-0000-0000-000000000001','Plywood','{"brand":"Century","thickness":"18mm","size":"8x4"}'),
  ('cccccccc-0000-0000-0000-000000000002','Plywood','{"brand":"Century","thickness":"12mm","size":"8x4"}'),
  ('cccccccc-0000-0000-0000-000000000003','Plywood','{"brand":"Greenply","thickness":"12mm","size":"7x4"}'),
  ('cccccccc-0000-0000-0000-000000000004','Doors','{"variety":"Lamination","design":"KP7098","size":"78x38"}'),
  ('cccccccc-0000-0000-0000-000000000005','Glass','{"kind":"Plain","thickness":"5mm"}');
