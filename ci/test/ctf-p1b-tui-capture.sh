#!/usr/bin/env bash
# ctf-p1b-tui-capture.sh — CTF-P1b's terminal captures of the Agent Harbor
# stories: every story of the section, dark and light, at the laptop (180x56
# cells, the brief's 1440x900 at 8x16 px a cell) and sidebar (45x56, 360x900)
# sizes, each as a real terminal shows it.
#
#   1. The coverage suite `src/frontend/tui/tests/real_terminal/
#      test_ctf_p1b_tui_views_cover_web_states.nim` (lane `tui-real-terminal`)
#      is compiled with that lane's flags and run with `CTF_P1B_TUI_OUT`: it
#      spawns the terminal story host (`src/frontend/tui/agent_harbor/ah_tui_story_host.nim`)
#      in a pty per story, size and theme, checks the screen TermAssert reads
#      back (libvterm) against the viewmodel and the committed styled
#      snapshots, and writes each screen as `<capture id>.svg` in its own
#      colours (TermAssert `renderColourSvg`) and `<capture id>.txt`;
#   2. each SVG is rasterised to `<capture id>.png` (ImageMagick, DejaVu Sans
#      Mono: 8x16 px a cell, so a laptop capture is 1440x896);
#   3. `tools/visual-review/parity-pairs.sh --agent-harbor-tui` pairs each
#      with the web capture of the same story, theme and size
#      (`build/ctf-p1b/web/`, `just ctf-p1b-web-captures`), when those exist.
#
# Output: `build/ctf-p1b/tui/` (`CTF_P1B_TUI_OUT` overrides) and
# `build/ctf-p1b/parity-tui/`. Always over the synthetic fixture set, the one
# the web record and the committed snapshots are taken over. Needs
# `just tui-prereqs` (the grammar archive and link flags the TUI lanes use);
# run inside this repo's dev shell.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"
out="${CTF_P1B_TUI_OUT:-${root}/build/ctf-p1b/tui}"
suite=src/frontend/tui/tests/real_terminal/test_ctf_p1b_tui_views_cover_web_states.nim
name="$(basename "${suite}" .nim)"
# shellcheck source=ci/lib/test-lane-files.sh
source ci/lib/test-lane-files.sh
read -r -a flags <<<"$(test_lane_extra_flags tui-real-terminal)"
cache=build/nimcache/ctf-p1b-tui-capture
mkdir -p "${cache}" "${out}"
rm -f "${out}"/*.svg "${out}"/*.png "${out}"/*.txt
AGENT_HARBOR_FIXTURES=synthetic nim c --hints:off --warnings:off "${flags[@]}" \
	--nimcache:"${cache}" -o:"${cache}/${name}" "${suite}"
AGENT_HARBOR_FIXTURES=synthetic CTF_P1B_TUI_OUT="${out}" "${cache}/${name}"
count="$(find "${out}" -name '*.svg' | wc -l)"
[ "${count}" -gt 0 ] || {
	echo "ctf-p1b-tui-capture: the suite wrote no capture into ${out}" >&2
	exit 1
}
# One imagemagick for every frame: a `nix shell` per frame costs a second each.
# shellcheck disable=SC2016  # the inner bash expands these, from its arguments
nix shell nixpkgs#imagemagick nixpkgs#dejavu_fonts --command bash -c '
	set -euo pipefail
	for svg in "$1"/*.svg; do
		magick "${svg}" "${svg%.svg}.png"
	done' convert "${out}"
echo "ctf-p1b-tui-capture: ${count} terminal captures in ${out}"
if [ -d "${CTF_P1B_WEB_OUT:-${root}/build/ctf-p1b/web}" ]; then
	bash tools/visual-review/parity-pairs.sh --agent-harbor-tui
else
	echo "ctf-p1b-tui-capture: no web captures (just ctf-p1b-web-captures); no pairs made"
fi
