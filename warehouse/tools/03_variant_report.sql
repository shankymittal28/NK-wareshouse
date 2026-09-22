-- Look-alike identities, for the owner to decide. Nothing is merged by this script.
-- Two identities appear together only because normalising case, spaces and hyphens makes
-- them look alike. They stay separate until a person confirms they are the same goods.
\pset pager off
select m.category_code,
       m.norm_key                                    as looks_like,
       string_agg(distinct wh.material_name(m.material_id), '   ||   ') as exact_values,
       count(*)                                      as identities,
       (select count(*) from wh.legacy_line l where l.material_id = any(array_agg(m.material_id))) as old_lines,
       array_agg(coalesce(le.expected_qty,0) order by wh.material_name(m.material_id)) as expectation_each,
       min(le.first_seen)::date                      as first_seen,
       max(le.last_seen)::date                       as last_seen
  from wh.material m
  left join wh.legacy_expected le on le.material_id = m.material_id
 group by m.category_code, m.norm_key
having count(*) > 1
 order by 1, 2;
