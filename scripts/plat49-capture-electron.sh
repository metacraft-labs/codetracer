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

# Every step names itself before it runs, and an exit that is not 0 — a failed
# command under `set -e`, or a kill from an outer `timeout` — names the step it
# ended in and shows the prefix build's log before the work directory goes. The
# prefix build writes only to that log, so without this a hang in it, or a
# failure, left nothing on stdout or stderr.
step="start"
announce() {
	step="$1"
	echo "PLAT-49: $(date +%H:%M:%S) step: $step" >&2
}
on_exit() {
	local rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "PLAT-49: FAILED (exit $rc) in step: $step" >&2
		if [ -f "$work/prefix.build/build.log" ]; then
			echo "PLAT-49: last lines of the prefix build log:" >&2
			tail -40 "$work/prefix.build/build.log" >&2
		fi
	fi
	if declare -F own_xvfb_stop >/dev/null; then own_xvfb_stop; fi
	rm -rf "$work"
}
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# THE RECORDING the terminal's suites read, recorded by the terminal lanes'
# own fixture provider when this host has not recorded it yet (a CI job that
# runs no terminal lane first) — so both front-ends open one recording.
if ! ls -d test-logs/tui-fixtures/calc-* >/dev/null 2>&1; then
	announce "record the calc fixture"
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

announce "build the desktop prefix (repro build; log: $work/prefix.build/build.log)"
bash scripts/plat45-desktop-prefix.sh "$work/prefix" src/config/default_layout.json
export PLAT49_DESKTOP_PREFIX="$work/prefix"
export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

run_spec() {
	# Part A (the chrome) and part B (the panes, the session tabs): each writes
	# its own answers file.
	announce "run the capture specs"
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
		# Started through the shared helper, which waits for the display to
		# answer instead of sleeping (scripts/lib/own-xvfb.sh).
		. "$repo/scripts/lib/own-xvfb.sh"
		announce "start Xvfb"
		own_xvfb_start -screen 0 2560x1440x24 -dpi 96 -nolisten tcp || exit 1
		run_spec "$@"
	fi
	;;
esac
