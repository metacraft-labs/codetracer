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

# AN OLD TOKEN IS RENEWED BEFORE IT IS HANDED OUT. An installation token lives
# an hour. When the one in the netrc is CT_GITHUB_TOKEN_MAX_AGE seconds old
# (45 minutes) and the job's refresher (refresh-github-token/keep-refreshing.sh)
# is running, ask it for a new one and wait up to CT_GITHUB_TOKEN_WAIT seconds
# (90) for it. A token handed out stale fails as "Invalid username or token":
# Nix's Cargo git fetches in GPUI shard 20 of run 43996043232, 88 minutes into
# the job, while the refresher's renewal had failed. If the wait runs out, say
# so on stderr, which git shows, and hand out what there is.
cred="$MCL_JOB_CREDENTIALS_DIR"
minted_at() {
	local at=0
	[ -r "$cred/github-token-minted-at" ] && read -r at <"$cred/github-token-minted-at"
	echo "${at:-0}"
}
minted="$(minted_at)"
if [ "$minted" -gt 0 ] 2>/dev/null; then
	now="$(date +%s)"
	if [ $((now - minted)) -ge "${CT_GITHUB_TOKEN_MAX_AGE:-2700}" ]; then
		pid=""
		[ -r "$cred/github-token-refresher.pid" ] && read -r pid <"$cred/github-token-refresher.pid"
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			: >"$cred/github-token-refresh-requested"
			deadline=$((now + ${CT_GITHUB_TOKEN_WAIT:-90}))
			while [ "$(minted_at)" = "$minted" ] && [ "$(date +%s)" -lt "$deadline" ]; do
				sleep 1
			done
		fi
		if [ "$(minted_at)" = "$minted" ]; then
			echo "git-credential-job-netrc: the job's GitHub token is $(((now - minted) / 60)) minutes old and was not renewed; see ${RUNNER_TEMP:-\$RUNNER_TEMP}/keep-refreshing-github-token.log" >&2
		fi
	fi
fi

# netrc is whitespace-separated tokens: `machine H login L password P`.
read -r -d '' -a words <"$netrc"
in_github=0 password=""
for ((i = 0; i < ${#words[@]}; i++)); do
	case "${words[i]}" in
	machine)
		in_github=0
		[ "${words[i + 1]:-}" = github.com ] && in_github=1
		i=$((i + 1))
		;;
	default) in_github=0 ;;
	password)
		[ "$in_github" = 1 ] && password="${words[i + 1]:-}"
		i=$((i + 1))
		;;
	esac
	[ -n "$password" ] && break
done
[ -n "$password" ] || exit 0
printf 'username=x-access-token\npassword=%s\n' "$password"
