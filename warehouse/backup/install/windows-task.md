# Windows Task Scheduler — the Tally machine

The backup runs the bash scripts, so the Tally machine needs two standard,
free installers first (each is next-next-finish):

1. **Git for Windows** — provides `bash`, `curl` and `sha256sum`.
   https://git-scm.com/download/win
2. **PostgreSQL 17 client tools** — provides `pg_dump`, `pg_restore`, `psql`.
   In the PostgreSQL installer you may untick "PostgreSQL Server" and keep only
   "Command Line Tools". Note the install path, e.g.
   `C:\Program Files\PostgreSQL\17\bin`, and put it in `PGBIN` in the env file.

Then register the schedule (run once, in an Administrator PowerShell — no secret
appears on this line; it points at the env file):

```powershell
$bash = "C:\Program Files\Git\bin\bash.exe"
$job  = "C:/nk-warehouse/warehouse/backup/run-backup.sh C:/nk-warehouse/warehouse/backup/wh-backup.env"
$act  = New-ScheduledTaskAction -Execute $bash -Argument "-lc `"$job`""
$trg  = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 6)
Register-ScheduledTask -TaskName "NK Warehouse Backup" -Action $act -Trigger $trg `
  -Description "Six-hourly warehouse backup to the offsite folder" -RunLevel Highest
```

The task runs whether or not anyone is logged in only if you tick "Run whether
user is logged on or not" in Task Scheduler afterwards; for a machine that stays
logged in (the Tally pump machine), the default is fine.

Check it any time:
```
"C:\Program Files\Git\bin\bash.exe" -lc "C:/nk-warehouse/warehouse/backup/backup-status.sh C:/nk-warehouse/warehouse/backup/wh-backup.env"
```
