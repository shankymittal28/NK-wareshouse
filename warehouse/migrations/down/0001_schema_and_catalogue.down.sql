-- Undo 0001. DESTRUCTIVE: removes the warehouse schema entirely.
-- The old system lives in a different Supabase project and is not touched by this.
drop function if exists wh.check_quantity(uuid,numeric,boolean);
drop function if exists wh.material_name(uuid);
drop trigger if exists material_derive_trg on wh.material;
drop function if exists wh.material_derive();
drop table if exists wh.material;
drop table if exists wh.attribute_value;
drop table if exists wh.category_attribute;
drop table if exists wh.category;
drop function if exists wh.exact_join(text[]);
drop function if exists wh.norm_join(text[]);
drop function if exists wh.norm(text);
drop schema if exists wh cascade;
