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
