#!/usr/bin/env bash
# PLAT-42 — THE FRAME BUDGET, MEASURED IN A WINDOW, REPORTED WITH THE HOST LOAD.
#
# PLAT-22's deliverable 2 with its blocker removed: a LARGE file (40,000 lines)
# opened in a real `codetracer-gpui --edit` window on a headless sway, scrolled
# (80 x Down — past both viewports, so the pane scrolls with the caret) and edited (typed text), with the
# shim recording every frame's RENDER-PATH time and every key-to-next-frame
# latency (`--frame-report`). Two viewports.
#
# WHAT IS MEASURED, EXACTLY: the render path (shadow-tree walk, render plan,
# GPUI element tree) — NOT GPUI's own layout and paint, which run after
# `render` returns and are not instrumented. The key-to-frame latency includes
# the host's handler (the edit, the redraw) and the repaint poller's wait.
#
# NEVER ASSERTED AGAINST A CONSTANT (Verification-Harness-Traps §28a): this host
# is shared, and a timing taken on it is a measurement of it. The load average
# at start and end and the CPU count are recorded beside every figure, and the
# gate over the record asserts only that the measurement HAPPENED (frames and
# latencies were recorded, the run ended on its sentinel).
#
# "Stepped through" — PLAT-22's wording — is NOT measured here: the GPUI
# replay window binds no key to a replay operation (PLAT-23's `--ui=gui`
# contract), so stepping cannot be driven in a window. The large file is
# scrolled and edited instead, and that substitution is stated in the record.
#
# Output: build/plat42-frames/<viewport>.json. `ci/test/plat42_frames_record.py`
# summarises them into src/tests/visual/plat42-frame-budget.json.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1
WS="$(cd "${root}/.." && pwd)"
ISONIM_GPUI="${WS}/isonim-gpui"
OUT="${root}/build/plat42-frames"
BIN="${CODETRACER_PLAT42_BIN:-${root}/build/bin/codetracer-gpui}"
WINDOWED_SHIM="${CODETRACER_PLAT42_WINDOWED_SHIM:-${ISONIM_GPUI}/rust/target/plat37/libgpui_nim_shim.windowed.so}"
LINES=40000
SETTLE_S=16
QUIT_AFTER_MS=420000
SENTINEL="f12"
DOWNS=80
PAUSE_MS=2000
INSIDE=0
[ "${1:-}" = "--inside" ] && INSIDE=1

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

LIVE_SHIM="${ISONIM_GPUI}/rust/target/debug/libgpui_nim_shim.so"
SHIM_BACKUP=""
# shellcheck disable=SC2329  # invoked indirectly, by the EXIT trap below
restore_shim() {
	if [ -n "${SHIM_BACKUP}" ] && [ -f "${SHIM_BACKUP}" ]; then
		mv -f "${SHIM_BACKUP}" "${LIVE_SHIM}"
		SHIM_BACKUP=""
		echo "restored ${LIVE_SHIM}"
	fi
}
trap restore_shim EXIT INT TERM

one_viewport() {
	local w="$1" h="$2"
	local name="${w}x${h}"
	local project="${OUT}/project-${name}"
	rm -rf "${project}"
	mkdir -p "${project}"
	python3 - "${project}/large.py" "${LINES}" <<'PY'
import sys
path, n = sys.argv[1], int(sys.argv[2])
with open(path, "w") as f:
    for i in range(1, n + 1):
        f.write(f"value_{i} = compute(value_{i - 1 if i > 1 else i}, {i})  # line {i}\n")
PY
	# ONE `wtype` PROCESS, WITH A SLEEP BETWEEN KEYS INSIDE ITS SEQUENCE.
	# Measured 2026-09-23, both ways: `wtype -s N` once at the front is a single
	# sleep, so all keys arrived at once and GPUI drew 8 frames in 300 s; and
	# one `wtype` PROCESS PER KEY lost keys (3 of 14 Downs arrived on a 100-line
	# file) — each process is a new virtual keyboard and its first key races the
	# client's keymap. One process with `-k Down -s <ms>` repeated delivered all
	# 14 and the sentinel. The pause is generous because the editing core costs
	# ~0.5-0.9 s per operation at 40,000 lines (measured in-process).
	local seq_args=""
	for _ in $(seq 1 "${DOWNS}"); do seq_args+=" -k Down -s ${PAUSE_MS}"; done
	for c in t y p e d; do seq_args+=" ${c} -s ${PAUSE_MS}"; done
	local typing="sleep ${SETTLE_S}; wtype ${seq_args} -s 2000 -k F12"
	bash -c "${typing}" >"${OUT}/${name}.typist.log" 2>&1 &
	local typist=$!
	CODETRACER_GPUI_PROBE_SENTINEL="${SENTINEL}" \
		CODETRACER_TUI_LAYOUT_DIR="${OUT}/state-${name}" \
		LD_LIBRARY_PATH="${CODETRACER_GPUI_RUNTIME_LIB_PATH:-}:${LD_LIBRARY_PATH:-}" \
		"${BIN}" --edit "--quit-after-ms=${QUIT_AFTER_MS}" \
		"--width=${w}" "--height=${h}" \
		"--frame-report=${OUT}/${name}.json" "${project}" \
		>"${OUT}/${name}.run.log" 2>&1
	echo "  ${name}: rc=$?"
	wait "${typist}" 2>/dev/null || true
}

inside() {
	rm -rf "${OUT}"
	mkdir -p "${OUT}"
	one_viewport 1440 900
	one_viewport 2560 1440
	ls -la "${OUT}"/*.json
}

if [ "${INSIDE}" = "1" ]; then
	inside
	exit $?
fi

[ -x "${BIN}" ] || fail "${BIN} is not built"
for tool in sway wayland-info wtype python3; do
	command -v "${tool}" >/dev/null 2>&1 || fail "'${tool}' is not on PATH"
done
[ -f "${WINDOWED_SHIM}" ] || fail "no windowed shim at ${WINDOWED_SHIM}"
grep -q 'gpui_frame_count' <<<"$(nm -D --defined-only "${WINDOWED_SHIM}" 2>/dev/null)" ||
	fail "${WINDOWED_SHIM} predates the frame-timing ABI; rebuild it"
# A binary built with `-d:gpuiShimPath=<windowed shim>` loads its own shim and
# the shared one is left alone (`CODETRACER_WINDOW_BIN_PINS_SHIM=1`); otherwise
# the shared file is swapped for the run and restored by the trap.
if [ "${CODETRACER_WINDOW_BIN_PINS_SHIM:-0}" != "1" ]; then
	SHIM_BACKUP="${LIVE_SHIM}.plat42-backup"
	[ -f "${LIVE_SHIM}" ] && mv -f "${LIVE_SHIM}" "${SHIM_BACKUP}"
	cp -f "${WINDOWED_SHIM}" "${LIVE_SHIM}"
fi
bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" -- \
	bash "${root}/ci/test/plat42-frame-budget.sh" --inside
rc=$?
echo "plat42-frame-budget: rc=${rc}"
exit "${rc}"
