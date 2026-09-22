-- 0001  warehouse schema, category/material catalogue, exact-decimal quantity rules
-- Stage 0. Applies to the dedicated NK Warehouse project only.
create schema if not exists wh;

-- ---------------------------------------------------------------- normalisation
-- Used ONLY to detect look-alike values and propose merges to the owner.
-- It never enforces uniqueness: two identities that merely normalise alike stay separate
-- until a human says they are the same physical material.
create or replace function wh.norm(p text) returns text
language sql immutable strict set search_path = '' as $$
  select lower(regexp_replace(p, '[^a-zA-Z0-9ऀ-ॿ]', '', 'g'))
$$;

create or replace function wh.norm_join(p text[]) returns text
language sql immutable strict set search_path = '' as $$
  select string_agg(coalesce(wh.norm(v), ''), '|') from unnest(p) as v
$$;

create or replace function wh.exact_join(p text[]) returns text
language sql immutable strict set search_path = '' as $$
  select string_agg(coalesce(btrim(v), ''), '|') from unnest(p) as v
$$;

-- ---------------------------------------------------------------- categories
create table wh.category (
  category_code   text primary key,
  name_hi         text not null,
  name_en         text not null,
  unit_code       text not null,
  unit_hi         text not null,
  unit_en         text not null,
  decimals        smallint not null default 0 check (decimals between 0 and 4),
  step            numeric(18,4) check (step is null or step > 0),
  active          boolean not null default true,
  sort            int not null default 0,
  created_at      timestamptz not null default now()
);
comment on column wh.category.decimals is
  'Permitted precision for quantities in this category. 0 = whole sheets/pieces, 2 = square feet, etc. A new unit is a new row, not a migration.';

create table wh.category_attribute (
  category_code   text not null references wh.category(category_code) on delete cascade,
  seq             smallint not null,
  attr_key        text not null,
  label_hi        text not null,
  label_en        text not null,
  primary key (category_code, attr_key),
  unique (category_code, seq)
);

create table wh.attribute_value (
  attribute_value_id uuid primary key default gen_random_uuid(),
  category_code   text not null,
  attr_key        text not null,
  value           text not null,
  norm_value      text generated always as (wh.norm(value)) stored,
  sort            int not null default 0,
  favourite       boolean not null default false,
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  foreign key (category_code, attr_key) references wh.category_attribute(category_code, attr_key) on delete cascade,
  unique (category_code, attr_key, value)
);
create index attribute_value_norm_idx on wh.attribute_value(category_code, attr_key, norm_value);

-- ---------------------------------------------------------------- materials
create table wh.material (
  material_id     uuid primary key default gen_random_uuid(),
  category_code   text not null references wh.category(category_code),
  attrs           jsonb not null,
  identity_key    text not null,   -- exact attribute values, joined in category order
  norm_key        text not null,   -- normalised; NOT unique, used only to propose merges
  unit_code       text not null,
  decimals        smallint not null check (decimals between 0 and 4),
  step            numeric(18,4) check (step is null or step > 0),
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  created_by_person_id uuid,
  created_in_event_id  uuid,
  resembles_material_id uuid references wh.material(material_id),
  merged_into_material_id uuid references wh.material(material_id),
  merged_at       timestamptz,
  merged_reason   text,
  origin          text not null default 'live' check (origin in ('live','legacy_import')),
  -- An old row that never carried a value for a required attribute. The quantity, date,
  -- recorder and evidence are all preserved; only the identity is incomplete. No type is
  -- ever invented for it, and it stays historical reference until a person classifies it.
  identity_incomplete boolean not null default false,
  missing_attrs   text[] not null default '{}',
  -- Identities that merely LOOK alike after normalising share a group id so a person can
  -- review them. They are never merged by that fact alone.
  possible_same_group uuid
);
-- Exact identity is unique: the same tuple cannot exist twice.
create unique index material_identity_uidx on wh.material(category_code, identity_key);
-- Normalised identity is only indexed, never unique.
create index material_norm_idx on wh.material(category_code, norm_key);
create index material_merged_idx on wh.material(merged_into_material_id) where merged_into_material_id is not null;

-- Identity keys and unit metadata are derived, never supplied by a caller.
create or replace function wh.material_derive() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_vals text[];
  v_cat  wh.category%rowtype;
  v_missing text;
begin
  select * into v_cat from wh.category where category_code = new.category_code;
  if not found then
    raise exception 'unknown category %', new.category_code using errcode='23514';
  end if;

  select array_agg(btrim(coalesce(new.attrs ->> ca.attr_key, '')) order by ca.seq)
    into v_vals
    from wh.category_attribute ca
   where ca.category_code = new.category_code;

  select string_agg(ca.attr_key, ', ' order by ca.seq) into v_missing
    from wh.category_attribute ca
   where ca.category_code = new.category_code
     and coalesce(btrim(new.attrs ->> ca.attr_key), '') = '';
  if v_missing is not null then
    raise exception 'material is missing required attribute(s): %', v_missing using errcode='23514';
  end if;

  new.identity_key := wh.exact_join(v_vals);
  new.norm_key     := wh.norm_join(v_vals);
  new.unit_code    := coalesce(new.unit_code, v_cat.unit_code);
  if new.decimals is null then new.decimals := v_cat.decimals; end if;
  if new.step is null then new.step := v_cat.step; end if;
  return new;
end $$;

create trigger material_derive_trg before insert or update of attrs, category_code
  on wh.material for each row execute function wh.material_derive();

-- Display name in category attribute order, e.g. 'Century · 18mm · 8x4'
create or replace function wh.material_name(p_material_id uuid) returns text
language sql stable set search_path = '' as $$
  select string_agg(btrim(m.attrs ->> ca.attr_key), ' · ' order by ca.seq)
    from wh.material m
    join wh.category_attribute ca on ca.category_code = m.category_code
   where m.material_id = p_material_id
$$;

-- Quantity rule: exact decimal, inside the material's permitted precision and step.
create or replace function wh.check_quantity(p_material_id uuid, p_qty numeric,
                                            p_allow_zero boolean default false)
returns void language plpgsql stable set search_path = '' as $$
declare m wh.material%rowtype;
begin
  select * into m from wh.material where material_id = p_material_id;
  if not found then
    raise exception 'unknown material %', p_material_id using errcode='23503';
  end if;
  if p_qty is null then
    raise exception 'quantity is required' using errcode='23514';
  end if;
  if p_qty = 0 and not p_allow_zero then
    raise exception 'quantity must not be zero' using errcode='23514';
  end if;
  if p_qty <> round(p_qty, m.decimals) then
    raise exception 'quantity % has more precision than % allows (% decimals)',
      p_qty, wh.material_name(p_material_id), m.decimals using errcode='23514';
  end if;
  if m.step is not null and mod(abs(p_qty), m.step) <> 0 then
    raise exception 'quantity % is not a multiple of the % step for %',
      p_qty, m.step, wh.material_name(p_material_id) using errcode='23514';
  end if;
end $$;

-- ---------------------------------------------------------------- settings
-- Tunables and deploy-time configuration. Defined here because 0002 reads
-- the owner identity from it.
create table wh.setting (
  key   text primary key,
  value jsonb not null,
  note  text
);
insert into wh.setting(key, value, note) values
  ('effective_future_tolerance_minutes','120','Clock skew allowed on a device-supplied physical time'),
  ('effective_backdate_free_days','7','Older than this needs a stated reason'),
  ('effective_backdate_max_days','400','Refused beyond this'),
  ('near_duplicate_warn','true','Warn when a new identity normalises like an existing one');

create or replace function wh.setting_num(p_key text, p_default numeric) returns numeric
language sql stable set search_path = '' as $$
  select coalesce((select value::text::numeric from wh.setting where key = p_key), p_default)
$$;
insert into wh.setting(key, value, note) values
  ('owner_email', '""'::jsonb, 'The Supabase account that is the warehouse owner. Seeded at deploy; not a secret, but not written into the repository either.')
  on conflict (key) do nothing;
