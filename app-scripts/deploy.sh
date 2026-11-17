#!/bin/bash
# Java app deploy with automatic rollback.   Usage: bash deploy.sh [branch]
# Exit codes: 0 = deployed
#             1 = failed, previous build restored and running (or another deploy is running)
#             2 = failed AND rollback failed -> manual fix needed
# Lines starting with "STEP:", "ROLLBACK", "FAILED", "REPORT", "ERROR", "OK:" are what the Slack bot shows.
# On failure a report is written to logs/error_<ts>.log (see write_report).
BASE_DIR=$(cd "$(dirname "$0")" && pwd)
. "$BASE_DIR/project.env"
[ -n "$JAR" ] && [ -n "$APP_DIR" ] || { echo "ERROR: project.env missing or incomplete in $BASE_DIR"; exit 1; }
mkdir -p "$BASE_DIR/logs"

# ---- outer layer: single-deploy lock + copy all output to logs/deploy_<ts>.log ----
if [ -z "$DEPLOY_LOG" ]; then
  export DEPLOY_TS=$(date +%Y%m%d_%H%M%S)
  export DEPLOY_LOG="$BASE_DIR/logs/deploy_$DEPLOY_TS.log"
  set -o pipefail
  # -o: children (gradle daemon, java) must not inherit the lock
  flock -n -E 99 -o "$BASE_DIR/.deploy.lock" bash "$0" "$@" 2>&1 | tee "$DEPLOY_LOG"
  rc=${PIPESTATUS[0]}
  [ "$rc" -eq 99 ] && { echo "ERROR: another deploy is already running in $BASE_DIR"; rc=1; rm -f "$DEPLOY_LOG"; }
  [ "$rc" -eq 0 ] && rm -f "$DEPLOY_LOG"     # success = no log left behind
  ls -t "$BASE_DIR"/logs/deploy_*.log 2>/dev/null | tail -n +11 | xargs -r rm -f   # keep last 10
  exit "$rc"
fi

# ---- inner layer: the actual deploy ----
set -e
TS=$DEPLOY_TS
BRANCH="${1:-$DEFAULT_BRANCH}"
BK="${APP_DIR}_bk"
SWAPPED=0
STEP=init

step() { STEP="$*"; echo "STEP: $*"; }

# Failure report, written BEFORE rollback moves the failed build away.
# Covers every stage: git/patch/build errors are in the deploy output tail;
# start/health failures also include the app's own log (runtime/logs/error.log).
write_report() {
  local f="$BASE_DIR/logs/error_$TS.log"
  sleep 1   # let tee flush the last lines
  {
    echo "project : $(basename "$BASE_DIR")"
    echo "branch  : $BRANCH"
    echo "time    : $TS"
    echo "failed  : $STEP (rc=$1)"
    echo "full log: $DEPLOY_LOG"
    echo "---------------- last 100 lines of deploy output ----------------"
    tail -n 100 "$DEPLOY_LOG"
    case "$STEP" in
      start*|health*)
        echo "---------------- app log ($APP_LOG, last 150) ----------------"
        tail -n 150 "$APP_DIR/$APP_LOG" 2>/dev/null ;;
    esac
  } > "$f" 2>&1
  echo "REPORT: $f"
  # whole report goes to stdout between markers; run_deploy.py sends it to Slack
  echo "REPORT-BEGIN"; cat "$f"; echo "REPORT-END"
  ls -t "$BASE_DIR"/logs/error_*.log 2>/dev/null | tail -n +11 | xargs -r rm -f   # keep last 10
}

on_exit() {
  local rc=$?
  trap - EXIT
  [ "$rc" -eq 0 ] && return 0
  set +e
  echo "FAILED: step '$STEP' (rc=$rc)"
  write_report "$rc"
  if [ "$SWAPPED" = 1 ]; then bash "$BASE_DIR/rollback.sh" "$TS"; else bash "$BASE_DIR/rollback.sh" --restart-only; fi
  if [ $? -eq 0 ]; then exit 1; else exit 2; fi
}
trap on_exit EXIT
trap 'exit 143' TERM INT HUP

echo "Deploying branch: $BRANCH"

step "stop - stopping app"
bash "$BASE_DIR/stop.sh"

step "backup - moving current build to _bk"
rm -rf "$BK"
if [ -d "$APP_DIR" ]; then mv "$APP_DIR" "$BK"; fi
SWAPPED=1

step "clone - $BRANCH"
git clone --branch "$BRANCH" -- "$REPO" "$APP_DIR"

if [ -n "$PRE_BUILD_CMD" ]; then
  step "prebuild - running PRE_BUILD_CMD"
  ( cd "$APP_DIR" && bash -c "$PRE_BUILD_CMD" )
fi

step "build - building jar"
bash "$BASE_DIR/build.sh"

step "start - starting app"
bash "$BASE_DIR/start.sh"

step "health - checking the process stays up (${STABLE_SECONDS}s)"
bash "$BASE_DIR/health.sh"

echo "OK: $BRANCH deployed"
exit 0
