#!/usr/bin/env bash
# Rehearses the legacy import on synthetic rows shaped exactly like the old table,
# so the tooling is proved on every push even where the real data is not available.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
PGHOST="${PGHOST:-/tmp}"; PGPORT="${PGPORT:-5433}"; PGUSER="${PGUSER:-postgres}"; export PGHOST PGPORT PGUSER
DB=whimport; PSQL="psql -X -q -v ON_ERROR_STOP=1 --no-psqlrc"; Q() { psql -X -q -t -A --no-psqlrc -d "$DB" -c "$1"; }
fail=0; say() { if [ "$2" = "$3" ]; then echo "  ok    $1 ($2)"; else echo "  NOT OK $1: expected $3, got $2"; fail=1; fi; }

$PSQL -d postgres -c "drop database if exists $DB;" >/dev/null
$PSQL -d postgres -c "create database $DB;" >/dev/null
$PSQL -d "$DB" -f "$HERE/000_supabase_stub.sql" >/dev/null
for f in "$ROOT"/migrations/*.sql; do $PSQL -d "$DB" -f "$f" >/dev/null || exit 1; done
$PSQL -d "$DB" -f "$HERE/001_fixtures.sql" >/dev/null
$PSQL -d "$DB" -f "$HERE/fixtures_legacy_synthetic.sql" >/dev/null || exit 1

$PSQL -d "$DB" -f "$ROOT/tools/01_import_legacy.sql" >/dev/null || { echo "  NOT OK import failed"; exit 1; }
say "every source row is imported or parked" \
    "$(Q "select (select count(*) from wh.legacy_line) + (select count(*) from wh_import.exception where source_row_id is not null)")" \
    "$(Q "select count(*) from src.nkg_stock")"
say "no identity's expectation differs from the old rule" \
    "$(Q "select count(*) from wh_import.identity_map im left join wh.legacy_expected le on le.material_id=im.material_id where im.src_net is distinct from coalesce(le.expected_qty,0)")" "0"
say "a row with no brand is kept, with its quantity, and flagged for naming" \
    "$(Q "select count(*) from wh.material where needs_naming")" "1"
say "look-alike identities are kept apart" \
    "$(Q "select count(*) from (select norm_key from wh.material group by category_code, norm_key having count(*)>1) x")" "1"
say "a repeated tap within two minutes is flagged, not removed" \
    "$(Q "select count(*) from wh.legacy_line where suspect_duplicate_of is not null")" "1"
say "rates are attached by the old key" "$(Q "select count(*) from wh.rate")" "1"
say "a rate key matching nothing is reported" \
    "$(Q "select count(*) from wh_import.exception where reason='rate key matches no identity'")" "1"
say "photographs land on the old line, never on an event" \
    "$(Q "select (select count(*) from wh.legacy_photo) || ':' || (select count(*) from wh.evidence)")" "2:0"
say "no imported material has a stock figure, because none has been counted" \
    "$(Q "select count(*) from wh.material where origin='legacy_import' and wh.stock_as_of(material_id) is not null")" "0"

# determinism: the same input produces the same identities and no new rows
before=$(Q "select md5(string_agg(material_id::text, ',' order by material_id)) from wh.material")
rows_before=$(Q "select count(*) from wh.legacy_line")
$PSQL -d "$DB" -f "$ROOT/tools/01_import_legacy.sql" >/dev/null || exit 1
say "running the import twice creates the same identities" "$(Q "select md5(string_agg(material_id::text, ',' order by material_id)) from wh.material")" "$before"
say "and adds no duplicate history" "$(Q "select count(*) from wh.legacy_line")" "$rows_before"

$PSQL -d postgres -c "drop database if exists $DB;" >/dev/null
exit $fail
