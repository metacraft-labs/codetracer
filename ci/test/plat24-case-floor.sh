#!/usr/bin/env bash
#
# plat24-case-floor.sh — PLAT-24's counted target, gated.
#
# Editor-Model-Conformance-Suite.md §10.1 puts TWO numbers in TWO units in TWO
# homes doing TWO different jobs:
#
#   * the exact ASSERTION count lives in the suite as `const ExpectedAssertions`
#     and is asserted by the suite against its own runtime tally. That half
#     already works: both PLAT-24 suites declare it, print `CHECKS:` and have a
#     case that compares the two.
#   * the CASE FLOOR lives in the milestone, on a line reading `FLOOR: <n>
#     cases`, and is asserted against the `[OK]` count of the milestone's
#     suites. That half is what this script is.
#
# WHY THIS IS A SCRIPT AND NOT A LINE IN `run-nim-test-lane.sh`
# ============================================================
# §10.1 states plainly that "nothing in the lane reads a `FLOOR:` line out of a
# milestone file today, so that half is a deliverable of the milestones below
# and not a mechanism to be assumed." A GENERIC floor mechanism — every lane
# discovering which milestone owns each of its files — is a campaign-wide
# change that would alter every lane's pass condition at once, and PLAT-24 is
# not where that should land.
#
# What PLAT-24 can honestly own is its OWN floor, gated by something somebody
# can run. So this script asserts PLAT-24's floor and nothing else, and the
# milestone's deliverable says "a gate" rather than "the lane" with the date
# the wording was corrected and the reason. A box that claims a mechanism which
# does not exist is the exact defect the milestone was last caught committing.
#
# THE RULES IT KEEPS
# ==================
#  * A MISSING SPEC CHECKOUT FAILS BY NAME. It does not skip and it is not
#    counted as a pass — the Silent-Self-Pass audit is why.
#  * THE PARSE IS ASSERTED. Exactly one `FLOOR:` line must be found inside
#    PLAT-24's section, and the section itself must be found; a parser that
#    silently read the wrong milestone's floor, or none, would otherwise
#    satisfy everything written over it.
#  * IT IS TWO-SIDED ABOUT ITS OWN INPUT. Every suite named below must
#    contribute at least one `[OK]`, so a suite that failed to compile cannot
#    be absorbed into a total the other one carries.
#  * THE UNIT IS `[OK]` BLOCKS, which is unittest's per-test-block line and the
#    same unit §1.1 measured CodeMirror's 633 in. It is deliberately NOT the
#    assertion count: a file of empty cases scores `OK (n tests)`, and that is
#    what the OTHER number is for.
#
# Usage (from the repository root):
#   bash ci/test/plat24-case-floor.sh

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"

SPEC_REL="../codetracer-specs/Planned-Work/CodeTracer-Platform.milestones.org"
MILESTONE="** PLAT-24: The text store decision"

SUITES=(
	src/frontend/viewmodel/tests/unit/test_editor_text_store.nim
	src/frontend/viewmodel/tests/unit/test_editor_unicode_corpus.nim
)

if [ ! -f "${SPEC_REL}" ]; then
	echo "FAIL: the milestone file is not here: ${SPEC_REL}"
	echo "      PLAT-24's floor is published in codetracer-specs and read at run"
	echo "      time, never transcribed. A missing sibling checkout fails BY"
	echo "      NAME rather than skipping: a check that detects a missing"
	echo "      prerequisite, returns early and is counted PASSED is the defect"
	echo "      (Silent-Self-Pass-Audit-2026-08-23.md)."
	exit 1
fi

# PLAT-24's section: from its heading to the next top-level milestone heading.
section="$(awk -v start="${MILESTONE}" '
	index($0, start) == 1 { inside = 1; print; next }
	inside && /^\*\* / { exit }
	inside { print }
' "${SPEC_REL}")"

if [ -z "${section}" ]; then
	echo "FAIL: no section in ${SPEC_REL} begins with:"
	echo "      ${MILESTONE}"
	exit 1
fi

mapfile -t floor_lines < <(grep -oE '^[[:space:]]*FLOOR: [0-9]+ cases' <<<"${section}" || true)
if [ "${#floor_lines[@]}" -ne 1 ]; then
	echo "FAIL: PLAT-24's section holds ${#floor_lines[@]} FLOOR lines, expected exactly 1."
	echo "      §10.2: one spelling, at one indent, one per milestone — the total"
	echo "      is computed from those lines, so a second one silently doubles a"
	echo "      term of it and a missing one silently drops a milestone."
	exit 1
fi
floor="$(grep -oE '[0-9]+' <<<"${floor_lines[0]}" | head -1)"
echo "FLOOR, read from ${SPEC_REL}: ${floor} cases"

total=0
for suite in "${SUITES[@]}"; do
	if [ ! -f "${suite}" ]; then
		echo "FAIL: ${suite} is not in the tree"
		exit 1
	fi
	bin="${TMPDIR:-/tmp}/plat24-floor-$(basename "${suite}" .nim)"
	out="$(nim c -r --hints:off -o:"${bin}" "${suite}" 2>&1)" || {
		echo "FAIL: ${suite} did not run green"
		printf '%s\n' "${out}" | tail -30
		exit 1
	}
	# `[OK]` blocks, the same unit §1.1 counted the reference suite in.
	n="$(grep -cE '^[[:space:]]*\[OK\]' <<<"${out}" || true)"
	failed="$(grep -cE '^[[:space:]]*\[FAILED\]' <<<"${out}" || true)"
	checks="$(grep -oE '^[[:space:]]*CHECKS: [0-9]+' <<<"${out}" | grep -oE '[0-9]+' | head -1 || true)"
	if [ "${failed}" -ne 0 ]; then
		echo "FAIL: ${suite} reported ${failed} failing case(s)"
		exit 1
	fi
	if [ "${n}" -eq 0 ]; then
		echo "FAIL: ${suite} produced NO [OK] lines."
		echo "      A run that prints nothing looks exactly like a run in which"
		echo "      every case passed, if the only signal read is an exit status."
		exit 1
	fi
	echo "  ${suite}: ${n} cases, CHECKS: ${checks:-none}"
	total=$((total + n))
done

echo "TOTAL: ${total} cases across ${#SUITES[@]} suites; floor is ${floor}"
if [ "${total}" -lt "${floor}" ]; then
	echo "FAIL: the suite shrank below its published floor."
	echo "      §10.1: the floor moves only UPWARD, and only by a deliberate"
	echo "      edit to the milestone. If these cases are genuinely gone, that"
	echo "      is an edit somebody makes on purpose and defends."
	exit 1
fi
echo "OK: PLAT-24's suites meet the floor published in the milestone."
