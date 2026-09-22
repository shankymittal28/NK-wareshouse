# NK Warehouse — the six-hourly backup

> **Status (owner decision, 2026-09-22): NOT a current requirement.**
> Shanky has decided NK Warehouse does not need an independent offsite backup;
> loss of warehouse data is acceptable to the business. The warehouse therefore
> relies on Supabase's default platform durability, and the app has no dependency
> on the Tally PC. The tooling below is kept, working and CI-guarded, purely so it
> is ready if that decision is ever revisited. It is optional and is not a Stage gate.


This runs on one always-on machine at the shop (the Tally data-pump PC is the
natural choice: it is on all day and already runs scheduled jobs against this
same Supabase project). It makes a complete, restorable copy of the warehouse
every six hours and keeps it in a folder that syncs off the machine, so losing
or corrupting the Supabase project cannot take the backup with it.

## What Shanky does, once

Everything below happens **on the backup machine**. No password is ever typed
into a chat, and nothing secret is committed to git.

1. Put the repository on the machine (e.g. `C:\nk-warehouse`).
2. On Windows, install the two free tools in `install/windows-task.md`
   (Git for Windows, and the PostgreSQL 17 command-line tools). On Linux they
   are `git`, `curl` and `postgresql-client-17`.
3. Make the offsite folder: sign in to OneDrive (already on Windows) or install
   Google Drive for Desktop, and create one synced folder for the backups.
4. Copy `wh-backup.env.example` to `wh-backup.env` beside it, and fill in:
   - the database connection string and password (Supabase dashboard →
     Project Settings → Database → Connection string → URI);
   - the service-role key (same kind of key the Tally pump already uses);
   - the staging and offsite folder paths.
   Then lock the file down (`chmod 600` on Linux; on Windows keep it in your
   user folder). **Enter the password here, on the machine, and stop — never
   send it back.**
5. Register the schedule: `install/windows-task.md` (Windows) or
   `install/crontab.txt` / `install/systemd/` (Linux).

## What it does, every six hours

`run-backup.sh` stages a timestamped set (database dump, the public API, the
evidence photographs, a manifest with the schema commit, and checksums),
verifies it, copies it to the offsite folder, verifies that copy too, then —
and only then — prunes sets older than 30 days. A failed dump, a failed object
copy, or a bad checksum fails the whole run and never deletes a previous good
set. Every run writes `_status/status.json` and appends to `_status/backup.log`.

## Checking and proving it

- `backup-status.sh` — last success, last failure, age of the newest valid set,
  how many valid sets are kept. Exits non-zero if the newest is too old.
- `restore-check.sh` — restores the newest set into a throwaway database and
  *operates* it (activates a device, records a movement, checks the stock and
  that staff still cannot see money), then throws it away. This is the proof
  that a backup is real, run it whenever you want reassurance.

Neither ever touches the live project.
