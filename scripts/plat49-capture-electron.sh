#!/usr/bin/env bash
# plat49-capture-electron.sh — PLAT-49: the REAL Electron front-end on the
# terminal lanes' `calc` recording: the desktop's root menu and its cascade,
# its transport tooltips and its omnibar placeholder (part A); its call-trace
# rows, event-log columns, footer auto-hide panels, GoldenLayout drop zones and
# session tabs (part B) — the reference the terminal and GPUI are measured
# against. Writes `src/tests/visual/answers/plat49-chrome.electron.json` and
# `src/tests/visual/answers/plat49-panes.electron.json`.
# The prefix is this checkout's desktop JavaScript
# (`scripts/plat45-desktop-prefix.sh`); without a DISPLAY an Xvfb is started.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

# Inside the checkout, for the reason `plat45-capture-electron.sh` gives: the
# prefix's real `index.js` / `ui.js` resolve `node_modules` by walking up.
mkdir -p test-logs
work="$(mktemp -d "$repo/test-logs/plat49-capture.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# THE RECORDING the terminal's suites read, recorded by the terminal lanes'
# own fixture provider when this host has not recorded it yet (a CI job that
# runs no terminal lane first) — so both front-ends open one recording.
if ! ls -d test-logs/tui-fixtures/calc-* >/dev/null 2>&1; then
	cat >"$work/record_calc.nim" <<'NIM'
import fixtures/fixture_provider
let r = resolveFixture("calc")
if r.outcome != foRecorded:
  quit("PLAT-49: could not record the calc fixture: " & r.detail, 1)
echo r.tracePath
NIM
	nim c -r --hints:off --warnings:off --path:src/frontend/tui/tests \
		--nimcache:"$work/nc-record" -o:"$work/record_calc" "$work/record_calc.nim"
fi

bash scripts/plat45-desktop-prefix.sh "$work/prefix" src/config/default_layout.json
export PLAT49_DESKTOP_PREFIX="$work/prefix"
export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

run_spec() {
	# Part A (the chrome) and part B (the panes, the session tabs): each writes
	# its own answers file.
	just test-e2e tests/visual/plat49-chrome-capture.spec.ts \
		tests/visual/plat49-panes-capture.spec.ts "$@"
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
		trap 'kill $xvfb_pid 2>/dev/null || true; rm -rf "$work"' EXIT
		sleep 1
		export DISPLAY=":${display_num}"
		run_spec "$@"
	fi
	;;
esac
