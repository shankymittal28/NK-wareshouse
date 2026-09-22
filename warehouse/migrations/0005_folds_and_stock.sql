-- 0005  the two folds, and stock computed from them
-- Stock is never an accumulator. It is a query over the effective state of each line,
-- which is why a correction that moves a line between materials cannot half-apply.

-- ---------------------------------------------------------------- folds, as of a moment
-- p_known_at answers "using only what NK had received by then".
create or replace function wh.line_effective_as_of(p_known_at timestamptz)
returns table(line_id uuid, event_id uuid, material_id uuid, qty numeric, voided boolean, is_added boolean)
language sql stable as $$
  select l.line_id, l.event_id,
    coalesce((select c.new_material_id from wh.line_correction c
               where c.line_id = l.line_id and c.new_material_id is not null and c.at <= p_known_at
               order by c.seq desc limit 1), l.material_id),
    coalesce((select c.new_qty from wh.line_correction c
               where c.line_id = l.line_id and c.new_qty is not null and c.at <= p_known_at
               order by c.seq desc limit 1), l.qty),
    coalesce((select c.new_voided from wh.line_correction c
               where c.line_id = l.line_id and c.new_voided is not null and c.at <= p_known_at
               order by c.seq desc limit 1), false),
    (l.added_at is not null)
  from wh.event_line l
  where l.added_at is null or l.added_at <= p_known_at
$$;

create or replace function wh.event_effective_as_of(p_known_at timestamptz)
returns table(event_id uuid, event_type text, effective_at timestamptz,
              handler_person_id uuid, counterparty text, kind text, vehicle text,
              ref_type text, ref_number text, ref_date date, no_paper boolean, notes text,
              server_received_at timestamptz, recorder_person_id uuid)
language sql stable as $$
  select e.event_id,
    coalesce((select c.new_event_type from wh.event_correction c
               where c.event_id = e.event_id and c.new_event_type is not null and c.at <= p_known_at
               order by c.seq desc limit 1), e.event_type),
    coalesce((select c.new_effective_at from wh.event_correction c
               where c.event_id = e.event_id and c.new_effective_at is not null and c.at <= p_known_at
               order by c.seq desc limit 1), e.effective_at),
    coalesce((select c.new_handler_person_id from wh.event_correction c
               where c.event_id = e.event_id and c.new_handler_person_id is not null and c.at <= p_known_at
               order by c.seq desc limit 1), e.handler_person_id),
    coalesce((select c.new_counterparty from wh.event_correction c
               where c.event_id = e.event_id and c.new_counterparty is not null and c.at <= p_known_at
               order by c.seq desc limit 1), e.counterparty),
    coalesce((select c.new_kind from wh.event_correction c
               where c.event_id = e.event_id and c.new_kind is not null and c.at <= p_known_at
               order by c.seq desc limit 1), e.kind),
    coalesce((select c.new_vehicle from wh.event_correction c
               where c.event_id = e.event_id and c.new_vehicle is not null and c.at <= p_known_at
               order by c.seq desc limit 1), e.vehicle),
    coalesce((select c.new_ref_type from wh.event_correction c
               where c.event_id = e.event_id and c.new_ref_type is not null and c.at <= p_known_at
               order by c.seq desc limit 1), e.ref_type),
    coalesce((select c.new_ref_number from wh.event_correction c
               where c.event_id = e.event_id and c.new_ref_number is not null and c.at <= p_known_at
               order by c.seq desc limit 1), e.ref_number),
    coalesce((select c.new_ref_date from wh.event_correction c
               where c.event_id = e.event_id and c.new_ref_date is not null and c.at <= p_known_at
               order by c.seq desc limit 1), e.ref_date),
    coalesce((select c.new_no_paper from wh.event_correction c
               where c.event_id = e.event_id and c.new_no_paper is not null and c.at <= p_known_at
               order by c.seq desc limit 1), e.no_paper),
    coalesce((select c.new_notes from wh.event_correction c
               where c.event_id = e.event_id and c.new_notes is not null and c.at <= p_known_at
               order by c.seq desc limit 1), e.notes),
    e.server_received_at, e.recorder_person_id
  from wh.stock_event e
  where e.server_received_at <= p_known_at
$$;

-- Current effective state: everything NK holds now.
create view wh.line_effective as select * from wh.line_effective_as_of('infinity'::timestamptz);
create view wh.event_effective as select * from wh.event_effective_as_of('infinity'::timestamptz);

create or replace function wh.line_sign(p_event_type text) returns int
language sql immutable strict as $$ select case p_event_type when 'OUT' then -1 else 1 end $$;

-- ---------------------------------------------------------------- stock
-- Physical chronology decides what counts. p_physical_at bounds the goods' own timeline;
-- p_known_at bounds what NK had been told. Returns NULL when the material has no baseline.
create or replace function wh.stock_as_of(p_material_id uuid,
                                          p_physical_at timestamptz default 'infinity',
                                          p_known_at timestamptz default 'infinity')
returns numeric language sql stable as $$
  with o as (
    select opening_id, counted, effective_at
      from wh.opening
     where material_id = p_material_id
       and recorded_at <= p_known_at
       and (superseded_at is null or superseded_at > p_known_at)
       and effective_at <= p_physical_at
     order by recorded_at desc
     limit 1
  )
  select o.counted + coalesce((
      select sum(wh.line_sign(e.event_type) * le.qty)
        from wh.line_effective_as_of(p_known_at) le
        join wh.event_effective_as_of(p_known_at) e on e.event_id = le.event_id
       where le.material_id = p_material_id
         and not le.voided
         and e.effective_at >  o.effective_at
         and e.effective_at <= p_physical_at
    ), 0)
  from o
$$;

-- ---------------------------------------------------------------- catalogue-wide views
create view wh.opening_active as
  select * from wh.opening where status = 'active';

create view wh.legacy_expected as
  select material_id,
         sum(case direction when 'in' then qty else -qty end) as expected_qty,
         count(*) as legacy_lines,
         min(occurred_at) as first_seen,
         max(occurred_at) as last_seen
    from wh.legacy_line
   group by material_id;

create view wh.material_stock as
  with mov as (
    select le.material_id,
           sum(wh.line_sign(e.event_type) * le.qty) as delta
      from wh.line_effective le
      join wh.event_effective e on e.event_id = le.event_id
      join wh.opening_active o  on o.material_id = le.material_id
     where not le.voided
       and e.effective_at > o.effective_at
     group by le.material_id
  )
  select m.material_id,
         m.category_code,
         wh.material_name(m.material_id) as material_name,
         m.unit_code, m.decimals,
         (o.opening_id is not null) as has_opening,
         o.counted     as opening_counted,
         o.effective_at as opening_effective_at,
         o.by_person_id as opening_by_person_id,
         case when o.opening_id is null then null
              else o.counted + coalesce(mov.delta, 0) end as recorded_qty,
         le.expected_qty as legacy_expected_qty,
         m.active,
         m.origin
    from wh.material m
    left join wh.opening_active o on o.material_id = m.material_id
    left join mov on mov.material_id = m.material_id
    left join wh.legacy_expected le on le.material_id = m.material_id;
comment on view wh.material_stock is
  'recorded_qty is NULL until a physical opening count exists. legacy_expected_qty is the old system''s net, shown as an expectation only.';

-- Money. Readable only by the owner, because wh.rate is owner-only under its policy.
create view wh.material_value as
  select ms.material_id, ms.material_name, ms.category_code, ms.recorded_qty,
         r.rate, round(ms.recorded_qty * r.rate, 2) as value
    from wh.material_stock ms
    join wh.rate r on r.material_id = ms.material_id
   where ms.recorded_qty is not null
     and wh.is_owner();

-- Wrapped so that a caller who may not see money gets no row at all, rather than a row of
-- zeros that could be mistaken for "nothing is stocked".
create view wh.valuation_coverage as
  select * from (
    select count(*) filter (where ms.recorded_qty is not null and ms.recorded_qty <> 0) as stocked_materials,
           count(*) filter (where ms.recorded_qty is not null and ms.recorded_qty <> 0 and r.rate is not null) as rated_materials,
           coalesce(sum(round(ms.recorded_qty * r.rate, 2))
                    filter (where ms.recorded_qty is not null and r.rate is not null), 0) as rated_value,
           count(*) filter (where not ms.has_opening) as materials_without_opening
      from wh.material_stock ms
      left join wh.rate r on r.material_id = ms.material_id
  ) c where wh.is_owner();

-- ---------------------------------------------------------------- trail
-- Why a material shows this quantity. Legacy rows sit below the baseline and are marked
-- as not counted, because they come from a table the arithmetic never reads.
create or replace function wh.trail(p_material_id uuid)
returns table(kind text, at timestamptz, delta numeric, running numeric,
              label text, detail jsonb, event_id uuid, counts boolean)
language sql stable as $$
  with o as (select * from wh.opening_active where material_id = p_material_id),
  legacy as (
    select 'legacy'::text as kind, l.occurred_at as at,
           (case l.direction when 'in' then l.qty else -l.qty end) as delta,
           coalesce(l.counterparty,'') as label,
           jsonb_build_object('recorded_by_name', l.recorded_by_name,
                              'photos', (select count(*) from wh.legacy_photo p where p.legacy_id = l.legacy_id),
                              'suspect_duplicate', l.suspect_duplicate_of is not null) as detail,
           null::uuid as event_id, false as counts
      from wh.legacy_line l where l.material_id = p_material_id
  ),
  opening as (
    select 'opening'::text, o.effective_at, o.counted, 'opening count'::text,
           jsonb_build_object('by', p.display_name, 'legacy_expected', o.legacy_expected),
           null::uuid, true
      from o join wh.person p on p.person_id = o.by_person_id
  ),
  moves as (
    select case e.event_type when 'ADJUSTMENT' then 'adjustment' else lower(e.event_type) end,
           e.effective_at,
           wh.line_sign(e.event_type) * le.qty,
           coalesce(e.counterparty, '') ,
           jsonb_build_object(
             'ref', nullif(concat_ws(' ', e.ref_type, e.ref_number), ''),
             'handler', (select display_name from wh.person where person_id = e.handler_person_id),
             'recorder', (select display_name from wh.person where person_id = e.recorder_person_id),
             'received_by_nk', e.server_received_at,
             'photos', (select count(*) from wh.evidence v where v.event_id = e.event_id),
             'corrections', (select coalesce(jsonb_agg(jsonb_build_object(
                                 'from_qty', c.new_qty is not null,
                                 'reason', c.reason,
                                 'at', c.at) order by c.seq), '[]'::jsonb)
                               from wh.line_correction c where c.line_id = le.line_id),
             'moved_here_by_correction',
               exists (select 1 from wh.line_correction c
                        where c.line_id = le.line_id and c.new_material_id = p_material_id),
             'late_pre_baseline', (o.effective_at is not null and e.effective_at <= o.effective_at)
           ),
           e.event_id, (o.effective_at is not null and e.effective_at > o.effective_at)
      from wh.line_effective le
      join wh.event_effective e on e.event_id = le.event_id
      left join o on true
     where le.material_id = p_material_id and not le.voided
  ),
  all_rows as (
    select * from legacy union all select * from opening union all select * from moves
  )
  select kind, at, delta,
         sum(case when counts then delta else 0 end) over (order by at, kind rows unbounded preceding) as running,
         label, detail, event_id, counts
    from all_rows
   order by at, kind
$$;

-- ---------------------------------------------------------------- review lists
-- Identities that look alike after normalising case, spaces and punctuation. Sharing a
-- group is an observation, never a decision: nothing here merges anything. A cancelling
-- pair of in and out quantities is suggestive and is shown, but it is not evidence.
create view wh.possible_same_material as
  select m.possible_same_group as group_id,
         m.category_code,
         m.material_id,
         wh.material_name(m.material_id) as material_name,
         m.norm_key,
         coalesce(le.expected_qty, 0) as legacy_expectation,
         coalesce(le.legacy_lines, 0) as legacy_lines,
         le.first_seen, le.last_seen,
         (select string_agg(distinct l.recorded_by_name, '/')
            from wh.legacy_line l where l.material_id = m.material_id) as recorded_by
    from wh.material m
    left join wh.legacy_expected le on le.material_id = m.material_id
   where m.possible_same_group is not null;
comment on view wh.possible_same_material is
  'A review list for a person. Membership means the spellings normalise alike, nothing more.';

create view wh.incomplete_identity as
  select m.material_id,
         wh.material_name(m.material_id) as material_name,
         m.category_code, m.missing_attrs,
         coalesce(le.legacy_lines, 0) as legacy_lines,
         coalesce(le.expected_qty, 0) as legacy_expectation,
         le.first_seen, le.last_seen,
         (select string_agg(distinct l.recorded_by_name, '/')
            from wh.legacy_line l where l.material_id = m.material_id) as recorded_by
    from wh.material m
    left join wh.legacy_expected le on le.material_id = m.material_id
   where m.identity_incomplete;
