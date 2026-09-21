-- Reconciliation: for every legacy identity, what the old app would calculate against what
-- the import produced. A row here is a difference that must be explained before Stage 1.
\pset pager off
\echo '--- totals ---'
select (select count(*) from src.nkg_stock)                                as source_rows,
       (select count(*) from wh.legacy_line)                               as imported_lines,
       (select count(*) from wh_import.exception where source_row_id is not null) as parked_rows,
       (select count(*) from wh_import.identity_map)                       as source_identities,
       (select count(*) from wh.material where origin='legacy_import')     as materials_created,
       (select count(*) from wh.material where needs_naming)               as materials_needing_a_name,
       (select count(*) from wh.legacy_photo)                              as photos_linked,
       (select count(*) from wh.rate)                                      as rates_mapped,
       (select count(*) from wh_import.exception where reason='rate key matches no identity') as rates_unmatched,
       (select count(*) from wh.legacy_line where suspect_duplicate_of is not null) as suspect_duplicates;

\echo '--- expectation per identity: old app rule vs imported history ---'
select count(*) filter (where old_net is distinct from new_net) as mismatched_identities,
       count(*)                                                 as identities_compared,
       sum(old_net)                                             as old_total,
       sum(new_net)                                             as new_total,
       count(*) filter (where new_net < 0)                      as identities_negative
  from (
    select im.source_key, im.src_net as old_net, coalesce(le.expected_qty, 0) as new_net
      from wh_import.identity_map im
      left join wh.legacy_expected le on le.material_id = im.material_id
  ) x;

\echo '--- every mismatch, if any ---'
select im.source_key, im.src_net as old_expectation, coalesce(le.expected_qty,0) as new_expectation,
       im.src_rows, (select count(*) from wh.legacy_line l where l.material_id = im.material_id) as imported_rows
  from wh_import.identity_map im
  left join wh.legacy_expected le on le.material_id = im.material_id
 where im.src_net is distinct from coalesce(le.expected_qty, 0)
 order by 1;

\echo '--- parked rows, if any ---'
select reason, count(*) from wh_import.exception group by 1 order by 1;

\echo '--- legacy history cannot reach stock ---'
select count(*) as materials_with_legacy_but_no_baseline,
       count(*) filter (where wh.stock_as_of(material_id) is not null) as any_with_a_stock_figure
  from wh.material where origin = 'legacy_import';
