#!/usr/bin/env bash
# Proves every migration has a working rollback: apply all, roll all back, apply again.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
PGHOST="${PGHOST:-/tmp}"; PGPORT="${PGPORT:-5433}"; PGUSER="${PGUSER:-postgres}"; export PGHOST PGPORT PGUSER
DB=whrollback; PSQL="psql -X -q -v ON_ERROR_STOP=1 --no-psqlrc"
$PSQL -d postgres -c "drop database if exists $DB;" >/dev/null
$PSQL -d postgres -c "create database $DB;" >/dev/null
$PSQL -d "$DB" -f "$HERE/000_supabase_stub.sql" >/dev/null || exit 1
for f in "$ROOT"/migrations/*.sql; do $PSQL -d "$DB" -f "$f" >/dev/null || { echo "up failed: $f"; exit 1; }; done
n1=$(psql -X -t -A -d "$DB" -c "select count(*) from pg_tables where schemaname='wh'")
for f in $(ls -r "$ROOT"/migrations/down/*.down.sql); do
  $PSQL -d "$DB" -f "$f" >/dev/null || { echo "down failed: $f"; exit 1; }
done
n2=$(psql -X -t -A -d "$DB" -c "select count(*) from pg_namespace where nspname='wh'")
for f in "$ROOT"/migrations/*.sql; do $PSQL -d "$DB" -f "$f" >/dev/null || { echo "re-apply failed: $f"; exit 1; }; done
n3=$(psql -X -t -A -d "$DB" -c "select count(*) from pg_tables where schemaname='wh'")
$PSQL -d postgres -c "drop database if exists $DB;" >/dev/null
echo "  tables after first apply: $n1 | wh schema after rollback: $n2 | tables after re-apply: $n3"
[ "$n1" = "$n3" ] && [ "$n2" = "0" ] && echo "  ok    every migration rolls back and re-applies cleanly" || { echo "  NOT OK rollback is not clean"; exit 1; }
