#!/bin/bash
# Roll back to the previous build (app_bk).
# Usage:  bash rollback.sh              restore app_bk as the live build (manual rollback)
#         bash rollback.sh <ts>         same, <ts> names the kept failed build (called by deploy.sh)
#         bash rollback.sh --restart-only   nothing was swapped yet: just start the current build again
# Exit codes: 0 = previous build is running | 2 = rollback failed -> manual fix needed
# Lines starting with "ROLLBACK" are shown by the Slack bot.
BASE_DIR=$(cd "$(dirname "$0")" && pwd)
. "$BASE_DIR/project.env"
[ -n "$JAR" ] && [ -n "$APP_DIR" ] || { echo "ERROR: project.env missing or incomplete in $BASE_DIR"; exit 1; }
mkdir -p "$BASE_DIR/logs"

ARG="${1:-$(date +%Y%m%d_%H%M%S)}"
BK="${APP_DIR}_bk"
ERR="${APP_DIR}_err_$ARG"

echo "ROLLBACK: stopping current build"
bash "$BASE_DIR/stop.sh"

if [ "$ARG" != "--restart-only" ]; then
  if [ ! -d "$BK" ]; then
    echo "ROLLBACK FAILED: no previous build ($BK) to restore"; exit 2
  fi
  if [ -d "$APP_DIR" ]; then
    mv "$APP_DIR" "$ERR" || { echo "ROLLBACK FAILED: cannot move $APP_DIR to $ERR"; exit 2; }
    echo "ROLLBACK: failed build kept as $ERR"
  fi
  mv "$BK" "$APP_DIR" || { echo "ROLLBACK FAILED: cannot restore $BK"; exit 2; }
  ls -dt "${APP_DIR}"_err_* 2>/dev/null | tail -n +3 | xargs -r rm -rf   # keep 2 newest _err
fi

echo "ROLLBACK: starting previous build"
bash "$BASE_DIR/start.sh"
if bash "$BASE_DIR/health.sh"; then
  echo "ROLLBACK: previous build is up"
  exit 0
fi
echo "ROLLBACK FAILED: previous build did not become ready"
exit 2
