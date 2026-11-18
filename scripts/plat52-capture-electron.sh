#!/usr/bin/env bash
# plat52-capture-electron.sh — PLAT-52: the REAL Electron front-end's Terminal
# Output pane on the two recordings the terminal lanes record
# (`test-programs/terminal_colours`, a program writing coloured lines, and
# `test-programs/terminal_screen`, a full-screen program): its lines and their
# computed styles, a click on a fragment, its screen view with the real-time
# scrubber and its marks — the reference the terminal and GPUI panes are
# measured against. Writes `src/tests/visual/answers/plat52-terminal.electron.json`.
# The prefix is this checkout's desktop JavaScript
# (`scripts/plat45-desktop-prefix.sh`); without a DISPLAY an Xvfb is started.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

mkdir -p test-logs
work="$(mktemp -d "$repo/test-logs/plat52-capture.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# THE RECORDINGS the terminal's suites read, recorded by the terminal lanes'
# own fixture provider when this host has not recorded them yet — so every
# front-end opens one recording.
if ! ls -d test-logs/tui-fixtures/terminal_colours-* >/dev/null 2>&1 ||
	! ls -d test-logs/tui-fixtures/terminal_screen-* >/dev/null 2>&1; then
	cat >"$work/record.nim" <<'NIM'
import fixtures/fixture_provider
for name in ["terminal_colours", "terminal_screen"]:
  let r = resolveFixture(FixtureSpec(
    name: name, program: "test-programs/" & name & "/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder), buildHint: "", blockedOn: ""))
  if r.outcome != foRecorded:
    quit("PLAT-52: could not record " & name & ": " & r.detail, 1)
  echo r.tracePath
NIM
	nim c -r --hints:off --warnings:off --path:src/frontend/tui/tests \
		--nimcache:"$work/nc-record" -o:"$work/record" "$work/record.nim"
fi

bash scripts/plat45-desktop-prefix.sh "$work/prefix" src/config/default_layout.json
export PLAT52_DESKTOP_PREFIX="$work/prefix"
export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

run_spec() {
	just test-e2e tests/visual/plat52-terminal-capture.spec.ts "$@"
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
		trap 'own_xvfb_stop; rm -rf "$work"' EXIT
		own_xvfb_start -screen 0 2560x1440x24 -dpi 96 -nolisten tcp || exit 1
		run_spec "$@"
	fi
	;;
esac
