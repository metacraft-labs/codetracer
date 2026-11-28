#!/usr/bin/env bash
#
# plat18-fake-timer-builds.sh — PLAT-18's rejection criterion, re-measured
# under the builds PLAT-18 actually evaluates.
#
# ## WHY THIS EXISTS BESIDE `wasm-fake-timer-speed.sh` RATHER THAN INSIDE IT
#
# Uniform-WASM-Core.md §5 lists, among the things that make the answer "no":
#
#     A fake-timer suite runs materially slower under WASM than natively.
#     Natural async testable at full speed is worth more than a uniform
#     artifact (§3A.4).
#
# PLAT-17 measured that signal and got **native 47.337 ms, wasm 84.000 ms for
# 1,000,000 simulated ms — 1.77×**, with both four orders of magnitude above a
# host loop. Its own bound 5 says every figure it published is a DEBUG build.
# Verification-Harness-Traps.md §12b says a timing quotes its build, and that
# a DEBUG figure compared against a release one is not a comparison — so
# inheriting 1.77× into an adoption decision about a shipped product would be
# quoting a number taken under a build the product does not use.
#
# This script therefore runs PLAT-17's OWN probe — unchanged, not a copy — at
# BOTH optimisation levels and prints the four numbers. It is a separate file
# rather than a flag on `wasm-fake-timer-speed.sh` because that script is one
# of the six entries in `run-plat17-wasm-mutations.py`'s `TOUCHED`: editing it
# invalidates eighteen recorded control digests and obliges a re-run of every
# arm graded against it (§16). A second consumer of the same probe costs
# nothing and leaves PLAT-17's harness able to grade the tree it recorded.
#
# ## WHAT IT ASSERTS
#
#   1. every run completed all its continuations — a ratio over a chain that
#      did not run is a ratio of nothing, and the probe already refuses to
#      print one, so this is the second reading of the same guard;
#   2. every run's simulated/wall ratio is above `CT_P18_MIN_RATIO` (default
#      1000), which is the MECHANISM threshold: a chain that reached a host
#      timer scores about 1 and one that did not scores four or five orders of
#      magnitude more, with nothing in between;
#   3. the wasm/native CPU-time ratio is taken over `CT_P18_PAIRS` (default 9)
#      back-to-back native/wasm pairs per build, and the MEDIAN per-pair
#      ratio is compared against `CT_P18_MAX_SLOWDOWN` (default 3.0). The threshold is the
#      "materially slower" in §5 made a number, and it is deliberately loose:
#      the criterion is about losing a testing PROPERTY, not about a constant
#      factor, and a tight bound here would be the coin flip §12a describes on
#      a host this campaign has measured at load 60 on 24 CPUs.
#
# ## CONTRACT 3 IS DECIDED ON CPU TIME
#
# Each side's run is timed with bash's `time` on its subshell: user+sys of the
# native process, and of node with its GC and compiler threads. Wall time is
# still printed beside it. Pairing and medians were not enough on a shared
# host: on 2026-11-19 ten wall-time pairs of one unchanged build, at load
# 115-134, read release ratios from 0.37 to 8.67, and on 2026-11-28 a
# behaviour-preserving edit of this script read 5.49x release at load ~100 and
# failed the 3.0 limit. The scheduler decided those numbers.
#
# A run's CPU time also counts its fixed costs — node's boot, the wasm
# module's compile, the JIT's warm-up — so each side is timed at N and at 2N
# iterations in the same pair and the chain's cost is cpu(2N) - cpu(N); the
# first version of this contract timed one run, and its release ratio read
# 1.87x at the default 300,000 iterations and 3.28x at the 100,000 the
# mutation harness uses, on one build. Two-point CPU ratios on one tree
# (bd2bfbdc7b0 plus this change), 2026-11-28, median of 9 pairs:
#
#   | condition                           | N       | load | debug  | release |
#   |-------------------------------------+---------+------+--------+---------|
#   | 6 cores                             | 300,000 |   79 | 1.61x  | 1.35x   |
#   | 6 cores                             | 100,000 |   67 | 1.57x  | 1.50x   |
#   | 2 cores, nice 19                    | 100,000 |   64 | 1.42x  | 1.55x   |
#   | REGRESSION: SAFE_HEAP=1 and         | 100,000 |   46 | 17.11x | 8.73x   |
#   |   ASSERTIONS=2 on the wasm link     |         |      |        |         |
#
# The limit stays 3.0x: nearly twice the highest healthy reading and far
# below the regression, which also reddens contract 2 (debug/wasm scored 618
# against the floor of 1000). The healthy figures agree with the wall-time
# ones published for this criterion (1.42x-1.96x), so the decision they
# support is unchanged.
#
# Exit 0 if every contract holds, 1 if any fails, 2 if a tool is missing —
# a failure and never a skip.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

PROBE="src/frontend/viewmodel/tests/manual/wasm_fake_timer_probe.nim"
# 300,000 AND NOT PLAT-17's 20,000, AND THE REASON IS A COIN FLIP THIS SCRIPT
# NEARLY PUBLISHED.
#
# `epochTime()` under emscripten/node has MILLISECOND granularity — PLAT-17
# records that and notes its own wasm column reads `84.000` exactly. At 20,000
# iterations the RELEASE arms are fast enough for the quantum to dominate:
# measured on this host, native 7.372 ms against wasm `22.000` ms gives 2.98x,
# where the true value of the wasm side is anywhere in [21.5, 22.5] and the
# ratio anywhere in [2.92, 3.05]. The threshold below is 3.0. A correct build
# would therefore have failed this script about as often as it passed, which
# is Verification-Harness-Traps.md §12a arriving through a clock's resolution
# rather than through a scheduler.
#
# At 300,000 iterations (15,000,000 simulated ms) the same pair reads 60.790
# and 119.000 — 1.96x, with the quantum worth 0.008x. Contract 0 below makes
# the floor a CHECK rather than a chosen constant, so a faster host that puts
# the wall time back under it reddens instead of reporting a ratio of a
# rounding error.
ITERATIONS="${CT_FAKE_TIMER_ITERATIONS:-300000}"
MIN_WALL_MS="${CT_P18_MIN_WALL_MS:-50}"
MIN_RATIO="${CT_P18_MIN_RATIO:-1000}"
MAX_SLOWDOWN="${CT_P18_MAX_SLOWDOWN:-3.0}"
PAIRS="${CT_P18_PAIRS:-9}"
out_dir="${CT_P18_FT_OUT:-${repo_root}/test-logs/plat18-fake-timer}"

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

rm -rf "${out_dir}"
mkdir -p "${out_dir}"

echo "=== PLAT-18: the fake-timer signal, DEBUG and RELEASE, --mm:orc ==="
echo "    probe=${PROBE} iterations=${ITERATIONS} pairs=${PAIRS}"
echo "    host: cpus=$(nproc 2>/dev/null || echo '?') load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo '?')"
echo

row() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k {print $2}'; }

# `native_wall`, `wasm_wall`, … are filled per build below and read by the
# comparison. Declared here so a build that failed leaves them empty rather
# than leaving the previous build's values in place — a comparison across two
# builds is exactly where a stale variable would read as a result.
#
# EVERY READ OF THESE THREE HOISTS ITS KEY INTO A PLAIN VARIABLE FIRST, AND
# THAT IS LOAD-BEARING RATHER THAN STYLE. This repo's pre-commit `shfmt` runs
# with `-s` (simplify), which rewrites a compound subscript
# `${wall_of[${label}-${target}]}` into `${wall_of[label - target]}`: correct
# for an INDEXED array, where the subscript is an arithmetic context in which
# a bare word is a variable reference and `-` is subtraction, and silently
# destructive here, where `declare -A` makes the subscript a STRING KEY and
# the rewrite asks for the literal key `label - target`. Measured: the
# original form reads `652.752`, the `-s` form reads nothing, and the key
# present is `debug-native`. The consequence was not a wrong number but a
# script that printed `<missing>` in all twelve cells, read `0 ms` for every
# arm, and SKIPPED contracts 2 and 3 — the mechanism check and §5's rejection
# criterion — while exiting non-zero for a reason with nothing to do with the
# measurement. Hoisting the key makes `shfmt -s` a no-op on this file, which
# is the only form of the fix that survives the hook.
# See Verification-Harness-Traps.md §16e.
declare -A wall_of done_of ratio_of slowdown_of

run_build() {
	local label="$1"
	shift
	local -a extra=("$@")

	if ! nim c --mm:orc --hints:off --warnings:off "${extra[@]}" \
		--path:src/frontend/viewmodel \
		--nimcache:"${out_dir}/native-${label}" \
		-o:"${out_dir}/ft-native-${label}" "${PROBE}" \
		>"${out_dir}/native-${label}-build.log" 2>&1; then
		fail "${label}: native build failed"
		tail -20 "${out_dir}/native-${label}-build.log" >&2
		return
	fi

	if ! nim c --hints:off --warnings:off "${extra[@]}" \
		--cpu:wasm32 --os:linux -d:emscripten \
		--cc:clang --clang.exe:emcc --clang.linkerexe:emcc \
		--mm:orc --threads:off \
		--passL:-sSTACK_SIZE=8388608 \
		--passL:-sNODERAWFS=1 \
		--passL:-sALLOW_MEMORY_GROWTH=1 \
		--passL:-sEXIT_RUNTIME=1 \
		--path:src/frontend/viewmodel \
		--nimcache:"${out_dir}/wasm-${label}" \
		-o:"${out_dir}/ft-wasm-${label}.js" "${PROBE}" \
		>"${out_dir}/wasm-${label}-build.log" 2>&1; then
		fail "${label}: wasm build failed"
		tail -20 "${out_dir}/wasm-${label}-build.log" >&2
		return
	fi

	# PAIRS, INTERLEAVED, AND THE VERDICT IS THE MEDIAN OF THE PER-PAIR RATIOS.
	#
	# One native run followed by one wasm run is a ratio of two samples of
	# whatever else the host was doing at the time. Measured 2026-11-19 on the
	# 24-CPU workstation at load 115-134, ten such pairs of this very build
	# read release ratios from 0.37 to 8.67 — the slower side was decided by the
	# scheduler, not by the target, and an unchanged tree failed the 3.0 limit
	# in four rounds out of ten. Each pair runs its two sides back to back, so
	# the load they see is close to the same; the median over the pairs then
	# discards the pairs where it was not. Contracts 0 and 1 read the WORST run
	# of each side, so a single short or unfinished run still reddens them;
	# contract 2 reads each side's median simulated/wall ratio, because a load
	# spike can stretch one run's wall time past the threshold while the chain
	# never left the runtime (measured 2026-11-19 at load ~130: with the worst
	# run kept, an unchanged chain failed this contract on debug/native).
	local n_out w_out pair nw ww pr
	local -a pair_ratios=() n_ratios=() w_ratios=()
	local nkey="${label}-native" wkey="${label}-wasm"
	for ((pair = 1; pair <= PAIRS; pair++)); do
		# EACH SIDE'S CPU TIME, BESIDE ITS OWN WALL CLOCK: bash's `time` on
		# the run's subshell reports user+sys of the process and its threads
		# (node's GC and compiler threads included), which a busy scheduler
		# does not stretch the way it stretches wall time. Contract 3 is
		# decided on these; see "CONTRACT 3 IS DECIDED ON CPU TIME" below.
		TIMEFORMAT='%3U %3S'
		{ time ("${out_dir}/ft-native-${label}" "${ITERATIONS}" >"${out_dir}/native-${label}-${pair}.out" 2>&1); } 2>"${out_dir}/native-${label}-${pair}.cpu"
		{ time (node "${out_dir}/ft-wasm-${label}.js" "${ITERATIONS}" >"${out_dir}/wasm-${label}-${pair}.out" 2>&1); } 2>"${out_dir}/wasm-${label}-${pair}.cpu"
		n_out="$(cat "${out_dir}/native-${label}-${pair}.out")"
		w_out="$(cat "${out_dir}/wasm-${label}-${pair}.out")"
		nw="$(row "${n_out}" FAKETIMER-WALL-MS)"
		ww="$(row "${w_out}" FAKETIMER-WALL-MS)"
		# TWO POINTS, AND THE RATIO IS OF THEIR DIFFERENCE. CPU time counts
		# every fixed cost of a run — node's boot, the wasm module's compile,
		# the JIT's warm-up, the native binary's load — which the wall time
		# read inside the probe never did. Subtracting a one-iteration run took
		# out the start but not the warm-up, and the release ratio still moved
		# with the iteration count (2.49x at 100,000 against 1.94x at 300,000 on
		# one build). So each side also runs 2N iterations in the same pair and
		# the chain's cost is cpu(2N) - cpu(N): N more iterations and nothing
		# else, which cancels every fixed cost whatever N the caller chose.
		{ time ("${out_dir}/ft-native-${label}" "$((2 * ITERATIONS))" >/dev/null 2>&1); } 2>"${out_dir}/native-${label}-${pair}.cpu2"
		{ time (node "${out_dir}/ft-wasm-${label}.js" "$((2 * ITERATIONS))" >/dev/null 2>&1); } 2>"${out_dir}/wasm-${label}-${pair}.cpu2"
		nc="$(awk 'FNR == 1 && NR == 1 {t = -($1 + $2) * 1000} FNR == 1 && NR > 1 {t += ($1 + $2) * 1000} END {printf "%d", t}' \
			"${out_dir}/native-${label}-${pair}.cpu" "${out_dir}/native-${label}-${pair}.cpu2")"
		wc="$(awk 'FNR == 1 && NR == 1 {t = -($1 + $2) * 1000} FNR == 1 && NR > 1 {t += ($1 + $2) * 1000} END {printf "%d", t}' \
			"${out_dir}/wasm-${label}-${pair}.cpu" "${out_dir}/wasm-${label}-${pair}.cpu2")"
		min_into wall_of "${nkey}" "${nw:-0}"
		min_into wall_of "${wkey}" "${ww:-0}"
		n_ratios+=("$(row "${n_out}" FAKETIMER-RATIO)")
		w_ratios+=("$(row "${w_out}" FAKETIMER-RATIO)")
		min_into done_of "${nkey}" "$(row "${n_out}" FAKETIMER-COMPLETED | awk '{print $1}')"
		min_into done_of "${wkey}" "$(row "${w_out}" FAKETIMER-COMPLETED | awk '{print $1}')"
		pr="$(awk -v n="${nc:-0}" -v w="${wc:-0}" 'BEGIN{ if (n + 0 > 0) printf "%.4f", (w + 0) / (n + 0) }')"
		[ -n "${pr}" ] && pair_ratios+=("${pr}")
		echo "    ${label} pair ${pair}/${PAIRS}: cpu native=${nc:-?} ms wasm=${wc:-?} ms ratio=${pr:-?}; wall native=${nw:-?} ms wasm=${ww:-?} ms"
	done
	ratio_of["${nkey}"]="$(median "${n_ratios[@]}")"
	ratio_of["${wkey}"]="$(median "${w_ratios[@]}")"
	if [ "${#pair_ratios[@]}" -eq "${PAIRS}" ]; then
		slowdown_of["${label}"]="$(median "${pair_ratios[@]}")"
	fi
}

# The median of the numbers given, or nothing when none is; an empty
# argument counts as 0, so a run that printed no figure pulls it down.
median() {
	[ "$#" -gt 0 ] || return 0
	printf '%s\n' "$@" | awk '{print ($1 == "" ? 0 : $1)}' | sort -g |
		awk '{v[NR] = $1} END{ if (NR) printf "%.2f", (NR % 2 ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2) }'
}

# Keeps the SMALLER of the stored and the offered value under `key`, and
# treats an empty offer as 0 so a run that printed nothing wins. Contracts 0
# and 1 are lower bounds, so the worst run is the one to keep.
min_into() {
	local -n arr="$1"
	local key="$2" v="${3:-0}" cur
	cur="${arr[$key]-}"
	if [ -z "${cur}" ] || awk -v a="${v}" -v b="${cur}" 'BEGIN{exit !(a+0 < b+0)}'; then
		arr["${key}"]="${v}"
	fi
}

run_build debug
run_build release -d:release

echo
printf '  %-10s %-12s %-14s %-14s %-14s\n' build target "wall ms" "sim/wall" completed
for label in debug release; do
	for target in native wasm; do
		key="${label}-${target}"
		printf '  %-10s %-12s %-14s %-14s %-14s\n' "${label}" "${target}" \
			"${wall_of[$key]:-<missing>}" \
			"${ratio_of[$key]:-<missing>}" \
			"${done_of[$key]:-<missing>}"
	done
done
echo

# --- contract 0: the clock can resolve what is being measured ---------------
#
# BEFORE any ratio, because a ratio taken over a duration the clock quantises
# is a measurement of the clock. The wasm arm's `epochTime()` ticks in whole
# milliseconds, so a wall time of `w` ms carries a relative uncertainty of
# 0.5/w — at the floor below that is 1%, and at PLAT-17's 20,000-iteration
# release timing it was 2.3%, against a threshold the measurement sat exactly
# on.
resolution_ok=1
for label in debug release; do
	for target in native wasm; do
		key="${label}-${target}"
		w="${wall_of[$key]:-0}"
		if ! awk -v w="${w}" -v m="${MIN_WALL_MS}" 'BEGIN{exit !(w+0 >= m+0)}'; then
			fail "${label}/${target} wall time is ${w} ms, under the ${MIN_WALL_MS} ms floor" \
				"— raise CT_FAKE_TIMER_ITERATIONS; a 1 ms clock quantum is worth" \
				"$(awk -v w="${w}" 'BEGIN{printf "%.1f%%", (w+0>0 ? 50.0/(w+0) : 100)}')" \
				"of this number"
			resolution_ok=0
		fi
	done
done
if [ "${resolution_ok}" -eq 1 ]; then
	ok "every wall time is at least ${MIN_WALL_MS} ms, so a 1 ms clock quantum is" \
		"worth at most 1% of any ratio below"
fi

# --- contract 1: every run finished the work it timed -----------------------
#
# FIRST, and the two contracts below are GATED on it rather than merely
# preceded by it — the repair PLAT-17's own script needed on 2026-09-15, for
# the reason recorded there: ordering only orders, so a run that recorded this
# failure went on to print an `ok:` line about a ratio it had no right to.
work_done=1
for label in debug release; do
	for target in native wasm; do
		key="${label}-${target}"
		if [ "${done_of[$key]:-0}" != "${ITERATIONS}" ]; then
			fail "${label}/${target} completed ${done_of[$key]:-0} of ${ITERATIONS} continuations"
			work_done=0
		fi
	done
done
if [ "${work_done}" -eq 1 ]; then
	ok "every run completed ${ITERATIONS} continuations"
fi

# --- contract 2: the MECHANISM, per run -------------------------------------
if [ "${work_done}" -eq 0 ] || [ "${resolution_ok}" -eq 0 ]; then
	echo "  skipped: the mechanism ratios — contract 1 says the timed work did not" \
		"complete, so there is nothing to take a ratio of"
else
	for label in debug release; do
		for target in native wasm; do
			key="${label}-${target}"
			r="${ratio_of[$key]:-0}"
			if awk -v r="${r}" -v m="${MIN_RATIO}" 'BEGIN{exit !(r+0 >= m+0)}'; then
				ok "${label}/${target} scores ${r} simulated ms per wall ms (>= ${MIN_RATIO})"
			else
				fail "${label}/${target} scores ${r}, below ${MIN_RATIO} — the chain is" \
					"deferring to a host loop"
			fi
		done
	done
fi

# --- contract 3: §5's rejection criterion, per build ------------------------
if [ "${work_done}" -eq 0 ] || [ "${resolution_ok}" -eq 0 ]; then
	echo "  skipped: the wasm/native slowdown — contract 1 says the timed work did" \
		"not complete, or contract 0 says the clock cannot resolve it"
else
	for label in debug release; do
		med="${slowdown_of[$label]:-}"
		verdict="$(awk -v r="${med}" -v lim="${MAX_SLOWDOWN}" 'BEGIN{
			if (r == "") { print "NOWALL 0"; exit }
			printf "%s %.2f\n", (r + 0 <= lim + 0 ? "OK" : "SLOW"), r
		}')"
		read -r kind ratio <<<"${verdict}"
		case "${kind}" in
		OK) ok "${label}: wasm is ${ratio}x native's CPU time, median of ${PAIRS} pairs (limit ${MAX_SLOWDOWN}x)" ;;
		SLOW) fail "${label}: wasm is ${ratio}x native's CPU time, above ${MAX_SLOWDOWN}x — §5's rejection criterion" ;;
		*) fail "${label}: no pair produced a native CPU time to divide by; raise CT_FAKE_TIMER_ITERATIONS" ;;
		esac
	done
fi

echo
if [ "${failures}" -ne 0 ]; then
	echo "plat18-fake-timer-builds: ${failures} failure(s)"
	exit 1
fi
echo "plat18-fake-timer-builds: all contracts hold"
exit 0
