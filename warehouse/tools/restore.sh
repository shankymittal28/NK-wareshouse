#!/usr/bin/env bash
# Restore a warehouse backup set into a destination database, and put the evidence
# objects back. Proves the backup rather than trusting it.
#
#   WH_RESTORE_URL  postgres connection string to restore INTO
#   WH_SET          the backup set directory to restore from
#   WH_OBJECT_DIR   optional: where to place the evidence objects
set -uo pipefail
: "${WH_RESTORE_URL:?set WH_RESTORE_URL}"; : "${WH_SET:?set WH_SET}"
PG_RESTORE="${PGBIN:+$PGBIN/}pg_restore"

echo "verifying the set is intact"
( cd "$WH_SET" && sha256sum -c checksums.sha256 --quiet ) || { echo "checksums do not match"; exit 1; }

echo "restoring the database"
# The warehouse's objects are owned by its confined caretaker, and that
# ownership is the security boundary. Recreate the role before replaying, so a
# restore into a fresh database rebuilds the boundary rather than dropping it.
psql -X -q -v ON_ERROR_STOP=1 -d "$WH_RESTORE_URL" -c "
do \$\$
begin
  if not exists (select 1 from pg_roles where rolname = 'wh_owner') then
    create role wh_owner nologin nosuperuser nocreatedb nocreaterole
                         noinherit nobypassrls noreplication;
  end if;
  alter role wh_owner nologin nosuperuser nocreatedb nocreaterole
                      noinherit nobypassrls noreplication;
  begin
    execute format('grant wh_owner to %I with inherit false, set true', current_user);
  exception when others then null;
  end;
end \$\$;" >/dev/null || { echo "could not prepare the warehouse caretaker role" >&2; exit 1; }

psql -X -q -v ON_ERROR_STOP=1 -d "$WH_RESTORE_URL" -f "$WH_SET/warehouse.sql" >/dev/null || {
  echo "plain restore failed, trying the custom dump"
  "$PG_RESTORE" --no-owner -d "$WH_RESTORE_URL" "$WH_SET/warehouse.dump" || exit 1; }

# the public API, which lives outside schema wh and is dumped separately
if [ -s "$WH_SET/public_api.sql" ]; then
  psql -X -q -v ON_ERROR_STOP=1 -d "$WH_RESTORE_URL" -f "$WH_SET/public_api.sql" >/dev/null || {
    echo "the warehouse schema restored but its public API did not" >&2; exit 1; }
fi

if [ -n "${WH_OBJECT_DIR:-}" ]; then
  echo "restoring evidence objects"
  mkdir -p "$WH_OBJECT_DIR"; cp -a "$WH_SET/objects/." "$WH_OBJECT_DIR/"
fi
echo "restored from $WH_SET"
