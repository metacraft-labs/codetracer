#!/usr/bin/env bash
# plat68-desktop-keys.sh — PLAT-68 Phase B: the REAL Electron front-end's keys
# through the one router (`src/frontend/ui/key_router.nim`): F-keys dispatch
# once, letters and Enter in the read-only editor, Alt+E in the editor, Ctrl+B
# and Ctrl+Shift+B, and the user's keybindings.json (a row added, a row
# removed, the chord the toolbar shows, a reload without a restart).
#
# The recording is the one the terminal lanes record (`test-logs/tui-fixtures/
# calc-*`); the prefix is this checkout's desktop JavaScript and stylesheets
# (`scripts/plat45-desktop-prefix.sh`); without a DISPLAY an Xvfb is started.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

# `PLAT68_FIXTURES_DIR` names a recording set the built variant's `ct` and
# `replay-server` read (their container version); the default is this
# checkout's own.
fixtures="${PLAT68_FIXTURES_DIR:-$repo/test-logs/tui-fixtures}"
if ! ls -d "$fixtures/calc"-* >/dev/null 2>&1; then
	echo "FAIL: the 'calc' recording is not in $fixtures — run the tui lane once" >&2
	exit 1
fi
export PLAT68_FIXTURES_DIR="$fixtures"

mkdir -p test-logs
work="$(mktemp -d "$repo/test-logs/plat68-desktop.XXXXXX")"
trap 'rm -rf "$work"' EXIT

bash scripts/plat45-desktop-prefix.sh "$work/prefix" src/config/default_layout.json

# This checkout's stylesheets too (the pane focus ring), compiled into a
# `frontend/styles` of the prefix's own — as `plat51-capture-electron.sh`.
stylus_bin="$repo/node_modules/.bin/stylus"
if [ ! -x "$stylus_bin" ]; then
	common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)"
	stylus_bin="$(dirname "$common")/node_modules/.bin/stylus"
fi
built_frontend="$(readlink -f "$work/prefix/frontend")"
rm -f "$work/prefix/frontend"
mkdir -p "$work/prefix/frontend/styles"
for entry in "$built_frontend"/*; do
	[ "$(basename "$entry")" = styles ] && continue
	ln -sfn "$entry" "$work/prefix/frontend/$(basename "$entry")"
done
for entry in "$built_frontend"/styles/*; do
	ln -sfn "$entry" "$work/prefix/frontend/styles/$(basename "$entry")"
done
for theme in default_dark_theme_electron default_white_theme_electron; do
	rm -f "$work/prefix/frontend/styles/$theme.css"
	"$stylus_bin" "src/frontend/styles/$theme.styl" -o "$work/prefix/frontend/styles/" >/dev/null
done
export PLAT68_DESKTOP_PREFIX="$work/prefix"
export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

run_spec() {
	(cd src/tests/gui && env CODETRACER_DEV_TOOLS=0 npx playwright test --workers=1 \
		"${PLAT68_SPEC:-tests/keymaps/plat68b-desktop-keys.spec.ts}" "$@")
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
