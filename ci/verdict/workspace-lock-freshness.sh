#!/usr/bin/env bash
# =============================================================================
# Alarm: the shared manifests repo is still receiving workspace locks for this
# repo's commits.
#
# # Why this file exists
#
# Until 2026-08-04, "is this commit locked?" was answered on every run as a side
# effect: `setup-dev-env` resolved each cross-repo sibling's revision from the
# per-commit workspace lock, so an unlocked commit could not get past
# `Setup dev env`. That coupling was a terrible gate — it took six jobs down in
# their first real step and left nine more `skipped` for eight days — and the
# `siblings:` entries now name their refs explicitly so it cannot happen again.
#
# But that coupling was also the ONLY thing anyone was watching. Removing it
# fixes the pipeline and silences the alarm in the same stroke, and the
# underlying condition is not small:
#
#   Nothing has been committed to metacraft-labs/metacraft-manifests, for ANY
#   repo, since 2026-08-02 (`b3b0ac6 Publish 1 workspace lock entry`).
#
# Those per-commit locks are what make a published workspace state reproducible.
# A stall means no reproducible snapshot of the workspace exists for any commit
# in that window — a fact about the whole workspace, not about CI.
#
# The failure is quieter than "the tooling broke". `repro`'s post-commit hook
# still WRITES the lock, into a workspace-local checkout of the manifests repo,
# and logs `ok wrote <path>` and exits 0. It is the commit-and-push that stopped:
# the files sit untracked in that checkout. On 2026-08-13 a developer's checkout
# held twenty untracked codetracer locks, including one for the exact commit CI
# was reporting as unlocked. The tooling's success message was true and useless
# — the artefact existed on one disk and nowhere else.
#
# So this job exists to say that out loud, on every run, in its own name.
#
# # Why it is a job and not a gate
#
# Nothing declares `needs:` on this job and it is absent from
# `ci/verdict/required-jobs.txt`. That is deliberate, and it is the whole design:
# a red check here must never be able to skip a test job. Coupling lock
# publication to the test suite is precisely the defect this repo just spent a
# PR undoing; re-introducing it as a gate would trade an eight-day outage for
# the next one. It is loud (a named, red check on every run) and structurally
# incapable of cascading.
#
# # What is asserted
#
# TWO things, and they are different questions with different remedies:
#
#   1. A LOCK EXISTS for the commit under test, or for its first parent (the
#      same two candidates `clone-siblings` probes, and the same `--no-walk`
#      reasoning: CI checkouts are shallow, so an ancestry walk would hide the
#      diagnosis rather than answer it).
#
#   2. THAT LOCK PINS EVERY SIBLING REPO THIS COMMIT DECLARES. Declaring a repo
#      does not put it in a lock and nothing else noticed when it failed to
#      arrive — see "THE DECLARED SIBLING SET" further down for the mechanism,
#      the four repos it has already cost, and why the declared set is derived
#      rather than listed here.
#
# Resolution is delegated to `scripts/resolve-sibling-rev.sh`, the repo's
# existing resolver — it already knows both lock layouts (nested and flat) and
# both spellings (repo-workspaces `.xml`, reprobuild `.toml`), and it carries
# its own 51-assertion contract suite. Its exit 3 is its only "this commit is
# not locked" answer; its 4 is "the lock exists and does not name this repo",
# which is question 2 above; its 5/6 mean the lock exists but is malformed or
# self-contradictory, which is a different and worse report than either.
#
# # No mocks
#
# The input is a real checkout of the manifests repo, cloned by the caller.
# `--manifest-dir` exists so the check can be exercised against a fixture
# directory offline, not so CI can be handed a stub.
#
# # Why there is a grace window
#
# Locks are published ASYNCHRONOUSLY, by the pusher's pre-push hook, into a
# different repo than the one CI checked out — so the alarm and the publisher
# race, and this alarm used to lose. It answered from the single clone the
# workflow handed it: for 84a8b633 that clone ran at 14:10:09 and the lock
# landed at 14:11:03, 54 seconds later, by which time the check had already
# said "missing". The workflow's two candidates (HEAD and HEAD^) blunted this
# into intermittency rather than fixing it — which is worse, because an alarm
# that is red on some commits and green on others with no change between them
# teaches its readers to discount it, and that is the exact disease this whole
# campaign is about.
#
# So absence is now something the check EARNS rather than assumes: it
# re-fetches the manifests repo and re-probes until either a lock appears or a
# bounded window expires.
#
# THE BOUND IS 300 SECONDS, and the reasoning matters more than the number.
# The 54s instance is one sample, not a specification, and the mechanism that
# sets this distribution's tail is not raw network latency — it is contention
# on the shared manifests remote, which several live sessions write
# concurrently, so a push can be refused as a non-fast-forward and retried
# after a fetch/rebase. Five minutes covers several such rounds (~5.5x the one
# observed sample, so it is not fitted to it) while costing nothing that
# matters: this alarm does no build, runs on a stock hosted runner, and
# RELEASES that runner the instant a fetch finds the lock, so the healthy case
# pays nothing. Past ~5 minutes we would be buying vanishing race coverage with
# real reporting delay, and a lock still absent after five minutes is far more
# likely to be the publication stall this alarm was built for than a slow push.
#
# Three properties of the window are deliberate, and each is pinned by a
# contract in the suite:
#
#   * It PREFERS FETCHING TO SLEEPING. Every round re-fetches; when the fetch
#     moves the ref the check re-probes at once instead of sitting out the
#     poll interval. A fetch that finds the ref is faster and more honest than
#     a fixed wait.
#   * It is only ever spent on a question waiting can answer, which is exactly
#     one question: "has the lock for this commit been published yet?". A lock
#     that EXISTS but cannot be trusted (resolver 5/6), a lock that EXISTS and
#     is missing a declared repo (resolver 4 — waiting cannot add a repo to a
#     lock that is already published), and a `--manifest-dir` with no upstream
#     to re-fetch from are all reported IMMEDIATELY: waiting could not change
#     any of them.
#   * It ends. When the lock is genuinely never coming the check still reports,
#     in full, at the bound. Curing this flake by learning to say nothing would
#     be a far worse defect than the flake.
#
# If every re-fetch failed, the check did not observe absence — it failed to
# look — and it says so instead of blaming publication. It stays red either
# way; an alarm must not go quiet because its own network broke.
#
# # Why it also reads the publisher's trigger list
#
# "No workspace lock for codetracer (candidates: b4738be9)" names the missing
# thing and not one word about the cause, and the difference is not cosmetic:
# the two causes have disjoint remedies and one of them cannot be acted on from
# a workspace at all.
#
#   PUBLICATION STALLED — the branch IS a publishing branch, and the record for
#   this commit was not produced or not pushed. Remedy is in the workspace (see
#   the post-commit log this report already points at).
#
#   BRANCH NOT COVERED — no publisher is configured to run for this branch, so
#   no record was ever going to exist for ANY of its commits. Nothing a
#   developer does to their checkout changes that; the remedy is one line in
#   `.github/workflows/publish-workspace-lock.yml`.
#
# The second cause is why this alarm is being taught to distinguish them.
# Measured on 2026-09-03: 24 of the last 60 commits on `dev` carried a lock and
# 0 of the last 60 on `cloud` did — because `cloud` was absent from that
# workflow's `branches:` lists. Every pull request into `cloud` therefore died
# at `Setup isonim siblings`, and this alarm — the one job whose entire purpose
# is to explain a missing lock — was reporting the workspace-side cause, which
# was the wrong one. It had all the evidence needed to say so: the publisher's
# trigger list is a file in this very checkout.
#
# So the branch coverage is DERIVED, from that workflow, at report time. It is
# not a constant here, because a constant would drift out of agreement with the
# workflow silently and this check would go back to guessing.
#
# Usage:
#   ci/verdict/workspace-lock-freshness.sh --manifest-dir DIR --sha SHA [--sha PARENT_SHA]
#                                          [--branch NAME] [--publisher-workflow FILE]
#                                          [--sibling-list FILE] [--workflow-dir DIR]
#                                          [--grace-seconds N] [--poll-seconds N]
#   ci/verdict/workspace-lock-freshness.sh --list-declared
#
#   --branch NAME      the branch the commit under test is on. When given, the
#                      report says whether a publisher is configured for it.
#                      Omitted (or empty) => that question is not answered
#                      rather than answered wrongly.
#   --publisher-workflow FILE
#                      the workflow whose `branches:` lists define which
#                      branches get a lock published. Default:
#                      `.github/workflows/publish-workspace-lock.yml` in this
#                      checkout. Overridable so the contract suite can drive
#                      both verdicts from fixtures.
#   --sibling-list FILE
#                      the names-only central declaration list. Default:
#                      `.github/sibling-repos` in this checkout.
#   --workflow-dir DIR the directory whose `*.yml` `siblings:` blocks are
#                      scanned for BARE declarations. Default:
#                      `.github/workflows` in this checkout. Both are
#                      overridable ONLY so the contract suite can drive the
#                      derivation from fixtures; CI uses the defaults.
#   --list-declared    print the derived declared set, one name per line, and
#                      exit 0. Nothing else is read and no lock is probed. This
#                      is how the contract suite proves the derivation reads the
#                      real declarations rather than a constant.
#   --grace-seconds N  how long a missing lock may still arrive (default 300).
#   --poll-seconds N   pause between re-fetches when the ref did not move
#                      (default 15). Both exist so the contract suite can
#                      compress the window into seconds; CI uses the defaults.
#
# Exit: 0 a lock exists and pins every declared sibling repo
#     · 1 no lock, or no trustworthy answer (the alarm)
#     · 2 usage error, including a declared set that derived to nothing (an
#         empty set would pass every lock, so it is refused, not reported green)
#     · 4 a lock exists and is well-formed, but one or more DECLARED sibling
#         repos are absent from it — distinct from 1 because the remedy is
#         different: nothing about publication is broken, the declaration never
#         reached a lock and never will on its own
# Lane: the `workspace-lock-freshness` job (stock ubuntu-latest, bash + git).
# Contract suite: ./workspace-lock-freshness-test.sh — run it after any change
# here; the decisive fixture is a lock that arrives while the check is running.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO_ROOT
readonly RESOLVER="$REPO_ROOT/scripts/resolve-sibling-rev.sh"

MANIFEST_DIR=""
SHAS=()
GRACE_SECONDS=300
POLL_SECONDS=15
BRANCH=""
PUBLISHER_WORKFLOW="$REPO_ROOT/.github/workflows/publish-workspace-lock.yml"
SIBLING_LIST="$REPO_ROOT/.github/sibling-repos"
WORKFLOW_DIR="$REPO_ROOT/.github/workflows"
LIST_DECLARED=0

usage() {
	echo "usage: workspace-lock-freshness.sh --manifest-dir DIR --sha SHA [--sha SHA]" \
		"[--branch NAME] [--publisher-workflow FILE]" \
		"[--sibling-list FILE] [--workflow-dir DIR]" \
		"[--grace-seconds N] [--poll-seconds N] | --list-declared" >&2
	exit 2
}

# A window that cannot be parsed must not silently become an unbounded wait, so
# anything but a non-negative integer is a usage error rather than a default.
require_uint() {
	case "${1:-}" in
	'' | *[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--manifest-dir)
		MANIFEST_DIR="${2:-}"
		shift 2
		;;
	--sha)
		[ -n "${2:-}" ] && SHAS+=("$2")
		shift 2
		;;
	--branch)
		BRANCH="${2:-}"
		shift 2
		;;
	--publisher-workflow)
		PUBLISHER_WORKFLOW="${2:-}"
		shift 2
		;;
	--sibling-list)
		SIBLING_LIST="${2:-}"
		shift 2
		;;
	--workflow-dir)
		WORKFLOW_DIR="${2:-}"
		shift 2
		;;
	--list-declared)
		LIST_DECLARED=1
		shift
		;;
	--grace-seconds)
		require_uint "${2:-}" || usage
		GRACE_SECONDS="$2"
		shift 2
		;;
	--poll-seconds)
		require_uint "${2:-}" || usage
		POLL_SECONDS="$2"
		shift 2
		;;
	*)
		usage
		;;
	esac
done

# =============================================================================
# THE DECLARED SIBLING SET — derived, never hard-coded.
#
# Two questions are asked of the lock, and until 2026-09-05 this file could only
# ask the first:
#
#   1. DOES A LOCK EXIST for the commit under test? Any single entry answers
#      that, so ONE sibling (the LEAD, below) is enough — and one probe is what
#      the wait loop wants, since it re-runs every round.
#
#   2. DOES THE LOCK CARRY EVERY REPO THIS COMMIT DECLARES? Only the full
#      declared set can answer that, and nothing anywhere asked it. A repo is
#      DECLARED here; locks are PRODUCED elsewhere — by a developer's pre-push
#      hook (whose repo set is whatever that developer had checked out) or by
#      the server-side re-anchor in publish-workspace-lock.yml, which copies
#      "every sibling pin verbatim" from an older lock. Neither producer reads
#      the declarations. So a NEWLY declared bare-name repo has no pin to copy,
#      is silently absent from that lock and from every lock carried forward
#      from it, and the carry sustains the hole indefinitely. It surfaced only
#      at build time, as `resolve-sibling-rev: sibling '<name>' not present in
#      lock` (exit 4), taking out every job that reached the action. That has
#      already happened: isonim-tui, isonim-gpui, nim-termctl and nim-pty (see
#      ci/test/sibling-provisioning-test.sh).
#
# WHAT THIS FILE USED TO DO. It probed exactly one hard-coded name,
# `codetracer-trace-format`, justified by a comment claiming that name "is in
# every one of this repo's sibling lists". That was FALSE — `.github/sibling-
# repos` names codetracer-launcher, codetracer-trace-format-nim and the three
# recorders, and not codetracer-trace-format at all — so a lock missing any
# other declared repo passed green here. The comment is gone with the constant.
#
# WHY DERIVED. A hard-coded list drifts out of agreement with the declarations
# silently, which is the same disease one layer up: the check would go on
# passing for a repo nobody had added to it. The two declaration sites are read
# directly instead.
#
#   `.github/sibling-repos`   names-only central list, one repo per line.
#   `.github/workflows/*.yml` the BARE entries of `siblings:` (and
#                             `extra-siblings:`) block scalars. Bare means "no
#                             `=`": `clone-siblings` resolves such an entry FROM
#                             the lock, whereas `name=ref` bypasses the lock
#                             entirely and so is none of this check's business.
#                             `${{ ... }}` items are expressions, not names, and
#                             are skipped rather than probed as literals.
# =============================================================================

# declared_pairs — print "<name><TAB><where it was declared>", one per line,
# with duplicates left in (the caller aggregates). Prints nothing readable? Then
# the caller refuses to run rather than probing an empty set: a check with no
# names to probe is a vacuous pass, which is worse than no check.
declared_pairs() {
	local f rel
	if [ -n "$SIBLING_LIST" ] && [ -r "$SIBLING_LIST" ]; then
		rel="${SIBLING_LIST#"$REPO_ROOT"/}"
		awk -v src="$rel" '
			{ sub(/#.*/, "", $0); gsub(/[ \t]/, "", $0) }
			# BARE_NAME (see the workflow parser below for why this shape is the
			# only test): this file is documented as names-only, but a `name=ref`
			# that slipped in would bypass the lock, so probing it would be a
			# false alarm about a revision the lock was never asked for.
			$0 ~ /^[A-Za-z0-9._-]+$/ { print $0 "\t" src }
		' "$SIBLING_LIST"
	fi
	[ -n "$WORKFLOW_DIR" ] && [ -d "$WORKFLOW_DIR" ] || return 0
	for f in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
		[ -r "$f" ] || continue
		rel="${f#"$REPO_ROOT"/}"
		awk -v src="$rel" '
			function indent_of(s) { match(s, /^[ \t]*/); return RLENGTH }
			{
				line = $0
				sub(/#.*/, "", line)
				sub(/[ \t]+$/, "", line)
			}
			# A `siblings:` / `extra-siblings:` key introducing a block scalar.
			line ~ /^[ \t]*(extra-)?siblings:[ \t]*\|?[ \t]*$/ {
				in_block = 1
				key_indent = indent_of(line)
				next
			}
			# A less-or-equally indented mapping key closes the block.
			line ~ /^[ \t]*[^ \t-]/ && indent_of(line) <= key_indent { in_block = 0 }
			in_block {
				if (line ~ /^[ \t]*$/) next          # blank / comment-only line
				if (indent_of(line) <= key_indent) { in_block = 0; next }
				item = line
				sub(/^[ \t]*-?[ \t]*/, "", item)
				# BARE_NAME. ONE test, deliberately, and it is a positive one: a
				# bare declaration is a plain repo name and nothing else. That
				# single shape excludes, in one place, everything this check must
				# not probe -- `name=ref` and `name=<40-hex>` (which bypass the
				# lock entirely, so the lock was never asked about them), and
				# `${{ ... }}` expressions (which are not names at all).
				#
				# An earlier draft spelled those out as three consecutive
				# guards. Every contract still passed with any ONE of them
				# deleted, because the next one caught the same entry -- the
				# exact "two guards can hide each other" hazard this check`s
				# contract suite has a whole header section about. Three guards
				# for one property means none of them is covered. One is.
				if (item !~ /^[A-Za-z0-9._-]+$/) next
				print item "\t" src
			}
		' "$f"
	done
}

# declared_names — the deduplicated, sorted set of declared bare sibling names.
declared_names() {
	declared_pairs | cut -f1 | sort -u
}

# declaring_sites NAME — where that name was declared, space separated.
declaring_sites() {
	declared_pairs | awk -F'\t' -v n="$1" '$1 == n { print $2 }' | sort -u | tr '\n' ' '
}

DECLARED_NAMES="$(declared_names)"
DECLARED_COUNT=0
if [ -n "$DECLARED_NAMES" ]; then
	DECLARED_COUNT="$(printf '%s\n' "$DECLARED_NAMES" | wc -l | tr -d ' ')"
fi
readonly DECLARED_NAMES DECLARED_COUNT

if [ "$LIST_DECLARED" -eq 1 ]; then
	[ "$DECLARED_COUNT" -gt 0 ] && printf '%s\n' "$DECLARED_NAMES"
	exit 0
fi

if [ -z "$MANIFEST_DIR" ] || [ "${#SHAS[@]}" -eq 0 ]; then
	usage
fi

# A check with nothing to probe would pass every lock ever written. That is a
# configuration error in THIS invocation, not a verdict about the lock, so it
# exits 2 with the two paths it read rather than quietly reporting success.
if [ "$DECLARED_COUNT" -eq 0 ]; then
	echo "::error::workspace-lock-freshness: no declared sibling repos could be derived from '${SIBLING_LIST}' or the \`siblings:\` blocks under '${WORKFLOW_DIR}'. Probing an empty set would pass every lock, so this is refused rather than reported green." >&2
	exit 2
fi

# The LEAD is the one name the wait loop re-probes each round to answer "does a
# lock exist at all?". Which name it is does not matter — any entry proves the
# lock exists, and every declared name is swept once the wait is over — so it is
# simply the first in sorted order, which makes it stable across runs.
LEAD_SIBLING="$(printf '%s\n' "$DECLARED_NAMES" | head -n1)"
readonly LEAD_SIBLING
# A zero poll with a non-zero window would spin the loop as fast as git can
# fetch, hammering the shared remote for no extra coverage.
[ "$POLL_SECONDS" -lt 1 ] && POLL_SECONDS=1
readonly GRACE_SECONDS POLL_SECONDS

# The all-zero SHA is what GitHub reports for a branch's first push; it is not a
# commit and must not be probed.
readonly ZERO_SHA="0000000000000000000000000000000000000000"

locked_sha=""
untrusted=""

# publisher_branches — print, one per line, every branch named in a `branches:`
# list in the publisher workflow.
#
# Both YAML spellings are accepted, because either is valid and a check that
# understood only one would report "not covered" for a branch that IS covered —
# the most expensive way this could be wrong:
#
#     branches: [dev, cloud]          flow sequence
#     branches:                       block sequence
#       - dev
#       - cloud
#
# Comments are stripped first, so a branch named only inside a comment (this
# file's own prose does exactly that) is never mistaken for configuration.
#
# It does NOT try to distinguish the `push:` list from the `pull_request_target:`
# one. Either trigger publishes a lock for the branch, so for the question
# actually being asked — "is anything configured to publish for this branch?" —
# the union is the honest answer, and a union needs no YAML nesting model to
# compute. Prints nothing if the file is unreadable; the caller treats "no
# branches found" as unknown rather than as "not covered", because an empty
# parse is far more likely to be this parser failing than a publisher genuinely
# configured for zero branches.
publisher_branches() {
	[ -n "$PUBLISHER_WORKFLOW" ] && [ -r "$PUBLISHER_WORKFLOW" ] || return 0
	awk '
		{ sub(/#.*/, "", $0) }
		# A `branches:` key. Anything on the same line is a flow sequence.
		/^[[:space:]]*branches:/ {
			rest = $0
			sub(/^[[:space:]]*branches:[[:space:]]*/, "", rest)
			gsub(/[][,"'"'"']/, " ", rest)
			n = split(rest, parts, /[[:space:]]+/)
			for (i = 1; i <= n; i++)
				if (parts[i] != "") print parts[i]
			# An empty remainder means the items follow as a block sequence.
			in_block = (rest ~ /^[[:space:]]*$/)
			next
		}
		in_block && /^[[:space:]]*-[[:space:]]*[^[:space:]]/ {
			item = $0
			sub(/^[[:space:]]*-[[:space:]]*/, "", item)
			gsub(/["'"'"']/, "", item)
			sub(/[[:space:]]+$/, "", item)
			if (item != "") print item
			next
		}
		# Any other non-blank line ends a block sequence.
		/[^[:space:]]/ { in_block = 0 }
	' "$PUBLISHER_WORKFLOW"
}

# publisher_covers BRANCH — 0 if a publisher is configured for it, 1 if not,
# 2 if the question could not be answered (no branch given, or nothing parsed).
publisher_covers() {
	local want="$1" b found=1 any=0
	[ -n "$want" ] || return 2
	while IFS= read -r b; do
		[ -n "$b" ] || continue
		any=1
		[ "$b" = "$want" ] && found=0
	done <<EOF
$(publisher_branches)
EOF
	[ "$any" -eq 0 ] && return 2
	return "$found"
}

# probe_sibling NAME SHA — the resolver's exit code, nothing else.
probe_sibling() {
	local rc=0
	"$RESOLVER" --repo codetracer --sibling "$1" \
		--manifest-dir "$MANIFEST_DIR" --sha "$2" --no-walk >/dev/null 2>&1 </dev/null || rc=$?
	return "$rc"
}

# One pass over the candidate SHAs against whatever is on disk right now.
# Answers ONLY question 1 — does a lock exist? — because this runs on every
# round of the wait loop and the full declared sweep would multiply that cost by
# the size of the declared set for no extra information: waiting cannot add a
# repo to a lock that already exists.
probe_candidates() {
	local sha rc
	locked_sha=""
	untrusted=""
	for sha in "${SHAS[@]}"; do
		[ "$sha" = "$ZERO_SHA" ] && continue
		rc=0
		probe_sibling "$LEAD_SIBLING" "$sha" || rc=$?
		case "$rc" in
		0)
			locked_sha="$sha"
			return 0
			;;
		3)
			# Not locked. Try the next candidate — this is the only code that
			# means "keep looking", and the only one the grace window is for.
			;;
		4)
			# A lock EXISTS for this sha and simply does not pin the LEAD. That
			# is question 2, answered by the sweep below against the full
			# declared set — not a reason to spend the window, and (since
			# 2026-09-05) not lumped in with 5/6 as "untrustworthy" either: the
			# lock is perfectly well-formed, it is the declaration that never
			# reached it.
			locked_sha="$sha"
			return 0
			;;
		*)
			# 5/6: a lock EXISTS but cannot be trusted — malformed, or two locks
			# for one commit disagreeing. A different report, and not the stall
			# this watches for. Waiting cannot turn a broken lock into a good
			# one, so this ends the window immediately rather than spending it.
			untrusted="$sha (resolver exit $rc)"
			return 0
			;;
		esac
	done
	return 1
}

# sweep_declared SHA — question 2. Probes EVERY declared name against the lock
# for SHA and sets, in the CALLING shell (no command substitution: the results
# are two values, and a subshell would silently drop the second):
#
#   MISSING_DECLARED  newline-separated names the lock does not pin
#   SWEEP_UNTRUSTED   non-empty if some name came back 5/6
MISSING_DECLARED=""
SWEEP_UNTRUSTED=""
sweep_declared() {
	local sha="$1" name rc
	MISSING_DECLARED=""
	SWEEP_UNTRUSTED=""
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		rc=0
		probe_sibling "$name" "$sha" || rc=$?
		case "$rc" in
		0) : ;;
		3 | 4)
			# 4 is the operative one: a lock exists and does not pin this repo.
			# 3 can only appear if the lock vanished mid-sweep; the repo is
			# equally unresolvable for this commit either way, and reporting it
			# as missing is the honest answer to "can this build clone it?".
			MISSING_DECLARED="${MISSING_DECLARED}${name}
"
			;;
		*) SWEEP_UNTRUSTED="$sha (resolver exit $rc for sibling '$name')" ;;
		esac
	done <<EOF
$DECLARED_NAMES
EOF
}

# Can this manifest dir even receive a late lock? A real clone can; the offline
# fixture directory `--manifest-dir` also accepts cannot, and giving one a
# grace window would be pure latency in exchange for nothing.
manifest_remote=""
manifest_branch=""
if git -C "$MANIFEST_DIR" rev-parse --git-dir >/dev/null 2>&1; then
	manifest_branch="$(git -C "$MANIFEST_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
	manifest_remote="$(git -C "$MANIFEST_DIR" remote 2>/dev/null | head -n1)"
fi
refreshable=0
if [ -n "$manifest_remote" ] && [ -n "$manifest_branch" ]; then
	refreshable=1
fi

fetch_attempts=0
# Counts only rounds where the fetch AND the fast-forward both landed, i.e.
# where the files the resolver reads were actually brought up to date. A fetch
# whose fast-forward was refused left the checkout as stale as before, so
# counting it as a success would let the check claim it looked when it did not.
refresh_successes=0

# refresh_manifest — bring the checkout up to date with its upstream.
# Exit: 0 the ref moved · 1 the fetch or the fast-forward failed
#     · 2 fetched, nothing new.
#
# Fast-forward, never `reset --hard`: `--manifest-dir` may legitimately be a
# developer's own manifests checkout, and an alarm has no business discarding
# work there. A refused fast-forward is reported, not forced.
refresh_manifest() {
	local before after
	before="$(git -C "$MANIFEST_DIR" rev-parse HEAD 2>/dev/null || true)"
	fetch_attempts=$((fetch_attempts + 1))
	if ! git -C "$MANIFEST_DIR" fetch --quiet "$manifest_remote" "$manifest_branch" >/dev/null 2>&1; then
		return 1
	fi
	if ! git -C "$MANIFEST_DIR" merge --ff-only --quiet FETCH_HEAD >/dev/null 2>&1; then
		return 1
	fi
	refresh_successes=$((refresh_successes + 1))
	after="$(git -C "$MANIFEST_DIR" rev-parse HEAD 2>/dev/null || true)"
	[ "$before" != "$after" ] && return 0
	return 2
}

started_at="$(date +%s)"
deadline=$((started_at + GRACE_SECONDS))
waited=0  # set once the loop exits, from started_at

while :; do
	probe_candidates && break

	# Nothing upstream could deliver a late lock — answer from what we have,
	# and say further down that that is what happened.
	[ "$refreshable" -eq 0 ] && break

	# THE ONE BOUND. Deliberately the only deadline test in this loop: both
	# ways round the loop pass back through here, so there is a single place
	# that can end the wait and a single place to get right. An earlier draft
	# also re-tested the deadline just before sleeping; that second test made
	# each one individually removable without any fixture noticing, which is
	# how a bound stops being a bound. One check, and the suite's `churn`
	# contract drives the fast path through it.
	now="$(date +%s)"
	[ "$now" -ge "$deadline" ] && break

	refresh_rc=0
	refresh_manifest || refresh_rc=$?
	# The ref moved: re-probe at once rather than sitting out the interval —
	# this is what makes an arriving lock cheap to notice. It loops back to the
	# bound above, and each round costs a real fetch, so it cannot spin.
	[ "$refresh_rc" -eq 0 ] && continue

	# `now` predates the fetch, and the bound above guarantees it was still
	# before the deadline, so this is always >= 1. Overshoot is at most one
	# fetch's duration, and the bound catches it on the next pass.
	remaining=$((deadline - now))
	if [ "$remaining" -lt "$POLL_SECONDS" ]; then
		sleep "$remaining"
	else
		sleep "$POLL_SECONDS"
	fi
done

waited=$(($(date +%s) - started_at))

# How stale is the shared repo overall? Reported either way: a lock for THIS
# commit does not prove publication is healthy for everyone else.
newest_lock_date="$(git -C "$MANIFEST_DIR" log -1 --format=%ad --date=short -- locks/ 2>/dev/null || true)"
[ -z "$newest_lock_date" ] && newest_lock_date="unknown"

if [ -n "$untrusted" ]; then
	echo "::error::A workspace lock exists for $untrusted but cannot be used. This is not a publication stall; read the resolver's diagnostic."
	exit 1
fi

if [ -n "$locked_sha" ]; then
	# A LOCK EXISTS. Now question 2: does it carry every repo this commit
	# declares? See "THE DECLARED SIBLING SET" at the top.
	sweep_declared "$locked_sha"

	if [ -n "$SWEEP_UNTRUSTED" ]; then
		echo "::error::A workspace lock exists for $SWEEP_UNTRUSTED but cannot be used. This is not a publication stall; read the resolver's diagnostic."
		exit 1
	fi

	if [ -n "$MISSING_DECLARED" ]; then
		missing_count="$(printf '%s' "$MISSING_DECLARED" | grep -c . || true)"
		echo "::error::${missing_count} declared sibling repo(s) are absent from the workspace lock for ${locked_sha}: $(printf '%s' "$MISSING_DECLARED" | tr '\n' ' ')"
		cat <<EOF

==============================================================
  DECLARED SIBLING REPOS ARE MISSING FROM THE WORKSPACE LOCK
==============================================================

A workspace lock DOES exist for ${locked_sha} — this is not the
publication stall this job also watches for, and it is not a
malformed lock either. The lock is fine. It simply does not pin
${missing_count} of the ${DECLARED_COUNT} repos this commit declares:

EOF
		while IFS= read -r missing_name; do
			[ -n "$missing_name" ] || continue
			echo "  - ${missing_name}"
			echo "      declared in: $(declaring_sites "$missing_name")"
		done <<EOF
$MISSING_DECLARED
EOF
		cat <<EOF

WHY THIS IS SILENT WITHOUT THIS CHECK. Declaring a repo does not put
it in a lock. Locks are produced by a developer's pre-push hook (whose
repo set is whatever THAT developer had checked out) or by the
server-side re-anchor in .github/workflows/publish-workspace-lock.yml,
which copies every sibling pin verbatim from an older lock. Neither
producer reads the declarations, so a newly declared bare-name repo
has no pin to copy — and every later lock carries the same hole
forward from the one before it. Nothing converges on its own.

WHAT IT COSTS IF IGNORED. A bare \`siblings:\` entry resolves its
revision FROM this lock, so every job that reaches \`clone-siblings\`
for one of the names above dies with:

    resolve-sibling-rev: sibling '<name>' not present in lock

Already observed for isonim-tui, isonim-gpui, nim-termctl and nim-pty
(see ci/test/sibling-provisioning-test.sh) — they took out every job
that reached the action.

REMEDY, either one:

  * PUBLISH A LOCK THAT CONTAINS THEM. Check the repos out in a
    workspace, \`repro workspace lock\`, push the manifests repo — then
    re-anchor forward with publish-workspace-lock.yml's
    \`workflow_dispatch\` (source-sha = that new lock's commit).

  * OR STOP DECLARING THEM BARE. If a repo is not part of this
    workspace project, give it an explicit \`<name>=<ref>\` (or a
    40-hex SHA, which is reproducible) so it bypasses the lock, or
    drop it from the declaration site named above. Both are honest;
    leaving it bare and unlocked is not.

Newest commit touching locks/ in the manifests repo: ${newest_lock_date}.
EOF
		exit 4
	fi

	echo "Workspace lock present for ${locked_sha}, and it pins all ${DECLARED_COUNT} declared sibling repo(s)."
	if [ "$fetch_attempts" -gt 0 ]; then
		echo "Found by re-fetching the manifests repo ${fetch_attempts} time(s) over ${waited}s:" \
			"the lock was NOT in the snapshot this job cloned, so a single-snapshot" \
			"check would have called this commit unlocked."
	fi
	echo "Newest commit touching locks/ in the manifests repo: ${newest_lock_date}."
	exit 0
fi

# Not one round brought the checkout up to date. We did not observe absence, we
# failed to look — which is still red (an alarm must not go quiet because its
# own network broke) but it is emphatically not a report about publication.
if [ "$refreshable" -eq 1 ] && [ "$fetch_attempts" -gt 0 ] && [ "$refresh_successes" -eq 0 ]; then
	echo "::error::The manifests repo could not be re-fetched (${fetch_attempts} attempts over ${waited}s, none brought '${MANIFEST_DIR}' up to date), so no lock could be confirmed either way for: ${SHAS[*]}. This is a report about THIS job's access to '${manifest_remote}/${manifest_branch}' — an unreachable remote, or a checkout that cannot fast-forward — not about workspace-lock publication. Fix that, then read the result."
	exit 1
fi

# How the window was spent, stated so the reader can judge the verdict rather
# than take it on trust.
if [ "$refreshable" -eq 1 ]; then
	window_note="Re-fetched the manifests repo ${fetch_attempts} time(s) over a ${GRACE_SECONDS}s grace
window (waited ${waited}s) before concluding this, so the lock is absent
rather than merely late."
else
	window_note="NOTE: '${MANIFEST_DIR}' has no upstream to re-fetch, so this was answered
from a single snapshot with no grace window. A late-arriving lock could
not have been seen. In CI this directory is a fresh clone and IS
re-fetched; this wording means the check was pointed at a fixture."
fi

# WHICH CAUSE, derived rather than assumed. See the header's "Why it also
# reads the publisher's trigger list".
coverage_rc=0
publisher_covers "$BRANCH" || coverage_rc=$?
publisher_list="$(publisher_branches | sort -u | tr '\n' ' ')"

case "$coverage_rc" in
0)
	headline="WORKSPACE LOCK PUBLICATION HAS STALLED"
	cause_note="CAUSE: not the branch. '${BRANCH}' IS a publishing branch —
'${PUBLISHER_WORKFLOW#"$REPO_ROOT"/}' triggers on: ${publisher_list}—
so a record for this commit was expected and did not arrive. The
workspace-side shapes below are the ones to check."
	;;
1)
	headline="NO PUBLISHER IS CONFIGURED FOR BRANCH '${BRANCH}'"
	cause_note="CAUSE: the branch, not the workspace. '${BRANCH}' is NOT in the
trigger lists of '${PUBLISHER_WORKFLOW#"$REPO_ROOT"/}', which
publishes for: ${publisher_list}— so no lock was ever going to exist
for this commit, or for any other commit on this branch.

Nothing done in a developer's workspace can change that, and the
workspace-side shapes listed below are NOT what happened here. Read
this line before spending time in the post-commit log.

REMEDY: add '${BRANCH}' to that workflow's \`push:\` (and, if it is a
pull-request base, \`pull_request_target:\`) \`branches:\` list. Then
SEED ONE COMMIT: the forward carry only sustains itself once its head
is locked, so run that workflow's \`workflow_dispatch\` with
source-sha = a locked commit whose sibling set is current,
target-sha = a commit on '${BRANCH}', base-ref = '${BRANCH}'."
	;;
*)
	headline="WORKSPACE LOCK IS MISSING"
	if [ -z "$BRANCH" ]; then
		cause_note="CAUSE: NOT DETERMINED — no --branch was given, so this check could not
say whether a publisher is even configured for this branch. That is the
difference between 'the record was not produced' and 'no record was ever
going to exist', and it is worth passing --branch to learn."
	else
		cause_note="CAUSE: NOT DETERMINED — no \`branches:\` list could be read from
'${PUBLISHER_WORKFLOW}', so whether a publisher covers '${BRANCH}'
is unknown. Treat the workspace-side shapes below as candidates, not
as the diagnosis, and fix that file's readability first."
	fi
	;;
esac

cat <<EOF

==============================================================
  ${headline}
==============================================================

No workspace lock exists in the shared manifests repo for any of:

$(printf '  - %s\n' "${SHAS[@]}")

Branch under test: ${BRANCH:-<not given>}
Newest commit touching locks/ in that repo: ${newest_lock_date}.

${cause_note}

${window_note}

This job is an alarm, not a gate: nothing declares \`needs:\` on it and
it is absent from ci/verdict/required-jobs.txt, so it cannot skip a
test job.

But do NOT read that as "a missing lock is harmless". It stopped being
harmless when sibling entries went back to BARE names: a bare entry in
\`clone-siblings\` resolves its revision FROM THIS LOCK, so an unlocked
commit dies at \`Setup isonim siblings\` before it builds anything.
Measured on a \`cloud\` run: 11 of 21 failing jobs, all with
\`No workspace lock for codetracer (candidates: <base sha>)\`. The
sentence that used to sit here — that the test jobs no longer depend
on the lock — was true when the entries carried explicit refs and is
not true now.

It is also, still, a statement about the WORKSPACE: for every commit in
this window there is no published, reproducible snapshot of which
sibling revisions it was built against.

IF THE CAUSE ABOVE IS A STALL, these are the shapes to look for. If it
is branch coverage, they are not — skip them and do the remedy above.

The likely shape, because it is the one already observed: 'repro's
post-commit hook still writes the lock into a workspace-local checkout
of the manifests repo and logs 'ok wrote <path>', exit 0 — and nothing
commits or pushes it. Check for untracked files:

    git -C <workspace>/.repro/manifests status --porcelain locks/

Two other silent modes have been seen in the same logs, both exit 0:

    skipped-dirty  dirty sibling(s): <repo>     (no lock written at all)
    failed         repo '<x>' has no on-disk checkout at ...

    <workspace>/.repro/workspace/post-commit-lock.log

EOF
exit 1
