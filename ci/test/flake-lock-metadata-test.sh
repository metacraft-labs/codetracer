#!/usr/bin/env bash
# =============================================================================
# flake-lock-metadata-test.sh — every `github` input this repository locks
# directly must record the `lastModified` that GitHub reports for the revision
# it names.
#
# WHY THIS EXISTS
# ---------------
# A flake.lock node is four coupled facts — `rev`, `narHash`, `lastModified`,
# and the `original` ref — and nix checks ALL FOUR when it fetches the input:
#
#     error: mismatch in field 'lastModified' of input
#       '{...,"lastModified":1787817463,"narHash":"sha256-ipDOfSFyPPRRs...",
#         "repo":"codetracer-trace-format-nim",
#         "rev":"e19a92179a2a101b76d2f7887ced16347691c2aa",...}',
#       got '{...,"lastModified":1789112885,"narHash":"sha256-ipDOfSFyPPRRs...",
#         ...same rev...}'
#
# That is a real failure from a real run — 34815351506, the LRC desktop edge,
# which died on ALL FOUR arms before `nix develop` had evaluated anything. The
# `rev` and the `narHash` agreed; only the timestamp did not, and nix refused
# the input anyway.
#
# THE DEFECT CLASS, precisely. `flake.lock` is machine-written, so it gets
# hand-edited: bumping one pin with `nix flake lock --update-input X` re-locks
# far more than the one input, and the tempting alternative is to edit the node
# in place. Commit 4d15c1ea did exactly that for `codetracer-trace-format-nim`
# — a two-line diff that moved `rev` (`d7eca441` -> `e19a9217`) and `narHash`,
# and left `lastModified` at 1787817463, which is `d7eca441`'s commit date
# (2026-08-27T07:57:43Z) and not `e19a9217`'s (2026-09-11T07:48:05Z). Fifteen
# days apart, in a field nobody reads.
#
# It survived review and survived every local shell, because `lastModified` is
# checked only when nix actually FETCHES the input, and in a workspace checkout
# `.envrc` overrides this input with a sibling path so the github node is never
# fetched at all. The first thing that fetched it was CI.
#
# WHAT IT ASSERTS
# ---------------
#   1. For every node this repository's own `flake.nix` declares (the
#      `nodes.root.inputs` set) that is a `github` input pinned to a `rev`:
#      `lastModified` equals the committer date GitHub reports for that `rev`.
#      Transitive nodes are deliberately NOT checked — they come from sibling
#      flakes' own locks and belong to those repositories; a hand-edit in THIS
#      repository can only touch a direct input.
#   2. That it checked a plausible number of them. A lock whose nodes stopped
#      parsing, or an API that answered nothing, would otherwise report a green
#      tick for zero comparisons — which is the exact shape of rot this suite
#      exists to catch elsewhere.
#
# WHAT IT DELIBERATELY DOES NOT ASSERT
# ------------------------------------
# That `narHash` matches. It would be the stronger check and it is the one nix
# itself makes, but it costs a full fetch of every input — hundreds of megabytes
# per run — and it is already enforced, loudly, by the first `nix` invocation in
# any lane. This suite exists to catch the field that fetch-free review misses,
# at one HTTP request per input.
#
# It also does not assert anything about non-`github` inputs (`git+https`,
# `path`, ...). Those carry no `rev`/commit-date pairing this check can compare.
#
# Run: bash ci/test/flake-lock-metadata-test.sh
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

LOCK=flake.lock

# The lock declares 31 direct `github` inputs today. Inputs come and go, so the
# floor is deliberately well below that and only has to be high enough that a
# parse which silently produced nothing cannot pass.
MIN_CHECKED=15

PASS=0
FAIL=0

pass() {
	PASS=$((PASS + 1))
	printf '  ok    %s\n' "$1"
}

fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL  %s\n' "$1" >&2
	if [ -n "${2:-}" ]; then
		printf '        %s\n' "$2" >&2
	fi
}

# -----------------------------------------------------------------------------
# Skip loudly, never silently -- and never at all in CI. Same discipline as
# ci/test/crates-io-download-url-test.sh: off a runner, a developer without a
# GitHub token should be told this did not run, not handed a green tick; in CI
# the token is there by construction and a skip would hide the defect.
# -----------------------------------------------------------------------------
in_ci() { [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; }

bail_or_skip() { # reason
	if in_ci; then
		cat >&2 <<-EOF
			ERROR: ci/test/flake-lock-metadata-test.sh cannot run.
			Reason: $1
			This is a hard failure in CI. Skipping here would report a green tick
			for a check that compared nothing.
		EOF
		exit 1
	fi
	printf 'SKIPPED: %s\n' "$1"
	printf '(this is a hard failure in CI; it is a skip only off a CI runner)\n'
	exit 0
}

[ -f "$LOCK" ] || bail_or_skip "$LOCK does not exist"
command -v python3 >/dev/null 2>&1 || bail_or_skip "python3 is not on PATH"

# `gh` first because it carries the runner's own credentials; a bare curl is the
# fallback for a shell that has a token but not the CLI. Unauthenticated GitHub
# allows 60 requests an hour and this suite makes about 30, so an anonymous run
# would fail for a reason that has nothing to do with the lock -- refuse it
# rather than report that.
FETCH=
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
	FETCH=gh
elif command -v curl >/dev/null 2>&1 && [ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]; then
	FETCH=curl
else
	bail_or_skip "no authenticated GitHub access (need 'gh auth status' to pass, or GITHUB_TOKEN/GH_TOKEN with curl)"
fi

# `gh` on a Windows developer checkout emits CRLF; a trailing carriage return
# survives command substitution (which strips only newlines) and would make
# every comparison below fail while printing two identical-looking timestamps.
# The python helper emits LF by construction; this covers the other producer.
strip_cr() { printf '%s' "${1%%$'\r'}"; }

commit_date() { # owner repo rev -> ISO8601 committer date, or empty
	local owner=$1 repo=$2 rev=$3
	if [ "$FETCH" = gh ]; then
		gh api "repos/$owner/$repo/commits/$rev" --jq '.commit.committer.date' 2>/dev/null
	else
		# -L, because GitHub answers a renamed or transferred repository with
		# `301 Moved Permanently` to its /repositories/<id>/ URL. `gh api`
		# follows that; a bare curl returned the 260-byte redirect notice, the
		# helper found no date in it, and the suite reported
		# facebook/yoga@3acb6cca42 as a revision the repository "does not have"
		# -- it does. The redirect stays on api.github.com, so curl keeps the
		# Authorization header across it.
		curl -sS -L --max-time 30 \
			-H "Authorization: Bearer ${GITHUB_TOKEN:-${GH_TOKEN:-}}" \
			-H "Accept: application/vnd.github+json" \
			"https://api.github.com/repos/$owner/$repo/commits/$rev" 2>/dev/null |
			python3 "$REPO_ROOT/ci/test/flake-lock-metadata-test.py" committer-date 2>/dev/null
	fi
}

echo "flake.lock metadata contract ($LOCK, direct github inputs)"

# name<TAB>owner<TAB>repo<TAB>rev<TAB>lastModified, one per direct github input.
ROWS=$(python3 "$REPO_ROOT/ci/test/flake-lock-metadata-test.py" rows "$LOCK")

if [ -z "$ROWS" ]; then
	fail "$LOCK names direct github inputs" \
		"parsed zero of them; either the lock changed shape or the parse broke"
	echo
	printf '%d passed, %d failed\n' "$PASS" "$FAIL"
	exit 1
fi

CHECKED=0
MISMATCHED=0
UNRESOLVED=0

while IFS=$'\t' read -r name owner repo rev locked_lm; do
	[ -n "$name" ] || continue
	iso=$(strip_cr "$(commit_date "$owner" "$repo" "$rev")")
	if [ -z "$iso" ]; then
		UNRESOLVED=$((UNRESOLVED + 1))
		fail "$name: GitHub knows $owner/$repo@${rev:0:10}" \
			"the API returned no committer date. A lock naming a revision its repository does not have is not a lock."
		continue
	fi
	actual=$(python3 "$REPO_ROOT/ci/test/flake-lock-metadata-test.py" to-epoch "$iso" 2>/dev/null)
	CHECKED=$((CHECKED + 1))
	if [ "$actual" = "$locked_lm" ]; then
		continue
	fi
	MISMATCHED=$((MISMATCHED + 1))
	fail "$name: lastModified matches $owner/$repo@${rev:0:10}" \
		"locked $locked_lm, GitHub says $actual ($iso). nix refuses the input outright with \"mismatch in field 'lastModified'\". A node whose rev was edited by hand without its timestamp looks exactly like this."
done <<ROWS_EOF
$ROWS
ROWS_EOF

if [ "$MISMATCHED" -eq 0 ] && [ "$UNRESOLVED" -eq 0 ]; then
	pass "all $CHECKED direct github inputs record GitHub's own commit date"
fi

if [ "$CHECKED" -ge "$MIN_CHECKED" ]; then
	pass "the comparison is not vacuous ($CHECKED inputs checked, floor $MIN_CHECKED)"
else
	fail "the comparison is not vacuous" \
		"only $CHECKED input(s) were compared, below the floor of $MIN_CHECKED. A green tick here would mean nothing."
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
