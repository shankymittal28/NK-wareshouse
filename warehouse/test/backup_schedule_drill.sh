#!/usr/bin/env bash
# Proves the scheduled backup wrapper end to end without a real project:
# source warehouse -> run-backup.sh -> offsite set -> restore-check -> status.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
PGHOST="${PGHOST:-/tmp}"; PGPORT="${PGPORT:-5433}"; PGUSER="${PGUSER:-postgres}"
export PGHOST PGPORT PGUSER
P="psql -X -q -v ON_ERROR_STOP=1 --no-psqlrc"
DB="${WH_SRC_DB:-whschedsrc}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"; psql -X -q -d postgres -c "drop database if exists $DB;" >/dev/null 2>&1' EXIT

$P -d postgres -c "drop database if exists $DB;" >/dev/null 2>&1
$P -d postgres -c "create database $DB;" >/dev/null
$P -d "$DB" -f "$HERE/000_supabase_stub.sql" >/dev/null 2>&1
for f in "$ROOT"/migrations/*.sql; do $P -d "$DB" -f "$f" >/dev/null 2>&1 || { echo "migration failed: $f"; exit 1; }; done
$P -d "$DB" -f "$HERE/001_fixtures.sql" >/dev/null 2>&1
# an opening and one evidence object so the set carries real data
mkdir -p "$WORK/bucket/e"; head -c 4096 /dev/urandom > "$WORK/bucket/e/p.jpg"
$P -d "$DB" -1 <<PSQL >/dev/null
select t.act_as('tok-raj-1');
select wh.record_opening('cccccccc-0000-0000-0000-000000000001', 40, now()-interval '2 days');
PSQL
$P -d "$DB" <<PSQL >/dev/null
insert into wh.stock_event(event_id,event_type,effective_at,confirmed_at,recorder_person_id,device_id)
 values ('ffff0000-0000-0000-0000-0000000000e1','IN',now(),now(),'22222222-2222-2222-2222-222222222222','dddddddd-0000-0000-0000-000000000002') on conflict do nothing;
insert into wh.event_line(line_id,event_id,line_no,material_id,qty)
 values ('ffff0000-0000-0000-0000-00000000abe1','ffff0000-0000-0000-0000-0000000000e1',1,'cccccccc-0000-0000-0000-000000000001',10) on conflict do nothing;
insert into wh.evidence(event_id,bucket_path,sha256,bytes)
 values ('ffff0000-0000-0000-0000-0000000000e1','e/p.jpg',encode(sha256('x'),'hex'),4096) on conflict do nothing;
PSQL

cat > "$WORK/wh-backup.env" <<ENV
WH_DB_URL="dbname=$DB host=$PGHOST port=$PGPORT user=$PGUSER"
WH_STAGING_DIR="$WORK/staging"
WH_OFFSITE_DIR="$WORK/offsite"
WH_LOCAL_BUCKET="$WORK/bucket"
WH_RETAIN_DAYS="30"
ENV
chmod 600 "$WORK/wh-backup.env"

echo "== run the scheduled wrapper once =="
bash "$ROOT/backup/run-backup.sh" "$WORK/wh-backup.env" || { echo "wrapper failed"; exit 1; }
[ -f "$WORK/offsite/_status/status.json" ] || { echo "no status file"; exit 1; }

echo "== restore-check the produced offsite set =="
bash "$ROOT/backup/restore-check.sh" "$WORK/wh-backup.env" || exit 1

echo "== freshness signal =="
bash "$ROOT/backup/backup-status.sh" "$WORK/wh-backup.env" 8 >/dev/null || { echo "status reported stale"; exit 1; }

echo "== visible failure keeps the last good set =="
good="$(ls -1d "$WORK"/offsite/20*Z | tail -1)"
sed 's/dbname='"$DB"'/dbname=nope_no_db/' "$WORK/wh-backup.env" > "$WORK/bad.env"
if bash "$ROOT/backup/run-backup.sh" "$WORK/bad.env" >/dev/null 2>&1; then echo "a bad dump did NOT fail"; exit 1; fi
[ -d "$good" ] || { echo "a failed run destroyed the last good set"; exit 1; }
echo "  ok: bad dump failed loudly, last good set intact"
echo "BACKUP SCHEDULE DRILL PASSED"
