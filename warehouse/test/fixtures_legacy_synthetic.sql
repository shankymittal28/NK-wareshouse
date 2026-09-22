-- Synthetic rows shaped exactly like the old nkg_stock, covering the cases the real
-- data contains: a missing attribute, a look-alike pair, a repeated tap, a rate that
-- matches nothing, photographs in both the old and the newer column.
create schema if not exists src;
create table src.nkg_stock(
  id uuid primary key, category text, item_name text, brand text, thickness text, size text, design text,
  qty numeric, unit text, direction text, source_godown text, customer text, zone_name text,
  logged_by text, note text, photo_url text, photos jsonb, entry_type text, created_at timestamptz);
create table src.nkg_rates(k text primary key, rate numeric, updated_at timestamptz);

insert into src.nkg_stock values
 ('aa000000-0000-0000-0000-000000000001','Plywood','Century 18mm 8x4','Century','18mm','8x4',null,15,'pcs','in','Zangi',null,null,'राज',null,
  'https://old/storage/v1/object/public/nkg-photos/2026-08-01/a.jpg','[]','lot','2026-08-01 10:00+00'),
 ('aa000000-0000-0000-0000-000000000002','Plywood','Century 18mm 8x4','Century','18mm','8x4',null,5,'pcs','out',null,'Om Furniture',null,'सुरेश',null,
  null,'["https://old/storage/v1/object/public/nkg-photos/2026-08-02/b.jpg"]','lot','2026-08-02 11:00+00'),
 -- the same tap twice, a minute apart
 ('aa000000-0000-0000-0000-000000000003','Plywood','Greenply 12mm 7x4','Greenply','12mm','7x4',null,8,'pcs','in','Rice Mill 2',null,null,'राज',null,null,'[]','lot','2026-08-03 09:00+00'),
 ('aa000000-0000-0000-0000-000000000004','Plywood','Greenply 12mm 7x4','Greenply','12mm','7x4',null,8,'pcs','in','Rice Mill 2',null,null,'राज',null,null,'[]','lot','2026-08-03 09:01+00'),
 -- no brand was ever recorded on this one
 ('aa000000-0000-0000-0000-000000000005','Plywood','12mm 8x4',null,'12mm','8x4',null,4,'pcs','in','दुकान',null,null,'अर्जुन',null,null,'[]','lot','2026-08-04 09:00+00'),
 -- two door identities that only look alike once case and hyphens are ignored
 ('aa000000-0000-0000-0000-000000000006','Door','Lamination KP7098 78x38','Lamination',null,'78x38','KP7098',3,'pcs','in','Sharda',null,null,'राज',null,null,'[]','lot','2026-08-05 09:00+00'),
 ('aa000000-0000-0000-0000-000000000007','Door','Lamination KP-7098 78x38','Lamination',null,'78x38','KP-7098',2,'pcs','in','Sharda',null,null,'अर्जुन',null,null,'[]','lot','2026-08-06 09:00+00');

insert into src.nkg_rates values
 ('Plywood|Century|18mm|8x4|', 2150, '2026-08-10 10:00+00'),
 ('Plywood|Nothing|9mm|8x4|', 999, '2026-08-10 10:00+00');
