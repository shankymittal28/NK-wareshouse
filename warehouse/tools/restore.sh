#!/usr/bin/env bash
# Restore a warehouse backup set into a destination database, and put the evidence
# objects back. Proves the backup rather than trusting it.
#
#   WH_RESTORE_URL  postgres connection string to restore INTO
#   WH_SET          the backup set directory to restore from
#   WH_OBJECT_DIR   optional: where to place the evidence objects
set -uo pipefail
: "${WH_RESTORE_URL:?set WH_RESTORE_URL}"; : "${WH_SET:?set WH_SET}"
BIN="${PGBIN:-/usr/lib/postgresql/16/bin}"

echo "verifying the set is intact"
( cd "$WH_SET" && sha256sum -c checksums.sha256 --quiet ) || { echo "checksums do not match"; exit 1; }

echo "restoring the database"
psql -X -q -v ON_ERROR_STOP=1 -d "$WH_RESTORE_URL" -f "$WH_SET/warehouse.sql" >/dev/null || {
  echo "plain restore failed, trying the custom dump"
  "$BIN/pg_restore" --no-owner -d "$WH_RESTORE_URL" "$WH_SET/warehouse.dump" || exit 1; }

if [ -n "${WH_OBJECT_DIR:-}" ]; then
  echo "restoring evidence objects"
  mkdir -p "$WH_OBJECT_DIR"; cp -a "$WH_SET/objects/." "$WH_OBJECT_DIR/"
fi
echo "restored from $WH_SET"
