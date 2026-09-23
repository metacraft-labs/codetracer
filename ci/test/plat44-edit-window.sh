#!/usr/bin/env bash
# PLAT-44 — A KEYSTROKE CHANGES A FILE ON DISK, THROUGH THE SHIPPED BINARY,
# IN A WINDOW.
#
# PLAT-23's G4 threshold verbatim: "the GPUI editor accepts a keystroke and
# changes a buffer, or G4 FAILS." This lane is the window half of that:
#
#   * `codetracer-gpui --edit <project>` is opened in a real window on a
#     headless sway (isonim-gpui's `wayland-run-test.sh`, PLAT-37/38's lane);
#   * `wtype` types REAL keys through the compositor's own seat — Shift+q, then
#     Ctrl+s, then F12 (the sentinel that closes the loop, so a run that
#     finished is distinguishable from one the backstop killed);
#   * `grim` takes three frames: a BLANK control before the window exists, the
#     window BEFORE the key, and AFTER it;
#   * the FILE is read off the disk afterwards.
#
# It writes `build/plat44/result.json`. `ci/test/plat44_window_record.py`
# reads the frames through PLAT-39's pixel reader and commits the measurement
# (`src/tests/visual/plat44-edit-window.json`); the portable suite
# `src/frontend/gpui/tests/test_plat44_edit_window.nim` asserts over it — the
# measure-locally-commit-the-measurement arrangement PLAT-37/38/39 use,
# because the assertions are Nim and a compositor is not a CI dependency.
#
# PREREQUISITES are refused BY NAME, never skipped: sway, wayland-info, wtype,
# grim and the WINDOWED shim (`just plat37-shims` in isonim-gpui).
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1
WS="$(cd "${root}/.." && pwd)"
ISONIM_GPUI="${WS}/isonim-gpui"
OUT="${root}/build/plat44"
BIN="${CODETRACER_PLAT44_BIN:-${root}/build/bin/codetracer-gpui}"
# THE BINARY AND THE WINDOWED SHIM MUST SHARE A C RUNTIME. The windowed shim
# is built in isonim-gpui's shell (`just plat37-shims`); a `codetracer-gpui`
# built against an older glibc cannot load it and exits at once with
# "could not load: …libgpui_nim_shim.so" (measured 2026-09-23 when this
# workspace's dev shell fell back to a profile with glibc 2.40 against a shim
# built with 2.42). `CODETRACER_PLAT44_BIN` names a binary built in the shim's
# toolchain; the result records which one ran.
PROJECT="${OUT}/project"
PROJECT_FILE="doc.txt"
PROJECT_TEXT=$'alpha beta\ngamma\n'
FRAME_W=1440
FRAME_H=900
SETTLE_S=14
KEY_GAP_MS=250
QUIT_AFTER_MS=45000
SENTINEL="f12"
INSIDE=0
[ "${1:-}" = "--inside" ] && INSIDE=1

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

check_prereqs() {
	[ -f "${ISONIM_GPUI}/scripts/wayland-run-test.sh" ] ||
		fail "${ISONIM_GPUI}/scripts/wayland-run-test.sh is missing"
	[ -x "${BIN}" ] || fail "${BIN} is not built. \`just build-gpui\` first."
	for tool in sway wayland-info wtype grim python3; do
		command -v "${tool}" >/dev/null 2>&1 ||
			fail "'${tool}' is not on PATH. isonim-gpui's dev shell provides
      the compositor tools; this lane refuses rather than running without a
      real keyboard seat."
	done
}

SHIM_DIR="${ISONIM_GPUI}/rust/target/plat37"
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

select_windowed_shim() {
	local src="${SHIM_DIR}/libgpui_nim_shim.windowed.so"
	[ -f "${src}" ] || fail "the WINDOWED shim is not at ${src}.
      Build it: cd ${ISONIM_GPUI} && nix develop --command just plat37-shims"
	nm -D --defined-only "${src}" 2>/dev/null |
		grep -q 'gpui_dispatch_key_to_focus' ||
		fail "${src} predates PLAT-38's key ABI. Rebuild it."
	SHIM_BACKUP="${LIVE_SHIM}.plat44-backup"
	[ -f "${LIVE_SHIM}" ] && mv -f "${LIVE_SHIM}" "${SHIM_BACKUP}"
	cp -f "${src}" "${LIVE_SHIM}"
	echo "selected the WINDOWED shim at ${LIVE_SHIM}"
}

inside() {
	rm -rf "${OUT}"
	mkdir -p "${PROJECT}"
	printf '%s' "${PROJECT_TEXT}" >"${PROJECT}/${PROJECT_FILE}"
	local blank="${OUT}/blank.ppm" before="${OUT}/before.ppm" after="${OUT}/after.ppm"
	grim -t ppm "${blank}" 2>/dev/null || true
	[ -s "${blank}" ] || fail "could not take the blank control frame"
	# The typist: settle, frame BEFORE, Shift+q, frame AFTER, Ctrl+s, sentinel.
	#
	# `CODETRACER_PLAT44_NEGATIVE=1` is the lane's NEGATIVE TWIN: the same run
	# with the Shift+q left out, which must end in `VERDICT: FAIL` — the proof
	# that the verdict below can fail at all (§4).
	local typed="wtype -s ${KEY_GAP_MS} -M shift q -m shift"
	[ "${CODETRACER_PLAT44_NEGATIVE:-0}" = "1" ] && typed="true"
	bash -c "sleep ${SETTLE_S}; grim -t ppm '${before}' >/dev/null 2>&1; \
             ${typed}; sleep 2; \
             grim -t ppm '${after}' >/dev/null 2>&1; \
             wtype -s ${KEY_GAP_MS} -M ctrl s -m ctrl; sleep 2; \
             wtype -s ${KEY_GAP_MS} -k F12" >"${OUT}/typist.log" 2>&1 &
	local typist=$!
	local started ended rc
	started=$(date +%s%3N)
	CODETRACER_GPUI_PROBE_SENTINEL="${SENTINEL}" \
		CODETRACER_TUI_LAYOUT_DIR="${OUT}/state" \
		LD_LIBRARY_PATH="${CODETRACER_GPUI_RUNTIME_LIB_PATH:-}:${LD_LIBRARY_PATH:-}" \
		"${BIN}" --edit "--quit-after-ms=${QUIT_AFTER_MS}" \
		"--width=${FRAME_W}" "--height=${FRAME_H}" "${PROJECT}" \
		>"${OUT}/run.log" 2>&1
	rc=$?
	ended=$(date +%s%3N)
	wait "${typist}" 2>/dev/null || true
	python3 - "${OUT}" "${PROJECT}/${PROJECT_FILE}" "${rc}" \
		"$((ended - started))" "${QUIT_AFTER_MS}" "${PROJECT_TEXT}" "${BIN}" \
		>"${OUT}/result.json" <<'PY'
import json, os, sys
out, path, rc, elapsed, deadline, original, binary = sys.argv[1:8]
on_disk = open(path).read() if os.path.exists(path) else None
print(json.dumps({
    "binary": os.path.basename(binary),
    "rc": int(rc), "elapsedMs": int(elapsed),
    "endedOnDeadline": int(elapsed) >= int(deadline) - 500,
    "original": original, "onDisk": on_disk,
    "expected": "Q" + original,
    "frames": {n: os.path.getsize(os.path.join(out, n + ".ppm"))
               if os.path.exists(os.path.join(out, n + ".ppm")) else 0
               for n in ("blank", "before", "after")},
}, indent=1))
PY
	cat "${OUT}/result.json"
	# THE VERDICT IS THE FILE. A run whose binary died, whose loop ended on the
	# backstop rather than the sentinel, or whose file is not what the keys
	# should have made is a FAILED run — the first version of this lane printed
	# such a result and exited 0.
	python3 - "${OUT}/result.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
ok = (r["rc"] == 0 and not r["endedOnDeadline"]
      and r["onDisk"] == r["expected"]
      and all(r["frames"][k] > 0 for k in ("blank", "before", "after")))
print("VERDICT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
}

if [ "${INSIDE}" = "1" ]; then
	inside
	exit $?
fi

check_prereqs
# A binary built with `-d:gpuiShimPath=<windowed shim>` loads its own shim and
# the shared one is left alone (`CODETRACER_WINDOW_BIN_PINS_SHIM=1`).
[ "${CODETRACER_WINDOW_BIN_PINS_SHIM:-0}" = "1" ] || select_windowed_shim
mkdir -p "${OUT}"
bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" -- \
	bash "${root}/ci/test/plat44-edit-window.sh" --inside
rc=$?
echo "plat44-edit-window: rc=${rc}"
exit "${rc}"
