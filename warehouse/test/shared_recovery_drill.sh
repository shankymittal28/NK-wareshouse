#!/usr/bin/env bash
# Warehouse-only recovery INSIDE a shared database.
#
# The warehouse lives in maios-tally-mirror beside the Tally mirror, StaffPay,
# the travel tables and the legacy NK app. The question this drill answers is
# the one that decides whether that is safe: can the warehouse be restored on
# its own, in place, without rolling anything else back?
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
PGHOST="${PGHOST:-/tmp}"; PGPORT="${PGPORT:-5433}"; PGUSER="${PGUSER:-postgres}"
export PGHOST PGPORT PGUSER
DB="${WH_SHARED_DB:-whshareddrill}"
PSQL="psql -X -q -v ON_ERROR_STOP=1 --no-psqlrc"
Q() { psql -X -q -t -A --no-psqlrc -d "$DB" -c "$1"; }
fail=0; say() { if [ "$2" = "$3" ]; then echo "  ok    $1 ($2)"; else echo "  NOT OK $1: expected $3, got $2"; fail=1; fi; }

echo "== a database shaped like the real shared project =="
$PSQL -d postgres -c "drop database if exists $DB;" >/dev/null 2>&1
$PSQL -d postgres -c "create database $DB;" >/dev/null
$PSQL -d "$DB" -f "$HERE/000_supabase_stub.sql" >/dev/null 2>&1
for f in "$ROOT"/migrations/*.sql; do
  $PSQL -d "$DB" -f "$f" >/dev/null 2>&1 || { echo "  migration failed: $(basename "$f")"; exit 1; }
done
$PSQL -d "$DB" -f "$HERE/001_fixtures.sql" >/dev/null 2>&1

# the co-tenants, standing in for what really shares this database
$PSQL -d "$DB" -c "
  create table public.sp_attendance(id int primary key, day date, status text);
  insert into public.sp_attendance values (1,'2026-09-01','present'),(2,'2026-09-02','absent');
  create table public.sp_staff(id int primary key, wage_type text);
  insert into public.sp_staff values (1,'daily');
  create schema mirror;
  create table mirror.voucher(id int primary key, amount numeric);
  insert into mirror.voucher values (1,100),(2,250),(3,75);
  create table public.nkg_stock(id int primary key, category text, qty numeric);
  insert into public.nkg_stock values (1,'Door',5),(2,'Plywood',12);" >/dev/null

$PSQL -d "$DB" -c "select t.act_as('tok-raj-1');
  select wh.record_opening('cccccccc-0000-0000-0000-000000000001', 60, now() - interval '2 days');" >/dev/null

BEFORE_WH=$(Q "select wh.stock_as_of('cccccccc-0000-0000-0000-000000000001')")
say "the warehouse is working" "$BEFORE_WH" "60.0000"
say "and it is sharing the database with three other applications" \
    "$(Q "select (select count(*) from public.sp_attendance)||':'||(select count(*) from mirror.voucher)||':'||(select count(*) from public.nkg_stock)")" "2:3:2"

echo "== back up the warehouse alone =="
export WH_DB_URL="postgresql:///$DB?host=$PGHOST&port=$PGPORT&user=$PGUSER"
export WH_BACKUP_DIR="$(mktemp -d)/backup"; mkdir -p "$WH_BACKUP_DIR"
bash "$ROOT/tools/backup.sh" >/dev/null || { echo "  backup failed"; exit 1; }
SET="$(ls -1d "$WH_BACKUP_DIR"/*/ | tail -1)"

OUTSIDE=$(grep -cE '^(CREATE|ALTER|COPY|GRANT|REVOKE|DROP) ' "$SET/warehouse.sql" \
          | xargs -I{} echo {} >/dev/null; \
          grep -E '^(CREATE|COPY|GRANT|REVOKE|ALTER|DROP) ' "$SET/warehouse.sql" \
          | grep -vicE '\bwh\.|schema wh|"wh"|wh_owner' || true)
say "nothing in the backup touches anything outside the warehouse" "$OUTSIDE" "0"

echo "== the warehouse is destroyed, the rest is not =="
$PSQL -d "$DB" -c "alter schema wh rename to wh_wrecked;" >/dev/null
say "the warehouse is gone" "$(Q "select count(*) from pg_namespace where nspname='wh'")" "0"
say "payroll is still there" "$(Q "select count(*) from public.sp_attendance")" "2"

echo "== restore the warehouse in place, inside the shared database =="
export WH_SET="$SET" WH_RESTORE_URL="$WH_DB_URL"
bash "$ROOT/tools/restore.sh" >/dev/null 2>&1 || { echo "  NOT OK restore failed"; fail=1; }

say "the warehouse is back" "$(Q "select wh.stock_as_of('cccccccc-0000-0000-0000-000000000001')")" "60.0000"
say "with its boundary intact -- still owned by the caretaker" \
    "$(Q "select pg_get_userbyid(nspowner) from pg_namespace where nspname='wh'")" "wh_owner"
say "and its public API" \
    "$(Q "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'wh\_%'")" "29"

echo "== and the neighbours never noticed =="
say "StaffPay attendance unchanged" "$(Q "select count(*) from public.sp_attendance")" "2"
say "StaffPay staff unchanged"      "$(Q "select count(*) from public.sp_staff")" "1"
say "the Tally mirror unchanged"    "$(Q "select count(*)||':'||sum(amount) from mirror.voucher")" "3:425"
say "the legacy NK app unchanged"   "$(Q "select count(*) from public.nkg_stock")" "2"
say "no StaffPay policy was touched" \
    "$(Q "select count(*) from pg_policies where schemaname='public' and tablename like 'sp\_%'")" "0"

$PSQL -d "$DB" -c "drop schema if exists wh_wrecked cascade;" >/dev/null 2>&1
[ -n "${WH_DRILL_KEEP:-}" ] || { $PSQL -d postgres -c "drop database if exists $DB;" >/dev/null; rm -rf "$(dirname "$WH_BACKUP_DIR")"; }
exit $fail
