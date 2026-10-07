#!/usr/bin/env bash
# plat51-capture-electron.sh — PLAT-51: the REAL Electron front-end's share of
# the milestone and the reference the terminal and GPUI are measured against:
# no Timeline (tab, View menu, a saved layout that held one), the list panes'
# scrollbar scrubbers (Event Log, Call Trace, the Terminal Output's line
# view) and the changed-value style. Writes
# `src/tests/visual/answers/plat51-desktop.electron.json`.
# The recordings are the ones the terminal lanes record
# (`test-logs/tui-fixtures/`: noir_space_ship, call_pages, terminal_colours,
# calc); the prefix is this checkout's desktop JavaScript
# (`scripts/plat45-desktop-prefix.sh`); without a DISPLAY an Xvfb is started.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

for name in noir_space_ship call_pages terminal_colours calc; do
	if ! ls -d "test-logs/tui-fixtures/$name"-* >/dev/null 2>&1; then
		echo "FAIL: the '$name' recording is not in test-logs/tui-fixtures/ — run the tui lane once" >&2
		exit 1
	fi
done

mkdir -p test-logs
work="$(mktemp -d "$repo/test-logs/plat51-capture.XXXXXX")"
trap 'rm -rf "$work"' EXIT

bash scripts/plat45-desktop-prefix.sh "$work/prefix" src/config/default_layout.json

# THIS CHECKOUT'S STYLESHEETS TOO: PLAT-51 changes the desktop's CSS (the
# list scrubbers, the changed-value accent), and the prefix links the built
# variant's `frontend/` — so the theme sheets are compiled here, from
# `src/frontend/styles`, into a `frontend/styles` of the prefix's own (every
# other entry stays a link to the build's).
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
export PLAT51_DESKTOP_PREFIX="$work/prefix"
export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

run_spec() {
	just test-e2e tests/visual/plat51-desktop-capture.spec.ts "$@"
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
