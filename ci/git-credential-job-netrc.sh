#!/usr/bin/env bash
# A git credential helper that answers for github.com with the token in the
# job netrc ($MCL_JOB_CREDENTIALS_DIR/netrc), which setup-nix writes and
# refresh-github-token rewrites, so it always hands out the job's current
# token.
#
# Why it exists: Nix fetches a `git+https://` source, and every
# `builtins.fetchGit` (crane vendors a Cargo git dependency that way, at
# evaluation time), by running `git` with no credential of its own. The job's
# git credential is scoped to github.com/metacraft-labs/, so a third-party
# repository went out anonymously, on the fleet's shared per-IP budget, and
# GitHub answered with a 401 that printed
#   fatal: could not read Username for 'https://github.com'
#   error: Failed to fetch git repository 'https://github.com/anza-xyz/crossbeam'
# and failed `nix develop` for Sui's and Agave's Cargo git dependencies.
#
# git asks a helper only after a 401 challenge, so a request the scoped
# extraHeader already authenticates never reaches this. Bash builtins only:
# a macOS runner's PATH need not carry sed or awk.
set -u
[ "${1:-}" = get ] || exit 0

protocol="" host=""
while IFS= read -r line && [ -n "$line" ]; do
	case "$line" in
	protocol=*) protocol="${line#protocol=}" ;;
	host=*) host="${line#host=}" ;;
	esac
done
[ "$protocol" = https ] && [ "$host" = github.com ] || exit 0

netrc="${MCL_JOB_CREDENTIALS_DIR:-}/netrc"
[ -n "${MCL_JOB_CREDENTIALS_DIR:-}" ] && [ -r "$netrc" ] || exit 0

# netrc is whitespace-separated tokens: `machine H login L password P`.
read -r -d '' -a words <"$netrc"
in_github=0 password=""
for ((i = 0; i < ${#words[@]}; i++)); do
	case "${words[i]}" in
	machine) in_github=0; [ "${words[i + 1]:-}" = github.com ] && in_github=1; i=$((i + 1)) ;;
	default) in_github=0 ;;
	password) [ "$in_github" = 1 ] && password="${words[i + 1]:-}"; i=$((i + 1)) ;;
	esac
	[ -n "$password" ] && break
done
[ -n "$password" ] || exit 0
printf 'username=x-access-token\npassword=%s\n' "$password"
