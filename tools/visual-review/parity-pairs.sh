#!/usr/bin/env bash
# parity-pairs.sh [out-dir] — gather the latest Electron and GPUI captures of
# every named view into <out-dir> (default build/plat35/parity) as
# `<view>.electron.png`, `<view>.gpui.png` and `<view>.side-by-side.png`
# (Electron on the left), the inputs of the parity review
# (`tools/visual-review/briefs/gpui-electron-parity.md`).
#
# Reads `src/tests/visual/scenarios.json` for the scenario → view mapping,
# `src/tests/visual/captures/electron/<scenario>.png` (`just
# plat35-capture-electron`) and `build/plat35/gpui-window/<view>.png`
# (`ci/test/plat35-gpui-window-capture.sh`, the real GPUI window on headless
# sway). A view missing from either side is reported by name
# and the script exits non-zero after doing the others.
#
# parity-pairs.sh --agent-harbor [out-dir] — the same for CTF-P1b's Agent
# Harbor stories: every GPUI capture `build/ctf-p1b/gpui/<id>.png`
# (`ci/test/ctf-p1b-gpui-story-capture.sh`) beside the web capture of the same
# story, theme and size, `build/ctf-p1b/web/<id>.png`
# (`ci/test/ctf-p1b-web-capture.sh`), as `<id>.web.png`, `<id>.gpui.png` and
# `<id>.side-by-side.png` (web on the left) in <out-dir> (default
# `build/ctf-p1b/parity`, where the layout test writes its report). A capture
# with no partner is reported by name and the script exits non-zero after
# doing the others.
#
# parity-pairs.sh --agent-harbor-tui [out-dir] — the same for the terminal:
# every terminal capture `build/ctf-p1b/tui/<id>.png`
# (`ci/test/ctf-p1b-tui-capture.sh`, `CTF_P1B_TUI_OUT` overrides) beside the
# web capture of the same story, theme and size, as `<id>.web.png`,
# `<id>.tui.png` and `<id>.side-by-side.png` (web on the left) in <out-dir>
# (default `build/ctf-p1b/parity-tui`).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ "${1:-}" = "--agent-harbor" ] || [ "${1:-}" = "--agent-harbor-tui" ]; then
	if [ "${1}" = "--agent-harbor-tui" ]; then
		gpui_dir="${CTF_P1B_TUI_OUT:-${root}/build/ctf-p1b/tui}"
		arm=tui
		out="${2:-${root}/build/ctf-p1b/parity-tui}"
	else
		gpui_dir="${CTF_P1B_GPUI_OUT:-${root}/build/ctf-p1b/gpui}"
		arm=gpui
		out="${2:-${root}/build/ctf-p1b/parity}"
	fi
	web_dir="${CTF_P1B_WEB_OUT:-${root}/build/ctf-p1b/web}"
	mkdir -p "${out}"
	# One imagemagick for every pair: a `nix shell` per pair costs a second
	# each, over hundreds of pairs.
	# shellcheck disable=SC2016  # the inner bash expands these, from its arguments
	nix shell nixpkgs#imagemagick --command bash -c '
		set -uo pipefail
		gpui_dir="$1" web_dir="$2" out="$3" arm="$4"
		status=0 pairs=0
		shopt -s nullglob
		ids=()
		for f in "${gpui_dir}"/*.png "${web_dir}"/*.png; do
			ids+=("$(basename "${f}" .png)")
		done
		[ "${#ids[@]}" -gt 0 ] || { echo "parity-pairs: no captures in ${gpui_dir} or ${web_dir}" >&2; exit 1; }
		for id in $(printf "%s\n" "${ids[@]}" | sort -u); do
			gpui="${gpui_dir}/${id}.png" web="${web_dir}/${id}.png"
			for f in "${web}" "${gpui}"; do
				[ -f "${f}" ] || { echo "parity-pairs: ${id}: missing ${f}" >&2; status=1; continue 2; }
			done
			cp "${web}" "${out}/${id}.web.png"
			cp "${gpui}" "${out}/${id}.${arm}.png"
			# The two halves differ in height by under a cell (a terminal
			# capture is whole rows: 896 px against the web 900 px). The GPUI
			# arm pads with magenta, which marks a size mismatch; the terminal
			# arm pads with the bottom-left colour of its own capture (the
			# window ground), so the short half ends in its own ground, not a strip.
			pad="#ff00ff"
			if [ "${arm}" = tui ]; then
				pad="$(magick "${gpui}" -format "%[pixel:p{0,h-1}]" info:)"
			fi
			magick "${web}" "${gpui}" -background "${pad}" +append "${out}/${id}.side-by-side.png"
			pairs=$((pairs + 1))
		done
		echo "parity-pairs: ${pairs} Agent Harbor ${arm} pairs in ${out}"
		exit "${status}"' pairs "${gpui_dir}" "${web_dir}" "${out}" "${arm}"
	exit $?
fi
out="${1:-${root}/build/plat35/parity}"
mkdir -p "${out}"
status=0
while IFS=$'\t' read -r scenario view; do
	electron="${root}/src/tests/visual/captures/electron/${scenario}.png"
	gpui="${root}/build/plat35/gpui-window/${view}.png"
	for f in "${electron}" "${gpui}"; do
		[ -f "${f}" ] || {
			echo "parity-pairs: ${view}: missing ${f}" >&2
			status=1
			continue 2
		}
	done
	cp "${electron}" "${out}/${view}.electron.png"
	cp "${gpui}" "${out}/${view}.gpui.png"
	nix shell nixpkgs#imagemagick --command magick "${electron}" "${gpui}" \
		-background '#ff00ff' +append "${out}/${view}.side-by-side.png"
	echo "parity-pairs: ${view} (${scenario})"
done < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for s in d["scenarios"]:
    print(s["id"] + "\t" + s["view"])
' "${root}/src/tests/visual/scenarios.json")
exit "${status}"
