#!/bin/bash
# Reproducible native-view inventory. Uses generated files and a fresh index; never the personal index/defaults.
# Build first: ./build.sh. Optional: MODELS=/path/to/local/models ./scripts/ui-smoke.sh
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT="$PWD"
APP="$PROJECT/build.noindex/Morrow.app"
MODELS="${MODELS:-$HOME/Library/Application Support/Morrow/Models}"
OUTPUT="${OUTPUT:-$PROJECT/.dev/ui-audit/$(date +%Y%m%d-%H%M%S)}"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/morrow-ui-audit.XXXXXX")"
FIXTURE="$(cd "$FIXTURE" && pwd -P)"
SUITE="com.iqbal.morrow.ui-audit.$(date +%s).$$"
FILES="$FIXTURE/files"
CODE="$FIXTURE/code"
INDEX="$FIXTURE/index"
mkdir -p "$OUTPUT" "$FILES" "$CODE"
[[ -x "$APP/Contents/Helpers/digup" ]] || { echo 'Build Morrow first: ./build.sh' >&2; exit 1; }
[[ -d "$MODELS" ]] || { echo 'Set MODELS to the downloaded local model folder.' >&2; exit 1; }
cat > "$FILES/receipt.txt" <<'TEXT'
Hardware store receipt. Peach paint, two brushes and a ladder. Total fifty dollars.
TEXT
cat > "$FILES/trip.txt" <<'TEXT'
Trip notes. We visited a beach at sunset and photographed the orange sky.
TEXT
cat > "$CODE/retry.swift" <<'SWIFT'
func retryRequest(attempts: Int, operation: () throws -> Void) throws {
    for _ in 0..<attempts { try operation() }
}
SWIFT
cp Tests/DigUpKitTests/Pictures/pattern-o6.jpg "$FILES/pattern.jpg"
export DIGUP_MODELS="$MODELS"
"$APP/Contents/Helpers/digup" index "$FILES" --index "$INDEX" > "$OUTPUT/index.log" 2>&1
"$APP/Contents/Helpers/digup" index "$CODE" --code --index "$INDEX" >> "$OUTPUT/index.log" 2>&1
# Calibrate estimates before timing UI readiness (Vision's first load can be slow).
"$APP/Contents/Helpers/digup" estimate "$FILES" --index "$INDEX" --json > "$OUTPUT/estimate.log" 2>&1

run_view() {
  local name="$1" page="$2" query="$3" width="$4" height="$5"
  if [[ -n "${VIEWS:-}" && " $VIEWS " != *" $name "* ]]; then return; fi
  printf '%s\t%s\t%s\n' "$name" "$width" "$height" >> "$OUTPUT/manifest.tsv"
  local png="$OUTPUT/$name.png" ax="$OUTPUT/$name.json"
  local offscreen=YES capture=NO
  if [[ "${ONSCREEN:-0}" == 1 ]]; then offscreen=NO; capture=YES; fi
  local args=(-defaultsSuite "$SUITE" -indexDir "$INDEX" -modelsDir "$MODELS"
    -roots "$FILES" -codeRoots "$CODE" -onboarded YES -peopleEnabled NO -hotkey none
    -onboardingLocations "$FILES" -codeLocations "$CODE" -debugOffscreen "$offscreen" -debugCapture "$capture" -debugQuit YES
    -debugWidth "$width" -debugHeight "$height" -debugSnapshot "$png" -debugAccessibility "$ax" -debugState "$OUTPUT/$name-state.json"
    -debugQuery "$query")
  if [[ "$page" != panel ]]; then args+=(-debugWindow "$page"); fi
  /usr/bin/open -n "$APP" --args "${args[@]}"
  local ready=0
  for ((tick=0; tick<400; tick++)); do
    if [[ -s "$png" && -s "$ax" && ( "$page" == panel || -s "$OUTPUT/$name-state.json" ) ]]; then ready=1; break; fi
    sleep 0.1
  done
  [[ "$ready" == 1 ]] || { echo "FAIL $name: snapshot/inventory missing; see $INDEX/app.log" >&2; exit 1; }
  echo "Captured $name"
}

run_view library library '' 1240 800
run_view browse-min browse '' 1000 640
run_view search search receipt 1240 800
run_view no-results search zzqxnovalidword 1000 640
run_view code-hint search 'code:' 1000 640
run_view code-results search 'code: retryRequest' 1240 800
run_view people people '' 1000 640
run_view activity activity '' 1000 640
for tab in general folders people code storage; do
  run_view "settings-$tab" "settings:$tab" '' 760 540
done
run_view add-folders settings:add '' 760 540
run_view add-code-folders settings:addcode '' 760 540
for step in welcome folders code shortcut ready; do
  run_view "onboarding-$step" "onboarding:$step" '' 680 600
done
run_view panel panel receipt 820 480

cp "$INDEX/app.log" "$OUTPUT/app.log"
python3 - "$OUTPUT" "$FIXTURE" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[1], 'fixture.json').write_text(json.dumps({'fixture': sys.argv[2], 'personalDataUsed': False}, indent=2))
PY
/usr/bin/defaults delete "$SUITE" >/dev/null 2>&1 || true
python3 "$PROJECT/scripts/verify-ui-inventory.py" "$OUTPUT"
echo "Evidence: $OUTPUT"
echo "Synthetic fixture retained for reproduction: $FIXTURE"
