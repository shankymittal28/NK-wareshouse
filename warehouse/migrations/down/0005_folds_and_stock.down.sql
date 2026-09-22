-- Undo 0005: remove the folds, the derived views and the review lists.
-- No stored data is affected, because none of this stores anything.
drop view if exists wh.incomplete_identity;
drop view if exists wh.possible_same_material;
drop function if exists wh.trail(uuid);
drop view if exists wh.valuation_coverage;
drop view if exists wh.material_value;
drop view if exists wh.material_stock;
drop view if exists wh.legacy_expected;
drop view if exists wh.opening_active;
drop function if exists wh.stock_as_of(uuid,timestamptz,timestamptz);
drop function if exists wh.line_sign(text);
drop view if exists wh.event_effective;
drop view if exists wh.line_effective;
drop function if exists wh.event_effective_as_of(timestamptz);
drop function if exists wh.line_effective_as_of(timestamptz);
