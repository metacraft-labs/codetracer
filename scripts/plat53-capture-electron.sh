#!/usr/bin/env bash
# plat53-capture-electron.sh — PLAT-53: the REAL Electron front-end's Test
# Results pane over the PLAT-53 Noir crate (one passing and one failing test),
# before and after a real `ct test run`, and what a right-click on a row opens
# — the reference the terminal's and the GPUI window's panes are measured
# against. Writes `src/tests/visual/answers/plat53-test-results.electron.json`.
# Without a DISPLAY an Xvfb is started (2560x1440, 96 dpi).
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

run_spec() {
	just test-e2e tests/test-results-pane/plat53-test-results-capture.spec.ts "$@"
}

case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN* | *_NT* | Darwin)
	run_spec "$@"
	;;
*)
	if [ -n "${DISPLAY:-}" ]; then
		run_spec "$@"
	else
		display_num=99
		while [ -e "/tmp/.X${display_num}-lock" ]; do
			display_num=$((display_num + 1))
		done
		Xvfb ":${display_num}" -screen 0 2560x1440x24 -dpi 96 -nolisten tcp &
		xvfb_pid=$!
		trap 'kill $xvfb_pid 2>/dev/null || true' EXIT
		sleep 1
		export DISPLAY=":${display_num}"
		run_spec "$@"
	fi
	;;
esac
