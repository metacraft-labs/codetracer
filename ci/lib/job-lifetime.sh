#!/usr/bin/env bash
# ci/lib/job-lifetime.sh -- source it; then `job_still_running` is false once
# the GitHub Actions job that started this process has ended.
#
# The CI jobs start helpers that loop until killed (ci/lib/memory-sampler.sh,
# refresh-github-token/keep-refreshing.sh), with `nohup ... &`. An ephemeral
# runner's VM ends with the job and takes them along; a persistent runner does
# not, and they outlive it: on high-mem-server-mcl-003 a memory sampler and a
# token refresher started by jobs on 2026-11-19 were still running two days
# and several jobs later (run 44648381899's process dump), the refresher
# minting tokens for a job long gone.
#
# At source time this records the job's Runner.Worker (one per job; the runner
# starts a fresh one for each) from the process's ancestors.
# `job_still_running` is then true while that process lives and the helper is
# younger than CT_HELPER_MAX_SECONDS (21600, six hours: no job's limit is
# longer). Outside a runner -- no Runner.Worker ancestor -- only the age bound
# applies.
_ct_job_worker=""
_ct_job_started_at="$(date +%s)"
_ct_job_find_worker() {
	local p="$$" comm
	while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
		comm="$(ps -o comm= -p "$p" 2>/dev/null)"
		case "$comm" in
		*Runner.Worker*)
			echo "$p"
			return
			;;
		esac
		p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
	done
}
_ct_job_worker="${CT_JOB_WORKER_PID:-$(_ct_job_find_worker)}"
job_still_running() {
	[ "$(($(date +%s) - _ct_job_started_at))" -lt "${CT_HELPER_MAX_SECONDS:-21600}" ] || return 1
	[ -z "$_ct_job_worker" ] || kill -0 "$_ct_job_worker" 2>/dev/null
}
