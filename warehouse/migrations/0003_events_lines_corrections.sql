-- 0003  confirmed movements, their lines, and append-only corrections
-- Confirmed rows are never updated. Every later change is a correction row.

create table wh.stock_event (
  event_id        uuid primary key,            -- minted on the device; also the draft id
  event_type      text not null check (event_type in ('IN','OUT','ADJUSTMENT')),
  -- three clocks, three jobs
  effective_at    timestamptz not null,        -- when the goods physically moved  -> arithmetic and history
  confirmed_at    timestamptz not null,        -- when the person completed it
  -- when NK accepted it -> sync and audit only. clock_timestamp(), not now():
  -- now() is fixed for a whole transaction, which would make two acceptances in
  -- one transaction indistinguishable and break "arrived after" comparisons.
  server_received_at timestamptz not null default clock_timestamp(),
  device_claimed_at  timestamptz,              -- raw device clock, kept for diagnosis
  backdated_reason   text,
  recorder_person_id uuid not null references wh.person(person_id),
  handler_person_id  uuid references wh.person(person_id),
  -- null when the owner acts through his Supabase session rather than a phone,
  -- as when he approves a count and the system places the adjustment. The
  -- recorder is always known; the device is not always there to be known.
  device_id       uuid references wh.device(device_id),
  counterparty    text,                        -- source for IN, destination for OUT
  kind            text,
  vehicle         text,
  ref_type        text,
  ref_number      text,
  ref_date        date,
  no_paper        boolean not null default false,
  notes           text,
  adjustment_of_count_id uuid,
  created_from_draft_rev int
);
create index stock_event_effective_idx on wh.stock_event(effective_at);
create index stock_event_received_idx  on wh.stock_event(server_received_at);
create index stock_event_recorder_idx  on wh.stock_event(recorder_person_id, effective_at);

create table wh.event_line (
  line_id      uuid primary key,               -- minted on the device
  event_id     uuid not null references wh.stock_event(event_id) on delete restrict,
  line_no      int not null,
  material_id  uuid not null references wh.material(material_id),
  qty          numeric(18,4) not null check (qty <> 0),
  over_ack     boolean not null default false,
  intentional_duplicate boolean not null default false,
  -- a line noticed after the event was confirmed is added, never edited in
  added_at     timestamptz,
  added_by_person_id uuid references wh.person(person_id),
  added_reason text,
  unique (event_id, line_no)
);
create index event_line_material_idx on wh.event_line(material_id);
create index event_line_event_idx on wh.event_line(event_id);

-- Defence in depth: even a faulty RPC cannot store a quantity the material does not permit.
create or replace function wh.event_line_guard() returns trigger
language plpgsql set search_path = '' as $$
declare v_type text;
begin
  select event_type into v_type from wh.stock_event where event_id = new.event_id;
  perform wh.check_quantity(new.material_id, new.qty);
  if v_type in ('IN','OUT') and new.qty <= 0 then
    raise exception 'a movement line must be positive; direction comes from the event' using errcode='23514';
  end if;
  return new;
end $$;
create trigger event_line_guard_trg before insert or update on wh.event_line
  for each row execute function wh.event_line_guard();

-- ---------------------------------------------------------------- corrections
-- NULL means "this correction does not touch that field". The effective value of a
-- field is the latest non-null value in the chain, ordered by seq.
create table wh.line_correction (
  correction_id uuid primary key default gen_random_uuid(),
  seq           bigserial not null,
  line_id       uuid not null references wh.event_line(line_id),
  new_material_id uuid references wh.material(material_id),
  new_qty       numeric(18,4),
  new_voided    boolean,
  reason        text not null,
  by_person_id  uuid not null references wh.person(person_id),
  by_device_id  uuid references wh.device(device_id),
  at            timestamptz not null default clock_timestamp(),
  check (new_material_id is not null or new_qty is not null or new_voided is not null)
);
create index line_correction_line_idx on wh.line_correction(line_id, seq);
create index line_correction_at_idx on wh.line_correction(at);

create table wh.event_correction (
  correction_id uuid primary key default gen_random_uuid(),
  seq           bigserial not null,
  event_id      uuid not null references wh.stock_event(event_id),
  new_event_type  text check (new_event_type in ('IN','OUT')),
  new_effective_at timestamptz,
  new_handler_person_id uuid references wh.person(person_id),
  new_counterparty text,
  new_kind      text,
  new_vehicle   text,
  new_ref_type  text,
  new_ref_number text,
  new_ref_date  date,
  new_no_paper  boolean,
  new_notes     text,
  reason        text not null,
  by_person_id  uuid not null references wh.person(person_id),
  by_device_id  uuid references wh.device(device_id),
  at            timestamptz not null default clock_timestamp(),
  check (num_nonnulls(new_event_type, new_effective_at, new_handler_person_id, new_counterparty,
                      new_kind, new_vehicle, new_ref_type, new_ref_number, new_ref_date,
                      new_no_paper, new_notes) > 0)
);
create index event_correction_event_idx on wh.event_correction(event_id, seq);
create index event_correction_at_idx on wh.event_correction(at);
