#!/usr/bin/env bash
# plat38-wait.sh — the state waits of PLAT-38's capture lane
# (`ci/test/plat38-keystroke.sh`), sourced. Every wait is bounded by
# PLAT38_WAIT_S (default 150 s) and answers non-zero when it runs out.

# plat38_wait_ready GEOMETRY OUT [DIFFERENT_FROM] — wait until the window has
# written GEOMETRY (its first arrangement is drawn) and three `grim` grabs a
# second apart are identical and painted (and, with DIFFERENT_FROM, differ
# from that frame). The last grab is left in OUT.
plat38_wait_ready() {
	local geometry="$1" out="$2" other="${3:-}" t=0 same=0
	local prev="${out}.prev"
	rm -f "${prev}"
	while [ "${t}" -lt "${PLAT38_WAIT_S:-150}" ]; do
		if [ -s "${geometry}" ] && grim -t ppm "${out}" >/dev/null 2>&1 && [ -s "${out}" ]; then
			if [ -s "${prev}" ] && cmp -s "${out}" "${prev}"; then
				same=$((same + 1))
			else
				same=0
			fi
			cp -f "${out}" "${prev}"
			if [ "${same}" -ge 2 ] && python3 -c 'import sys; sys.path.insert(0, "ci/test")
from plat38_frames import read_ppm, nonblank_fraction
f = read_ppm(sys.argv[1])
sys.exit(0 if f and nonblank_fraction(f[2]) > 0.05 else 1)' "${out}" &&
				{ [ -z "${other}" ] || ! cmp -s "${out}" "${other}"; }; then
				rm -f "${prev}"
				return 0
			fi
		fi
		sleep 1
		t=$((t + 1))
	done
	rm -f "${prev}"
	return 1
}

# plat38_wait_trace LOG NEEDLE — wait until the window's gesture trace in LOG
# names NEEDLE.
plat38_wait_trace() {
	local log="$1" needle="$2" t=0
	while [ "${t}" -lt "${PLAT38_WAIT_S:-150}" ]; do
		grep -q "gesture ${needle}" "${log}" 2>/dev/null && return 0
		sleep 1
		t=$((t + 1))
	done
	return 1
}
