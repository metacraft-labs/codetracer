#!/usr/bin/env bash
# NOT-A-CI-GATE: a measurement on a compositor (the shim's work and the front-end's redraw per
# step); its numbers are recorded in codetracer-pm, nothing here passes or fails.
# A STEP'S COST, KEPT VS REBUILT: the shim's work per step frame and the
# front-end's redraw per step, with the panes' pools on and under
# CODETRACER_GPUI_FULL_REDRAW (every element built anew, the control), on
# the `calc` recording.
#
# Builds `codetracer-gpui` against isonim-gpui's WINDOWED shim, then runs
# PAIRS alternating pairs (keyed, full) of: a window on a headless sway
# (isonim-gpui `scripts/wayland-run-test.sh`), `n` x30 at 1.5 s, F12 to end,
# with `--frame-report` (the shim's `frameWork` per frame, the window's
# `refreshes`). Both halves of a pair run the same binary, so the pair is
# measured at one commit; the host load is recorded before and after each
# run. `analyse.py` summarises the reports.
#
# Run from the codetracer root, in the dev shell, through the host's heavy
# slot:
#   ISONIM_GPUI=../isonim-gpui SHIM=<windowed libgpui_nim_shim.so> \
#   REPLAY_SERVER_BIN=<replay-server> bash ci/test/gpui-keyed-redraw-measure/run.sh
# Needs the calc recording in test-logs/tui-fixtures/ (the window-capture
# lane's fixture step records it) and sway, wtype, python3 inside
# isonim-gpui's dev shell.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/../../.." && pwd)"
cd "${root}" || exit 1
I="${ISONIM_GPUI:-${root}/../isonim-gpui}"
SHIM="${SHIM:-${I}/rust/target/windowed/debug/libgpui_nim_shim.so}"
OUT="${OUT:-${root}/build/gpui-keyed-redraw-measure}"
PAIRS="${PAIRS:-3}"
BIN="${BIN:-${OUT}/codetracer-gpui-window}"
: "${REPLAY_SERVER_BIN:?set REPLAY_SERVER_BIN to a replay-server}"
mkdir -p "${OUT}"
echo "tree $(git rev-parse --short=11 HEAD) dirty: $(git status --porcelain --untracked-files=no | tr '\n' ' '); isonim-gpui $(git -C "$I" rev-parse --short HEAD); load $(cut -d' ' -f1-3 /proc/loadavg)"
if [ ! -x "${BIN}" ] || [ "${REBUILD:-1}" = 1 ]; then
	ISONIM_GPUI_SRC="${I}/src" nim c --hints:off --warnings:off --mm:orc -d:release \
		--path:src/frontend/viewmodel --nimcache:"${OUT}/nimcache" \
		-d:gpuiShimPath="${SHIM}" -o:"${BIN}" src/frontend/gpui/main.nim \
		>"${OUT}/build.log" 2>&1
	echo "build rc=$?"
fi
outer="$PATH"
for k in $(seq 1 "${PAIRS}"); do for mode in keyed full; do
	o="${OUT}/${mode}-${k}"
	rm -rf "${o}"
	l0=$(cut -d' ' -f1 /proc/loadavg)
	(cd "$I" && nix develop --command bash -c "export PATH=\"\$PATH:${outer}\" REPLAY_SERVER_BIN='${REPLAY_SERVER_BIN}'; bash scripts/wayland-run-test.sh -- bash '${here}/inner.sh' '${o}' '${mode}' '${BIN}'") \
		>"${OUT}/${mode}-${k}.sway.log" 2>&1
	echo "${mode}-${k} sway-rc=$? $(cat "${o}/rc" 2>/dev/null) load-start=${l0} load-end=$(cut -d' ' -f1 /proc/loadavg)"
done; done
python3 -I "${here}/analyse.py" "${OUT}"
