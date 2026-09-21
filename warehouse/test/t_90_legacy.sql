\set QUIET on
\set ON_ERROR_STOP on
-- Old history is copied in as history. It is structurally incapable of becoming stock.
\set M '''cccccccc-0000-0000-0000-000000000001'''

insert into wh.legacy_line(source_row_id, material_id, category_code, attrs, qty, direction,
                           counterparty, recorded_by_name, occurred_at)
values ('99990000-0000-0000-0000-000000000001', :M::uuid, 'Plywood',
        '{"brand":"Century","thickness":"18mm","size":"8x4"}', 15, 'in', 'दुकान', 'अर्जुन',
        now() - interval '40 days'),
       ('99990000-0000-0000-0000-000000000002', :M::uuid, 'Plywood',
        '{"brand":"Century","thickness":"18mm","size":"8x4"}', 5, 'out', 'Om Furniture', 'सुरेश',
        now() - interval '35 days');
insert into wh.legacy_photo(legacy_id, bucket_path, original_url)
select legacy_id, 'legacy/2026-08-12/bilty-1.jpg', 'https://old/storage/v1/object/public/nkg-photos/x.jpg'
  from wh.legacy_line where source_row_id = '99990000-0000-0000-0000-000000000001';

select t.eq((select expected_qty from wh.legacy_expected where material_id = :M::uuid), 10::numeric,
            'the old system''s net becomes an expectation of 10');
select t.eq(wh.stock_as_of(:M::uuid), null::numeric,
            'with no physical count yet, recorded stock is honestly unknown, not 10');

set role authenticated;
select t.act_as('aaaaaaaa-0000-0000-0000-000000000002');
select wh.record_opening(:M::uuid, 8, now() - interval '1 day');
select t.eq(wh.stock_as_of(:M::uuid), 8::numeric,
            'the physical count is the baseline; the old net does not add to it');
select t.eq((select legacy_expected from wh.opening where material_id = :M::uuid), 10::numeric,
            'what the old records expected is kept beside it for comparison');

select t.eq((select count(*)::int from wh.trail(:M::uuid) where kind = 'legacy'), 2,
            'the old lines are visible in the trail');
select t.eq((select count(*)::int from wh.trail(:M::uuid) where kind = 'legacy' and counts), 0,
            'and none of them counts towards the quantity');
select t.eq((select (detail ->> 'recorded_by_name') from wh.trail(:M::uuid)
              where kind = 'legacy' order by at limit 1), 'अर्जुन',
            'their recorder stays a plain name, because those writes were never authenticated');
select t.eq((select (detail ->> 'photos')::int from wh.trail(:M::uuid)
              where kind = 'legacy' order by at limit 1), 1,
            'their photographs are attached to the old line, not to any event');
reset role;

-- the separation is structural, not a convention
select t.eq((select count(*)::int
               from pg_depend d
               join pg_rewrite r on r.oid = d.objid
               join pg_class v on v.oid = r.ev_class
               join pg_class src on src.oid = d.refobjid
              where v.relname in ('material_stock','line_effective','event_effective')
                and src.relname in ('legacy_line','legacy_photo')), 0,
            'no view behind stock arithmetic reads the legacy tables at all');
select t.eq((select count(*)::int from pg_proc p
              where p.proname in ('stock_as_of','line_effective_as_of','event_effective_as_of')
                and p.prosrc like '%legacy%'), 0,
            'and no stock function mentions them either');
