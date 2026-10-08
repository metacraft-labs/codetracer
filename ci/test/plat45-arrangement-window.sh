#!/usr/bin/env bash
# PLAT-45 — the arrangement the GPUI window OPENS WITH, in a real window.
#
#   bash ci/test/plat45-arrangement-window.sh            # capture
#   bash ci/test/plat45-arrangement-window.sh --inside   # internal
#
# Opens the windowed `codetracer-gpui` on the `calc` recording on a headless
# sway (isonim-gpui's `wayland-run-test.sh`), with NO remembered layout — the
# product's state root is a fresh directory, so the window opens the one shared
# default arrangement and not whatever a developer last left — and frames it
# with `grim` once it has settled (`ci/lib/gpui-window-capture.sh`):
#
#   shared   the window as it opens: what a user of the GPUI front-end sees
#            first, and what `test_plat45_three_media.nim` compares with the
#            desktop's and the terminal's first screens;
#   blank    the compositor with no window — the negative control on which
#            the reader must find no arrangement at all.
#
# `src/tests/visual/screen_oracle/plat45_window_record.nim` (`just
# plat45-window-record`) reads the frames through PLAT-39's pixel reader and
# commits `src/tests/visual/plat45-gpui-arrangement.json`; the portable suite
# asserts over that record — the measure-locally-commit-the-measurement
# arrangement PLAT-40/41/44 use, because a compositor is not a CI dependency.
#
# PREREQUISITES are refused BY NAME, never skipped: sway, wayland-info, grim,
# the `calc` recording and a binary that pins the WINDOWED shim.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1
WS="$(cd "${root}/.." && pwd)"
ISONIM_GPUI="${WS}/isonim-gpui"
OUT="${root}/build/plat45"
BIN="${CODETRACER_PLAT45_BIN:-${root}/build/bin/codetracer-gpui-window}"
# shellcheck disable=SC2034  # read by gpui-window-capture.sh
TRACE="${CODETRACER_PLAT45_TRACE:-${root}/test-logs/tui-fixtures/calc-2f0db4f45192}"
# shellcheck disable=SC2034  # read by gpui-window-capture.sh
OPS="next=3"
# shellcheck source=/dev/null
. "${root}/ci/lib/gpui-window-capture.sh"
INSIDE=0
[ "${1:-}" = "--inside" ] && INSIDE=1

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

inside() {
	rm -rf "${OUT}"
	mkdir -p "${OUT}/state"
	# THE PRODUCT'S OWN MEMORY IS EMPTY: the window must open the shared
	# default, and a remembered `gpui-layout.json` would open something else.
	export CODETRACER_TUI_LAYOUT_DIR="${OUT}/state"
	capture_blank
	capture_window shared "--dock-out=${OUT}/shared.dock.json"
	# Nothing was remembered by merely opening a window.
	if [ -n "$(ls -A "${OUT}/state")" ]; then
		echo "FAIL: opening the window wrote a remembered layout" >&2
		return 1
	fi
}

if [ "${INSIDE}" = "1" ]; then
	inside
	exit $?
fi

[ -x "${BIN}" ] || fail "${BIN} is not built"
[ -d "${TRACE}" ] || fail "the calc recording is not at ${TRACE} — run 'just test-tui' once"
for tool in sway wayland-info grim; do
	command -v "${tool}" >/dev/null 2>&1 || fail "'${tool}' is not on PATH"
done
[ "${CODETRACER_WINDOW_BIN_PINS_SHIM:-0}" = "1" ] ||
	fail "this lane needs a binary built with -d:gpuiShimPath=<windowed shim>
      (CODETRACER_WINDOW_BIN_PINS_SHIM=1); it does not swap the shared shim."
bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" -- \
	bash "${root}/ci/test/plat45-arrangement-window.sh" --inside
rc=$?
echo "plat45-arrangement-window: rc=${rc}"
exit "${rc}"
