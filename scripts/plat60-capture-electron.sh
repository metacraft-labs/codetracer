#!/usr/bin/env bash
# plat60-capture-electron.sh — PLAT-60: the REAL Electron front-end's Low
# Level Code view on the `noir_space_ship` recording the terminal lanes
# record: its listing, the execution pointer, its header, an instruction's
# right-click menu and a click on an instruction — the reference the terminal
# and GPUI panes are measured against. Writes
# `src/tests/visual/answers/plat60-low-level-code.electron.json`. The prefix
# is this checkout's desktop JavaScript (`scripts/plat45-desktop-prefix.sh`);
# without a DISPLAY an Xvfb is started.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

mkdir -p test-logs
work="$(mktemp -d "$repo/test-logs/plat60-capture.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# THE RECORDING the terminal's suites read, recorded by the terminal lanes'
# own fixture provider when this host has not recorded it yet — so every
# front-end opens one recording.
if ! ls -d test-logs/tui-fixtures/noir_space_ship-* >/dev/null 2>&1; then
	cat >"$work/record.nim" <<'NIM'
import fixtures/fixture_provider
let r = resolveFixture("noir_space_ship")
if r.outcome != foRecorded:
  quit("PLAT-60: could not record noir_space_ship: " & r.detail, 1)
echo r.tracePath
NIM
	nim c -r --hints:off --warnings:off --path:src/frontend/tui/tests \
		--nimcache:"$work/nc-record" -o:"$work/record" "$work/record.nim"
fi

bash scripts/plat45-desktop-prefix.sh "$work/prefix" src/config/default_layout.json
export PLAT60_DESKTOP_PREFIX="$work/prefix"
export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

run_spec() {
	just test-e2e tests/low-level-code/plat60-low-level-code-capture.spec.ts "$@"
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
