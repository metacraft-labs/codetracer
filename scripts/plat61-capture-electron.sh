#!/usr/bin/env bash
# plat61-capture-electron.sh — PLAT-61: the REAL Electron front-end's Shell
# pane running a recorded build — the reference the terminal's and the GPUI
# window's Shell panes are measured against. Writes
# `src/tests/visual/answers/plat61-shell.electron.json`. Without a DISPLAY an
# Xvfb is started (2560x1440, 96 dpi).
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

ct="${CT_BIN:-$repo/src/build-debug/bin/ct}"
work="$(mktemp -d "${TMPDIR:-/tmp}/ct-plat61-capture-XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Every `ct` this script runs indexes its recordings in a scratch home, never
# the user's (the Playwright fixtures give the app its own).
export CODETRACER_HOME="$work/ct-home"
mkdir -p "$CODETRACER_HOME"
: >"$CODETRACER_HOME/.codetracer-test-home"

# The session the window opens: a recording made by this build's `ct record`.
mkdir -p "$work/session-src"
printf 'x = 41\nprint(x + 1)\n' >"$work/session-src/session.py"
"$ct" record -o "$work/session" "$work/session-src/session.py" >/dev/null
export PLAT61_SESSION_TRACE="$work/session"

# The recorded build the pane's shell runs (the native suites run the same
# script), and the shell: bash with a fixed prompt, this build's `ct` first.
mkdir -p "$work/project"
cat >"$work/project/build.sh" <<'BUILD'
#!/bin/sh
cd "$(dirname "$0")"
echo "building prog.py"
printf 'def add(a, b):\n    return a + b\nprint("sum", add(2, 3))\nprint("done")\n' > prog.py
rm -rf rec-build
ct record -o rec-build prog.py
BUILD
chmod +x "$work/project/build.sh"
printf "PS1='\$ '\n" >"$work/shellrc"
export PLAT61_PROJECT="$work/project"
export CODETRACER_SHELL_COMMAND="bash --noprofile --rcfile $work/shellrc -i"
PATH="$(dirname "$ct"):$PATH"
export PATH

run_spec() {
	just test-e2e tests/shell/plat61-shell-capture.spec.ts "$@"
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
