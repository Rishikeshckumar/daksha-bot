#!/bin/bash
set -e
BASE_DIR=$(cd "$(dirname "$0")" && pwd)
. "$BASE_DIR/project.env"
[ -n "$JAR" ] && [ -n "$APP_DIR" ] || { echo "ERROR: project.env missing or incomplete in $BASE_DIR"; exit 1; }

cd "$APP_DIR"
bash -c "${BUILD_CMD:-./gradlew --no-daemon clean jar}"

# rename so the running process is identifiable in ps/pgrep
mv -f "$APP_DIR/${BUILT_JAR:-build/libs/app.jar}" "$JAR"
