#!/usr/bin/env bash
# PLAT-68 Phase A — THE CUA EDITING SEQUENCE IN A REAL GPUI WINDOW.
#
# The milestone's GPUI box: *"the same editing sequence through PLAT-38's key
# delivery gives the same document"*. The same sequence the terminal suite
# (`test_plat68_keymaps_pty.nim`) types through a pty is typed here through a
# compositor's seat into `codetracer-gpui --edit`:
#
#   * a real window on a headless sway (isonim-gpui's `wayland-run-test.sh`,
#     PLAT-37/38/44's lane);
#   * `wtype` types REAL keys — `x y`, `Shift+Right` ×3, `Ctrl+C`, `End`,
#     `Ctrl+V`, `Ctrl+Z`, `Ctrl+Y`, `Down`, `Ctrl+Shift+K`, `Ctrl+S`, and the
#     `F12` sentinel that ends the loop (a run that finished, not one the
#     backstop killed), with pauses past the undo-grouping delay where the
#     terminal suite pauses;
#   * every key's canonical name, as the edit arm decoded it, is logged
#     (`CODETRACER_GPUI_EDIT_TRACE=1`), and the FILE is read off the disk.
#
# It writes `build/plat68/result.json`; `--record` copies it to the committed
# record `src/tests/visual/plat68-cua-window.json`, which the portable suite
# `src/frontend/gpui/tests/test_plat68_cua_window.nim` asserts over — the
# measure-locally-commit-the-measurement arrangement of PLAT-37/38/44, because
# a compositor is not a CI dependency of the test lanes. The re-taking itself
# is a step of the `gpui-window-captures` CI job
# (`ci/test/gpui-window-captures.sh plat68`), which replaces the record with
# a fresh measurement of the commit and runs the suite over it.
#
# PREREQUISITES are refused BY NAME, never skipped: sway, wayland-info, wtype,
# and a `codetracer-gpui` built against the WINDOWED shim
# (`-d:gpuiShimPath=…/windowed/debug/libgpui_nim_shim.so`), named by
# `CODETRACER_PLAT68_BIN`.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1
WS="$(cd "${root}/.." && pwd)"
ISONIM_GPUI="${CODETRACER_PLAT68_ISONIM_GPUI:-${WS}/isonim-gpui}"
OUT="${root}/build/plat68"
BIN="${CODETRACER_PLAT68_BIN:-${root}/build/bin/codetracer-gpui-window}"
PROJECT="${OUT}/project"
PROJECT_FILE="doc.txt"
PROJECT_TEXT=$'alpha\n    beta\ngamma\n'
EXPECTED=$'xyalphaalp\ngamma\n'
SETTLE_S=14
KEY_GAP_MS=120
PAUSE_S=1
QUIT_AFTER_MS=60000
INSIDE=0
[ "${1:-}" = "--inside" ] && INSIDE=1
RECORD=0
[ "${1:-}" = "--record" ] && RECORD=1

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

inside() {
	rm -rf "${OUT}"
	mkdir -p "${PROJECT}"
	printf '%s' "${PROJECT_TEXT}" >"${PROJECT}/${PROJECT_FILE}"
	local w="wtype -s ${KEY_GAP_MS}"
	bash -c "sleep ${SETTLE_S}; \
             ${w} xy; sleep ${PAUSE_S}; \
             ${w} -M shift -k Right -k Right -k Right -m shift; \
             ${w} -M ctrl c -m ctrl; ${w} -k End; sleep ${PAUSE_S}; \
             ${w} -M ctrl v -m ctrl; sleep ${PAUSE_S}; \
             ${w} -M ctrl z -m ctrl; sleep ${PAUSE_S}; \
             ${w} -M ctrl y -m ctrl; ${w} -k Down; sleep ${PAUSE_S}; \
             ${w} -M ctrl -M shift k -m shift -m ctrl; sleep ${PAUSE_S}; \
             ${w} -M ctrl s -m ctrl; sleep 2; \
             ${w} -k F12" >"${OUT}/typist.log" 2>&1 &
	local typist=$!
	local started ended rc
	started=$(date +%s%3N)
	CODETRACER_GPUI_PROBE_SENTINEL="f12" \
		CODETRACER_GPUI_EDIT_TRACE=1 \
		CODETRACER_TUI_LAYOUT_DIR="${OUT}/state" \
		LD_LIBRARY_PATH="${CODETRACER_GPUI_RUNTIME_LIB_PATH:-}:${LD_LIBRARY_PATH:-}" \
		"${BIN}" --edit "--quit-after-ms=${QUIT_AFTER_MS}" \
		"--width=1440" "--height=900" "${PROJECT}" \
		>"${OUT}/run.log" 2>&1
	rc=$?
	ended=$(date +%s%3N)
	wait "${typist}" 2>/dev/null || true
	python3 - "${OUT}" "${PROJECT}/${PROJECT_FILE}" "${rc}" \
		"$((ended - started))" "${QUIT_AFTER_MS}" "${PROJECT_TEXT}" \
		"${EXPECTED}" "${BIN}" >"${OUT}/result.json" <<'PY'
import json, os, socket, sys, datetime
out, path, rc, elapsed, deadline, original, expected, binary = sys.argv[1:9]
on_disk = open(path).read() if os.path.exists(path) else None
keys = []
for line in open(os.path.join(out, "run.log"), errors="replace"):
    if line.startswith("edit-key "):
        parts = line.split()
        keys.append({"gpui": parts[1], "name": parts[3], "outcome": parts[4]})
print(json.dumps({
    "takenAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "host": socket.gethostname(),
    "binary": os.path.basename(binary),
    "rc": int(rc), "elapsedMs": int(elapsed),
    "endedOnDeadline": int(elapsed) >= int(deadline) - 500,
    "original": original, "onDisk": on_disk, "expected": expected,
    "keys": keys,
}, indent=1))
PY
	cat "${OUT}/result.json"
	python3 - "${OUT}/result.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
ok = r["rc"] == 0 and not r["endedOnDeadline"] and r["onDisk"] == r["expected"]
print("VERDICT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
}

if [ "${INSIDE}" = "1" ]; then
	inside
	exit $?
fi
if [ "${RECORD}" = "1" ]; then
	[ -f "${OUT}/result.json" ] || fail "no ${OUT}/result.json; run this lane first"
	cp "${OUT}/result.json" src/tests/visual/plat68-cua-window.json
	echo "recorded src/tests/visual/plat68-cua-window.json"
	exit 0
fi

[ -f "${ISONIM_GPUI}/scripts/wayland-run-test.sh" ] ||
	fail "${ISONIM_GPUI}/scripts/wayland-run-test.sh is missing"
[ -x "${BIN}" ] || fail "${BIN} is not built (a codetracer-gpui against the windowed shim)"
for tool in sway wayland-info wtype python3; do
	command -v "${tool}" >/dev/null 2>&1 ||
		fail "'${tool}' is not on PATH; this lane refuses rather than running without a real keyboard seat"
done
mkdir -p "${OUT}"
bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" -- \
	bash "${root}/ci/test/plat68-cua-window.sh" --inside
rc=$?
echo "plat68-cua-window: rc=${rc}"
exit "${rc}"
