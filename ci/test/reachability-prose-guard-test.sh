#!/usr/bin/env bash
#
# reachability-prose-guard-test.sh — the contract suite for
# `assert_reachability_prose_agrees` in `ci/lint/nim.sh`.
#
# WHY THIS EXISTS
# ---------------
# The guard it covers asserts that three SENTENCES agree with one NUMBER: the
# `lint_step` label in `ci/lint/nim.sh`, the quoted invocation in
# `ci/test/frontend-reachability.sh`'s header, and that header's "so N+1
# findings fail and N do not". A guard over prose is the easiest kind to write
# so that it can never fail — one unmatchable regex and it reports OK forever,
# over exactly the drift it was added to stop.
#
# That is not hypothetical here. The first draft interpolated the file being
# READ into the pattern that matches the quoted invocation, so pointing it at a
# copy made the match impossible and every verdict below came back FAILED for
# the instrument's reason rather than the arm's. The unmutated control caught
# it. Which is the whole argument for running the arms before trusting the
# guard.
#
# HOW IT WORKS
# ------------
# The guard reads `CT_PROSE_SETTER_FILE` and `CT_PROSE_HEADER_FILE`, defaulting
# to the two real files. Each arm copies both, mutates ONE sentence, and asserts
# the guard's verdict. The control arm mutates nothing and must pass — an arm
# suite whose control is red grades the instrument, not the product.
#
# Usage:  bash ci/test/reachability-prose-guard-test.sh
# Exit:   0 every arm behaved, 1 otherwise, 2 could not run.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
cd "${repo_root}" || exit 2

nim_sh="ci/lint/nim.sh"
reach_sh="ci/test/frontend-reachability.sh"
[ -f "${nim_sh}" ] && [ -f "${reach_sh}" ] || {
	echo "reachability-prose-guard-test.sh: cannot find ${nim_sh} / ${reach_sh}" >&2
	exit 2
}

# THE FUNCTION UNDER TEST, LIFTED FROM THE FILE THAT SHIPS IT rather than
# copied here. A copy would drift, and a suite covering a copy of the guard
# proves nothing about the guard.
fn_src="$(sed -n '/^assert_reachability_prose_agrees() {/,/^}/p' "${nim_sh}")"
# A HERE-STRING, NOT A PIPE. `producer | grep -q PAT` returns a successful
# match AS FAILURE whenever the producer is still writing when `grep` exits and
# `pipefail` is set — which this file sets on line 8. The failure is racy and
# size-dependent, so it hides on a short function and appears when the function
# grows past a pipe buffer, at which point this suite would refuse to run and
# blame a rename. `ci/test/grep-q-pipefail-gate.sh` is the standing check;
# this was the one site it had left to report.
if ! grep -q 'CT_PROSE_HEADER_FILE' <<<"${fn_src}"; then
	echo "reachability-prose-guard-test.sh: could not lift" >&2
	echo "  assert_reachability_prose_agrees out of ${nim_sh}. If it was renamed or" >&2
	echo "  its overrides removed, this suite is covering nothing — fix it here." >&2
	exit 2
fi
eval "${fn_src}"

work="${TMPDIR:-/tmp}/ct-reachability-prose-arms.$$"
rm -rf "${work}"
mkdir -p "${work}" || exit 2
trap 'rm -rf "${work}"' EXIT

checks=0
failures=0

ck() {
	local verdict="$1"
	shift
	checks=$((checks + 1))
	if [ "${verdict}" = ok ]; then
		echo "  [OK]     $*"
	else
		echo "  [FAILED] $*"
		failures=$((failures + 1))
	fi
}

reset_copies() {
	cp "${nim_sh}" "${work}/nim.sh"
	cp "${reach_sh}" "${work}/reach.sh"
}

# Runs the guard against the copies and echoes `pass` or `fail`. The guard's own
# diagnostics go to stderr and are dropped: this suite grades the VERDICT, and
# printing four lines of correct complaint per arm buries it.
verdict() {
	if CT_PROSE_SETTER_FILE="${work}/nim.sh" \
		CT_PROSE_HEADER_FILE="${work}/reach.sh" \
		assert_reachability_prose_agrees >/dev/null 2>&1; then
		echo pass
	else
		echo fail
	fi
}

# Every mutation asserts it changed something. A `perl -pi -e` whose pattern
# stopped matching leaves the file identical, and the arm would then be grading
# the control while reporting on a mutant.
mutate() {
	local file="$1" script="$2" what="$3" before after
	before="$(cksum <"${file}")"
	# SLURP MODE, deliberately. The header sentence this suite mutates is
	# WRAPPED — "so 1229" ends one line and "findings fail" begins the next,
	# behind a `# ` — so a line-at-a-time substitution silently matched nothing
	# and two arms reported "changed nothing" instead of grading the guard.
	# The patterns below spell the gap as `[\s#]*` so they survive a re-wrap.
	perl -0777 -pi -e "${script}" "${file}"
	after="$(cksum <"${file}")"
	if [ "${before}" = "${after}" ]; then
		echo "  [FAILED] the arm '${what}' changed nothing — it would grade the control" >&2
		checks=$((checks + 1))
		failures=$((failures + 1))
		return 1
	fi
	return 0
}

echo "=== the ratchet's prose guard can observe its own failures ==="
echo

# ---------------------------------------------------------------------------
# THE CONTROL. Unmutated copies must pass, or nothing below means anything.
# ---------------------------------------------------------------------------
reset_copies
ck "$([ "$(verdict)" = pass ] && echo ok || echo no)" \
	"control: the tree as it stands passes (an arm suite with a red control grades the instrument)"

# ---------------------------------------------------------------------------
# THE ARM THIS GUARD EXISTS FOR: a ceiling raised on its own.
# ---------------------------------------------------------------------------
reset_copies
if mutate "${work}/nim.sh" 's/CT_REACHABILITY_MAX=\d+/CT_REACHABILITY_MAX=9999/' \
	"raise the ceiling and touch no prose"; then
	ck "$([ "$(verdict)" = fail ] && echo ok || echo no)" \
		"a raise that touches no sentence FAILS — the defect this guard was added for"
fi

# ---------------------------------------------------------------------------
# ONE SENTENCE AT A TIME. Three arms, because a guard that reads only one of
# the three would pass all of the remaining two's drift.
# ---------------------------------------------------------------------------
reset_copies
if mutate "${work}/nim.sh" 's/\(ratchet at \d+/(ratchet at 1/' \
	"stale step label"; then
	ck "$([ "$(verdict)" = fail ] && echo ok || echo no)" \
		"a stale step LABEL fails, with the setter and the header both correct"
fi

reset_copies
if mutate "${work}/reach.sh" 's/CT_REACHABILITY_MAX=\d+ bash/CT_REACHABILITY_MAX=1 bash/' \
	"stale quoted invocation"; then
	ck "$([ "$(verdict)" = fail ] && echo ok || echo no)" \
		"a stale QUOTED INVOCATION in the header fails, with the label correct"
fi

reset_copies
# shellcheck disable=SC2016  # `${1}` and `${2}` are PERL capture groups, and
# must reach perl unexpanded; double quotes would blank them and the arm would
# delete the number instead of changing it.
if mutate "${work}/reach.sh" 's/(so[\s#]*)\d+([\s#]*findings fail)/${1}1${2}/' \
	"stale fail-side number"; then
	ck "$([ "$(verdict)" = fail ] && echo ok || echo no)" \
		"a stale 'so N findings fail' fails, with the invocation it follows correct"
fi

reset_copies
# shellcheck disable=SC2016  # perl capture groups again, for the reason above.
if mutate "${work}/reach.sh" 's/(and[\s#]*)\d+([\s#]*do not\.)/${1}1${2}/' \
	"stale pass-side number"; then
	ck "$([ "$(verdict)" = fail ] && echo ok || echo no)" \
		"a stale 'and N do not' fails — both sides of the boundary are read, not one"
fi

# THE OFF-BY-ONE IS ASSERTED, not assumed. `so N findings fail` must be the
# ceiling PLUS ONE, and a header saying the ceiling itself fails describes a
# guard that would reject its own passing tree.
#
# The ceiling is READ, not spelled out here: a suite that hard-codes 1228 goes
# stale on the next raise, which is the disease the guard under test treats.
reset_copies
ceiling="$(grep -oE 'CT_REACHABILITY_MAX=[0-9]+' "${nim_sh}" | grep -oE '[0-9]+' | head -1)"
if [ -z "${ceiling}" ]; then
	ck no "could not read the ceiling out of ${nim_sh} to build the off-by-one arm"
elif mutate "${work}/reach.sh" \
	"s/(so[\\s#]*)\\d+([\\s#]*findings fail)/\${1}${ceiling}\${2}/" \
	"fail-side equals the ceiling"; then
	ck "$([ "$(verdict)" = fail ] && echo ok || echo no)" \
		"a header claiming the ceiling ITSELF fails is rejected (it is '>' , not '>=')"
fi

# ---------------------------------------------------------------------------
# THE GUARD MUST NOT PASS OVER NOTHING. A check whose subject has been renamed
# away should fail, not report OK over a file it can no longer find anything in.
# ---------------------------------------------------------------------------
reset_copies
if mutate "${work}/nim.sh" 's/CT_REACHABILITY_MAX=/CT_REACHABILITY_RENAMED=/g' \
	"delete the setter"; then
	ck "$([ "$(verdict)" = fail ] && echo ok || echo no)" \
		"with NO setter to read the guard fails rather than passing vacuously"
fi

# ---------------------------------------------------------------------------
# AND IT MUST NOT BE BRITTLE ABOUT LAYOUT. Re-wrapping the paragraph with the
# numbers intact is not drift, and a guard that reddens over it gets deleted.
# ---------------------------------------------------------------------------
reset_copies
if python3 - "${work}/reach.sh" <<'PY'; then
import re, sys

# DERIVED, NOT SPELLED OUT. An arm that hard-codes today's ceiling fails
# confusingly on the next legitimate raise, which is the same disease as the
# stale prose this suite protects. So: find the sentence by its SHAPE, keep
# every number in it, and re-flow it onto one word per line.
path = sys.argv[1]
lines = open(path, encoding="utf-8").read().split("\n")
start = next((i for i, l in enumerate(lines)
              if re.search(r"`env CT_REACHABILITY_MAX=\d+ bash", l)), None)
if start is None:
    raise SystemExit("the re-wrap arm found no quoted invocation — it would grade the control")
end = start
while end + 1 < len(lines) and "do not." not in lines[end]:
    end += 1
if "do not." not in lines[end]:
    raise SystemExit("the re-wrap arm found no 'do not.' terminator — it would grade the control")

sentence = " ".join(l.lstrip("#").strip() for l in lines[start:end + 1])
rewrapped = ["# " + w for w in sentence.split(" ") if w]
if len(rewrapped) <= (end - start + 1):
    raise SystemExit("the re-wrap arm did not change the layout — it would grade the control")
open(path, "w", encoding="utf-8").write("\n".join(lines[:start] + rewrapped + lines[end + 1:]))
PY
	ck "$([ "$(verdict)" = pass ] && echo ok || echo no)" \
		"the same numbers re-wrapped one word per line still PASS (layout is not drift)"
else
	ck no "the re-wrap arm could not be applied"
fi

echo
echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — the prose guard fails for each sentence on its own, and only for drift"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
