#!/usr/bin/env bash
#
# lint-step-isolation-test.sh — the guard for "a lint script cannot abort before
# reaching a check it claims to run", plus the contract suite for
# ci/lib/lint-steps.sh, which is what makes that property hold.
#
# WHY THIS EXISTS
# ---------------
# Two CI lint scripts were flat `set -e` lists. In both, the first command had
# been failing for a long time, so everything below it was documentation rather
# than a check:
#
#   * ci/lint/bash.sh aborted on a shellcheck style finding, hiding
#     scripts/resolve-sibling-rev-test.sh (89 assertions) and
#     tools/visual-review/deepreview-harness-test.sh (65 contracts). Both pass
#     when run by hand; neither had ever run in CI.
#   * ci/lint/nim.sh aborted on a crashing `just test-nimsuggest`, hiding the
#     test-lane coverage guard — the guard whose entire subject is "tests that
#     do not run but look like they pass".
#
# The class is old and this repo keeps meeting it. What is new is that the
# instrument built to catch the class was itself an instance of it. So the
# property gets a guard of its own, and the guard is behavioural: it does not
# read the lint scripts and judge their style, it RUNS them in a world where
# every external command fails and checks that each one still reports every
# check it declares.
#
# WHAT IT ASSERTS
# ---------------
# Part A — ci/lib/lint-steps.sh honours its contract: a failing step does not
#   abort the run or the caller, every step is reported, the exit status is
#   decided from all of them at the end, and a quarantined step is visible but
#   not fatal. A7-A9 cover the two ways the ACCUMULATOR itself could lose a
#   verdict it had already printed — a second `source` emptying the record, and
#   a `lint_step` or `lint_summary` run in a subshell.
#
# Part B — every script in ci/lint/ is built on that contract and demonstrably
#   survives total failure:
#     B1. it declares at least one step, with a literal name;
#     B2. it ends by calling lint_summary;
#     B3. run with a PATH in which every external command it needs is missing —
#         so EVERY step fails — it still exits non-zero, still prints the
#         summary, names every step it declared, and refused none of them for
#         being in a subshell.
#
#   B3 is the one that catches the real defect. A flat `set -e` script dies at
#   its first command and never mentions the rest, which is precisely the
#   failure being guarded against, reproduced on demand.
#
# Part C — the scanner B1 uses has no blind spot of its own. It reads
#   declarations out of a script's source, and for a long time it read them
#   with `^`-anchored greps, so a `lint_step` behind `if …; then` or `&&` was
#   invisible: unchecked for reporting, and reported as literally named even
#   when it was not. The guard is the enforcement mechanism for the whole
#   property, so its blind spot was the delivery route past every check it
#   makes. Part C drives this script, as a subprocess, over synthetic lint
#   scripts and asserts what it concluded — in both directions, since dropping
#   the anchor must not start reading comments or lookalike identifiers as
#   declarations.
#
# HERMETIC AND CHEAP
#   No toolchain, no network, no repo state beyond ci/ itself. The probe runs
#   each lint script against a throwaway copy of ci/, with cwd inside that copy
#   and an almost-empty PATH, so nothing it does can touch the working tree —
#   which matters because ci/lint/rust.sh writes files when it succeeds.
#
# RED-BEFORE
#   Pass the pre-accumulator versions of the lint scripts as arguments and B1
#   and B3 both fail on them:
#
#     ci/test/lint-step-isolation-test.sh /path/to/old/nim.sh
#
#   With no arguments it checks every ci/lint/*.sh.
#
# MOCKING POLICY
#   (metacraft-dev-guidelines/policies/documentation-conventions.md)
#   Part A drives the real ci/lib/lint-steps.sh; only the STEP BODIES are
#   synthetic (`exit 1`, `exit 78`, `true`), because the contract under test is
#   about how outcomes are aggregated, not about any particular check. Part B
#   runs the real, unmodified ci/lint scripts; nothing about them is stubbed.
#   The empty PATH is not a mock of the tools either — it is the fault being
#   injected, and injecting it is the only way to observe that a later step
#   still reports.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
library="${repo_root}/ci/lib/lint-steps.sh"

checks=0
failures=0

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# ---------------------------------------------------------------------------
# Assertion helpers, in the shape ci/test/test-lane-coverage-test.sh uses.
# ---------------------------------------------------------------------------

pass() {
	checks=$((checks + 1))
	echo "  [OK] $1"
}

fail() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	echo "  [FAILED] $1"
	if [ "$#" -gt 1 ]; then
		shift
		printf '%s\n' "$*" | sed 's/^/        | /'
	fi
}

# assert_status NAME WANT GOT OUTPUT
assert_status() {
	local name="$1" want="$2" got="$3" output="$4"
	if [ "${got}" = "${want}" ]; then
		pass "${name}"
	else
		fail "${name}: expected exit ${want}, got ${got}" "${output}"
	fi
}

# assert_nonzero NAME GOT OUTPUT
assert_nonzero() {
	local name="$1" got="$2" output="$3"
	if [ "${got}" -ne 0 ]; then
		pass "${name}"
	else
		fail "${name}: expected a non-zero exit, got 0" "${output}"
	fi
}

# assert_contains NAME NEEDLE OUTPUT
assert_contains() {
	local name="$1" needle="$2" output="$3"
	if grep -qF -- "${needle}" <<<"${output}"; then
		pass "${name}"
	else
		fail "${name}: output did not contain '${needle}'" "${output}"
	fi
}

# assert_lacks NAME NEEDLE OUTPUT
assert_lacks() {
	local name="$1" needle="$2" output="$3"
	if grep -qF -- "${needle}" <<<"${output}"; then
		fail "${name}: output unexpectedly contained '${needle}'" "${output}"
	else
		pass "${name}"
	fi
}

# run_fixture BODY — writes BODY into a script that sources the real library,
# runs it, and leaves the output in ${fixture_out} and status in ${fixture_rc}.
fixture_out=""
fixture_rc=0
run_fixture() {
	local body="$1"
	local script="${work}/fixture.sh"
	{
		echo '#!/usr/bin/env bash'
		# `set -e` on purpose: a lint script running under errexit must not be
		# aborted by a red step, and that is only observable if the fixture is
		# under errexit too.
		echo 'set -euo pipefail'
		echo "source '${library}'"
		printf '%s\n' "${body}"
	} >"${script}"
	fixture_out="$(bash "${script}" 2>&1)"
	fixture_rc=$?
}

echo "=== Part A — ci/lib/lint-steps.sh contract ==="

# ---------------------------------------------------------------------------
# A1. The headline: a step that fails does not stop the steps after it, and the
#     caller's own `set -e` does not turn a red step into an aborted run.
# ---------------------------------------------------------------------------
run_fixture '
lint_step "first, and red" false
lint_step "second, and green" true
lint_step "third, also red" bash -c "exit 3"
lint_summary
'
assert_contains "a failing first step does not stop the second" \
	"second, and green" "${fixture_out}"
assert_contains "a failing first step does not stop the third" \
	"third, also red" "${fixture_out}"
assert_nonzero "a run with failed steps exits non-zero" \
	"${fixture_rc}" "${fixture_out}"
assert_contains "the summary reports the failure count" \
	"2 FAILED" "${fixture_out}"
assert_contains "a failing step's real exit code is reported" \
	"(exit 3)" "${fixture_out}"

# ---------------------------------------------------------------------------
# A2. All-green stays green.
# ---------------------------------------------------------------------------
run_fixture '
lint_step "a" true
lint_step "b" true
lint_summary
'
assert_status "an all-green run exits 0" 0 "${fixture_rc}" "${fixture_out}"
assert_contains "an all-green run says so" "2 OK" "${fixture_out}"

# ---------------------------------------------------------------------------
# A3. Quarantine: reported, counted, not fatal — and it must not be able to
#     mask a genuine failure elsewhere in the same run.
# ---------------------------------------------------------------------------
run_fixture '
lint_step "known-bad, quarantined" bash -c "exit 78"
lint_step "healthy" true
lint_summary
'
assert_status "a quarantined step alone does not fail the run" \
	0 "${fixture_rc}" "${fixture_out}"
assert_contains "a quarantined step is named as QUARANTINED" \
	"QUARANTINED  known-bad, quarantined" "${fixture_out}"
assert_lacks "a quarantined step is not silently relabelled OK" \
	"OK           known-bad" "${fixture_out}"

run_fixture '
lint_step "known-bad, quarantined" bash -c "exit 78"
lint_step "genuinely broken" false
lint_summary
'
assert_nonzero "a quarantined step does not mask a real failure" \
	"${fixture_rc}" "${fixture_out}"

# ---------------------------------------------------------------------------
# A3b. A step body that is a SHELL FUNCTION running several commands under
#      `set -e` must be decided by the FIRST command that fails, not the last
#      one that runs.
#
#      This is the case the guard could not see at first, and it is the one
#      that bit. Catching the step with `("$@") || rc=$?` looks equivalent and
#      is not: bash suppresses errexit inside an operand of `||` and the
#      subshell INHERITS that suppression, so `set -e; false; true` came back
#      0. Two failing `cargo check --release -D warnings` runs reported OK and
#      the job exited green — a worse outcome than the flat script the library
#      replaced.
#
#      Part B cannot catch it: it makes EVERY command fail, so the last one
#      fails too and a compound body looks correct. Only a body that fails
#      early and succeeds late distinguishes the two.
# ---------------------------------------------------------------------------
run_fixture '
compound_body() {
	set -e
	false
	echo "REACHED THE COMMAND AFTER THE FAILING ONE"
	true
}
lint_step "a multi-command body under set -e" compound_body
lint_summary
'
assert_nonzero "a step body failing at its FIRST command fails the run" \
	"${fixture_rc}" "${fixture_out}"
assert_contains "...and is reported FAILED, not OK" \
	"FAILED       a multi-command body under set -e" "${fixture_out}"
assert_lacks "...and the body really did stop at the failure" \
	"REACHED THE COMMAND AFTER THE FAILING ONE" "${fixture_out}"

# The same body, with the caller NOT under errexit: the step must still be red,
# and the disarm/re-arm must not leave the caller's own options changed.
run_fixture '
set +e
compound_body() {
	set -e
	false
	true
}
lint_step "same body, caller without errexit" compound_body
case $- in
*e*) echo "CALLER ERREXIT LEAKED ON" ;;
esac
lint_summary
'
assert_nonzero "the same body is red when the caller is not under errexit" \
	"${fixture_rc}" "${fixture_out}"
assert_lacks "lint_step does not leave errexit switched on behind it" \
	"CALLER ERREXIT LEAKED ON" "${fixture_out}"

# ---------------------------------------------------------------------------
# A3c. A step with no command at all is a failure, not a pass. An empty
#      subshell exits 0, so a refactor that drops the command would otherwise
#      turn a check into a green no-op — the same bug, one level down.
# ---------------------------------------------------------------------------
run_fixture '
lint_step "a step someone forgot to give a command"
lint_summary
'
assert_nonzero "a step with no command fails the run" \
	"${fixture_rc}" "${fixture_out}"
assert_contains "...and is reported FAILED" \
	"FAILED       a step someone forgot to give a command" "${fixture_out}"

# ---------------------------------------------------------------------------
# A4. Steps are isolated from each other: a step may cd, or set -e, or exit,
#     without changing the ground under the next one.
# ---------------------------------------------------------------------------
# The body is deliberately unexpanded here: `$PWD` and `$here` must be
# evaluated by the fixture, not by this script.
# shellcheck disable=SC2016
run_fixture '
here="$PWD"
lint_step "wanders off" bash -c "cd /"
lint_step "still where it started" bash -c "[ \"\$PWD\" = \"$here\" ]"
lint_summary
'
assert_status "a step that changes directory does not move the next one" \
	0 "${fixture_rc}" "${fixture_out}"

# ---------------------------------------------------------------------------
# A5. A script that declares nothing must not be able to report success. This
#     is the degenerate version of the whole bug: an empty job that prints OK.
# ---------------------------------------------------------------------------
run_fixture '
lint_summary
'
assert_nonzero "a summary with no steps at all fails" \
	"${fixture_rc}" "${fixture_out}"
assert_contains "...and says why" "no steps ran" "${fixture_out}"

# ---------------------------------------------------------------------------
# A6. Every declared step gets exactly one verdict line — no step reported
#     twice, none dropped.
# ---------------------------------------------------------------------------
run_fixture '
lint_step "one" true
lint_step "two" false
lint_step "three" bash -c "exit 78"
lint_summary
'
verdict_lines="$(printf '%s\n' "${fixture_out}" |
	grep -cE '^  (OK|FAILED|QUARANTINED) +' || true)"
if [ "${verdict_lines}" = "3" ]; then
	pass "three declared steps produce exactly three verdict lines"
else
	fail "three declared steps produced ${verdict_lines} verdict lines" "${fixture_out}"
fi

# ---------------------------------------------------------------------------
# A7. Sourcing the library a second time must not empty the report.
#
#     The step arrays used to be reinitialised on every `source`, so a helper
#     that sourced the library after the caller had already recorded steps
#     discarded every verdict collected so far — and the summary then reported
#     the surviving remainder as the whole run. That is the library's own
#     subject matter turned against it: a check that failed, printed `-->
#     FAILED`, and was counted `0 FAILED`.
# ---------------------------------------------------------------------------
run_fixture "
lint_step \"the first check, and it FAILED\" false
source '${library}'
lint_step \"a later check\" true
lint_summary
"
assert_nonzero "a second source does not discard what was already recorded" \
	"${fixture_rc}" "${fixture_out}"
assert_contains "...the failed step recorded before it is still in the report" \
	"FAILED       the first check, and it FAILED" "${fixture_out}"
assert_contains "...and both steps are counted, not just the later one" \
	"2 step(s): 1 OK, 1 FAILED" "${fixture_out}"

# ---------------------------------------------------------------------------
# A8. A step cannot be recorded from a subshell, so it must not be RUN from
#     one either.
#
#     `lint_step` appends to shell arrays. Inside a pipeline stage, a `while
#     read` loop or a command substitution those appends land in a copy that
#     dies with the subshell, so the step used to run, print `--> FAILED`, and
#     be counted by nobody. Nothing the subshell writes can reach the parent,
#     so the misuse is refused where it happens rather than missed where it
#     would be counted: the body does not run, the step is not reported as
#     anything, and the caller is told why.
#
#     The ci/lint scripts run under `set -uo pipefail` — no errexit — so both
#     callers are covered: with errexit the refusal aborts the run, without it
#     the refusal is still loud and the summary still refuses to invent a
#     verdict. B3 below closes the remaining gap for the real scripts.
# ---------------------------------------------------------------------------
run_fixture '
set +e
body_ran() { echo "THE STEP BODY RAN"; return 1; }
lint_step "a real step in the owner shell" true
printf "x\n" | while read -r _; do
	lint_step "a step inside a while-read subshell" body_ran
done
lint_summary
'
assert_contains "a step in a subshell is refused, by name" \
	"lint_step called from a subshell: a step inside a while-read subshell" \
	"${fixture_out}"
assert_lacks "...and its body never runs, so there is no verdict to lose" \
	"THE STEP BODY RAN" "${fixture_out}"
assert_lacks "...and it is not reported OK" \
	"OK           a step inside a while-read subshell" "${fixture_out}"
assert_contains "...and the summary counts only what the owner shell recorded" \
	"1 step(s): 1 OK, 0 FAILED" "${fixture_out}"

# The same misuse with the caller under errexit: fatal, and before the summary
# can print a report that would be missing a check.
run_fixture '
lint_step "a real step in the owner shell" true
printf "x\n" | while read -r _; do
	lint_step "a step inside a while-read subshell" true
done
lint_summary
'
assert_nonzero "under errexit the subshell misuse aborts the run" \
	"${fixture_rc}" "${fixture_out}"
assert_lacks "...before a summary missing that step can be printed" \
	"=== lint summary ===" "${fixture_out}"

# ---------------------------------------------------------------------------
# A9. The mirrored half: `lint_summary` in a subshell.
#
#     Here the records ARE visible — a subshell inherits a copy — so the
#     report would read correctly. What gets lost is the RETURN VALUE, which
#     is the only thing that fails the job: `lint_summary | tee log` under
#     `set -e` without `pipefail` exits with tee's status, so a run with
#     failed steps goes green having printed every one of them. It fails
#     closed rather than warning, because the bare-line call is the documented
#     and B2-enforced form and an unreliable green is the whole subject.
# ---------------------------------------------------------------------------
run_fixture '
set +e
lint_step "a perfectly green step" true
( lint_summary )
echo "SUBSHELL SUMMARY STATUS: $?"
'
assert_contains "lint_summary refuses to decide the run from a subshell" \
	"lint_summary ran in a subshell" "${fixture_out}"
assert_contains "...and returns non-zero rather than an unreliable success" \
	"SUBSHELL SUMMARY STATUS: 1" "${fixture_out}"
assert_lacks "...and prints no report whose status cannot reach the job" \
	"=== lint summary ===" "${fixture_out}"

# ---------------------------------------------------------------------------
# Part B — every ci/lint script is built on that contract and survives total
# failure with its report intact.
# ---------------------------------------------------------------------------

echo
echo "=== Part B — ci/lint/*.sh cannot hide a step ==="

# An almost-empty PATH: the fault injection. `dirname` is linked in because
# every lint script resolves its own repo root with it before it can declare a
# single step; everything else — shellcheck, just, bash, cargo, nix, node — is
# absent, so every step fails and we get to see which ones still report.
stub_bin="${work}/stub-bin"
mkdir -p "${stub_bin}"
ln -sf "$(command -v dirname)" "${stub_bin}/dirname"

# A throwaway copy of ci/, so a lint script that writes files on its way past a
# failure (ci/lint/rust.sh regenerates dap_types.rs) cannot reach the real tree.
probe_root="${work}/probe"
mkdir -p "${probe_root}"
cp -R "${repo_root}/ci" "${probe_root}/ci"

# check_lint_script PATH — B1, B2 and B3 for one script.
check_lint_script() {
	local script="$1"
	local name
	name="$(basename "${script}")"

	echo
	echo "--- ${name}"

	# B1: the steps it declares, read straight out of the source. Requiring a
	# literal name is part of the contract: a step named by a variable could
	# not be checked against the report, and a check whose identity is not
	# fixed at read time is a check nobody can look for in a log.
	#
	# THE SCAN IS NOT ANCHORED TO THE START OF A LINE, and that is the point.
	# Both greps here used to begin `^[[:space:]]*lint_step`, so a declaration
	# behind `if …; then`, `&&` or `;` did not exist as far as this guard was
	# concerned. That is the worst possible place for a blind spot: this file
	# IS the enforcement mechanism for "no step can hide another", so anything
	# it cannot see is a free route past every check it makes — including the
	# "every declared step reported" check below, and the literal-name check,
	# which would report a variable-named step as a literal one.
	#
	# Two things the anchor used to buy for free have to be bought explicitly:
	#   * whole-line comments are dropped first, so a header that SHOWS a
	#     `lint_step "…"` call as an example is not counted as a declaration;
	#   * `(^|[^[:alnum:]_])` keeps `_lint_step_names`, `maybe_lint_step` and
	#     any other identifier that merely ends in `lint_step` from matching.
	local declared=()
	mapfile -t declared < <(grep -vE '^[[:space:]]*#' "${script}" |
		grep -oE '(^|[^[:alnum:]_])lint_step[[:space:]]+"[^"]*"' |
		sed -E 's/^.?lint_step[[:space:]]+"//; s/"$//')

	if [ "${#declared[@]}" -gt 0 ]; then
		pass "${name}: declares ${#declared[@]} step(s) through ci/lib/lint-steps.sh"
	else
		fail "${name}: declares no lint_step — a flat script under 'set -e' stops at its first failure, so every command after that one is documentation, not a check"
	fi

	# Unanchored for the same reason, and comment-stripped by the same means.
	# `grep -nv` keeps the original line numbers on the surviving lines, so the
	# diagnostic still points at the offending line of the real file.
	local dynamic
	dynamic="$(grep -nvE '^[[:space:]]*#' "${script}" |
		grep -E '(^|[^[:alnum:]_])lint_step[[:space:]]+[^"]' || true)"
	if [ -z "${dynamic}" ]; then
		pass "${name}: every step name is a literal, so it can be looked for in a log"
	else
		fail "${name}: a step name is not a literal string" "${dynamic}"
	fi

	# B2
	if grep -qE '^[[:space:]]*lint_summary[[:space:]]*$' "${script}"; then
		pass "${name}: ends its run through lint_summary"
	else
		fail "${name}: never calls lint_summary, so nothing decides the exit status from all the steps"
	fi

	# B3: run it with everything broken.
	local copy="${probe_root}/ci/lint/${name}"
	cp -f "${script}" "${copy}"
	chmod +x "${copy}"

	local out rc
	# `${BASH}` by absolute path: the whole point of the probe is that PATH
	# resolves nothing, and that has to include the interpreter this guard uses
	# to start the script under test.
	out="$(cd "${probe_root}" && PATH="${stub_bin}" "${BASH}" "${copy}" 2>&1)"
	rc=$?

	assert_nonzero "${name}: a run in which every step fails exits non-zero" "${rc}" "${out}"
	assert_contains "${name}: ...and still prints its summary" \
		"=== lint summary ===" "${out}"

	# The behavioural half of A8, for the scripts that matter. A step declared
	# inside a pipeline stage or a `while read` loop is refused by the library
	# and never reaches the report — so the script would run one fewer check
	# than it claims to. The declared-name sweep below cannot catch that on its
	# own: the refusal banner names the step, so the name is present in the
	# output either way. This is the assertion that separates "the step ran and
	# reported" from "the step was refused and merely mentioned".
	assert_lacks "${name}: no step is declared in a subshell, where it could not be recorded" \
		"lint_step called from a subshell" "${out}"

	local missing=() step
	for step in ${declared[@]+"${declared[@]}"}; do
		if ! grep -qF -- "${step}" <<<"${out}"; then
			missing+=("${step}")
		fi
	done
	if [ "${#declared[@]}" -eq 0 ]; then
		# Nothing was declared, so "every declared step reported" is vacuous.
		# The B1 failure above is the finding; do not paper over it with a
		# green line here.
		fail "${name}: cannot check that every step reported — the script declares none"
	elif [ "${#missing[@]}" -eq 0 ]; then
		pass "${name}: every one of its ${#declared[@]} steps still reported"
	else
		fail "${name}: ${#missing[@]} step(s) never reported — an earlier failure hid them: ${missing[*]}" "${out}"
	fi
}

targets=("$@")
run_part_c=0
if [ "${#targets[@]}" -eq 0 ]; then
	mapfile -t targets < <(find "${repo_root}/ci/lint" -maxdepth 1 -name '*.sh' | sort)
	# Part C invokes THIS script with explicit targets. Running it only on the
	# default, whole-suite run is what makes that recursion terminate after one
	# level.
	run_part_c=1
fi

if [ "${#targets[@]}" -eq 0 ]; then
	echo "lint-step-isolation: no ci/lint scripts found — refusing to report success" >&2
	exit 2
fi

for target in "${targets[@]}"; do
	check_lint_script "${target}"
done

# ---------------------------------------------------------------------------
# Part C — the scanner in Part B has no blind spot of its own.
#
# Parts A and B check the library and the lint scripts. Part C checks THIS
# FILE. B1 reads a script's declared steps out of its source, and it used to
# read them with `^`-anchored greps: a `lint_step` that was not the first thing
# on its line simply did not exist as far as this guard was concerned.
#
# That is the worst place in the campaign for a blind spot. This guard IS the
# enforcement mechanism for "no step can hide another", so anything it cannot
# see is a free route past every check it makes — a variable-named step
# reported as a literal one, and a step whose reporting is never verified. The
# anchor made the guard the delivery route for the shapes it exists to catch.
#
# Each case builds a synthetic lint script and runs THIS SCRIPT against it in a
# subprocess, so the synthetic verdicts land in the child's counters rather
# than ours, and asserts what the child concluded. The last two cases are the
# other direction: dropping the anchor must not start counting things that are
# not declarations.
# ---------------------------------------------------------------------------

# write_synthetic_lint_script PATH BODY — a minimal but REAL lint script, built
# on the same repo-root idiom the ci/lint scripts use so that B3's throwaway
# copy resolves the library the same way they do.
write_synthetic_lint_script() {
	local path="$1" body="$2"
	# The single quotes are the point: these lines are the CONTENT of the
	# script being written, and their `$` must be expanded by that script when
	# it runs, not by this one now.
	# shellcheck disable=SC2016
	{
		echo '#!/usr/bin/env bash'
		echo 'set -uo pipefail'
		echo 'repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"'
		echo '# shellcheck source=ci/lib/lint-steps.sh disable=SC1091'
		echo 'source "${repo_root}/ci/lib/lint-steps.sh"'
		printf '%s\n' "${body}"
		echo 'lint_summary'
	} >"${path}"
	chmod +x "${path}"
}

# guard_verdict_on BODY — run this guard, as a child, over a synthetic script
# carrying BODY. Leaves the child's output in ${child_out}.
#
# The child's EXIT STATUS is deliberately not kept: it also reflects Part A,
# which has nothing to do with the synthetic script. Cases read
# assert_child_findings instead, which counts only what the child said about
# the script it was pointed at.
child_out=""
guard_verdict_on() {
	local dir="${work}/part-c"
	mkdir -p "${dir}"
	local script="${dir}/synthetic.sh"
	write_synthetic_lint_script "${script}" "$1"
	child_out="$("${BASH}" "${BASH_SOURCE[0]}" "${script}" 2>&1)"
}

# assert_child_findings NAME WANT OUTPUT — how many things the child found
# wrong WITH THE SYNTHETIC SCRIPT.
#
# Scoped to the `synthetic.sh:` findings on purpose, rather than reading the
# child's exit status. The child also runs Part A, so its exit status answers
# "is the library healthy AND is the scanner right", and a library defect would
# then turn every Part C case red as well — no mutation would fail exactly the
# checks that own it, which is the property this suite is being held to.
assert_child_findings() {
	local name="$1" want="$2" output="$3" got
	got="$(grep -cF '[FAILED] synthetic.sh:' <<<"${output}" || true)"
	if [ "${got}" = "${want}" ]; then
		pass "${name}"
	else
		fail "${name}: expected ${want} finding(s) about the synthetic script, got ${got}" \
			"${output}"
	fi
}

if [ "${run_part_c}" -eq 1 ]; then
	echo
	echo "=== Part C — the guard's own scanner sees every declaration ==="
	echo

	# C1. A declaration that is not the first thing on its line is still a
	#     declaration, and must be counted and checked like any other.
	guard_verdict_on '
lint_step "declared at the start of a line" false
if true; then lint_step "declared behind an if, not at line start" false; fi
'
	assert_contains "a step behind 'if …; then' is counted as declared" \
		"declares 2 step(s)" "${child_out}"
	assert_contains "...and its reporting is verified like any other step's" \
		"every one of its 2 steps still reported" "${child_out}"
	assert_child_findings "...and the guard finds nothing else wrong with it" \
		0 "${child_out}"

	# C2. The one that went green before: a step named by a VARIABLE, placed
	#     off the start of its line. The literal-name contract exists so a
	#     check's identity is fixed at read time and can be looked for in a
	#     log; an anchored scan could not see this and said "every step name is
	#     a literal".
	#
	#     The name is deliberately UNQUOTED, because that is the shape this
	#     check has always been written for. A quoted-but-interpolated
	#     `lint_step "${name}"` reads as a literal to this scan and is caught
	#     one line further down instead, by "every declared step reported" —
	#     the declared name `${name}` never appears in the log.
	#
	# The body is script CONTENT: its `${name}` is for the synthetic script to
	# expand when it runs, not for this script to expand now.
	# shellcheck disable=SC2016
	guard_verdict_on '
name="a name decided at runtime"
lint_step "declared at the start of a line" false
if true; then lint_step ${name} false; fi
'
	assert_contains "a variable-named step off the line start is caught" \
		"a step name is not a literal string" "${child_out}"
	assert_child_findings "...and that is the ONLY thing the guard faults it for" \
		1 "${child_out}"

	# C3. The opposite direction. Dropping the anchor must not make the scanner
	#     read PROSE as code: a header that shows an example `lint_step` call —
	#     which ci/lib/lint-steps.sh's own usage block does — is not a
	#     declaration, and counting it would demand a report line for a step
	#     that does not exist.
	guard_verdict_on '
# Usage, for the next reader:
#   lint_step "an example that is not a real step" some_command
lint_step "the only real step" false
'
	assert_contains "a lint_step shown in a comment is not counted" \
		"declares 1 step(s)" "${child_out}"
	assert_child_findings "...and the commented example demands no report line" \
		0 "${child_out}"

	# C4. The other over-match the anchor used to prevent for free: an
	#     identifier that merely ENDS in lint_step. Without a word boundary,
	#     `maybe_lint_step "…"` would be counted as a declaration of a step
	#     that never reports.
	guard_verdict_on '
maybe_lint_step() { :; }
maybe_lint_step "not a step at all, just a helper with an unlucky name"
lint_step "the only real step" false
'
	assert_contains "an identifier ending in lint_step is not a declaration" \
		"declares 1 step(s)" "${child_out}"
	assert_child_findings "...and the lookalike demands no report line either" \
		0 "${child_out}"

	# C5. The behavioural half of A8, checked on a whole script rather than on
	#     a fixture: a lint script that declares a step inside a subshell must
	#     be failed by B3. The library refuses the step, so the check never
	#     runs, and the script quietly performs one fewer check than it claims
	#     to. The declared-name sweep alone cannot see this — the refusal
	#     banner names the step, so the name appears in the output either way —
	#     which is why B3 asserts the banner's ABSENCE.
	guard_verdict_on '
lint_step "an honest step in the owner shell" false
printf "x\n" | while read -r _; do lint_step "a step inside a while-read subshell" false; done
'
	assert_contains "a lint script that declares a step in a subshell is failed" \
		"[FAILED] synthetic.sh: no step is declared in a subshell" "${child_out}"
	assert_child_findings "...and that is the ONLY thing the guard faults it for" \
		1 "${child_out}"
fi

echo
if [ "${failures}" -eq 0 ]; then
	echo "lint-step isolation: ${checks} check(s) passed across ${#targets[@]} lint script(s)."
	exit 0
fi
echo "lint-step isolation: ${failures} of ${checks} check(s) FAILED" >&2
exit 1
