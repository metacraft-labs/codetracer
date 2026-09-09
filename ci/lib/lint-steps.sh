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
# EVERY CALL BELONGS TO ONE SHELL — the one that sourced this file. The report
# lives in shell arrays, so a `lint_step` inside a pipeline stage or a `while
# read` loop records into a subshell that then exits, and a `lint_summary` in a
# pipeline stage has its exit status swallowed. Both are refused rather than
# documented; see the block above the array declarations for why each one had
# to be caught where it is.
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

# THE RECORD, AND THE TWO WAYS A VERDICT COULD STILL GO MISSING
# -------------------------------------------------------------
# The block below is the accumulator every verdict has to survive in. Two
# shapes could empty it, and both reproduced — through this library — exactly
# the defect the library was written to kill: a step printed `--> FAILED` in
# the log while the job exited 0.
#
#   (1) A SECOND `source`. These three arrays used to be reinitialised on
#       every source, so a helper that sourced this file after the caller had
#       already recorded steps silently discarded every one of them. The
#       initialisation is therefore guarded: sourcing this file again is a
#       no-op, and a re-source cannot erase a verdict.
#
#   (2) A STEP RECORDED IN A SUBSHELL. `lint_step` inside a pipeline stage, a
#       `while read` loop or a command substitution appends to a COPY of the
#       arrays that dies with the subshell. Nothing appended there can reach
#       the parent, so — unlike (1) — this cannot be fixed by making the
#       record survive; it has to be REFUSED where it happens, which is what
#       the BASHPID check at the top of lint_step does. lint_summary carries
#       the mirrored check for the same reason: run as a pipeline stage its
#       non-zero return is swallowed, and a swallowed verdict is the same bug
#       wearing the other hat.
if [ -z "${_LINT_STEPS_SOURCED:-}" ]; then
	_LINT_STEPS_SOURCED=1

	_lint_step_names=()
	_lint_step_verdicts=()
	_lint_step_codes=()

	# The shell that owns the record. Source time is the only moment at which
	# "the shell whose arrays these are" is knowable, so it is captured here
	# and compared against BASHPID at every entry point that depends on it.
	_lint_steps_owner_pid=$BASHPID
fi

# _lint_in_owner_shell — true when the caller is the shell that owns the record.
#
# Defensive about an unset owner pid (someone defining these functions without
# sourcing the file): with nothing to compare against, the check cannot make a
# finding and must not manufacture one.
_lint_in_owner_shell() {
	[ -z "${_lint_steps_owner_pid:-}" ] || [ "${BASHPID}" = "${_lint_steps_owner_pid}" ]
}

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
	# Refuse to run at all from a subshell. A step recorded here would append
	# to a copy of the arrays that dies with this shell, so the check would
	# run, print its verdict, and then be counted by nobody — `--> FAILED` in
	# the log and `0 FAILED` in the summary. There is no way to push the
	# record back into the parent, so the only honest thing to do is not
	# pretend to have recorded it.
	#
	# This is the one path that returns non-zero, and the exception is
	# deliberate: the always-return-0 contract exists so a RED STEP cannot
	# abort the caller, and this is not a red step, it is a caller-side misuse
	# with no result at all. Returning non-zero gives the caller's `set -e` /
	# `pipefail` a chance to turn the misuse into a red job at the point where
	# it can still be read, instead of a green one at the end.
	if ! _lint_in_owner_shell; then
		printf '\n'
		_lint_rule
		printf 'lint_step called from a subshell: %s\n' "${1:-<unnamed step>}"
		_lint_rule
		printf 'lint-steps: refusing to run this step. lint_step appends to shell\n' >&2
		printf 'arrays, so a step run inside a pipeline stage, a while-read loop or a\n' >&2
		printf 'command substitution reports its verdict into a subshell that then exits,\n' >&2
		printf 'and lint_summary would count the run as if the step had never existed.\n' >&2
		printf 'Move the lint_step call into the shell that sourced ci/lib/lint-steps.sh.\n' >&2
		return 2
	fi

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

	# The mirrored subshell check. Here the records ARE visible — a subshell
	# inherits a copy — so the report would read correctly; what gets lost is
	# the RETURN VALUE, which is the only thing that fails the job. `lint_summary
	# | tee log` under `set -e` without `pipefail` exits with tee's status, so a
	# run with failed steps goes green having printed every one of them. Fail
	# closed rather than warn: the bare-line call is the documented and
	# guard-enforced form (ci/test/lint-step-isolation-test.sh's B2), so there is
	# no legitimate caller to break, and an unreliable green is the exact defect
	# this file exists to make impossible.
	if ! _lint_in_owner_shell; then
		printf 'lint-steps: lint_summary ran in a subshell, so its exit status may not\n' >&2
		printf 'reach the job — a run with failed steps could still report success.\n' >&2
		printf 'Call it as a bare lint_summary on its own line, in the shell that\n' >&2
		printf 'sourced ci/lib/lint-steps.sh. Failing the run rather than guessing.\n' >&2
		return 1
	fi

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
