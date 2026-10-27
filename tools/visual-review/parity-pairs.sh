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
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
