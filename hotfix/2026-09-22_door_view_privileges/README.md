# Hotfix — `public.nkg_door_stock` write privileges (2026-09-22)

Independent of the NK Warehouse build. Privileges only; no data, no view
definition, no policy, no StaffPay object is touched.

## The defect

`public.nkg_door_stock` is a view over `nkg_stock` restricted to
`category = 'Door'`. Three facts combine into a privilege escalation:

1. The view is owned by `postgres` and has no `security_invoker` option, so
   it runs with the owner's authority. `postgres` owns `nkg_stock` and
   `relforcerowsecurity` is false there, so **RLS does not apply through the
   view**.
2. The view is auto-updatable — `pg_relation_is_updatable(oid, true) = 28`,
   i.e. UPDATE | INSERT | DELETE.
3. `anon` held `arwdDxtm` on it.

Anyone holding the public key — which is embedded in the NK app — could
therefore update or delete any door row in `nkg_stock`, unrestricted by
`nkg_stock_anon_undo` (the 30-minute delete window).

Supabase's own database linter reports the same object at ERROR level
(`security_definer_view`).

## Evidence, gathered without touching a row

Query plans only (`EXPLAIN`, never `EXPLAIN ANALYZE`), run as `anon`:

| statement | plan |
|---|---|
| `DELETE FROM nkg_stock WHERE zone_name = '…'` | `One-Time Filter: false` — the RLS policy applied and refused |
| `UPDATE nkg_door_stock SET customer = customer WHERE zone_name = '…'` | `Update on nkg_stock` → `Index Scan` → `Filter: (category = 'Door')` — **no policy qualifier** |
| `DELETE FROM nkg_door_stock WHERE zone_name = '…'` | same — the view's own WHERE clause is the only restriction |

## The application does not write through the view

`index.html` is the whole NK app. `nkg_door_stock` appears exactly once:

- line 1290, `loadDoorStock()` — a `select=…&order=created_at.desc` read.

Every write in the app goes elsewhere: `nkg_stock`, `nkg_options`,
`nkg_sources`, `nkg_zones`, `nkg_rates`, `nkg_customers`, `nkg_ledger`, or
`rpc/set_door_customer`. Customer assignment (line 1331) uses the RPC, which
is `SECURITY DEFINER` and unaffected by this change.

The read is issued through `api()`, which sends the anon key when nobody is
signed in and the owner's token when he is — so **both** `anon` and
`authenticated` must keep `SELECT`.

## The change

```
anon, authenticated:  revoke INSERT, UPDATE, DELETE, TRUNCATE,
                             REFERENCES, TRIGGER, MAINTAIN
anon, authenticated:  grant  SELECT   (stated explicitly)
service_role:         unchanged
```

`up.sql` asserts the end state and raises rather than leaving the change
half-applied. `down.sql` restores the captured prior grants exactly.

## Prior state, captured for rollback

```
relacl: {postgres=arwdDxtm/postgres, anon=arwdDxtm/postgres,
         authenticated=arwdDxtm/postgres, service_role=arwdDxtm/postgres}
owner:  postgres
view definition md5: 8c465862068990a891d7998a7c3208d7   (unchanged by this hotfix)
```

## Not in scope

No change to `nkg_stock` policies, to the customer-assignment workflow, to
door data, to StaffPay or Tally, and no warehouse Stage 0 migration is
bundled here.

## Applied

Applied to project `enjlgflisuywkaorxetv` on 2026-09-22 as Supabase migration
`hotfix_nkg_door_stock_read_only_for_client_roles`.

Privileges after the change:

```
{postgres=arwdDxtm/postgres, anon=r/postgres,
 authenticated=r/postgres, service_role=arwdDxtm/postgres}
```

View definition md5 `8c465862068990a891d7998a7c3208d7` — unchanged.

### Tests, on production

| # | Test | Result |
|---|---|---|
| T1 | Door Stock screen's exact read (`id, door_type, design, size, item_name, customer, qty, direction, zone_name, source_godown`, ordered) as `anon` | 50 rows returned |
| T2 | `anon` INSERT / UPDATE / DELETE through the view | 3 of 3 denied — `permission denied for view nkg_door_stock` |
| T3 | Customer assignment via `rpc/set_door_customer` as `anon` | 1 row affected, value applied |
| T4 | Clearing the customer via the same RPC (blank string) | 1 row affected, customer set to NULL |
| T5 | Original value restored | matches |
| T6 | RPC refuses a non-Door row | 0 rows affected |

T3–T6 ran inside a transaction that was rolled back, so no door row was
left changed. Verified afterwards: 0 rows carry the test value; 1307 stock
rows and 385 door rows, unchanged; `nkg_stock` still carries exactly its
three original policies (`nkg_stock_anon_insert`, `nkg_stock_anon_undo`,
`nkg_stock_owner`).

No frontend change is required: the app only reads the view.

### Known remaining finding, deliberately not fixed here

Supabase's linter will still report `nkg_door_stock` as a SECURITY DEFINER
view. That is now true only of the **read**, which is the deliberate
mechanism letting staff see door rows without seeing plywood rows. Removing
it would mean giving `anon` a SELECT policy on `nkg_stock` — a change to
`nkg_stock` policies, which this hotfix is explicitly not permitted to make.
Worth revisiting separately.
