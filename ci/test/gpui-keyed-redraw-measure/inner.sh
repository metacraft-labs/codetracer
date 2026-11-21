#!/usr/bin/env bash
# NOT-A-CI-GATE: run.sh's inner half, inside the compositor it starts.
# Inside sway: one window on calc, `n` x30 at 1.5 s, then F12 until it exits.
# inner.sh <out dir> <keyed|full> <codetracer-gpui binary>
set -uo pipefail
out="$1"
mode="$2"
bin="$3"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
mkdir -p "$out"
rm -f "$out/ended"
trace=$(find "${root}/test-logs/tui-fixtures" -maxdepth 1 -name "calc-*" -type d | sort | head -1)
if [ "$mode" = full ]; then export CODETRACER_GPUI_FULL_REDRAW=1; else unset CODETRACER_GPUI_FULL_REDRAW; fi
# The keys wait for the window's first frame (its frame report's sentinel is
# not ours to read, so the first-frame line in the gesture trace stands for
# it), then step on a fixed cadence: the cadence is the measurement's, and
# the steps' cost is read from the frame report, not from the clock.
bash -c "
  for _ in \$(seq 1 120); do grep -q 'gesture tick armed' '$out/run.log' 2>/dev/null && break; sleep 1; done
  sleep 5
  for i in \$(seq 1 30); do bash '${root}/ci/test/wtype-keys.sh' -k n; echo \"n \$i \$(date +%s%3N)\"; sleep 1.5; done
  sleep 4
  for _ in \$(seq 1 20); do [ -e '$out/ended' ] && break; bash '${root}/ci/test/wtype-keys.sh' -k F12; echo \"F12 \$(date +%s%3N)\"; sleep 2; done
" >"$out/keys.log" 2>&1 &
kp=$!
CODETRACER_GPUI_PROBE_SENTINEL=f12 CODETRACER_TUI_LAYOUT_DIR="$out/state" CODETRACER_GPUI_GESTURE_TRACE=1 \
	"$bin" --quit-after-ms=200000 --width=1600 --height=1000 \
	--frame-report="$out/frames.json" "$trace" >"$out/run.log" 2>&1
echo "rc=$?" >"$out/rc"
touch "$out/ended"
wait $kp
