#!/usr/bin/env bash
# ci/test/github-token-freshness-test.sh -- a git fetch late in a job gets a
# token minted recently, not the one the job started with.
#
# Drives the real refresher (.github/actions/refresh-github-token/
# keep-refreshing.sh, with refresh.sh) and the real git credential helper
# (ci/git-credential-job-netrc.sh) against a scratch credential directory, with
# a counting fake in place of the GitHub App exchange. It holds that:
#   * the refresher mints at start and records when (github-token-minted-at);
#   * it mints again once the token reaches REFRESH_AFTER seconds;
#   * a failed mint is retried after RETRY_AFTER, not after the next period;
#   * the helper hands a young token out as is and asks for nothing;
#   * the helper, given a token older than CT_GITHUB_TOKEN_MAX_AGE, asks the
#     refresher for a new one and hands out THAT;
#   * with no refresher running it says so on stderr instead of hanging.
# GPUI shard 20 of run 43996043232 is the case: Nix's Cargo git fetches 88
# minutes into the job got "Invalid username or token".
set -euo pipefail
cd "$(dirname "$0")/../.."
root="$PWD"
failures=0
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}
ok() { echo "  ok   $*"; }
# check <ok message> <fail message> <command...>
check() {
	local good="$1" bad="$2"
	shift 2
	if "$@"; then ok "$good"; else fail "$bad"; fi
}
same() { [ "$1" = "$2" ]; }

work="$(mktemp -d)"
refresher=""
cleanup() {
	[ -z "$refresher" ] || kill "$refresher" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT

new_cred_dir() {
	local d="$work/$1"
	mkdir -p "$d/cred" "$d/home"
	printf 'access-tokens = github.com=tok0\n' >"$d/cred/nix-access-tokens.conf"
	printf 'machine github.com login x-access-token password tok0\n' >"$d/cred/netrc"
	printf 'tok0\n' >"$d/cred/git-token"
	echo "$d"
}

# Prints tok<N> on the Nth call, failing the first $1 calls.
mint_cmd() {
	local d="$1" fail_first="$2"
	echo "n=\$((\$(cat '$d/count' 2>/dev/null || echo 0) + 1)); echo \$n >'$d/count'; [ \$n -gt $fail_first ] || exit 1; echo tok\$n"
}

start_refresher() {
	local d="$1" fail_first="$2" refresh_after="$3"
	HOME="$d/home" MCL_JOB_CREDENTIALS_DIR="$d/cred" APP_ID=test APP_PRIVATE_KEY=test \
		KEEP_REFRESHING_MINT_COMMAND="$(mint_cmd "$d" "$fail_first")" \
		REFRESH_AFTER="$refresh_after" RETRY_AFTER=1 TICK=1 \
		bash .github/actions/refresh-github-token/keep-refreshing.sh 2>"$d/refresher.log" &
	refresher=$!
}

stop_refresher() {
	kill "$refresher" 2>/dev/null || true
	wait "$refresher" 2>/dev/null || true
	refresher=""
}

# Waits up to $2 seconds for the netrc to hand out token $3.
wait_for_token() {
	local d="$1" limit="$2" want="$3" i
	for ((i = 0; i < limit * 4; i++)); do
		grep -q "password $want\$" "$d/cred/netrc" && return 0
		sleep 0.25
	done
	return 1
}

helper() {
	local d="$1"
	shift
	printf 'protocol=https\nhost=github.com\n\n' |
		env MCL_JOB_CREDENTIALS_DIR="$d/cred" "$@" bash "$root/ci/git-credential-job-netrc.sh" get
}

echo "the refresher mints at start and again when the token is old"
d="$(new_cred_dir age)"
start_refresher "$d" 0 3
if wait_for_token "$d" 5 tok1; then ok "minted at start (tok1)"; else fail "no mint at start: $(cat "$d/cred/netrc")"; fi
check "the mint time is recorded" "refresh.sh recorded no github-token-minted-at" \
	test -s "$d/cred/github-token-minted-at"
# setup-dev-env's helper reads git-token, and git asks it first.
git_token_renewed() {
	local i
	for i in $(seq 1 20); do
		grep -qx 'tok[1-9][0-9]*' "$1/cred/git-token" && return 0
		sleep 0.25
	done
	return 1
}
check "the git credential helper's token is renewed" \
	"git-token still holds '$(cat "$d/cred/git-token")'" git_token_renewed "$d"
if wait_for_token "$d" 8 tok2; then ok "minted again at REFRESH_AFTER (tok2)"; else fail "no renewal after REFRESH_AFTER: $(cat "$d/cred/netrc")"; fi
stop_refresher

echo "a failed mint is retried soon"
d="$(new_cred_dir retry)"
start_refresher "$d" 2 3600
if wait_for_token "$d" 8 tok3; then ok "two failures, then tok3 within seconds"; else fail "no retry after a failed mint: $(cat "$d/refresher.log")"; fi
check "the failures are logged" "a failed mint left no log line" grep -q "could not refresh" "$d/refresher.log"
stop_refresher

echo "the helper hands out a young token without asking"
d="$(new_cred_dir young)"
start_refresher "$d" 0 3600
wait_for_token "$d" 5 tok1 || fail "no mint at start"
out="$(helper "$d" CT_GITHUB_TOKEN_MAX_AGE=2700)"
check "tok1 handed out" "helper said: $out" same "$out" "$(printf 'username=x-access-token\npassword=tok1')"
check "no renewal asked for" "a young token triggered a renewal" \
	test ! -e "$d/cred/github-token-refresh-requested" -a "$(cat "$d/count")" = 1

echo "the helper renews an old token before handing it out"
echo "$(($(date +%s) - 3000))" >"$d/cred/github-token-minted-at"
out="$(helper "$d" CT_GITHUB_TOKEN_MAX_AGE=2700 CT_GITHUB_TOKEN_WAIT=10 2>"$d/helper.err")"
check "tok2, minted on request, handed out" "helper handed out '$out' for a 50-minute-old token ($(cat "$d/helper.err"))" \
	same "$out" "$(printf 'username=x-access-token\npassword=tok2')"
check "the refresher logged the request" "the refresher did not see the request" grep -q "asked for it" "$d/refresher.log"
stop_refresher

echo "with no refresher the helper warns and does not hang"
echo "$(($(date +%s) - 3000))" >"$d/cred/github-token-minted-at"
start="$(date +%s)"
out="$(helper "$d" CT_GITHUB_TOKEN_MAX_AGE=2700 CT_GITHUB_TOKEN_WAIT=30 2>"$d/helper.err")"
check "returned at once" "waited for a refresher that is not running" test $(($(date +%s) - start)) -lt 5
check "said why on stderr" "no warning: $(cat "$d/helper.err")" grep -q "50 minutes old and was not renewed" "$d/helper.err"
check "handed out what there is" "helper said: $out" same "$out" "$(printf 'username=x-access-token\npassword=tok2')"

echo
if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "all checks passed"
