#!/usr/bin/env bash
#
# reachability-ratchet-test.sh — does `--max` bite where it is supposed to?
#
# WHY THIS EXISTS
# ---------------
# `frontend-reachability-guard.py` had no contract suite at all. Its sibling
# `reachability-prose-guard-test.sh` tests the SENTENCES that describe the
# threshold; nothing tested the threshold. That gap is how the defect this file
# was written for survived in the open: `--max` was a `>` and not an `=`, the
# backlog fell from 1228 to 1223 when dead entry points were deleted, and the
# ceiling stayed at 1228 — five free slots, for five new unreached exports that
# could land without reddening `lint-nim`. `ci/lint/nim.sh` said so in its own
# header, in the present tense, for as long as it was true.
#
# It shipped as an EQUALITY on that rule — the shell-gate inventory's, almost
# word for word: slack under a ceiling is a budget. Since 2026-09-12 it is a
# CEILING again, and the slack side is a loud report rather than a failure; arm
# 2 below carries the measurement that decided it.
#
# WHY A SYNTHETIC TREE, AND WHY ITS COUNT IS ASSERTED FIRST
# ---------------------------------------------------------
# Every arm below is a claim about what the guard does at a KNOWN count. Against
# the real `src/frontend` the count is 1078 and moves whenever anyone exports a
# symbol, so an arm written against it would be measuring the tree rather than
# the ratchet — and would go red for reasons that have nothing to do with this
# file. The fixture is four unreached exports in two modules.
#
# THE NON-VACUITY CHECK IS THE FIRST ONE, and it is not a formality: if the
# fixture produced no findings, `--max 0` would pass, `--max 1` would report
# slack, and every arm below would still look like it was working. A suite whose
# subject is empty grades itself.
#
# Run: bash ci/test/reachability-ratchet-test.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${repo_root}/ci/test/frontend-reachability-guard.py"

checks=0
failures=0
ok() {
	checks=$((checks + 1))
	printf '  [OK]     %s\n' "$*"
}
bad() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '  [FAILED] %s\n' "$*"
}

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# Four exported declarations, none of which another module reads. `beta` imports
# `alpha` and calls one of them, which is deliberately NOT enough: `betaEntry` is
# itself unreached, so the guard counts all four. The number is what matters, and
# it is asserted below rather than assumed.
mkdir -p "${work}/src/frontend"
cat >"${work}/src/frontend/alpha.nim" <<'NIM'
import beta

proc reachedByBeta*(): int = 1
proc nobodyReachesMe*(): int = 2
const UnreadValue* = 7
NIM
cat >"${work}/src/frontend/beta.nim" <<'NIM'
import alpha

proc betaEntry*(): int = reachedByBeta()
NIM

run_guard() { python3 "${guard}" --repo-root "${work}" "$@" 2>&1; }

echo "=== reachability ratchet contract — six arms ==="
echo

# ---------------------------------------------------------------------------
# NON-VACUITY. Assert the fixture's count before asserting anything about it.
# ---------------------------------------------------------------------------
base_out="$(run_guard)"
base_rc=$?
fixture_findings="$(printf '%s\n' "${base_out}" |
	grep -oE '^findings *: *[0-9]+' | grep -oE '[0-9]+' | head -1)"
if [ "${fixture_findings:-0}" -eq 4 ]; then
	ok "CONTROL: the fixture produces exactly 4 findings — the arms below have a subject"
else
	bad "CONTROL: the fixture produced ${fixture_findings:-<none>} findings, expected 4"
	printf '%s\n' "${base_out}" | head -8 | sed 's/^/           /'
	echo
	echo "${checks} check(s), ${failures} failure(s)"
	echo "RESULT: FAILED — with the wrong subject every arm below is vacuous"
	exit 1
fi

# And that a bare run still REPORTS rather than enforcing. This is the behaviour
# the ratchet is layered on top of; if it had changed, the arms would be testing
# a different instrument.
if [ "${base_rc}" -eq 0 ] &&
	grep -q 'Reported, not enforced' <<<"${base_out}"; then
	ok "CONTROL: with no --max and no --enforce the guard reports and exits 0"
else
	bad "CONTROL: a bare run did not report-and-exit-0 (rc=${base_rc})"
fi
echo

# ---------------------------------------------------------------------------
# ARM 1 — THE EXACT COUNT PASSES. Without this, arm 3 would be satisfied by a
# guard that simply always fails, and arm 2 by one that never does.
# ---------------------------------------------------------------------------
out="$(run_guard --max 4)"
rc=$?
if [ "${rc}" -eq 0 ] && ! grep -q 'RATCHET' <<<"${out}"; then
	ok "1/the exact count passes: --max 4 over 4 findings exits 0"
else
	bad "1/--max 4 over 4 findings did not pass (rc=${rc})"
	printf '%s\n' "${out}" | grep RATCHET | sed 's/^/           /'
fi

# ---------------------------------------------------------------------------
# ARM 2 — SLACK IS REPORTED AND IS NOT A FAILURE (changed 2026-09-12).
#
# This arm asserted the opposite until 2026-09-12, and the change is a decision
# rather than a relaxation, so the old assertion is quoted rather than deleted:
# it required `--max 5` over 4 findings to EXIT NON-ZERO, on the rule that slack
# under a ceiling is a budget.
#
# What the equality did in practice was measured instead of argued.
# `f274fa68` and `ab7ce4c1` (2026-09-05) carry 1225 findings against a ceiling
# of 1226 and both exit 1: CI was red for five hours because the tree had got
# BETTER, and went green again only when an unrelated commit put the count back
# up to 1226. A gate whose failure asks a developer to undo an improvement — or
# to edit a number in a different file — is the "guard that gets switched off"
# this instrument's own header is about.
#
# So the budget is answered by reporting it loudly rather than by failing on it.
# ARM 2b is what keeps that honest: the report must still name the value, so it
# is actionable rather than decorative. The permanent answer is "no new findings
# in files this change touched" and is recorded in the guard's header; it is a
# repo-wide policy change and is deliberately not implemented here.
# ---------------------------------------------------------------------------
out="$(run_guard --max 5)"
rc=$?
if [ "${rc}" -eq 0 ] && grep -q 'RATCHET SLACK' <<<"${out}"; then
	ok "2/a ceiling with slack under it REPORTS and does not fail: --max 5 over 4 findings exits 0"
else
	bad "2/--max 5 over 4 findings did not report-and-pass (rc=${rc}); a ceiling is not an equality"
	printf '%s\n' "${out}" | tail -4 | sed 's/^/           /'
fi

# And it must say which way to move, by number. "Lower it" without the value is
# the kind of message that gets the ceiling raised instead.
if grep -q 'Lower it to 4' <<<"${out}"; then
	ok "2b/the slack message names the number to lower it to"
else
	bad "2b/the slack message does not name the value (wanted 'Lower it to 4')"
fi

# ---------------------------------------------------------------------------
# ARM 3 — AND THE DIRECTION THAT MATTERS STILL BITES. A new unreached export
# must still redden the lane; relaxing the slack side in 2026-09-12 must not
# have traded one direction for the other, and this is the arm that says so.
# ---------------------------------------------------------------------------
out="$(run_guard --max 3)"
rc=$?
if [ "${rc}" -ne 0 ] && grep -q 'RATCHET: 4 findings exceeds' <<<"${out}"; then
	ok "3/one over the ceiling still FAILS: --max 3 over 4 findings exits ${rc}"
else
	bad "3/--max 3 over 4 findings did not fail for its own reason (rc=${rc})"
	printf '%s\n' "${out}" | tail -3 | sed 's/^/           /'
fi

# ---------------------------------------------------------------------------
# ARM 4 — `--enforce` IS STILL THE HARDER SETTING. It has never been set by any
# caller in this repository, which is worth knowing when reading its verdicts:
# nothing has ever exercised it in CI. This arm is the only thing that does.
# ---------------------------------------------------------------------------
out="$(run_guard --enforce)"
rc=$?
if [ "${rc}" -ne 0 ] && grep -q 'ENFORCE: 4 exported symbols' <<<"${out}"; then
	ok "4/--enforce fails on any finding at all: exits ${rc} over 4"
else
	bad "4/--enforce did not fail over 4 findings (rc=${rc})"
	printf '%s\n' "${out}" | tail -3 | sed 's/^/           /'
fi

echo
echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -gt 0 ]; then
	echo "RESULT: FAILED"
	exit 1
fi
echo "  The ratchet passes at its number and BELOW it, fails above it, and names"
echo "  the value to lower the ceiling to when the tree has got better."
echo "RESULT: OK"
