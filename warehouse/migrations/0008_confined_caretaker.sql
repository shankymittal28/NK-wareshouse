-- 0008  the confined caretaker
--
-- Every warehouse function runs with borrowed authority (SECURITY DEFINER).
-- The whole security boundary of this system is the answer to one question:
-- WHOSE authority does it borrow?
--
-- Today's NK functions borrow `postgres`, which on this project holds
-- BYPASSRLS and owns every table. A single mistake in such a function reaches
-- payroll, Tally and the legacy NK data.
--
-- So the warehouse gets a caretaker of its own: a role that can log in nowhere,
-- inherits nothing, cannot bypass row level security, and owns nothing but the
-- `wh` schema. If a warehouse function is ever subverted, that is the whole of
-- what it can touch. 0010 asserts exactly this, and CI fails if it drifts.
--
-- Verified on the real project before this was written: a non-login role can be
-- created, can own a schema and its functions, and is denied every table
-- outside wh, the Tally schemas, auth and storage.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'wh_owner') then
    create role wh_owner
      nologin nosuperuser nocreatedb nocreaterole noinherit nobypassrls noreplication;
  end if;
end $$;

-- Converge the attributes whether the role was just created or already existed,
-- so this migration is idempotent and cannot inherit a looser earlier state.
alter role wh_owner
  nologin nosuperuser nocreatedb nocreaterole noinherit nobypassrls noreplication;

-- The role that runs migrations must be able to SET ROLE to the caretaker in
-- order to hand objects over. On Supabase, CREATE ROLE by `postgres` yields a
-- membership with set=false, so the grant below is required, not decorative.
do $$
begin
  execute format('grant wh_owner to %I with inherit false, set true', current_user);
exception when others then null;   -- already a member, or the platform granted it
end $$;

alter schema wh owner to wh_owner;

-- Hand over every object the earlier migrations created.
do $$
declare r record;
begin
  for r in select 'table'    as kind, format('%I.%I', schemaname, tablename) as ident
             from pg_tables where schemaname = 'wh'
           union all
           select 'view',     format('%I.%I', schemaname, viewname)
             from pg_views  where schemaname = 'wh'
  loop
    execute format('alter %s %s owner to wh_owner', r.kind, r.ident);
  end loop;

  for r in select format('%I.%I(%s)', n.nspname, p.proname,
                         pg_get_function_identity_arguments(p.oid)) as ident
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'wh'
  loop
    execute format('alter function %s owner to wh_owner', r.ident);
  end loop;

  for r in select format('%I.%I', sequence_schema, sequence_name) as ident
             from information_schema.sequences where sequence_schema = 'wh'
  loop
    execute format('alter sequence %s owner to wh_owner', r.ident);
  end loop;
end $$;

-- The caretaker needs nothing outside wh. State that as an assertion, so the
-- migration fails rather than silently leaving a wider role in place.
do $$
declare bad text;
begin
  select string_agg(distinct table_schema || '.' || table_name, ', ')
    into bad
    from information_schema.table_privileges
   where grantee = 'wh_owner' and table_schema <> 'wh';
  if bad is not null then
    raise exception 'caretaker holds privileges outside wh: %', bad;
  end if;

  if exists (select 1 from pg_roles
              where rolname = 'wh_owner'
                and (rolsuper or rolcreatedb or rolcreaterole
                     or rolbypassrls or rolreplication or rolcanlogin or rolinherit)) then
    raise exception 'caretaker has attributes it must not have';
  end if;

  if exists (select 1 from pg_auth_members m join pg_roles r on r.oid = m.member
              where r.rolname = 'wh_owner') then
    raise exception 'caretaker is a member of another role and would borrow its rights';
  end if;

  raise notice 'wh_owner: owns wh, holds nothing else';
end $$;

-- The pepper is minted here, once, from the server's own randomness. It is
-- never printed, never committed, and never leaves the database.
insert into wh.secret(k, v)
select 'pepper', uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid())
 where not exists (select 1 from wh.secret where k = 'pepper');
