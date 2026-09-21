\set QUIET on
\set ON_ERROR_STOP on
-- Drafts are revision-safe and invisible to stock. Confirming is atomic and idempotent.
set role authenticated;
select t.act_as('aaaaaaaa-0000-0000-0000-000000000002');   -- Raj, phone 1

\set D '''d0000000-0000-0000-0000-0000000000a1'''
select t.eq(wh.draft_put(:D::uuid, 1, '{"event_type":"IN","lines":[]}') ->> 'applied', 'true',
            'a new draft is stored');
select t.eq(wh.draft_put(:D::uuid, 1, '{"event_type":"IN","lines":[1]}') ->> 'reason', 'stale_rev',
            'the same revision again changes nothing');
select t.eq(wh.draft_put(:D::uuid, 4, '{"event_type":"IN","lines":[]}') ->> 'client_rev', '4',
            'a newer revision is applied, so resuming after an interruption works');
select t.eq((select client_rev from wh.draft where draft_id = :D::uuid), 4,
            'the server holds the revision the phone last sent');
select t.eq((select count(*)::int from wh.stock_event where event_id = :D::uuid), 0,
            'an open draft has no event and cannot touch stock');

-- confirming a revision older than the server holds is refused
select t.raises(format($$select wh.submit_event('{"draft_id":"%s","event_type":"IN","effective_at":"%s",
   "lines":[{"material_id":"cccccccc-0000-0000-0000-000000000001","qty":20}]}'::jsonb, 3)$$,
   'd0000000-0000-0000-0000-0000000000a1', now()),
   'rev_mismatch', 'confirming a draft the server has moved past is refused');

select t.eq(wh.submit_event(jsonb_build_object(
      'draft_id', :D, 'event_type','IN', 'effective_at', now()::text,
      'counterparty','Zangi Transport','kind','transport',
      'lines', jsonb_build_array(
         jsonb_build_object('material_id','cccccccc-0000-0000-0000-000000000001','qty',20),
         jsonb_build_object('material_id','cccccccc-0000-0000-0000-000000000002','qty',25))), 4) ->> 'lines',
   '2', 'the exact reviewed draft confirms, with all its lines, in one go');
select t.eq((select status from wh.draft where draft_id = :D::uuid), 'confirmed',
            'the draft is marked confirmed');

-- retry of the very same submission
select t.eq(wh.submit_event(jsonb_build_object(
      'draft_id', :D, 'event_type','IN', 'effective_at', now()::text,
      'lines', jsonb_build_array(
         jsonb_build_object('material_id','cccccccc-0000-0000-0000-000000000001','qty',20))), 4) ->> 'already',
   'true', 'a retry after a lost reply returns the same event');
select t.eq((select count(*)::int from wh.event_line where event_id = :D::uuid), 2,
            'the retry added no second set of lines');
select t.eq((select count(*)::int from wh.stock_event where event_id = :D::uuid), 1,
            'exactly one event exists for that identity');

-- a movement needs at least one line
select t.raises($$select wh.submit_event('{"draft_id":"d0000000-0000-0000-0000-0000000000a2",
   "event_type":"IN","effective_at":"2026-09-20T10:00:00Z","lines":[]}'::jsonb, 0)$$,
   'at least one line', 'an empty movement is refused');

-- giving out more than is recorded needs a deliberate acknowledgement
select wh.record_opening('cccccccc-0000-0000-0000-000000000003', 5, now() - interval '3 days');
select t.raises($$select wh.submit_event(jsonb_build_object(
   'draft_id','d0000000-0000-0000-0000-0000000000a3','event_type','OUT','effective_at',now()::text,
   'lines', jsonb_build_array(jsonb_build_object(
      'material_id','cccccccc-0000-0000-0000-000000000003','qty',9))), 0)$$,
   'deliberate acknowledgement', 'an outward above recorded stock is refused without acknowledgement');
select t.eq(wh.submit_event(jsonb_build_object(
   'draft_id','d0000000-0000-0000-0000-0000000000a3','event_type','OUT','effective_at',now()::text,
   'lines', jsonb_build_array(jsonb_build_object(
      'material_id','cccccccc-0000-0000-0000-000000000003','qty',9,'over_ack',true))), 0) ->> 'lines',
   '1', 'with acknowledgement the real movement is recorded');
select t.eq(wh.stock_as_of('cccccccc-0000-0000-0000-000000000003'), -4::numeric,
            'physical reality wins: recorded stock goes negative and stays visible');

-- somebody else's draft
select t.act_as('aaaaaaaa-0000-0000-0000-000000000003');   -- Suresh
select t.raises($$select wh.draft_put('d0000000-0000-0000-0000-0000000000a4'::uuid, 1, '{}'::jsonb);
                  select wh.draft_put('d0000000-0000-0000-0000-0000000000a1'::uuid, 9, '{}'::jsonb)$$,
   'belongs to someone else', 'one person cannot overwrite another person''s draft');
reset role;
