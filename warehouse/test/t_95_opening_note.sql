\set QUIET on
\set ON_ERROR_STOP on
-- Stage 1C: an owner-recorded opening count becomes the trusted baseline, carries
-- an optional note, is owner-only at the boundary, and never silently borrows the
-- legacy expectation. Physical reality wins; the old records are reference only.

-- P: Plywood 18mm, sheets, decimals 0 | P3: Plywood (fresh, decimals 0)
-- G: Glass, sqft, decimals 2 | D: Doors, pcs, decimals 0
\set P '''cccccccc-0000-0000-0000-000000000001'''
\set P2 '''cccccccc-0000-0000-0000-000000000002'''
\set P3 '''cccccccc-0000-0000-0000-000000000003'''
\set G '''cccccccc-0000-0000-0000-000000000005'''
\set D '''cccccccc-0000-0000-0000-000000000004'''

-- ---- before any opening: legacy is reference only, never trusted stock ----
select t.act_as_owner();
select t.ok((select recorded_qty is null from wh.material_stock where material_id = :P::uuid),
            'before an opening, recorded (trusted) stock is NULL even if old records exist');
select t.ok((select not has_opening from wh.material_stock where material_id = :P::uuid),
            'and the material is not yet verified');

-- ---- owner records a real physical count, with a note ----
select t.eq((wh.record_opening(:P::uuid, 18, now() - interval '1 hour', '  3 शीट ख़राब, हटाईं  ')
             ->> 'counted')::numeric, 18::numeric,
            'the owner records a physical count of 18');
select t.eq((select counted from wh.opening where material_id = :P::uuid and status='active'),
            18::numeric, 'the trusted baseline is exactly what was physically counted');
select t.ok((select recorded_qty = 18 and has_opening from wh.material_stock where material_id = :P::uuid),
            'the catalogue now shows 18 as verified, trusted stock');

-- ---- the note is persisted, trimmed, and never becomes the quantity ----
select t.eq((select note from wh.opening where material_id = :P::uuid and status='active'),
            '3 शीट ख़राब, हटाईं', 'the note is stored, trimmed of surrounding spaces');
select t.eq((select detail->>'note' from wh.trail(:P::uuid) where kind='opening'),
            '3 शीट ख़राब, हटाईं', 'and the trail shows the note on the opening event');
select t.eq((select detail->>'by' from wh.trail(:P::uuid) where kind='opening'),
            'Shanky', 'the trail records who confirmed the opening');

-- ---- legacy vs count difference is visible, legacy is not auto-used ----
select t.ok((select (legacy_expected is distinct from counted)
               from wh.opening where material_id = :P::uuid and status='active'),
            'the opening keeps the legacy expectation for comparison, separate from the count');

-- ---- a second opening is refused by the database (no silent overwrite) ----
select t.raises(format($$select wh.record_opening(%L::uuid, 20)$$, :P),
                'opening_exists', 'a second opening is refused; history is never silently overwritten');
select t.eq((select count(*)::int from wh.opening where material_id = :P::uuid and status='active'), 1,
            'still exactly one active baseline (idempotent against a double submit)');

-- ---- zero is a legitimate physical count; negative is not ----
select t.eq((wh.record_opening(:D::uuid, 0, now()) ->> 'counted')::numeric, 0::numeric,
            'a physical count of zero is accepted');
select t.ok((select has_opening and recorded_qty = 0 from wh.material_stock where material_id = :D::uuid),
            'zero-count material is verified with trusted stock of 0');
select t.raises(format($$select wh.record_opening(%L::uuid, -1, now())$$, :G),
                'negative', 'a negative physical count is rejected');

-- ---- unit precision follows the category, not a global rule ----
select t.raises(format($$select wh.record_opening(%L::uuid, 18.5, now())$$, :P3),
                'precision', 'whole-unit categories reject a fractional count');
select t.eq((wh.record_opening(:G::uuid, 12.25, now()) ->> 'counted')::numeric, 12.25::numeric,
            'a decimal category (sq ft) accepts a decimal count');

-- ---- recording an opening is owner-only, stated at the public boundary ----
select t.act_as('tok-raj-1');   -- an activated staff device, not the owner
select t.raises(format($$select public.wh_owner_record_opening(%L::uuid, 5, now(), null)$$,
                       :P2),
                'only the owner', 'staff cannot record an opening through the public wrapper');
select t.act_as_nobody();
select t.raises(format($$select public.wh_owner_record_opening(%L::uuid, 5, now(), null)$$,
                       :P2),
                'not activated', 'an unauthenticated caller cannot record an opening either');
select t.ok((select not has_opening from wh.material_stock
              where material_id = :P2::uuid),
            'so that material remains unverified');

-- ---- mixed trust: verified and unverified coexist, valuation counts only trusted ----
select t.act_as_owner();
select t.ok((select count(*) >= 1 from wh.material_stock where not has_opening),
            'unverified materials still exist alongside the verified ones');
select t.ok((select not exists (select 1 from wh.material_value v
                                  join wh.material_stock ms on ms.material_id = v.material_id
                                 where ms.recorded_qty is null)),
            'valuation never includes a material without a trusted quantity');
