#!/usr/bin/env bash
# PLAT-47 part B — the GPUI window at desktop parity, driven by a REAL pointer
# and a REAL key on a headless sway, framed with `grim` after every step.
#
#   bash ci/test/plat47-gpui-window.sh            # capture
#   bash ci/test/plat47-gpui-window.sh --inside   # internal
#
# `ci/test/plat47_gpui_window.py` holds the steps and says what each frame
# is; `just plat47-gpui-window-record` measures the frames into the committed
# `src/tests/visual/plat47-gpui-window.json` that
# `src/frontend/gpui/tests/test_plat47_gpui_window.nim` asserts over.
#
# Needs: a binary pinned to the WINDOWED shim (`-d:gpuiShimPath=<windowed
# shim>`, `CODETRACER_WINDOW_BIN_PINS_SHIM=1`), isonim-gpui's
# `build/virtual-pointer` (`scripts/build-virtual-pointer.sh`), sway, grim,
# wtype and tesseract, the `calc` and `call_pages` recordings, and
# `REPLAY_SERVER_BIN`. Refused BY NAME, never skipped. Run it from
# isonim-gpui's dev shell, which provides the compositor tools.
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
	exec python3 "${root}/ci/test/plat47_gpui_window.py" capture
fi

for tool in sway grim wtype wayland-info tesseract python3; do
	command -v "${tool}" >/dev/null 2>&1 || fail "'${tool}' is not on PATH"
done
[ -n "${REPLAY_SERVER_BIN:-}" ] || fail "REPLAY_SERVER_BIN is not set"
[ "${CODETRACER_WINDOW_BIN_PINS_SHIM:-0}" = "1" ] ||
	fail "this lane needs a binary built with -d:gpuiShimPath=<windowed shim>
      (CODETRACER_WINDOW_BIN_PINS_SHIM=1); it does not swap the shared shim."
bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" -- \
	bash "${root}/ci/test/plat47-gpui-window.sh" --inside
rc=$?
echo "plat47-gpui-window: rc=${rc}"
exit "${rc}"
