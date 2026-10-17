#!/usr/bin/env bash
# plat35-gpui-window-capture.sh [view] — PLAT-35's GPUI arm on Linux, as a real
# window on GuiAssert's headless sway (see `ci/test/plat35_gpui_window_capture.nim`
# for why: GPUI has no headless renderer off macOS).
#
#   1. isonim-gpui's windowed shim (`--features gpui-backend`), in its shell,
#      and that shell's LD_LIBRARY_PATH;
#   2. this checkout's `build/bin/codetracer-gpui-window`, pinned to it;
#   3. the capture, in GuiAssert's shell (`GUI_ASSERT_DIR`, default
#      ../GuiAssert), into `build/plat35/gpui-window/<view>.ppm`, and each
#      frame converted to `<view>.png`.
# Needs `src/build-debug/bin/replay-server` (`just build-once`) and the `calc`
# recording (`just test-tui` once). Run inside this repo's dev shell.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS="$(cd "${root}/.." && pwd)"
ISONIM_GPUI="$(cd "${ISONIM_GPUI_DIR:-${WS}/isonim-gpui}" && pwd)"
GUI_ASSERT="$(cd "${GUI_ASSERT_DIR:-${WS}/GuiAssert}" && pwd)"
OUT="${root}/build/plat35/gpui-window"
TRACE="${CODETRACER_PLAT35_TRACE:-${root}/test-logs/tui-fixtures/calc-2f0db4f45192}"
REPLAY="${REPLAY_SERVER_BIN:-${root}/src/build-debug/bin/replay-server}"
fail() {
	echo "FAIL: $*" >&2
	exit 1
}
[ -d "${TRACE}" ] || fail "the calc recording is not at ${TRACE} (just test-tui once)"
[ -x "${REPLAY}" ] || fail "no replay-server at ${REPLAY} (just build-once)"
target="${ISONIM_GPUI}/rust/target/windowed"
shim="${target}/debug/libgpui_nim_shim.so"
mkdir -p "${OUT}"
(cd "${ISONIM_GPUI}" && nix develop --command bash -c \
	"cd rust && CARGO_TARGET_DIR='${target}' cargo build -q --features gpui-backend &&
	 printf '%s' \"\$LD_LIBRARY_PATH\" > '${OUT}/gpui.ld-path'") ||
	fail "could not build isonim-gpui's windowed shim"
nim c --hints:off --warnings:off --mm:orc -d:release \
	--path:src/frontend/viewmodel \
	--nimcache:build/nimcache/codetracer-gpui-window \
	"-d:gpuiShimPath=${shim}" \
	-o:build/bin/codetracer-gpui-window src/frontend/gpui/main.nim ||
	fail "could not build the windowed codetracer-gpui"
(cd "${GUI_ASSERT}" &&
	PLAT35_GPUI_BIN="${root}/build/bin/codetracer-gpui-window" \
		PLAT35_GPUI_LD_LIBRARY_PATH="$(cat "${OUT}/gpui.ld-path")" \
		PLAT35_TRACE="${TRACE}" REPLAY_SERVER_BIN="${REPLAY}" \
		PLAT35_REPO="${root}" PLAT35_OUT="${OUT}" PLAT35_ONLY="${1:-}" \
		nix develop --command nim c -r --hints:off --warnings:off --path:src \
		--nimcache:"${root}/build/nimcache/plat35_gpui_window_capture" \
		-o:"${root}/build/plat35_gpui_window_capture" \
		"${root}/ci/test/plat35_gpui_window_capture.nim")
for ppm in "${OUT}"/*.ppm; do
	nix shell nixpkgs#imagemagick --command magick "${ppm}" "${ppm%.ppm}.png"
done
echo "plat35-gpui-window-capture: frames in ${OUT}"
