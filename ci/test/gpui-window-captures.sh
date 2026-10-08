#!/usr/bin/env bash
# gpui-window-captures.sh — RE-TAKE the GPUI window's measurements on a real
# compositor and assert them, end to end, from nothing but a checkout.
#
#   bash ci/test/gpui-window-captures.sh [plat45] [plat47] [plat48]
#   just gpui-window-captures                 # all three
#
# The GPUI window suites (`test_plat45_three_media.nim`,
# `test_plat47_gpui_window.nim`, `test_plat48_gpui_window.nim`) assert
# COMMITTED records measured off a real window on a headless sway. A record
# nobody re-takes stops describing the product the first time the window
# changes — which is how PLAT-45's and PLAT-47's records came to predate the
# top bar. This script is what re-takes them, and it is a CI job
# (`gpui-window-captures` in `.github/workflows/codetracer.yml`), so on every
# run the committed record is REPLACED by a fresh measurement of this commit's
# window and the suite asserts that, not the file a person last committed.
#
# For each capture named (default: all three):
#   1. isonim-gpui's WINDOWED shim (`--features gpui-backend`) and its
#      `build/virtual-pointer`, built in isonim-gpui's own dev shell — the
#      shell that declares the X/Wayland link libraries and the compositor
#      tools (sway, grim, wtype);
#   2. `build/bin/codetracer-gpui-window`, this checkout's GPUI front-end
#      pinned to that shim (`-d:gpuiShimPath`);
#   3. the recordings the drivers open (`calc`, and `call_pages` for PLAT-47),
#      recorded by the terminal lanes' own fixture provider when absent, and
#      the terminal front-end where a capture drives it (PLAT-45's three
#      media, PLAT-48's terminal-saved layout);
#   4. the capture (`ci/test/plat4N-…window…`) on a headless sway, the record
#      step that measures its frames into `src/tests/visual/…json`, and the
#      Nim suite that asserts that record.
#
# Prerequisites it does not build are refused BY NAME: the isonim-gpui
# checkout (`ISONIM_GPUI_DIR`, default `../isonim-gpui`), `nix`, `nim`,
# `tesseract`, and `REPLAY_SERVER_BIN` (default: the one `just build-once`
# leaves in `src/build-debug/bin`). Run it inside this repo's dev shell.
#
# `GPUI_WINDOWED_TARGET_DIR` overrides where the windowed shim is built
# (default `<isonim-gpui>/rust/target/windowed`, kept apart from
# `target/debug`, the featureless shim every other consumer links).
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1
WS="$(cd "${root}/.." && pwd)"
ISONIM_GPUI="$(cd "${ISONIM_GPUI_DIR:-${WS}/isonim-gpui}" 2>/dev/null && pwd)"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

which=("$@")
[ "${#which[@]}" -gt 0 ] || which=(plat45 plat47 plat48)
for w in "${which[@]}"; do
	case "${w}" in
	plat45 | plat47 | plat48) ;;
	*) fail "unknown capture '${w}' (plat45, plat47, plat48)" ;;
	esac
done

[ -n "${ISONIM_GPUI}" ] && [ -d "${ISONIM_GPUI}/rust/gpui-nim-shim" ] ||
	fail "no isonim-gpui checkout at ${ISONIM_GPUI_DIR:-${WS}/isonim-gpui}"
for tool in nix nim tesseract python3; do
	command -v "${tool}" >/dev/null 2>&1 || fail "'${tool}' is not on PATH (run inside the dev shell)"
done
export REPLAY_SERVER_BIN="${REPLAY_SERVER_BIN:-${root}/src/build-debug/bin/replay-server}"
[ -x "${REPLAY_SERVER_BIN}" ] || fail "no replay-server at ${REPLAY_SERVER_BIN} (just build-once)"

# ---- 1. the windowed shim and the virtual pointer, in isonim-gpui's shell ---
target="${GPUI_WINDOWED_TARGET_DIR:-${ISONIM_GPUI}/rust/target/windowed}"
echo "=== isonim-gpui: the windowed shim (${target}) and build/virtual-pointer"
(cd "${ISONIM_GPUI}" && nix develop --command bash -c \
	"cd rust && CARGO_TARGET_DIR='${target}' cargo build --features gpui-backend &&
	 cd .. && bash scripts/build-virtual-pointer.sh") ||
	fail "could not build isonim-gpui's windowed shim or its virtual pointer"
shim="${target}/debug/libgpui_nim_shim.so"
[ -f "${shim}" ] || fail "the windowed shim is not at ${shim}"

# ---- 2. this checkout's GPUI front-end, pinned to that shim -----------------
echo "=== build/bin/codetracer-gpui-window against ${shim}"
mkdir -p build/bin
nim c --hints:off --warnings:off --mm:orc -d:release \
	--path:src/frontend/viewmodel \
	--nimcache:build/nimcache/codetracer-gpui-window \
	"-d:gpuiShimPath=${shim}" \
	-o:build/bin/codetracer-gpui-window src/frontend/gpui/main.nim ||
	fail "could not build the windowed codetracer-gpui"

# ---- 3. the recordings -------------------------------------------------------
fixtures=(calc)
for w in "${which[@]}"; do
	[ "${w}" = "plat47" ] && fixtures+=(call_pages)
done
work="$(mktemp -d "${root}/build/gpui-window-captures.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
for fx in "${fixtures[@]}"; do
	ls -d "test-logs/tui-fixtures/${fx}-"* >/dev/null 2>&1 && continue
	echo "=== recording the ${fx} fixture"
	cat >"${work}/record_${fx}.nim" <<NIM
import fixtures/fixture_provider
let r = resolveFixture("${fx}")
if r.outcome != foRecorded:
  quit("could not record the ${fx} fixture: " & r.detail, 1)
echo r.tracePath
NIM
	nim c -r --hints:off --warnings:off --path:src/frontend/tui/tests \
		--nimcache:"${work}/nc-${fx}" -o:"${work}/record_${fx}" \
		"${work}/record_${fx}.nim" || fail "could not record the ${fx} fixture"
done

# ---- 4. capture, measure, assert --------------------------------------------
export ISONIM_GPUI_DIR="${ISONIM_GPUI}" CODETRACER_WINDOW_BIN_PINS_SHIM=1
export CODETRACER_REPO_ROOT="${root}"
# shellcheck source=/dev/null
. ci/lib/test-lane-files.sh

suite() {
	# suite <lane> <file>: one Nim suite, compiled with its lane's flags.
	local lane="$1" file="$2" name
	name="$(basename "${file}" .nim)"
	# shellcheck disable=SC2046  # the flag string must word-split
	nim c -r --hints:off --warnings:off $(test_lane_extra_flags "${lane}") \
		--nimcache:"build/nimcache/gpui-window-captures-${name}" \
		-o:"build/gpui-window-captures-${name}" "${file}"
}

in_compositor_shell() {
	# The capture runs in isonim-gpui's dev shell (sway, grim, wtype,
	# wayland-info come first on its PATH); this shell's PATH (tesseract,
	# python3, nim) is appended, and the environment is inherited.
	local outer="${PATH}"
	(cd "${ISONIM_GPUI}" && nix develop --command bash -c \
		"export PATH=\"\$PATH:${outer}\"; cd '${root}' && $*")
}

failed=()
for w in "${which[@]}"; do
	echo "=== ${w}"
	case "${w}" in
	plat48)
		# The last case opens a layout the TERMINAL saved, so the terminal
		# front-end is built too (`build-tui` runs `tui-prereqs`).
		just build-tui &&
			in_compositor_shell "bash ci/test/plat48-gpui-window.sh" &&
			python3 ci/test/plat48_gpui_window.py record &&
			suite gpui-shell src/frontend/gpui/tests/test_plat48_gpui_window.nim ||
			failed+=("${w}")
		;;
	plat47)
		in_compositor_shell "bash ci/test/plat47-gpui-window.sh" &&
			python3 ci/test/plat47_gpui_window.py record &&
			suite gpui-shell src/frontend/gpui/tests/test_plat47_gpui_window.nim ||
			failed+=("${w}")
		;;
	plat45)
		# The three-media suite also reads the SHIPPED featureless binary's
		# dock document and opens the terminal on `calc`, so it needs
		# `just build-gpui` (over isonim-gpui's featureless shim) and the
		# terminal's prerequisites as well as the window's frames.
		(cd "${ISONIM_GPUI}" && nix develop --command bash -c "cd rust && cargo build") &&
			ISONIM_GPUI_SHIM_DIR="${ISONIM_GPUI}/rust/target/debug" just build-gpui &&
			just tui-prereqs &&
			in_compositor_shell "CODETRACER_PLAT45_BIN='${root}/build/bin/codetracer-gpui-window' bash ci/test/plat45-arrangement-window.sh" &&
			just plat45-window-record &&
			ISONIM_GPUI_SHIM_DIR="${ISONIM_GPUI}/rust/target/debug" \
				suite tui src/frontend/tui/tests/test_plat45_three_media.nim ||
			failed+=("${w}")
		;;
	esac
	# What moved in the committed record, for a reader of the log: the suite
	# above is the verdict; this is the evidence.
	git --no-pager diff --stat -- src/tests/visual/ || true
done

if [ "${#failed[@]}" -gt 0 ]; then
	echo "gpui-window-captures: FAILED: ${failed[*]}"
	exit 1
fi
echo "gpui-window-captures: ${which[*]} re-taken and asserted"
