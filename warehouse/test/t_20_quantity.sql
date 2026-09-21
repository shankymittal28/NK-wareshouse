\set QUIET on
\set ON_ERROR_STOP on
-- Exact decimals, with permitted precision belonging to the material, enforced at the
-- table guard as well as in the write path.
select t.raises($$insert into wh.stock_event(event_id,event_type,effective_at,confirmed_at,recorder_person_id,device_id)
                  values ('eeee0000-0000-0000-0000-00000000f001','IN',now(),now(),
                          '22222222-2222-2222-2222-222222222222','dddddddd-0000-0000-0000-000000000002');
                  insert into wh.event_line(line_id,event_id,line_no,material_id,qty)
                  values (gen_random_uuid(),'eeee0000-0000-0000-0000-00000000f001',1,
                          'cccccccc-0000-0000-0000-000000000001',1.5)$$,
                'more precision', 'a whole-sheet material refuses a fractional quantity, even by direct insert');

insert into wh.stock_event(event_id,event_type,effective_at,confirmed_at,recorder_person_id,device_id)
 values ('eeee0000-0000-0000-0000-00000000f002','IN',now(),now(),
         '22222222-2222-2222-2222-222222222222','dddddddd-0000-0000-0000-000000000002');
insert into wh.event_line(line_id,event_id,line_no,material_id,qty)
 values (gen_random_uuid(),'eeee0000-0000-0000-0000-00000000f002',1,
         'cccccccc-0000-0000-0000-000000000005',146.25);
select t.ok(true, 'a two-decimal material accepts 146.25');

select t.raises($$insert into wh.event_line(line_id,event_id,line_no,material_id,qty)
                  values (gen_random_uuid(),'eeee0000-0000-0000-0000-00000000f002',2,
                          'cccccccc-0000-0000-0000-000000000005',146.255)$$,
                'more precision', 'a two-decimal material refuses three decimals');

-- exact arithmetic end to end on a fractional category
select wh.record_opening('cccccccc-0000-0000-0000-000000000005', 100.10, now() - interval '2 days')
  from (select t.act_as('aaaaaaaa-0000-0000-0000-000000000002')) x;
insert into wh.stock_event(event_id,event_type,effective_at,confirmed_at,recorder_person_id,device_id)
 values ('eeee0000-0000-0000-0000-00000000f003','IN',now() - interval '1 day',now(),
         '22222222-2222-2222-2222-222222222222','dddddddd-0000-0000-0000-000000000002');
insert into wh.event_line(line_id,event_id,line_no,material_id,qty) values
 (gen_random_uuid(),'eeee0000-0000-0000-0000-00000000f003',1,'cccccccc-0000-0000-0000-000000000005',0.10),
 (gen_random_uuid(),'eeee0000-0000-0000-0000-00000000f003',2,'cccccccc-0000-0000-0000-000000000005',0.20);
-- 100.10 baseline + 146.25 + 0.10 + 0.20. In floating point the last two would land on
-- 0.30000000000000004; in exact numeric the total is 246.65 and nothing drifts.
select t.eq(wh.stock_as_of('cccccccc-0000-0000-0000-000000000005'), 246.65::numeric,
            'fractional quantities sum exactly, with no floating-point drift');
select t.ok(wh.stock_as_of('cccccccc-0000-0000-0000-000000000005')::text = '246.6500',
            'the stored total keeps its declared scale');

-- No floating point anywhere in what is stored.
select t.eq((select count(*)::int from information_schema.columns
              where table_schema='wh' and data_type in ('double precision','real')), 0,
            'no floating-point column exists in the warehouse schema');
select t.eq((select count(*)::int from information_schema.columns
              where table_schema='wh'
                and column_name in ('qty','counted','rate','recorded_at_count','legacy_expected','step')
                and data_type <> 'numeric'), 0,
            'every quantity and rate column is exact numeric');
