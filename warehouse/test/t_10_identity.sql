\set QUIET on
\set ON_ERROR_STOP on
-- Material identity: exact tuples are unique; look-alikes are reported, never merged.
set role authenticated;
select t.act_as('aaaaaaaa-0000-0000-0000-000000000002');   -- Raj

select t.eq((wh.create_material('Plywood','{"brand":"Century","thickness":"18mm","size":"8x4"}') ->> 'material_id')::uuid,
            'cccccccc-0000-0000-0000-000000000001'::uuid,
            'creating an identical material returns the existing one');

-- "KP 7098" normalises like "KP7098" but is a different exact tuple: both survive.
select t.eq(jsonb_array_length(
    wh.create_material('Doors','{"variety":"Lamination","design":"KP 7098","size":"78x38"}') -> 'look_alikes'),
    1, 'a look-alike identity is reported');
select t.eq((select count(*)::int from wh.material where category_code='Doors'
              and norm_key = (select norm_key from wh.material where material_id='cccccccc-0000-0000-0000-000000000004')),
            2, 'both identities are kept until a person says they are the same');

select t.eq(wh.material_name('cccccccc-0000-0000-0000-000000000001'), 'Century · 18mm · 8x4',
            'name follows the category attribute order');
select t.raises($$select wh.create_material('Plywood','{"brand":"Century","thickness":"18mm"}')$$,
                'missing required attribute', 'an incomplete identity is refused');
select t.raises($$select wh.create_material('Nope','{"a":"b"}')$$,
                'unknown category', 'an unknown category is refused');
reset role;
