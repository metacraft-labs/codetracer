#!/usr/bin/env bash
# Exercise the real lane runner and inventory with a recording compiler and
# uname fixture. These stand-ins isolate selection/reporting from product code;
# the real Darwin compiler refusal is checked separately during issue review.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"
work="$(mktemp -d /tmp/ct-lane-platform.XXXXXX)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin" "${work}/tmp"
cat >"${work}/bin/uname" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${PLATFORM}"
STUB
cat >"${work}/bin/nim" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CALLS}"
if [ "${COMPILE_FAIL:-0}" = 1 ]; then
 echo 'Error: deliberate compiler failure' >&2
 exit 1
fi
for arg in "$@"; do
 case "$arg" in -o:*) out="${arg#-o:}" ;; esac
done
mkdir -p "$(dirname "${out}")"
printf '#!/usr/bin/env bash\necho "[OK] platform fixture"\n' >"${out}"
chmod +x "${out}"
STUB
chmod +x "${work}/bin/"*
# shellcheck source=ci/lib/test-lane-files.sh
# shellcheck disable=SC1091 # resolved at runtime from $root
source "${root}/ci/lib/test-lane-files.sh"
killed=src/tests/ct_host/test_ct_host_killed_leaves_no_process_behind.nim
inventory="$(test_lane_files ct-host-admission)"
grep -qxF "${killed}" <<<"${inventory}"
count="$(wc -l <<<"${inventory}" | tr -d ' ')"
for platform in Darwin Linux MINGW64_NT-10.0 FreeBSD; do
	for mode in run compile; do
		export PLATFORM="${platform}" CALLS="${work}/calls"
		: >"${CALLS}"
		args=()
		[ "${mode}" = run ] || args=(--compile-only)
		out="$(PATH="${work}/bin:${PATH}" TMPDIR="${work}/tmp" \
			CT_NIM_CACHE_ROOT="${work}/cache" CT_LANE_TIMEOUT=0 \
			bash ci/lib/run-nim-test-lane.sh ct-host-admission "${args[@]+${args[@]}}")"
		calls="$(wc -l <"${CALLS}" | tr -d ' ')"
		expected="${count}"
		if [ "${platform}" = Linux ]; then
			grep -qF "${killed}" "${CALLS}"
			if grep -qF 'SKIPPED (linux-only)' <<<"${out}"; then exit 1; fi
		else
			expected=$((count - 1))
			if grep -qF "${killed}" "${CALLS}"; then exit 1; fi
			grep -qF "${killed} ... SKIPPED (linux-only)" <<<"${out}"
			grep -qF '1 file(s) SKIPPED' <<<"${out}"
		fi
		[ "${calls}" = "${expected}" ]
		expected_files="${inventory}"
		if [ "${platform}" != Linux ]; then
			expected_files="$(grep -vxF "${killed}" <<<"${inventory}")"
		fi
		# Compare the exact population, retaining duplicate compiler calls as errors.
		actual_files="$(awk '{print $NF}' "${CALLS}" | sort)"
		[ "${actual_files}" = "$(sort <<<"${expected_files}")" ]
		if [ "${mode}" = run ]; then
			grep -qF "${expected} case(s)" <<<"${out}"
		fi
		grep -qF "${expected} file(s) passed, 0 failed" <<<"${out}"
		echo "OK: ${platform} ${mode}: ${calls} compiler calls, explicit platform report"
	done
done
# Eligibility never excuses a broken portable suite, on any host.
export PLATFORM=Darwin COMPILE_FAIL=1
if PATH="${work}/bin:${PATH}" TMPDIR="${work}/tmp" \
	CT_NIM_CACHE_ROOT="${work}/cache" CT_LANE_TIMEOUT=0 \
	bash ci/lib/run-nim-test-lane.sh ct-host-admission --compile-only >"${work}/failure" 2>&1; then
	echo 'FAIL: portable compile errors were swallowed' >&2
	exit 1
fi
grep -qF 'COMPILE ERROR' "${work}/failure"
echo 'OK: portable compile failure remains a lane failure'
