#!/bin/bash
BASE_DIR=$(cd "$(dirname "$0")" && pwd)
. "$BASE_DIR/project.env"
[ -n "$JAR" ] && [ -n "$APP_DIR" ] || { echo "ERROR: project.env missing or incomplete in $BASE_DIR"; exit 1; }

PIDS=$(pgrep -f -- "$JAR")
if [ -z "$PIDS" ]; then
  echo "Not running."
  exit 0
fi

echo "Stopping PID $PIDS ..."
kill $PIDS                                   # clean shutdown
for i in $(seq 1 30); do                     # wait up to 90 seconds
  pgrep -f -- "$JAR" > /dev/null || { echo "Stopped."; exit 0; }
  sleep 3
done

echo "Did not stop in 90s, forcing."
pkill -9 -f -- "$JAR"
sleep 2
if pgrep -f -- "$JAR" > /dev/null; then
  echo "ERROR: could not stop the app (PID $(pgrep -f -- "$JAR" | tr '\n' ' ')). Check who owns the process."
  exit 1
fi
echo "Stopped (forced)."
exit 0
