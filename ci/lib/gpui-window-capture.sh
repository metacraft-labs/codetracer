#!/usr/bin/env bash
# gpui-window-capture.sh — one `codetracer-gpui` window, opened on a real
# compositor, framed with `grim` once it has SETTLED. Sourced by the pane
# capture lanes (`ci/test/plat40-panes-window.sh`,
# `ci/test/plat41-panes-window.sh`); it defines functions and sets nothing
# until one is called.
#
# The caller sets, before calling `capture_window`:
#   BIN            the windowed binary (built with -d:gpuiShimPath)
#   OUT            the directory frames and records go to
#   TRACE          the recording to open
#   OPS            the `--replay-ops` spec
#   FRAME_W/H      the window's size (default 1920x1080)
#
# THE FRAME IS TAKEN WHEN THE WINDOW HAS SETTLED, NOT AFTER A FIXED DELAY:
# two consecutive byte-identical, non-blank grabs, polled every POLL_S. A
# fixed sleep was measured to produce black frames at this host's load.

: "${FRAME_W:=1920}" "${FRAME_H:=1080}" "${POLL_S:=3}" "${STABLE_GRABS:=2}"
: "${SETTLE_MAX_S:=150}" "${QUIT_AFTER_MS:=180000}"

# capture_window <id> [extra args…] — writes ${OUT}/<id>.ppm, <id>.plan.json,
# <id>.run.log, and appends one JSON line to ${OUT}/manifest.jsonl.
capture_window() {
	local id="$1"
	shift
	LD_LIBRARY_PATH="${CODETRACER_GPUI_RUNTIME_LIB_PATH:-}:${LD_LIBRARY_PATH:-}" \
		"${BIN}" "--quit-after-ms=${QUIT_AFTER_MS}" \
		"--width=${FRAME_W}" "--height=${FRAME_H}" \
		"--replay-ops=${OPS}" "--plan-out=${OUT}/${id}.plan.json" \
		"$@" "${TRACE}" >"${OUT}/${id}.run.log" 2>&1 &
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

# capture_blank — the compositor before any window exists: the negative
# control every reader must find no pane on.
capture_blank() {
	grim -t ppm "${OUT}/blank.ppm" >"${OUT}/blank.grim.log" 2>&1
	printf '{"id":"blank","ops":"","extra":"","rc":0,"settled":true,"settledAfterS":0}\n' \
		>>"${OUT}/manifest.jsonl"
}
