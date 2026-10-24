#!/bin/bash
# One local run loop. Only this checkout's bundled copy is stopped; an installed copy is left alone.
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT="$PWD"
APP="$PROJECT/build.noindex/Morrow.app"
EXE="$APP/Contents/MacOS/Morrow"
MODE="${1:-run}"
case "$MODE" in run|--verify|--logs|--telemetry|--debug) ;; *) echo "usage: $0 [--verify|--logs|--telemetry|--debug]" >&2; exit 2 ;; esac
local_pid() {
  local pid
  for pid in $(pgrep -x Morrow || true); do
    if [[ "$(ps -o comm= -p "$pid")" == "$EXE" ]]; then echo "$pid"; fi
  done
}
for pid in $(local_pid); do kill -TERM "$pid"; done
for ((tick=0; tick<50; tick++)); do
  [[ -z "$(local_pid)" ]] && break
  sleep 0.1
done
[[ -z "$(local_pid)" ]] || { echo "The previous development app has not quit; build stopped." >&2; exit 1; }
./build.sh
/usr/bin/open -n "$APP"
for ((tick=0; tick<50; tick++)); do
  [[ -n "$(local_pid)" ]] && break
  sleep 0.1
done
APP_PID="$(local_pid | head -1)"
[[ -n "$APP_PID" ]] || { echo "The development app did not stay running. Check for another installed Morrow copy and the app log." >&2; exit 1; }
case "$MODE" in
  --verify) echo "Morrow bundle launched (pid $APP_PID): $APP" ;;
  --logs) tail -F "$HOME/Library/Application Support/Morrow/index.noindex/app.log" ;;
  --telemetry) /usr/bin/log stream --info --style compact --predicate 'process == "Morrow"' ;;
  --debug) xcrun lldb -p "$APP_PID" ;;
esac
