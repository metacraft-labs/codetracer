#!/usr/bin/env bash
# plat59-capture-electron.sh — PLAT-59: the REAL Electron front-end's Visual
# Replay panes on the `gl_scene` visual recording the native suites open: the
# Video Player's frame at three positions, a draw call, a picked pixel's
# history, the Shader Debug pane's context and a history row's click — the
# reference the terminal and GPUI panes are measured against. Writes
# `src/tests/visual/answers/plat59-visual-replay.electron.json`. It runs the
# built desktop (`just build-once`), opened as the desktop's gate opens a
# recorded GL trace; without a DISPLAY an Xvfb is started.
#
# Needs what the desktop needs to show a visual recording: `ct-mcr`
# (`CODETRACER_CT_MCR_CMD`, which extracts the stream), `ct_gfx_player`
# (`CODETRACER_CT_GFX_PLAYER_CMD`) and a license the player accepts
# (`CODETRACER_LICENSE_FILE`); `CODETRACER_VISUAL_REPLAY_ENV`, when set, is
# sourced first to provide them.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

if [ -n "${CODETRACER_VISUAL_REPLAY_ENV:-}" ]; then
	# shellcheck disable=SC1090 # the caller's environment file
	. "$CODETRACER_VISUAL_REPLAY_ENV"
fi

# THE RECORDING the native suites read, recorded when this host has none yet
# — so every front-end opens one recording.
fixture="${CODETRACER_VISUAL_REPLAY_FIXTURE:-$repo/test-logs/tui-fixtures/visual-gl-scene}"
if [ ! -f "$fixture/gfx_stream/gfx_frames.idx" ]; then
	bash scripts/record-visual-replay-fixture.sh "$fixture"
fi
export CODETRACER_VISUAL_REPLAY_FIXTURE="$fixture"

export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

run_spec() {
	just test-e2e tests/frame-viewer/plat59-visual-replay-capture.spec.ts "$@"
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
		trap 'own_xvfb_stop' EXIT
		own_xvfb_start -screen 0 2560x1440x24 -dpi 96 -nolisten tcp || exit 1
		run_spec "$@"
	fi
	;;
esac
