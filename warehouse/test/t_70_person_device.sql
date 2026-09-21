\set QUIET on
\set ON_ERROR_STOP on
-- "Recorded by Raj" means the person Raj. A phone is a separate thing that can be
-- replaced or revoked without touching history.
set role authenticated;
\set M '''cccccccc-0000-0000-0000-000000000001'''
select t.act_as('aaaaaaaa-0000-0000-0000-000000000002');   -- Raj, phone 1
select wh.record_opening(:M::uuid, 50, now() - interval '5 days');

-- the payload cannot say who recorded it
select wh.submit_event(jsonb_build_object('draft_id','d0000000-0000-0000-0000-0000000000f1',
  'event_type','IN','effective_at',now()::text,
  'recorder_person_id','11111111-1111-1111-1111-111111111111',
  'handler_person_id','33333333-3333-3333-3333-333333333333',
  'lines', jsonb_build_array(jsonb_build_object('material_id',:M,'qty',5))), 0);
select t.eq((select recorder_person_id from wh.stock_event where event_id='d0000000-0000-0000-0000-0000000000f1'),
            '22222222-2222-2222-2222-222222222222'::uuid,
            'the recorder comes from the credential, not from the payload that tried to claim the owner');
select t.eq((select handler_person_id from wh.stock_event where event_id='d0000000-0000-0000-0000-0000000000f1'),
            '33333333-3333-3333-3333-333333333333'::uuid,
            'who physically handled the goods is a separate, supplied fact');

-- an unactivated phone can do nothing
select t.act_as('aaaaaaaa-0000-0000-0000-000000000004');
select t.raises($$select wh.submit_event('{"draft_id":"d0000000-0000-0000-0000-0000000000f2",
  "event_type":"IN","effective_at":"2026-09-21T10:00:00Z","lines":[]}'::jsonb, 0)$$,
  'not activated', 'a phone that was never activated cannot record anything');
select t.eq((select count(*)::int from wh.material), 0, 'and it cannot read the catalogue either');

-- Raj moves to a second phone: same person, no change to history
reset role;
insert into auth.users(id) values ('aaaaaaaa-0000-0000-0000-000000000005');
insert into wh.device(device_id, auth_user_id, person_id, label)
values ('dddddddd-0000-0000-0000-000000000005','aaaaaaaa-0000-0000-0000-000000000005',
        '22222222-2222-2222-2222-222222222222','Raj phone 2');
set role authenticated;
select t.act_as('aaaaaaaa-0000-0000-0000-000000000005');
select wh.submit_event(jsonb_build_object('draft_id','d0000000-0000-0000-0000-0000000000f3',
  'event_type','IN','effective_at',now()::text,
  'lines', jsonb_build_array(jsonb_build_object('material_id',:M,'qty',3))), 0);
select t.eq((select count(distinct recorder_person_id)::int from wh.stock_event
              where event_id in ('d0000000-0000-0000-0000-0000000000f1','d0000000-0000-0000-0000-0000000000f3')), 1,
            'both phones record as the same person');
select t.eq((select count(distinct device_id)::int from wh.stock_event
              where event_id in ('d0000000-0000-0000-0000-0000000000f1','d0000000-0000-0000-0000-0000000000f3')), 2,
            'while the two devices remain separately identifiable');

-- a lost phone is revoked on its own
select t.raises($$select wh.revoke_device('dddddddd-0000-0000-0000-000000000002','खो गया')$$,
                'only the owner', 'staff cannot revoke a device');
select t.act_as('aaaaaaaa-0000-0000-0000-000000000001');
select wh.revoke_device('dddddddd-0000-0000-0000-000000000002','फ़ोन खो गया');
select t.act_as('aaaaaaaa-0000-0000-0000-000000000002');   -- the lost phone
select t.raises($$select wh.submit_event('{"draft_id":"d0000000-0000-0000-0000-0000000000f4",
  "event_type":"IN","effective_at":"2026-09-21T10:00:00Z","lines":[]}'::jsonb, 0)$$,
  'not activated', 'the revoked phone can no longer write');
select t.act_as('aaaaaaaa-0000-0000-0000-000000000005');   -- Raj's other phone
select t.eq(wh.submit_event(jsonb_build_object('draft_id','d0000000-0000-0000-0000-0000000000f5',
  'event_type','IN','effective_at',now()::text,
  'lines', jsonb_build_array(jsonb_build_object('material_id',:M,'qty',1))), 0) ->> 'lines', '1',
  'his other phone is unaffected');
select t.eq((select count(*)::int from wh.stock_event
              where device_id='dddddddd-0000-0000-0000-000000000002'), 1,
            'and everything the lost phone recorded is still in the ledger');
select t.eq((select recorder_person_id from wh.stock_event where event_id='d0000000-0000-0000-0000-0000000000f1'),
            '22222222-2222-2222-2222-222222222222'::uuid,
            'still attributed to the person, not to the revoked phone');
reset role;

-- activation: a code is single use and binds one phone to one person
set role authenticated;
select t.act_as('aaaaaaaa-0000-0000-0000-000000000001');
\set CODE '''(select wh.issue_activation_code(''22222222-2222-2222-2222-222222222222''))'''
select t.act_as('aaaaaaaa-0000-0000-0000-000000000009');
select t.raises($$select wh.activate_device('BADCODE1','phone')$$,
                'not valid', 'a wrong activation code is refused');
reset role;
