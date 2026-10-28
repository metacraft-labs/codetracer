#!/usr/bin/env bash
# build-tasks-electron.sh — the REAL Electron front-end's build tasks, task
# picker, Stop, BUILD panel reveal and editor diagnostics
# (`src/tests/gui/tests/build/build-tasks.spec.ts`; Build-Output-Pane.md
# §3.2, §3.6, §3.8, §3.9, §3.11, §3.12): real `gcc` builds of the PLAT-56
# project run by the desktop's own main process. Without a DISPLAY an Xvfb is
# started (2560x1440, 96 dpi). Needs `gcc` on PATH (the dev shell's).
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

run_spec() {
	just test-e2e tests/build/build-tasks.spec.ts "$@"
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
