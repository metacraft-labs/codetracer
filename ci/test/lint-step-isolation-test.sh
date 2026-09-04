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
#   not fatal.
#
# Part B — every script in ci/lint/ is built on that contract and demonstrably
#   survives total failure:
#     B1. it declares at least one step, with a literal name;
#     B2. it ends by calling lint_summary;
#     B3. run with a PATH in which every external command it needs is missing —
#         so EVERY step fails — it still exits non-zero, still prints the
#         summary, and still names every step it declared.
#
#   B3 is the one that catches the real defect. A flat `set -e` script dies at
#   its first command and never mentions the rest, which is precisely the
#   failure being guarded against, reproduced on demand.
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
	local declared=()
	mapfile -t declared < <(grep -oE '^[[:space:]]*lint_step[[:space:]]+"[^"]*"' "${script}" |
		sed -E 's/^[[:space:]]*lint_step[[:space:]]+"//; s/"$//')

	if [ "${#declared[@]}" -gt 0 ]; then
		pass "${name}: declares ${#declared[@]} step(s) through ci/lib/lint-steps.sh"
	else
		fail "${name}: declares no lint_step — a flat script under 'set -e' stops at its first failure, so every command after that one is documentation, not a check"
	fi

	local dynamic
	dynamic="$(grep -nE '^[[:space:]]*lint_step[[:space:]]+[^"]' "${script}" || true)"
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
if [ "${#targets[@]}" -eq 0 ]; then
	mapfile -t targets < <(find "${repo_root}/ci/lint" -maxdepth 1 -name '*.sh' | sort)
fi

if [ "${#targets[@]}" -eq 0 ]; then
	echo "lint-step-isolation: no ci/lint scripts found — refusing to report success" >&2
	exit 2
fi

for target in "${targets[@]}"; do
	check_lint_script "${target}"
done

echo
if [ "${failures}" -eq 0 ]; then
	echo "lint-step isolation: ${checks} check(s) passed across ${#targets[@]} lint script(s)."
	exit 0
fi
echo "lint-step isolation: ${failures} of ${checks} check(s) FAILED" >&2
exit 1
