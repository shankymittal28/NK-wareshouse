#!/usr/bin/env bash
# Independent warehouse backup: the database, the evidence objects, and a manifest.
# Written to a destination OUTSIDE the warehouse Supabase project, so losing or
# corrupting that project cannot destroy the primary and the backup together.
#
#   WH_DB_URL       postgres connection string for the warehouse database
#   WH_BACKUP_DIR   destination directory (a mounted disk, a synced folder, an object store mount)
#   WH_STORAGE_URL  optional: Supabase storage base, e.g. https://<ref>.supabase.co/storage/v1
#   WH_STORAGE_KEY  optional: service key, read from the environment only
#   WH_BUCKET       optional: evidence bucket name (default wh-evidence)
#   WH_RETAIN_DAYS  optional: how long to keep sets (default 30)
#
# No credential is ever written to a file, printed, or committed.
set -uo pipefail
: "${WH_DB_URL:?set WH_DB_URL}"; : "${WH_BACKUP_DIR:?set WH_BACKUP_DIR}"
BUCKET="${WH_BUCKET:-wh-evidence}"; RETAIN="${WH_RETAIN_DAYS:-30}"
# The dump tool must be at least the server's version, so it is taken from PATH
# unless PGBIN points somewhere specific.
PG_DUMP="${PGBIN:+$PGBIN/}pg_dump"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SET="$WH_BACKUP_DIR/$STAMP"
mkdir -p "$SET/objects" || exit 1
echo "backup set $STAMP"

# 1. the database, as a logical dump: portable, restorable into any Postgres
# Ownership and privileges are BOTH kept. Two drills taught this. Stripping
# privileges restores a database nobody can read, because the grants that let
# the app roles reach the schema go missing. Stripping ownership is worse: the
# confined caretaker IS the security boundary, so a restore that hands the
# warehouse to whoever ran it quietly rebuilds the system without its boundary.
# restore.sh recreates the caretaker first, so the dump always lands correctly.
"$PG_DUMP" -n wh -Fc -f "$SET/warehouse.dump" "$WH_DB_URL" || {
  echo "database dump failed"; exit 1; }
# a plain-text copy too, so a restore never depends on a matching pg_restore build
"$PG_DUMP" -n wh -f "$SET/warehouse.sql" "$WH_DB_URL" || exit 1

# 1b. the public API. The wrappers in 0009 are the only warehouse objects that
# live outside schema wh, so a -n wh dump misses them -- a recovery drill caught
# exactly that. They are extracted by name, never by dumping schema public,
# which holds other applications' tables that are none of the warehouse's business.
psql -X -q -t -A --no-psqlrc -d "$WH_DB_URL" -o "$SET/public_api.sql" -c "
  select string_agg(def, E'\n\n') from (
    select pg_get_functiondef(p.oid) || E';\n'
           || E'alter function ' || n.nspname || '.' || p.proname
           || '(' || pg_get_function_identity_arguments(p.oid) || ') owner to '
           || quote_ident(pg_get_userbyid(p.proowner)) || ';'
           || coalesce(E'\n' || (select string_agg(
                  'grant execute on function ' || n.nspname || '.' || p.proname || '('
                  || pg_get_function_identity_arguments(p.oid) || ') to ' || quote_ident(g) || ';',
                  E'\n')
                from unnest(array['anon','authenticated','service_role']) g
               where has_function_privilege(g, p.oid, 'EXECUTE')), '') as def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like 'wh\\_%'
     order by p.proname) x" || exit 1
if [ ! -s "$SET/public_api.sql" ]; then
  echo "refusing to write a backup with no public API in it" >&2; exit 1
fi

# 2. the evidence objects. Supabase database backups do not restore object contents,
#    so they are copied here on their own.
if [ -n "${WH_STORAGE_URL:-}" ] && [ -n "${WH_STORAGE_KEY:-}" ]; then
  psql -X -t -A -d "$WH_DB_URL" -c \
    "select bucket_path from wh.evidence union select bucket_path from wh.legacy_photo" \
  | while read -r p; do
      [ -z "$p" ] && continue
      mkdir -p "$SET/objects/$(dirname "$p")"
      curl -fsS -H "Authorization: Bearer $WH_STORAGE_KEY" \
        "$WH_STORAGE_URL/object/$BUCKET/$p" -o "$SET/objects/$p" \
        || echo "MISSING OBJECT $p" >> "$SET/objects.missing"
    done
elif [ -n "${WH_LOCAL_BUCKET:-}" ]; then
  cp -a "$WH_LOCAL_BUCKET/." "$SET/objects/" 2>/dev/null || true
fi

# 3. what a person needs in order to restore, and to prove nothing rotted
{
  echo "set: $STAMP"
  echo "database: warehouse.dump (custom) and warehouse.sql (plain), schema wh only"
  echo "objects: $(find "$SET/objects" -type f | wc -l) files"
  echo "schema version: see the repository, warehouse/migrations, at the commit below"
  echo "commit: $(git -C "$(dirname "$0")/../.." rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "restore: warehouse/tools/restore.sh, and warehouse/BACKUP.md"
  echo "identities: people and devices are inside the dump; after restoring into a new"
  echo "  project every phone session ends, so each device re-activates with a fresh code"
} > "$SET/README.txt"
( cd "$SET" && find . -type f ! -name checksums.sha256 -print0 | sort -z \
    | xargs -0 sha256sum > checksums.sha256 )

# 4. retention
find "$WH_BACKUP_DIR" -maxdepth 1 -type d -name '20*Z' -mtime +"$RETAIN" -exec rm -rf {} + 2>/dev/null
echo "wrote $SET ($(du -sh "$SET" | cut -f1)), keeping $RETAIN days"
