#!/usr/bin/env bash
#
# shell-gate-coverage-test.sh — does shell-gate-coverage.sh bite?
#
# The convention `ci/lint/nim.sh` states for its Nim sibling: "a guard that has
# only ever been watched printing OK is not evidence. It drives the guard against
# synthetic trees and asserts each of its checks fires by name."
#
# So every arm below builds a SYNTHETIC tree — a few files with the shape the
# guard reads — rather than mutating the real one. Two reasons, and the second is
# the one that decided it:
#
#   * other agents are editing `ci/test/` and `.github/workflows/` concurrently,
#     and an in-place mutate-and-restore would race them;
#   * a synthetic tree lets an arm assert the guard's answer on a KNOWN input.
#     Against the real tree, "13 dark" and "5 dark" both look like a working
#     guard, and the first one was wrong.
#
# That is not hypothetical. The guard's first run over the real tree reported 13
# dark gates; 8 of those were reachable through `ci/lint/*.sh`, which was missing
# from its roots. Its second run reported 63 of 63 reachable, because it had been
# wired up and the walk was following names out of its own DOC COMMENT. Neither
# number was right and both looked plausible. Arms 1 and 5 are those two mistakes,
# frozen.
#
# AND A THIRD, ADDED 2026-09-04, WHICH IS WHY THERE ARE NOW ELEVEN ARMS. The
# guard's steady state — `96 found, 88 reachable, 0 UNRECORDED dark`, green for
# days — was also wrong, and this time in a way none of the six arms could
# catch, because none of them was about the guard's SCOPE. Two blind spots: the
# justfile counted as a CI root, so a gate wired to a recipe no lane calls was
# "covered"; and the scan was `ci/test` at `-maxdepth 1`, so most of the
# repository's shell could not produce a finding at all. Honest figures on the
# same tree: 161 found, 130 reachable, 22 recorded dark. Arms 7 and 8 are those
# two, frozen. Arm 9 is the rule the widening needed to mean anything (a linter
# reads a file; it does not run it), and arms 10 and 11 are the two directions
# of the ratchet that stops the exception list absorbing the next hole.
#
# A NOTE ON WHAT AN ARM IS WORTH. Arm 7's mutation is deliberately generous: a
# real recipe, in the real justfile, with a real `bash` invocation of a real
# file. The ONLY thing wrong with it is that no lane calls the recipe. An arm
# that removes something obviously load-bearing proves less than one that
# removes the single edge under dispute.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${repo_root}/ci/test/shell-gate-coverage.sh"

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

# A minimal tree the guard can read. It has to carry every edge the real walk
# uses, because an arm can only demonstrate a rule the control exercises:
#
#   workflow -> gate                        (gate1..gate10, direct)
#   workflow -> recipe -> dispatcher        (`just lint` -> ci/lint/sh.sh)
#   dispatcher -> gate -> gate              (sh.sh -> gate11 -> gate12)
#   gate -> script outside ci/test          (gate1 -> scripts/wired-tool.sh)
#
# THE LAST TWO ARE THE ONES THIS FILE GAINED ON 2026-09-04, and they are the two
# the guard used to get wrong. `just lint` is now reachable ONLY because a
# workflow calls it — the justfile stopped being a root — and `scripts/` is in
# the universe at all only because the scan stopped being `ci/test -maxdepth 1`.
stage() {
	local d="$1"
	rm -rf "${d}"
	mkdir -p "${d}/.github/workflows" "${d}/ci/test" "${d}/ci/lint" "${d}/scripts"
	local i
	for i in $(seq 1 12); do
		printf '#!/usr/bin/env bash\necho gate%s\n' "${i}" >"${d}/ci/test/gate${i}.sh"
	done
	# Root 1: a workflow naming ten gates directly.
	{
		printf 'name: t\non:\n  push:\njobs:\n  a:\n    steps:\n'
		for i in $(seq 1 10); do
			printf '      - run: bash ci/test/gate%s.sh\n' "${i}"
		done
	} >"${d}/.github/workflows/t.yml"
	# Root 2. TWO workflows, because the guard's non-vacuity floor for roots is
	# two and the justfile no longer counts toward it.
	printf 'name: u\non:\n  push:\njobs:\n  b:\n    steps:\n      - run: just lint\n' \
		>"${d}/.github/workflows/u.yml"
	# The justfile: one recipe a lane calls, one recipe nobody calls. `unwired`
	# is the control's proof that a recipe alone confers nothing — the gate it
	# names does not exist, so if the guard ever credited recipe bodies
	# unconditionally, step 4 would report the missing file.
	printf 'lint:\n  bash ci/lint/sh.sh\n\nunwired:\n  bash ci/test/nobody-calls-this-recipe.sh\n' \
		>"${d}/justfile"
	# A dispatcher, reached through that recipe, that reaches gate11. gate12 is
	# reachable only transitively, through gate11.
	printf '#!/usr/bin/env bash\nbash ci/test/gate11.sh\n' >"${d}/ci/lint/sh.sh"
	printf '#!/usr/bin/env bash\nbash ci/test/gate12.sh\n' >"${d}/ci/test/gate11.sh"
	# A script outside ci/test/, reached from a gate. Without this the widened
	# scan would be untested in the direction that matters most: that a
	# scripts/ file CAN be reachable, and is not dark merely for living there.
	printf '#!/usr/bin/env bash\nbash scripts/wired-tool.sh\n' >"${d}/ci/test/gate1.sh"
	printf '#!/usr/bin/env bash\necho tool\n' >"${d}/scripts/wired-tool.sh"
	printf '# RECORDED-DARK-CEILING: 0\n' \
		>"${d}/ci/test/shell-gate-coverage.known-dark.txt"
}

run_guard() { bash "${guard}" --root "$1" 2>&1; }

echo "=== shell-gate-coverage selftest — eleven arms ==="
echo

# ---------------------------------------------------------------------------
# THE CONTROL. Without a green baseline every red below is unattributable.
# ---------------------------------------------------------------------------
stage "${work}/base"
base_out="$(run_guard "${work}/base")"
if printf '%s' "${base_out}" | grep -q 'RESULT: OK'; then
	ok "CONTROL: a fully-wired synthetic tree is green"
else
	bad "CONTROL: the synthetic tree is already red — no arm can demonstrate anything"
	printf '%s\n' "${base_out}" | grep -E '\[FAILED\]' | head -4 | sed 's/^/           /'
	echo
	echo "${checks} check(s), ${failures} failure(s)"
	echo "RESULT: FAILED"
	exit 1
fi

# The control also has to prove the INDIRECT paths resolved, or the arms below
# would be measuring a guard that only ever sees direct references. Fourteen:
# twelve gates, the dispatcher, and the tool under scripts/.
if printf '%s' "${base_out}" | grep -q '14 reachable'; then
	ok "CONTROL: all 14 scripts resolved — direct, via-recipe, transitive, and outside ci/test/"
else
	bad "CONTROL: the walk did not reach all 14 — an indirect path is not being followed"
	printf '%s\n' "${base_out}" | grep 'gates:' | sed 's/^/           /'
fi

# AND THAT THE RECIPE EDGE IS LOAD-BEARING RATHER THAN DECORATIVE. If the guard
# reached ci/lint/sh.sh some other way, arm 7 below would prove nothing: it
# would be removing an edge that was never carrying anything.
if printf '%s' "${base_out}" | grep -qF 'reaches 1 of 2 recipe(s)'; then
	ok "CONTROL: exactly one recipe is reachable, so the recipe edge is the only way in"
else
	bad "CONTROL: the reachable-recipe count is not 1 — the recipe edge is not what it appears"
	printf '%s\n' "${base_out}" | grep 'recipe' | sed 's/^/           /'
fi
echo

arm() {
	local name="$1" expect="$2"
	shift 2
	stage "${work}/arm"
	"$@" || {
		bad "${name}: the mutation could not be applied"
		return
	}
	local out
	out="$(run_guard "${work}/arm")"
	if printf '%s' "${out}" | grep -q 'RESULT: OK'; then
		bad "${name}: SURVIVED — the guard is still green with the defect in place"
		return
	fi
	if printf '%s' "${out}" | grep -qF -- "${expect}"; then
		ok "${name}: killed"
	else
		bad "${name}: went red, but not for its own reason (wanted: ${expect})"
		printf '%s\n' "${out}" | grep -E '\[FAILED\]' | head -3 | sed 's/^/           /'
	fi
}

# ARM 1 — a gate nothing reaches. The whole point.
m_dark() { printf '#!/usr/bin/env bash\necho x\n' >"${work}/arm/ci/test/nobody-runs-me.sh"; }
arm "1/a gate no root reaches" "nobody-runs-me.sh is reachable from NO workflow" m_dark

# ARM 2 — the ROT check: a root naming a gate that does not exist.
m_rot() { printf '      - run: bash ci/test/deleted-gate.sh\n' >>"${work}/arm/.github/workflows/t.yml"; }
arm "2/a root names a gate that is gone" "which does not exist" m_rot

# ARM 3 — the inventory naming a gate that IS reachable. The both-directions
# rule, which evicted eight wrong entries from the real inventory on its first
# correct run.
m_resurrected() {
	printf '# RECORDED-DARK-CEILING: 1\nci/test/gate1.sh\n' \
		>"${work}/arm/ci/test/shell-gate-coverage.known-dark.txt"
}
arm "3/inventory names a reachable gate" "IS now reachable — delete that line" m_resurrected

# ARM 4 — the CONTRADICTION check: wired up AND declaring it is not a gate.
m_contradiction() {
	printf '#!/usr/bin/env bash\n# NOT-A-CI-GATE: but I am wired anyway\necho x\n' \
		>"${work}/arm/ci/test/gate1.sh"
}
arm "4/reachable and declares it is not a gate" "one of the two is wrong" m_contradiction

# ARM 5 — THE TRAP THIS GUARD WALKED INTO. A gate that merely NAMES another in a
# comment must not make it reachable. Without comment-stripping the guard
# reported 63 of 63 covered while four gates were referenced by nothing.
m_prose() {
	printf '#!/usr/bin/env bash\necho x\n' >"${work}/arm/ci/test/only-named-in-prose.sh"
	printf '# see also only-named-in-prose.sh for the other half\n' \
		>>"${work}/arm/ci/test/gate1.sh"
}
arm "5/a name in a comment does not confer reachability" \
	"only-named-in-prose.sh is reachable from NO workflow" m_prose

# ARM 6 — the non-vacuity floor: a tree with almost no gates must not report a
# clean sweep.
m_empty() { rm -f "${work}/arm"/ci/test/gate*.sh; }
arm "6/an empty scan is not a clean sweep" "the scan is broken" m_empty

# ---------------------------------------------------------------------------
# ARMS 7-11 — the rules added on 2026-09-04. Each is a way the guard reported
# 96/88/0-unrecorded on a tree with thirty-one dark gates in it.
# ---------------------------------------------------------------------------

# ARM 7 — THE ONE THAT MADE THE OLD NUMBER A FICTION. A gate wired to a `just`
# recipe that NO WORKFLOW CALLS is dark. Thirteen real gates were credited this
# way: the noir-* family, the desktop-* family, cli-record-smoke.sh and the rest.
# The mutation is deliberately generous to the guard — the gate is named by a
# real recipe, in the real justfile, with a real `bash` invocation. The only
# thing missing is a lane that calls it.
m_dev_recipe_only() {
	printf '#!/usr/bin/env bash\necho x\n' >"${work}/arm/ci/test/typed-by-hand-only.sh"
	printf '\ndev-only:\n  bash ci/test/typed-by-hand-only.sh\n' >>"${work}/arm/justfile"
}
arm "7/a recipe no lane calls is not a wire" \
	"typed-by-hand-only.sh is reachable from NO workflow lane" m_dev_recipe_only

# ARM 8 — THE OTHER HALF: a dark script OUTSIDE ci/test/. With the old
# `-maxdepth 1` scan the whole of scripts/, ci/lib/, ci/verdict/ and ci/runner/
# could not produce a finding at all, so this arm would have been unkillable.
m_dark_outside() {
	printf '#!/usr/bin/env bash\necho x\n' >"${work}/arm/scripts/nobody-runs-me.sh"
}
arm "8/a dark script outside ci/test/ is still a dark script" \
	"scripts/nobody-runs-me.sh is reachable from NO workflow lane" m_dark_outside

# ARM 9 — A LINTER READS A FILE; IT DOES NOT RUN IT. `ci/lint/bash.sh` lints
# eleven scripts it never executes, and counting that as CI reaching them is the
# same category error as counting a doc comment. Without this rule the widened
# scan finds almost nothing under scripts/.
#
# (The line above says "lints" rather than naming the tool, because a comment
# whose first word IS that tool's name is read as a directive and fails to
# parse. SC1073, found by the lint step this arm is about.)
m_shellcheck_only() {
	printf '#!/usr/bin/env bash\necho x\n' >"${work}/arm/scripts/only-linted.sh"
	printf 'shellcheck scripts/only-linted.sh\n' >>"${work}/arm/ci/lint/sh.sh"
}
arm "9/shellchecking a script is not running it" \
	"scripts/only-linted.sh is reachable from NO workflow lane" m_shellcheck_only

# ARM 10 — THE INVENTORY CANNOT GROW QUIETLY. A genuinely dark gate, genuinely
# recorded with a reason — and the ceiling left where it was. This is the
# cheapest way to silence this guard, and it is the one the old design allowed.
m_ceiling_growth() {
	printf '#!/usr/bin/env bash\necho x\n' >"${work}/arm/ci/test/newly-dark.sh"
	printf '# RECORDED-DARK-CEILING: 0\n# a reason\nci/test/newly-dark.sh\n' \
		>"${work}/arm/ci/test/shell-gate-coverage.known-dark.txt"
}
arm "10/recording a new dark gate without raising the ceiling" \
	"a NEW dark gate was recorded" m_ceiling_growth

# ARM 11 — AND IT CANNOT KEEP SLACK EITHER. A ceiling above the entry count is a
# budget: it lets the next dark gate be added with no diff to the number at all.
# The ratchet has to tighten itself or it only works once.
m_ceiling_slack() {
	printf '# RECORDED-DARK-CEILING: 3\n' \
		>"${work}/arm/ci/test/shell-gate-coverage.known-dark.txt"
}
arm "11/a ceiling with slack under it is a budget" \
	"lower it to 0" m_ceiling_slack

echo
echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -gt 0 ]; then
	echo "RESULT: FAILED — every arm must be killed by the rule written for it"
	exit 1
fi
echo "  The guard reports each hole, and a name in a comment is not a wire."
echo "RESULT: OK"
