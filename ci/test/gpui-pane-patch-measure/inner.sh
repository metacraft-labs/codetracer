#!/usr/bin/env bash
# Inside sway: one window on calc, `n` x30, then F12 until it exits.
# inner.sh <out dir> <patch|full> <codetracer-gpui binary>
set -uo pipefail
out="$1"; mode="$2"; bin="$3"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
mkdir -p "$out"; rm -f "$out/ended"
trace=$(ls -d "${root}"/test-logs/tui-fixtures/calc-* | head -1)
if [ "$mode" = full ]; then export CODETRACER_GPUI_FULL_REDRAW=1; else unset CODETRACER_GPUI_FULL_REDRAW; fi
bash -c "
  sleep 25
  for i in \$(seq 1 30); do bash '${root}/ci/test/wtype-keys.sh' -k n; echo \"n \$i \$(date +%s%3N)\"; sleep 1.5; done
  sleep 4
  for _ in \$(seq 1 20); do [ -e '$out/ended' ] && break; bash '${root}/ci/test/wtype-keys.sh' -k F12; echo \"F12 \$(date +%s%3N)\"; sleep 2; done
" >"$out/keys.log" 2>&1 &
kp=$!
CODETRACER_GPUI_PROBE_SENTINEL=f12 CODETRACER_TUI_LAYOUT_DIR="$out/state" CODETRACER_GPUI_GESTURE_TRACE=1 \
	"$bin" --quit-after-ms=200000 --width=1600 --height=1000 \
	--frame-report="$out/frames.json" "$trace" >"$out/run.log" 2>&1
echo "rc=$?" >"$out/rc"
touch "$out/ended"; wait $kp
