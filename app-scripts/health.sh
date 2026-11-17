#!/bin/bash
# Jar-based health check (no port/URL): the app's java process (identified by its renamed jar path)
# must stay alive for STABLE_SECONDS after start.   Usage: bash health.sh [seconds]
# Exit codes: 0 = process stayed up | 2 = process died (fails immediately)
BASE_DIR=$(cd "$(dirname "$0")" && pwd)
. "$BASE_DIR/project.env"
[ -n "$JAR" ] && [ -n "$APP_DIR" ] || { echo "ERROR: project.env missing or incomplete in $BASE_DIR"; exit 1; }

T="${1:-$STABLE_SECONDS}"
t=0
while [ "$t" -lt "$T" ]; do
  if ! pgrep -f -- "$JAR" > /dev/null; then
    echo "Process exited ${t}s after start"; exit 2
  fi
  sleep 5; t=$((t + 5))
done
echo "Process $(pgrep -f -- "$JAR" | head -1) stayed up for ${T}s"
exit 0
