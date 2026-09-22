#!/usr/bin/env bash
# Two phones confirming the same movement at the same moment, and a journal replayed twice.
# Each psql -c is one transaction, and the actor a credential establishes is
# transaction-local, so becoming Raj and recording must travel together.
set -uo pipefail
PGHOST="${PGHOST:-/tmp}"; PGPORT="${PGPORT:-5433}"; PGUSER="${PGUSER:-postgres}"
DB="${WH_TEST_DB:-whtest}"; export PGHOST PGPORT PGUSER
Q() { psql -X -q --no-psqlrc -t -A -d "$DB" -c "$1"; }
fail=0
say() { if [ "$2" = "$3" ]; then echo "  ok    $1 ($2)"; else echo "  NOT OK $1: expected $3, got $2"; fail=1; fi; }

Q "select t.act_as('tok-raj-1'); select wh.record_opening('cccccccc-0000-0000-0000-000000000001', 100, now() - interval '3 days');" >/dev/null

DOC=$(cat <<'JSON'
{"draft_id":"cc000000-0000-0000-0000-00000000aa01","event_type":"IN","effective_at":"__NOW__",
 "counterparty":"Zangi Transport",
 "lines":[{"line_id":"cc000000-0000-0000-0000-00000000bb01","material_id":"cccccccc-0000-0000-0000-000000000001","qty":20},
          {"line_id":"cc000000-0000-0000-0000-00000000bb02","material_id":"cccccccc-0000-0000-0000-000000000002","qty":5}]}
JSON
)
NOW=$(Q "select now()::text")
DOC=${DOC/__NOW__/$NOW}

# eight simultaneous confirmations of the same identity
for i in $(seq 1 8); do
  psql -X -q --no-psqlrc -t -A -d "$DB" \
    -c "select t.act_as('tok-raj-1');
        select wh.submit_event(\$json\$$DOC\$json\$::jsonb, 0)" >/dev/null 2>&1 &
done
wait
say "eight simultaneous confirmations create one event" \
    "$(Q "select count(*) from wh.stock_event where event_id='cc000000-0000-0000-0000-00000000aa01'")" "1"
say "and exactly its two lines" \
    "$(Q "select count(*) from wh.event_line where event_id='cc000000-0000-0000-0000-00000000aa01'")" "2"
say "with one stock effect" \
    "$(Q "select wh.stock_as_of('cccccccc-0000-0000-0000-000000000001')")" "120.0000"

# a whole offline journal replayed twice
J1='{"draft_id":"cc000000-0000-0000-0000-00000000aa02","event_type":"IN","effective_at":"'$NOW'","lines":[{"material_id":"cccccccc-0000-0000-0000-000000000001","qty":7}]}'
J2='{"draft_id":"cc000000-0000-0000-0000-00000000aa03","event_type":"OUT","effective_at":"'$NOW'","lines":[{"material_id":"cccccccc-0000-0000-0000-000000000001","qty":3}]}'
for pass in 1 2; do
  Q "select t.act_as('tok-raj-1');
     select wh.submit_event(\$json\$$J1\$json\$::jsonb, 0);
     select wh.submit_event(\$json\$$J2\$json\$::jsonb, 0);" >/dev/null
done
say "replaying the journal twice leaves the same stock" \
    "$(Q "select wh.stock_as_of('cccccccc-0000-0000-0000-000000000001')")" "124.0000"
say "and the same number of events" \
    "$(Q "select count(*) from wh.stock_event where event_id in ('cc000000-0000-0000-0000-00000000aa02','cc000000-0000-0000-0000-00000000aa03')")" "2"
exit $fail
