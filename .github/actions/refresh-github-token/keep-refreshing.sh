#!/usr/bin/env bash
# Re-mint the GitHub App installation token every 40 minutes for the rest of
# the job, and write each new one into nix.conf and the Nix netrc (refresh.sh
# without GITHUB_ENV, which a running step cannot see anyway).
#
# A single step can outlast a token: the AppImage build alone runs for more
# than an hour on a fresh runner, and the 26.10.1 dry run (36832102898) failed
# 61 minutes into it, when nix fetched a flake input with a token minted just
# before the step. Nix rereads its configuration and netrc on every
# invocation, so rewriting the files is enough for every later fetch.
#
# WHEN IT MINTS. Once at start, so the age of the job's token is known from
# here on, then whenever the token is REFRESH_AFTER seconds old (35 minutes;
# refresh.sh records each mint in $MCL_JOB_CREDENTIALS_DIR/github-token-
# minted-at, so a refresh-github-token step counts too), and at once when the
# git credential helper asks for it by creating github-token-refresh-requested
# there, because it is about to hand out a token that old. A failed mint is
# retried every RETRY_AFTER seconds (60) until one succeeds.
#
# It used to sleep 40 minutes, try twice and sleep again. GPUI shard 20 of run
# 43996043232 started it at 05:53 with a token minted at 05:46; the attempts at
# 06:33 and 06:38 evidently failed (it was alive at the end of the job, and its
# log was never kept), and the next would have been at 07:18. In between the
# token expired, and Nix's Cargo git fetches at 07:14 got "Invalid username or
# token". ci/test/github-token-freshness-test.sh drives this loop.
#
# Needs APP_ID and APP_PRIVATE_KEY in the environment, and openssl, curl and
# jq on PATH. Runs until the job ends; the runner kills it then. The test sets
# KEEP_REFRESHING_MINT_COMMAND to a command that prints a token, in place of
# the GitHub App exchange.
set -uo pipefail
: "${APP_ID:?}" "${APP_PRIVATE_KEY:?}"
here="$(cd "$(dirname "$0")" && pwd)"
owner="${OWNER:-metacraft-labs}"
refresh_after="${REFRESH_AFTER:-2100}"
retry_after="${RETRY_AFTER:-60}"
tick="${TICK:-15}"
cred_dir="${MCL_JOB_CREDENTIALS_DIR:-}"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

mint_from_app() {
	local now header payload signature jwt installation
	now="$(date +%s)"
	header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
	payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$APP_ID" | b64url)"
	signature="$(printf '%s.%s' "$header" "$payload" |
		openssl dgst -sha256 -sign <(printf '%s\n' "$APP_PRIVATE_KEY") | b64url)" || return 1
	jwt="$header.$payload.$signature"
	installation="$(curl -fsS -H "Authorization: Bearer $jwt" -H 'Accept: application/vnd.github+json' \
		"https://api.github.com/orgs/$owner/installation" | jq -r .id)" || return 1
	curl -fsS -X POST -H "Authorization: Bearer $jwt" -H 'Accept: application/vnd.github+json' \
		"https://api.github.com/app/installations/$installation/access_tokens" | jq -r .token
}

mint() {
	local token
	if [ -n "${KEEP_REFRESHING_MINT_COMMAND:-}" ]; then
		token="$(bash -c "$KEEP_REFRESHING_MINT_COMMAND")" || return 1
	else
		token="$(mint_from_app)" || return 1
	fi
	[ -n "$token" ] && [ "$token" != null ] || return 1
	NEW_TOKEN="$token" GITHUB_ENV=/dev/null GITHUB_WORKSPACE=/nonexistent GIT_CONFIG_COUNT=0 \
		bash "$here/refresh.sh" >/dev/null
}

log() { echo "$(date -u +%FT%TZ) $*" >&2; }

# The later of this loop's own last mint and the one refresh.sh recorded (a
# job with no credential directory has only the former).
last_mint=0
minted_at() {
	local at=0
	[ -n "$cred_dir" ] && [ -r "$cred_dir/github-token-minted-at" ] &&
		read -r at <"$cred_dir/github-token-minted-at"
	at="${at:-0}"
	[ "$at" -gt "$last_mint" ] 2>/dev/null || at="$last_mint"
	echo "$at"
}

[ -n "$cred_dir" ] && echo "$$" >"$cred_dir/github-token-refresher.pid"
# It ends with the job that started it: a persistent runner does not end it,
# and one started on 2026-11-19 was still minting tokens two days later.
# shellcheck source=ci/lib/job-lifetime.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../../../ci/lib/job-lifetime.sh"
next_try=0
while job_still_running; do
	now="$(date +%s)"
	age=$((now - $(minted_at)))
	requested=0
	[ -n "$cred_dir" ] && [ -e "$cred_dir/github-token-refresh-requested" ] && requested=1
	if { [ "$age" -ge "$refresh_after" ] || [ "$requested" = 1 ]; } && [ "$now" -ge "$next_try" ]; then
		if mint; then
			next_try=0 last_mint="$now"
			if [ "$requested" = 1 ]; then
				rm -f "$cred_dir/github-token-refresh-requested"
				log "refreshed the GitHub token (the git credential helper asked for it)"
			else
				log "refreshed the GitHub token"
			fi
		else
			next_try=$((now + retry_after))
			log "could not refresh the GitHub token (it is $((age / 60)) minutes old); retrying in ${retry_after}s"
		fi
	fi
	sleep "$tick"
done
