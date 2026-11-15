#!/usr/bin/env bash
# Register ci/git-credential-job-netrc.sh as the git credential helper for
# https://github.com for the rest of the job, by appending one entry to the
# numbered GIT_CONFIG_* configuration setup-dev-env exports through
# GITHUB_ENV. refresh-github-token rewrites only the extraHeader entries, so
# this one survives a refresh, and the helper reads the netrc it refreshes.
# Idempotent: a second call finds its entry and changes nothing.
set -euo pipefail
helper="!bash $(cd "$(dirname "$0")" && pwd)/git-credential-job-netrc.sh"
key="credential.https://github.com.helper"
count="${GIT_CONFIG_COUNT:-0}"
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
