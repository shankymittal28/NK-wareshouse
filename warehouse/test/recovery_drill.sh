#!/usr/bin/env bash
# Recovery drill. A restore is only proven when a warehouse can be OPERATED from it.
# Builds a working warehouse, backs up database and evidence objects, destroys both,
# restores, and then does real work against the restored system.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
PGHOST="${PGHOST:-/tmp}"; PGPORT="${PGPORT:-5433}"; PGUSER="${PGUSER:-postgres}"; export PGHOST PGPORT PGUSER
BIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
WORK="${WH_DRILL_DIR:-$(mktemp -d)}"
LIVE=whlive; REST=whrestored
PSQL="psql -X -q -v ON_ERROR_STOP=1 --no-psqlrc"
Q() { psql -X -q -t -A --no-psqlrc -d "$1" -c "$2"; }
fail=0; say() { if [ "$2" = "$3" ]; then echo "  ok    $1 ($2)"; else echo "  NOT OK $1: expected $3, got $2"; fail=1; fi; }

echo "== build a working warehouse =="
$PSQL -d postgres -c "drop database if exists $LIVE;" >/dev/null
$PSQL -d postgres -c "create database $LIVE;" >/dev/null
$PSQL -d "$LIVE" -f "$HERE/000_supabase_stub.sql" >/dev/null
for f in "$ROOT"/migrations/*.sql; do $PSQL -d "$LIVE" -f "$f" >/dev/null || exit 1; done
$PSQL -d "$LIVE" -f "$HERE/001_fixtures.sql" >/dev/null
# an evidence object, as a real file with a checksum
mkdir -p "$WORK/bucket" "$WORK/backup"
printf 'bilty 4471, Zangi Transport, 20 sheets\n' > "$WORK/bucket/evidence.jpg"
SHA=$(sha256sum "$WORK/bucket/evidence.jpg" | cut -d' ' -f1)
Q "$LIVE" "select t.act_as('aaaaaaaa-0000-0000-0000-000000000002');
  select wh.record_opening('cccccccc-0000-0000-0000-000000000001', 50, now() - interval '2 days');
  select wh.submit_event(jsonb_build_object('draft_id','ab000000-0000-0000-0000-00000000dd01',
    'event_type','IN','effective_at',now()::text,'counterparty','Zangi Transport',
    'lines', jsonb_build_array(jsonb_build_object('material_id','cccccccc-0000-0000-0000-000000000001','qty',20))), 0);
  select wh.attach_evidence('ab000000-0000-0000-0000-00000000dd01','ev/2026-09-21/evidence.jpg','$SHA',
    $(stat -c%s "$WORK/bucket/evidence.jpg"), now());
  select t.act_as('aaaaaaaa-0000-0000-0000-000000000001');
  select wh.set_rate('cccccccc-0000-0000-0000-000000000001', 2150);" >/dev/null
say "the live warehouse works before the drill" "$(Q "$LIVE" "select wh.stock_as_of('cccccccc-0000-0000-0000-000000000001')")" "70.0000"

echo "== back up database and evidence =="
T0=$(date +%s)
$BIN/pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$LIVE" -n wh -n auth -f "$WORK/backup/warehouse.sql" || exit 1
cp -a "$WORK/bucket/." "$WORK/backup/objects/" 2>/dev/null || { mkdir -p "$WORK/backup/objects"; cp -a "$WORK/bucket/." "$WORK/backup/objects/"; }
(cd "$WORK/backup/objects" && sha256sum * > ../objects.manifest)
BACKUP_SECONDS=$(( $(date +%s) - T0 ))
say "the backup holds the schema, the data and the objects" \
    "$([ -s "$WORK/backup/warehouse.sql" ] && [ -s "$WORK/backup/objects/evidence.jpg" ] && echo yes || echo no)" "yes"

echo "== lose everything =="
$PSQL -d postgres -c "drop database $LIVE;" >/dev/null
rm -rf "$WORK/bucket"
say "the warehouse is gone" "$(Q postgres "select count(*) from pg_database where datname='$LIVE'")" "0"

echo "== restore =="
T1=$(date +%s)
$PSQL -d postgres -c "drop database if exists $REST;" >/dev/null
$PSQL -d postgres -c "create database $REST;" >/dev/null
$PSQL -d "$REST" -f "$WORK/backup/warehouse.sql" >/dev/null 2>"$WORK/restore.err" || { echo "  NOT OK restore failed"; head -5 "$WORK/restore.err"; exit 1; }
$PSQL -d "$REST" -f "$HERE/001_fixtures.sql" >/dev/null 2>&1   # test helpers only; data came from the dump
mkdir -p "$WORK/bucket"; cp -a "$WORK/backup/objects/." "$WORK/bucket/"
RESTORE_SECONDS=$(( $(date +%s) - T1 ))

echo "== can a warehouse be operated from it? =="
say "the schema came back whole" "$(Q "$REST" "select count(*) from pg_tables where schemaname='wh'")" "21"
say "the write path came back" "$(Q "$REST" "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='wh' and p.proname in ('submit_event','approve_count','correct_line','record_opening','draft_put','set_rate')")" "6"
say "row-level security came back" "$(Q "$REST" "select count(*) from pg_policies where schemaname='wh'")" "$(Q "$REST" "select count(*) from pg_tables where schemaname='wh'")"
say "materials, rates and configuration are present" \
    "$(Q "$REST" "select (select count(*) from wh.material) || ':' || (select count(*) from wh.rate) || ':' || (select count(*) from wh.category)")" "5:1:4"
say "history survived with its stock figure" "$(Q "$REST" "select wh.stock_as_of('cccccccc-0000-0000-0000-000000000001')")" "70.0000"
say "people and their device mappings came from the same restore point" \
    "$(Q "$REST" "select (select count(*) from wh.person) || ':' || (select count(*) from wh.device)")" "3:3"

# A real restore into a new project issues new keys, so every phone session dies.
# Re-activation is therefore part of recovery, not an afterthought.
Q "$REST" "insert into auth.users(id, is_anonymous) values ('cafe0000-0000-0000-0000-000000000001', true);" >/dev/null
CODE=$(Q "$REST" "select t.act_as('aaaaaaaa-0000-0000-0000-000000000001'); select wh.issue_activation_code('22222222-2222-2222-2222-222222222222');" | tail -1)
say "the owner can authenticate against the restored warehouse" \
    "$(Q "$REST" "select t.act_as('aaaaaaaa-0000-0000-0000-000000000001'); select wh.current_role();" | tail -1)" "owner"
say "a staff phone can be re-activated after the restore" \
    "$(Q "$REST" "select t.act_as('cafe0000-0000-0000-0000-000000000001'); select wh.activate_device('$CODE','Raj replacement phone') ->> 'person';" | tail -1)" "राज"
say "and record a real movement on the restored system" \
    "$(Q "$REST" "select t.act_as('cafe0000-0000-0000-0000-000000000001');
       select wh.submit_event(jsonb_build_object('draft_id','ab000000-0000-0000-0000-00000000dd02',
         'event_type','IN','effective_at',now()::text,
         'lines', jsonb_build_array(jsonb_build_object('material_id','cccccccc-0000-0000-0000-000000000001','qty',4))), 0) ->> 'lines';" | tail -1)" "1"
say "stock calculates correctly afterwards" "$(Q "$REST" "select wh.stock_as_of('cccccccc-0000-0000-0000-000000000001')")" "74.0000"

# evidence
P=$(Q "$REST" "select bucket_path from wh.evidence limit 1")
S=$(Q "$REST" "select sha256 from wh.evidence limit 1")
say "the evidence row points at an object that is really there" \
    "$([ -f "$WORK/bucket/$(basename "$P")" ] && echo yes || echo no)" "yes"
say "and the photograph is byte-for-byte the one that was taken" \
    "$(sha256sum "$WORK/bucket/$(basename "$P")" | cut -d' ' -f1)" "$S"

# permissions still enforced
say "staff still cannot read a rate after the restore" \
    "$(Q "$REST" "set role authenticated; select t.act_as('cafe0000-0000-0000-0000-000000000001'); select count(*) from wh.rate;" | tail -1)" "0"
say "the owner still can" \
    "$(Q "$REST" "set role authenticated; select t.act_as('aaaaaaaa-0000-0000-0000-000000000001'); select count(*) from wh.rate;" | tail -1)" "1"

echo "  backup took ${BACKUP_SECONDS}s, restore and verification took ${RESTORE_SECONDS}s"
$PSQL -d postgres -c "drop database if exists $REST;" >/dev/null
[ -n "${WH_DRILL_KEEP:-}" ] || rm -rf "$WORK"
exit $fail
