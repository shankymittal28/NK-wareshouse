\set QUIET on
\set ON_ERROR_STOP on
-- The owner keeps the Supabase identity he already uses for NK. There is no
-- second owner auth realm, no second password, and nothing is ever copied from
-- one project to another. Warehouse staff never enter that realm at all.

-- ---- the deploy-time door ------------------------------------------------
delete from wh.device; delete from wh.activation_code; delete from wh.person;
delete from wh.setting where key = 'owner_email';
select t.eq((select count(*)::int from wh.person where role='owner'), 0, 'no owner exists yet');

select wh.bootstrap_owner('Shanky', 'Owner@Example.Test') as owner \gset
select t.eq((select count(*)::int from wh.person where role='owner'), 1,
            'the deployer names the existing Supabase account as the owner');
select t.eq(wh.owner_email(), 'owner@example.test',
            'the email is stored folded to lower case, so a capital cannot lock him out');
select t.eq((select count(*)::int from wh.setting where key='owner_email'), 1,
            'and it is configuration in the database, not a literal in the repository');

-- ---- who the warehouse believes is the owner -----------------------------
select t.act_as_nobody();
select t.eq(wh.jwt_is_owner(), false, 'a caller with no session is not the owner');
select t.eq(wh.is_owner(), false, 'and holds no owner rights');

select set_config('request.jwt.claims',
  '{"email":"someone.else@example.test","role":"authenticated"}', true);
select t.eq(wh.jwt_is_owner(), false, 'a different signed-in account is not the owner');
select t.raises($$select wh.require_owner()$$, 'not activated',
                'and is refused owner work');

select set_config('request.jwt.claims',
  '{"email":"OWNER@example.test","role":"authenticated"}', true);
select t.eq(wh.jwt_is_owner(), true, 'the owner is recognised regardless of how he types his email');
select t.eq(wh.current_role(), 'owner', 'and holds owner rights');
select t.eq(wh.current_person_id(), :'owner'::uuid, 'resolving to the owner person history points at');
select t.eq(wh.current_device_id(), null::uuid,
            'with no device behind him -- he is at a desk, not on a warehouse phone');

-- ---- the claim is the only way in ----------------------------------------
select t.act_as_nobody();
select set_config('request.jwt.claims', '{"email":"","role":"authenticated"}', true);
select t.eq(wh.jwt_is_owner(), false, 'an empty email claim is not the owner');
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select t.eq(wh.jwt_is_owner(), false, 'nor is a session with no email at all');

-- ---- a staff phone can never become the owner ----------------------------
select t.act_as_nobody();
insert into wh.person(person_id, display_name, role)
values ('22222222-2222-2222-2222-222222222222','राज','staff');
insert into wh.device(device_id, person_id, label, token_hash, token_issued_at)
values ('dddddddd-0000-0000-0000-00000000aa01','22222222-2222-2222-2222-222222222222',
        'Raj phone', wh.fingerprint_token('tok-raj-x'), now());
select t.act_as('tok-raj-x');
select t.eq(wh.current_role(), 'staff', 'a warehouse credential resolves to its own person and role');
select t.eq(wh.is_owner(), false, 'never to the owner');
select t.raises($$select wh.set_rate('cccccccc-0000-0000-0000-000000000002', 100)$$,
                'only the owner', 'so staff cannot touch money');

-- and the two identities cannot be held at once
select set_config('request.jwt.claims',
  '{"email":"owner@example.test","role":"authenticated"}', true);
select t.eq(wh.current_role(), 'staff',
            'a device credential presented in a request wins over any claim alongside it');

-- ---- the deploy door is closed to every client ---------------------------
set role authenticated;
select t.raises($$select wh.bootstrap_owner('someone else','thief@example.test')$$,
                'permission denied', 'the bootstrap door is closed to a signed-in client');
set role anon;
select t.raises($$select wh.bootstrap_owner('someone else','thief@example.test')$$,
                'permission denied', 'and to the public key');
