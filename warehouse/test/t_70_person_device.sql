\set QUIET on
\set ON_ERROR_STOP on
-- "Recorded by Raj" means the person Raj. A phone is a separate thing that can be
-- replaced or revoked without touching history.
\set M '''cccccccc-0000-0000-0000-000000000001'''
select t.act_as('tok-raj-1');   -- Raj, phone 1
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
select t.act_as_nobody();
select t.raises($$select wh.submit_event('{"draft_id":"d0000000-0000-0000-0000-0000000000f2",
  "event_type":"IN","effective_at":"2026-09-21T10:00:00Z","lines":[]}'::jsonb, 0)$$,
  'not activated', 'a phone that was never activated cannot record anything');
select t.raises($$select public.wh_catalogue('not-a-real-credential')$$, 'unauthorised',
  'and a phone with no valid credential cannot read the catalogue through the API');

-- Raj moves to a second phone: same person, no change to history
insert into wh.device(device_id, person_id, label, token_hash, token_issued_at)
values ('dddddddd-0000-0000-0000-000000000005','22222222-2222-2222-2222-222222222222',
        'Raj phone 2', wh.fingerprint_token('tok-raj-2'), now());
select t.act_as('tok-raj-2');
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
select t.act_as_owner();
select wh.revoke_device('dddddddd-0000-0000-0000-000000000002','फ़ोन खो गया');
select t.raises($$select t.act_as('tok-raj-1')$$, 'unauthorised',
  'the revoked phone is refused at the credential, before it can ask for anything');
select t.raises($$select public.wh_submit_event('tok-raj-1',
  '{"draft_id":"d0000000-0000-0000-0000-0000000000f4","event_type":"IN",
    "effective_at":"2026-09-21T10:00:00Z","lines":[]}'::jsonb, 0)$$,
  'unauthorised', 'and the same phone is refused through the public API');
select t.act_as('tok-raj-2');   -- Raj's other phone
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

-- activation: a code is single use and binds one phone to one person
select t.act_as_owner();
select wh.issue_activation_code('22222222-2222-2222-2222-222222222222') as code \gset
select t.act_as_nobody();
select t.eq(wh.activate_device('BADCODEXX9','phone') ->> 'error', 'unauthorised',
            'a wrong activation code is refused');
select t.eq((select attempts::int from wh.activation_code where used_at is null and void_at is null), 1,
            'and the attempt is counted -- the function answers rather than raising, so the count survives');
select t.eq(wh.activate_device('BADCODEXX9','phone') -> 'ok', 'false'::jsonb,
            'every refusal looks the same from outside');
select t.eq(wh.activate_device(:'code', 'Raj phone 3') ->> 'ok', 'true',
            'the right code activates a phone');
select t.eq(wh.activate_device(:'code', 'again') ->> 'error', 'unauthorised',
            'and an activation code is single use');
select t.eq(length(wh.activate_device('ZZZZZZZZZZ','x') ->> 'error'), 12,
            'a refusal carries no name, no person and no hint');
