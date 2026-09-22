-- 0004  the opening baseline, physical counts, valuation, evidence, legacy history, drafts

-- ---------------------------------------------------------------- opening
-- The first trusted baseline for a material. At most one active row per material,
-- enforced here rather than by any screen. A later physical count is a count report.
create table wh.opening (
  opening_id    uuid primary key default gen_random_uuid(),
  material_id   uuid not null references wh.material(material_id),
  counted       numeric(18,4) not null check (counted >= 0),
  legacy_expected numeric(18,4),
  effective_at  timestamptz not null,
  recorded_at   timestamptz not null default clock_timestamp(),
  by_person_id  uuid not null references wh.person(person_id),
  by_device_id  uuid references wh.device(device_id),
  status        text not null default 'active' check (status in ('active','superseded')),
  superseded_at timestamptz,
  superseded_by_opening_id uuid references wh.opening(opening_id),
  superseded_reason text
);
create unique index opening_one_active_uidx on wh.opening(material_id) where status = 'active';

-- ---------------------------------------------------------------- physical counts
create table wh.count_report (
  count_id      uuid primary key default gen_random_uuid(),
  material_id   uuid not null references wh.material(material_id),
  counted       numeric(18,4) not null check (counted >= 0),
  counted_at    timestamptz not null,          -- physical time of the count
  reported_at   timestamptz not null default clock_timestamp(),   -- see stock_event.server_received_at
  recorded_at_count numeric(18,4) not null,    -- basis: stock at counted_at, as known at reported_at
  by_person_id  uuid not null references wh.person(person_id),
  by_device_id  uuid references wh.device(device_id),
  note          text,
  status        text not null default 'pending'
                check (status in ('pending','approved','rejected','recount','needs_review')),
  resolved_at   timestamptz,
  resolved_by_person_id uuid references wh.person(person_id),
  resolution_reason text,
  adjustment_event_id uuid references wh.stock_event(event_id)
);
create index count_report_pending_idx on wh.count_report(material_id) where status = 'pending';

-- ---------------------------------------------------------------- valuation
create table wh.rate (
  material_id   uuid primary key references wh.material(material_id),
  rate          numeric(14,4) not null check (rate > 0),
  set_at        timestamptz not null default now(),
  set_by_person_id uuid not null references wh.person(person_id)
);
create table wh.rate_history (
  rate_history_id bigserial primary key,
  material_id   uuid not null references wh.material(material_id),
  rate          numeric(14,4) not null check (rate > 0),
  set_at        timestamptz not null default now(),
  set_by_person_id uuid not null references wh.person(person_id)
);
create index rate_history_material_idx on wh.rate_history(material_id, set_at desc);

-- ---------------------------------------------------------------- evidence
create table wh.evidence (
  evidence_id   uuid primary key default gen_random_uuid(),
  event_id      uuid not null references wh.stock_event(event_id),
  bucket_path   text not null unique,
  sha256        text,
  bytes         bigint,
  taken_at      timestamptz,
  uploaded_at   timestamptz not null default now(),
  by_person_id  uuid references wh.person(person_id)
);
create index evidence_event_idx on wh.evidence(event_id);

-- ---------------------------------------------------------------- legacy history
-- Copied from the old system. These tables are NOT read by any stock calculation.
-- Their recorder stays a name, never a person: those writes were never authenticated.
create table wh.legacy_line (
  legacy_id     uuid primary key default gen_random_uuid(),
  source_row_id uuid not null unique,
  material_id   uuid not null references wh.material(material_id),
  category_code text not null,
  attrs         jsonb not null,
  qty           numeric(18,4) not null,
  direction     text not null check (direction in ('in','out')),
  counterparty  text,
  zone          text,
  recorded_by_name text,
  occurred_at   timestamptz not null,
  suspect_duplicate_of uuid references wh.legacy_line(legacy_id),
  imported_at   timestamptz not null default now()
);
create index legacy_line_material_idx on wh.legacy_line(material_id, occurred_at);

create table wh.legacy_photo (
  legacy_photo_id uuid primary key default gen_random_uuid(),
  legacy_id     uuid not null references wh.legacy_line(legacy_id) on delete cascade,
  bucket_path   text not null,
  original_url  text
);
create index legacy_photo_line_idx on wh.legacy_photo(legacy_id);

-- ---------------------------------------------------------------- drafts
-- A draft is not a fact. One JSON document per movement in progress, mirrored to the
-- server only when online, and structurally invisible to stock arithmetic.
create table wh.draft (
  draft_id      uuid primary key,
  person_id     uuid not null references wh.person(person_id),
  device_id     uuid not null references wh.device(device_id),
  client_rev    int not null check (client_rev >= 0),
  doc           jsonb not null,
  status        text not null default 'open' check (status in ('open','confirmed','abandoned')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  server_received_at timestamptz not null default clock_timestamp()
);
create index draft_open_idx on wh.draft(person_id) where status = 'open';
