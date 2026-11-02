#!/usr/bin/env bash
#
# ci-reached-recipes-test.sh — fail, BY NAME, on any `just` recipe listed in
# `ci/test/ci-reached-recipes.txt` that no CI workflow lane reaches.
#
# WHY THIS EXISTS
# ---------------
# `just test-tui` and `just test-tui-real-terminal` are the only routes to the
# `tui` (133 files) and `tui-real-terminal` (64 files) lanes of
# `ci/lib/run-nim-test-lane.sh`, and no workflow called either of them. Measured
# at codetracer `agents` 4b64e0134: nothing under `.github/workflows/` names
# them, and the walk in `ci/test/shell-gate-coverage.sh` reaches 132 of the
# justfile's 376 recipes, neither of these among them.
#
# Every guard that could have said so was green, each for a reason that is
# correct about its own subject:
#
#   * `test-lane-coverage.sh` asks whether a test-shaped Nim file is IN a lane.
#     All 197 are. It does not ask whether any workflow RUNS that lane.
#   * `shell-gate-coverage.sh` walks recipes, but only to reach SCRIPTS. The two
#     recipes invoke `ci/lib/run-nim-test-lane.sh`, which other reached recipes
#     invoke too, so no script went dark and nothing failed.
#   * Until `ed9afd6bc` that walk even counted `test-tui` as reached, because four
#     window gates print `run 'just test-tui' once` as a remedy. A string that
#     names a recipe is not a call that runs it, and the
#     walk stopped crediting it -- which made the recipe honestly unreached,
#     silently, since recipes are not that guard's subject.
#
# This suite makes recipes a subject, for the short list of recipes whose
# reachability is a decision rather than an accident: the ones that are the only
# route to a body of tests CI is meant to run. The TUI's Tier-1 suites are meant
# to run fast, on every pull request, and Tier 2 is its check against real
# terminals, so both lanes run in the `tui-tests` job of `codetracer.yml`, and this
# suite is what fails if either recipe stops being reached.
#
# THE WALK IS NOT REIMPLEMENTED HERE. `shell-gate-coverage.sh
# --print-reached-recipes` prints the recipe set its own Step 2 computes, so a
# recipe is "reached" by exactly the rule a gate is: invoked in command position
# by a workflow step, a composite action a workflow uses, or a reached recipe or
# script -- never by a mention in prose or a quoted string. A second, simpler
# walk here would disagree with that one sooner or later, and the disagreement
# would be read as a finding.
#
# WHAT IS ASSERTED
# ----------------
#   0. The list is non-empty and every listed name is a recipe the justfile
#      defines -- a renamed recipe would otherwise be "unreached" forever while
#      the lane it guarded ran under its new name, or did not.
#   1. POSITIVE CONTROL: the walk reaches `test-cli-record`, which the
#      `viewmodel-tests` job invokes directly, and reaches at least
#      ${REACHED_FLOOR} recipes. A walk that reaches nothing reports every listed
#      recipe unreached, which is the right answer for the wrong reason.
#   2. THE SUBJECT: every listed recipe is in the reached set, or it fails by
#      name.
#   3. NEGATIVE CONTROL: on a copy of the tree with every workflow line that
#      invokes a listed recipe deleted, the same walk must report EVERY listed
#      recipe unreached, BY NAME, while still reaching the positive control.
#      This proves the instrument can see the absence it is here to report, and
#      that the edge it credits is the workflow step and not something else --
#      the arm removes exactly the edge under dispute, nothing more. If a listed
#      recipe stays reached after its workflow lines are gone, it is reached by
#      another route, and the arm says so rather than passing vacuously.
#
# WHAT IS NOT ASSERTED: that the recipes pass, or that a reached step executes
# -- a step behind a false `if:` is reachable and never runs. This measures the
# graph, which is strictly less than the schedule; the same limit
# `shell-gate-coverage.sh` states for itself.
#
# No mocks. The subject is the committed workflows and justfile; the negative
# control is a real copy of them with real lines removed, read by the real walk.
#
# Bash 3.2 compatible (no `mapfile`, no associative arrays), like the guard it
# drives, so it runs on the macOS host bash as well as on CI.
#
# Run:  bash ci/test/ci-reached-recipes-test.sh
# Lane: a step of `ci-contract-suites` in `.github/workflows/codetracer.yml`
#       (stock ubuntu-latest: bash, coreutils, git -- no Nix, no dev shell).

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${repo_root}/ci/test/shell-gate-coverage.sh"
list="${repo_root}/ci/test/ci-reached-recipes.txt"

# A recipe a workflow step invokes directly, by name, in the `viewmodel-tests`
# job (`just test-cli-record`). Chosen because it is reached by the plainest
# edge the walk has; if this ever moves, pick another directly-invoked recipe.
POSITIVE_CONTROL="test-cli-record"
# The walk reached 132 recipes at 4b64e0134. The floor is far below that on
# purpose: it exists to catch a walk that reached nothing, not to pin a count.
REACHED_FLOOR=20

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
finish() {
	echo
	echo "${checks} check(s), ${failures} failure(s)"
	if [ "${failures}" -gt 0 ]; then
		echo "RESULT: FAILED"
		exit 1
	fi
	echo "RESULT: OK"
	exit 0
}

# A here-string, not `printf | grep -q`: under pipefail that pipeline can report
# a present item as absent (see `in_set` in shell-gate-coverage.sh).
in_set() { grep -Fxq -- "$1" <<<"$2"; }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

echo "=== ci-reached-recipes — does a CI lane reach every recipe that must run? ==="
echo

# ---------------------------------------------------------------------------
echo "Step 0: the list names real recipes"
# ---------------------------------------------------------------------------
if [ ! -f "${guard}" ] || [ ! -f "${list}" ]; then
	bad "missing ${guard#"${repo_root}"/} or ${list#"${repo_root}"/}"
	finish
fi
required="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "${list}" |
	grep -v '^$' | sort -u)"
required_count="$(grep -c . <<<"${required}" || true)"
if [ "${required_count}" -ge 1 ]; then
	ok "${required_count} recipe(s) listed in ${list#"${repo_root}"/}"
else
	bad "the list is empty — every check below would pass over nothing"
	finish
fi
# A recipe header is the name at column 0, then optional parameters or
# dependencies, then `:`. Attributes (`[positional-arguments]`) sit on the line
# above and do not matter here.
while IFS= read -r r; do
	if grep -Eq "^${r}([[:space:]][^=]*)?:([^=]|\$)" "${repo_root}/justfile"; then
		ok "\`${r}\` is a recipe the justfile defines"
	else
		bad "\`${r}\` is listed but the justfile defines no such recipe — renamed or deleted?"
	fi
done <<<"${required}"
echo

# `reached_in DIR OUT` — the walk's recipe set for the tree at DIR, into OUT.
# The walk's own report goes to `OUT.log`; it is printed only when the walk
# itself fails, because then it is the only explanation there is.
reached_in() {
	if ! bash "${guard}" --root "$1" --print-reached-recipes >"$2" 2>"$2.log"; then
		bad "the reachability walk failed on $1 — no recipe set to read"
		sed 's/^/           /' "$2.log" | grep -E 'FAILED|unknown|no ' | head -6
		return 1
	fi
}

# ---------------------------------------------------------------------------
echo "Step 1: positive control — the walk reaches recipes, including ${POSITIVE_CONTROL}"
# ---------------------------------------------------------------------------
reached_in "${repo_root}" "${work}/reached" || finish
reached="$(cat "${work}/reached")"
reached_count="$(grep -c . <<<"${reached}" || true)"
if [ "${reached_count}" -ge "${REACHED_FLOOR}" ]; then
	ok "the walk reaches ${reached_count} recipe(s) from the workflows (floor ${REACHED_FLOOR})"
else
	bad "the walk reaches only ${reached_count} recipe(s) — it is broken, and an unreached verdict below would mean nothing"
fi
if in_set "${POSITIVE_CONTROL}" "${reached}"; then
	ok "\`${POSITIVE_CONTROL}\`, invoked directly by a workflow step, is reached"
else
	bad "\`${POSITIVE_CONTROL}\` is not reached — either the control moved or the walk stopped seeing direct steps"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 2: every listed recipe is reached by a CI workflow lane"
# ---------------------------------------------------------------------------
while IFS= read -r r; do
	if in_set "${r}" "${reached}"; then
		ok "\`${r}\` is reached by a CI workflow lane"
	else
		bad "\`${r}\` is reached by NO CI workflow lane — the tests only it runs run nowhere"
	fi
done <<<"${required}"
echo

# ---------------------------------------------------------------------------
echo "Step 3: negative control — without the workflow steps, each is reported unreached"
# ---------------------------------------------------------------------------
# The walk reads `.github/` (workflows and the composite actions they use), the
# justfile, `ci/` and `scripts/`. Those, and nothing else, are copied; a file
# outside them cannot change its answer.
tree="${work}/tree"
mkdir -p "${tree}"
for d in .github ci scripts; do
	cp -R "${repo_root}/${d}" "${tree}/${d}"
done
cp "${repo_root}/justfile" "${tree}/justfile"

# Delete every workflow line that invokes a listed recipe: `just <name>`
# followed by anything that cannot continue a recipe name. Whole lines, because
# the walk does not parse YAML and a half-deleted step is still a step to it.
stripped=0
while IFS= read -r wf; do
	[ -n "${wf}" ] || continue
	cp "${wf}" "${wf}.orig"
	while IFS= read -r r; do
		grep -Ev "just[[:space:]]+${r}([^A-Za-z0-9_-]|\$)" "${wf}" >"${wf}.next" || true
		mv "${wf}.next" "${wf}"
	done <<<"${required}"
	n="$(diff "${wf}.orig" "${wf}" | grep -c '^<' || true)"
	stripped=$((stripped + n))
	rm -f "${wf}.orig"
done < <(find "${tree}/.github/workflows" -type f \( -name '*.yml' -o -name '*.yaml' \))
echo "    ${stripped} workflow line(s) naming \`just <listed recipe>\` removed from the copy (comments included; the walk ignores those either way)"

reached_in "${tree}" "${work}/reached-stripped" || finish
reached_stripped="$(cat "${work}/reached-stripped")"
if in_set "${POSITIVE_CONTROL}" "${reached_stripped}"; then
	ok "the copy still reaches \`${POSITIVE_CONTROL}\` — only the disputed edges were removed"
else
	bad "the copy no longer reaches \`${POSITIVE_CONTROL}\` — the arm removed more than the edge under dispute"
fi
while IFS= read -r r; do
	if in_set "${r}" "${reached_stripped}"; then
		bad "\`${r}\` is still reached with its workflow steps removed — another route reaches it, so this arm cannot show the walk would miss its absence"
	else
		ok "without its workflow steps, \`${r}\` is reported unreached by name"
	fi
done <<<"${required}"

finish
