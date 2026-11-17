#!/bin/bash
BASE_DIR=$(cd "$(dirname "$0")" && pwd)
. "$BASE_DIR/project.env"
[ -n "$JAR" ] && [ -n "$APP_DIR" ] || { echo "ERROR: project.env missing or incomplete in $BASE_DIR"; exit 1; }

if pgrep -f -- "$JAR" > /dev/null; then
  echo "Already running (PID $(pgrep -f -- "$JAR")). Not starting again."
  exit 1
fi

cd "$APP_DIR" || exit 1
# extra JVM flags come from JAVA_OPTS in project.env (space separated)
nohup java -Xms"${XMS:-512m}" -Xmx"${XMX:-1g}" $JAVA_OPTS -jar "$JAR" > /dev/null 2>&1 &
echo "Started PID $!"
