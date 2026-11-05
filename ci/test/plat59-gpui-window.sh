#!/usr/bin/env bash
# plat59-gpui-window.sh — the Video Player's frames, read from a REAL GPUI
# window's pixels on a headless sway (`ci/test/plat59_gpui_window.py capture`);
# `ci/test/plat59_gpui_window.py record` commits the measurement, and
# `src/frontend/gpui/tests/test_plat59_gpui_window.nim` asserts it against the
# recorded program and the desktop. Linux has no off-screen GPUI renderer
# (`gpui_render_to_pixels` answers 2 there), so a window is how pixels are read.
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
	exec python3 "${root}/ci/test/plat59_gpui_window.py" capture
fi

for tool in sway grim wtype python3; do
	command -v "${tool}" >/dev/null 2>&1 || fail "'${tool}' is not on PATH"
done
[ -n "${REPLAY_SERVER_BIN:-}" ] || fail "REPLAY_SERVER_BIN is not set"
[ -n "${CODETRACER_CT_GFX_PLAYER_CMD:-}" ] ||
	fail "CODETRACER_CT_GFX_PLAYER_CMD is not set (the visual replay player)"
[ "${CODETRACER_WINDOW_BIN_PINS_SHIM:-0}" = "1" ] ||
	fail "this lane needs a binary built with -d:gpuiShimPath=<windowed shim>
      (CODETRACER_WINDOW_BIN_PINS_SHIM=1); it does not swap the shared shim."
bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" -- \
	bash "${root}/ci/test/plat59-gpui-window.sh" --inside
rc=$?
echo "plat59-gpui-window: rc=${rc}"
exit "${rc}"
