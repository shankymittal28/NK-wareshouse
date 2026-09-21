\set QUIET on
\set ON_ERROR_STOP on
-- The warehouse project has its own auth realm. The owner is established here by an
-- activation he performs himself. No password is ever copied from anywhere.
-- (The fixtures already bound an owner device; this test starts from an empty realm.)
delete from wh.device; delete from wh.person where role <> 'owner';
delete from wh.activation_code;
delete from wh.person;

select t.eq((select count(*)::int from wh.person where role='owner'), 0, 'no owner exists yet');

-- the deployer, holding the service key, seeds the owner and one code
\set CODE `echo`
select wh.bootstrap_owner('Shanky') as code \gset
select t.eq(length(:'code'), 8, 'the deployer receives a single activation code');
select t.eq((select count(*)::int from wh.person where role='owner'), 1, 'the owner person now exists');
select t.eq((select count(*)::int from wh.activation_code where code_hash = :'code'), 0,
            'and the code itself is not stored anywhere, only its salted hash');

-- the owner signs up in this project with a password only he knows, then redeems the code
insert into auth.users(id, email, is_anonymous) values
  ('bbbbbbbb-0000-0000-0000-000000000001','shanky@example.test', false);
set role authenticated;
select t.act_as('bbbbbbbb-0000-0000-0000-000000000001');
select t.eq(wh.activate_device(:'code', 'Shanky phone') ->> 'role', 'owner',
            'redeeming the code binds his own account to the owner person');
select t.eq(wh.current_role(), 'owner', 'he is the owner in this project from now on');

-- single use
select t.raises(format($$select wh.activate_device(%L, 'again')$$, :'code'),
                'already activated', 'the same phone cannot activate twice');
reset role;
insert into auth.users(id, is_anonymous) values ('bbbbbbbb-0000-0000-0000-000000000002', true);
set role authenticated;
select t.act_as('bbbbbbbb-0000-0000-0000-000000000002');
select t.raises(format($$select wh.activate_device(%L, 'stolen code')$$, :'code'),
                'not valid', 'a used code cannot be redeemed by anyone else');

-- from here the owner issues codes for the staff through the normal path
select t.act_as('bbbbbbbb-0000-0000-0000-000000000001');
reset role;
insert into wh.person(person_id, display_name, role)
values ('22222222-2222-2222-2222-222222222222','राज','staff');
set role authenticated;
select wh.issue_activation_code('22222222-2222-2222-2222-222222222222') as rcode \gset
select t.act_as('bbbbbbbb-0000-0000-0000-000000000002');
select t.eq(wh.activate_device(:'rcode', 'Raj phone') ->> 'person', 'राज',
            'a staff phone activates against its own person');
select t.eq(wh.current_role(), 'staff', 'and holds only staff rights');
select t.raises($$select wh.bootstrap_owner('someone else')$$,
                'permission denied', 'the bootstrap door is closed to every client');
reset role;
