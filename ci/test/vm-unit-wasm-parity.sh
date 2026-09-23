#!/usr/bin/env bash
#
# vm-unit-wasm-parity.sh — PLAT-17's verification gate, made mechanical.
#
# WHY THIS EXISTS, AND WHY IT IS NOT "BOTH LANES ARE GREEN"
# --------------------------------------------------------
# codetracer-specs/Architecture/Uniform-WASM-Core.md §2.1.4 states the
# criterion for a WASM build of the ViewModel core, and the load-bearing word
# is *same*:
#
#     The `vm-unit` suite passes under WASM with the same case count and the
#     same assertion count as native, not merely "green". Any suite that
#     cannot run under WASM is named, with the reason, and the reason is a
#     platform fact rather than an unexplained failure.
#
# Both halves need a program, because neither survives being a sentence in a
# status note:
#
#   * "Green" is satisfied by a lane that runs eleven files. `vm-unit-js` is
#     65 files against `vm-unit`'s 76 and is green; the eleven are documented,
#     but nothing in the tree ASSERTS that they are eleven rather than twelve.
#     A twelfth could join by a compile error nobody reads, and the lane would
#     still be green.
#   * A case count that shrinks is invisible to an inequality. If a suite's
#     cases stop running under one backend — a `when` that elides a block, a
#     fixture that is absent — the lane reports `OK (n tests)` with a smaller
#     n and passes. Only an EQUALITY against the other backend sees it.
#
# So this script runs both lanes and compares them file by file. It is slow
# (two full compiles of ~70 ViewModel suites) and that is the price of the
# claim; it is a gate, not a unit test.
#
# WHAT IS COMPARED, AND WHAT EACH NUMBER IS WORTH
# ----------------------------------------------
#   cases       `[OK]` lines. `std/unittest` prints one per test BLOCK that
#               did not fail, never one per `check`, so this counts case
#               markers and a block that asserts nothing prints one too. It
#               is compared anyway because a DIFFERENCE in it is decisive
#               even though a MATCH in it is weak.
#   assertions  the file's own declared count — a `CHECKS: <n>` line it
#               printed, or a `const ExpectedAssertions = <n>` it validated
#               against its own tally in a case of its own. This is the
#               number that means something, and it is the one §2.1.4 names.
#   failures    `[FAILED]` lines. Compared as an equality too, so a red that
#               exists on one backend and not the other is a divergence
#               rather than "both lanes were red anyway".
#
# The comparison is per FILE, not on the totals. Totals can agree while two
# files diverge in opposite directions, and a gate that can be satisfied by a
# coincidence is not a gate.
#
# THE SECOND CONTRACT: THE EXCLUSION LIST IS EXACTLY RIGHT
# --------------------------------------------------------
# `vm-unit-wasm` is `vm-unit` minus six named files. This script re-derives
# that difference from the two lanes and requires it to equal
# `EXPECTED_WASM_EXCLUSIONS` below, in both directions:
#
#   * a file in the difference and NOT in the list is a suite that left the
#     wasm lane without anyone writing down why — the exact shape the
#     milestone's risk section names;
#   * a file in the list and NOT in the difference means the list has outlived
#     its reason, which is how an exclusion becomes permanent by neglect.
#
# Run directly:  bash ci/test/vm-unit-wasm-parity.sh
# Or:            just test-vm-unit-wasm-parity
#
# Environment:
#   CT_NIM_CACHE_ROOT   nimcache root (default is the per-checkout directory
#                       ci/lib/run-nim-test-lane.sh computes, for the reason
#                       recorded there: two worktrees sharing one compiler
#                       cache have already produced a green lane that
#                       measured another tree's source).
#
#   CT_PARITY_ONLY      a `grep -E` pattern restricting contract 2 to the
#                       files it matches. For FALSIFYING this gate and for
#                       iterating on it — a full run is two compiles of ~70
#                       suites, and an arm that plants a divergence in one
#                       file should not cost that.
#
#                       IT CANNOT BE USED AS A MUTE BUTTON, and that is
#                       enforced rather than asked: a restricted run NEVER
#                       prints the PASS line and ALWAYS exits non-zero, even
#                       when every file it compared agreed. The exit code is
#                       2 — distinct from 1, which means a contract failed —
#                       so a caller can tell "you restricted this run" from
#                       "this tree diverges". An environment variable that
#                       can turn a red gate green is a defect in the gate;
#                       one that can only ever make it non-green is a tool.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}" || exit 2

# The six files `vm-unit` runs and `vm-unit-wasm` does not, each explained in
# full at its rejection in ci/lib/test-lane-files.sh. Kept here as a flat list
# so this script can compare against it without parsing that file's prose --
# and duplicated DELIBERATELY rather than derived, because a check that reads
# its expectation out of the thing it is checking asserts nothing (trap 14:
# one predicate, two call sites, is right for a PREDICATE; an expectation has
# to come from somewhere else or it is a self-comparison).
EXPECTED_WASM_EXCLUSIONS=(
	src/frontend/viewmodel/tests/unit/test_platform_desktop_native.nim
	src/frontend/viewmodel/tests/unit/test_plugin_grant_lifecycle.nim
	src/frontend/viewmodel/tests/unit/test_plugin_io_sdk.nim
	src/frontend/viewmodel/tests/unit/test_plugin_source_admission.nim
	src/frontend/viewmodel/tests/unit/test_project_action_runner.nim
	src/frontend/viewmodel/tests/unit/test_sdk_facade_boundary.nim
)

failures=0

fail() {
	echo "  FAIL: $*" >&2
	failures=$((failures + 1))
}

ok() {
	echo "  ok: $*"
}

# ---------------------------------------------------------------------------
# Per-file measurement
# ---------------------------------------------------------------------------
#
# Deliberately NOT parsed out of the lane's human-readable headline. That line
# is `OK (12 tests)` / `PARTIAL (8 OK, 1 FAILED, exit 1)` and its shape is
# owned by ci/lib/test-lane-report.sh, whose job is to be readable; binding a
# gate to it makes a wording change a false verdict. This compiles and runs
# each file itself, through the same backend selection the lane uses, and
# counts the markers.
#
# It is also what makes the two sides symmetric: the same function, the same
# greps, the same arithmetic, differing only in the backend argument. Two
# hand-written measurement loops would be trap 14 in the place it does the
# most damage — a parity check whose two halves do not measure the same thing.

# shellcheck source=ci/lib/test-lane-files.sh
# shellcheck disable=SC1091
source "${REPO_ROOT}/ci/lib/test-lane-files.sh"

# The same root ci/lib/nim-cache-root.sh computes -- this block used to
# re-implement it inline (override honoured, then basename + cksum of the
# checkout), which gave an identical path but a second copy of the rule.
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${REPO_ROOT}/ci/lib/nim-cache-root.sh"
cache_root="$(ct_nim_cache_root "${REPO_ROOT}")"
mkdir -p "${cache_root}" test-logs

# measure_file LANE FILE -> "cases<TAB>failures<TAB>assertions<TAB>status"
#
# The field order is `failures` BEFORE `assertions` and both call sites read it
# that way (`n_cases n_fails n_checks n_status`). An earlier revision of this
# comment transposed the two, which is trap 14 in its cheapest form — a second
# copy of the tuple, held in a place the shell does not read.
#
# `status` is one of: ran | build-failed. It is a separate field rather than a
# sentinel inside `cases` on purpose (trap 5a): "this file did not build" and
# "this file ran zero cases" are different events with different remedies, and
# a single number that means both merges them at exactly the moment the
# distinction matters.
measure_file() {
	local lane="$1" f="$2"
	local name backend cache artifact out rc oks fails checks
	name="$(basename "${f}" .nim)"
	backend="$(test_lane_backend "${lane}")"
	cache="${cache_root}/parity-${lane}-${name}"
	read -r -a extra <<<"$(test_lane_extra_flags "${lane}")"

	if [ "${backend}" = "wasm" ]; then
		artifact="${cache}/${name}.js"
		if ! nim c --hints:off --warnings:off \
			--cpu:wasm32 --os:linux -d:emscripten \
			--cc:clang --clang.exe:emcc --clang.linkerexe:emcc \
			--mm:orc --threads:off \
			--passL:-sSTACK_SIZE=8388608 \
			--passL:-sNODERAWFS=1 \
			--passL:-sALLOW_MEMORY_GROWTH=1 \
			--passL:-sEXIT_RUNTIME=1 \
			"${extra[@]}" --nimcache:"${cache}" -o:"${artifact}" "${f}" \
			>"${cache}.build.log" 2>&1; then
			printf '0\t0\t0\tbuild-failed\n'
			return
		fi
		out="$(timeout 1800 node "${artifact}" 2>&1)" && rc=0 || rc=$?
	else
		artifact="${cache}/${name}"
		if ! nim c --hints:off --warnings:off \
			"${extra[@]}" --nimcache:"${cache}" -o:"${artifact}" "${f}" \
			>"${cache}.build.log" 2>&1; then
			printf '0\t0\t0\tbuild-failed\n'
			return
		fi
		out="$(LD_LIBRARY_PATH="${CT_LD_LIBRARY_PATH:-}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
			timeout 1800 "${artifact}" 2>&1)" && rc=0 || rc=$?
	fi
	: "${rc}" # the status is carried by the [FAILED] count, which is compared

	oks="$(printf '%s\n' "${out}" | grep -c '\[OK\]' || true)"
	fails="$(printf '%s\n' "${out}" | grep -c '\[FAILED\]' || true)"

	# The assertion count, by the same two routes ci/lib/run-nim-test-lane.sh
	# reads it: a RUNTIME `CHECKS: <n>` wins, because a static one cannot see
	# a case that returned early; otherwise the `const ExpectedAssertions`
	# every declaring file also asserts against its own tally.
	checks=0
	if grep -qE '^[[:space:]]*CHECKS:[[:space:]]*[0-9]+' <<<"${out}"; then
		checks="$(printf '%s\n' "${out}" |
			grep -oE '^[[:space:]]*CHECKS:[[:space:]]*[0-9]+' |
			grep -oE '[0-9]+' | awk '{s += $1} END {print s + 0}')"
	elif grep -qE '^[[:space:]]*const[[:space:]]+ExpectedAssertions[[:space:]]*=[[:space:]]*[0-9]+' "${f}" 2>/dev/null; then
		checks="$(grep -oE '^[[:space:]]*const[[:space:]]+ExpectedAssertions[[:space:]]*=[[:space:]]*[0-9]+' "${f}" |
			grep -oE '[0-9]+$' | head -1)"
	fi
	printf '%s\t%s\t%s\tran\n' "${oks}" "${fails}" "${checks}"
}

parity_only="${CT_PARITY_ONLY:-}"

echo "=== PLAT-17 parity: vm-unit (native, nim c) vs vm-unit-wasm (wasm32, emcc, node) ==="
if [ -n "${parity_only}" ]; then
	echo "!!! RESTRICTED RUN — CT_PARITY_ONLY='${parity_only}'"
	echo "!!! This is NOT a verdict. It will exit 2 whatever it finds."
fi
echo

native_files="$(test_lane_files vm-unit)"
wasm_files="$(test_lane_files vm-unit-wasm)"
native_count="$(printf '%s\n' "${native_files}" | grep -c . || true)"
wasm_count="$(printf '%s\n' "${wasm_files}" | grep -c . || true)"

echo "vm-unit:      ${native_count} file(s)"
echo "vm-unit-wasm: ${wasm_count} file(s)"
echo

# ---------------------------------------------------------------------------
# Contract 1 — the exclusion list is exactly the difference
# ---------------------------------------------------------------------------
echo "--- contract 1: the wasm lane's exclusions are exactly the six that are documented"
actual_excluded="$(comm -23 \
	<(printf '%s\n' "${native_files}" | sort) \
	<(printf '%s\n' "${wasm_files}" | sort))"
expected_excluded="$(printf '%s\n' "${EXPECTED_WASM_EXCLUSIONS[@]}" | sort)"

if [ "${actual_excluded}" = "${expected_excluded}" ]; then
	ok "the difference is the documented six"
else
	fail 'vm-unit \ vm-unit-wasm is not the documented set'
	echo "      undocumented (in the difference, not in the list):" >&2
	comm -23 <(printf '%s\n' "${actual_excluded}") <(printf '%s\n' "${expected_excluded}") |
		sed 's/^/        /' >&2
	echo "      stale (in the list, not in the difference):" >&2
	comm -13 <(printf '%s\n' "${actual_excluded}") <(printf '%s\n' "${expected_excluded}") |
		sed 's/^/        /' >&2
fi

# The other direction, which a set difference alone does not cover: the wasm
# lane must not carry a file the native lane does not. `vm-unit-js` does carry
# one (`test_opfs_volume`, whose subject is `{.error.}` on the C target), so
# this is not a property of every derived lane and is worth asserting rather
# than assuming.
wasm_only="$(comm -13 \
	<(printf '%s\n' "${native_files}" | sort) \
	<(printf '%s\n' "${wasm_files}" | sort))"
if [ -z "${wasm_only}" ]; then
	ok "the wasm lane carries no file the native lane does not"
else
	fail "the wasm lane carries files vm-unit does not, so the counts below compare nothing:"
	printf '%s\n' "${wasm_only}" | sed 's/^/        /' >&2
fi

# Vacuous-pass guard, one level up from the runner's own.
if [ "${native_count}" -eq 0 ] || [ "${wasm_count}" -eq 0 ]; then
	fail "a lane matched no files at all (native=${native_count} wasm=${wasm_count})"
	echo
	echo "vm-unit-wasm parity: ${failures} contract(s) FAILED" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Contract 2 — per-file case, assertion and failure counts are EQUAL
# ---------------------------------------------------------------------------
echo
echo "--- contract 2: every shared file reports the same cases, assertions and failures"
echo "    (this compiles and runs ${wasm_count} suites twice; it is slow by construction)"
echo

total_native_cases=0
total_wasm_cases=0
total_native_checks=0
total_wasm_checks=0
divergent=0
compared=0

compare_files="${wasm_files}"
if [ -n "${parity_only}" ]; then
	compare_files="$(printf '%s\n' "${wasm_files}" | grep -E -- "${parity_only}" || true)"
	if [ -z "${compare_files}" ]; then
		echo "  CT_PARITY_ONLY='${parity_only}' matched no file in the lane." >&2
		exit 2
	fi
fi

printf '  %-62s %-18s %-18s\n' "file" "native c/a/f" "wasm c/a/f"
while read -r f; do
	[ -n "${f}" ] || continue

	IFS=$'\t' read -r n_cases n_fails n_checks n_status <<<"$(measure_file vm-unit "${f}")"
	IFS=$'\t' read -r w_cases w_fails w_checks w_status <<<"$(measure_file vm-unit-wasm "${f}")"

	compared=$((compared + 1))
	total_native_cases=$((total_native_cases + n_cases))
	total_wasm_cases=$((total_wasm_cases + w_cases))
	total_native_checks=$((total_native_checks + n_checks))
	total_wasm_checks=$((total_wasm_checks + w_checks))

	line="$(printf '  %-62s %-18s %-18s' \
		"${f#src/frontend/viewmodel/tests/unit/}" \
		"${n_cases}/${n_checks}/${n_fails}" \
		"${w_cases}/${w_checks}/${w_fails}")"

	# A build failure on either side is reported as ITS OWN event, never
	# folded into "the counts differ". A file that did not build reports
	# 0/0/0, and 0/0/0 against 0/0/0 is an EQUALITY -- so without this branch
	# a lane where nothing compiled at all would pass contract 2 perfectly.
	if [ "${n_status}" != "ran" ] || [ "${w_status}" != "ran" ]; then
		echo "${line}  <- DID NOT BUILD (native=${n_status} wasm=${w_status})"
		fail "${f}: did not build (native=${n_status} wasm=${w_status})"
		divergent=$((divergent + 1))
		continue
	fi

	if [ "${n_cases}" -eq 0 ]; then
		echo "${line}  <- RAN NO CASES on native"
		fail "${f}: ran no cases on the native backend; there is nothing to compare"
		divergent=$((divergent + 1))
		continue
	fi

	if [ "${n_cases}" -ne "${w_cases}" ] ||
		[ "${n_checks}" -ne "${w_checks}" ] ||
		[ "${n_fails}" -ne "${w_fails}" ]; then
		echo "${line}  <- DIVERGES"
		fail "${f}: native ${n_cases} case(s)/${n_checks} assertion(s)/${n_fails} failed," \
			"wasm ${w_cases}/${w_checks}/${w_fails}"
		divergent=$((divergent + 1))
	else
		echo "${line}"
	fi
done <<<"${compare_files}"

echo
echo "compared ${compared} file(s)"
echo "  cases:      native ${total_native_cases}   wasm ${total_wasm_cases}"
echo "  assertions: native ${total_native_checks}   wasm ${total_wasm_checks}"
echo "  divergent files: ${divergent}"

# The totals are printed for the reader and checked for the record, but the
# per-file loop above is what decides -- see this file's header for why a
# totals-only gate can be satisfied by two files diverging in opposite
# directions.
if [ "${total_native_cases}" -ne "${total_wasm_cases}" ]; then
	fail "total case counts differ: native ${total_native_cases}, wasm ${total_wasm_cases}"
fi
if [ "${total_native_checks}" -ne "${total_wasm_checks}" ]; then
	fail "total assertion counts differ: native ${total_native_checks}, wasm ${total_wasm_checks}"
fi

echo
if [ -n "${parity_only}" ]; then
	# A restricted run reports what it FOUND and refuses to conclude. Both
	# arms are here so the tool is still useful for falsification: it must be
	# able to say "the planted divergence was seen" without ever being able to
	# say "this tree is fine".
	if [ "${failures}" -eq 0 ]; then
		echo "vm-unit-wasm parity: RESTRICTED RUN, 0 contract(s) failed over the" \
			"${compared} file(s) CT_PARITY_ONLY matched." >&2
	else
		echo "vm-unit-wasm parity: RESTRICTED RUN, ${failures} contract(s) FAILED" \
			"over the ${compared} file(s) CT_PARITY_ONLY matched." >&2
	fi
	echo "vm-unit-wasm parity: NOT A VERDICT — rerun without CT_PARITY_ONLY." >&2
	exit 2
fi
if [ "${failures}" -eq 0 ]; then
	echo "vm-unit-wasm parity: PASS — three backends, one set of results"
	exit 0
fi
echo "vm-unit-wasm parity: ${failures} contract(s) FAILED" >&2
exit 1
