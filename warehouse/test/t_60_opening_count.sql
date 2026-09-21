\set QUIET on
\set ON_ERROR_STOP on
-- The first trusted baseline is the opening. Every later physical count is a report,
-- and an approved report becomes an adjustment placed at the moment of counting.
set role authenticated;
select t.act_as('aaaaaaaa-0000-0000-0000-000000000002');
\set M '''cccccccc-0000-0000-0000-000000000001'''

select t.raises(format($$select wh.report_count(%L::uuid, 40)$$, :M),
                'no_opening', 'the first count of a material cannot be a count report');
select wh.record_opening(:M::uuid, 50, now() - interval '20 days');
select t.raises(format($$select wh.record_opening(%L::uuid, 44)$$, :M),
                'opening_exists', 'a second opening is refused by the database, not by a screen');
select t.eq((select count(*)::int from wh.opening where material_id = :M::uuid and status='active'), 1,
            'exactly one active baseline exists');

-- a count that agrees needs no adjustment but is still recorded
select t.eq(wh.report_count(:M::uuid, 50, now() - interval '19 days') ->> 'status', 'approved',
            'a count that matches is recorded and closed');

-- movements, then a count that disagrees
select wh.submit_event(jsonb_build_object('draft_id','d0000000-0000-0000-0000-0000000000e1',
  'event_type','IN','effective_at',(now() - interval '10 days')::text,'counterparty','Zangi Transport',
  'backdated_reason','test fixture',
  'lines', jsonb_build_array(jsonb_build_object('material_id',:M,'qty',12))), 0);
select t.eq(wh.stock_as_of(:M::uuid), 62::numeric, 'stock is 50 + 12');

select t.eq((wh.report_count(:M::uuid, 60, now() - interval '5 days', '2 शीट टूटी मिलीं') ->> 'difference')::numeric,
            -2::numeric, 'a count five days ago found two fewer than recorded');

-- a movement AFTER the count does not invalidate it
select wh.submit_event(jsonb_build_object('draft_id','d0000000-0000-0000-0000-0000000000e2',
  'event_type','IN','effective_at',(now() - interval '2 days')::text,'counterparty','दुकान',
  'backdated_reason','test fixture',
  'lines', jsonb_build_array(jsonb_build_object('material_id',:M,'qty',10))), 0);
select t.eq(wh.stock_as_of(:M::uuid), 72::numeric, 'stock is now 72 before approval');

select t.act_as('aaaaaaaa-0000-0000-0000-000000000001');   -- owner approves
select t.eq((wh.approve_count((select count_id from wh.count_report
                               where material_id = :M::uuid and status='pending'), 'टूट-फूट') ->> 'delta')::numeric,
            -2::numeric, 'approving applies the difference the count actually found');
select t.eq(wh.stock_as_of(:M::uuid), 70::numeric,
            'the later arrival is preserved: 60 counted, then 10 arrived, so 70');
select t.eq((select event_type from wh.stock_event e
              join wh.count_report c on c.adjustment_event_id = e.event_id
             where c.material_id = :M::uuid and c.status='approved' and c.adjustment_event_id is not null),
            'ADJUSTMENT', 'the adjustment is a real event in the ledger');
select t.ok((select e.effective_at = c.counted_at from wh.stock_event e
              join wh.count_report c on c.adjustment_event_id = e.event_id
             where c.adjustment_event_id is not null),
            'and it sits at the moment of counting, so later movements stay on top of it');

-- a pre-count change arriving afterwards invalidates the basis
select t.act_as('aaaaaaaa-0000-0000-0000-000000000002');
select wh.report_count(:M::uuid, 66, now() - interval '1 day', 'फिर से गिना');
select wh.submit_event(jsonb_build_object('draft_id','d0000000-0000-0000-0000-0000000000e3',
  'event_type','OUT','effective_at',(now() - interval '3 days')::text,'counterparty','दुकान',
  'backdated_reason','offline phone synced late',
  'lines', jsonb_build_array(jsonb_build_object('material_id',:M,'qty',4,'over_ack',true))), 0);
select t.act_as('aaaaaaaa-0000-0000-0000-000000000001');
select t.eq(wh.approve_count((select count_id from wh.count_report
                               where material_id = :M::uuid and status='pending'), null) ->> 'status',
            'needs_review',
            'a pre-count movement that arrived later invalidates the basis instead of being applied');
select t.eq((select status from wh.count_report where material_id = :M::uuid
              and counted = 66), 'needs_review', 'and the report says so');
select t.ok((select jsonb_array_length(wh.count_basis_changes(count_id) -> 'late_events') = 1
               from wh.count_report where material_id = :M::uuid and counted = 66),
            'naming the event responsible');
select t.eq(wh.resolve_count((select count_id from wh.count_report where material_id = :M::uuid and counted = 66),
                             'recount', 'दोबारा गिनें') ->> 'status', 'recount',
            'the owner asks for a recount rather than applying a stale difference');

-- replacing a wrong baseline is the owner's, and keeps the original visible
select t.act_as('aaaaaaaa-0000-0000-0000-000000000002');
select t.raises(format($$select wh.supersede_opening(%L::uuid, 44, now(), 'ग़लत थी')$$, :M),
                'only the owner', 'staff cannot replace a baseline');
select t.act_as('aaaaaaaa-0000-0000-0000-000000000001');
select wh.supersede_opening(:M::uuid, 44, now() - interval '20 days', 'पहली गिनती में एक बंडल छूट गया था');
select t.eq((select count(*)::int from wh.opening where material_id = :M::uuid), 2,
            'the replaced baseline is still on the record');
select t.eq((select count(*)::int from wh.opening where material_id = :M::uuid and status='superseded'), 1,
            'marked superseded, with its reason');
reset role;
