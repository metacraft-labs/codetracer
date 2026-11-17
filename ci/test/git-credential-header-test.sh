#!/usr/bin/env bash
# ci/test/git-credential-header-test.sh -- in a job that registers the git
# credential helper, a stale github.com extraHeader cannot outlive its token.
#
# git sends an http.<url>.extraHeader with every request and does not fall back
# to a credential helper when the header is refused, so a header fixed at a
# step's start failed metacraft-labs fetches an hour later however fresh the
# helper's token (codetracer-pm issues/2026-11-17-a-ci-step-longer-than-an-
# hour-sends-metacraft-labs-git-requests-a-stale-token.md).
#
# Against a local smart-HTTP server that answers like GitHub for a private
# repository (ci/test/git-basic-auth-server.py), this holds that:
#   * CONTROL: a stale extraHeader fails the fetch even with the helper holding
#     the good token -- the defect, reproduced;
#   * the same entry with an empty value resets the header list, git asks the
#     helper, and the fetch succeeds;
#   * ci/register-git-credential-helper.sh blanks the github.com extraHeader
#     entries when the job netrc is there, and keeps them when it is not;
#   * refresh-github-token's refresh.sh leaves a blanked entry blank and still
#     refreshes one that is set.
set -euo pipefail
cd "$(dirname "$0")/../.."
root="$PWD"
failures=0
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}
ok() { echo "  ok   $*"; }
check() {
	local good="$1" bad="$2"
	shift 2
	if "$@"; then ok "$good"; else fail "$bad"; fi
}

work="$(mktemp -d)"
server=""
cleanup() {
	[ -z "$server" ] || kill "$server" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT

basic() { printf 'x-access-token:%s' "$1" | base64 | tr -d '\n'; }

# A private repository with one commit.
mkdir -p "$work/srv/metacraft-labs"
git init -q --bare "$work/srv/metacraft-labs/private.git"
git -C "$work/srv/metacraft-labs/private.git" config http.receivepack false
git init -q "$work/seed"
git -C "$work/seed" -c user.name=t -c user.email=t@t commit -q --allow-empty -m seed
git -C "$work/seed" push -q "$work/srv/metacraft-labs/private.git" HEAD:refs/heads/main

python3 ci/test/git-basic-auth-server.py "$work/srv" good-token "$work/port" 2>"$work/server.log" &
server=$!
for _ in $(seq 1 50); do
	[ -s "$work/port" ] && break
	sleep 0.1
done
port="$(cat "$work/port")"
base="http://127.0.0.1:${port}"
url="${base}/metacraft-labs/private.git"

mkdir -p "$work/cred"
printf 'machine github.com login x-access-token password good-token\n' >"$work/cred/netrc"
helper="!bash ${root}/ci/git-credential-job-netrc.sh"

# fetch <header value> -- ls-remote the private repository with the scoped
# extraHeader set to <header value> (empty: blanked) and the helper registered.
fetch() {
	env -u GIT_CONFIG_PARAMETERS HOME="$work" GIT_TERMINAL_PROMPT=0 \
		MCL_JOB_CREDENTIALS_DIR="$work/cred" CT_GIT_CREDENTIAL_ORIGIN="http 127.0.0.1:${port}" \
		GIT_CONFIG_COUNT=2 \
		GIT_CONFIG_KEY_0="http.${base}/metacraft-labs/.extraHeader" GIT_CONFIG_VALUE_0="$1" \
		GIT_CONFIG_KEY_1="credential.${base}.helper" GIT_CONFIG_VALUE_1="$helper" \
		git ls-remote "$url" HEAD >/dev/null 2>"$work/fetch.err"
}
nofetch() { ! fetch "$@"; }

: >"$work/fetch.err"
echo "the defect, against a git server that answers like GitHub"
check "a good extraHeader is let in (the server works)" "a good header was refused: $(cat "$work/fetch.err")" \
	fetch "AUTHORIZATION: basic $(basic good-token)"
check "CONTROL: a stale extraHeader fails even with the helper holding the good token" \
	"a stale header got through, so this test cannot see the defect" \
	nofetch "AUTHORIZATION: basic $(basic stale-token)"

echo "a blanked extraHeader lets the helper answer"
seen="$(wc -l <"$work/server.log")"
check "an empty value resets the header list and the helper's token gets in" \
	"a blanked header still failed: $(cat "$work/fetch.err")" fetch ""
check "the server let in requests carrying one Authorization header, the helper's" \
	"no request was let in on the helper's credential alone" \
	grep -q "auth=1 allowed=True" <(tail -n +"$((seen + 1))" "$work/server.log")

echo "register-git-credential-helper.sh blanks the github.com header"
reg() {
	: >"$work/github_env"
	env GITHUB_ENV="$work/github_env" GITHUB_WORKSPACE="$work/seed" "$@" \
		GIT_CONFIG_COUNT=1 \
		GIT_CONFIG_KEY_0="http.https://github.com/metacraft-labs/.extraHeader" \
		GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(basic stale-token)" \
		bash ci/register-git-credential-helper.sh >/dev/null
}
reg MCL_JOB_CREDENTIALS_DIR="$work/cred"
check "with the job netrc: GIT_CONFIG_VALUE_0 is written empty" "not blanked: $(cat "$work/github_env")" \
	grep -qx 'GIT_CONFIG_VALUE_0=' "$work/github_env"
check "and the helper is registered" "helper not registered: $(cat "$work/github_env")" \
	grep -qx 'GIT_CONFIG_KEY_1=credential.https://github.com.helper' "$work/github_env"
reg MCL_JOB_CREDENTIALS_DIR="$work/no-such-dir"
check "without the job netrc: the header is kept" "blanked with no netrc for the helper to read" \
	test "$(grep -c '^GIT_CONFIG_VALUE_0=' "$work/github_env")" = 0

echo "refresh.sh leaves a blanked header blank"
refresh() {
	: >"$work/github_env"
	env HOME="$work" GITHUB_ENV="$work/github_env" GITHUB_WORKSPACE="$work/seed" NEW_TOKEN=new-token \
		GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.https://github.com/metacraft-labs/.extraHeader" \
		GIT_CONFIG_VALUE_0="$1" bash .github/actions/refresh-github-token/refresh.sh >/dev/null
}
refresh ""
check "a blank entry is not written back" "refresh.sh restored the header: $(cat "$work/github_env")" \
	test "$(grep -c '^GIT_CONFIG_VALUE_0=' "$work/github_env")" = 0
refresh "AUTHORIZATION: basic $(basic stale-token)"
check "a set entry is still refreshed" "refresh.sh no longer refreshes a set header" \
	grep -qx "GIT_CONFIG_VALUE_0=AUTHORIZATION: basic $(basic new-token)" "$work/github_env"

echo
if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "all checks passed"
