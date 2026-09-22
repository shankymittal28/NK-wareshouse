#!/usr/bin/env bash
# The freshness signal. Prints the four things an owner needs to trust the
# backup, and exits non-zero if the newest valid offsite set is too old --
# so it can drive an alert later without any dashboard.
#
#   backup-status.sh [path-to-env-file] [max-age-hours (default 8)]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-$HERE/wh-backup.env}"; MAX_H="${2:-8}"
[ -f "$ENV_FILE" ] || { echo "no env file at $ENV_FILE"; exit 2; }
set -a; . "$ENV_FILE"; set +a
OFF="${WH_OFFSITE_DIR:?}"; ST="$OFF/_status/status.json"

newest="$(ls -1d "$OFF"/20*Z 2>/dev/null | sort | tail -1)"
valid=0
for d in "$OFF"/20*Z; do
  [ -d "$d" ] && [ -f "$d/checksums.sha256" ] && ( cd "$d" && sha256sum -c checksums.sha256 --quiet ) >/dev/null 2>&1 && valid=$((valid+1))
done
echo "NK Warehouse backup — freshness"
echo "  status file        : ${ST}"
[ -f "$ST" ] && sed -n 's/^/  /p' "$ST"
if [ -n "$newest" ] && [ -f "$newest/checksums.sha256" ]; then
  age=$(( ($(date -u +%s) - $(stat -c %Y "$newest/checksums.sha256")) / 60 ))
  echo "  newest valid set   : $(basename "$newest")  (${age} minutes old)"
else age=999999; echo "  newest valid set   : NONE"; fi
echo "  retained valid sets: $valid"
if [ "$age" -gt $(( MAX_H * 60 )) ]; then
  echo "  RESULT: STALE — newest valid backup is older than ${MAX_H}h"; exit 1
fi
echo "  RESULT: FRESH"
