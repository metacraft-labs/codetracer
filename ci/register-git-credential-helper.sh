#!/usr/bin/env bash
# Register ci/git-credential-job-netrc.sh as the git credential helper for
# https://github.com for the rest of the job, by appending one entry to the
# numbered GIT_CONFIG_* configuration setup-dev-env exports through
# GITHUB_ENV. refresh-github-token rewrites only the extraHeader entries, so
# this one survives a refresh, and the helper reads the netrc it refreshes.
# Idempotent: a second call finds its entry and changes nothing.
#
# It also BLANKS the job's github.com extraHeader entries, and drops the one
# actions/checkout persisted in this checkout, when the job netrc the helper
# reads is there. git sends an extraHeader with every request and never falls
# back to a helper when the header is refused, so a header fixed at a step's
# start went stale an hour after its token was minted and failed every
# metacraft-labs fetch late in a long step, however fresh the helper's token
# (codetracer-pm issues/2026-11-17-a-ci-step-longer-than-an-hour-sends-
# metacraft-labs-git-requests-a-stale-token.md). An empty value resets
# git's extraHeader list; a private repository then answers 401, git asks the
# helper, and the helper renews a token by its age. refresh.sh leaves a blank
# entry blank. ci/test/git-credential-header-test.sh holds this against a
# local git server.
set -euo pipefail
helper="!bash $(cd "$(dirname "$0")" && pwd)/git-credential-job-netrc.sh"
key="credential.https://github.com.helper"
count="${GIT_CONFIG_COUNT:-0}"

if [ -n "${MCL_JOB_CREDENTIALS_DIR:-}" ] && [ -r "${MCL_JOB_CREDENTIALS_DIR}/netrc" ]; then
	for ((i = 0; i < count; i++)); do
		k="GIT_CONFIG_KEY_$i" v="GIT_CONFIG_VALUE_$i"
		case "${!k:-}" in
		http.https://github.com/*.extraHeader | http.https://github.com/*.extraheader)
			if [ -n "${!v:-}" ]; then
				echo "GIT_CONFIG_VALUE_$i=" >>"${GITHUB_ENV:?}"
				echo "blanked ${!k} for later steps: the helper answers instead"
			fi
			;;
		esac
	done
	if [ -n "${GITHUB_WORKSPACE:-}" ] &&
		git -C "$GITHUB_WORKSPACE" config --local --get-all http.https://github.com/.extraheader >/dev/null 2>&1; then
		git -C "$GITHUB_WORKSPACE" config --local --unset-all http.https://github.com/.extraheader
		echo "dropped the checkout's persisted github.com extraheader: the helper answers instead"
	fi
else
	echo "no job netrc (\$MCL_JOB_CREDENTIALS_DIR/netrc): keeping the extraHeader entries"
fi

for ((i = 0; i < count; i++)); do
	k="GIT_CONFIG_KEY_$i" v="GIT_CONFIG_VALUE_$i"
	if [ "${!k:-}" = "$key" ] && [ "${!v:-}" = "$helper" ]; then
		echo "git credential helper for github.com already registered"
		exit 0
	fi
done
{
	echo "GIT_CONFIG_KEY_$count=$key"
	echo "GIT_CONFIG_VALUE_$count=$helper"
	echo "GIT_CONFIG_COUNT=$((count + 1))"
} >>"${GITHUB_ENV:?}"
echo "registered the job-netrc git credential helper for github.com"
