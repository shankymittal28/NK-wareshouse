# Running the legacy import in the shared project

`01_import_legacy.sql` reads schema `src`. In a dedicated project that is a
staged copy. In `maios-tally-mirror` the old data is already in the same
database, so `src` is two views over it, and the import runs as the caretaker.

Two things the first live run taught, both of which fail quietly if you get
them wrong:

1. **The staging views must NOT be `security_invoker`.** Row level security on
   `public.nkg_stock` grants the caretaker nothing, so an invoker view returns
   zero rows and the import succeeds while doing nothing. Definer views owned
   by `postgres` are right here, and only here: read-only, reachable by exactly
   one role, and dropped when the import finishes. No NK policy is changed.

2. **The caretaker's reach must be taken away again**, and asserted. The import
   is the only moment the warehouse is allowed to see the old tables.

```sql
-- staging
create schema src;
create view src.nkg_stock as select * from public.nkg_stock;
create view src.nkg_rates as select * from public.nkg_rates;
alter view src.nkg_stock set (security_invoker = false);
alter view src.nkg_rates set (security_invoker = false);
create schema wh_import authorization wh_owner;
revoke all on schema src from public, anon, authenticated;
revoke all on src.nkg_stock, src.nkg_rates from public, anon, authenticated;
grant usage on schema src to wh_owner;
grant select on src.nkg_stock, src.nkg_rates to wh_owner;

-- the import itself, verbatim, as the caretaker
set role wh_owner;
\i tools/01_import_legacy.sql
\i tools/02_reconcile.sql
reset role;

-- take it all away, and prove it
drop view src.nkg_stock; drop view src.nkg_rates; drop schema src;
\i test/t_85_boundary.sql
```

The reconciliation must report the same row count and the same net units on
both sides, and zero identities that disagree. Anything else means stop.
