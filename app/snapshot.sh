#!/bin/zsh
# Developer check: opens a recording in a test copy of MadStudio and saves a picture of the window.
# Works in a separate data folder (copies of projects, shared models), so the user's
# projects and edits are never touched.
#   app/snapshot.sh <recording|-> <out.png> [delay] [--auto-clean|--demo|--show-models]
#   app/snapshot.sh <recording> --record <out.mov> [seconds] [--demo]
set -e
cd "$(dirname "$0")"
SRC="$1"; shift
REAL="$HOME/Library/Application Support/MadStudio"
TEST="${TMPDIR:-/tmp}/madstudio-test-home"
mkdir -p "$TEST/projects"
ln -sfn "$REAL/models" "$TEST/models"
rsync -a --exclude 'edits.json' "$REAL/projects/" "$TEST/projects/"
APP="$TEST/MadStudio.app"
rm -rf "$APP"
cp -R ../MadStudio.app "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.madstudio.test" "$APP/Contents/Info.plist"
codesign -f -s - "$APP" 2>/dev/null
OPEN=(--open "$SRC")
[[ "$SRC" == "-" ]] && OPEN=()   # "-": start without a recording
if [[ "$1" == "--record" ]]; then
  ARGS=("${OPEN[@]}" --record "$2" --record-seconds "${3:-12}" "${@:4}")
  WAIT=$(( ${3:-12} + 10 ))
else
  ARGS=("${OPEN[@]}" --snapshot "$1" --snapshot-delay "${2:-5}" "${@:3}")
  WAIT=$(( ${2:-5} + 30 ))
fi
MADSTUDIO_HOME="$TEST" "$APP/Contents/MacOS/MadStudio" "${ARGS[@]}" >/dev/null 2>&1 &
PID=$!
for i in $(seq 1 $WAIT); do sleep 1; kill -0 $PID 2>/dev/null || exit 0; done
kill $PID 2>/dev/null || true
