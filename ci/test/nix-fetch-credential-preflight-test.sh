#!/usr/bin/env bash
set -euo pipefail

# Tests for ci/nix-fetch-credential-preflight.sh.
#
# The bug under test: a catch-all `http.https://github.com/.extraHeader` in
# scope makes git send an Authorization header to PUBLIC third-party
# repositories, GitHub answers 401, and git dies with
#
#     fatal: could not read Username for 'https://github.com': ...
#
# naming a repository that is public. These tests pin the two properties the
# preflight must have: it neutralises the catch-all, and it does NOT disturb a
# correctly scoped credential.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO_ROOT
readonly PREFLIGHT="${REPO_ROOT}/ci/nix-fetch-credential-preflight.sh"

readonly CATCH_ALL_KEY="http.https://github.com/.extraheader"
readonly CATCH_ALL_VALUE="AUTHORIZATION: basic eC1hY2Nlc3MtdG9rZW46Z2hzX3N0YWxl"
readonly SCOPED_KEY="http.https://github.com/metacraft-labs/.extraheader"
readonly SCOPED_VALUE="AUTHORIZATION: basic bWNsOnNjb3BlZA=="

readonly PUBLIC_THIRD_PARTY_URL="https://github.com/anza-xyz/crossbeam"
readonly OWN_URL="https://github.com/metacraft-labs/lldb-sys.rs"

failures=0

fail() {
	echo "FAIL: $*" >&2
	failures=$((failures + 1))
}

pass() {
	echo "ok: $*"
}

# Each case runs in a throwaway repository with an isolated HOME, so the
# developer's own git configuration cannot mask or cause a result.
make_sandbox() {
	local dir
	dir="$(mktemp -d)"
	git init -q "$dir"
	printf '%s' "$dir"
}

# The subshell-local HOME/GIT_CONFIG_* are the POINT of these helpers: each
# case must run against a known configuration, never the developer's own. The
# values are deliberately not meant to escape the subshell.
# shellcheck disable=SC2030,SC2031
run_preflight() {
	local dir="$1"
	shift
	(
		cd "$dir"
		export HOME="${dir}/home"
		mkdir -p "$HOME"
		export GIT_CONFIG_GLOBAL="${HOME}/.gitconfig"
		export GIT_CONFIG_SYSTEM=/dev/null
		unset GITHUB_ENV
		"$PREFLIGHT" "$@" 2>&1
	)
}

# Resolve the header a fetch of $2 would carry, under the GIT_CONFIG_* the
# preflight exports. Mirrors how git itself picks a header: longest URL match.
# shellcheck disable=SC2030,SC2031
header_after_preflight() {
	local dir="$1" url="$2"
	(
		cd "$dir"
		export HOME="${dir}/home"
		mkdir -p "$HOME"
		export GIT_CONFIG_GLOBAL="${HOME}/.gitconfig"
		export GIT_CONFIG_SYSTEM=/dev/null
		local env_file="${dir}/exported.env"
		export GITHUB_ENV="$env_file"
		: >"$env_file"
		"$PREFLIGHT" >/dev/null 2>&1 || true
		# Replay what $GITHUB_ENV would hand to the next step.
		set -a
		# shellcheck disable=SC1090
		. "$env_file"
		set +a
		git config --get-urlmatch http.extraHeader "$url" 2>/dev/null || true
	)
}

echo "== case 1: catch-all header is detected and reported =="
dir="$(make_sandbox)"
git -C "$dir" config "$CATCH_ALL_KEY" "$CATCH_ALL_VALUE"
output="$(run_preflight "$dir" || true)"
if grep -q "Authorization WOULD be sent" <<<"$output"; then
	pass "catch-all exposure reported before reset"
else
	fail "catch-all exposure was not reported; output was: ${output}"
fi
if grep -q "anza-xyz" <<<"$output"; then
	pass "report names the third-party owner"
else
	fail "report did not name the third-party owner"
fi
# The whole point is legibility: the token must never be echoed verbatim.
if grep -q "eC1hY2Nlc3MtdG9rZW46Z2hzX3N0YWxl" <<<"$output"; then
	fail "preflight leaked the raw credential into its output"
else
	pass "credential redacted in output"
fi
rm -rf "$dir"

echo
echo "== case 2: catch-all is neutralised for the public third-party repo =="
dir="$(make_sandbox)"
git -C "$dir" config "$CATCH_ALL_KEY" "$CATCH_ALL_VALUE"
resolved="$(header_after_preflight "$dir" "$PUBLIC_THIRD_PARTY_URL")"
if [[ -z $resolved ]]; then
	pass "no header resolves for ${PUBLIC_THIRD_PARTY_URL}"
else
	fail "header still resolves for public repo: ${resolved}"
fi
rm -rf "$dir"

echo
echo "== case 3: a correctly scoped credential survives the reset =="
dir="$(make_sandbox)"
git -C "$dir" config "$CATCH_ALL_KEY" "$CATCH_ALL_VALUE"
git -C "$dir" config "$SCOPED_KEY" "$SCOPED_VALUE"
resolved="$(header_after_preflight "$dir" "$OWN_URL")"
if [[ $resolved == "$SCOPED_VALUE" ]]; then
	pass "metacraft-labs-scoped header preserved for ${OWN_URL}"
else
	fail "scoped header was lost; resolved to: '${resolved}'"
fi
resolved="$(header_after_preflight "$dir" "$PUBLIC_THIRD_PARTY_URL")"
if [[ -z $resolved ]]; then
	pass "third-party repo still unauthenticated with both headers present"
else
	fail "third-party repo picked up a header: ${resolved}"
fi
rm -rf "$dir"

echo
echo "== case 4: clean configuration passes and reports no exposure =="
dir="$(make_sandbox)"
if output="$(run_preflight "$dir")"; then
	pass "preflight succeeds with no ambient header"
else
	fail "preflight failed on a clean configuration: ${output}"
fi
if grep -q "no Authorization header (correct)" <<<"$output"; then
	pass "clean state reported explicitly"
else
	fail "clean state was not reported"
fi
rm -rf "$dir"

echo
echo "== case 5: a configuration git cannot evaluate is NOT reported as clean =="
# Found by mutation testing. When the header lookup swallowed git's exit
# status, breaking the reset made every URL report "no Authorization header
# (correct)" and this suite passed green while the fix did nothing. A broken
# configuration must be loud, never laundered into the all-clear.
dir="$(make_sandbox)"
git -C "$dir" config "$CATCH_ALL_KEY" "$CATCH_ALL_VALUE"
# GIT_CONFIG_COUNT promises one key/value pair that is not supplied.
output="$(
	cd "$dir"
	HOME="${dir}/home" GIT_CONFIG_GLOBAL="${dir}/home/.gitconfig" \
		GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_COUNT=1 \
		"$PREFLIGHT" 2>&1
)" && status=0 || status=$?
if ((status != 0)); then
	pass "malformed git configuration fails the preflight (exit ${status})"
else
	fail "malformed git configuration was accepted as clean"
fi
if grep -q "no Authorization header (correct)" <<<"$output"; then
	fail "malformed configuration was reported as an all-clear"
else
	pass "malformed configuration did not produce a false all-clear"
fi
rm -rf "$dir"

echo
if ((failures)); then
	echo "${failures} assertion(s) failed." >&2
	exit 1
fi
echo "All nix-fetch-credential-preflight assertions passed."
