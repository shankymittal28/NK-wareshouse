\set QUIET on
\set ON_ERROR_STOP on
-- Physical time decides the arithmetic and ordinary history. System-receipt time is kept
-- separately, for sync questions only. The two are never collapsed.
select t.act_as('tok-raj-1');
\set M '''cccccccc-0000-0000-0000-000000000001'''

select wh.record_opening(:M::uuid, 50, now() - interval '10 days');

-- a truck that physically arrived five days ago, synced only now
select wh.submit_event(jsonb_build_object('draft_id','d0000000-0000-0000-0000-0000000000b1',
  'event_type','IN','effective_at',(now() - interval '5 days')::text,'counterparty','Zangi Transport',
  'backdated_reason','phone was offline in the godown',
  'lines', jsonb_build_array(jsonb_build_object('material_id',:M,'qty',20))), 0);
select t.eq(wh.stock_as_of(:M::uuid), 70::numeric,
            'a movement after the baseline applies, even though NK learned of it only now');

-- a movement that physically happened BEFORE the opening count, synced afterwards.
-- The counted 50 already contains it, so applying it again would double-count.
select wh.submit_event(jsonb_build_object('draft_id','d0000000-0000-0000-0000-0000000000b2',
  'event_type','OUT','effective_at',(now() - interval '12 days')::text,'counterparty','दुकान',
  'backdated_reason','late sync from an offline phone',
  'lines', jsonb_build_array(jsonb_build_object('material_id',:M,'qty',5,'over_ack',true))), 0);
select t.eq(wh.stock_as_of(:M::uuid), 70::numeric,
            'a late movement from before the baseline is excluded from stock');
select t.eq((select count(*)::int from wh.trail(:M::uuid)
              where (detail ->> 'late_pre_baseline')::boolean), 1,
            'but it is stored and flagged in the trail, so the goods do not vanish');
select t.eq((select count(*)::int from wh.stock_event where event_id = 'd0000000-0000-0000-0000-0000000000b2'), 1,
            'the excluded movement is still a real recorded event');

-- ordinary business history follows physical time
select t.eq((select count(*)::int from wh.event_effective
              where effective_at >= date_trunc('day', now() - interval '5 days')
                and effective_at <  date_trunc('day', now() - interval '4 days')), 1,
            'what moved five days ago is found by physical time, though it synced today');
select t.eq((select count(*)::int from wh.event_effective
              where effective_at >= date_trunc('day', now())), 0,
            'a movement that synced today is NOT counted as today''s physical movement');

-- the sync question is answerable separately
select t.eq((select count(*)::int from wh.stock_event
              where server_received_at >= date_trunc('day', now())), 2,
            'when NK learned of things is a separate question with its own answer');
select t.ok((select e.effective_at < e.server_received_at from wh.stock_event e
              where e.event_id = 'd0000000-0000-0000-0000-0000000000b1'),
            'physical time and receipt time are stored as different values');

-- as-of queries honour both axes
select t.eq(wh.stock_as_of(:M::uuid, now() - interval '6 days'), 50::numeric,
            'stock six days ago was the baseline alone');
select t.eq(wh.stock_as_of(:M::uuid, 'infinity', (select recorded_at - interval '1 second'
                                                    from wh.opening where material_id = :M::uuid)), null::numeric,
            'before the baseline reached NK, NK could not state a stock at all');
select t.eq(wh.stock_as_of(:M::uuid, 'infinity',
              (select server_received_at from wh.stock_event
                where event_id = 'd0000000-0000-0000-0000-0000000000b1')), 70::numeric,
            'as NK received the first movement, it knew 70');
