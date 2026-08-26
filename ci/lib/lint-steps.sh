#!/usr/bin/env bash
#
# lint-steps.sh — the shared "run every check, then report" driver for the
# scripts under ci/lint/.
#
# WHY THIS EXISTS
# ---------------
# Every lint script used to be a flat list of commands under `set -e`. That
# shape has one failure mode and it is not a small one: the FIRST failing
# command decides how much of the job ever runs. Everything written below it is
# documentation, not a check.
#
# It bit us twice, in the two scripts that were supposed to be the safety net:
#
#   * ci/lint/bash.sh aborted on a style finding (SC2001) in its very first
#     command, so `scripts/resolve-sibling-rev-test.sh` (89 assertions) and
#     `tools/visual-review/deepreview-harness-test.sh` (65 contracts) had never
#     executed in CI. 154 assertions, green in principle, unrun in practice.
#
#   * ci/lint/nim.sh aborted on `just test-nimsuggest`, so the test-lane
#     coverage guard below it — the guard whose entire purpose is to catch
#     "tests that do not run but look like they pass" — had itself never run.
#
# So the rule this file exists to enforce: NO SINGLE FAILING STEP CAN PREVENT
# ANOTHER STEP FROM RUNNING OR FROM REPORTING. One run of the job tells a
# reader the outcome of every check it claims to make, and the job's exit
# status is decided at the end, from all of them.
#
# Usage:
#
#   set -uo pipefail
#   source ci/lib/lint-steps.sh
#
#   lint_step "shellcheck: ci scripts" shellcheck ci/**/*.sh
#   lint_step "test-lane coverage"     bash ci/test/test-lane-coverage.sh
#
#   lint_summary
#
# Ordering is still yours to choose, and still matters for a different reason:
# a reader watching the log should learn about the cheap, always-runnable
# failures first. Put the pure-bash guards ahead of anything that needs a
# compiler. They no longer HIDE what follows them, but they still reach the log
# sooner.
#
# QUARANTINE
# ----------
# A step whose command exits with LINT_STEP_QUARANTINE_RC (78) is reported as
# QUARANTINED: visible in the summary, counted, but not fatal. This is for a
# check that is red for a reason outside this repo — an upstream toolchain
# defect we cannot fix — where deleting the check would lose the intent and
# leaving it fatal would train everyone to ignore the job.
#
# The decision belongs to the CHECK, not to the caller: only the check knows
# how to tell "the toolchain is broken" from "our code broke". A step that
# cannot make that distinction has no business being quarantined. See
# ci/test/nimsuggest-check.sh for the worked example — it probes the toolchain
# with a file this repo did not write, and returns 78 only when that probe
# fails too, so the quarantine retires itself the moment the toolchain is
# fixed.
#
# A STEP BODY MAY BE A SHELL FUNCTION RUNNING SEVERAL COMMANDS UNDER `set -e`,
# and the first one to fail decides the step. Getting that right took a specific
# piece of care — see the comment on the errexit handling in lint_step, and
# ci/test/lint-step-isolation-test.sh's "a multi-command body under set -e"
# case, which is the shape that caught it.
#
# This library deliberately uses shell builtins only (no date, no sed, no
# grep). ci/test/lint-step-isolation-test.sh drives the ci/lint scripts with a
# PATH in which every external command fails, and that probe is only meaningful
# if the driver itself still works there.

# The exit status a check uses to say "I am red for a reason this repo cannot
# fix, and I have proved it". Anything else non-zero is an ordinary failure.
LINT_STEP_QUARANTINE_RC=78

# Marker lines. The isolation guard greps for these, so they are part of the
# contract rather than decoration.
LINT_SUMMARY_HEADER='=== lint summary ==='

_lint_step_names=()
_lint_step_verdicts=()
_lint_step_codes=()

# _lint_rule — the banner separating steps in the log.
_lint_rule() {
	printf '###############################################################################\n'
}

# _lint_record NAME VERDICT RC — the one place a step enters the report.
_lint_record() {
	_lint_step_names+=("$1")
	_lint_step_verdicts+=("$2")
	_lint_step_codes+=("$3")
}

# lint_step NAME COMMAND [ARGS...]
#
# Runs COMMAND, records its verdict, and ALWAYS returns 0 so that a caller
# running under `set -e` cannot be aborted by a step. The verdict is decided in
# lint_summary, from every step at once.
#
# NAME must be a literal double-quoted string: it is the identity of the check
# in the summary, and ci/test/lint-step-isolation-test.sh reads the declared
# names straight out of the script to assert every one of them reported.
lint_step() {
	if [ "$#" -lt 2 ]; then
		# A step with no command runs an empty subshell and would otherwise be
		# recorded OK — a refactor that drops the command would go green in
		# silence, which is the bug this whole library exists to prevent, one
		# level up. Record it as a failure rather than returning non-zero, so
		# it cannot abort the steps after it either.
		_lint_record "${1:-<unnamed step>}" FAILED 2
		printf '\n'
		_lint_rule
		printf '%s\n' "${1:-<unnamed step>}"
		_lint_rule
		printf -- '--> FAILED (%s, exit 2, no command given to lint_step)\n' \
			"${1:-<unnamed step>}"
		return 0
	fi

	local name="$1"
	shift

	printf '\n'
	_lint_rule
	printf '%s\n' "${name}"
	_lint_rule

	local started=${SECONDS}
	local rc=0

	# Disarm errexit around the call rather than catching the step with `|| rc=$?`.
	#
	# This is not a style choice and the obvious spelling is wrong. Bash
	# suppresses errexit inside any command that is an operand of `||`, AND THE
	# SUPPRESSION IS INHERITED BY A SUBSHELL — re-issuing `set -e` inside does
	# not re-arm it:
	#
	#   $ bash -c 'rc=0; ( set -e; false; echo reached; true ) || rc=$?; echo $rc'
	#   reached
	#   0
	#
	# With `|| rc=$?`, a step body that is a shell function running several
	# commands under `set -e` reports only its LAST command's status. That made
	# two failing `cargo check --release -D warnings` runs report OK and the job
	# exit 0 — strictly worse than the flat script this library replaced, which
	# at least aborted loudly on the first one.
	#
	# Turning errexit off around a plain command substitution has no such
	# inheritance, so the subshell's own `set -e` behaves normally and the first
	# failing command in a compound body decides the step.
	local _lint_restore_errexit=0
	case $- in
	*e*)
		_lint_restore_errexit=1
		set +e
		;;
	esac

	# A subshell so a step may cd, pushd or set -e without leaking any of it
	# into the driver or into the next step.
	("$@")
	rc=$?

	if [ "${_lint_restore_errexit}" -eq 1 ]; then
		set -e
	fi

	local elapsed=$((SECONDS - started))

	local verdict
	if [ "${rc}" -eq 0 ]; then
		verdict=OK
	elif [ "${rc}" -eq "${LINT_STEP_QUARANTINE_RC}" ]; then
		verdict=QUARANTINED
	else
		verdict=FAILED
	fi

	_lint_record "${name}" "${verdict}" "${rc}"

	printf -- '--> %s (%s, exit %s, %ss)\n' "${verdict}" "${name}" "${rc}" "${elapsed}"
	return 0
}

# lint_summary
#
# Prints every step and its verdict, then returns non-zero if any step FAILED.
# Quarantined steps are listed and explained but do not decide the status.
#
# Call this as the LAST line of a lint script, as `lint_summary` — under
# `set -e` its non-zero return is what fails the job.
lint_summary() {
	local failed=0 quarantined=0 passed=0
	local i

	printf '\n'
	_lint_rule
	printf '%s\n' "${LINT_SUMMARY_HEADER}"
	_lint_rule

	if [ "${#_lint_step_names[@]}" -eq 0 ]; then
		printf 'no steps ran — this script declared no lint_step at all\n' >&2
		return 1
	fi

	for i in "${!_lint_step_names[@]}"; do
		printf '  %-12s %s (exit %s)\n' \
			"${_lint_step_verdicts[$i]}" \
			"${_lint_step_names[$i]}" \
			"${_lint_step_codes[$i]}"
		case "${_lint_step_verdicts[$i]}" in
		OK) passed=$((passed + 1)) ;;
		QUARANTINED) quarantined=$((quarantined + 1)) ;;
		*) failed=$((failed + 1)) ;;
		esac
	done

	printf '\n  %s step(s): %s OK, %s FAILED, %s QUARANTINED\n' \
		"${#_lint_step_names[@]}" "${passed}" "${failed}" "${quarantined}"

	# Deliberately not starting this note with a verdict word: the lines above
	# are the machine-readable report, one per step, and a prose line that
	# began "QUARANTINED ..." would read as a fourth step to anything counting
	# them — including ci/test/lint-step-isolation-test.sh.
	if [ "${quarantined}" -gt 0 ]; then
		printf '\n  Note: quarantined steps ran and reported. They are red for a reason\n'
		printf '  outside this repo, and each one names what would make it fatal again.\n'
	fi

	if [ "${failed}" -gt 0 ]; then
		printf '\n%s FAILED\n' "${failed}" >&2
		return 1
	fi

	printf '\nOK\n'
	return 0
}
