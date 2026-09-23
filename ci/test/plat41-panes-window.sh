#!/usr/bin/env bash
# PLAT-41 — the thirteen panes on the shipped GPUI binary, and the eight
# newly expressed ones drawn in a real window.
#
#   bash ci/test/plat41-panes-window.sh            # capture
#   bash ci/test/plat41-panes-window.sh --inside   # internal
#
# Opens `codetracer-gpui` on the `calc` recording at the stop
# `src/tests/visual/plat41-scenario.json` declares, on a headless sway:
#
#   panes    the eight panes PLAT-41 expressed, laid out by
#            `plat41-layout.json` and FRAMED — PLAT-39's reader reads them.
#   all      all thirteen `PaneKind` values in one window
#            (`plat41-all-panes.json`); its `--plan-out` is the RUN tier of
#            the parity table — what the shipped binary drew per pane.
#   default  the default layout: the negative control, whose frame has none
#            of the eight but the debug controls.
#   blank    the compositor with no window.
#
# `src/tests/visual/screen_oracle/plat41_record.nim` turns the frames and the
# plan into `src/tests/visual/plat41-readings.json`;
# `test_plat41_parity.nim` asserts over it.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1
WS="$(cd "${root}/.." && pwd)"
ISONIM_GPUI="${WS}/isonim-gpui"
OUT="${root}/build/plat41"
BIN="${CODETRACER_PLAT41_BIN:-${root}/build/bin/codetracer-gpui}"
# shellcheck disable=SC2034  # read by gpui-window-capture.sh
TRACE="${CODETRACER_PLAT41_TRACE:-${root}/test-logs/tui-fixtures/calc-2f0db4f45192}"
# shellcheck disable=SC2034  # read by gpui-window-capture.sh
OPS="$(python3 -c "import json; print(json.load(open('${root}/src/tests/visual/plat41-scenario.json'))['gpuiOps'])")"
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
	capture_window panes "--layout=${root}/src/tests/visual/plat41-layout.json"
	capture_window all "--layout=${root}/src/tests/visual/plat41-all-panes.json"
	capture_window default
}

if [ "${INSIDE}" = "1" ]; then
	inside
	exit $?
fi

[ -x "${BIN}" ] || fail "${BIN} is not built"
[ -d "${TRACE}" ] || fail "the calc recording is not at ${TRACE} — run 'just test-tui' once"
for tool in sway wayland-info grim python3; do
	command -v "${tool}" >/dev/null 2>&1 || fail "'${tool}' is not on PATH"
done
[ "${CODETRACER_WINDOW_BIN_PINS_SHIM:-0}" = "1" ] ||
	fail "this lane needs a binary built with -d:gpuiShimPath=<windowed shim>
      (CODETRACER_WINDOW_BIN_PINS_SHIM=1); it does not swap the shared shim."
bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" -- \
	bash "${root}/ci/test/plat41-panes-window.sh" --inside
rc=$?
echo "plat41-panes-window: rc=${rc}"
exit "${rc}"
