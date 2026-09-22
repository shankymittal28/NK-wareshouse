#!/usr/bin/env bash
# Prove a produced set: restore the newest offsite set (or WH_SET) into a
# throwaway database and OPERATE the restored warehouse. Never touches
# production. Prints PASS/FAIL lines and exits non-zero on any failure.
#
#   restore-check.sh [path-to-env-file]
# Extra knobs (for CI / a scratch server):
#   WH_SCRATCH_URL  postgres connection to restore INTO (default: a temp local db)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
ENV_FILE="${1:-$HERE/wh-backup.env}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
OFF="${WH_OFFSITE_DIR:?set WH_OFFSITE_DIR}"
SET="${WH_SET:-$(ls -1d "$OFF"/20*Z 2>/dev/null | sort | tail -1)}"
[ -n "$SET" ] && [ -d "$SET" ] || { echo "FAIL no set to check"; exit 1; }
echo "checking set: $(basename "$SET")"

PGHOST="${PGHOST:-/tmp}"; PGPORT="${PGPORT:-5433}"; PGUSER="${PGUSER:-postgres}"
export PGHOST PGPORT PGUSER
DB="wh_restorecheck_$$"
Q(){ psql -X -q -t -A --no-psqlrc -d "$DB" -c "$1"; }
fail=0; say(){ if [ "$2" = "$3" ]; then echo "  PASS $1 ($2)"; else echo "  FAIL $1: expected $3 got $2"; fail=1; fi; }

psql -X -q -d postgres -c "drop database if exists $DB;" >/dev/null
psql -X -q -d postgres -c "create database $DB;" >/dev/null
psql -X -q -d "$DB" -f "$ROOT/test/000_supabase_stub.sql" >/dev/null 2>&1

OBJDIR="$(mktemp -d)"
if ! WH_RESTORE_URL="dbname=$DB host=$PGHOST port=$PGPORT user=$PGUSER" WH_SET="$SET" \
     WH_OBJECT_DIR="$OBJDIR/objects" bash "$ROOT/tools/restore.sh" >/dev/null 2>&1; then
  echo "  FAIL restore.sh errored"; psql -X -q -d postgres -c "drop database if exists $DB;" >/dev/null; exit 1
fi

say "wh schema restored"       "$(Q "select count(*)>0 from pg_tables where schemaname='wh'")" "t"
say "views restored"           "$(Q "select count(*)>0 from pg_views where schemaname='wh'")" "t"
say "the caretaker owns wh"    "$(Q "select pg_get_userbyid(nspowner) from pg_namespace where nspname='wh'")" "wh_owner"
say "the public API restored"  "$(Q "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'wh\_%'")" "28"
say "no client role holds a privilege inside wh" \
    "$(Q "select count(*) from information_schema.role_table_grants where table_schema='wh' and grantee in ('anon','authenticated','PUBLIC')")" "0"
# unrelated apps are NOT part of a warehouse restore
say "Tally/StaffPay/legacy are NOT in the set" \
    "$(Q "select count(*) from information_schema.tables where table_schema in ('mirror','raw') or table_name like 'sp\_%' or table_name like 'nkg\_%'")" "0"

# operate it: owner (from the restored identity) -> code -> anon activates -> movement -> stock
OWNER="$(Q "select value #>> '{}' from wh.setting where key='owner_email'")"
if [ -z "$OWNER" ]; then echo "  (no owner seeded in this set; operating checks skipped)";
else
  MAT="$(Q "select material_id from wh.material limit 1")"
  if [ -z "$MAT" ]; then
    MAT="$(psql -X -q -t -A -d "$DB" -c "set role wh_owner; select (wh.create_material('Plywood', jsonb_build_object('brand','RC','thickness','18mm','size','8x4'))->>'material_id');" 2>/dev/null | tail -1)"
  fi
  # Each owner interaction is ONE transaction (-1), because the role and the JWT
  # claim are transaction-local -- exactly as a single PostgREST request is.
  BASE="$(Q "select coalesce(wh.stock_as_of('$MAT'::uuid),0)")"
  CODE="$(psql -X -q -t -A -1 -d "$DB" <<PSQL 2>/dev/null | tail -1
set local role wh_owner;
select set_config('request.jwt.claims', json_build_object('email','$OWNER','role','authenticated')::text, true);
with p as (insert into wh.person(display_name,role) values ('Restore Check','staff') returning person_id)
select wh.issue_activation_code((select person_id from p), 15, 'add');
PSQL
)"
  TOK="$(psql -X -q -t -A -d "$DB" -c "set role anon; select public.wh_activate('$CODE','restore-check phone')->>'token';" 2>/dev/null | tail -1)"
  say "a device activates on the restored warehouse" "$([ -n "$TOK" ] && [ "$TOK" != "null" ] && echo yes || echo no)" "yes"
  psql -X -q -1 -d "$DB" <<PSQL >/dev/null 2>&1
set local role wh_owner;
select set_config('request.jwt.claims', json_build_object('email','$OWNER','role','authenticated')::text, true);
select public.wh_owner_set_rate('$MAT'::uuid, 1250);
PSQL
  EV="$(psql -X -q -t -A -d "$DB" -c "select gen_random_uuid()")"
  psql -X -q -d "$DB" -c "set role anon; select public.wh_submit_event('$TOK', jsonb_build_object('draft_id','$EV','event_type','IN','effective_at',now()::text,'lines',jsonb_build_array(jsonb_build_object('material_id','$MAT','qty',7))), 0);" >/dev/null 2>&1
  WANT="$(psql -X -q -t -A -d "$DB" -c "select ($BASE + 7)::numeric(18,4)")"
  say "a movement records and stock advances correctly" \
      "$(psql -X -q -t -A -d "$DB" -c "set role anon; select public.wh_stock_for_staff('$TOK','$MAT'::uuid)->>'qty';" 2>/dev/null | tail -1)" "$WANT"
  say "staff cannot read a rate (permission separation holds)" \
      "$(psql -X -q -t -A -d "$DB" -c "set role anon; select count(*) from wh.rate;" 2>&1 | grep -c 'permission denied')" "1"
fi

# evidence objects survived the round trip byte-for-byte
if [ -d "$SET/objects" ] && [ "$(find "$SET/objects" -type f | wc -l)" -gt 0 ]; then
  a="$(cd "$SET/objects" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
  b="$(cd "$OBJDIR/objects" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
  say "evidence objects restored byte-for-byte" "$([ "$a" = "$b" ] && echo yes || echo no)" "yes"
else echo "  (no evidence objects in this set)"; fi

psql -X -q -d postgres -c "drop database if exists $DB;" >/dev/null; rm -rf "$OBJDIR"
[ "$fail" = 0 ] && echo "RESTORE-CHECK PASSED" || echo "RESTORE-CHECK FAILED"
exit $fail
