#!/usr/bin/env bash
# ctf-p1b-gpui-story-capture.sh [story-substring] — CTF-P1b's GPUI captures of
# the Agent Harbor stories, as REAL windows on GuiAssert's headless sway (see
# `ci/test/ctf_p1b_gpui_story_capture.nim` for why: GPUI has no headless
# renderer off macOS). PLAT-35's window path (`plat35-gpui-window-capture.sh`)
# for the story host instead of the debugger.
#
#   1. isonim-gpui's windowed shim (`--features gpui-backend`), in its shell,
#      and that shell's LD_LIBRARY_PATH;
#   2. this checkout's `build/bin/codetracer-gpui-story`
#      (`src/frontend/gpui/agent_harbor/ah_story_window.nim`), pinned to it;
#   3. the captures, in GuiAssert's shell (`GUI_ASSERT_DIR`, default
#      ../GuiAssert), into `build/ctf-p1b/gpui/<capture id>.{ppm,regions.json}`
#      (`CTF_P1B_GPUI_OUT` overrides), each frame converted to `.png`.
#
# Every story of the section, both themes, at the laptop and sidebar sizes
# (`CTF_P1B_SIZES`, `CTF_P1B_THEMES` override; the argument, comma-separated substrings,
# keeps the stories whose id contains one). Needs no recording and no replay-server: a story's
# data is the committed synthetic fixture set. Run inside this repo's dev
# shell. The layout test that reads these captures is
# `src/tests/visual/agent_harbor/test_ctf_p1b_gpui_capture_matches_web_layout.nim`
# (`just ctf-p1b-gpui-captures` runs both).
#
# With `CTF_P1B_MOMENTS=1` (CTF-P1c, `just ctf-p1c-gpui-captures`): each
# playback story at each named moment of its scenario instead, into
# `build/ctf-p1c/gpui/` (`CTF_P1C_GPUI_OUT` overrides), read by
# `test_ctf_p1c_gpui_capture_matches_web_layout_at_moments.nim`.
#
# With `CTF_P1B_SHARD=<i>/<n>`: only the i-th of n round-robin shares of the
# captures (`ctf_p1b_gpui_story_capture.nim`), which is how CI spreads the
# set over the GPUI shards (`just ctf-p1b-gpui-captures-shard`).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS="$(cd "${root}/.." && pwd)"
ISONIM_GPUI="$(cd "${ISONIM_GPUI_DIR:-${WS}/isonim-gpui}" && pwd)"
GUI_ASSERT="$(cd "${GUI_ASSERT_DIR:-${WS}/GuiAssert}" && pwd)"
if [ "${CTF_P1B_MOMENTS:-}" = 1 ]; then
	OUT="${CTF_P1C_GPUI_OUT:-${root}/build/ctf-p1c/gpui}"
else
	OUT="${CTF_P1B_GPUI_OUT:-${root}/build/ctf-p1b/gpui}"
fi
fail() {
	echo "FAIL: $*" >&2
	exit 1
}
target="${GPUI_WINDOWED_TARGET_DIR:-${ISONIM_GPUI}/rust/target/windowed}"
shim="${target}/debug/libgpui_nim_shim.so"
mkdir -p "${OUT}"
# A re-take of the whole set starts from no frames: a frame left from an
# earlier run of a story or moment that no longer exists would be converted
# and paired (`parity-pairs.sh`) as a capture with no partner. A run limited
# to some stories keeps the others' frames.
if [ -z "${1:-}" ]; then
	rm -f "${OUT}"/*.ppm "${OUT}"/*.png "${OUT}"/*.regions.json
fi
# CT_GPUI_SHIM_PREBUILT=1: CI's shards restore the windowed shim from the
# ct-build job (the .so alone, without cargo's fingerprints, so a `cargo
# build` here would rebuild it whole); only its shell's library path is read.
if [ "${CT_GPUI_SHIM_PREBUILT:-0}" = 1 ]; then
	[ -e "${shim}" ] || fail "CT_GPUI_SHIM_PREBUILT=1, but there is no ${shim}"
	build_shim=true
else
	build_shim="cd rust && CARGO_TARGET_DIR='${target}' cargo build -q --features gpui-backend"
fi
(cd "${ISONIM_GPUI}" && nix develop --command bash -c \
	"${build_shim} && printf '%s' \"\$LD_LIBRARY_PATH\" > '${OUT}/gpui.ld-path'") ||
	fail "could not build isonim-gpui's windowed shim"
cd "${root}"
# The synthetic fixture set, always: the web record this capture is compared
# with is taken over it (`ctf-p1b-web-capture.sh` refuses any other set), and
# a workspace that holds the private set would otherwise embed that one here
# (`fixture_source.nim`'s compile-time choice) and compare different data.
AGENT_HARBOR_FIXTURES=synthetic nim c --hints:off --warnings:off --mm:orc -d:release \
	--path:src/frontend/viewmodel \
	--nimcache:build/nimcache/codetracer-gpui-story \
	"-d:gpuiShimPath=${shim}" \
	-o:build/bin/codetracer-gpui-story src/frontend/gpui/agent_harbor/ah_story_window.nim ||
	fail "could not build the windowed codetracer-gpui-story"
(cd "${GUI_ASSERT}" &&
	CTF_P1B_STORY_BIN="${root}/build/bin/codetracer-gpui-story" \
		CTF_P1B_GPUI_LD_LIBRARY_PATH="$(cat "${OUT}/gpui.ld-path")" \
		CTF_P1B_REGIONS="${root}/src/tests/visual/agent-harbor-regions.json" \
		CTF_P1B_OUT="${OUT}" CTF_P1B_ONLY="${1:-}" CTF_P1B_MOMENTS="${CTF_P1B_MOMENTS:-}" \
		CTF_P1B_SHARD="${CTF_P1B_SHARD:-}" \
		nix develop --command nim c -r --hints:off --warnings:off --path:src \
		--nimcache:"${root}/build/nimcache/ctf_p1b_gpui_story_capture" \
		-o:"${root}/build/ctf_p1b_gpui_story_capture" \
		"${root}/ci/test/ctf_p1b_gpui_story_capture.nim")
# One imagemagick for every frame: a `nix shell` per frame costs a second each.
# The PPM is kept: it is what the layout test reads, pixel for pixel (this
# repository has a PNG encoder and no decoder); the PNG is for people.
# shellcheck disable=SC2016  # the inner bash expands these, from its arguments
nix shell nixpkgs#imagemagick --command bash -c '
	set -euo pipefail
	for ppm in "$1"/*.ppm; do
		magick "${ppm}" "${ppm%.ppm}.png"
	done' convert "${OUT}"
echo "ctf-p1b-gpui-story-capture: frames and regions in ${OUT}"
