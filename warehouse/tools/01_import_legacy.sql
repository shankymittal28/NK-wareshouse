-- Deterministic legacy import. Reads a staging copy of the old table in schema `src`
-- and produces materials, legacy history and rates in `wh`. Running it twice produces
-- exactly the same identities and the same rows.
--
--   psql -f tools/01_import_legacy.sql
--
-- It never writes to the old system, and the rows it creates are structurally outside
-- stock arithmetic: the stock calculation reads events, never wh.legacy_line.

create schema if not exists wh_import;

-- The godown keeps working while this runs, so the import is always against a frozen
-- snapshot, recorded here. A later run against a newer snapshot is a different fact.
create table if not exists wh_import.snapshot(
  snapshot_id uuid primary key default gen_random_uuid(),
  taken_at    timestamptz not null default now(),
  source_rows int not null,
  source_max_created_at timestamptz,
  note        text);
insert into wh_import.snapshot(source_rows, source_max_created_at, note)
select count(*), max(created_at), 'staged copy in schema src' from src.nkg_stock;

-- old app's grouping key, reproduced exactly: category|brand|thickness|size|design
create or replace function wh_import.source_key(p_category text, p_brand text, p_thickness text,
                                                p_size text, p_design text)
returns text language sql immutable as $$
  select concat_ws('|', coalesce(p_category,''), coalesce(p_brand,''), coalesce(p_thickness,''),
                        coalesce(p_size,''), coalesce(p_design,''))
$$;

-- old category -> warehouse category, and which old column feeds which attribute
create table if not exists wh_import.category_map(
  src_category text primary key, category_code text not null);
insert into wh_import.category_map(src_category, category_code) values
  ('Plywood','Plywood'), ('Door','Doors')
on conflict do nothing;

drop table if exists wh_import.identity_map;
create table wh_import.identity_map(
  source_key    text primary key,
  category_code text not null,
  attrs         jsonb not null,
  identity_key  text not null,
  material_id   uuid not null,
  identity_incomplete boolean not null default false,
  missing_attrs text[] not null default '{}',
  src_rows      int not null,
  src_net       numeric(18,4) not null
);

drop table if exists wh_import.exception;
create table wh_import.exception(
  source_row_id uuid, reason text, detail jsonb);

-- rows whose old category has no mapping are parked, never guessed
insert into wh_import.exception(source_row_id, reason, detail)
select s.id, 'unmapped category', jsonb_build_object('category', s.category)
  from src.nkg_stock s
 where not exists (select 1 from wh_import.category_map m where m.src_category = s.category);

-- one identity per distinct old grouping key
insert into wh_import.identity_map(source_key, category_code, attrs, identity_key, material_id,
                                   identity_incomplete, missing_attrs, src_rows, src_net)
with rows as (
  select s.*, m.category_code
    from src.nkg_stock s
    join wh_import.category_map m on m.src_category = s.category
),
keyed as (
  select wh_import.source_key(category, brand, thickness, size, design) as source_key,
         category_code,
         case category_code
           when 'Plywood' then jsonb_build_object(
             'brand',     coalesce(nullif(btrim(brand),''), '(not recorded)'),
             'thickness', coalesce(nullif(btrim(thickness),''), '(not recorded)'),
             'size',      coalesce(nullif(btrim(size),''), '(not recorded)'))
           when 'Doors' then jsonb_build_object(
             'variety',   coalesce(nullif(btrim(brand),''), '(not recorded)'),
             'design',    coalesce(nullif(btrim(design),''), '(not recorded)'),
             'size',      coalesce(nullif(btrim(size),''), '(not recorded)'))
         end as attrs,
         qty, direction
    from rows
),
agg as (
  select source_key, category_code, (array_agg(attrs))[1] as attrs,
         count(*)::int as src_rows,
         sum(case direction when 'in' then qty else -qty end) as src_net
    from keyed group by source_key, category_code
)
select a.source_key, a.category_code, a.attrs,
       wh.exact_join((select array_agg(btrim(coalesce(a.attrs ->> ca.attr_key,'')) order by ca.seq)
                        from wh.category_attribute ca where ca.category_code = a.category_code)),
       -- deterministic identity: the same tuple always maps to the same material
       md5(a.category_code || '|' ||
           wh.exact_join((select array_agg(btrim(coalesce(a.attrs ->> ca.attr_key,'')) order by ca.seq)
                            from wh.category_attribute ca where ca.category_code = a.category_code)))::uuid,
       -- which required attribute the old row never carried; no value is ever invented
       cardinality(miss.attrs) > 0, miss.attrs, a.src_rows, a.src_net
  from agg a
  cross join lateral (
    select coalesce(array_agg(ca.attr_key order by ca.seq), '{}'::text[]) as attrs
      from wh.category_attribute ca
     where ca.category_code = a.category_code
       and btrim(coalesce(a.attrs ->> ca.attr_key, '')) = '(not recorded)'
  ) miss;

-- If the warehouse already holds a material with this exact identity, that one is used.
-- Otherwise the deterministic id is created, so a re-run produces the same identities.
update wh_import.identity_map im
   set material_id = m.material_id
  from wh.material m
 where m.category_code = im.category_code
   and m.identity_key = im.identity_key
   and m.material_id <> im.material_id;

insert into wh.material(material_id, category_code, attrs, origin, identity_incomplete, missing_attrs)
select im.material_id, im.category_code, im.attrs, 'legacy_import', im.identity_incomplete, im.missing_attrs
  from wh_import.identity_map im
 where not exists (select 1 from wh.material m where m.material_id = im.material_id)
on conflict (category_code, identity_key) do nothing;

-- every attribute value the old system used becomes a pickable value
insert into wh.attribute_value(category_code, attr_key, value)
select distinct im.category_code, ca.attr_key, btrim(im.attrs ->> ca.attr_key)
  from wh_import.identity_map im
  join wh.category_attribute ca on ca.category_code = im.category_code
 where btrim(coalesce(im.attrs ->> ca.attr_key,'')) <> ''
on conflict (category_code, attr_key, value) do nothing;

-- the history itself
insert into wh.legacy_line(legacy_id, source_row_id, material_id, category_code, attrs, qty,
                           direction, counterparty, zone, recorded_by_name, occurred_at)
select md5('legacy:' || s.id::text)::uuid, s.id, im.material_id, im.category_code, im.attrs,
       s.qty, s.direction,
       coalesce(nullif(btrim(s.source_godown),''), nullif(btrim(s.customer),'')),
       nullif(btrim(s.zone_name),''), nullif(btrim(s.logged_by),''), s.created_at
  from src.nkg_stock s
  join wh_import.category_map cm on cm.src_category = s.category
  join wh_import.identity_map im
    on im.source_key = wh_import.source_key(s.category, s.brand, s.thickness, s.size, s.design)
on conflict (source_row_id) do nothing;

-- photographs stay with the old line, never with an event
insert into wh.legacy_photo(legacy_photo_id, legacy_id, bucket_path, original_url)
select md5('legacyphoto:' || s.id::text || ':' || p.ord::text)::uuid,
       md5('legacy:' || s.id::text)::uuid,
       'legacy/' || regexp_replace(p.url, '^.*/nkg-photos/', ''),
       p.url
  from src.nkg_stock s
  cross join lateral (
      select url, ord from jsonb_array_elements_text(coalesce(s.photos,'[]'::jsonb)) with ordinality as x(url, ord)
      union
      select s.photo_url, 0 where nullif(btrim(coalesce(s.photo_url,'')),'') is not null
  ) p
 where exists (select 1 from wh.legacy_line l where l.source_row_id = s.id)
   and nullif(btrim(coalesce(p.url,'')),'') is not null
on conflict do nothing;

-- movements that look like an accidental double tap are flagged, never removed
update wh.legacy_line a
   set suspect_duplicate_of = b.legacy_id
  from wh.legacy_line b
 where a.legacy_id <> b.legacy_id
   and a.material_id = b.material_id and a.qty = b.qty and a.direction = b.direction
   and a.recorded_by_name is not distinct from b.recorded_by_name
   and abs(extract(epoch from a.occurred_at - b.occurred_at)) < 120
   and a.occurred_at > b.occurred_at
   and a.suspect_duplicate_of is null;

-- Identities that look alike once case, spaces and punctuation are ignored are grouped
-- for a person to review. NOTHING is merged here. A cancelling pair of in and out
-- quantities is suggestive, and is shown in the review list, but it is not evidence:
-- punctuation, a cancelling pair and a normalised match are each, alone, not a reason.
update wh.material m
   set possible_same_group = g.group_id
  from (select category_code, norm_key,
               md5('possible_same:' || category_code || '|' || norm_key)::uuid as group_id
          from wh.material
         group by category_code, norm_key
        having count(*) > 1) g
 where m.category_code = g.category_code
   and m.norm_key = g.norm_key
   and m.possible_same_group is distinct from g.group_id;

-- the owner's valuation rates, keyed the same way the old app keyed them
insert into wh.rate(material_id, rate, set_by_person_id)
select im.material_id, r.rate, (select person_id from wh.person where role='owner' order by created_at limit 1)
  from src.nkg_rates r
  join wh_import.identity_map im on im.source_key = r.k
 where r.rate > 0
on conflict (material_id) do nothing;

insert into wh_import.exception(source_row_id, reason, detail)
select null, 'rate key matches no identity', jsonb_build_object('k', r.k, 'rate', r.rate)
  from src.nkg_rates r
 where not exists (select 1 from wh_import.identity_map im where im.source_key = r.k);
