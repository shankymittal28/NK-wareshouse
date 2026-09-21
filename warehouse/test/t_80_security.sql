\set QUIET on
\set ON_ERROR_STOP on
-- Least privilege: staff see the quantities their work needs; money is the owner's.
-- No client role may write to a table at all.
set role authenticated;
\set M '''cccccccc-0000-0000-0000-000000000001'''
select t.act_as('aaaaaaaa-0000-0000-0000-000000000002');   -- Raj
select wh.record_opening(:M::uuid, 73, now() - interval '2 days');

select t.eq((select recorded_qty from wh.material_stock where material_id = :M::uuid), 73::numeric,
            'staff can see the recorded quantity they need to do warehouse work');
select t.eq((select count(*)::int from wh.material), 5, 'staff can search the material catalogue');

select t.act_as('aaaaaaaa-0000-0000-0000-000000000001');
select wh.set_rate(:M::uuid, 2150);
select t.act_as('aaaaaaaa-0000-0000-0000-000000000002');
select t.eq((select count(*)::int from wh.rate), 0, 'staff cannot read a valuation rate');
select t.eq((select count(*)::int from wh.rate_history), 0, 'nor its history');
select t.eq((select count(*)::int from wh.material_value), 0, 'nor any material value');
select t.eq((select count(*)::int from wh.valuation_coverage), 0, 'nor the godown total');
select t.raises($$select wh.set_rate('cccccccc-0000-0000-0000-000000000001', 99)$$,
                'only the owner', 'staff cannot set a rate');
select t.eq((select count(*)::int from wh.audit), 0, 'staff cannot read the audit log');

select t.act_as('aaaaaaaa-0000-0000-0000-000000000001');
-- a second stocked material, deliberately left without a rate
select wh.record_opening('cccccccc-0000-0000-0000-000000000002', 30, now() - interval '2 days');
select t.eq((select rate from wh.rate where material_id = :M::uuid), 2150::numeric, 'the owner sees rates');
select t.eq((select value from wh.material_value where material_id = :M::uuid), 156950::numeric,
            'and the value, computed in exact arithmetic');
select t.eq((select rated_materials::int from wh.valuation_coverage), 1, 'and how much of the value is covered');
select t.ok((select stocked_materials > rated_materials from wh.valuation_coverage),
            'coverage is stated honestly, never as a complete figure');

-- no client may write to a table directly, by any route
select t.raises($$insert into wh.stock_event(event_id,event_type,effective_at,confirmed_at,
   recorder_person_id,device_id) values (gen_random_uuid(),'IN',now(),now(),
   '11111111-1111-1111-1111-111111111111','dddddddd-0000-0000-0000-000000000001')$$,
   'permission denied', 'even the owner cannot insert an event outside the write path');
select t.raises($$update wh.event_line set qty = 999$$, 'permission denied',
   'nobody can update a confirmed line');
select t.raises($$delete from wh.stock_event$$, 'permission denied',
   'nobody can delete a recorded movement');
select t.raises($$insert into wh.rate(material_id, rate, set_by_person_id)
   values ('cccccccc-0000-0000-0000-000000000002', 1, '11111111-1111-1111-1111-111111111111')$$,
   'permission denied', 'not even a rate can be written around the function');
select t.raises($$select wh.hash_code('x','y')$$, 'permission denied',
   'internal helpers are not callable by a client');
reset role;

-- the anonymous role, which is what an unauthenticated page would hold, sees nothing
set role anon;
select t.raises($$select count(*) from wh.material$$, 'permission denied',
                'the anonymous role cannot read the catalogue');
select t.raises($$select count(*) from wh.stock_event$$, 'permission denied',
                'nor any movement');
reset role;
