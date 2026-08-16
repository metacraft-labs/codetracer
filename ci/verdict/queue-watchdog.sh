#!/usr/bin/env bash
#
# queue-watchdog.sh — fail a run that is not being SERVICED, without waiting
# for GitHub's 24-hour queue ceiling.
#
# WHY THIS EXISTS
# ---------------
# `ci-verdict` answers "did the required jobs run?", but it can only answer it
# once every job it declares `needs:` on has reached a conclusion. When a job
# never gets a runner, it does not fail and it does not finish: it sits
# `queued` until GitHub cancels it at the 24-hour ceiling. Neither of GitHub's
# two timers helps — the 24h limit applies to a job WAITING for a runner, and
# `timeout-minutes` applies to a job that has STARTED — and a job starved of a
# runner is in neither state.
#
# So the verdict, which is correct when it arrives, arrives about a day after
# the push. That is indistinguishable from "CI is still thinking" for the whole
# of that day, and the `ci-verdict` job header already had to warn readers not
# to mistake a missing verdict for a passing one. This watchdog exists so that
# warning has a deadline attached: a run that nothing is servicing is called
# within minutes instead of within a day.
#
# WHAT IT DETECTS, AND WHY THIS PREDICATE
# ---------------------------------------
#   STALLED := no job in this run is `in_progress`
#              AND at least one job in this run is `queued`
#
# If nothing is running, nothing can finish; if nothing can finish, no queued
# job's dependencies can become satisfied. A run in that state will not advance
# on its own no matter how long it is given. That is a deadlock, and it is
# exactly the state the churning-runner outage produces: GitHub hands a queued
# job to an ephemeral instance, marks it busy, the instance dies without
# executing anything, and the run sits with everything queued and nothing
# running.
#
# The predicate deliberately does NOT try to decide WHICH job should have
# started, and that is the point:
#
#   * The jobs API reports a job that is merely waiting for its `needs:` as
#     `queued`, identically to one waiting for a runner. Distinguishing them
#     would mean parsing this workflow's dependency graph — brittle, and it
#     would have to be kept in step with every `needs:` edit. The conjunction
#     above sidesteps that entirely: while dependencies are legitimately
#     pending, something upstream is `in_progress`, so the predicate is false.
#   * A "no runner carries label X" precheck is NOT implementable, so this is
#     not a lazy substitute for one. `/orgs/{org}/actions/runner-scale-sets`
#     answers 404 for this org, and scale-set runners appear in
#     `/orgs/{org}/actions/runners` with an EMPTY `labels` array — so a check
#     that compared `runs-on:` labels against registered runner labels would
#     declare healthy job classes unserviceable. This watchdog therefore
#     observes the run's own behaviour, which needs no runner introspection and
#     no special permission beyond reading the run it is part of.
#
# The watchdog excludes ITSELF from the `in_progress` count. It is a job in the
# run it is watching, so counting itself would make the predicate permanently
# false — the one bug that would render this silently useless.
#
# DESIGN CONSTRAINT
# -----------------
# Same rule as `ci-verdict` and `workspace-lock-freshness`: a watchdog must not
# share the failure mode it watches for. This runs on a stock GitHub-hosted
# runner with nothing but `bash`, `jq` and `curl`, declares no `needs:`, and
# touches no Nix, dev shell, workspace lock or sibling checkout. If it needed
# any of those, a run starved of self-hosted runners would starve the watchdog
# too, and it would report nothing at precisely the moment it is needed.
#
# USAGE
#   queue-watchdog.sh --jobs-json <file|->  [--self-job-name NAME]
#   queue-watchdog.sh --poll --deadline-minutes N [--interval-seconds N]
#
#   --jobs-json FILE       one snapshot of the GitHub jobs API payload, or `-`
#                          for stdin. Shape: {"jobs":[{"name":..,"status":..}]}
#                          A bare JSON array is also accepted. Evaluates the
#                          predicate once and exits. This is the offline,
#                          testable form.
#   --self-job-name NAME   display name of this watchdog's own job, excluded
#                          from the `in_progress` count. Default: $GITHUB_JOB,
#                          else "queue-watchdog".
#   --poll                 CI form: fetch snapshots from the API and require
#                          the stalled predicate to hold CONTINUOUSLY for the
#                          deadline before failing. Any observed progress
#                          resets the clock, so a slow-but-moving run is never
#                          failed.
#   --deadline-minutes N   how long the stall must persist. Default 30.
#   --interval-seconds N   polling interval. Default 30.
#
# EXIT CODES
#   0  the run is being serviced (or finished)
#   4  the run is STALLED: jobs are queued and nothing is running
#   3  usage or environment error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

JOBS_JSON=""
SELF_JOB_NAME="${GITHUB_JOB:-queue-watchdog}"
POLL=0
DEADLINE_MINUTES=30
INTERVAL_SECONDS=30

while [[ $# -gt 0 ]]; do
	case "$1" in
	--jobs-json)
		JOBS_JSON="${2:-}"
		shift 2
		;;
	--self-job-name)
		SELF_JOB_NAME="${2:-}"
		shift 2
		;;
	--poll)
		POLL=1
		shift
		;;
	--deadline-minutes)
		DEADLINE_MINUTES="${2:-}"
		shift 2
		;;
	--interval-seconds)
		INTERVAL_SECONDS="${2:-}"
		shift 2
		;;
	-h | --help)
		grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "queue-watchdog: unknown argument: $1" >&2
		exit 3
		;;
	esac
done

if ! command -v jq >/dev/null 2>&1; then
	# Deliberately fatal rather than degraded, for the same reason as
	# required-jobs.sh: a watchdog that cannot read its input must never
	# report that everything is fine.
	echo "queue-watchdog: jq not found on PATH; cannot evaluate the jobs payload" >&2
	exit 3
fi

for _n in DEADLINE_MINUTES INTERVAL_SECONDS; do
	if [[ ! ${!_n} =~ ^[0-9]+$ ]]; then
		echo "queue-watchdog: --${_n,,} must be a non-negative integer (got '${!_n}')" >&2
		exit 3
	fi
done
DEADLINE_MINUTES="${DEADLINE_MINUTES#0}"
: "${DEADLINE_MINUTES:=0}"

emit() {
	echo "$@"
	# The step summary is a rendering surface, never the verdict. An
	# unwritable summary must not be able to abort this script under `set -e`
	# before it reaches its exit-4 branch, which is the one signal it exists
	# to raise.
	if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
		echo "$@" >>"${GITHUB_STEP_SUMMARY}" 2>/dev/null || true
	fi
}

# Normalise either {"jobs":[...]} or a bare [...] into the job array, so a
# caller can pipe the API response through unchanged.
normalise() {
	jq -e 'if type == "object" then (.jobs // empty) elif type == "array" then . else empty end'
}

# --- the predicate --------------------------------------------------------
#
# Sets RUNNING / QUEUED / QUEUED_NAMES / TOTAL from one snapshot.
# Returns 0 when STALLED, 1 otherwise.
evaluate_snapshot() {
	local payload="$1" self="$2" jobs
	if ! jobs="$(printf '%s' "${payload}" | normalise 2>/dev/null)"; then
		echo 'queue-watchdog: jobs payload is neither {"jobs":[...]} nor [...]' >&2
		exit 3
	fi
	if ! printf '%s' "${jobs}" | jq -e 'all(.[]; type == "object" and has("status"))' >/dev/null 2>&1; then
		echo 'queue-watchdog: every job entry must be an object carrying a "status"' >&2
		exit 3
	fi

	TOTAL="$(printf '%s' "${jobs}" | jq 'length')"
	# `in_progress` anywhere except this watchdog's own job means the run is
	# still being serviced and can still advance.
	RUNNING="$(printf '%s' "${jobs}" |
		jq --arg self "${self}" '[.[] | select(.status == "in_progress") | select(.name != $self)] | length')"
	QUEUED="$(printf '%s' "${jobs}" |
		jq '[.[] | select(.status == "queued")] | length')"
	QUEUED_NAMES="$(printf '%s' "${jobs}" |
		jq -r '[.[] | select(.status == "queued") | .name] | sort | .[]')"

	[[ ${RUNNING} -eq 0 && ${QUEUED} -gt 0 ]]
}

report_stalled() {
	emit ""
	emit "=============================================================="
	emit "  CI IS NOT BEING SERVICED"
	emit "=============================================================="
	emit ""
	emit "${QUEUED} job(s) are queued and NOTHING in this run is running."
	emit "Nothing is running, so nothing can finish; nothing can finish, so"
	emit "no queued job's dependencies can ever be satisfied. This run will"
	emit "not advance on its own -- it will sit here until GitHub cancels it"
	emit "at the 24-hour queue ceiling."
	emit ""
	emit "This is NOT a test failure and NOT a verdict on the code. It says"
	emit "no runner is picking this run's jobs up."
	emit ""
	emit "Still queued:"
	while IFS= read -r n; do
		[[ -z ${n} ]] && continue
		emit "  - ${n}"
	done <<<"${QUEUED_NAMES}"
	emit ""
	emit "Most common cause: the runner pool is churning -- instances are"
	emit "provisioned, handed a queued job, marked busy, and then die without"
	emit "executing it. Check the org's runner pool before re-running, and do"
	emit "not read this as a reason to re-push."
}

# --- single-snapshot mode -------------------------------------------------
if [[ ${POLL} -eq 0 ]]; then
	if [[ -z ${JOBS_JSON} ]]; then
		echo "queue-watchdog: --jobs-json is required (file path or '-'), or use --poll" >&2
		exit 3
	fi
	if [[ ${JOBS_JSON} == "-" ]]; then
		payload="$(cat)"
	else
		if [[ ! -f ${JOBS_JSON} ]]; then
			echo "queue-watchdog: jobs payload not found: ${JOBS_JSON}" >&2
			exit 3
		fi
		payload="$(cat "${JOBS_JSON}")"
	fi
	if evaluate_snapshot "${payload}" "${SELF_JOB_NAME}"; then
		emit "queue-watchdog: STALLED — ${QUEUED} queued, 0 running (of ${TOTAL} jobs)"
		report_stalled
		exit 4
	fi
	emit "queue-watchdog: run is being serviced — ${RUNNING} running, ${QUEUED} queued (of ${TOTAL} jobs)"
	exit 0
fi

# --- polling mode ---------------------------------------------------------
: "${GITHUB_REPOSITORY:?queue-watchdog: --poll needs GITHUB_REPOSITORY}"
: "${GITHUB_RUN_ID:?queue-watchdog: --poll needs GITHUB_RUN_ID}"
: "${GH_TOKEN:?queue-watchdog: --poll needs GH_TOKEN (actions: read)}"

deadline_seconds=$((DEADLINE_MINUTES * 60))
stalled_since=""

emit "queue-watchdog: watching ${GITHUB_REPOSITORY} run ${GITHUB_RUN_ID}"
emit "queue-watchdog: fails if jobs stay queued with nothing running for ${DEADLINE_MINUTES}m"

while :; do
	# `--paginate` matters: this workflow has well over the 30-job default
	# page size, and a truncated page could show zero `in_progress` jobs
	# purely because the running ones fell off the end -- a false STALL.
	if ! snapshot="$(gh api --paginate \
		"repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/jobs" \
		--jq '.jobs' 2>/dev/null | jq -s 'add // []')"; then
		# A transient API failure is not evidence of a stall. Say so and
		# retry rather than inventing a verdict from a failed read.
		echo "queue-watchdog: jobs API read failed; retrying in ${INTERVAL_SECONDS}s" >&2
		sleep "${INTERVAL_SECONDS}"
		continue
	fi

	if evaluate_snapshot "${snapshot}" "${SELF_JOB_NAME}"; then
		now="$(date +%s)"
		if [[ -z ${stalled_since} ]]; then
			stalled_since="${now}"
			echo "queue-watchdog: stall observed (${QUEUED} queued, 0 running); starting ${DEADLINE_MINUTES}m clock"
		fi
		elapsed=$((now - stalled_since))
		if [[ ${elapsed} -ge ${deadline_seconds} ]]; then
			emit "queue-watchdog: STALLED for $((elapsed / 60))m — ${QUEUED} queued, 0 running (of ${TOTAL} jobs)"
			report_stalled
			exit 4
		fi
		echo "queue-watchdog: stalled ${elapsed}s/${deadline_seconds}s (${QUEUED} queued)"
	else
		# Any observed progress clears the clock, so a long-running job can
		# never accumulate a stall verdict against it.
		if [[ -n ${stalled_since} ]]; then
			echo "queue-watchdog: progress resumed (${RUNNING} running); clock reset"
		fi
		stalled_since=""
		if [[ ${QUEUED} -eq 0 ]]; then
			emit "queue-watchdog: nothing queued — run is fully scheduled (${TOTAL} jobs)"
			exit 0
		fi
		echo "queue-watchdog: ${RUNNING} running, ${QUEUED} queued"
	fi

	sleep "${INTERVAL_SECONDS}"
done
