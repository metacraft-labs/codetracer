#!/usr/bin/env bash
# INSTALLED PLUGINS IN A REAL GPUI WINDOW (Extensibility-Model.md §11).
#
# A real `codetracer-gpui` window on a headless sway (isonim-gpui's
# `wayland-run-test.sh`, the window lanes' compositor) over the real `calc`
# recording and `replay-server`, with the `acme-tools` test package installed as
# a component (`plugin_process_fixture.installPackage`). The driver,
# `ci/test/gpui_plugins_window.py`, types real keys through the compositor (and
# presses a real pointer, isonim-gpui's `virtual-pointer`) and
# reads the window's own gesture trace, the process table and `grim` frames;
# its header lists the windows and what each shows.
#
#   bash ci/test/gpui-plugins-window.sh            # capture
#   bash ci/test/gpui-plugins-window.sh --record   # -> src/tests/visual/gpui-plugins-window.json
#
# `src/frontend/gpui/tests/test_gpui_plugins_window.nim` asserts the record;
# `ci/test/gpui-window-captures.sh plugins` re-takes it.
#
# PREREQUISITES are refused by name: sway, swaymsg, wayland-info, wtype, grim,
# isonim-gpui's `build/virtual-pointer`,
# tesseract, pgrep, python3, nim, `REPLAY_SERVER_BIN`, the `calc` recording and
# a `codetracer-gpui` built against the WINDOWED shim
# (`CODETRACER_GPUI_PLUGINS_BIN`, default build/bin/codetracer-gpui-window).
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1
WS="$(cd "${root}/.." && pwd)"
ISONIM_GPUI="${CODETRACER_PLUGINS_ISONIM_GPUI:-${WS}/isonim-gpui}"
OUT="${root}/build/gpui-plugins"
BIN="${CODETRACER_GPUI_PLUGINS_BIN:-${root}/build/bin/codetracer-gpui-window}"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

if [ "${1:-}" = "--record" ]; then
	exec python3 "${root}/ci/test/gpui_plugins_window.py" record
fi

[ -f "${ISONIM_GPUI}/scripts/wayland-run-test.sh" ] ||
	fail "${ISONIM_GPUI}/scripts/wayland-run-test.sh is missing"
[ -x "${BIN}" ] || fail "${BIN} is not built (a codetracer-gpui against the windowed shim)"
[ -n "${REPLAY_SERVER_BIN:-}" ] && [ -x "${REPLAY_SERVER_BIN}" ] ||
	fail "REPLAY_SERVER_BIN is not set to a replay-server"
for tool in sway swaymsg wayland-info wtype grim tesseract pgrep python3 nim; do
	command -v "${tool}" >/dev/null 2>&1 ||
		fail "'${tool}' is not on PATH; this lane refuses rather than running without it"
done
# A glob, not `compgen -G`: the lane runs under isonim-gpui's dev shell,
# whose non-interactive bash has no completion builtins ("compgen: command
# not found"), and that refusal named a recording that was there.
calc_recordings=("${root}"/test-logs/tui-fixtures/calc-*)
[ -e "${calc_recordings[0]}" ] ||
	fail "no calc recording in test-logs/tui-fixtures/ (the capture lane's fixture step records it)"

# The installer: the plugin-process suite's own fixture, which builds the
# package with this compiler against this tree's plugin SDK.
mkdir -p "${OUT}"
export CT_PLUGIN_TEST_SCRATCH="${CT_PLUGIN_TEST_SCRATCH:-${OUT}/package-build}"
nim c --hints:off --warnings:off --nimcache:"${OUT}/nimcache-install" \
	-o:"${OUT}/gpui_plugins_install" \
	src/frontend/gpui/tests/gpui_plugins_install.nim >"${OUT}/install-build.log" 2>&1 ||
	fail "building the installer failed (${OUT}/install-build.log)"
export CODETRACER_GPUI_PLUGINS_INSTALLER="${OUT}/gpui_plugins_install"
# A real pointer for the pane-click window: isonim-gpui's virtual-pointer
# (`scripts/build-virtual-pointer.sh`, which `gpui-window-captures.sh` runs in
# isonim-gpui's dev shell; `CODETRACER_VIRTUAL_POINTER` names another build).
VP="${CODETRACER_VIRTUAL_POINTER:-${ISONIM_GPUI}/build/virtual-pointer}"
[ -x "${VP}" ] || fail "${VP} is not built (isonim-gpui's scripts/build-virtual-pointer.sh)"
export CODETRACER_VIRTUAL_POINTER="${VP}"
export CODETRACER_GPUI_PLUGINS_BIN="${BIN}"

bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" -- \
	python3 "${root}/ci/test/gpui_plugins_window.py" capture
rc=$?
echo "gpui-plugins-window: rc=${rc}"
exit "${rc}"
