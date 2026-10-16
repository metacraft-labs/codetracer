#!/usr/bin/env bash
# PLAT-69 — the GPUI window as a normal desktop window (its top bar is the
# title bar), driven on GuiAssert's headless-sway target (PLAT69_TARGET=gnome:
# its headless GNOME). See `ci/test/plat69_window_chrome.nim` for the
# scenarios and what each reads.
#
#   bash ci/test/plat69-window-chrome.sh                  # every scenario
#   bash ci/test/plat69-window-chrome.sh plat69-button-placement ...
#
# Run inside this repo's dev shell. Prerequisites are refused BY NAME, never
# skipped:
#   * build/bin/codetracer-gpui-window — this checkout's GPUI front-end pinned
#     to isonim-gpui's WINDOWED shim (`ci/test/gpui-window-captures.sh` builds
#     it; CODETRACER_WINDOW_BIN_PINS_SHIM=1 says it was);
#   * the `calc` recording under test-logs/tui-fixtures/, and REPLAY_SERVER_BIN
#     (default: src/build-debug/bin/replay-server);
#   * src/build-debug/bin/ct and its Electron bundle (`just build-once`), for
#     the desktop half of plat69-initial-window;
#   * the isonim-gpui checkout (ISONIM_GPUI_DIR, default ../isonim-gpui), whose
#     dev shell declares the libraries the windowed shim loads, and the
#     GuiAssert checkout (GUI_ASSERT_DIR, default ../GuiAssert), whose dev
#     shell pins sway and its session stack.
#
# Two dev shells, as isonim-gpui's own window-frame suite uses them: the
# windowed binary's library path is read in isonim-gpui's, the scenarios run
# in GuiAssert's, and this shell's PATH and node modules are handed to the
# desktop front-end.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1
WS="$(cd "${root}/.." && pwd)"
ISONIM_GPUI="$(cd "${ISONIM_GPUI_DIR:-${WS}/isonim-gpui}" 2>/dev/null && pwd)"
GUI_ASSERT="$(cd "${GUI_ASSERT_DIR:-${WS}/GuiAssert}" 2>/dev/null && pwd)"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

BIN="${CODETRACER_PLAT69_BIN:-${root}/build/bin/codetracer-gpui-window}"
TRACE="${CODETRACER_PLAT69_TRACE:-${root}/test-logs/tui-fixtures/calc-2f0db4f45192}"
CT="${CODETRACER_PLAT69_CT:-${root}/src/build-debug/bin/ct}"
export REPLAY_SERVER_BIN="${REPLAY_SERVER_BIN:-${root}/src/build-debug/bin/replay-server}"
OUT="${root}/build/plat69"

[ -n "${ISONIM_GPUI}" ] && [ -d "${ISONIM_GPUI}/rust/gpui-nim-shim" ] ||
	fail "no isonim-gpui checkout at ${ISONIM_GPUI_DIR:-${WS}/isonim-gpui}"
[ -n "${GUI_ASSERT}" ] && [ -f "${GUI_ASSERT}/src/gui_assert/desktop_env/sway.nim" ] ||
	fail "no GuiAssert checkout with desktop_env at ${GUI_ASSERT_DIR:-${WS}/GuiAssert}"
[ -x "${BIN}" ] || fail "${BIN} is not built (ci/test/gpui-window-captures.sh builds it)"
[ "${CODETRACER_WINDOW_BIN_PINS_SHIM:-0}" = "1" ] ||
	fail "this lane needs a binary built with -d:gpuiShimPath=<windowed shim>
      (CODETRACER_WINDOW_BIN_PINS_SHIM=1); it does not swap the shared shim."
[ -d "${TRACE}" ] || fail "no recording at ${TRACE} (the tui lane's fixture provider records calc)"
[ -x "${REPLAY_SERVER_BIN}" ] || fail "no replay-server at ${REPLAY_SERVER_BIN} (just build-once)"
[ -x "${CT}" ] || fail "no ct at ${CT} (just build-once)"
command -v electron >/dev/null 2>&1 || fail "'electron' is not on PATH (run inside the dev shell)"

rm -rf "${OUT}"
mkdir -p "${OUT}"

echo "=== the windowed shim's library path, from isonim-gpui's dev shell"
(cd "${ISONIM_GPUI}" && nix develop --command bash -c \
	"printf '%s' \"\$LD_LIBRARY_PATH\" > '${OUT}/gpui.ld-path'") ||
	fail "could not enter isonim-gpui's dev shell"

filters=()
for s in "$@"; do
	case "${s}" in
	plat69-window-management | plat69-button-placement | plat69-initial-window | plat69-server-mode)
		filters+=("${s}::*")
		;;
	*) fail "unknown scenario '${s}'" ;;
	esac
done

echo "=== the scenarios, in GuiAssert's dev shell"
(cd "${GUI_ASSERT}" &&
	PLAT69_GPUI_BIN="${BIN}" \
		PLAT69_GPUI_LD_LIBRARY_PATH="$(cat "${OUT}/gpui.ld-path")" \
		PLAT69_TRACE="${TRACE}" PLAT69_OUT="${OUT}" PLAT69_REPO="${root}" \
		PLAT69_CT_BIN="${CT}" PLAT69_CT_PATH="${PATH}" \
		PLAT69_CT_LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" \
		PLAT69_CT_NODE_PATH="${NODE_PATH:-}" \
		nix develop --command nim c -r --hints:off --warnings:off --path:src \
		--nimcache:"${root}/build/nimcache/plat69_window_chrome" \
		-o:"${root}/build/plat69_window_chrome" \
		"${root}/ci/test/plat69_window_chrome.nim" "${filters[@]}")
rc=$?
echo "plat69-window-chrome: rc=${rc}"
exit "${rc}"
