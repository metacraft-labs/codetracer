#!/usr/bin/env bash
# ctf-p1b-tui-capture.sh [--moments] — CTF-P1b's terminal captures of the
# Agent Harbor stories: every story of the section, dark and light, at the
# laptop (180x56 cells, the brief's 1440x900 at 8x16 px a cell) and sidebar
# (45x56, 360x900) sizes, each as a real terminal shows it.
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
#
# `--moments` (CTF-P1c, `just ctf-p1c-tui-captures`): each PLAYBACK story at
# each named moment of its scenario instead, as the web and GPUI arms take
# them (`ctf-p1b-web-capture.sh --moments`, `CTF_P1B_MOMENTS=1
# ctf-p1b-gpui-story-capture.sh`). Step 1 is then CTF-P1c's suite
# `test_ctf_p1c_playback_stories_agree_at_each_moment.nim`, run with
# `CTF_P1C_TUI_OUT`: its real-terminal test spawns the story host with
# `--moment=<name>` per story, moment, size and theme, holds the screen to
# the in-process drawing at that moment cell by cell, and writes it as
# `agent-harbor-<story>-at-<moment>-<size>-<theme>.{svg,txt}`. Output:
# `build/ctf-p1c/tui/` (`CTF_P1C_TUI_OUT` overrides) and
# `build/ctf-p1c/parity-tui/` (`parity-pairs.sh --agent-harbor-tui-moments`).
# The web moment captures (`build/ctf-p1c/web/`, `CTF_P1C_WEB_OUT`, `just
# ctf-p1c-web-captures`) are required: the run fails when the captures
# written are not exactly the ones the story host lists (`--captures
# --moments`, from the scenarios) or when a capture on either side has no
# partner.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"
moments=0
for arg in "$@"; do
	case "${arg}" in
	--moments) moments=1 ;;
	*)
		echo "ctf-p1b-tui-capture: unknown argument ${arg}" >&2
		exit 2
		;;
	esac
done
if [ "${moments}" = 1 ]; then
	out="${CTF_P1C_TUI_OUT:-${root}/build/ctf-p1c/tui}"
	web="${CTF_P1C_WEB_OUT:-${root}/build/ctf-p1c/web}"
	suite=src/frontend/tui/tests/real_terminal/test_ctf_p1c_playback_stories_agree_at_each_moment.nim
	out_var=CTF_P1C_TUI_OUT
	pairs=--agent-harbor-tui-moments
	cache=build/nimcache/ctf-p1c-tui-capture
	if [ ! -d "${web}" ]; then
		echo "ctf-p1b-tui-capture: no web moment captures in ${web} (just ctf-p1c-web-captures)" >&2
		exit 1
	fi
else
	out="${CTF_P1B_TUI_OUT:-${root}/build/ctf-p1b/tui}"
	web="${CTF_P1B_WEB_OUT:-${root}/build/ctf-p1b/web}"
	suite=src/frontend/tui/tests/real_terminal/test_ctf_p1b_tui_views_cover_web_states.nim
	out_var=CTF_P1B_TUI_OUT
	pairs=--agent-harbor-tui
	cache=build/nimcache/ctf-p1b-tui-capture
fi
name="$(basename "${suite}" .nim)"
# shellcheck source=ci/lib/test-lane-files.sh
source ci/lib/test-lane-files.sh
read -r -a flags <<<"$(test_lane_extra_flags tui-real-terminal)"
mkdir -p "${cache}" "${out}"
rm -f "${out}"/*.svg "${out}"/*.png "${out}"/*.txt
AGENT_HARBOR_FIXTURES=synthetic nim c --hints:off --warnings:off "${flags[@]}" \
	--nimcache:"${cache}" -o:"${cache}/${name}" "${suite}"
AGENT_HARBOR_FIXTURES=synthetic env "${out_var}=${out}" "${cache}/${name}"
count="$(find "${out}" -name '*.svg' | wc -l)"
[ "${count}" -gt 0 ] || {
	echo "ctf-p1b-tui-capture: the suite wrote no capture into ${out}" >&2
	exit 1
}
if [ "${moments}" = 1 ]; then
	# The captures written are exactly the ones the story host lists from the
	# scenarios: none missing (a story, moment, size or theme skipped) and
	# none extra (one named otherwise than the web and GPUI captures). The
	# suite built the host as its child app (`testing/dual_snap`).
	host="${root}/test-logs/tui-dual-snap/bin/app_agent_harbor_story"
	expected="$(mktemp)" written="$(mktemp)"
	trap 'rm -f "${expected}" "${written}"' EXIT
	"${host}" --captures --moments | sort >"${expected}"
	find "${out}" -name '*.svg' -printf '%f\n' | sed 's/\.svg$//' | sort >"${written}"
	if [ ! -s "${expected}" ] || ! diff -u "${expected}" "${written}" >&2; then
		echo "ctf-p1b-tui-capture: the captures in ${out} (${count}) are not the" \
			"$(wc -l <"${expected}") the story host lists (--captures --moments); diff above" >&2
		exit 1
	fi
fi
# One imagemagick for every frame: a `nix shell` per frame costs a second each.
# shellcheck disable=SC2016  # the inner bash expands these, from its arguments
nix shell nixpkgs#imagemagick nixpkgs#dejavu_fonts --command bash -c '
	set -euo pipefail
	for svg in "$1"/*.svg; do
		magick "${svg}" "${svg%.svg}.png"
	done' convert "${out}"
echo "ctf-p1b-tui-capture: ${count} terminal captures in ${out}"
if [ -d "${web}" ]; then
	bash tools/visual-review/parity-pairs.sh "${pairs}"
else
	echo "ctf-p1b-tui-capture: no web captures (just ctf-p1b-web-captures); no pairs made"
fi
