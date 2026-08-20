#!/usr/bin/env bash
#
# Post (or update) the single "docs preview" comment on a pull request.
#
# ONE comment per pull request, edited in place. A pull request that touches
# the docs is pushed to many times, and a bot that posted a fresh comment per
# push would bury the human review conversation under a wall of near-identical
# notices -- the reason most people end up muting docs bots entirely.
#
# The comment is found again on the next run by a hidden HTML marker in its
# body (invisible when rendered, and not something a human would type), NOT by
# author or by position: the author is `github-actions[bot]`, which also
# authors other comments in this repo, and positions move.
#
# The body always names the COMMIT the preview was built from. Without it a
# reviewer cannot tell whether the page they are looking at includes the change
# they just pushed, which is the one question a preview link exists to answer.
#
# Usage:
#   docs-preview-comment.sh published <pr> <url> <sha>
#   docs-preview-comment.sh removed   <pr>
#
# Environment:
#   GITHUB_TOKEN        a token with `pull-requests: write` (or `issues: write`)
#   GITHUB_REPOSITORY   owner/repo
#   GITHUB_API_URL      optional; defaults to https://api.github.com
#
# Exits non-zero if the comment could not be written. That is deliberate: a
# published preview nobody is told about is indistinguishable from no preview,
# and a silently skipped comment is exactly the kind of failure that survives
# for months.

set -euo pipefail

MARKER="<!-- codetracer-docs-preview -->"

die() {
	echo "docs-preview-comment.sh: ERROR -- $*" >&2
	exit 1
}

MODE="${1:-}"
PR="${2:-}"
[ -n "$MODE" ] || die "usage: $0 published <pr> <url> <sha> | removed <pr>"
# Enumerated digits, not the ranges `[1-9]`/`[0-9]`: a bracket-expression range
# is locale-collated, and under a UTF-8 locale `[0-9]` also matches non-ASCII
# decimal digits. The number goes straight into an API path, so it is pinned to
# ASCII here. Same check, same reasoning, as `resolve_pr_number` in docs.sh.
[[ $PR =~ ^[123456789][0123456789]{0,8}$ ]] || die "'$PR' is not a pull-request number"

API="${GITHUB_API_URL:-https://api.github.com}"
[ -n "${GITHUB_TOKEN:-}" ] || die "GITHUB_TOKEN is not set"
[ -n "${GITHUB_REPOSITORY:-}" ] || die "GITHUB_REPOSITORY is not set"

api() {
	# $1 method, $2 path, $3 optional JSON body. Prints the response body;
	# fails the script on any non-2xx so a broken token or a revoked
	# permission cannot look like "there was simply nothing to do".
	local method="$1" path="$2" body="${3:-}"
	local out status
	out="$(mktemp)"
	local -a args=(
		--silent --show-error --location
		--write-out '%{http_code}' --output "$out"
		--request "$method"
		--header "Authorization: Bearer ${GITHUB_TOKEN}"
		--header "Accept: application/vnd.github+json"
		--header "X-GitHub-Api-Version: 2022-11-28"
	)
	if [ -n "$body" ]; then
		args+=(--header "Content-Type: application/json" --data "$body")
	fi
	status="$(curl "${args[@]}" "${API}${path}")" || {
		rm -f "$out"
		die "$method $path: curl failed"
	}
	if [ "${status:0:1}" != "2" ]; then
		echo "docs-preview-comment.sh: $method $path -> HTTP $status" >&2
		head -c 2000 "$out" >&2
		echo >&2
		rm -f "$out"
		die "the GitHub API rejected $method $path (HTTP $status)"
	fi
	cat "$out"
	rm -f "$out"
}

find_marked_comment() {
	# Echo the id of this pull request's preview comment, or nothing. Paginated
	# explicitly: a long-running pull request can easily pass 100 comments, and
	# a truncated search would silently start posting duplicates.
	local page=1 ids count
	while [ "$page" -le 20 ]; do
		local body
		body="$(api GET "/repos/${GITHUB_REPOSITORY}/issues/${PR}/comments?per_page=100&page=${page}")"
		count="$(printf '%s' "$body" | jq 'length')"
		ids="$(printf '%s' "$body" |
			jq -r --arg marker "$MARKER" '.[] | select(.body // "" | contains($marker)) | .id')"
		if [ -n "$ids" ]; then
			# Oldest wins if a race ever produced two: editing the same one
			# every time is what keeps the count at one.
			printf '%s\n' "$ids" | head -1
			return 0
		fi
		[ "$count" = "100" ] || return 0
		page=$((page + 1))
	done
	return 0
}

build_body() {
	local url="$1" sha="$2"
	local short="${sha:0:7}"
	local now
	now="$(date -u '+%Y-%m-%d %H:%M UTC')"
	cat <<BODY
${MARKER}
## Documentation preview

The docs site as this pull request would leave it:

**${url}**

| | |
| --- | --- |
| Built from | \`${short}\` |
| Updated | ${now} |

Rebuilt on every push that changes the docs, and removed when this pull
request is closed. Excluded from search indexing, so it will not compete with
the published documentation.
BODY
}

build_removed_body() {
	cat <<BODY
${MARKER}
## Documentation preview

This pull request is closed, so its documentation preview has been removed.
BODY
}

case "$MODE" in
published)
	URL="${3:-}"
	SHA="${4:-}"
	[ -n "$URL" ] || die "usage: $0 published <pr> <url> <sha>"
	[ -n "$SHA" ] || die "usage: $0 published <pr> <url> <sha>"
	BODY="$(build_body "$URL" "$SHA")"
	;;
removed)
	BODY="$(build_removed_body)"
	;;
*)
	die "unknown mode '$MODE' (expected 'published' or 'removed')"
	;;
esac

PAYLOAD="$(jq -nc --arg body "$BODY" '{body: $body}')"
EXISTING="$(find_marked_comment)"

if [ -n "$EXISTING" ]; then
	api PATCH "/repos/${GITHUB_REPOSITORY}/issues/comments/${EXISTING}" "$PAYLOAD" >/dev/null
	echo "docs-preview-comment.sh: updated comment $EXISTING on PR #${PR} ($MODE)."
elif [ "$MODE" = "removed" ]; then
	# Nothing was ever announced, so there is nothing to correct. Posting a
	# "the preview has been removed" comment on a pull request that never had
	# one would be pure noise.
	echo "docs-preview-comment.sh: PR #${PR} has no preview comment; nothing to update."
else
	api POST "/repos/${GITHUB_REPOSITORY}/issues/${PR}/comments" "$PAYLOAD" >/dev/null
	echo "docs-preview-comment.sh: posted the preview comment on PR #${PR}."
fi
