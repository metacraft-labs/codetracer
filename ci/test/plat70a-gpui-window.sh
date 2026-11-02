#!/usr/bin/env bash
# PLAT-70 Part A — the GPUI window's text panes scrolled sideways by a REAL
# horizontal wheel, Shift + wheel and a bar press, on a headless sway, framed
# with `grim` after every step.
#
#   bash ci/test/plat70a-gpui-window.sh            # capture
#   bash ci/test/plat70a-gpui-window.sh --inside   # internal
#
# `ci/test/plat70a_gpui_window.py` holds the steps and says what each frame
# is; `python3 ci/test/plat70a_gpui_window.py record` measures the frames
# into the committed `src/tests/visual/plat70a-gpui-window.json` that
# `src/frontend/gpui/tests/test_plat70a_gpui_window.nim` asserts over.
#
# Needs: a binary pinned to the WINDOWED shim (`-d:gpuiShimPath=<windowed
# shim>`, `CODETRACER_WINDOW_BIN_PINS_SHIM=1`), isonim-gpui's
# `build/virtual-pointer` with its `hwheel` command
# (`scripts/build-virtual-pointer.sh`; `CODETRACER_VIRTUAL_POINTER` names
# another build), sway, grim and wtype, the `wide_lines` recording, and
# `REPLAY_SERVER_BIN`. Refused BY NAME, never skipped.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1
WS="$(cd "${root}/.." && pwd)"
ISONIM_GPUI="${ISONIM_GPUI_DIR:-${WS}/isonim-gpui}"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

if [ "${1:-}" = "--inside" ]; then
	exec python3 "${root}/ci/test/plat70a_gpui_window.py" capture
fi

for tool in sway grim wtype python3; do
	command -v "${tool}" >/dev/null 2>&1 || fail "'${tool}' is not on PATH"
done
[ -n "${REPLAY_SERVER_BIN:-}" ] || fail "REPLAY_SERVER_BIN is not set"
[ "${CODETRACER_WINDOW_BIN_PINS_SHIM:-0}" = "1" ] ||
	fail "this lane needs a binary built with -d:gpuiShimPath=<windowed shim>
      (CODETRACER_WINDOW_BIN_PINS_SHIM=1); it does not swap the shared shim."
bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" -- \
	bash "${root}/ci/test/plat70a-gpui-window.sh" --inside
rc=$?
echo "plat70a-gpui-window: rc=${rc}"
exit "${rc}"
