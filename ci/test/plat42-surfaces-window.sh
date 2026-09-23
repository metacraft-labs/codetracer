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
# No key is typed: the window is framed after it settles and the loop ends on
# its deadline, BY DESIGN (the record says so). `ci/test/plat42_window_record.nim`
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
FRAME_W=1440
FRAME_H=900
SETTLE_S=20
QUIT_AFTER_MS=30000
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
	bash -c "sleep ${SETTLE_S}; grim -t ppm '${OUT}/${id}.ppm'" \
		>"${OUT}/${id}.grim.log" 2>&1 &
	local grabber=$!
	LD_LIBRARY_PATH="${CODETRACER_GPUI_RUNTIME_LIB_PATH:-}:${LD_LIBRARY_PATH:-}" \
		"${argv[@]}" >"${OUT}/${id}.run.log" 2>&1
	local rc=$?
	wait "${grabber}" 2>/dev/null || true
	printf '{"id":"%s","trace":"%s","ops":"%s","extra":"%s","rc":%d}\n' \
		"${id}" "$(basename "${trace}")" "${ops}" "$*" "${rc}" \
		>>"${OUT}/manifest.jsonl"
	echo "  ${id}: rc=${rc} frame=$(stat -c %s "${OUT}/${id}.ppm" 2>/dev/null || echo 0)"
}

inside() {
	rm -rf "${OUT}"
	mkdir -p "${OUT}"
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
