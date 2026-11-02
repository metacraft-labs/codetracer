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

# The specs: Phase B's keys (`plat68b`) and the real-stack boxes of the
# desktop's column (`plat68c`: the stepping F-keys once each in and out of the
# editor, a rebound step-over on every surface that shows it, the letters,
# VS Code's precedence and the shortcut reference, the layer stack, the
# inert-key note). `PLAT68_SPEC` names other spec files, space-separated.
read -r -a specs <<<"${PLAT68_SPEC:-tests/keymaps/plat68b-desktop-keys.spec.ts tests/keymaps/plat68c-desktop-keys.spec.ts}"

run_spec() {
	(cd src/tests/gui && env CODETRACER_DEV_TOOLS=0 npx playwright test --workers=1 \
		"${specs[@]}" "$@")
}

case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN* | *_NT* | Darwin)
	run_spec "$@"
	;;
*)
	if [ -n "${DISPLAY:-}" ]; then
		run_spec "$@"
	else
		# The specs start when the display answers, not after a fixed sleep: a
		# one-second sleep was outlasted on a loaded host and the run failed
		# with "Missing X server". Xvfb picks a free display itself and writes
		# its number and a newline to `-displayfd` only once it accepts
		# connections (Xserver(1), "-displayfd"), so a complete line in that
		# file is the readiness signal; `read` refuses a line without its
		# newline, so a half-written number is never taken.
		# `PLAT68_XVFB_WAIT_SECONDS` bounds the wait.
		wait_seconds="${PLAT68_XVFB_WAIT_SECONDS:-60}"
		display_file="$work/xvfb-display"
		: >"$display_file"
		Xvfb -displayfd 3 -screen 0 2560x1440x24 -dpi 96 -nolisten tcp \
			3>"$display_file" >"$work/xvfb.log" 2>&1 &
		xvfb_pid=$!
		trap 'kill $xvfb_pid 2>/dev/null || true; rm -rf "$work"' EXIT
		deadline=$((SECONDS + wait_seconds))
		until IFS= read -r display_num <"$display_file" && [ -n "$display_num" ]; do
			if ! kill -0 "$xvfb_pid" 2>/dev/null; then
				echo "FAIL: Xvfb exited before its display answered; its output:" >&2
				cat "$work/xvfb.log" >&2
				exit 1
			fi
			if [ "$SECONDS" -ge "$deadline" ]; then
				echo "FAIL: Xvfb's display did not answer within ${wait_seconds}s" \
					"(PLAT68_XVFB_WAIT_SECONDS); its output:" >&2
				cat "$work/xvfb.log" >&2
				exit 1
			fi
			sleep 0.1
		done
		export DISPLAY=":${display_num}"
		run_spec "$@"
	fi
	;;
esac
