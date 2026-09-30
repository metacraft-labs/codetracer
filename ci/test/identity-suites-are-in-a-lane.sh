#!/usr/bin/env bash
#
# identity-suites-are-in-a-lane.sh — every identity suite is collected by a
# lane, so writing one is enough to make it run.
#
# ## The defect this exists for, which really happened
#
# `issuer_test.nim` and `jwt_test.nim` were written under `src/tests/identity/`.
# `ci/lib/test-lane-files.sh` collects `src/frontend/viewmodel/tests/unit/
# test_*.nim` by glob, plus `src/tests/gui/tests` and `src/tests/cli`, and
# nothing else in this area. So 32 cases ran when a person ran them by hand and
# NEVER ONCE in CI, for a week, while their commit messages reported them
# passing. Both files have moved; this asserts nobody can do it again.
#
# ## Why this is a gate and not a CI job
#
# It is the same claim CI would make and it does not need CI to make it. The
# lane list is a file in this checkout: which suites a lane collects is
# decidable by reading it, so the assertion belongs wherever the other identity
# gates run — including on a branch that has no CI at all, which `agents`
# currently does not (`codetracer-specs/issues/
# 2026-09-30-agents-branch-has-no-ci.md`).
#
# That is the narrow lesson of the original defect. The suites were not
# unverified because CI was absent; they were unverified because NOTHING
# COLLECTED THEM, and no amount of CI on a branch fixes a suite that no lane
# names.
#
# ## Two lanes, not one
#
# `vm-unit` is the C backend and `vm-unit-js` is JavaScript, and the identity
# layer's whole reason for living in `viewmodel/` is that it must behave
# identically on both. A suite collected by one lane and not the other is the
# shape of the M17/J8 defect — a bug invisible on the backend most people
# compile and fatal on the one that ships — so both are required.
#
# ## THE SUITES ARE FOUND BY SUBJECT, NOT BY LOCATION, and the first version of
# ## this gate was vacuous for exactly that reason
#
# It globbed `src/frontend/viewmodel/tests/unit/test_identity_*.nim` and then
# asserted every file it found was in the unit lane. That is a tautology: the
# lane is defined by that same directory, so a suite which LEAVES the directory
# leaves the enumeration with it and the gate stays green. Moving one suite out
# by hand proved it — 6 checks, 0 failures, and the suite nobody would ever run
# again sitting untested in `src/tests/`.
#
# Which is the original defect, reproduced by the gate written to prevent it.
#
# So the subject set is every file under `src/` that IMPORTS an identity module
# and looks like a suite. That property does not move when the file does, so a
# suite written anywhere in the tree is found and then required to be in a lane.
#
# Usage:  bash ci/test/identity-suites-are-in-a-lane.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

# A file that directly imports one of these is testing the identity layer,
# wherever it happens to live.
IDENTITY_IMPORT='^import .*identity/(token|session|jwt|issuer|device_grant|rs256_verifier)'
# ...and looks like a suite rather than a module.
SUITE_MARKER='std/unittest|std/\[[^]]*unittest'
REQUIRED_LANES="vm-unit vm-unit-js"

work="$(mktemp -d)"
checks=0
failures=0
note() { printf '  %s\n' "$*"; }
ok() {
	checks=$((checks + 1))
	printf '  [OK]     %s\n' "$*"
}
bad() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '  [FAILED] %s\n' "$*"
}
cleanup() {
	rm -rf "${work}"
	rm -rf "${repo_root}/src/tests/_lane_control"
}
trap cleanup EXIT INT TERM

# shellcheck source=ci/lib/test-lane-files.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/test-lane-files.sh"

echo "=== every identity suite is collected by a lane ==="
echo

# ---------------------------------------------------------------------------
echo "Step 1: the suites exist, and there are more than one"
echo "    THE POSITIVE CONTROL ON THE SUBJECT. 'Every suite is in a lane' is"
echo "    also true of a directory with no suites in it, and of a glob that"
echo "    stopped matching."
# ---------------------------------------------------------------------------
# By subject. The identity MODULES import each other, so the directory they
# live in is excluded — they are the thing under test, not tests of it.
mapfile -t suites < <(
	grep -rlE "${IDENTITY_IMPORT}" --include='*.nim' src |
		grep -v '^src/frontend/viewmodel/identity/' |
		while IFS= read -r f; do
			grep -qE "${SUITE_MARKER}" "${f}" && printf '%s\n' "${f}"
		done | sort
)
if [ "${#suites[@]}" -ge 2 ]; then
	ok "found ${#suites[@]} suite(s) that import an identity module"
	for s in "${suites[@]}"; do note "  ${s}"; done
else
	bad "found ${#suites[@]} suite(s) importing an identity module; the import pattern is wrong or the suites are gone"
	echo
	echo "RESULT: FAILED"
	exit 1
fi
echo

# ---------------------------------------------------------------------------
echo "Step 2: each lane collects every one of them"
# ---------------------------------------------------------------------------
for lane in ${REQUIRED_LANES}; do
	if ! test_lane_files "${lane}" >"${work}/${lane}.txt" 2>"${work}/${lane}.err"; then
		bad "the lane list for '${lane}' could not be produced"
		sed 's/^/      /' "${work}/${lane}.err" | head -5
		continue
	fi
	missing=0
	for s in "${suites[@]}"; do
		if ! grep -qxF "${s}" "${work}/${lane}.txt"; then
			bad "${lane} does not collect ${s}"
			note "      A suite no lane names runs only when somebody runs it by hand."
			missing=$((missing + 1))
		fi
	done
	if [ "${missing}" -eq 0 ]; then
		ok "${lane} collects all ${#suites[@]} identity suite(s)"
	fi
done
echo

# ---------------------------------------------------------------------------
echo "Step 3: THE REAL POSITIVE CONTROL — the mistake that was made, replanted"
echo "    Proves this gate can fail. A suite in the directory the two lost"
echo "    files were written in must NOT be collected, and the check above must"
echo "    be able to see that."
# ---------------------------------------------------------------------------
mkdir -p "${repo_root}/src/tests/_lane_control"
planted="src/tests/_lane_control/test_identity_planted.nim"
cat >"${repo_root}/${planted}" <<'NIMEOF'
## A control for ci/test/identity-suites-are-in-a-lane.sh. Deleted by that
## script's cleanup; if you are reading this in a checkout, something aborted.
##
## It IMPORTS an identity module on purpose: that is what puts it in the subject
## set, and a control that was not in the subject set would prove nothing.
import std/unittest
import ../../frontend/viewmodel/identity/token
suite "planted": test "nothing": check compiles(IdentityClaims)
NIMEOF

mapfile -t with_control < <(
	grep -rlE "${IDENTITY_IMPORT}" --include='*.nim' src |
		grep -v '^src/frontend/viewmodel/identity/' |
		while IFS= read -r f; do
			grep -qE "${SUITE_MARKER}" "${f}" && printf '%s\n' "${f}"
		done | sort
)
if printf '%s\n' "${with_control[@]}" | grep -qxF "${planted}"; then
	ok "the planted suite is IN the subject set — the enumeration follows the import, not the directory"
else
	bad "the planted suite is not in the subject set; the enumeration is still location-based and this gate is vacuous"
fi

control_seen=0
for lane in ${REQUIRED_LANES}; do
	if test_lane_files "${lane}" 2>/dev/null | grep -qxF "${planted}"; then
		control_seen=$((control_seen + 1))
	fi
done
if [ "${control_seen}" -eq 0 ]; then
	ok "...and is collected by NEITHER lane, which is exactly how the two real ones were lost"
else
	bad "the planted suite WAS collected by ${control_seen} lane(s); this gate's premise is wrong"
fi

# The two together are the whole control: in the subject set AND in no lane
# means step 2 would have failed. Asserted as one statement so a future edit
# cannot satisfy half of it.
if printf '%s\n' "${with_control[@]}" | grep -qxF "${planted}" &&
	[ "${control_seen}" -eq 0 ]; then
	ok "so step 2 WOULD have failed with the control present — this gate can fail"
else
	bad "the control does not demonstrate a failure; step 2's passes are unproven"
fi

rm -rf "${repo_root}/src/tests/_lane_control"
if [ -e "${repo_root}/src/tests/_lane_control" ]; then
	bad "the planted control was not removed"
else
	ok "the planted control was removed and the tree is clean"
fi
echo

echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -gt 0 ]; then
	echo "RESULT: FAILED — ${failures} check(s)"
	exit 1
fi
echo "RESULT: OK — every identity suite is collected by both unit lanes"
