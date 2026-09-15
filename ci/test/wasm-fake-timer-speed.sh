#!/usr/bin/env bash
#
# wasm-fake-timer-speed.sh — PLAT-17's fourth verification signal, taken on
# both backends and compared.
#
# `Uniform-WASM-Core.md` §2.1.4: "A fake-timer suite runs at native speed,
# which is the signal that the clock and the dispatcher are genuinely inside
# WASM rather than deferring to a host loop."
#
# Builds src/frontend/viewmodel/tests/manual/wasm_fake_timer_probe.nim native
# and wasm32, runs both, and grades THREE things:
#
#   1. each probe's own verdict — every continuation arrived, and the
#      simulated/wall ratio is above the mechanism threshold the probe
#      documents. That is the "inside one runtime" claim, and it is taken
#      independently on each target so a green wasm column cannot be produced
#      by a native column carrying it;
#   2. the wasm wall time is within `MAX_SLOWDOWN` of native's. This is the
#      "at native speed" half, and it is a RATIO between two measurements of
#      the same work rather than an absolute bound on one
#      (Verification-Harness-Traps.md §12a);
#   3. both probes report a non-zero completion count, so neither ratio is
#      being computed over a chain that did not run. Contract 3 is checked
#      before contract 2 and — this is the part ordering does not give you —
#      it GATES contract 2: an incomplete chain makes contract 2 print
#      `skipped:` rather than an `ok:` line about a ratio it had no right to
#      take. Ordering only orders.
#
# WHY `MAX_SLOWDOWN` IS LOOSE, AND WHY THAT IS NOT A WEAKNESS
# -----------------------------------------------------------
# §12 is explicit that an inequality between two independently noisy
# measurements asserted against a tight constant is a coin flip. The two
# numbers here are wall-clock timings on a shared, loaded developer machine,
# and the run is short. A 1.5x threshold would be a flake generator.
#
# What the check is actually for is the FAILURE it would catch, and that
# failure is not subtle: if the WASM arm of `drainPlatformCallbacks` ever
# reaches a host timer — a `setTimeout`, an `epoll_wait` with a computed
# deadline — the wasm column does not go 1.5x slower, it goes to the
# SIMULATED duration, which is 1,000,000 ms against native's tens of
# milliseconds. Four orders of magnitude. A threshold anywhere between the two
# grades that, and the loose one does not flake.
#
# Run:  bash ci/test/wasm-fake-timer-speed.sh  |  just test-wasm-fake-timer
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}" || exit 2

PROBE="src/frontend/viewmodel/tests/manual/wasm_fake_timer_probe.nim"
ITERATIONS="${CT_FAKE_TIMER_ITERATIONS:-20000}"
MAX_SLOWDOWN="${CT_FAKE_TIMER_MAX_SLOWDOWN:-20}"

out_dir="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/plat17-faketimer"
mkdir -p "${out_dir}"

failures=0
fail() {
	echo "  FAIL: $*" >&2
	failures=$((failures + 1))
}

ok() {
	echo "  ok: $*"
}

if ! command -v emcc >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
	echo "ERROR: wasm-fake-timer-speed.sh needs emcc and node (this repo's dev shell)." >&2
	exit 1
fi

echo "=== PLAT-17: fake-timer speed, native vs wasm32, --mm:orc, ${ITERATIONS} iterations ==="
echo

if ! nim c --mm:orc --hints:off --warnings:off \
	--path:src/frontend/viewmodel \
	--nimcache:"${out_dir}/native" -o:"${out_dir}/faketimer-native" "${PROBE}" \
	>"${out_dir}/native-build.log" 2>&1; then
	fail "native build failed"
	tail -20 "${out_dir}/native-build.log" >&2
fi

if ! nim c --hints:off --warnings:off \
	--cpu:wasm32 --os:linux -d:emscripten \
	--cc:clang --clang.exe:emcc --clang.linkerexe:emcc \
	--mm:orc --threads:off \
	--passL:-sSTACK_SIZE=8388608 \
	--passL:-sNODERAWFS=1 \
	--passL:-sALLOW_MEMORY_GROWTH=1 \
	--passL:-sEXIT_RUNTIME=1 \
	--path:src/frontend/viewmodel \
	--nimcache:"${out_dir}/wasm" -o:"${out_dir}/faketimer-wasm.js" "${PROBE}" \
	>"${out_dir}/wasm-build.log" 2>&1; then
	fail "wasm build failed"
	tail -20 "${out_dir}/wasm-build.log" >&2
fi

if [ "${failures}" -ne 0 ]; then
	echo "wasm-fake-timer-speed: ${failures} failure(s)" >&2
	exit 1
fi

native_out="$(LD_LIBRARY_PATH="${CT_LD_LIBRARY_PATH:-}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	"${out_dir}/faketimer-native" "${ITERATIONS}" 2>&1)" && native_rc=0 || native_rc=$?
wasm_out="$(node "${out_dir}/faketimer-wasm.js" "${ITERATIONS}" 2>&1)" && wasm_rc=0 || wasm_rc=$?

printf '%s\n' "${native_out}" >"${out_dir}/native.out"
printf '%s\n' "${wasm_out}" >"${out_dir}/wasm.out"

row() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k { print $2; exit }'; }

n_wall="$(row "${native_out}" FAKETIMER-WALL-MS)"
w_wall="$(row "${wasm_out}" FAKETIMER-WALL-MS)"
n_done="$(row "${native_out}" FAKETIMER-COMPLETED)"
w_done="$(row "${wasm_out}" FAKETIMER-COMPLETED)"
n_ratio="$(row "${native_out}" FAKETIMER-RATIO)"
w_ratio="$(row "${wasm_out}" FAKETIMER-RATIO)"
sim="$(row "${native_out}" FAKETIMER-SIMULATED-MS)"

printf '  %-28s %-22s %-22s\n' "" "native (nim c)" "wasm32 (emcc + node)"
printf '  %-28s %-22s %-22s\n' "----------------------------" \
	"----------------------" "----------------------"
printf '  %-28s %-22s %-22s\n' "build" \
	"$(row "${native_out}" FAKETIMER-BUILD)" "$(row "${wasm_out}" FAKETIMER-BUILD)"
printf '  %-28s %-22s %-22s\n' "simulated ms" "${sim:-<missing>}" \
	"$(row "${wasm_out}" FAKETIMER-SIMULATED-MS)"
printf '  %-28s %-22s %-22s\n' "wall ms" "${n_wall:-<missing>}" "${w_wall:-<missing>}"
printf '  %-28s %-22s %-22s\n' "continuations" "${n_done:-<missing>}" "${w_done:-<missing>}"
printf '  %-28s %-22s %-22s\n' "sim ms per wall ms" "${n_ratio:-<missing>}" "${w_ratio:-<missing>}"
printf '  %-28s %-22s %-22s\n' "verdict" \
	"$(row "${native_out}" FAKETIMER-VERDICT)" "$(row "${wasm_out}" FAKETIMER-VERDICT)"
echo

# Contract 1 — each probe's own verdict.
[ "${native_rc}" -eq 0 ] || fail "the native probe exited ${native_rc}: $(printf '%s' "${native_out}" | tail -3)"
[ "${wasm_rc}" -eq 0 ] || fail "the wasm probe exited ${wasm_rc}: $(printf '%s' "${wasm_out}" | tail -3)"

# Contract 3 — neither ratio is over a chain that did not run. Checked BEFORE
# contract 2 uses the timings, because a wall time is not a measurement of
# anything if the work it timed did not happen.
#
# ORDERING ONLY ORDERS. Running this first does not stop contract 2 running
# afterwards, and contract 2's happy path PRINTS — so a run that reported
# `completed 0 of 20000` went on to print `ok: wasm is 1.98x native's wall
# time` two lines below it. The overall verdict was red, correctly, and the
# transcript still carried an `ok:` line asserting a ratio over a chain that
# never ran. A precondition has to GATE the dependent check, not merely
# precede it, so contract 3 records a named flag and contract 2 reads it.
timings_are_measurements=1
if [ "${n_done:-0}" != "${ITERATIONS}" ]; then
	fail "native completed ${n_done:-0} of ${ITERATIONS} continuations"
	timings_are_measurements=0
fi
if [ "${w_done:-0}" != "${ITERATIONS}" ]; then
	fail "wasm completed ${w_done:-0} of ${ITERATIONS} continuations"
	timings_are_measurements=0
fi
# A probe that exited non-zero is the same event one layer up: its wall time is
# the duration of a run that did not finish saying what it was measuring.
if [ "${native_rc}" -ne 0 ] || [ "${wasm_rc}" -ne 0 ]; then
	timings_are_measurements=0
fi

# Contract 2 — wasm within MAX_SLOWDOWN of native.
if [ "${timings_are_measurements}" -eq 0 ]; then
	echo "  skipped: the slowdown ratio — contract 1 or 3 already reported that" \
		"the timed work did not complete, so there is no ratio to take"
elif [ -z "${n_wall}" ] || [ -z "${w_wall}" ]; then
	fail "a wall time is missing (native='${n_wall}' wasm='${w_wall}')"
else
	verdict="$(awk -v n="${n_wall}" -v w="${w_wall}" -v m="${MAX_SLOWDOWN}" '
		BEGIN {
			# A native run fast enough to round to zero has no denominator.
			# Say so rather than dividing: an "infinite slowdown" verdict
			# would be a measurement failure wearing the costume of a
			# result.
			if (n <= 0) { printf "NODENOM %s\n", n; exit }
			r = w / n
			printf "%s %.2f\n", (r <= m ? "OK" : "SLOW"), r
		}')"
	# `read` rather than `set -- ${verdict}`: the latter needs the expansion
	# UNQUOTED to split, which shellcheck reports (SC2086) and which a reader
	# has to recognise as deliberate. Two named variables say what the two
	# fields are.
	read -r slow_kind slow_ratio <<<"${verdict}"
	case "${slow_kind}" in
	OK) ok "wasm is ${slow_ratio}x native's wall time (limit ${MAX_SLOWDOWN}x)" ;;
	SLOW) fail "wasm is ${slow_ratio}x native's wall time, above the ${MAX_SLOWDOWN}x limit" ;;
	*) fail "native wall time was ${n_wall} ms — too short to divide by; raise CT_FAKE_TIMER_ITERATIONS" ;;
	esac
fi

echo
if [ "${failures}" -eq 0 ]; then
	echo "wasm-fake-timer-speed: OK — the clock and the dispatcher are inside WASM"
	exit 0
fi
echo "wasm-fake-timer-speed: ${failures} failure(s)" >&2
exit 1
