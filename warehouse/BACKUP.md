# Warehouse backups

Supabase's managed backups cover the database. They do **not** restore the contents of
Storage objects, and they live inside the same project as the thing being protected. So
the warehouse carries its own independent backup as well, written somewhere else.

## What is backed up

| Layer | Where it comes from | In the set |
|---|---|---|
| Database | logical dump of schema `wh`, privileges included | `warehouse.dump`, `warehouse.sql` |
| Evidence photographs | the private evidence bucket, and legacy photographs | `objects/` |
| Schema and configuration | the repository, `warehouse/migrations` | commit recorded in `README.txt` |
| People and devices | inside the database dump | `warehouse.sql` |
| Integrity | every file, hashed | `checksums.sha256` |

A drill found that dumping with privileges stripped restores a database that nobody can
read: the policies survive but the grants that let the application roles reach the schema
do not. The dump therefore keeps privileges, and the drill asserts they come back.

## Schedule

| Setting | Value | Why |
|---|---|---|
| Frequency | every 6 hours | The godown records a few dozen movements a day. Six hours bounds the loss to part of one working day, at four small sets a day. |
| Retention | 30 days of sets | Long enough to notice a problem that took days to surface, short enough to stay cheap. |
| Maximum data loss | **up to 6 hours** of confirmed movements from the independent copy | Supabase's own daily backup bounds it to 24 hours; the independent copy improves on that. Point-in-time recovery, which would bound it to minutes, is deliberately not bought. |
| Verified | the drill runs in continuous integration on every push | A backup nobody has restored is not a backup. |

Anything recorded on a phone but not yet synced is not in any backup, by definition. That
window belongs to the phone, and the app shows it as pending.

## Destination

The set must not live inside the warehouse Supabase project. Any of these work, and the
script only needs a directory:

- a folder on a machine at the shop that is itself synced to a consumer cloud drive;
- an object store bucket in a different account, mounted or synced;
- a second, separate Supabase project used only as a backup store.

Credentials are read from the environment and never written to a file, printed, or
committed.

## Running it

```
WH_DB_URL=...            # warehouse database connection string
WH_BACKUP_DIR=...        # destination directory, outside the warehouse project
WH_STORAGE_URL=...       # optional, the project's storage endpoint
WH_STORAGE_KEY=...       # optional, service key, from the environment only
warehouse/tools/backup.sh
```

## Restoring

```
WH_RESTORE_URL=...       # the database to restore INTO
WH_SET=.../20260922T0600Z
WH_OBJECT_DIR=...        # where the evidence objects go
warehouse/tools/restore.sh
```

The script verifies every checksum before it writes anything, then restores the database
and puts the objects back.

Then, because a restore into a new project issues new keys and ends every phone session:

1. The owner signs in to the restored project and confirms he is the owner.
2. He issues an activation code for each staff phone.
3. Each phone redeems its code once. History is unaffected, because records name the
   person, not the phone.
4. Record one movement and open its photograph. Until that has been done, the restore is
   not proven.

`warehouse/test/recovery_drill.sh` performs exactly these steps end to end.


## Recovering the warehouse alone, inside the shared project

The warehouse lives in `maios-tally-mirror` beside Tally, StaffPay and the
legacy NK app. It is restored on its own, in place, and the neighbours are not
touched. `test/shared_recovery_drill.sh` runs exactly this in CI.

1. Move the damaged schema aside rather than dropping it — it may be evidence:
   `alter schema wh rename to wh_damaged_<date>;`
2. `WH_SET=<backup set> WH_RESTORE_URL=<project url> bash warehouse/tools/restore.sh`
   The script recreates the confined caretaker first, verifies the set's
   checksums, replays the schema, then replays the public API.
3. Check the boundary came back: `psql "$WH_DB_URL" -f warehouse/test/t_85_boundary.sql`
4. Re-issue activation codes for every phone. Device credentials from before
   the restore point are gone by design.
5. Drop `wh_damaged_<date>` once the restore is confirmed.

**The trap to write on the wall:** if anyone ever restores the *whole project*
backwards in time to rescue StaffPay or Tally, the warehouse travels back with
it. Restore the warehouse again from its own backup afterwards, or six hours of
recording silently disappears.

## What the backup contains

- `warehouse.dump` / `warehouse.sql` — schema `wh`, with ownership and
  privileges kept. Both matter: privileges alone restore a database nobody can
  read, and ownership alone restores a warehouse without its security boundary.
  Two drills taught us that, one each.
- `public_api.sql` — the `public.wh_*` wrappers, extracted by name. They are the
  only warehouse objects outside schema `wh`, so a `-n wh` dump misses them. A
  drill caught that too.
- `objects/` — the evidence photographs. Supabase database backups do not
  restore object contents.
- `README.txt`, `checksums.sha256` — verified before anything is written.
