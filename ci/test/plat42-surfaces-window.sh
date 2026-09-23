#!/usr/bin/env bash
# PLAT-42 — THE FOUR SURFACES, ON SCREEN: each pinned stop opened in a REAL
# `codetracer-gpui` window on a headless sway and framed with `grim`.
#
# Frames, written to build/plat42-window/<id>.ppm:
#   * the six pinned calc scenarios (src/tests/visual/scenarios.json), with
#     their own `--replay-ops` — the pointer and the inline values;
#   * `noir-flow` and `noir-flow-off`: noir_space_ship stopped (`stepIn=15`)
#     beside the declined `if` arm, with the flow overlay shown and hidden —
#     the flow overlay's PIXEL TWIN;
#   * `breakpoint-editor` against `stepped-editor` — the same stop with and
#     without the breakpoint — is the per-line status mark's pixel twin.
#
# No key is typed: the window is framed once it has SETTLED (two identical,
# non-blank grabs in a row) and is then closed; `settled` and the time it took
# are in the manifest. `ci/test/plat42_window_record.nim`
# reads the frames through PLAT-39's reader and writes
# src/tests/visual/plat42-window.json; `test_plat42_window.nim` asserts over it.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1
WS="$(cd "${root}/.." && pwd)"
ISONIM_GPUI="${WS}/isonim-gpui"
OUT="${root}/build/plat42-window"
BIN="${CODETRACER_PLAT42_BIN:-${root}/build/bin/codetracer-gpui}"
CALC="${CODETRACER_PLAT42_TRACE:-${root}/test-logs/tui-fixtures/calc-2f0db4f45192}"
NOIR="${CODETRACER_PLAT42_FLOW_TRACE:-${root}/test-logs/tui-fixtures/noir_space_ship-f9f31b01a0d2}"
SCENARIOS="${root}/src/tests/visual/scenarios.json"
# THE WIDEST WINDOW THE HEADLESS OUTPUT HOLDS (1920x1080), and measured
# rather than chosen: the inline value is drawn in the space the code leaves
# on its row, as the terminal draws it, and at 1440x900 the editor pane — a
# fifth of the window, 276 px — left none at `returned-calltrace`'s stop
# (`» 110 results.append(va`, clipped). A frame in which a surface cannot
# appear is not a frame that shows it.
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
	local id="$1" trace="$2" ops="$3"
	shift 3
	local argv=("${BIN}" "--quit-after-ms=${QUIT_AFTER_MS}"
		"--width=${FRAME_W}" "--height=${FRAME_H}")
	[ -n "${ops}" ] && argv+=("--replay-ops=${ops}")
	argv+=("$@" "${trace}")
	LD_LIBRARY_PATH="${CODETRACER_GPUI_RUNTIME_LIB_PATH:-}:${LD_LIBRARY_PATH:-}" \
		"${argv[@]}" >"${OUT}/${id}.run.log" 2>&1 &
	local app=$!
	# THE FRAME IS TAKEN WHEN THE WINDOW HAS SETTLED, NOT AFTER A FIXED DELAY.
	# A fixed 20 s was measured to be too short on a loaded host (load ~170 on
	# 24 CPUs): five of eight frames came back black. So: grab every
	# ${POLL_S} s, and keep the first frame that is not blank AND is
	# byte-identical to the ${STABLE_GRABS} grabs before it — the window drew
	# and stopped changing for ${STABLE_GRABS} x ${POLL_S} s, which a
	# replay still loading does not do. Then the window is closed; a frame the loop never settled on is
	# recorded as `settled:false` and the reader refuses it.
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
# P6 header: magic, dims, maxval, then the raster.
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
	printf '{"id":"%s","trace":"%s","ops":"%s","extra":"%s","rc":%d,"settled":%s,"settledAfterS":%d}\n' \
		"${id}" "$(basename "${trace}")" "${ops}" "$*" "${rc}" "${settled}" "${waited}" \
		>>"${OUT}/manifest.jsonl"
	echo "  ${id}: settled=${settled} after ${waited}s frame=$(stat -c %s "${OUT}/${id}.ppm" 2>/dev/null || echo 0)"
}

inside() {
	rm -rf "${OUT}"
	mkdir -p "${OUT}"
	# THE BLANK CONTROL: the compositor's output before any window exists.
	# The reader must find none of the four surfaces on it — a reader that
	# "found" a pointer or a value here would be reading the compositor.
	grim -t ppm "${OUT}/blank.ppm" >"${OUT}/blank.grim.log" 2>&1
	printf '{"id":"blank","trace":"","ops":"","extra":"","rc":0,"settled":true,"settledAfterS":0}\n' \
		>>"${OUT}/manifest.jsonl"
	while IFS=$'\t' read -r id ops; do
		one "${id}" "${CALC}" "${ops}"
	done < <(
		python3 - "${SCENARIOS}" <<'PY'
import json, sys
for s in json.load(open(sys.argv[1]))["scenarios"]:
    terms = []
    for op in s.get("operations") or []:
        if op["kind"] == "setBreakpoint":
            terms.append(f"setBreakpoint@{op['line']}")
        else:
            terms.append(f"{op['kind']}={op.get('times', 1)}")
    print(s["id"] + "\t" + ",".join(terms))
PY
	)
	one noir-flow "${NOIR}" "stepIn=15"
	one noir-flow-off "${NOIR}" "stepIn=15" --no-flow-overlay
}

if [ "${INSIDE}" = "1" ]; then
	inside
	exit $?
fi

[ -x "${BIN}" ] || fail "${BIN} is not built"
[ -d "${CALC}" ] || fail "the calc recording is not at ${CALC}"
[ -d "${NOIR}" ] || fail "the noir_space_ship recording is not at ${NOIR}"
for tool in sway wayland-info grim python3; do
	command -v "${tool}" >/dev/null 2>&1 || fail "'${tool}' is not on PATH"
done
[ "${CODETRACER_WINDOW_BIN_PINS_SHIM:-0}" = "1" ] ||
	fail "this lane needs a binary built with -d:gpuiShimPath=<windowed shim>
      (CODETRACER_WINDOW_BIN_PINS_SHIM=1); it does not swap the shared shim."
bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" -- \
	bash "${root}/ci/test/plat42-surfaces-window.sh" --inside
rc=$?
echo "plat42-surfaces-window: rc=${rc}"
exit "${rc}"
