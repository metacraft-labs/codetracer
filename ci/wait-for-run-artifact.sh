#!/usr/bin/env bash
# ci/wait-for-run-artifact.sh ARTIFACT JOB_PREFIX TIMEOUT_SECONDS
#
# Wait until this workflow run has an artifact named ARTIFACT, or until the
# job that makes it (the first job whose name starts with JOB_PREFIX) has
# finished without making it, or until TIMEOUT_SECONDS pass. Exit 0 when the
# artifact exists, 1 otherwise, so the caller's download step runs only when
# there is something to download and falls back to building otherwise.
#
# It exists so that the shards do not `need` the visual-replay-tools job. As a
# `needs`, the 105-minute tools job held back every TUI and GPUI shard, not
# only the ones that use its tools: in run 44384977215 ct-build finished at
# 21:22 and the shards started after 22:04. The shards that use the tools
# reach this step after their own ~55 minutes of provisioning, by when the
# tools job has normally finished, so the wait is normally zero.
#
# Reads GITHUB_API_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID and GH_TOKEN (a token
# with actions: read). CT_WAIT_POLL_SECONDS overrides the 30 s poll (tests).
set -euo pipefail

artifact="${1:?usage: wait-for-run-artifact.sh ARTIFACT JOB_PREFIX TIMEOUT_SECONDS}"
job_prefix="${2:?usage: wait-for-run-artifact.sh ARTIFACT JOB_PREFIX TIMEOUT_SECONDS}"
timeout="${3:?usage: wait-for-run-artifact.sh ARTIFACT JOB_PREFIX TIMEOUT_SECONDS}"
poll="${CT_WAIT_POLL_SECONDS:-30}"
api="${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY:?}/actions/runs/${GITHUB_RUN_ID:?}"

get() {
	curl -fsS --max-time 30 -H "Authorization: Bearer ${GH_TOKEN:?}" \
		-H "Accept: application/vnd.github+json" "$1"
}

start=$(date +%s)
done_polls=0
while :; do
	waited=$(($(date +%s) - start))
	# A transient API failure is a reason to poll again, not a verdict.
	if count="$(get "${api}/artifacts?name=${artifact}" | jq -er '.total_count')"; then
		if [ "${count}" -gt 0 ]; then
			echo "wait-for-run-artifact: '${artifact}' is available (waited ${waited}s)"
			exit 0
		fi
	else
		echo "wait-for-run-artifact: could not list the run's artifacts; polling again" >&2
	fi
	if job="$(get "${api}/jobs?per_page=100" |
		jq -er --arg p "${job_prefix}" \
			'[.jobs[] | select(.name | startswith($p))][0] | "\(.status) \(.conclusion)"')"; then
		case "${job}" in
		"completed success")
			# Uploaded; give the artifact listing two polls to catch up.
			done_polls=$((done_polls + 1))
			if [ "${done_polls}" -gt 2 ]; then
				echo "wait-for-run-artifact: '${job_prefix}' succeeded but '${artifact}' is not listed; not waiting" >&2
				exit 1
			fi
			;;
		completed\ *)
			echo "wait-for-run-artifact: '${job_prefix}' finished (${job#completed }) without '${artifact}'; not waiting" >&2
			exit 1
			;;
		esac
	fi
	if [ "${waited}" -ge "${timeout}" ]; then
		echo "wait-for-run-artifact: no '${artifact}' after ${waited}s; not waiting longer" >&2
		exit 1
	fi
	sleep "${poll}"
done
