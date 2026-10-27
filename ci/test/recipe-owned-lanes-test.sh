#!/usr/bin/env bash
#
# recipe-owned-lanes-test.sh — every lane id is EITHER run by the generic lane
# runner OR owned by a `just` recipe, never both and never neither, and the
# runner refuses the recipe-owned ones by name.
#
# WHY THIS EXISTS
# ---------------
# `ci/lib/test-lane-files.sh` lists every lane in `test_lane_ids`, and for most
# of them `ci/lib/run-nim-test-lane.sh <lane>` IS the lane: its `just` recipe is
# one line that hands the id to the runner. For ten of them it is not. Their
# file lists exist so `ci/test/test-lane-coverage.sh` can answer "does every
# test-shaped file run somewhere?", but their EXECUTION lives in a bespoke
# recipe — per-file defines and a `window` alias (`frontend-js`), a CLI that is
# compiled and never run (`m16-release-gate`), BPF capabilities and a separately
# built object (`bpf`), a sibling framework's paths (`book-isonim`), a scoring
# rule for all-`MISSING-RECORDER SKIP:` files (`vm-recorder-gated`), and so on.
#
# Until the runner refused them, it accepted every one, and the five that were
# measured under it were red for reasons that had nothing to do with the
# product (at codetracer `661744f2c`: 3 + 1 + 4 + 10 artefact failures over
# `frontend-js`, `m16-release-gate`, `bpf` and `book-isonim`, and
# `vm-recorder-gated` scoring all-`MISSING-RECORDER SKIP:` files DID NOT RUN).
# A sweep over `test_lane_ids` — which that function's own header used to
# invite — reported those as product failures. An eleventh lane,
# `agent-api-contract`, was run by its recipe with a bare `nim c -r` and by
# nothing through the runner; that recipe now hands the id to the runner, so
# check (a) classifies it runner-owned.
#
# The fix marks such a lane with `test_lane_recipe` and has the runner exit 2
# naming the recipe. This suite keeps the two halves from drifting apart:
#
#   a. CLASSIFICATION — every lane in `test_lane_ids` is invoked as
#      `run-nim-test-lane.sh <lane>` by some non-comment line under justfile,
#      ci/, scripts/ or .github/, XOR has a non-empty `test_lane_recipe`. A lane
#      that is neither is a lane nothing runs; a lane that is both is a lane
#      whose recipe was just converted to the runner, and whose marker now
#      refuses its own recipe.
#   b. RECIPES EXIST — every recipe `test_lane_recipe` names is a recipe in
#      `justfile`, so the remedy the refusal prints is one that works.
#   c. REFUSAL — against the REAL runner, every recipe-owned lane, with and
#      without `--compile-only`, exits 2, names `just <recipe>`, and never
#      reaches the compiler. "Never reaches" is observed, not inferred: `nim`
#      on PATH is a stub that records each call.
#   d. POSITIVE CONTROL — a runner-owned lane under the same stub is NOT
#      refused and DOES reach the compiler. Without it, (c) would pass against
#      a runner that refused everything, or against a stub that PATH never
#      resolved.
#
# The stub `nim` is the one double here, and it is justified: the property
# under test is that the runner stops BEFORE compiling anything, so a real
# compiler would add minutes and nothing to observe. It exits 1, so the
# positive control's lane reports COMPILE ERROR — that is expected; only the
# fact of the call is asserted. Pure bash, no toolchain, a few seconds; it runs
# in the lint stage (`ci/lint/nim.sh`).

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

# shellcheck source=ci/lib/test-lane-files.sh
# shellcheck disable=SC1091 # resolved at runtime from $repo_root
source "${repo_root}/ci/lib/test-lane-files.sh"

runner="ci/lib/run-nim-test-lane.sh"
self="ci/test/recipe-owned-lanes-test.sh"

failures=0
checks=0

pass() {
	checks=$((checks + 1))
	echo "  [OK] $1"
}

fail() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	echo "  [FAILED] $1"
}

# lane_recipe ID — `test_lane_recipe`, or empty when the function does not
# exist. The absent case is a tree that predates the marker; it must FAIL the
# checks below (every recipe-owned lane then reads as "neither"), not abort
# the suite on `command not found`.
lane_recipe() {
	if declare -F test_lane_recipe >/dev/null; then
		test_lane_recipe "$1"
	fi
}

work="$(mktemp -d "${TMPDIR:-/tmp}/recipe-owned-lanes-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

echo "=== recipe-owned lanes: classification, refusal, positive control ==="

# ---------------------------------------------------------------------------
# (a) every lane is runner-invoked XOR recipe-owned
# ---------------------------------------------------------------------------
# Every line that hands a lane to the runner, with comment lines dropped: a
# `# ... run-nim-test-lane.sh vm-js` inside a recipe's commentary invokes
# nothing. The runner itself, the lane library and this file are excluded,
# because each names lanes in prose or usage text rather than running them.
# `grep -rn` prints `path:line:content`; the comment test is applied to the
# content field only.
invocations="${work}/invocations"
grep -rnE 'run-nim-test-lane\.sh[[:space:]]' justfile ci scripts .github 2>/dev/null |
	grep -vE "^(${runner}|ci/lib/test-lane-files\.sh|${self}):" |
	grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' >"${invocations}" || true

while read -r lane; do
	[ -n "${lane}" ] || continue
	invoked=0
	if grep -qE "run-nim-test-lane\.sh[[:space:]]+${lane}([[:space:]]|\$)" "${invocations}"; then
		invoked=1
	fi
	recipe="$(lane_recipe "${lane}")"
	if [ "${invoked}" -eq 1 ] && [ -n "${recipe}" ]; then
		fail "${lane}: run through ${runner} AND marked recipe-owned (${recipe}) — the runner now refuses its own caller"
	elif [ "${invoked}" -eq 0 ] && [ -z "${recipe}" ]; then
		fail "${lane}: run through ${runner} by nothing, and test_lane_recipe names no owning recipe"
	elif [ -n "${recipe}" ]; then
		pass "${lane}: recipe-owned (${recipe})"
	else
		pass "${lane}: runner-owned"
	fi
done < <(test_lane_ids)

# ---------------------------------------------------------------------------
# (b) every named recipe exists in justfile
# ---------------------------------------------------------------------------
# A recipe header is `name:` or `name params...:` optionally followed by
# dependencies (`test-vm-recorder-gated: vm-test-prereqs`). `[^:=]*` between
# the name and the colon keeps `name := value` assignments from matching.
recipe_lanes=()
while read -r lane; do
	[ -n "${lane}" ] || continue
	recipe="$(lane_recipe "${lane}")"
	[ -n "${recipe}" ] || continue
	recipe_lanes+=("${lane}")
	for r in ${recipe}; do
		if grep -qE "^${r}( [^:=]*)?:([^=]|\$)" justfile; then
			pass "${lane}: recipe '${r}' exists in justfile"
		else
			fail "${lane}: test_lane_recipe names '${r}', which is not a recipe in justfile"
		fi
	done
done < <(test_lane_ids)

# ---------------------------------------------------------------------------
# (c) + (d) the real runner, a recording stub compiler
# ---------------------------------------------------------------------------
stub_dir="${work}/bin"
stub_log="${work}/nim.calls"
mkdir -p "${stub_dir}" "${work}/tmp" "${work}/cache" "${work}/layout"
cat >"${stub_dir}/nim" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${stub_log}"
exit 1
EOF
chmod +x "${stub_dir}/nim"

# run_runner ARGS... — the real runner with the stub first on PATH and every
# location it would write pointed into the scratch directory. CODETRACER_HOME
# sits under TMPDIR so the runner treats it as scratch (see its header). Prints
# combined output; returns the runner's status.
run_runner() {
	: >"${stub_log}"
	PATH="${stub_dir}:${PATH}" \
		TMPDIR="${work}/tmp" \
		CT_NIM_CACHE_ROOT="${work}/cache" \
		CODETRACER_HOME="${work}/tmp/home" \
		CODETRACER_TUI_LAYOUT_DIR="${work}/layout" \
		CT_LANE_TIMEOUT=60 \
		bash "${runner}" "$@" 2>&1
}

stub_calls() {
	if [ -s "${stub_log}" ]; then
		wc -l <"${stub_log}" | tr -d ' '
	else
		echo 0
	fi
}

if [ "${#recipe_lanes[@]}" -eq 0 ]; then
	fail "no lane is marked recipe-owned — test_lane_recipe is absent or answers nothing, so the refusal cannot be exercised"
fi

for lane in ${recipe_lanes[@]+"${recipe_lanes[@]}"}; do
	recipe="$(lane_recipe "${lane}")"
	for mode in "" "--compile-only"; do
		label="${lane}${mode:+ ${mode}}"
		out="$(run_runner "${lane}" ${mode:+"${mode}"})"
		rc=$?
		calls="$(stub_calls)"
		ok=1
		[ "${rc}" -eq 2 ] || {
			ok=0
			fail "${label}: expected exit 2 (refused), got ${rc}"
		}
		for r in ${recipe}; do
			grep -qF -- "just ${r}" <<<"${out}" || {
				ok=0
				fail "${label}: refusal does not name 'just ${r}'"
			}
		done
		[ "${calls}" -eq 0 ] || {
			ok=0
			fail "${label}: the runner reached the compiler (${calls} nim call(s)) instead of refusing"
		}
		if [ "${ok}" -eq 1 ]; then
			pass "${label}: refused with exit 2, names its recipe, compiler never called"
		else
			printf '%s\n' "${out}" | tail -n 15 | sed 's/^/        | /'
		fi
	done
done

control="common-units"
if [ -n "$(lane_recipe "${control}")" ]; then
	fail "positive control '${control}' is itself marked recipe-owned — pick another runner-owned lane"
else
	out="$(run_runner "${control}")"
	calls="$(stub_calls)"
	if grep -qF "recipe-owned" <<<"${out}"; then
		fail "${control}: a runner-owned lane was refused"
		printf '%s\n' "${out}" | tail -n 15 | sed 's/^/        | /'
	elif [ "${calls}" -eq 0 ]; then
		fail "${control}: the stub nim was never called — the stub is not on the runner's PATH, so (c) proves nothing"
		printf '%s\n' "${out}" | tail -n 15 | sed 's/^/        | /'
	else
		pass "${control}: not refused, reached the compiler (${calls} nim call(s); COMPILE ERROR from the stub is expected)"
	fi
fi

echo
if [ "${failures}" -gt 0 ]; then
	echo "recipe-owned lanes: ${failures} of ${checks} check(s) FAILED"
	exit 1
fi
echo "recipe-owned lanes: all ${checks} check(s) passed"
