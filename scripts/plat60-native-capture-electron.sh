#!/usr/bin/env bash
# plat60-native-capture-electron.sh — the REAL Electron front-end's Low Level
# Code view on an rr recording of the shared native fixture
# (`codetracer-native-test-programs/c/sudoku_solver`): its machine-code listing, the execution pointer, its
# header, and a step by instruction and back — the reference the terminal
# pane is measured against. Writes
# `src/tests/visual/answers/plat60-native-low-level-code.electron.json`. The
# prefix is this checkout's desktop JavaScript
# (`scripts/plat45-desktop-prefix.sh`); without a DISPLAY an Xvfb is started.
# Needs `ct-native-replay` (CT_NATIVE_REPLAY_PATH, or the
# codetracer-native-backend sibling's debug build) and rr.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

mkdir -p test-logs
work="$(mktemp -d "$repo/test-logs/plat60-native-capture.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# The replay worker, which `ct record` records the native fixture with and
# the replay server replays it through.
native_replay="${CT_NATIVE_REPLAY_PATH:-${CODETRACER_CT_NATIVE_REPLAY_CMD:-$repo/../codetracer-native-backend/target/debug/ct-native-replay}}"
if [ ! -x "$native_replay" ]; then
	echo "ct-native-replay not found at $native_replay (just ensure-ct-native-replay, or set CT_NATIVE_REPLAY_PATH)" >&2
	exit 1
fi
export CODETRACER_CT_NATIVE_REPLAY_CMD="$native_replay" CT_NATIVE_REPLAY_PATH="$native_replay"
# The e2e fixture skips an rr-recorded program unless told the backend is here.
export CODETRACER_RR_BACKEND_PRESENT=1
# `ct record` finds the worker on PATH (or in its config).
export PATH="$(dirname "$native_replay"):$PATH"
export NATIVE_TEST_PROGRAMS_REPO="${NATIVE_TEST_PROGRAMS_REPO:-$repo/../codetracer-native-test-programs}"

bash scripts/plat45-desktop-prefix.sh "$work/prefix" src/config/default_layout.json
export PLAT60_DESKTOP_PREFIX="$work/prefix"
export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

run_spec() {
	just test-e2e tests/low-level-code/plat60-native-low-level-code-capture.spec.ts "$@"
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
