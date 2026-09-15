#!/usr/bin/env bash
#
# plat18-dev-loop.sh — Uniform-WASM-Core.md §4 metric 7 and §5's fifth
# criterion: "the developer loop does not get materially slower".
#
# ## WHAT A DEVELOPER LOOP IS, HERE — AND WHY THAT IS A PROXY
#
# One edit, one suite, compiled and run. Not the whole lane: a developer
# waiting on `just test-vm-unit` is waiting on seventy-seven suites and would
# be doing that on any backend, and the number that decides whether a backend
# is tolerable to work in is the one paid per edit.
#
# **§4 METRIC 7 DOES NOT SAY THAT.** It reads "time to run the *full ViewModel
# suite* | Developer feedback loop", and §6 step 3 repeats it. This script
# redefines the metric's subject in its own header, which is the thing a
# header is least able to do honestly: the reader who came from §4 believes
# they are reading metric 7. So what this measures is a PROXY for metric 7 and
# is labelled one, and the metric's own quantity — the LANE — was measured
# separately rather than extrapolated. On one host, one afternoon, three lanes
# cold on one fresh `CT_NIM_CACHE_ROOT`:
#
#   | lane                | files | cold  | s/file |
#   |---------------------+-------+-------+--------|
#   | `vm-unit-js`        |    66 |  76 s |   1.15 |
#   | `vm-unit` (native C)|    77 | 279 s |   3.62 |
#   | `vm-unit-wasm`      |    71 | 628 s |   8.85 |
#
# **8.26x by lane and 7.68x per file**, against this script's ~3.1x. The js
# column cross-checks — this script's own per-suite median times 66 lands on
# the measured js lane — so the proxy is sound on the js side and the wasm
# side is about 2.3x worse at lane scale than the small suite it chose. The
# lane figures are the ones §5's fifth criterion is applied to; this script's
# ratio is reported beside them and is not a substitute for them.
#
# Reproduce the lanes with `ci/lib/run-nim-test-lane.sh` directly. Do not go
# through `just test-vm-*`: those depend on `vm-test-prereqs`, which needs a
# `tailwindcss` this workspace's `isonim/node_modules` does not have.
#
# ## INTERLEAVED, AND WHY
#
# The three backends are compiled and run back to back inside one repetition,
# and the repetition is repeated. Verification-Harness-Traps.md §12a: an
# absolute timing on a loaded host is a coin flip — this campaign has measured
# load 60 on 24 CPUs — so the quantity published is the RATIO between arms
# measured under the same scheduler, and every arm's own median, min and max
# are printed beside it so a reader can see the spread rather than a point.
#
# ## THE CACHE IS CLEARED PER ARM PER REPETITION
#
# A developer's edit invalidates the module they edited and everything
# downstream of it, so a warm-cache figure measures the wrong thing on the
# first run after an edit and the right thing never. Clearing the whole
# nimcache over-states every arm equally, which is the honest direction for a
# comparison: it is the same work on all three.
#
# ## THE SUBJECT IS NAMED, AND IT IS A CLAIM (trap 6)
#
# `test_async_compat_wasm_arm.nim` — PLAT-17's own new suite, 12 cases / 23
# assertions, identical on all three backends and in every one of the three
# lanes. A suite that ran a different number of cases on one backend would
# make this a comparison of two different amounts of work.
#
# Exit 0 if every arm built, ran and reported its cases; 1 otherwise; 2 if a
# tool is missing — a failure, never a skip.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

SUITE="${CT_P18_DEV_SUITE:-src/frontend/viewmodel/tests/unit/test_async_compat_wasm_arm.nim}"
REPS="${CT_P18_DEV_REPS:-3}"
out_dir="${CT_P18_DEV_OUT:-${repo_root}/test-logs/plat18-dev-loop}"

failures=0
fail() {
	echo "  FAIL: $*"
	failures=$((failures + 1))
}
ok() { echo "  ok: $*"; }

for tool in nim emcc node; do
	command -v "${tool}" >/dev/null 2>&1 || {
		echo "ERROR: ${tool} is not on PATH; run inside this repo's dev shell." >&2
		exit 2
	}
done
[ -f "${SUITE}" ] || {
	echo "ERROR: the subject suite ${SUITE} does not exist." >&2
	exit 2
}

rm -rf "${out_dir}"
mkdir -p "${out_dir}"

echo "=== PLAT-18: the developer loop, one suite, three backends ==="
echo "    suite=${SUITE} repetitions=${REPS}"
echo "    host: cpus=$(nproc 2>/dev/null || echo '?') load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo '?')"
echo

now_ms() { date +%s%3N; }

declare -A samples cases_of
for arm in native js wasm; do samples["${arm}"]=""; done

for rep in $(seq 1 "${REPS}"); do
	for arm in native js wasm; do
		cache="${out_dir}/${arm}-${rep}"
		rm -rf "${cache}"
		t0="$(now_ms)"
		case "${arm}" in
		native)
			nim c --hints:off --warnings:off --mm:orc \
				--path:src/frontend/viewmodel \
				--nimcache:"${cache}" -o:"${cache}.bin" "${SUITE}" \
				>"${cache}.log" 2>&1 && "${cache}.bin" >>"${cache}.log" 2>&1
			;;
		js)
			nim js -d:nodejs --hints:off --warnings:off \
				--path:src/frontend/viewmodel \
				--nimcache:"${cache}" -o:"${cache}.js" "${SUITE}" \
				>"${cache}.log" 2>&1 && node "${cache}.js" >>"${cache}.log" 2>&1
			;;
		wasm)
			nim c --hints:off --warnings:off \
				--cpu:wasm32 --os:linux -d:emscripten \
				--cc:clang --clang.exe:emcc --clang.linkerexe:emcc \
				--mm:orc --threads:off \
				--passL:-sSTACK_SIZE=8388608 \
				--passL:-sNODERAWFS=1 \
				--passL:-sALLOW_MEMORY_GROWTH=1 \
				--passL:-sEXIT_RUNTIME=1 \
				--path:src/frontend/viewmodel \
				--nimcache:"${cache}" -o:"${cache}.js" "${SUITE}" \
				>"${cache}.log" 2>&1 && node "${cache}.js" >>"${cache}.log" 2>&1
			;;
		esac
		rc=$?
		t1="$(now_ms)"
		if [ "${rc}" -ne 0 ]; then
			fail "${arm} rep ${rep}: compile or run exited ${rc}"
			tail -10 "${cache}.log" >&2
			continue
		fi
		samples["${arm}"]="${samples[${arm}]} $((t1 - t0))"
		# THE CASE COUNT IS READ FROM THE RUN, NOT ASSUMED. A backend that ran
		# fewer cases took less time for a reason that is not about the
		# backend, and this is where that would show.
		cases_of["${arm}"]="$(grep -c '\[OK\]' "${cache}.log")"
	done
done

# The samples arrive as one space-separated string per arm. `tr` rather than an
# unquoted expansion: word splitting would do the same job and shellcheck is
# right that it is the wrong tool — a sample list is data, and data that
# depends on IFS and on globbing is data with two extra ways to be wrong.
_lines() { printf '%s' "$1" | tr ' ' '\n' | grep -v '^$'; }
median() {
	_lines "$1" | sort -n | awk '{a[NR]=$1} END{print (NR ? a[int((NR+1)/2)] : 0)}'
}
minv() { _lines "$1" | sort -n | head -1; }
maxv() { _lines "$1" | sort -n | tail -1; }

echo
printf '  %-10s %-12s %-10s %-10s %-10s\n' backend "median ms" "min" "max" "[OK] cases"
for arm in native js wasm; do
	printf '  %-10s %-12s %-10s %-10s %-10s\n' "${arm}" \
		"$(median "${samples[${arm}]}")" "$(minv "${samples[${arm}]}")" \
		"$(maxv "${samples[${arm}]}")" "${cases_of[${arm}]:-<none>}"
done
echo

# --- contract 1: the same work on every arm ---------------------------------
#
# FIRST, and the ratio below is gated on it. A backend that ran a different
# number of cases was doing different work, and a ratio between two different
# amounts of work is not a comparison of backends (§10's assertion that cannot
# fail, wearing a stopwatch).
same_work=1
ref="${cases_of[native]:-0}"
for arm in js wasm; do
	if [ "${cases_of[${arm}]:-0}" != "${ref}" ]; then
		fail "${arm} reported ${cases_of[${arm}]:-0} [OK] case(s) against native's ${ref}"
		same_work=0
	fi
done
if [ "${ref}" = "0" ]; then
	fail "native reported 0 [OK] cases — there is no loop here to time"
	same_work=0
fi
if [ "${same_work}" -eq 1 ]; then
	ok "all three backends ran ${ref} case(s) — the same work"
fi

# --- contract 2: the loop is not materially slower under WASM ---------------
if [ "${same_work}" -eq 0 ] || [ "${failures}" -ne 0 ]; then
	echo "  skipped: the wasm/js developer-loop ratio — contract 1 says the three" \
		"arms did not do the same work"
else
	n="$(median "${samples[native]}")"
	j="$(median "${samples[js]}")"
	w="$(median "${samples[wasm]}")"
	# THE REGRESSION LIMIT IS LOOSE ON PURPOSE. It is not §5's criterion —
	# that is reported below — it is the value above which something has
	# broken rather than merely got slower. 5x on a 1.3 s loop is 6.5 s.
	limit="${CT_P18_DEV_MAX:-5.0}"
	# AGAINST `nim js`, NOT AGAINST NATIVE, and that is the whole point of the
	# comparison: §5 asks whether ADOPTING the wasm core makes the loop worse,
	# and what it would replace in Electron and the browser is `nim js`. The
	# native figure is printed because a reader wants it and because it is the
	# floor, not because it is the thing being decided.
	verdict="$(awk -v j="${j}" -v w="${w}" -v lim="${limit}" 'BEGIN{
		if (j + 0 <= 0) { print "NOBASE 0"; exit }
		r = (w + 0) / (j + 0);
		printf "%s %.2f\n", (r <= lim + 0 ? "OK" : "SLOW"), r
	}')"
	read -r kind ratio <<<"${verdict}"
	case "${kind}" in
	OK) ok "one edit-compile-run is ${ratio}x the nim js loop under wasm (regression limit ${limit}x); native median ${n} ms, js ${j} ms, wasm ${w} ms" ;;
	SLOW) fail "one edit-compile-run is ${ratio}x the nim js loop under wasm, above the ${limit}x regression limit" ;;
	*) fail "the nim js median was ${j} ms — too short to divide by" ;;
	esac

	# --- and, SEPARATELY, §5's criterion ---------------------------------
	#
	# TWO THRESHOLDS, AND THEY ARE NOT THE SAME KIND OF THING. The contract
	# above is a REGRESSION GATE: loose, CI-facing, and there to catch a
	# blow-up. The line below is Uniform-WASM-Core.md §5's fifth adopt
	# condition — "the developer loop does not get materially slower" — turned
	# into a number, and it is REPORTED rather than gated.
	#
	# The distinction is the whole reason there are two. A decision criterion
	# wired into CI reddens every day and trains the next person to re-run it
	# (§12a, on exactly this shape); and a criterion whose threshold is chosen
	# AFTER the measurement is the defect this milestone was warned about —
	# a measurement that flatters the option the author has invested in. So
	# the criterion's number is stated as a judgement with its reasoning, the
	# measurement is printed beside it, and a reader who disagrees with the
	# judgement can see the figure it was applied to.
	#
	# 2.0x, because the loop being compared is 1.3 s: at 2x it becomes 2.6 s,
	# which is the region where an edit-run cycle stops feeling immediate.
	# The threshold was stated before the run, the run came out above it, and
	# the criterion is recorded as NOT met rather than re-tuned.
	#
	# NO MEASURED RATIO IS QUOTED IN THIS COMMENT, and that is §12b rather
	# than reticence. The figure this paragraph used to carry (3.01x) was
	# already stale when it was read: the same quantity reads 3.09x in the
	# milestone and 3.29x in an independent re-measurement, so a constant
	# typed here is a third value for one figure with nothing able to notice
	# the disagreement. The run prints `PLAT18-DEV-CRITERION … ratio=` on
	# every invocation; that line is the figure.
	crit="${CT_P18_DEV_CRITERION:-2.0}"
	cv="$(awk -v j="${j}" -v w="${w}" -v c="${crit}" 'BEGIN{
		r = (w + 0) / (j + 0);
		printf "%s %.2f\n", (r <= c + 0 ? "met" : "NOT-MET"), r
	}')"
	read -r cverdict cratio <<<"${cv}"
	echo "  PLAT18-DEV-CRITERION ${cverdict} ratio=${cratio} threshold=${crit}" \
		"js_median_ms=${j} wasm_median_ms=${w} native_median_ms=${n}" \
		'— Uniform-WASM-Core.md §5, "the developer loop does not get' \
		'materially slower"; REPORTED, not gated'
fi

echo
if [ "${failures}" -ne 0 ]; then
	echo "plat18-dev-loop: ${failures} failure(s)"
	exit 1
fi
echo "plat18-dev-loop: all contracts hold"
exit 0
