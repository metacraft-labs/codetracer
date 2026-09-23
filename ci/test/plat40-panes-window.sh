#!/usr/bin/env bash
# PLAT-40 — the three producer-fed panes, drawn by a real GPUI window.
#
#   bash ci/test/plat40-panes-window.sh            # capture
#   bash ci/test/plat40-panes-window.sh --inside   # internal
#
# Opens `codetracer-gpui` on the `calc` recording in a real window on a
# headless sway, with the arrangement `src/tests/visual/plat40-layout.json`
# describes — the editor beside the call trace, the event log and the
# breakpoint list — advances it with the same operations the desktop capture
# performs (`PLAT40_OPS`, which sets one breakpoint through the engine), waits
# for the window to SETTLE (two identical non-blank grabs), and frames it with
# `grim`.
#
# Three frames, and the two that are not the subject are what make the subject
# mean anything:
#
#   panes      the subject: all three panes, fed by the producers.
#   default    the NEGATIVE CONTROL: the same run under the DEFAULT layout,
#              which has no breakpoint list — the reader must not find one.
#   blank      the compositor before any window exists: the reader must find
#              no pane at all.
#
# `src/tests/visual/screen_oracle/plat40_record.nim` reads the frames into
# PLAT-39's domain types and writes `src/tests/visual/plat40-readings.json`;
# `test_plat40_producers.nim` asserts over that record.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1
WS="$(cd "${root}/.." && pwd)"
ISONIM_GPUI="${WS}/isonim-gpui"
OUT="${root}/build/plat40"
BIN="${CODETRACER_PLAT40_BIN:-${root}/build/bin/codetracer-gpui}"
CALC="${CODETRACER_PLAT40_TRACE:-${root}/test-logs/tui-fixtures/calc-2f0db4f45192}"
LAYOUT="${root}/src/tests/visual/plat40-layout.json"
# The operations, in `--replay-ops`'s spelling. Kept in ONE place the desktop
# capture reads too (`plat40-scenario.json`), so the two front-ends cannot be
# driven to different stops.
OPS="$(python3 -c "import json; print(json.load(open('${root}/src/tests/visual/plat40-scenario.json'))['gpuiOps'])")"
FRAME_W=1920
FRAME_H=1080
POLL_S=3
STABLE_GRABS=2
SETTLE_MAX_S=150
QUIT_AFTER_MS=180000
INSIDE=0
[ "${1:-}" = "--inside" ] && INSIDE=1

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

one() {
	local id="$1"
	shift
	LD_LIBRARY_PATH="${CODETRACER_GPUI_RUNTIME_LIB_PATH:-}:${LD_LIBRARY_PATH:-}" \
		"${BIN}" "--quit-after-ms=${QUIT_AFTER_MS}" \
		"--width=${FRAME_W}" "--height=${FRAME_H}" \
		"--replay-ops=${OPS}" "--plan-out=${OUT}/${id}.plan.json" \
		"$@" "${CALC}" >"${OUT}/${id}.run.log" 2>&1 &
	local app=$!
	local prev="${OUT}/${id}.prev.ppm" cur="${OUT}/${id}.cur.ppm" settled=false
	local waited=0 same=0
	while [ "${waited}" -lt "${SETTLE_MAX_S}" ] && kill -0 "${app}" 2>/dev/null; do
		sleep "${POLL_S}"
		waited=$((waited + POLL_S))
		grim -t ppm "${cur}" >>"${OUT}/${id}.grim.log" 2>&1 || continue
		if [ -f "${prev}" ] && cmp -s "${prev}" "${cur}"; then
			same=$((same + 1))
		else
			same=0
		fi
		if [ "${same}" -ge "${STABLE_GRABS}" ] &&
			python3 - "${cur}" <<'PY'; then
import sys
d = open(sys.argv[1], "rb").read()
raster = d.split(b"\n", 3)[3]
sys.exit(0 if max(raster[::97]) > 40 else 1)
PY
			settled=true
			mv "${cur}" "${OUT}/${id}.ppm"
			break
		fi
		mv "${cur}" "${prev}"
	done
	rm -f "${prev}" "${cur}"
	kill "${app}" 2>/dev/null
	wait "${app}" 2>/dev/null
	local rc=$?
	printf '{"id":"%s","ops":"%s","extra":"%s","rc":%d,"settled":%s,"settledAfterS":%d}\n' \
		"${id}" "${OPS}" "$*" "${rc}" "${settled}" "${waited}" >>"${OUT}/manifest.jsonl"
	echo "  ${id}: settled=${settled} after ${waited}s"
}

inside() {
	rm -rf "${OUT}"
	mkdir -p "${OUT}"
	grim -t ppm "${OUT}/blank.ppm" >"${OUT}/blank.grim.log" 2>&1
	printf '{"id":"blank","ops":"","extra":"","rc":0,"settled":true,"settledAfterS":0}\n' \
		>>"${OUT}/manifest.jsonl"
	one panes "--layout=${LAYOUT}"
	one default
}

if [ "${INSIDE}" = "1" ]; then
	inside
	exit $?
fi

[ -x "${BIN}" ] || fail "${BIN} is not built"
[ -d "${CALC}" ] || fail "the calc recording is not at ${CALC} — run 'just test-tui' once"
for tool in sway wayland-info grim python3; do
	command -v "${tool}" >/dev/null 2>&1 || fail "'${tool}' is not on PATH"
done
[ "${CODETRACER_WINDOW_BIN_PINS_SHIM:-0}" = "1" ] ||
	fail "this lane needs a binary built with -d:gpuiShimPath=<windowed shim>
      (CODETRACER_WINDOW_BIN_PINS_SHIM=1); it does not swap the shared shim."
bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" -- \
	bash "${root}/ci/test/plat40-panes-window.sh" --inside
rc=$?
echo "plat40-panes-window: rc=${rc}"
exit "${rc}"
