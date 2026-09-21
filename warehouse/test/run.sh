#!/usr/bin/env bash
# Builds a template database from the versioned migrations, then runs every test file
# against its own fresh copy, so no test can depend on another.
# Usage: warehouse/test/run.sh [name-fragment]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
PGHOST="${PGHOST:-/tmp}"; PGPORT="${PGPORT:-5433}"; PGUSER="${PGUSER:-postgres}"
TMPL="${WH_TEMPLATE_DB:-whtemplate}"
export PGHOST PGPORT PGUSER
PSQL="psql -X -q -v ON_ERROR_STOP=1 --no-psqlrc"

echo "== building $TMPL from migrations =="
$PSQL -d postgres -c "drop database if exists $TMPL;" >/dev/null || exit 1
$PSQL -d postgres -c "create database $TMPL;" >/dev/null || exit 1
$PSQL -d "$TMPL" -f "$HERE/000_supabase_stub.sql" >/dev/null || { echo "stub failed"; exit 1; }
for f in "$ROOT"/migrations/*.sql; do
  $PSQL -d "$TMPL" -f "$f" >/dev/null || { echo "MIGRATION FAILED: $(basename "$f")"; exit 1; }
done
$PSQL -d "$TMPL" -f "$HERE/001_fixtures.sql" >/dev/null || { echo "fixtures failed"; exit 1; }
echo "   $(ls "$ROOT"/migrations/*.sql | wc -l) migrations, fixtures loaded"

pass=0; fail=0; total_assertions=0; failed_files=()
fresh() {  # $1 = database name
  $PSQL -d postgres -c "drop database if exists $1;" >/dev/null
  $PSQL -d postgres -c "create database $1 template $TMPL;" >/dev/null
}

shopt -s nullglob
for t in "$HERE"/t_*.sql; do
  name="$(basename "$t")"
  [ -n "${1:-}" ] && [[ "$name" != *"$1"* ]] && continue
  db="wht_$(echo "$name" | tr -cd 'a-z0-9')"
  fresh "$db" || { echo "could not create $db"; exit 1; }
  out="$(psql -X -q --no-psqlrc -v ON_ERROR_STOP=1 -d "$db" -f "$t" 2>&1)"; rc=$?
  n_ok=$(grep -c 'NOTICE: *ok ' <<<"$out"); n_bad=$(grep -c 'NOTICE: *NOT OK' <<<"$out")
  total_assertions=$((total_assertions + n_ok))
  if [ $rc -ne 0 ] || [ "$n_bad" -gt 0 ]; then
    fail=$((fail+1)); failed_files+=("$name")
    echo "FAIL  $name  (${n_ok} ok, ${n_bad} not-ok)"
    grep -E '(NOT OK|ERROR:)' <<<"$out" | head -12 | sed 's/^/      /'
  else
    pass=$((pass+1)); echo "ok    $name  (${n_ok} assertions)"
  fi
  $PSQL -d postgres -c "drop database if exists $db;" >/dev/null
done

if [ -z "${1:-}" ] || [[ "concurrency" == *"$1"* ]]; then
  fresh whtconc || exit 1
  echo "run   concurrency.sh"
  if WH_TEST_DB=whtconc bash "$HERE/concurrency.sh"; then pass=$((pass+1))
  else fail=$((fail+1)); failed_files+=("concurrency.sh"); fi
  $PSQL -d postgres -c "drop database if exists whtconc;" >/dev/null
fi

echo "== suites passed: $pass  failed: $fail  assertions: $total_assertions =="
[ $fail -eq 0 ] || { printf '   failing: %s\n' "${failed_files[*]}"; exit 1; }
