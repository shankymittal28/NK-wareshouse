\set QUIET on
\set ON_ERROR_STOP on
-- Confirmed rows are never mutated. Every later change is an appended correction.
set role authenticated;
select t.act_as('aaaaaaaa-0000-0000-0000-000000000002');   -- Raj records everything here
\set A '''cccccccc-0000-0000-0000-000000000001'''
\set B '''cccccccc-0000-0000-0000-000000000002'''

select wh.record_opening(:A::uuid, 50, now() - interval '10 days');
select wh.record_opening(:B::uuid, 30, now() - interval '10 days');
select wh.submit_event(jsonb_build_object('draft_id','d0000000-0000-0000-0000-0000000000c1',
  'event_type','IN','effective_at',(now() - interval '2 days')::text,'counterparty','Zangi Transport',
  'lines', jsonb_build_array(
    jsonb_build_object('line_id','11110000-0000-0000-0000-0000000000c1','material_id',:A,'qty',50),
    jsonb_build_object('line_id','11110000-0000-0000-0000-0000000000c2','material_id',:A,'qty',10))), 0);
select t.eq(wh.stock_as_of(:A::uuid), 110::numeric, 'starting point: 50 + 50 + 10');

-- 1. quantity
select wh.correct_line('11110000-0000-0000-0000-0000000000c1','टाइप की गलती', null, 20, null);
select t.eq(wh.stock_as_of(:A::uuid), 80::numeric, 'a quantity correction moves the stock');
select t.eq((select qty from wh.event_line where line_id='11110000-0000-0000-0000-0000000000c1'), 50::numeric,
            'the confirmed row still says 50: history was not rewritten');

-- 2. wrong material: one fact, read two ways
select wh.correct_line('11110000-0000-0000-0000-0000000000c2','गलत माल', :B::uuid, null, null);
select t.eq(wh.stock_as_of(:A::uuid), 70::numeric, 'the first material loses the quantity');
select t.eq(wh.stock_as_of(:B::uuid), 40::numeric, 'the second material gains it, in the same fact');
select t.eq((select count(*)::int from wh.line_correction
              where line_id='11110000-0000-0000-0000-0000000000c2'), 1,
            'one correction row did both halves, so they cannot disagree');
select t.eq((select material_id from wh.event_line where line_id='11110000-0000-0000-0000-0000000000c2'), :A::uuid,
            'the confirmed line still names the original material');
select t.eq((select count(*)::int from wh.trail(:B::uuid)
              where (detail ->> 'moved_here_by_correction')::boolean), 1,
            'the receiving material shows where the quantity came from');

-- 3. a line noticed afterwards
select wh.add_line('d0000000-0000-0000-0000-0000000000c1', :A::uuid, 7, 'छूट गई थी');
select t.eq(wh.stock_as_of(:A::uuid), 77::numeric, 'an added line joins the same movement');
select t.eq((select count(*)::int from wh.event_line
              where event_id='d0000000-0000-0000-0000-0000000000c1' and added_at is not null), 1,
            'and is visibly marked as added later');

-- 4. voiding a line added by mistake
select wh.correct_line((select line_id from wh.event_line
                         where event_id='d0000000-0000-0000-0000-0000000000c1' and added_at is not null),
                       'ग़लती से जोड़ी', null, null, true);
select t.eq(wh.stock_as_of(:A::uuid), 70::numeric, 'voiding removes its effect');
select t.eq((select count(*)::int from wh.event_line
              where event_id='d0000000-0000-0000-0000-0000000000c1'), 3,
            'the voided line is still on the record');

-- 5. the physical time was wrong
select wh.correct_event('d0000000-0000-0000-0000-0000000000c1','तारीख़ ग़लत थी',
                        jsonb_build_object('effective_at',(now() - interval '11 days')::text));
select t.eq(wh.stock_as_of(:A::uuid), 50::numeric,
            'moving the movement before the baseline takes it out of the arithmetic');
select wh.correct_event('d0000000-0000-0000-0000-0000000000c1','वापस सही तारीख़',
                        jsonb_build_object('effective_at',(now() - interval '2 days')::text));
select t.eq(wh.stock_as_of(:A::uuid), 70::numeric, 'and correcting it again restores the position');

-- 6. direction is owner-only, and flips the whole event at once
select t.raises($$select wh.correct_event('d0000000-0000-0000-0000-0000000000c1','दिशा ग़लत',
                   '{"event_type":"OUT"}'::jsonb)$$,
                'only the owner', 'staff cannot reverse the direction of a recorded movement');
select t.act_as('aaaaaaaa-0000-0000-0000-000000000001');   -- owner
select wh.correct_event('d0000000-0000-0000-0000-0000000000c1','यह माल गया था, आया नहीं',
                        '{"event_type":"OUT"}'::jsonb);
select t.eq(wh.stock_as_of(:A::uuid), 30::numeric, 'the owner reverses it and every line flips together');
select t.eq(wh.stock_as_of(:B::uuid), 20::numeric, 'including the line that had been moved to another material');
select t.eq((select event_type from wh.stock_event where event_id='d0000000-0000-0000-0000-0000000000c1'), 'IN',
            'and the confirmed event still records what was originally entered');

-- corrections need a reason, and strangers cannot make them
select t.raises($$select wh.correct_line('11110000-0000-0000-0000-0000000000c1','', null, 5, null)$$,
                'needs a reason', 'a correction without a reason is refused');
select t.act_as('aaaaaaaa-0000-0000-0000-000000000003');   -- Suresh, not the recorder
select t.raises($$select wh.correct_line('11110000-0000-0000-0000-0000000000c1','कुछ', null, 5, null)$$,
                'only the person who recorded', 'someone else cannot correct another person''s record');
reset role;
