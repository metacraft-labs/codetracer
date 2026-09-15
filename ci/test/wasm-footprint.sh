#!/usr/bin/env bash
#
# wasm-footprint.sh — PLAT-17 deliverable 2, taken as a measurement rather
# than written down as one.
#
# Builds src/frontend/viewmodel/tests/manual/wasm_footprint_probe.nim twice --
# native `nim c --mm:orc`, and wasm32 through emcc with the same `--mm:orc` --
# runs both, and prints the two columns side by side.
#
# WHAT IT GRADES, AND WHAT IT DELIBERATELY DOES NOT
# -------------------------------------------------
# It grades exactly two things, and both are PROPERTIES rather than numbers:
#
#   1. the probe's own verdict on each target: after every session is released
#      and `GC_fullCollect()` has run, live bytes must be BELOW the peak. On a
#      graph that is cyclic by construction -- parent holding children holding
#      a parent -- that is a statement about ORC's cycle collector actually
#      running under a linear-memory target, which is the half of "`--mm:orc`
#      under a linear memory target" that a build succeeding does not
#      establish.
#
#      NARROWED TWICE BY FALSIFICATION, 2026-09-15, and the second time
#      mattered. It used to say "after every session is DISPOSED": an arm that
#      deleted the `dispose()` call left this green, because ORC reclaims on
#      the dropped reference alone. Reaimed at retention, the arm SURVIVED
#      AGAIN — the probe asserted `steady < peak`, and a run that kept every
#      session still satisfied it by 4%, because the full collection frees the
#      transient garbage of eight constructions either way. The assertion is a
#      FRACTION now (steady must be at most 25% of peak, measured at 0.01%
#      released and 95.6% retained) and the arm kills it;
#   2. that both targets produced a full set of rows. A missing row is an
#      absent measurement, and an absent measurement read as a zero is how a
#      footprint gets quoted for a column nobody took.
#
# It does NOT assert a byte bound. Verification-Harness-Traps.md §12a: an
# absolute bound on a single measurement is a coin flip with one side hidden,
# and a footprint that varies with the Nim version, the emscripten version and
# the allocator's page size would either be set so loose it grades nothing or
# so tight it fails on the next toolchain bump. The numbers are for a reader
# and for the milestone's status note, where they are quoted WITH the build
# that produced them.
#
# Run:  bash ci/test/wasm-footprint.sh   |   just test-wasm-footprint
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}" || exit 2

PROBE="src/frontend/viewmodel/tests/manual/wasm_footprint_probe.nim"
SESSIONS="${CT_FOOTPRINT_SESSIONS:-8}"

out_dir="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/plat17-footprint"
mkdir -p "${out_dir}"

failures=0
fail() {
	echo "  FAIL: $*" >&2
	failures=$((failures + 1))
}

if ! command -v emcc >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
	# A hard failure, not a skip, for the reason recorded at the same check in
	# ci/lib/run-nim-test-lane.sh: a measurement that silently does not happen
	# is indistinguishable from one that happened and agreed.
	echo "ERROR: wasm-footprint.sh needs emcc and node (this repo's dev shell)." >&2
	exit 1
fi

echo "=== PLAT-17: ViewModel-core footprint, --mm:orc, ${SESSIONS} concurrent sessions, no UI ==="
echo

echo "--- building native (nim c --mm:orc)"
if ! nim c --mm:orc --hints:off --warnings:off \
	--path:src/frontend/viewmodel \
	--nimcache:"${out_dir}/native" -o:"${out_dir}/footprint-native" "${PROBE}" \
	>"${out_dir}/native-build.log" 2>&1; then
	fail "native build failed; see ${out_dir}/native-build.log"
	tail -20 "${out_dir}/native-build.log" >&2
fi

echo "--- building wasm32 (nim c --cpu:wasm32 -d:emscripten --mm:orc, emcc as cc+ld)"
if ! nim c --hints:off --warnings:off \
	--cpu:wasm32 --os:linux -d:emscripten \
	--cc:clang --clang.exe:emcc --clang.linkerexe:emcc \
	--mm:orc --threads:off \
	--passL:-sSTACK_SIZE=8388608 \
	--passL:-sNODERAWFS=1 \
	--passL:-sALLOW_MEMORY_GROWTH=1 \
	--passL:-sEXIT_RUNTIME=1 \
	--path:src/frontend/viewmodel \
	--nimcache:"${out_dir}/wasm" -o:"${out_dir}/footprint-wasm.js" "${PROBE}" \
	>"${out_dir}/wasm-build.log" 2>&1; then
	fail "wasm build failed; see ${out_dir}/wasm-build.log"
	tail -20 "${out_dir}/wasm-build.log" >&2
fi

if [ "${failures}" -ne 0 ]; then
	echo
	echo "wasm-footprint: ${failures} failure(s)" >&2
	exit 1
fi

echo
echo "--- running"
native_out="$(LD_LIBRARY_PATH="${CT_LD_LIBRARY_PATH:-}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	"${out_dir}/footprint-native" "${SESSIONS}" 2>&1)" && native_rc=0 || native_rc=$?
wasm_out="$(node "${out_dir}/footprint-wasm.js" "${SESSIONS}" 2>&1)" && wasm_rc=0 || wasm_rc=$?

printf '%s\n' "${native_out}" >"${out_dir}/native.out"
printf '%s\n' "${wasm_out}" >"${out_dir}/wasm.out"

field() { # field OUTPUT ROW -> the human-readable column, or the empty string
	# Column 3 is the human-readable rendering for every row except
	# FOOTPRINT-BUILD, whose whole point is that it carries SEVERAL fields --
	# target, memory manager, release, danger, session count. Truncating that
	# to one would print `mm=orc` under a heading that says `BUILD`, which is
	# the §12b failure (a number quoted without its build) committed by the
	# very row that exists to prevent it.
	printf '%s\n' "$1" | awk -F'\t' -v k="$2" '
		$1 == k {
			if (k == "FOOTPRINT-BUILD") {
				out = $2
				for (i = 3; i <= NF; i++) out = out " " $i
				print out
			} else {
				print $3
			}
			found = 1
		}
		END { if (!found) exit 0 }'
}

# `wasm_artifact_bytes` is the shipped size of the module this measures, which
# is §4 row 6 and is free to take here.
wasm_bytes="$(wc -c <"${out_dir}/footprint-wasm.wasm" 2>/dev/null || echo 0)"

echo
printf '  %-32s %-38s %-38s\n' "" "native (nim c)" "wasm32 (emcc + node)"
printf '  %-32s %-38s %-38s\n' "--------------------------------" \
	"--------------------------------------" "--------------------------------------"
for row in \
	FOOTPRINT-BUILD \
	FOOTPRINT-BASELINE-OCCUPIED \
	FOOTPRINT-BASELINE-TOTAL \
	FOOTPRINT-PEAK-DELTA \
	FOOTPRINT-STEADY-DELTA \
	FOOTPRINT-PER-SESSION-PEAK \
	FOOTPRINT-PEAK-TOTAL-DELTA \
	FOOTPRINT-STEADY-TOTAL-DELTA \
	FOOTPRINT-STEADY-PERCENT-OF-PEAK \
	FOOTPRINT-LINEAR-BASELINE \
	FOOTPRINT-LINEAR-PEAK \
	FOOTPRINT-LINEAR-STEADY \
	FOOTPRINT-VERDICT; do
	n="$(field "${native_out}" "${row}")"
	w="$(field "${wasm_out}" "${row}")"
	printf '  %-32s %-38s %-38s\n' "${row#FOOTPRINT-}" "${n:-<missing>}" "${w:-<missing>}"
	# Contract 2: a row present on one target and absent on the other is an
	# absent measurement. It is checked per row rather than by counting lines,
	# so the failure names WHICH number is missing.
	if [ -z "${n}" ]; then fail "native produced no ${row}"; fi
	if [ -z "${w}" ]; then fail "wasm produced no ${row}"; fi
done
printf '  %-32s %-38s %-38s\n' "ARTIFACT-BYTES" "n/a" "${wasm_bytes}"

echo
# Contract 1: each probe's own verdict.
if [ "${native_rc}" -ne 0 ]; then
	fail "the native probe exited ${native_rc} — it reclaimed almost nothing, or built nothing"
	printf '%s\n' "${native_out}" | sed 's/^/      /' >&2
fi
if [ "${wasm_rc}" -ne 0 ]; then
	fail "the wasm probe exited ${wasm_rc} — it reclaimed almost nothing, or built nothing"
	printf '%s\n' "${wasm_out}" | sed 's/^/      /' >&2
fi

# And the negative control on contract 1: a verdict of OK has to come from the
# probe having actually MEASURED something. A run where the peak delta is zero
# would satisfy "steady below peak" only by accident of sign, and would mean
# eight sessions allocated nothing — which is not a footprint, it is a probe
# that did not build the graph.
for target in native wasm; do
	# Selected with a `case` rather than `eval "peak=\$${target}_out"`: the
	# eval form made shellcheck report `peak is referenced but not assigned`,
	# and a variable a static checker cannot see assigned is one a reader
	# cannot see assigned either.
	case "${target}" in
	native) peak="$(field "${native_out}" FOOTPRINT-PEAK-DELTA)" ;;
	wasm) peak="$(field "${wasm_out}" FOOTPRINT-PEAK-DELTA)" ;;
	*) peak="" ;;
	esac
	case "${peak}" in
	"0.0 KiB" | "" | "-"*)
		fail "${target}: peak delta is '${peak}' — eight sessions allocated nothing," \
			"so the verdict below it grades no measurement"
		;;
	esac
done

if [ "${failures}" -eq 0 ]; then
	echo "wasm-footprint: OK — both targets measured, both reclaimed their graph"
	exit 0
fi
echo "wasm-footprint: ${failures} failure(s)" >&2
exit 1
