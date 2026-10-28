#!/usr/bin/env bash
# plat58-capture-electron.sh — PLAT-58: the REAL Electron front-end's REQUESTS
# panel on the RS-M4 demo session (the container `just demo-request-panel`
# writes) — the reference the terminal's and the GPUI window's panes are
# measured against. Writes `src/tests/visual/answers/plat58-requests.electron.json`.
# Without a DISPLAY an Xvfb is started (2560x1440, 96 dpi).
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

# The demo session, written by the canonical writer (the producer
# `just demo-request-panel` runs).
work="$(mktemp -d "${TMPDIR:-/tmp}/ct-plat58-capture-XXXXXX")"
trap 'rm -rf "$work"' EXIT
nim c -d:release --hints:off --warnings:off --nimcache:"$work/nimcache" \
	--out:"$work/demo_request_session" src/tools/demo_request_session.nim
"$work/demo_request_session" "$work/demo" >/dev/null
export PLAT58_DEMO_TRACE="$work/demo"

run_spec() {
	just test-e2e tests/request-panel/plat58-requests-capture.spec.ts "$@"
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
