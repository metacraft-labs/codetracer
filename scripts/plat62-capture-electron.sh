#!/usr/bin/env bash
# plat62-capture-electron.sh — PLAT-62: the REAL Electron front-end's
# Constraints pane over the PLAT-62 Noir crate, measured by the real
# `nargo info --json` — its rows, where each function is declared, what a
# right-click on a row opens and where a press goes — the reference the
# terminal's and the GPUI window's panes are measured against. Writes
# `src/tests/visual/answers/plat62-constraints.electron.json`.
# Without a DISPLAY an Xvfb is started (2560x1440, 96 dpi).
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

run_spec() {
	just test-e2e tests/constraints-pane/plat62-constraints-capture.spec.ts "$@"
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
