#!/usr/bin/env bash
#
# grep-q-pipefail-gate.sh — no shell in this repository may pipe a producer
# into `grep -q` while `pipefail` is in force.
#
# THE DEFECT
# ----------
# `grep -q` exits the instant it matches. If the haystack is larger than a pipe
# buffer the producer is still writing when the pipe closes, takes EPIPE, and
# dies of SIGPIPE (141). Under `set -o pipefail` the pipeline adopts that
# status, so
#
#     printf '%s' "$haystack" | grep -q needle
#
# RETURNS A SUCCESSFUL MATCH AS A FAILURE.
#
# THE THRESHOLD, MEASURED RATHER THAN ASSUMED, because it decides whether any
# given site is failing today or merely waiting to. With the needle on line 1:
#
#     8/16/32/48/56/60/61/62/63 KB -> sees the needle
#     64/96/256 KB                 -> MISSES it, pipeline exit 141
#
# 64 KiB, the pipe buffer, exactly. Two consequences worth stating plainly:
#
#   * BELOW 64 KiB THE CONSTRUCTION IS CORRECT. Most sites in this repository
#     are below it today. They are latent, not live, and anyone auditing this
#     work should not be told otherwise.
#   * The needle must also be found EARLY. `grep` reads to the end of a line
#     before it can match, so a single 128 KB line with no newline does not
#     trigger it; a 64 KB log whose first line matches does, every time.
#
# Latent is still worth fixing, and the reason is the direction of the error
# rather than its likelihood. Where the condition is inverted — where a MATCH
# is the failure, as in `if <found the thing that must not be here>; then fail`
# — the EPIPE answer is the PASSING one. The day such a site crosses 64 KiB it
# starts reporting a clean result and nothing anywhere says so. A false red
# announces itself; a false green is found by accident or not at all.
#
# WHY A LINT AND NOT JUST A FIX
# -----------------------------
# It has already cost this repository real time in both directions:
#
#   * FALSE RED. `ci/test/shell-gate-coverage.sh`'s membership test reported
#     three unreachable gates on `dev` while the same tree reported one
#     locally; two of the three were reachable all along. That failed
#     `lint-nim`, which gates every build job.
#
#   * FALSE GREEN, which is worse and is why this file exists rather than
#     another one-line fix. `ci/test/noir-build-mutations.sh` asked "is the
#     baseline suite already red?" with this construction. A red Nim suite
#     prints a failure dump, so its output is large and its first `[FAILED]`
#     sits near the top — the exact shape that takes EPIPE. The question
#     answered "no", and 27 mutation arms then ran against a baseline that was
#     already broken, reporting coverage they did not have.
#
# One site was fixed. Roughly a hundred and thirty were not, and nothing stopped
# the hundred and thirty-first being written tomorrow. That is what a lint is
# for: the fix is cheap, remembering to apply it is not.
#
# THE FIX, in every case, is to remove the pipe rather than to defeat the race:
#
#     grep -q needle <<<"$haystack"                 # variable haystack
#     grep -q needle <<<"$(producer)"               # command haystack
#     [ -n "$(find ... -print -quit)" ]             # "is there any output"
#
# A here-string is a file, not a pipe: there is nothing to break, so there is
# no EPIPE and no pipefail interaction. It is bash 3.2 compatible, which the
# CI hosts require.
#
# WHAT THIS GATE DOES NOT COVER, said plainly so nobody reads more into a pass:
#   * other early-exiting consumers (`head -n1`, `head -c`, `sed -n '1p;1q'`)
#     have the same EPIPE behaviour and are not scanned;
#   * a pipeline split across lines so that `grep -q` begins a line with no
#     leading `|` is not seen;
#   * it is a textual scan, so it cannot tell a live `grep -q` from one inside
#     a here-doc. Whole-line comments ARE excluded, because this file and
#     several others describe the defect in prose.
#
# Run:  bash ci/test/grep-q-pipefail-gate.sh
# Exit: 0 clean, 1 a violation or a stale inventory entry, 2 could not run.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2

INVENTORY="ci/test/grep-q-pipefail.known-remaining.txt"

# The detector's own test cases, kept in a `.txt` and not in a here-doc inside
# this file. That is not tidiness: this script is one of the files the scan
# below covers, and an inline fixture made the gate report its own test data as
# seven violations the moment it was committed. The fixture must live somewhere
# the scan does not look.
FIXTURE_FILE="ci/test/grep-q-pipefail-gate.fixture.txt"

# A producer piped into a grep whose flags ask it to exit on first match.
#
# `(^|[^|])` is what keeps `a || grep -q x file` — a logical OR in front of a
# grep that reads a FILE, which is correct code — out of the results. The
# repeated flag group lets `grep -F -q` and `grep -Fxq` both be seen, while
# still requiring the quiet flag to be a FLAG word rather than text inside the
# pattern argument.
PATTERN='(^|[^|])\|[[:space:]]*grep([[:space:]]+-[A-Za-z]+)*[[:space:]]+(-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)([[:space:]]|$)'

failures=0

ok() { echo "  [OK]     $*"; }
bad() {
	echo "  [FAILED] $*"
	failures=$((failures + 1))
}

# scan_file FILE -> `<line-number><TAB><trimmed line>` for every violation.
# Whole-line comments are dropped here rather than by the caller, so the
# self-test below exercises the same exclusion the real scan uses.
scan_file() {
	grep -nE "${PATTERN}" "$1" 2>/dev/null |
		grep -vE '^[0-9]+:[[:space:]]*#' |
		sed -e 's/^\([0-9]*\):[[:space:]]*/\1	/' -e 's/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
echo "=== no producer may be piped into 'grep -q' under pipefail ==="
echo

# ---------------------------------------------------------------------------
# STEP 0: THE DETECTOR IS ABLE TO SAY YES AND ABLE TO SAY NO.
#
# A scanner whose regex has rotted finds nothing and reports a clean repository.
# That is the same class of defect this gate exists to catch, so the detector is
# run against a fixture carrying one of each shape before it is trusted with the
# real tree: every HIT row must be found and every MISS row must not be. This
# is the part that makes a green run mean something.
#
# The verdict travels with the case (`HIT<TAB>line`) rather than sitting in a
# separate list of line numbers here, so adding a case cannot leave it
# unasserted and reordering the fixture cannot silently retarget an assertion.
# ---------------------------------------------------------------------------
echo "Step 0: the detector fires on the defect and stays quiet on the fix"

if [ ! -f "${FIXTURE_FILE}" ]; then
	bad "${FIXTURE_FILE} is missing — the detector cannot be checked, so nothing below is evidence"
	echo
	echo "RESULT: FAILED — no fixture"
	exit 1
fi

fixture="$(mktemp)" || exit 2
trap 'rm -f "${fixture}"' EXIT

# Column 2 of every HIT/MISS row, in order, is the file the detector is run
# against; the row's line number in that file is its index here.
cases="$(grep -E '^(HIT|MISS)	' "${FIXTURE_FILE}" || true)"
case_count="$(grep -c . <<<"${cases}" || true)"
cut -f2- <<<"${cases}" >"${fixture}"

# A fixture that lost its cases would make every assertion below vacuous, and
# this gate is precisely the one that must not pass vacuously.
if [ "${case_count}" -lt 10 ]; then
	bad "${FIXTURE_FILE} yields only ${case_count} case(s); it is supposed to carry both verdicts and every shape"
	echo
	echo "RESULT: FAILED — the fixture proves nothing"
	exit 1
fi

fixture_hits="$(scan_file "${fixture}" | cut -f1)"
detector_ok=1
hits_expected=0
n=0
while IFS= read -r row; do
	n=$((n + 1))
	[ -n "${row}" ] || continue
	verdict="${row%%	*}"
	text="${row#*	}"
	if grep -qx "${n}" <<<"${fixture_hits}"; then fired=1; else fired=0; fi
	if [ "${verdict}" = "HIT" ]; then
		hits_expected=$((hits_expected + 1))
		if [ "${fired}" -eq 0 ]; then
			bad "the detector MISSED a planted defect — it would not catch this:"
			echo "             ${text}"
			detector_ok=0
		fi
	elif [ "${fired}" -eq 1 ]; then
		bad "the detector FIRED on correct code:"
		echo "             ${text}"
		detector_ok=0
	fi
done <<<"${cases}"

if [ "${detector_ok}" -eq 1 ]; then
	ok "the detector found all ${hits_expected} planted defect(s) and none of the $((case_count - hits_expected)) correct form(s)"
else
	echo
	echo "RESULT: FAILED — the detector does not work, so the scan below means nothing"
	exit 1
fi
echo

# ---------------------------------------------------------------------------
# STEP 1: the subject list is non-empty.
#
# A scan over no files reports a perfectly clean repository.
#
# UNTRACKED-BUT-NOT-IGNORED FILES ARE IN THE SUBJECT LIST, and that is the
# whole point of this block rather than a refinement of it.
#
# This gate used to enumerate `git ls-files` alone. On a developer's machine
# that is exactly the wrong set: the files a commit is about are the ones still
# untracked, so the local run skipped precisely the code under test and printed
# `RESULT: OK — 377 file(s) scanned, ... 0 new`. It read as a clean tree. It was
# a clean scan OF NOTHING RELEVANT.
#
# That is not hypothetical. It is how the three `grep -q` defects inside
# ci/test/sourced-var-collision-gate.sh reached CI: a local run of THIS gate
# was consulted first and reported the tree clean, because that gate's files
# had not been `git add`ed yet. Two of the three sat inside that gate's own
# self-test assertions, where a pipefail-swallowed match inverts the verdict of
# the check that exists to stop the gate decaying into a no-op.
#
# `--others --exclude-standard` is the safe widening, and the only safe one: it
# respects .gitignore, so it cannot wander into `node_modules/`, `target/` or a
# `result*` Nix out-link, and it stays empty on a CI checkout — `actions/checkout`
# produces a fully-tracked tree, so `subject_count` there is unchanged. A
# filesystem walk was deliberately NOT used; widening a lint's scan set to the
# filesystem is what `shopt -s globstar` did in this repository, and it
# dark-gated every build job for 13 runs.
#
# THE COUNT IS THE TELL, NEVER THE VERDICT. `0 new` looks identical whether the
# scan covered your files or none of them. `subject_count` is printed on the OK
# path for that reason: it is the only number that distinguishes the two.
# ---------------------------------------------------------------------------
echo "Step 1: there is something to scan"

subject_pathspec=('*.sh' 'justfile' '.github/workflows/*.yml' '.github/workflows/*.yaml')
subjects="$({
	git ls-files -- "${subject_pathspec[@]}" 2>/dev/null
	git ls-files --others --exclude-standard -- "${subject_pathspec[@]}" 2>/dev/null
} | sort -u)"
subject_count="$(grep -c . <<<"${subjects}" || true)"
untracked_count="$(grep -c . <<<"$(git ls-files --others --exclude-standard -- "${subject_pathspec[@]}" 2>/dev/null)" || true)"

if [ "${subject_count}" -lt 100 ]; then
	bad "found only ${subject_count} shell subject(s); this repository has hundreds"
	echo
	echo "RESULT: FAILED — the subject list is implausible, so a clean scan proves nothing"
	exit 1
fi
ok "${subject_count} shell subject(s) to scan (${untracked_count} untracked, not yet committed)"
echo

# ---------------------------------------------------------------------------
# STEP 2: the inventory of sites this gate does not yet own.
#
# NOT an exemption list, and it fails in BOTH directions. A recorded site that
# is still there is reported and tolerated; a recorded site that has been FIXED
# fails this gate by name and demands its line be deleted — so an entry cannot
# outlive the defect it records. Same rule, and the same reason, as
# ci/test/shell-gate-coverage.known-dark.txt.
#
# Entries are `<path><TAB><the offending line, trimmed>`. Line NUMBERS are
# deliberately not part of the key: an entry must not go stale because somebody
# added a comment forty lines above it.
# ---------------------------------------------------------------------------
echo "Step 2: recorded sites are still exactly what the inventory says"

known=""
if [ -f "${INVENTORY}" ]; then
	known="$(grep -vE '^[[:space:]]*(#|$)' "${INVENTORY}" || true)"
fi
known_count="$(grep -c . <<<"${known}" || true)"
echo "         ${INVENTORY} records ${known_count} site(s)"

# Every violation in the tree, as `<path><TAB><trimmed line>`, computed once.
found=""
for f in ${subjects}; do
	[ -f "${f}" ] || continue
	hits="$(scan_file "${f}")"
	[ -n "${hits}" ] || continue
	while IFS= read -r hit; do
		[ -n "${hit}" ] || continue
		found="${found}${f}	${hit#*	}
"
	done <<<"${hits}"
done

stale=0
if [ -n "${known}" ]; then
	while IFS= read -r entry; do
		[ -n "${entry}" ] || continue
		if ! grep -Fxq -- "${entry}" <<<"${found}"; then
			bad "the inventory records a site that is no longer there:"
			echo "             ${entry}"
			echo "           It has been fixed, or the line was edited. Delete the entry —"
			echo "           an inventory that only ever grows stops describing this repo."
			stale=$((stale + 1))
		fi
	done <<<"${known}"
fi
if [ "${stale}" -eq 0 ] && [ "${known_count}" -gt 0 ]; then
	ok "all ${known_count} recorded site(s) still exist and still read as recorded"
elif [ "${known_count}" -eq 0 ]; then
	ok "the inventory is empty — no site is exempt"
fi
echo

# ---------------------------------------------------------------------------
# STEP 3: no violation outside the inventory.
# ---------------------------------------------------------------------------
echo "Step 3: no producer is piped into 'grep -q'"

new=0
if [ -n "${found}" ]; then
	while IFS= read -r hit; do
		[ -n "${hit}" ] || continue
		if grep -Fxq -- "${hit}" <<<"${known}"; then continue; fi
		if [ "${new}" -eq 0 ]; then
			echo
			echo "  A pipeline ending in 'grep -q' returns a SUCCESSFUL MATCH AS FAILURE"
			echo "  whenever the producer is still writing when grep exits. Rewrite each"
			echo "  of these as a here-string:"
			echo
			# Literal remedy text, printed verbatim. Single-quoted because
			# shfmt -s rewrites the double-quoted-with-escapes form to this
			# one; shellcheck then reads the `$var` it contains as an
			# unexpanded expression. Both tools run as pre-commit hooks here,
			# so the pair only settles with the quoting shfmt wants and this
			# directive for shellcheck.
			# shellcheck disable=SC2016
			echo '      grep -q PAT <<<"$var"        or        grep -q PAT <<<"$(producer)"'
			echo
		fi
		printf '    %s\n' "${hit}"
		new=$((new + 1))
	done <<<"${found}"
fi

if [ "${new}" -gt 0 ]; then
	echo
	bad "${new} new site(s) pipe a producer into 'grep -q'"
else
	ok "no site outside the inventory pipes a producer into 'grep -q'"
fi

# ---------------------------------------------------------------------------
echo
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — ${subject_count} file(s) scanned (${untracked_count} untracked), ${known_count} recorded site(s), 0 new"
	exit 0
fi
echo "RESULT: FAILED — ${failures} problem(s)"
exit 1
