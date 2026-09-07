#!/usr/bin/env bash
set -euo pipefail

# Keep an ambient catch-all github.com Authorization header out of Nix's Git
# fetcher, and make it legible when one is present.
#
# WHY THIS EXISTS
#
# `nix develop` evaluates flake inputs, and some of those resolve to plain
# `git+https://github.com/...` fetches of THIRD-PARTY PUBLIC repositories --
# `anza-xyz/crossbeam` is the one that has bitten `push-install-script`.
# Nix implements that fetch by shelling out to `git ls-remote` / `git fetch`,
# so the child git reads ordinary git configuration: the system file, the
# global file, AND the `.git/config` of whatever repository the working
# directory happens to sit in. All three were verified directly; the
# long-standing claim that "Nix's fetcher does not read gitconfig" is false
# for `git+https` inputs and cost an afternoon of hunting a nonexistent 404.
#
# When a CATCH-ALL header is in scope --
#
#     [http "https://github.com/"]
#             extraHeader = AUTHORIZATION: basic <token for one org>
#
# -- git sends it UNCONDITIONALLY, to every github.com URL, including public
# repositories that need no credential at all. GitHub answers a token it will
# not honour for that owner with 401 rather than the 200 an anonymous request
# gets, git then falls back to the credential helper, finds none on a CI
# runner, tries to prompt, and dies on a runner with no terminal:
#
#     fatal: could not read Username for 'https://github.com':
#            No such device or address
#
# That message names a PUBLIC repository, so it reads like a 404 or a private
# repo. It is neither. It is a 401 caused by sending an Authorization header
# that should never have been sent to that owner. The failure is intermittent
# because it depends on whether a catch-all header happens to be in scope on
# the reused self-hosted runner -- for example one persisted into a reused
# work tree by an `actions/checkout` whose cleanup did not run.
#
# WHAT THIS DOES
#
# Git resolves `http.<url>.extraHeader` by LONGEST MATCHING URL PREFIX, so a
# header registered for `https://github.com/` (empty value) resets the header
# list for every github.com URL WITHOUT disturbing a correctly scoped
# `https://github.com/<owner>/` header, which remains the longest match for
# its own owner. That was measured, not assumed. So this script installs an
# empty catch-all reset and leaves properly scoped credentials alone.
#
# This is deliberately NOT an unauthenticated fallback. It does not retry
# without credentials on failure -- that would turn a hard failure into an
# intermittent one, which is the very bug being fixed here. It only removes a
# header that was never valid for the owner being contacted.

readonly GITHUB_PREFIX="https://github.com/"

# The owner whose credentials this repository's CI legitimately holds. A
# header scoped at or below `https://github.com/<CREDENTIALED_OWNER>/` is
# expected and is preserved.
readonly CREDENTIALED_OWNER="metacraft-labs"

# Third-party PUBLIC github.com repositories that flake evaluation is known to
# fetch over `git+https`. These need no credential; a header reaching them is
# always a defect.
THIRD_PARTY_URLS=(
	"https://github.com/anza-xyz/crossbeam"
)

redact_header() {
	sed -E \
		-e 's#([Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*[A-Za-z]+[[:space:]]+)[A-Za-z0-9+/=_.-]+#\1[REDACTED]#g' \
		-e 's#(https://[^:@/[:space:]]+:)[^@[:space:]]+(@)#\1[REDACTED]\2#g'
}

# `--get-urlmatch` exits 1 when nothing matches, which is a legitimate answer
# ("no header"). Any OTHER non-zero status means git could not evaluate the
# configuration at all -- a malformed GIT_CONFIG_COUNT/KEY_n set is the easy
# way to get there -- and that must not be laundered into "no header".
#
# This distinction is load-bearing, and it was found by mutation testing: with
# the status swallowed by `|| true`, breaking the reset made every URL report
# "no Authorization header (correct)" and the whole suite passed green while
# the fix did nothing. A check that reports success when its subject is broken
# is worse than no check.
#
# Callers MUST inspect the return status, not just the output. This function is
# used from a command substitution, and an `exit` inside one only leaves the
# subshell -- a second way the same failure got laundered into "no header".
# Returns: 0 header printed, 1 no header, 2 git could not evaluate the config.
effective_header_for() {
	local out status
	out="$(git config --get-urlmatch http.extraHeader "$1" 2>&1)"
	status=$?

	case "$status" in
	0)
		printf '%s' "$out"
		return 0
		;;
	1)
		# No key matched this URL. Nothing to print.
		return 1
		;;
	*)
		printf '%s' "$out"
		return 2
		;;
	esac
}

# Resolve into a GLOBAL rather than returning through a command substitution:
# `$(...)` runs a subshell, so an `exit` inside one would abort only that
# subshell and the caller would sail on with an empty string -- the very
# laundering this guard exists to prevent. Callers read $RESOLVED_HEADER.
RESOLVED_HEADER=""
resolve_header_or_die() {
	local url="$1" status
	RESOLVED_HEADER="$(effective_header_for "$url")" && status=0 || status=$?

	if ((status >= 2)); then
		echo "Nix fetch credential preflight: git could not evaluate" >&2
		echo "http.extraHeader for '${url}'. The git configuration in scope is" >&2
		echo "malformed, so NOTHING here can be trusted -- in particular this" >&2
		echo "must not be reported as 'no header'. git said:" >&2
		printf '%s\n' "$RESOLVED_HEADER" | redact_header >&2
		exit 1
	fi
}

owner_of() {
	local url="${1#"${GITHUB_PREFIX}"}"
	printf '%s' "${url%%/*}"
}

# Report every configuration file that registers a github.com extraHeader,
# with its scope, so a recurrence says WHO installed the header and WHERE.
report_header_sources() {
	echo "Configured github.com extraHeader keys in scope (value redacted):"
	local found=0
	local line
	# `--show-origin` prefixes each hit with `file:<path>` / `command line:`.
	while IFS= read -r line; do
		found=1
		printf '  %s\n' "$(printf '%s' "$line" | redact_header)"
	done < <(git config --show-origin --get-regexp \
		'^http\..*\.extraheader$' 2>/dev/null || true)

	if [[ ${GIT_CONFIG_COUNT:-0} != 0 ]]; then
		local i
		for ((i = 0; i < ${GIT_CONFIG_COUNT:-0}; i++)); do
			local key_var="GIT_CONFIG_KEY_${i}"
			[[ ${!key_var:-} == http.*.extraHeader ]] || continue
			found=1
			printf '  environment GIT_CONFIG_KEY_%s: %s\n' "$i" "${!key_var}"
		done
	fi

	((found)) || echo "  (none)"
}

# Print, for each third-party URL, whether a credential would be sent and to
# which owner. This is the discriminating observation: it distinguishes "the
# repo is private/missing" from "we sent an Authorization header we should
# not have".
report_third_party_exposure() {
	local label="$1"
	local url owner header leaking=0
	echo "Third-party fetch exposure (${label}):"
	for url in "${THIRD_PARTY_URLS[@]}"; do
		owner="$(owner_of "$url")"
		resolve_header_or_die "$url"
		header="$RESOLVED_HEADER"
		if [[ -n $header ]]; then
			leaking=1
			printf '  %s [owner: %s] -> Authorization WOULD be sent: %s\n' \
				"$url" "$owner" "$(printf '%s' "$header" | redact_header)"
			printf '      This repository is public and needs no credential. A\n'
			printf '      header here is honoured by nobody and GitHub answers 401,\n'
			printf '      which git reports as "could not read Username".\n'
		else
			printf '  %s [owner: %s] -> no Authorization header (correct)\n' \
				"$url" "$owner"
		fi
	done
	return $((leaking))
}

install_catch_all_reset() {
	local index="${GIT_CONFIG_COUNT:-0}"
	local key="http.${GITHUB_PREFIX}.extraHeader"

	export "GIT_CONFIG_KEY_${index}=${key}"
	export "GIT_CONFIG_VALUE_${index}="
	export GIT_CONFIG_COUNT=$((index + 1))

	if [[ -n ${GITHUB_ENV:-} ]]; then
		{
			printf 'GIT_CONFIG_KEY_%s=%s\n' "$index" "$key"
			printf 'GIT_CONFIG_VALUE_%s=\n' "$index"
			printf 'GIT_CONFIG_COUNT=%s\n' "$((index + 1))"
		} >>"$GITHUB_ENV"
	fi

	printf 'Installed catch-all reset: %s (empty) at GIT_CONFIG index %s.\n' \
		"$key" "$index"
}

main() {
	echo "::group::Nix fetch credential preflight"
	report_header_sources
	echo

	local leaked_before=0
	report_third_party_exposure "before reset" || leaked_before=1
	echo

	install_catch_all_reset
	echo

	local leaked_after=0
	report_third_party_exposure "after reset" || leaked_after=1
	echo

	# Preserve the credential that IS ours: a header scoped to the owner we
	# hold a token for must survive the reset, otherwise private inputs break.
	local own_url="${GITHUB_PREFIX}${CREDENTIALED_OWNER}/"
	resolve_header_or_die "$own_url"
	if [[ -n $RESOLVED_HEADER ]]; then
		printf 'Scoped %s credential preserved across the reset.\n' \
			"$CREDENTIALED_OWNER"
	else
		printf 'No %s-scoped extraHeader configured (nothing to preserve).\n' \
			"$CREDENTIALED_OWNER"
	fi
	echo "::endgroup::"

	if ((leaked_after)); then
		echo "Nix fetch credential preflight failed: an Authorization header" >&2
		echo "is still in scope for a public third-party repository after the" >&2
		echo "catch-all reset. Fetches of that repository will fail with" >&2
		echo "'could not read Username' naming a repository that is public." >&2
		echo "Inspect the header sources printed above." >&2
		exit 1
	fi

	if ((leaked_before)); then
		echo "Note: a catch-all github.com Authorization header was in scope" \
			"and has been neutralised for subsequent steps."
	fi
}

main "$@"
