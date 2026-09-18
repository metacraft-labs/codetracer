#!/usr/bin/env bash
#
# editor-model-case-floor.sh — the Editor Model Conformance campaign's counted
# targets, gated. One milestone per invocation.
#
#   bash ci/test/editor-model-case-floor.sh PLAT-24
#   bash ci/test/editor-model-case-floor.sh PLAT-25
#   bash ci/test/editor-model-case-floor.sh PLAT-26
#   bash ci/test/editor-model-case-floor.sh PLAT-27
#
# THIS FILE WAS `plat24-case-floor.sh` AND IT GREW AN ARGUMENT
# ===========================================================
# It was renamed rather than copied, deliberately. PLAT-25 needs the same
# gate, and a second script would be a second copy of a parser, a second
# `FLOOR:` grammar and a second place for the two to drift — which is
# Verification-Harness-Traps §30 arriving through a file copy instead of
# through a function. `just plat24-case-floor` still works and still gates
# PLAT-24 and nothing else; what changed is that the milestone is a parameter
# and the suite list is a table.
#
# Editor-Model-Conformance-Suite.md §10.1 puts TWO numbers in TWO units in TWO
# homes doing TWO different jobs:
#
#   * the exact ASSERTION count lives in the suite as `const ExpectedAssertions`
#     and is asserted by the suite against its own runtime tally. Every suite
#     named below declares it, prints `CHECKS:` and has a case comparing the
#     two.
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
# change that would alter every lane's pass condition at once, and neither of
# these milestones is where that should land. This gates the milestones named
# in its own table and nothing else.
#
# THE RULES IT KEEPS
# ==================
#  * A MISSING SPEC CHECKOUT FAILS BY NAME. It does not skip and it is not
#    counted as a pass — the Silent-Self-Pass audit is why.
#  * THE PARSE IS ASSERTED. Exactly one `FLOOR:` line must be found inside the
#    milestone's section, and the section itself must be found; a parser that
#    silently read the wrong milestone's floor, or none, would otherwise
#    satisfy everything written over it.
#  * IT IS TWO-SIDED ABOUT ITS OWN INPUT. Every suite named below must
#    contribute at least one `[OK]`, so a suite that failed to compile cannot
#    be absorbed into a total the other one carries.
#  * THE UNIT IS `[OK]` BLOCKS, which is unittest's per-test-block line and the
#    same unit §1.1 measured CodeMirror's 633 in. It is deliberately NOT the
#    assertion count: a file of empty cases scores `OK (n tests)`, and that is
#    what the OTHER number is for.
#  * FOR PLAT-25 AND PLAT-26 IT ALSO RUNS THE LAW-TABLE ORACLE (§7.1). The ten
#    `LAW-A*` ids are published in §3.1 of the conformance suite and the six
#    `LAW-S*` ids in §3.2; each suite file carries a transcription. The two are
#    compared here, in BOTH directions, with the cardinality asserted — because
#    two set differences are both satisfied by two empty sets — and a killer
#    cell that is empty or an em dash fails, because "an arm with no stated
#    killer is not admitted".
#
#    THE ORACLE IS PARAMETERISED RATHER THAN COPIED. PLAT-26 needed the same
#    two-way count over a different table, a different id prefix and a
#    different cardinality; a second block would have been a second parser and
#    a second place for the grammar to drift, which is the file-copy form of
#    Verification-Harness-Traps §30. Four variables carry the difference.
#
#    PLAT-27 ADDED A FIFTH: `LAW_DEFERRED`. §3.3 publishes SEVEN `LAW-C` rows
#    and says of the seventh that it *"lands in PLAT-28, which owns widgets,
#    and is named here because it is a coordinate claim"*. A milestone that
#    implements six of seven and a milestone that silently dropped one look
#    identical to a two-way count, so the deferral is DECLARED here and
#    CHECKED in both directions: every deferred id must be published in the
#    table AND absent from the suite, and the two-way count then runs over
#    `published − deferred` against the suite with the cardinality asserted.
#    The alternative — writing `LAW_COUNT=6` and letting the seventh row fall
#    out of the comparison — is the shape where a published law stops being
#    published and nothing says so.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"

MILESTONE_ID="${1:-PLAT-24}"

SPEC_REL="../codetracer-specs/Planned-Work/CodeTracer-Platform.milestones.org"
LAWS_REL="../codetracer-specs/Testing/Editor-Model-Conformance-Suite.md"

case "${MILESTONE_ID}" in
PLAT-24)
	MILESTONE="** PLAT-24: The text store decision"
	SUITES=(
		src/frontend/viewmodel/tests/unit/test_editor_text_store.nim
		src/frontend/viewmodel/tests/unit/test_editor_unicode_corpus.nim
	)
	LAW_SUITE=""
	;;
PLAT-25)
	MILESTONE="** PLAT-25: The edit algebra"
	SUITES=(
		src/frontend/viewmodel/tests/unit/test_editor_change_algebra.nim
		src/frontend/viewmodel/tests/unit/test_editor_change_examples.nim
	)
	LAW_SUITE=src/frontend/viewmodel/tests/unit/test_editor_change_algebra.nim
	LAW_PREFIX="LAW-A"
	LAW_SECTION="3.1"
	LAW_COUNT=10
	;;
PLAT-26)
	MILESTONE="** PLAT-26: Selections as the primitive"
	SUITES=(
		src/frontend/viewmodel/tests/unit/test_editor_selection_laws.nim
		src/frontend/viewmodel/tests/unit/test_editor_selection_examples.nim
	)
	LAW_SUITE=src/frontend/viewmodel/tests/unit/test_editor_selection_laws.nim
	LAW_PREFIX="LAW-S"
	LAW_SECTION="3.2"
	LAW_COUNT=6
	;;
PLAT-27)
	MILESTONE="** PLAT-27: The coordinate model under soft wrap"
	SUITES=(
		src/frontend/viewmodel/tests/unit/test_editor_wrap_laws.nim
		src/frontend/viewmodel/tests/unit/test_editor_wrap_examples.nim
	)
	LAW_SUITE=src/frontend/viewmodel/tests/unit/test_editor_wrap_laws.nim
	LAW_PREFIX="LAW-C"
	LAW_SECTION="3.3"
	LAW_COUNT=7
	LAW_DEFERRED="LAW-C7"
	;;
*)
	echo "FAIL: this gate has no table entry for '${MILESTONE_ID}'."
	echo "      Known: PLAT-24, PLAT-25, PLAT-26, PLAT-27. A milestone gates"
	echo "      its own floor; adding one here is a deliberate edit, which is"
	echo "      the point."
	exit 1
	;;
esac
LAW_DEFERRED="${LAW_DEFERRED:-}"

if [ ! -f "${SPEC_REL}" ]; then
	echo "FAIL: the milestone file is not here: ${SPEC_REL}"
	echo "      The floor is published in codetracer-specs and read at run"
	echo "      time, never transcribed. A missing sibling checkout fails BY"
	echo "      NAME rather than skipping: a check that detects a missing"
	echo "      prerequisite, returns early and is counted PASSED is the defect"
	echo "      (Silent-Self-Pass-Audit-2026-08-23.md)."
	exit 1
fi

# The milestone's section: from its heading to the next top-level heading.
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
	echo "FAIL: ${MILESTONE_ID}'s section holds ${#floor_lines[@]} FLOOR lines, expected exactly 1."
	echo "      §10.2: one spelling, at one indent, one per milestone — the total"
	echo "      is computed from those lines, so a second one silently doubles a"
	echo "      term of it and a missing one silently drops a milestone."
	exit 1
fi
floor="$(grep -oE '[0-9]+' <<<"${floor_lines[0]}" | head -1)"
echo "FLOOR, read from ${SPEC_REL}: ${floor} cases"

# ---------------------------------------------------------------------------
# THE LAW-TABLE ORACLE — §7.1's two-way count, for the milestones that have one
# ---------------------------------------------------------------------------
if [ -n "${LAW_SUITE}" ]; then
	if [ ! -f "${LAWS_REL}" ]; then
		echo "FAIL: the conformance suite spec is not here: ${LAWS_REL}"
		echo "      §${LAW_SECTION}'s law table is an ORACLE and is read at run time."
		exit 1
	fi
	# The table rows: `| \`LAW-X1\` | statement | [population |] killer |`
	law_section="$(awk -v sect="### ${LAW_SECTION} " '
		index($0, sect) == 1 { inside = 1; next }
		inside && /^### / { exit }
		inside { print }
	' "${LAWS_REL}")"
	if [ -z "${law_section}" ]; then
		echo "FAIL: §${LAW_SECTION} was not found in ${LAWS_REL}."
		echo "      A parser that matched nothing satisfies every check written"
		echo "      over what it read (§4)."
		exit 1
	fi
	spec_ids=()
	missing_killers=()
	# The ids are spelled in MARKDOWN backticks, and a backtick inside a
	# single-quoted pattern is what shellcheck reports SC2016 for. Hoisting it
	# into a variable removes the report rather than suppressing it — the
	# pattern this repo's `nix/pre-commit.nix` asks for is to accept the
	# formatter's form rather than widen an exclusion.
	bt='`'
	while IFS= read -r row; do
		id="$(sed -E "s/^\\| *${bt}([^${bt}]+)${bt}.*/\\1/" <<<"${row}")"
		killer="$(awk -F'|' '{print $(NF-1)}' <<<"${row}" | sed -E 's/^ +| +$//g')"
		spec_ids+=("${id}")
		# An em dash in that column means the law is not admitted. Seven laws
		# in that document held one until 2026-09-18.
		if [ -z "${killer}" ] || [ "${killer}" = "—" ] || [ "${killer}" = "-" ] ||
			[ "${#killer}" -lt 15 ]; then
			missing_killers+=("${id}: '${killer}'")
		fi
	done < <(grep -E "^\\| *${bt}${LAW_PREFIX}[0-9]+${bt} *\\|" <<<"${law_section}" || true)

	echo "LAW TABLE, read from ${LAWS_REL} §${LAW_SECTION}: ${#spec_ids[@]} rows"
	if [ "${#spec_ids[@]}" -ne "${LAW_COUNT}" ]; then
		echo "FAIL: §${LAW_SECTION} published ${#spec_ids[@]} ${LAW_PREFIX} rows, expected ${LAW_COUNT}."
		exit 1
	fi

	# THE DECLARED DEFERRALS. Each must be PUBLISHED (or the deferral is about
	# a row that no longer exists) and must be ABSENT from the suite (or the
	# milestone implemented it and the deferral is stale). Both directions,
	# because either alone is satisfied by an empty set.
	deferred_ids=()
	if [ -n "${LAW_DEFERRED}" ]; then
		read -r -a deferred_ids <<<"${LAW_DEFERRED}"
		for d in "${deferred_ids[@]}"; do
			found=0
			for id in "${spec_ids[@]}"; do
				[ "${id}" = "${d}" ] && found=1
			done
			if [ "${found}" -ne 1 ]; then
				echo "FAIL: ${d} is declared DEFERRED by this gate and is not published"
				echo "      in §${LAW_SECTION}. A deferral about a row that does not exist"
				echo "      is a deferral nothing can expire."
				exit 1
			fi
		done
		echo "LAW TABLE: ${#deferred_ids[@]} row(s) declared deferred: ${LAW_DEFERRED}"
	fi
	expected_impl=$((LAW_COUNT - ${#deferred_ids[@]}))
	if [ "${#missing_killers[@]}" -ne 0 ]; then
		echo "FAIL: ${#missing_killers[@]} law(s) in §${LAW_SECTION} carry no killing mutation:"
		printf '      %s\n' "${missing_killers[@]}"
		echo "      §3: 'an arm with no stated killer is not admitted'."
		exit 1
	fi

	# The implementation's side, read out of the suite's own declaration.
	mapfile -t impl_ids < <(sed -n '/^const LawName/,/\]/p' "${LAW_SUITE}" |
		grep -oE "${LAW_PREFIX}[0-9]+" || true)
	echo "LAW TABLE, read from ${LAW_SUITE}: ${#impl_ids[@]} ids"
	if [ "${#impl_ids[@]}" -ne "${expected_impl}" ]; then
		echo "FAIL: the suite declares ${#impl_ids[@]} ${LAW_PREFIX} ids, expected ${expected_impl}"
		echo "      (${LAW_COUNT} published minus ${#deferred_ids[@]} declared deferred)."
		exit 1
	fi
	for d in "${deferred_ids[@]:-}"; do
		[ -z "${d}" ] && continue
		for id in "${impl_ids[@]}"; do
			if [ "${id}" = "${d}" ]; then
				echo "FAIL: ${d} is declared DEFERRED by this gate and the suite runs it."
				echo "      A stale deferral hides the only difference between 'not yet'"
				echo "      and 'never'."
				exit 1
			fi
		done
	done
	# Both directions, separately, and then the cardinality — the last line is
	# the one usually omitted, and without it the two differences are both
	# satisfied by two empty sets.
	# The published set MINUS the declared deferrals is what the suite is
	# compared against. The subtraction is the only thing `LAW_DEFERRED`
	# changes; both directions and the cardinality are unchanged.
	expected_sorted="$(printf '%s\n' "${spec_ids[@]}" | sort -u)"
	for d in "${deferred_ids[@]:-}"; do
		[ -z "${d}" ] && continue
		expected_sorted="$(grep -vxF "${d}" <<<"${expected_sorted}" || true)"
	done
	impl_sorted="$(printf '%s\n' "${impl_ids[@]}" | sort -u)"
	only_spec="$(comm -23 <(echo "${expected_sorted}") <(echo "${impl_sorted}"))"
	only_impl="$(comm -13 <(echo "${expected_sorted}") <(echo "${impl_sorted}"))"
	if [ -n "${only_spec}" ]; then
		echo "FAIL: published in §${LAW_SECTION} and not run by the suite: ${only_spec}"
		exit 1
	fi
	if [ -n "${only_impl}" ]; then
		echo "FAIL: run by the suite and not published in §${LAW_SECTION}: ${only_impl}"
		exit 1
	fi
	if [ "$(wc -l <<<"${expected_sorted}")" -ne "${expected_impl}" ] ||
		[ "$(wc -l <<<"${impl_sorted}")" -ne "${expected_impl}" ]; then
		echo "FAIL: the two law sets agree but are not ${expected_impl} distinct ids."
		exit 1
	fi
	echo "OK: ${LAW_COUNT} laws published, ${#deferred_ids[@]} deferred, ${expected_impl} run, both directions, no duplicates."
fi

total=0
for suite in "${SUITES[@]}"; do
	if [ ! -f "${suite}" ]; then
		echo "FAIL: ${suite} is not in the tree"
		exit 1
	fi
	bin="${TMPDIR:-/tmp}/editor-model-floor-$(basename "${suite}" .nim)"
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
echo "OK: ${MILESTONE_ID}'s suites meet the floor published in the milestone."
