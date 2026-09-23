#!/usr/bin/env bash
# PLAT-40 — the three producer-fed panes, drawn by a real GPUI window.
#
#   bash ci/test/plat40-panes-window.sh            # capture
#   bash ci/test/plat40-panes-window.sh --inside   # internal
#
# Opens `codetracer-gpui` on the `calc` recording in a real window on a
# headless sway, with the arrangement `src/tests/visual/plat40-layout.json`
# describes — the editor beside the call trace, the event log and the
# breakpoint list — advances it with the same operations the desktop capture
# performs (`PLAT40_OPS`, which sets one breakpoint through the engine), waits
# for the window to SETTLE (two identical non-blank grabs), and frames it with
# `grim`.
#
# Three frames, and the two that are not the subject are what make the subject
# mean anything:
#
#   panes      the subject: all three panes, fed by the producers.
#   default    the NEGATIVE CONTROL: the same run under the DEFAULT layout,
#              which has no breakpoint list — the reader must not find one.
#   blank      the compositor before any window exists: the reader must find
#              no pane at all.
#
# `src/tests/visual/screen_oracle/plat40_record.nim` reads the frames into
# PLAT-39's domain types and writes `src/tests/visual/plat40-readings.json`;
# `test_plat40_producers.nim` asserts over that record.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1
WS="$(cd "${root}/.." && pwd)"
ISONIM_GPUI="${WS}/isonim-gpui"
OUT="${root}/build/plat40"
BIN="${CODETRACER_PLAT40_BIN:-${root}/build/bin/codetracer-gpui}"
CALC="${CODETRACER_PLAT40_TRACE:-${root}/test-logs/tui-fixtures/calc-2f0db4f45192}"
LAYOUT="${root}/src/tests/visual/plat40-layout.json"
# The operations, in `--replay-ops`'s spelling. Kept in ONE place the desktop
# capture reads too (`plat40-scenario.json`), so the two front-ends cannot be
# driven to different stops.
# shellcheck disable=SC2034  # read by gpui-window-capture.sh
OPS="$(python3 -c "import json; print(json.load(open('${root}/src/tests/visual/plat40-scenario.json'))['gpuiOps'])")"
# shellcheck disable=SC2034  # read by gpui-window-capture.sh
TRACE="${CALC}"
# `OPS` and `TRACE` are read by the sourced library's `capture_window`.
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
	mkdir -p "${OUT}"
	capture_blank
	capture_window panes "--layout=${LAYOUT}"
	capture_window default
}

if [ "${INSIDE}" = "1" ]; then
	inside
	exit $?
fi

[ -x "${BIN}" ] || fail "${BIN} is not built"
[ -d "${CALC}" ] || fail "the calc recording is not at ${CALC} — run 'just test-tui' once"
for tool in sway wayland-info grim python3; do
	command -v "${tool}" >/dev/null 2>&1 || fail "'${tool}' is not on PATH"
done
[ "${CODETRACER_WINDOW_BIN_PINS_SHIM:-0}" = "1" ] ||
	fail "this lane needs a binary built with -d:gpuiShimPath=<windowed shim>
      (CODETRACER_WINDOW_BIN_PINS_SHIM=1); it does not swap the shared shim."
bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" -- \
	bash "${root}/ci/test/plat40-panes-window.sh" --inside
rc=$?
echo "plat40-panes-window: rc=${rc}"
exit "${rc}"
