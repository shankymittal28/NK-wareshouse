#!/usr/bin/env bash
# =====================================================================
# The scheduled warehouse backup. This is the command the scheduler runs,
# every six hours, with no arguments and no secret on its command line.
#
#   run-backup.sh [path-to-env-file]     (defaults to wh-backup.env beside this file)
#
# It stages a set with the proven engine, verifies it, copies it to the
# offsite folder, verifies THAT copy, prunes old sets only after the new
# one is safely offsite, and writes a status file. A failed dump, a failed
# object copy, or a checksum mismatch fails the whole job visibly and
# leaves every previous good set untouched.
# =====================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ENV_FILE="${1:-$HERE/wh-backup.env}"

fail() { echo "BACKUP FAILED: $*" >&2; record_status "$1" fail; exit 1; }

record_status() {  # $1 = message, $2 = ok|fail
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$STATUS_DIR" 2>/dev/null || true
  local newest age count
  newest="$(ls -1d "$OFF"/20*Z 2>/dev/null | sort | tail -1)"
  if [ -n "$newest" ] && [ -f "$newest/checksums.sha256" ]; then
    age=$(( $(date -u +%s) - $(stat -c %Y "$newest/checksums.sha256" 2>/dev/null || echo 0) ))
  else age=""; fi
  count="$(ls -1d "$OFF"/20*Z 2>/dev/null | wc -l | tr -d ' ')"
  {
    echo "{"
    echo "  \"checked_at\": \"$now\","
    if [ "$2" = ok ]; then echo "  \"last_success\": \"$now\","; else
      echo "  \"last_success\": \"$(sed -n 's/.*"last_success": "\([^"]*\)".*/\1/p' "$STATUS_DIR/status.json" 2>/dev/null | head -1)\","; fi
    if [ "$2" = fail ]; then echo "  \"last_failure\": \"$now\","; echo "  \"last_failure_reason\": \"$1\","; else
      echo "  \"last_failure\": \"$(sed -n 's/.*"last_failure": "\([^"]*\)".*/\1/p' "$STATUS_DIR/status.json" 2>/dev/null | head -1)\","; fi
    echo "  \"newest_offsite_set\": \"$(basename "${newest:-none}")\","
    echo "  \"newest_offsite_age_seconds\": ${age:-null},"
    echo "  \"retained_offsite_sets\": ${count:-0},"
    echo "  \"schema_commit\": \"$(git -C "$ROOT/.." rev-parse --short HEAD 2>/dev/null || echo unknown)\""
    echo "}"
  } > "$STATUS_DIR/status.json.tmp" && mv "$STATUS_DIR/status.json.tmp" "$STATUS_DIR/status.json"
}

[ -f "$ENV_FILE" ] || { echo "BACKUP FAILED: no env file at $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
: "${WH_DB_URL:?set WH_DB_URL in the env file}"
: "${WH_STAGING_DIR:?set WH_STAGING_DIR}"; : "${WH_OFFSITE_DIR:?set WH_OFFSITE_DIR}"
RETAIN="${WH_RETAIN_DAYS:-30}"
OFF="$WH_OFFSITE_DIR"
STATUS_DIR="$WH_OFFSITE_DIR/_status"
LOG="$STATUS_DIR/backup.log"
mkdir -p "$WH_STAGING_DIR" "$OFF" "$STATUS_DIR" || { echo "BACKUP FAILED: cannot make dirs" >&2; exit 1; }

# one run at a time; if the last run is somehow still going, do not pile on
exec 9>"$STATUS_DIR/.lock"
if ! flock -n 9; then echo "BACKUP FAILED: a run is already in progress" >&2; exit 1; fi

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"; }
log "=== scheduled backup starting ==="

# 1-6. stage a set with the proven engine. Retention is disabled for the inner
# call: nothing old is pruned until the new set is safely offsite (step 9).
if ! WH_BACKUP_DIR="$WH_STAGING_DIR" WH_RETAIN_DAYS=100000 \
     bash "$ROOT/tools/backup.sh" >>"$LOG" 2>&1; then
  fail "the engine (dump / public API / evidence copy) reported an error"
fi
SET="$(ls -1d "$WH_STAGING_DIR"/20*Z 2>/dev/null | sort | tail -1)"
[ -n "$SET" ] && [ -d "$SET" ] || fail "no set was produced"
STAMP="$(basename "$SET")"
log "staged $STAMP"

# 7-verify the staged set before it is allowed to count as a backup
( cd "$SET" && sha256sum -c checksums.sha256 --quiet ) >>"$LOG" 2>&1 \
  || fail "the staged set failed its own checksums"
[ -s "$SET/warehouse.dump" ] && [ -s "$SET/warehouse.sql" ] && [ -s "$SET/public_api.sql" ] \
  || fail "the staged set is missing a required file"

# 7b. copy to offsite, then verify the OFFSITE copy independently
DEST="$OFF/$STAMP"
rm -rf "$DEST.partial" "$DEST" 2>/dev/null
cp -a "$SET" "$DEST.partial" || fail "could not copy the set offsite"
mv "$DEST.partial" "$DEST"
( cd "$DEST" && sha256sum -c checksums.sha256 --quiet ) >>"$LOG" 2>&1 \
  || fail "the offsite copy failed its checksums"
log "offsite copy verified at $DEST"

# 8-9. only now prune, on BOTH staging and offsite, and only sets that are
# themselves complete (have a checksums file). A failed future run cannot reach
# here, so it can never delete a previous good set.
for base in "$WH_STAGING_DIR" "$OFF"; do
  find "$base" -maxdepth 1 -type d -name '20*Z' -mtime +"$RETAIN" \
    -exec test -f '{}/checksums.sha256' ';' -exec rm -rf '{}' ';' 2>/dev/null || true
done

record_status "ok" ok
log "=== scheduled backup OK: $STAMP ==="
