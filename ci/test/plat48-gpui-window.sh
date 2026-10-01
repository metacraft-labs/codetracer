#!/usr/bin/env bash
# PLAT-48 — the top bar and the auto-hide panels in a REAL GPUI window,
# driven by a REAL pointer and REAL keys on a headless sway, framed with
# `grim` after every step. See `ci/test/plat48_gpui_window.py`.
#
#   bash ci/test/plat48-gpui-window.sh            # capture (needs the tools)
#   python3 ci/test/plat48_gpui_window.py record  # measure -> committed JSON
#
# Prerequisites are refused by name: sway, grim, wtype, tesseract, the
# windowed binary built against the windowed shim, REPLAY_SERVER_BIN.
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
	exec python3 "${root}/ci/test/plat48_gpui_window.py" capture
fi

for tool in sway grim wtype wayland-info tesseract python3; do
	command -v "${tool}" >/dev/null 2>&1 || fail "'${tool}' is not on PATH"
done
[ -n "${REPLAY_SERVER_BIN:-}" ] || fail "REPLAY_SERVER_BIN is not set"
[ "${CODETRACER_WINDOW_BIN_PINS_SHIM:-0}" = "1" ] ||
	fail "this lane needs a binary built with -d:gpuiShimPath=<windowed shim>
      (CODETRACER_WINDOW_BIN_PINS_SHIM=1); it does not swap the shared shim."
bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" -- \
	bash "${root}/ci/test/plat48-gpui-window.sh" --inside
rc=$?
echo "plat48-gpui-window: rc=${rc}"
exit "${rc}"
