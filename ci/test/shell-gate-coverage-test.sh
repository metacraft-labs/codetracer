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
# AND A THIRD, ADDED 2026-09-04, WHICH IS WHY THERE WERE THEN ELEVEN ARMS. The
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
# AND A FOURTH, LATER THE SAME DAY, WHICH IS WHY THERE WERE THEN THIRTEEN. With
# the justfile-as-root fix already landed, the guard printed `143 reachable` and
# `RESULT: OK` — and two of those 143 were credited by a mention rather than a
# wire, which no arm could see because arms 5 and 9 only cover comments and
# linters. Arm 12 is `resolve` reading `index() == 0` (not found) as a suffix
# match whenever two same-basename paths are the same LENGTH; it credited
# `ci/test/rust.sh`, an orphan referenced nowhere in the repository, to
# `ci/lint/rust.sh`. Arm 13 is a `paths:` trigger filter read as a step; two such
# entries in `beam-flow.yml` were the only references to a deprecated shim.
#
# Both were found by attributing every one of the 143 credits to the line that
# made it, which is the measurement this file exists to make unnecessary next
# time. Figures after that step: 172 found, 141 reachable, 10 declared
# not-a-gate, 21 recorded dark — the dark inventory did NOT grow, because one
# gate was deleted as dead and one declared not-a-gate in its own header.
#
# AND A SIXTH, ON 2026-09-06, WHICH IS ARMS 15, 15b AND 15c — and this one had
# already cost the build chain a night. The guard went RED on `dev` demanding
# that `ci/test/worker-backend-wasm-e2e.sh` be DELETED from the recorded-dark
# inventory, because 295f36835 had added an assignment and two reads of it to a
# meta-test. Nothing in that commit builds the WASM engine; the gate was as dark
# as the day it was recorded. `lint-nim` gates `nix-build`, so eleven build and
# release jobs were skipped behind a demand to retire a truthfully recorded
# blocker.
#
# `refs_of_text` was extracting EVERY path token on every non-comment line, and
# arm 9 was the only thing holding that up — by dropping lines that name one of
# eight linters. A blacklist of readers is unbounded (grep, cat, head, cp, diff,
# echo, a Python docstring), and every name missing from it fails silently and
# green. The rule is now POSITIONAL: a path counts when it stands where a
# command goes — first word of a command, or the argument of `bash`/`node`/
# `source`/`python3`. `shellcheck x.sh` needs no special case any more, which is
# why arm 9 still passes with the blacklist deleted.
#
# 15b and 15c are the controls that rule needs, and they are not decorative:
# twenty-nine suites here name their subject in a VARIABLE and then run it, and
# three browser probes are run by a local wrapper that executes its `$2`. A
# position rule without them would have invented dark gates by the dozen, which
# is how a guard gets switched off.
#
# Honest figures, same tree: 236 found, 196 reachable, 10 declared not-a-gate,
# 30 recorded dark, 0 UNRECORDED. Reachable fell by four and the recorded-dark
# CEILING DID NOT MOVE: the four were `worker-backend-wasm-e2e.sh` (already
# recorded, and now counted as such), and three files that are not gates and now
# say so in their own headers — the canonical text of an inline pre-checkout
# step, and the two fixtures a text-scanning gate greps.
#
# AND A FIFTH, WHICH IS WHY THERE ARE NOW FIFTEEN, and it is the same sentence
# as blind spot (b) with one word changed: the scan was `-name '*.sh'`. 43 gates
# under `ci/` and `scripts/` are Node or Python and none of them could produce a
# finding. Twelve were dark; three were referenced NOWHERE, not even in a
# comment. Arms 14 and 14b are that, frozen, one per extension — widening the
# `find` and widening the token regex in `refs_of_text` are separate edits and
# either alone leaves half the subject invisible.
#
# ARM 14c IS THE CONTROL THAT MAKES 14 AND 14b MEAN ANYTHING: a `.mjs` a
# reachable gate actually invokes must still be CREDITED. Without it both arms
# are satisfied by a guard that calls every non-shell file dark, which would be
# a worse instrument than the one being replaced.
#
# Honest figures, same tree, same day: 216 found, 172 reachable, 11 declared
# not-a-gate, 33 recorded dark, 0 UNRECORDED. The ceiling moved 21 -> 33 in the
# open, which is the rule at the top of the inventory working as written.
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

# EVERY MATCH BELOW IS A HERE-STRING, NOT `printf | grep -q`. Under the
# `set -uo pipefail` on line 26 that pipeline reports FALSE FOR A MATCH THAT IS
# PRESENT: `grep -q` exits at its first hit, `printf` takes EPIPE, and pipefail
# adopts printf's failure. The guard this file tests carries the same note at
# `in_set`, and the failure mode is specific to a suite like this one: a false
# negative here reads as "this arm SURVIVED", which is a mutation test reporting
# that the guard is broken when the guard is fine.

# The banner carried a count of the arms, and the count went stale the first
# time an arm was added — it read "fifteen" over nineteen. The run prints the
# real number of checks at the end; a claim that has to be maintained by hand to
# stay true is exactly what this suite exists to distrust.
echo "=== shell-gate-coverage selftest — mutation arms ==="
echo

# ---------------------------------------------------------------------------
# THE CONTROL. Without a green baseline every red below is unattributable.
# ---------------------------------------------------------------------------
stage "${work}/base"
base_out="$(run_guard "${work}/base")"
if grep -q 'RESULT: OK' <<<"${base_out}"; then
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
if grep -q '14 reachable' <<<"${base_out}"; then
	ok "CONTROL: all 14 scripts resolved — direct, via-recipe, transitive, and outside ci/test/"
else
	bad "CONTROL: the walk did not reach all 14 — an indirect path is not being followed"
	printf '%s\n' "${base_out}" | grep 'gates:' | sed 's/^/           /'
fi

# AND THAT THE RECIPE EDGE IS LOAD-BEARING RATHER THAN DECORATIVE. If the guard
# reached ci/lint/sh.sh some other way, arm 7 below would prove nothing: it
# would be removing an edge that was never carrying anything.
if grep -qF 'reaches 1 of 2 recipe(s)' <<<"${base_out}"; then
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
	if grep -q 'RESULT: OK' <<<"${out}"; then
		bad "${name}: SURVIVED — the guard is still green with the defect in place"
		return
	fi
	if grep -qF -- "${expect}" <<<"${out}"; then
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

# ---------------------------------------------------------------------------
# ARMS 12-13 — the two ways the guard still over-credited on 2026-09-04, after
# the justfile-as-root fix had already landed. Both are MENTION READ AS WIRE,
# the same category as arms 5 and 9, and neither was visible as a wrong number:
# the run said `143 reachable` and `RESULT: OK` with both defects in place.
# ---------------------------------------------------------------------------

# ARM 12 — TWO GATES, ONE BASENAME, EQUAL PATH LENGTH. `resolve` tested for a
# suffix with `index(q, "/" tok) == length(q) - length(tok)`, and `index()`
# returns 0 when it does not match — which is the SAME value the right-hand side
# takes whenever the two paths are the same length. So `ci/lint/sh.sh` being
# wired credited `ci/test/sh.sh`, which nothing references.
#
# This is not hypothetical: it is exactly how `ci/test/rust.sh` (15 chars) rode
# in on `ci/lint/rust.sh` (15 chars) for as long as it existed. `ci/build/nix.sh`
# (15) and `ci/lint/nix.sh` (14) differ in length, which is the only reason that
# pair never showed it.
#
# The fixture is deliberately the tightest case: `ci/lint/sh.sh` is the wired
# dispatcher the CONTROL already proves is the only way in, and `ci/test/sh.sh`
# is its equal-length twin with no reference anywhere.
m_equal_length_twin() {
	printf '#!/usr/bin/env bash\necho x\n' >"${work}/arm/ci/test/sh.sh"
}
arm "12/an equal-length basename twin is not a wire" \
	"ci/test/sh.sh is reachable from NO workflow lane" m_equal_length_twin

# ARM 13 — A `paths:` FILTER IS A TRIGGER, NOT A STEP. Listing a script under
# `on: push: paths:` decides whether the workflow STARTS when that file changes.
# It never runs it. This is rule 3 one step further along than arm 9: a linter at
# least opens the file.
#
# Measured on the real tree: two `paths:` entries in `beam-flow.yml` were the
# only references to `ci/test/elixir-flow-cross-repo.sh` in the whole repository,
# and they made a deprecated shim with no in-tree caller report as covered.
m_paths_filter_only() {
	printf '#!/usr/bin/env bash\necho x\n' >"${work}/arm/ci/test/only-watched.sh"
	printf "      - 'ci/test/only-watched.sh'\n" \
		>>"${work}/arm/.github/workflows/t.yml"
}
arm "13/a paths: trigger filter is not a wire" \
	"ci/test/only-watched.sh is reachable from NO workflow lane" m_paths_filter_only

# ARM 14 — A GATE IS NOT ONLY A SHELL SCRIPT. The scan was `-name '*.sh'`, which
# is the THIRD instance of this guard's own recurring defect, after "the justfile
# was a root" and "the scan was one directory". 43 gates under `ci/` are Node or
# Python — Playwright browser probes, pure-python3 guards, the
# `noir-wasm-worker/` harness — and none of them could produce a finding.
# Twelve were dark, and three of those were referenced NOWHERE, not even by a
# comment. `mode_layout_probe.mjs` is the one that stings: it measures the
# rendered `.lm_title` geometry that went to zero in the defect it covers, and
# has never run.
#
# BOTH new extensions are mutated, because widening the `find` and widening the
# TOKEN REGEX in `refs_of_text` are two separate edits and either alone leaves
# half the subject invisible.
m_nonshell_dark() {
	printf '// a probe nothing runs\nconsole.log("x");\n' \
		>"${work}/arm/ci/test/orphan_probe.mjs"
	printf '# a guard nothing runs\nprint("x")\n' \
		>"${work}/arm/ci/test/orphan_guard.py"
}
arm "14/a dark .mjs is still a dark gate" \
	"ci/test/orphan_probe.mjs is reachable from NO workflow lane" m_nonshell_dark
arm "14b/a dark .py is still a dark gate" \
	"ci/test/orphan_guard.py is reachable from NO workflow lane" m_nonshell_dark

# AND THE OTHER DIRECTION FOR THE SAME WIDENING: a non-shell gate that IS
# invoked must be credited, or arm 14 is satisfied by a guard that simply calls
# every `.mjs` dark. This is the control arm 14 needs, and it is why the
# mutation below is expected to leave the tree GREEN — so it is asserted
# directly rather than through `arm`, which requires a red.
stage "${work}/arm"
printf '// a probe a wired gate runs\nconsole.log("x");\n' \
	>"${work}/arm/ci/test/wired_probe.mjs"
printf '#!/usr/bin/env bash\nnode ci/test/wired_probe.mjs\n' \
	>"${work}/arm/ci/test/gate2.sh"
nonshell_out="$(run_guard "${work}/arm")"
if grep -q 'RESULT: OK' <<<"${nonshell_out}"; then
	ok "14c/a .mjs invoked by a reachable gate IS credited (the widening is not a blanket)"
else
	bad "14c/a .mjs invoked by a reachable gate was reported dark — the widening invents holes"
	printf '%s\n' "${nonshell_out}" | grep -E '\[FAILED\]' | head -3 | sed 's/^/           /'
fi

# ---------------------------------------------------------------------------
# ARMS 15 — READING A FILE IS NOT RUNNING IT, AND ARM 9 ONLY EVER SAID THAT
# ABOUT ONE TOOL.
#
# On 2026-09-06 the guard demanded that `ci/test/worker-backend-wasm-e2e.sh` be
# DELETED from the recorded-dark inventory — "IS now reachable" — because
# 295f36835 added three lines to `stale-artefact-guards-test.sh`:
#
#     WORKER_E2E="${SUITE_ROOT}/ci/test/worker-backend-wasm-e2e.sh"
#     grep -q wasm_engine_assert_fresh "${WORKER_E2E}"
#     assert_not_contains "$(cat "${WORKER_E2E}")" ...
#
# An assignment and two reads. Nothing in that commit builds the WASM engine and
# nothing executes the gate, so it was as dark as the day it was recorded — and
# the guard, gating `lint-nim` and through it eleven build jobs, went red until
# somebody retired a truthfully recorded blocker on a false premise.
#
# Arm 9 could not catch this. It drops lines by TOOL NAME, and the tools that
# read a file are unbounded: grep, cat, head, tail, cp, diff, echo, a Python
# docstring. The rule is now positional — a path counts when it stands where a
# command goes — and these three arms pin both edges of it.
m_read_only_reference() {
	printf '#!/usr/bin/env bash\necho x\n' >"${work}/arm/ci/test/only-read.sh"
	# shellcheck disable=SC2016  # the ${...} here is TEXT WRITTEN INTO THE
	# FIXTURE, not a value this suite wants: the fixture has to contain the
	# literal read that fooled the guard, so it must not expand here.
	{
		printf 'READ_ONLY_GATE="ci/test/only-read.sh"\n'
		printf 'grep -q needle "${READ_ONLY_GATE}"\n'
		printf 'cat "${READ_ONLY_GATE}"\n'
		printf 'head -5 ci/test/only-read.sh\n'
		printf 'echo "see ci/test/only-read.sh for the rules"\n'
	} >>"${work}/arm/ci/test/gate2.sh"
}
arm "15/a gate only assigned, grepped, catted and echoed is not a wire" \
	"ci/test/only-read.sh is reachable from NO workflow lane" m_read_only_reference

# 15b — THE CONTROL THE ARM ABOVE REQUIRES, and the reason the fix is two passes
# rather than "ignore assignments". Twenty-nine contract suites in this tree name
# their subject in a variable and then RUN it, and a rule that dropped the
# assignment would have invented a dark gate for every one of them.
stage "${work}/arm"
printf '#!/usr/bin/env bash\necho x\n' >"${work}/arm/ci/test/run-via-var.sh"
# shellcheck disable=SC2016  # written into the fixture verbatim, as above.
{
	printf 'RUN_GATE="ci/test/run-via-var.sh"\n'
	printf 'bash "${RUN_GATE}" --root "${TMP}"\n'
} >>"${work}/arm/ci/test/gate2.sh"
via_var_out="$(run_guard "${work}/arm")"
if grep -q 'RESULT: OK' <<<"${via_var_out}"; then
	ok "15b/a gate RUN through the variable that names it IS credited"
else
	bad "15b/a gate run as \${VAR} was reported dark — the position rule dropped a real wire"
	printf '%s\n' "${via_var_out}" | grep -E '\[FAILED\]' | head -3 | sed 's/^/           /'
fi

# 15c — AND THROUGH A LOCAL WRAPPER. `chord-and-pane-uniqueness.sh` runs three
# browser probes as `probe <label> ci/test/<probe>.mjs /noir`, and `probe` is its
# own function: the path is an ARGUMENT, and only the function body says whether
# that argument is executed or read. It executes `$2`; `expect_leak` in
# `sourced-var-collision-gate.sh` greps `$1`. Without this the position rule
# calls all three probes dark.
stage "${work}/arm"
printf '// a probe a wrapper runs\nconsole.log("x");\n' \
	>"${work}/arm/ci/test/via_wrapper_probe.mjs"
# shellcheck disable=SC2016  # `$1`, `$2` and `${script}` are the FIXTURE
# function's own parameters, resolved when the guard reads that file.
{
	printf 'probe() {\n'
	printf '\tlocal label="$1" script="$2"\n'
	printf '\tnode "${script}" "${label}"\n'
	printf '}\n'
	printf 'probe chords ci/test/via_wrapper_probe.mjs /noir\n'
} >>"${work}/arm/ci/test/gate2.sh"
wrapper_out="$(run_guard "${work}/arm")"
if grep -q 'RESULT: OK' <<<"${wrapper_out}"; then
	ok "15c/a gate a local wrapper EXECUTES as \$2 IS credited"
else
	bad "15c/a gate run by a local wrapper was reported dark — the position rule stops at the call"
	printf '%s\n' "${wrapper_out}" | grep -E '\[FAILED\]' | head -3 | sed 's/^/           /'
fi

echo
echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -gt 0 ]; then
	echo "RESULT: FAILED — every arm must be killed by the rule written for it"
	exit 1
fi
echo "  The guard reports each hole, and a name in a comment is not a wire."
echo "RESULT: OK"
